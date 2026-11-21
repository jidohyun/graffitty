//! The `client.toml` document: schema validation, overlay merging, platform
//! filtering, and resolution for frontends.
//!
//! Value ranges that worlds also enforce on their programmatic settings remain
//! in the frontend's typed settings validators; this layer owns syntax, types,
//! names, enumerations, colors, menus, rules, and bindings.
use crate::bindings::{
    Action, InputConfig, PerOs, Platform, PrefixConfig, ResolvedBindings, Shortcuts,
    default_bindings,
};
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const FILE_NAME: &str = "client.toml";

#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(transparent)]
pub struct Color(String);

impl<'de> Deserialize<'de> for Color {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        let hex = text.strip_prefix('#').unwrap_or_default();
        if text == "none"
            || ([3, 4, 6, 8].contains(&hex.len()) && hex.bytes().all(|c| c.is_ascii_hexdigit()))
        {
            Ok(Self(text))
        } else {
            Err(D::Error::custom(format!(
                "invalid color {text:?}; expected #RGB, #RGBA, #RRGGBB, #RRGGBBAA, or \"none\""
            )))
        }
    }
}

macro_rules! names {
    ($name:ident { $($variant:ident = $text:literal),* $(,)? }) => {
        #[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
        pub enum $name { $(#[serde(rename = $text)] $variant),* }
    };
}

names!(CursorShape { Auto = "auto", Block = "block", Bar = "bar", Beam = "beam", Underline = "underline", Hollow = "hollow" });
names!(ClipboardRead { Deny = "deny", Ask = "ask", Allow = "allow" });
names!(CopyOnSelect { None = "none", Primary = "primary", Clipboard = "clipboard", Both = "both" });
names!(CursorBlink { Auto = "auto", On = "on", Off = "off" });
names!(WindowDecorations { Client = "client", System = "system" });
names!(BlurMaterial { Acrylic = "acrylic", Mica = "mica", Tabbed = "tabbed" });
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
pub enum UiScale {
    #[serde(rename = "auto")]
    Auto,
    #[serde(untagged)]
    Fixed(f64),
}
names!(TrailStyle { Smear = "smear", Blaze = "blaze", Lightning = "lightning" });
names!(ParticlePreset { None = "none", Sparks = "sparks", Dots = "dots", Fireworks = "fireworks", Flames = "flames", Glitter = "glitter" });
names!(RuleEvent { AppChanged = "app_changed", FocusChanged = "focus_changed", Active = "active" });

macro_rules! section {
    ($name:ident { $($field:ident : $kind:ty),* $(,)? }) => {
        #[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
        #[serde(deny_unknown_fields)]
        pub struct $name {
            $(#[serde(default, skip_serializing_if = "Option::is_none")] pub $field: Option<$kind>,)*
        }
    };
}

section!(WorldSection { path: String });
section!(MacosWindow { blur_radius: i64 });
section!(WindowsWindow {
    blur_material: BlurMaterial
});
section!(WindowSection {
    decorations: WindowDecorations,
    ui_scale: UiScale,
    max_fps: i64,
    inactive_max_fps: i64,
    background_blur: bool,
    macos: MacosWindow,
    windows: WindowsWindow,
});
// Effect settings and named profiles are inline client.toml tables.
names!(EffectZoomMode { Typing = "typing", Adaptive = "adaptive" });
names!(EffectShape { Flat = "flat", Saddle = "saddle" });
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(untagged)]
pub enum EffectGroupLimit { Enabled(bool), Gap(f64) }
section!(EffectCamera {
    zoom: f64, drift_px: f64, drift_speed: f64, shake_px: f64, shake_seconds: f64,
    tilt_limit_deg: f64, dof_blur_amount: f64, dof_blur_tint: Color,
    dof_blur_tint_strength: f64, decay: f64, overscroll: f64,
    left_preserving_cursor_follow_threshold: f64, top_preserving_cursor_follow_threshold: f64,
    zoom_sensitivity: f64, zoom_mode: EffectZoomMode, adaptive_zoom_in_seconds: f64,
    adaptive_zoom_out_seconds: f64, adaptive_group: BTreeMap<String, EffectGroupLimit>,
    graphics_plane_tilt_scale: f64, graphics_plane_lift: f64,
});
section!(EffectSheet {
    ripple: f64, typing_shape: EffectShape, curvature_deg: f64,
    ripple_wavelength: f64, ripple_speed: f64, ripple_falloff: f64,
    edge_margin: f64, corner_radius: f64, edge_blur: f64, edge_shadow: f64,
    edge_shadow_width: f64, content_gloss: f64,
});
section!(EffectLighting { strength: f64, minimum: f64, maximum: f64, color: Color });
section!(EffectSplash { scale: f64, speed: f64, life: f64 });
section!(EffectBehavior { enter_duration: f64, idle_after: f64, leave_duration: f64 });
section!(EffectTuning {
    camera: EffectCamera, sheet: EffectSheet, lighting: EffectLighting,
    splash: EffectSplash, behavior: EffectBehavior,
});

impl EffectTuning {
    /// Renderer assignments normalized once at the Rust configuration boundary.
    pub fn options(&self) -> Vec<(String, String, serde_json::Value)> {
        let value = serde_json::to_value(self).expect("effect settings serialize");
        let mut result = Vec::new();
        for (group, values) in value.as_object().unwrap() {
            for (key, value) in values.as_object().unwrap() {
                let (section, key) = match (group.as_str(), key.as_str()) {
                    ("camera", "zoom" | "drift_px" | "drift_speed" | "shake_px" | "shake_seconds" | "tilt_limit_deg")
                    | ("sheet", "ripple") => ("state.typing".into(), format!("{group}.{key}")),
                    ("splash", _) => ("scene.typing".into(), format!("splash_{key}")),
                    ("behavior", _) => ("behavior".into(), key.clone()),
                    _ => (format!("scene.{group}"), key.clone()),
                };
                result.push((section, key, value.clone()));
            }
        }
        result
    }

    fn validate(&self) -> Result<(), String> {
        for (_, key, value) in self.options() {
            if let Some(number) = value.as_f64() {
                let (min, max) = match key.as_str() {
                    "camera.zoom" => (0.1, 10.0),
                    "camera.tilt_limit_deg" | "curvature_deg" => (0.0, 90.0),
                    "adaptive_zoom_in_seconds" | "adaptive_zoom_out_seconds" | "splash_life" => (0.001, 60.0),
                    "content_gloss" | "edge_shadow" | "left_preserving_cursor_follow_threshold" | "top_preserving_cursor_follow_threshold" => (0.0, 1.0),
                    _ => (0.0, 10000.0),
                };
                if !number.is_finite() || number < min || number > max {
                    return Err(format!("effects.{key} must be finite and between {min} and {max}"));
                }
            }
        }
        if let Some(groups) = self.camera.as_ref().and_then(|c| c.adaptive_group.as_ref()) {
            for (name, limit) in groups {
                if !["main_view", "filetree", "chromium", "spawned", "graph"].contains(&name.as_str()) {
                    return Err(format!("Unknown effects.camera.adaptive_group relation {name}"));
                }
                if let EffectGroupLimit::Gap(gap) = limit {
                    if name == "main_view" || !gap.is_finite() || !(0.0..=1.0).contains(gap) {
                        return Err(format!("Invalid effects.camera.adaptive_group.{name}"));
                    }
                }
            }
        }
        Ok(())
    }
}

section!(EffectProfilesSection {
    profile: String,
    profiles: BTreeMap<String, EffectTuning>,
    camera: EffectCamera,
    sheet: EffectSheet,
    lighting: EffectLighting,
    splash: EffectSplash,
    behavior: EffectBehavior,
    // Effects switched off at startup, by effect name (the `ToggleEffect` switches).
    disabled: Vec<String>,
});
impl EffectProfilesSection {
    pub fn tuning(&self) -> EffectTuning {
        EffectTuning { camera: self.camera.clone(), sheet: self.sheet.clone(),
            lighting: self.lighting.clone(), splash: self.splash.clone(), behavior: self.behavior.clone() }
    }
    pub fn profile_options(&self) -> BTreeMap<String, Vec<(String, String, serde_json::Value)>> {
        let mut profiles: BTreeMap<String, EffectTuning> = toml::from_str(include_str!("../defaults/effect-profiles.toml"))
            .expect("built-in effect profiles validate");
        profiles.extend(self.profiles.clone().unwrap_or_default());
        profiles.into_iter().map(|(name, tuning)| (name, tuning.options())).collect()
    }
}

section!(TilingSection {
    enabled: bool,
    gap: f64
});
section!(PowerSection {
    enabled: bool,
    battery_world: String,
    external_world: String,
    follow_changes: bool
});
section!(BackgroundSection {
    color: Color,
    alpha: f64
});
section!(SmearTrail { color: Color });
section!(BlazeTrail {
    duration: f64,
    color: Color,
    accent_color: Color
});
section!(LightningTrail {
    duration: f64,
    color: Color,
    glow_color: Color,
    jaggedness: f64,
    core_width: f64,
    glow_width: f64,
});
section!(CursorTrailSection {
    style: TrailStyle,
    delay_ms: i64,
    decay: [f64; 2],
    start_threshold: [f64; 2],
    smear: SmearTrail,
    blaze: BlazeTrail,
    lightning: LightningTrail,
});
section!(TypingParticlesSection {
    preset: ParticlePreset,
    amount: i64,
    scale: f64,
});
section!(TypingPaneZoomSection { scale: f64 });
section!(EffectsSection {
    cursor_trail: CursorTrailSection,
    typing_particles: TypingParticlesSection,
    typing_pane_zoom: TypingPaneZoomSection,
});

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SymbolMap {
    pub first: u32,
    pub last: u32,
    pub family: String,
}

section!(TerminalSection {
    font_family: String, font_fallbacks: Vec<String>,
    font_regular_path: String, font_bold_path: String, font_italic_path: String, font_bold_italic_path: String,
    font_size: i64, ligatures: bool, line_height: f64, column_width: f64,
    font_features: BTreeMap<String, i64>, font_variations: BTreeMap<String, f64>, symbol_maps: Vec<SymbolMap>,
    foreground: Color, palette: Vec<Color>, palette_overrides: BTreeMap<String, Color>,
    selection_foreground: Color, selection_background: Color,
    cursor_color: Color, cursor_shape: CursorShape, cursor_blink: CursorBlink, cursor_blink_interval_ms: i64,
    cursor_beam_thickness: f64, cursor_underline_thickness: f64,
    text_outline: bool, text_outline_width: f64, text_outline_color: Color,
    background: BackgroundSection, effects: EffectsSection,
    clipboard_read: ClipboardRead, clipboard_write: bool, open_hyperlinks: bool, hyperlink_patterns: Vec<String>,
    scroll_multiplier: f64, selection_word_boundaries: String, iskeyword: Vec<String>, copy_on_select: CopyOnSelect,
    quick_select_patterns: Vec<String>, quick_select_defaults: bool, quick_select_alphabet: String,
    audible_bell: bool, visual_bell_duration_ms: i64, visual_bell_color: Color,
});

/// Menu-only commands that are not bindable actions.
#[derive(Clone, Copy, Debug, Serialize, PartialEq)]
#[serde(untagged)]
pub enum MenuAction {
    Action(Action),
    Special(MenuSpecial),
}

#[derive(Clone, Copy, Debug, Serialize, PartialEq)]
pub enum MenuSpecial {
    SwitchWorld,
    /// Sets one of the active world's `[worlds.<id>]` settings.
    SetWorldSetting,
    Separator,
}

impl MenuAction {
    pub fn name(self) -> &'static str {
        match self {
            Self::Action(action) => action.name(),
            Self::Special(MenuSpecial::SwitchWorld) => "SwitchWorld",
            Self::Special(MenuSpecial::SetWorldSetting) => "SetWorldSetting",
            Self::Special(MenuSpecial::Separator) => "Separator",
        }
    }
}

impl<'de> Deserialize<'de> for MenuAction {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let name = String::deserialize(deserializer)?;
        match name.as_str() {
            "SwitchWorld" => Ok(Self::Special(MenuSpecial::SwitchWorld)),
            "SetWorldSetting" => Ok(Self::Special(MenuSpecial::SetWorldSetting)),
            "Separator" => Ok(Self::Special(MenuSpecial::Separator)),
            _ => Action::from_name(&name)
                .map(Self::Action)
                .ok_or_else(|| D::Error::custom(format!("unknown menu action {name:?}"))),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct MenuItem {
    /// Menu path such as "View::World::Bistro".
    pub label: String,
    pub action: MenuAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    /// The panel folder an `OpenPanel` entry toggles.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// The text a `SendText` entry writes to the focused terminal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// Restricts the entry to these platforms; omitted means all platforms.
    #[serde(default, skip_serializing)]
    pub os: Option<Vec<Platform>>,
    /// Shows the entry only while the world with this manifest id is active.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub world: Option<String>,
    /// The dotted `[worlds.<id>]` key a `SetWorldSetting` entry sets, such as
    /// "weather.kind". The world's settings class owns its type and range.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub setting: Option<String>,
    /// The value a `SetWorldSetting` entry sets: a string, number or boolean.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<toml::Value>,
}

section!(MenuSection { items: Vec<MenuItem> });

names!(TouchKeyName {
    Copy = "copy", Paste = "paste",
    Escape = "escape", Tab = "tab", Ctrl = "ctrl", Alt = "alt", Shift = "shift",
    Left = "left", Down = "down", Up = "up", Right = "right",
    Home = "home", End = "end", PageUp = "page_up", PageDown = "page_down"
});
names!(TouchButton { Keyboard = "keyboard", TextSize = "text_size", Microphone = "microphone" });

/// A key on the touch key strip: one of the built-in keys, or a labelled key
/// that taps a registry action. New kinds of control (holds, drags, choosers)
/// are frontend features, not configuration.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(untagged)]
pub enum TouchKey {
    Key(TouchKeyName),
    Action(TouchAction),
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct TouchAction {
    /// The text the key shows.
    pub label: String,
    pub action: Action,
    /// The text a `SendText` key writes to the focused terminal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

impl<'de> Deserialize<'de> for TouchKey {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        match toml::Value::deserialize(deserializer)? {
            toml::Value::String(name) => TouchKeyName::deserialize(toml::Value::String(name.clone()))
                .map(TouchKey::Key)
                .map_err(|_| D::Error::custom(format!(
                    "unknown touch key {name:?}; use copy, paste, escape, tab, ctrl, alt, shift, left, down, up, right, home, end, page_up, page_down, or {{ label, action }}"
                ))),
            value @ toml::Value::Table(_) => TouchAction::deserialize(value)
                .map(TouchAction::into)
                .map_err(|error| D::Error::custom(format!("touch key: {error}"))),
            other => Err(D::Error::custom(format!(
                "touch key must be a key name or {{ label, action }}, not {}",
                other.type_str()
            ))),
        }
    }
}

impl From<TouchAction> for TouchKey {
    fn from(action: TouchAction) -> Self {
        TouchKey::Action(action)
    }
}

// Touch controls: the key strip above the soft keyboard and the floating
// buttons, in the order they appear. Omitted lists keep the defaults.
section!(TouchSection {
    keys: Vec<TouchKey>,
    buttons: Vec<TouchButton>
});

/// The shipped key strip, left to right. A narrow screen shows the start and
/// scrolls sideways to the navigation keys at the end.
pub const DEFAULT_TOUCH_KEYS: [TouchKeyName; 15] = [
    TouchKeyName::Copy, TouchKeyName::Paste,
    TouchKeyName::Escape, TouchKeyName::Tab, TouchKeyName::Ctrl, TouchKeyName::Alt,
    TouchKeyName::Shift, TouchKeyName::Left, TouchKeyName::Down, TouchKeyName::Up,
    TouchKeyName::Right,
    TouchKeyName::Home, TouchKeyName::End, TouchKeyName::PageUp, TouchKeyName::PageDown,
];
/// The shipped floating buttons.
pub const DEFAULT_TOUCH_BUTTONS: [TouchButton; 3] =
    [TouchButton::Keyboard, TouchButton::TextSize, TouchButton::Microphone];

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(untagged)]
pub enum Names {
    One(String),
    Many(Vec<String>),
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
pub enum RuleAction {
    SettleEffects,
    DisableEffects,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Rule {
    pub event: RuleEvent,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub app: Option<Names>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<Names>,
    pub action: RuleAction,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub include: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exclude: Option<Vec<String>>,
}

/// One client.toml document. Every field is optional so files can be layered.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct ClientFile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mods: Option<crate::mods::Registry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sounds: Option<SoundsSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub world: Option<WorldSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<WindowSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tiling: Option<TilingSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effects: Option<EffectProfilesSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub power: Option<PowerSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<TerminalSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub prefix: Option<PrefixConfig>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bindings: Option<BTreeMap<Action, PerOs<Shortcuts>>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub menu: Option<MenuSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub touch: Option<TouchSection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rules: Option<Vec<Rule>>,
    /// World-owned tables (`[worlds.<id>]`), opaque to the client like
    /// `[tool.<name>]` in pyproject.toml: only the named world reads one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worlds: Option<BTreeMap<String, toml::Value>>,
}

/// Client-side attention audio. Empty paths use the bundled sound.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct SoundsSection {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocked: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub done: Option<String>,
}

/// Settings without the sections that resolve into bindings, menus, and rules.
#[derive(Clone, Debug, Default, Serialize, PartialEq)]
pub struct Settings {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sounds: Option<SoundsSection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub world: Option<WorldSection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub window: Option<WindowSection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tiling: Option<TilingSection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub effects: Option<EffectProfilesSection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub power: Option<PowerSection>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal: Option<TerminalSection>,
    /// Always present: configured lists, or the defaults for omitted ones.
    pub touch: TouchSection,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub worlds: Option<BTreeMap<String, toml::Value>>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Resolved {
    pub mods: crate::mods::Registry,
    pub mod_order: Vec<String>,
    pub settings: Settings,
    pub bindings: ResolvedBindings,
    /// Configured menu entries for this platform; None keeps only built-ins.
    pub menu: Option<Vec<MenuItem>>,
    /// Configured rules; None keeps the frontend's default rules.
    pub rules: Option<Vec<Rule>>,
}

const FONT_PATHS: [&str; 4] = [
    "font_regular_path",
    "font_bold_path",
    "font_italic_path",
    "font_bold_italic_path",
];
const PATH_FIELDS: [(&str, &str); 5] = [
    ("sounds", "blocked"),
    ("sounds", "done"),
    ("world", "path"),
    ("power", "battery_world"),
    ("power", "external_world"),
];

/// Effect profiles every frontend provides. `world` keeps the world's own
/// effects; the others are frontend-owned presets that user profiles cannot replace.
pub const BUILTIN_EFFECT_PROFILES: [&str; 4] = ["world", "off", "mild", "exaggerated"];

/// Base directories that client paths may start from: `~` for home, and
/// `%(config)`, `%(data)`, `%(cache)`, `%(state)` for the app's stdpaths. The
/// frontend supplies its own stdpaths so the config and the app agree.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Dirs {
    pub home: Option<PathBuf>,
    pub config: Option<PathBuf>,
    pub data: Option<PathBuf>,
    pub cache: Option<PathBuf>,
    pub state: Option<PathBuf>,
}

impl Dirs {
    pub fn home(home: impl Into<PathBuf>) -> Self {
        Self { home: Some(home.into()), ..Self::default() }
    }

    /// Expand a leading `~`, `~/`, `%(kind)` or `%(kind)/`; other text is unchanged.
    pub fn expand(&self, text: &str) -> Result<String, String> {
        let (base, rest) = if let Some(placeholder) = text.strip_prefix("%(") {
            let (kind, rest) = placeholder
                .split_once(')')
                .ok_or_else(|| format!("{text:?}: unterminated %( placeholder"))?;
            let base = match kind {
                "config" => &self.config,
                "data" => &self.data,
                "cache" => &self.cache,
                "state" => &self.state,
                _ => {
                    return Err(format!(
                        "{text:?}: unknown placeholder %({kind}); use %(config), %(data), %(cache) or %(state)"
                    ));
                }
            };
            let base = base
                .as_ref()
                .ok_or_else(|| format!("{text:?}: the {kind} directory is unknown"))?;
            (base, rest)
        } else if let Some(rest) = text.strip_prefix('~').filter(|rest| rest.is_empty() || rest.starts_with('/')) {
            match &self.home {
                Some(home) => (home, rest),
                None => return Ok(text.into()),
            }
        } else {
            return Ok(text.into());
        };
        match rest {
            "" => Ok(base.display().to_string()),
            _ => match rest.strip_prefix('/') {
                // Joined as text: client paths use `/` on every platform, and
                // `Path::join` would put a `\` in the middle of one on Windows.
                Some(rest) if !rest.is_empty() => {
                    Ok(format!("{}/{rest}", base.display().to_string().trim_end_matches(['/', '\\'])))
                }
                _ => Err(format!("{text:?}: a placeholder must be followed by / and a path")),
            },
        }
    }
}

/// A relative `path` placed in `base`; a rooted one unchanged. Joined as
/// text, so the result keeps its `/` on Windows.
fn beside(base: &Path, path: String) -> String {
    let base = base.display().to_string();
    // `/fonts/x.ttf` is rooted on Windows without being absolute there.
    if Path::new(&path).has_root() || base.is_empty() {
        return path;
    }
    format!("{}/{path}", base.trim_end_matches(['/', '\\']))
}

/// Parse one document. Relative font and mod paths resolve against its
/// directory; `~` and `%(kind)` prefixes expand against `dirs` for fonts, mods,
/// sounds, worlds, and menu worlds.
pub fn parse(source: &str, path: &Path, dirs: &Dirs) -> Result<toml::Table, String> {
    let label = path.display();
    let mut table: toml::Table = source
        .parse()
        .map_err(|error: toml::de::Error| format!("{label}: {error}"))?;
    let file = ClientFile::deserialize(toml::Value::Table(table.clone()))
        .map_err(|error| format!("{label}: {error}"))?;
    validate_file(&file).map_err(|error| format!("{label}: {error}"))?;
    let base = path.parent().unwrap_or(Path::new(""));
    let expand = |text: &str| dirs.expand(text).map_err(|error| format!("{label}: {error}"));
    if let Some(terminal) = table
        .get_mut("terminal")
        .and_then(toml::Value::as_table_mut)
    {
        for key in FONT_PATHS {
            if let Some(toml::Value::String(value)) = terminal.get_mut(key)
                && !value.is_empty()
            {
                *value = beside(base, expand(value)?);
            }
        }
    }
    if let Some(toml::Value::Table(mods)) = table.get_mut("mods") {
        for (_, spec) in mods.iter_mut() {
            if let Some(toml::Value::String(value)) = spec.get_mut("entry") {
                if !value.starts_with("res://") {
                    *value = beside(base, expand(value)?);
                }
            }
        }
    }
    for (section, key) in PATH_FIELDS {
        if let Some(toml::Value::String(value)) =
            table.get_mut(section).and_then(|value| value.get_mut(key))
        {
            *value = expand(value)?;
        }
    }
    if let Some(toml::Value::Array(items)) =
        table.get_mut("menu").and_then(|menu| menu.get_mut("items"))
    {
        for item in items {
            if let Some(toml::Value::String(value)) = item.get_mut("path") {
                *value = expand(value)?;
            }
        }
    }
    Ok(table)
}

/// Later tables override earlier ones key by key; arrays and scalars replace.
/// A binding replaces the whole earlier value for that action.
pub fn merge(base: &mut toml::Table, overlay: toml::Table) {
    for (key, value) in overlay {
        match (base.get_mut(&key), value) {
            (Some(toml::Value::Table(existing)), toml::Value::Table(next)) => merge(existing, next),
            (_, value) => {
                base.insert(key, value);
            }
        }
    }
}

/// Load overlays in order. `bindings` merges per action: a later
/// `NewTab = { macos = ... }` replaces the earlier NewTab value entirely.
pub fn resolve_documents(
    documents: Vec<toml::Table>,
    platform: Platform,
) -> Result<Resolved, String> {
    let mut merged = toml::Table::new();
    for document in documents {
        // Per-OS binding maps must not merge with an earlier value for the same action.
        let mut document = document;
        if let Some(toml::Value::Table(next)) = document.remove("bindings") {
            let existing = merged
                .entry("bindings")
                .or_insert_with(|| toml::Value::Table(toml::Table::new()));
            if let toml::Value::Table(existing) = existing {
                existing.extend(next);
            }
        }
        merge(&mut merged, document);
    }
    let file =
        ClientFile::deserialize(toml::Value::Table(merged)).map_err(|error| error.to_string())?;
    validate_file(&file)?;
    if let Some(effects) = &file.effects {
        validate_effect_profile(effects)?;
    }
    let input = InputConfig {
        prefix: file.prefix.clone().unwrap_or_default(),
        bindings: file.bindings.clone().unwrap_or_default(),
    };
    let bindings = input.resolve(platform, &default_bindings(platform))?;
    let menu = file
        .menu
        .as_ref()
        .and_then(|menu| menu.items.as_ref())
        .map(|items| {
            items
                .iter()
                .filter(|item| item.os.as_ref().is_none_or(|os| os.contains(&platform)))
                .cloned()
                .collect()
        });
    let mods = crate::mods::resolve(file.mods.unwrap_or_default())?;
    let mod_order = crate::mods::order(&mods)?;
    Ok(Resolved {
        mods,
        mod_order,
        settings: Settings {
            sounds: file.sounds,
            language: file.language,
            world: file.world,
            window: file.window,
            tiling: file.tiling,
            effects: file.effects,
            power: file.power,
            terminal: file.terminal,
            touch: resolve_touch(file.touch.unwrap_or_default()),
            worlds: file.worlds,
        },
        bindings,
        menu,
        rules: file.rules,
    })
}

/// Schema and value checks for one layer, without resolving it.
pub fn validate_document(table: &toml::Table) -> Result<(), String> {
    let file = ClientFile::deserialize(toml::Value::Table(table.clone()))
        .map_err(|error| error.to_string())?;
    validate_file(&file)
}

/// Read and resolve the given files in overlay order.
pub fn load(
    paths: &[PathBuf],
    platform: Platform,
    dirs: &Dirs,
) -> Result<Resolved, String> {
    let mut documents = Vec::new();
    for path in paths {
        let source = std::fs::read_to_string(path)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        documents.push(parse(&source, path, dirs)?);
    }
    resolve_documents(documents, platform)
}

fn validate_file(file: &ClientFile) -> Result<(), String> {
    if let Some(UiScale::Fixed(scale)) = file.window.as_ref().and_then(|window| window.ui_scale)
        && (!(scale as f32).is_finite() || (scale as f32) <= 0.0)
    {
        return Err("window.ui_scale must be \"auto\" or a positive finite scale factor".into());
    }
    if let Some(mods) = &file.mods { crate::mods::validate(mods)?; }
    if file.language.as_ref().is_some_and(String::is_empty) {
        return Err("language must be \"auto\" or a locale code".into());
    }
    if let Some(terminal) = &file.terminal {
        if terminal
            .palette
            .as_ref()
            .is_some_and(|palette| palette.len() != 16)
        {
            return Err("terminal.palette must contain 16 ANSI colors".into());
        }
        for index in terminal.palette_overrides.iter().flat_map(BTreeMap::keys) {
            if !index
                .parse::<u8>()
                .is_ok_and(|value| value.to_string() == *index)
            {
                return Err(format!(
                    "terminal.palette_overrides key {index:?} must be an index 0..255"
                ));
            }
        }
        if let Some(maps) = &terminal.symbol_maps {
            for map in maps {
                if map.first > map.last || map.last > 0x10ffff || map.family.trim().is_empty() {
                    return Err("terminal.symbol_maps entries require first <= last <= 0x10FFFF and a family".into());
                }
            }
        }
    }
    if let Some(effects) = &file.effects {
        validate_effects(effects)?;
    }
    let input = InputConfig {
        prefix: file.prefix.clone().unwrap_or_default(),
        bindings: file.bindings.clone().unwrap_or_default(),
    };
    input.validate()?;
    if let Some(items) = file.menu.as_ref().and_then(|menu| menu.items.as_ref()) {
        validate_menu(items)?;
    }
    if let Some(touch) = &file.touch {
        validate_touch(touch)?;
    }
    for rule in file.rules.iter().flatten() {
        if rule.event == RuleEvent::Active && rule.action == RuleAction::SettleEffects {
            return Err("rules with event = \"active\" must use DisableEffects".into());
        }
        if rule.event != RuleEvent::Active && rule.action == RuleAction::DisableEffects {
            return Err("DisableEffects rules require event = \"active\"".into());
        }
    }
    Ok(())
}

fn validate_effects(effects: &EffectProfilesSection) -> Result<(), String> {
    effects.tuning().validate()?;
    for (name, tuning) in effects.profiles.iter().flatten() {
        let valid_name = !name.is_empty()
            && name
                .chars()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_');
        if !valid_name {
            return Err(format!(
                "effects.profiles key {name:?} must use lowercase letters, digits, - or _"
            ));
        }
        if BUILTIN_EFFECT_PROFILES.contains(&name.as_str()) {
            return Err(format!(
                "effects.profiles.{name} replaces a built-in profile; choose another name"
            ));
        }
        tuning.validate().map_err(|error| format!("effects.profiles.{name}: {error}"))?;
    }
    Ok(())
}

/// Overlays may define a profile that an earlier layer selects, so references
/// are checked on the merged document only.
fn validate_effect_profile(effects: &EffectProfilesSection) -> Result<(), String> {
    if let Some(profile) = &effects.profile {
        let defined = effects
            .profiles
            .as_ref()
            .is_some_and(|profiles| profiles.contains_key(profile));
        if !defined && !BUILTIN_EFFECT_PROFILES.contains(&profile.as_str()) {
            return Err(format!(
                "effects.profile {profile:?} must be one of {} or a name in [effects.profiles]",
                BUILTIN_EFFECT_PROFILES.join(", ")
            ));
        }
    }
    Ok(())
}

fn resolve_touch(touch: TouchSection) -> TouchSection {
    TouchSection {
        keys: Some(touch.keys.unwrap_or_else(|| DEFAULT_TOUCH_KEYS.map(TouchKey::Key).to_vec())),
        buttons: Some(touch.buttons.unwrap_or_else(|| DEFAULT_TOUCH_BUTTONS.to_vec())),
    }
}

/// A touch key or button as written in client.toml.
fn touch_name(value: &impl Serialize) -> String {
    toml::Value::try_from(value).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default()
}

fn validate_touch(touch: &TouchSection) -> Result<(), String> {
    let mut keys = Vec::new();
    for key in touch.keys.iter().flatten() {
        match key {
            TouchKey::Key(name) => {
                if keys.contains(name) {
                    return Err(format!("touch.keys lists {} twice", touch_name(name)));
                }
                keys.push(*name);
            }
            TouchKey::Action(entry) => {
                let label = &entry.label;
                if label.trim().is_empty() {
                    return Err("touch.keys: an action key needs a nonempty label".into());
                }
                let send_text = entry.action == Action::SendText;
                if send_text != entry.text.as_ref().is_some_and(|text| !text.is_empty()) {
                    return Err(format!(
                        "touch key {label:?}: SendText requires a nonempty text, and only SendText has one"
                    ));
                }
                // These need arguments a key cannot carry, or are only key bindings.
                if matches!(entry.action, Action::Ignore | Action::SetEffectsProfile | Action::ToggleEffect | Action::OpenPanel) {
                    return Err(format!(
                        "touch key {label:?}: {} cannot be a touch key", entry.action.name()
                    ));
                }
            }
        }
    }
    let mut buttons = Vec::new();
    for button in touch.buttons.iter().flatten() {
        if buttons.contains(button) {
            return Err(format!("touch.buttons lists {} twice", touch_name(button)));
        }
        buttons.push(*button);
    }
    Ok(())
}

/// The shape of a `SetWorldSetting` entry. Whether the world has that setting
/// and accepts the value is checked by the world when it is active.
fn validate_world_setting(item: &MenuItem) -> Result<(), String> {
    let label = &item.label;
    let sets = item.action == MenuAction::Special(MenuSpecial::SetWorldSetting);
    if !sets {
        return if item.setting.is_some() || item.value.is_some() {
            Err(format!("menu item {label:?}: setting and value are only allowed for SetWorldSetting"))
        } else {
            Ok(())
        };
    }
    if item.world.is_none() {
        return Err(format!("menu item {label:?}: SetWorldSetting requires the world it applies to"));
    }
    let setting = item.setting.as_deref().unwrap_or_default();
    let valid_part = |part: &str| {
        !part.is_empty() && part.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
    };
    if !setting.split('.').all(valid_part) {
        return Err(format!(
            "menu item {label:?}: setting must be a dotted key such as \"weather.kind\""
        ));
    }
    if setting.split('.').next() == Some("terminal") {
        return Err(format!(
            "menu item {label:?}: SetWorldSetting sets world settings, not [terminal]"
        ));
    }
    match &item.value {
        Some(toml::Value::String(_) | toml::Value::Integer(_) | toml::Value::Float(_) | toml::Value::Boolean(_)) => Ok(()),
        Some(_) => Err(format!("menu item {label:?}: value must be a string, number or boolean")),
        None => Err(format!("menu item {label:?}: SetWorldSetting requires a value")),
    }
}

fn validate_menu(items: &[MenuItem]) -> Result<(), String> {
    for platform in Platform::ALL {
        // Entries for different worlds are never shown together, so they may
        // share a label; a world-wide entry conflicts with every world.
        let mut labels: Vec<(&str, Option<&str>)> = Vec::new();
        for item in items
            .iter()
            .filter(|item| item.os.as_ref().is_none_or(|os| os.contains(&platform)))
        {
            let label = item.label.as_str();
            let parts: Vec<_> = label.split("::").collect();
            if parts.len() < 2 || parts.iter().any(|part| part.trim().is_empty()) {
                return Err(format!(
                    "menu label {label:?} must be Menu::Item (or deeper)"
                ));
            }
            let world = item.world.as_deref();
            let conflicts = |(other, other_world): &(&str, Option<&str>)| {
                (world.is_none() || other_world.is_none() || world == *other_world)
                    && (*other == label
                        || other.starts_with(&format!("{label}::"))
                        || label.starts_with(&format!("{other}::")))
            };
            if labels.iter().any(conflicts) {
                return Err(format!(
                    "duplicate or conflicting menu label {label:?} on {}",
                    platform.name()
                ));
            }
            labels.push((label, world));
        }
    }
    for item in items {
        let label = &item.label;
        if item.os.as_ref().is_some_and(Vec::is_empty) {
            return Err(format!(
                "menu item {label:?}: os must list at least one platform"
            ));
        }
        let world = item.action == MenuAction::Special(MenuSpecial::SwitchWorld);
        if world != item.path.is_some() {
            return Err(format!(
                "menu item {label:?}: path is required for SwitchWorld and only allowed there"
            ));
        }
        if item.world.as_ref().is_some_and(|world| world.trim().is_empty()) {
            return Err(format!("menu item {label:?}: world must be a world id"));
        }
        validate_world_setting(item)?;
        let chromium = item.action == MenuAction::Action(Action::NewChromium);
        let effects = item.action == MenuAction::Action(Action::SetEffectsProfile);
        if !chromium && item.url.is_some() {
            return Err(format!("menu item {label:?}: url is only allowed for NewChromium"));
        }
        if !chromium && !effects && item.profile.is_some() {
            return Err(format!(
                "menu item {label:?}: profile is only allowed for NewChromium and SetEffectsProfile"
            ));
        }
        if effects && item.profile.as_ref().is_none_or(String::is_empty) {
            return Err(format!("menu item {label:?}: SetEffectsProfile requires a profile"));
        }
        let open_mod = item.action == MenuAction::Action(Action::OpenPanel);
        if open_mod != item.name.as_ref().is_some_and(|name| !name.is_empty()) {
            return Err(format!("menu item {label:?}: OpenPanel requires a nonempty name, and only OpenPanel has one"));
        }
        let send_text = item.action == MenuAction::Action(Action::SendText);
        if send_text != item.text.as_ref().is_some_and(|text| !text.is_empty()) {
            return Err(format!(
                "menu item {label:?}: SendText requires a nonempty text, and only SendText has one"
            ));
        }
        if item.action == MenuAction::Action(Action::Ignore) {
            return Err(format!("menu item {label:?}: Ignore is only a key binding"));
        }
    }
    Ok(())
}
