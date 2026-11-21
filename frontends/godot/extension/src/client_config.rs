//! Godot adapter for `graffitty-client-config`: client.toml loading and the
//! shared action/binding registry, with key names converted to Godot keycodes.
use godot::classes::{DisplayServer, IRefCounted, RefCounted, RenderingServer};
use godot::classes::rendering_device::DeviceType;
use godot::global::{Key, KeyModifierMask};
use godot::prelude::*;
use graffitty_client_config::bindings::{Action, Chord, NAMED_KEYS, Platform, Shortcut};
use graffitty_client_config::config::Dirs;
use graffitty_client_config::remembered;
use graffitty_client_config::rendering::{self, AdapterType};
use std::path::PathBuf;

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct ClientConfig {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for ClientConfig {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

fn keycode(key: &str) -> i64 {
    let named = match key {
        "Space" => Key::SPACE,
        "Tab" => Key::TAB,
        "Enter" => Key::ENTER,
        "Escape" => Key::ESCAPE,
        "Backspace" => Key::BACKSPACE,
        "Delete" => Key::DELETE,
        "Insert" => Key::INSERT,
        "Left" => Key::LEFT,
        "Right" => Key::RIGHT,
        "Up" => Key::UP,
        "Down" => Key::DOWN,
        "Home" => Key::HOME,
        "End" => Key::END,
        "PageUp" => Key::PAGEUP,
        "PageDown" => Key::PAGEDOWN,
        "Backslash" => Key::BACKSLASH,
        "Slash" => Key::SLASH,
        "Minus" => Key::MINUS,
        "Equal" => Key::EQUAL,
        "Plus" => Key::PLUS,
        "Comma" => Key::COMMA,
        "Period" => Key::PERIOD,
        "Semicolon" => Key::SEMICOLON,
        "Colon" => Key::COLON,
        "Apostrophe" => Key::APOSTROPHE,
        "QuoteLeft" => Key::QUOTELEFT,
        "BracketLeft" => Key::BRACKETLEFT,
        "BracketRight" => Key::BRACKETRIGHT,
        "Bar" => Key::BAR,
        "Underscore" => Key::UNDERSCORE,
        "Percent" => Key::PERCENT,
        "Dollar" => Key::DOLLAR,
        "At" => Key::AT,
        _ => {
            if let Some(number) = key.strip_prefix('F').and_then(|n| n.parse::<i64>().ok()) {
                return Key::F1.ord() as i64 + number - 1;
            }
            // Letters and digits: Godot's logical keycodes are their ASCII values.
            return i64::from(key.as_bytes()[0]);
        }
    };
    debug_assert!(NAMED_KEYS.contains(&key));
    named.ord() as i64
}

/// Keycode combined with Godot modifier masks, as InputEventKey reports it.
fn chord_code(chord: &Chord) -> i64 {
    let mut code = keycode(&chord.key);
    for (pressed, mask) in [
        (chord.modifiers.ctrl, KeyModifierMask::CTRL),
        (chord.modifiers.alt, KeyModifierMask::ALT),
        (chord.modifiers.shift, KeyModifierMask::SHIFT),
        (chord.modifiers.meta, KeyModifierMask::META),
    ] {
        if pressed {
            code |= mask.ord() as i64;
        }
    }
    code
}

fn shortcut_variant(shortcut: &Shortcut) -> VarDictionary {
    let mut entry = VarDictionary::new();
    entry.set("prefix", shortcut.prefix);
    entry.set("key", chord_code(&shortcut.chord));
    entry
}

fn json_variant<T: serde::Serialize>(value: &T) -> Variant {
    crate::graph_client::to_variant(&serde_json::to_value(value).unwrap_or_default())
}

fn software_renderer() -> bool {
    let server = RenderingServer::singleton();
    let kind = if DisplayServer::singleton().get_name() == "headless" {
        AdapterType::Headless
    } else {
        match server.get_video_adapter_type() {
            DeviceType::CPU => AdapterType::Cpu,
            DeviceType::INTEGRATED_GPU => AdapterType::Integrated,
            DeviceType::DISCRETE_GPU => AdapterType::Discrete,
            DeviceType::VIRTUAL_GPU => AdapterType::Virtual,
            _ => AdapterType::Other,
        }
    };
    rendering::is_software(kind, &server.get_video_adapter_name().to_string())
}

#[godot_api]
impl ClientConfig {
    #[func]
    fn linux_text_scale() -> f64 {
        #[cfg(target_os = "linux")]
        { crate::x11_scale::text_scale() }
        #[cfg(not(target_os = "linux"))]
        { 1.0 }
    }

    /// Logical DPI from the active X display's desktop settings and environment.
    #[func]
    fn x11_ui_scale(display: i64) -> f64 {
        #[cfg(target_os = "linux")]
        {
            crate::x11_scale::for_display(display)
        }
        #[cfg(not(target_os = "linux"))]
        { let _ = display; 1.0 }
    }

    /// Whether the active renderer draws on the CPU; the same test that
    /// selects the software defaults.
    #[func]
    fn software_renderer() -> bool {
        software_renderer()
    }

    #[func]
    fn prefix_punctuation(unicode: i64, ctrl: bool, alt: bool, meta: bool) -> i64 {
        let Some(character) = u32::try_from(unicode).ok().and_then(char::from_u32) else { return 0; };
        graffitty_client_config::bindings::prefix_punctuation(&character.to_string(),
            graffitty_client_config::bindings::Modifiers { ctrl, alt, meta, ..Default::default() })
            .map_or(0, |character| i64::from(u32::from(character)))
    }

    /// Every bindable action, in registry order.
    #[func]
    fn actions() -> PackedStringArray {
        Action::ALL
            .iter()
            .map(|action| GString::from(action.name()))
            .collect()
    }

    /// Resolve `client.toml` overlays for `platform` (macos, windows, linux,
    /// android, ios).
    ///
    /// - Return `{error}` on failure. On success, return
    ///   `{settings, prefix, bindings, menu, rules, mods, mod_order}`.
    /// - `bindings` maps each action to `[{prefix, key}]` using Godot keycodes
    ///   and modifier masks. SendText adds `text`. Conditions add `when`.
    /// - `menu` and `rules` are null when unconfigured.
    /// - `dirs` supplies `home`, `config`, `data`, `cache`, and `state` for
    ///   expanding `~` and `%(kind)`. Missing or empty entries leave prefixes unresolved.
    /// - `remembered` is the UI's last-choice file. Layer it below `paths`,
    ///   or pass an empty value to omit it.
    #[func]
    fn load(paths: PackedStringArray, platform: GString, dirs: VarDictionary, remembered: GString) -> VarDictionary {
        let mut result = VarDictionary::new();
        let Some(platform) = Platform::from_name(&platform.to_string()) else {
            result.set("error", format!("unknown platform {platform}"));
            return result;
        };
        let paths: Vec<PathBuf> = paths
            .as_slice()
            .iter()
            .map(|path| PathBuf::from(path.to_string()))
            .collect();
        let dir = |kind: &str| {
            let value = dirs.get(kind).map(|value| value.to_string()).unwrap_or_default();
            (!value.is_empty()).then(|| PathBuf::from(value))
        };
        let dirs = Dirs {
            home: dir("home"),
            config: dir("config"),
            data: dir("data"),
            cache: dir("cache"),
            state: dir("state"),
        };
        let remembered = remembered.to_string();
        let remembered = (!remembered.is_empty()).then(|| PathBuf::from(remembered));
        match remembered::load(&paths, remembered.as_deref(), platform, &dirs) {
            Err(error) => result.set("error", error),
            Ok(mut resolved) => {
                rendering::apply_defaults(&mut resolved.settings, software_renderer());
                let mut mods = serde_json::to_value(&resolved.mods).unwrap();
                for (id, spec) in mods.as_object_mut().unwrap() {
                    spec.as_object_mut().unwrap().retain(|_, value| !value.is_null());
                    spec["persistence_key"] = graffitty_client_config::mods::persistence_key(id).into();
                }
                result.set("mods", &crate::graph_client::to_variant(&mods));
                result.set("mod_order", &json_variant(&resolved.mod_order));
                result.set("settings", &json_variant(&resolved.settings));
                let effects = resolved.settings.effects.clone().unwrap_or_default();
                result.set("effect_options", &json_variant(&effects.tuning().options()));
                result.set("effect_profiles", &json_variant(&effects.profile_options()));
                result.set("prefix", chord_code(&resolved.bindings.prefix));
                let mut bindings = VarDictionary::new();
                for (action, shortcuts) in &resolved.bindings.actions {
                    let entries: Array<VarDictionary> = shortcuts
                        .iter()
                        .map(|shortcut| {
                            let mut entry = shortcut_variant(shortcut);
                            if let Some(text) = resolved.bindings.texts.get(shortcut) {
                                entry.set("text", text.as_str());
                            }
                            if let Some(condition) = resolved.bindings.conditions.get(shortcut) {
                                entry.set("when", condition.name().as_str());
                            }
                            entry
                        })
                        .collect();
                    bindings.set(action.name(), &entries);
                }
                result.set("bindings", &bindings);
                let menu = resolved
                    .menu
                    .map_or(Variant::nil(), |items| json_variant(&items));
                result.set("menu", &menu);
                let rules = resolved
                    .rules
                    .map_or(Variant::nil(), |rules| json_variant(&rules));
                result.set("rules", &rules);
            }
        }
        result
    }

    /// Merge `choice`, a client.toml fragment such as `{effects: {profile}}`,
    /// into the remembered file at `path`. Returns an error text, or empty.
    #[func]
    fn remember(path: GString, choice: VarDictionary) -> GString {
        let table = crate::graph_client::from_variant(&choice.to_variant())
            .and_then(|value| toml::Table::try_from(value).map_err(|error| error.to_string()))
            .and_then(|table| remembered::remember(&PathBuf::from(path.to_string()), table));
        GString::from(table.err().unwrap_or_default().as_str())
    }
}
