use graffitty_terminal_core::vt as libghostty_vt;
use godot::prelude::*;
use std::collections::HashMap;
use graffitty_terminal_core::copy_mode::IsKeyword;

pub fn value<T: FromGodot>(d: &VarDictionary, key: &str, fallback: T) -> T {
    d.get(key)
        .and_then(|v| v.try_to::<T>().ok())
        .unwrap_or(fallback)
}

#[derive(Clone)]
pub struct Options {
    pub cursor_blink: i64,
    pub cursor_period: f64,
    pub beam: f32,
    pub underline: f32,
    pub outline_width: i32,
    pub outline_color: Color,
    pub scroll_multiplier: f64,
    pub mouse_bypass: i64,
    pub copy_on_select: String,
    pub word_boundaries: Option<Vec<char>>,
    pub iskeyword: IsKeyword,
    pub quick_pattern: Option<std::sync::Arc<fancy_regex::Regex>>,
    pub quick_alphabet: String,
    pub modal: HashMap<String, HashMap<i64, String>>,
    pub hyperlinks: Vec<std::sync::Arc<fancy_regex::Regex>>,
    pub audible_bell: bool,
    pub visual_bell_duration: f64,
    pub visual_bell_color: Color,
    pub font_features: VarDictionary,
    pub font_variations: VarDictionary,
    pub symbol_maps: Array<VarDictionary>,
    pub mouse_bindings: Option<HashMap<(i32, i64), String>>,
}
impl Default for Options {
    fn default() -> Self {
        Self::parse(&VarDictionary::new())
    }
}
impl Options {
    pub fn bypasses_mouse(&self, mods: libghostty_vt::key::Mods) -> bool {
        use godot::global::KeyModifierMask as M;
        use libghostty_vt::key::Mods;
        let mut mask = 0i64;
        for (vt, godot) in [
            (Mods::SHIFT, M::SHIFT),
            (Mods::CTRL, M::CTRL),
            (Mods::ALT, M::ALT),
            (Mods::SUPER, M::META),
        ] {
            if mods.contains(vt) {
                mask |= godot.ord() as i64;
            }
        }
        self.mouse_bypass != 0 && mask & self.mouse_bypass == self.mouse_bypass
    }

    pub fn parse(d: &VarDictionary) -> Self {
        let patterns: PackedStringArray =
            value(d, "quick_select_patterns", PackedStringArray::new());
        let defaults = value(d, "quick_select_defaults", true);
        let mut sources: Vec<String> = patterns.to_vec().iter().map(ToString::to_string).collect();
        if defaults {
            sources.extend(crate::quick_select::PATTERNS.iter().map(|s| s.to_string()));
        }
        let pattern = if sources.is_empty() {
            "(?!)".to_owned()
        } else {
            format!("(?m)(?:{})", sources.join("|"))
        };
        let quick_pattern = match fancy_regex::Regex::new(&pattern) {
            Ok(p) => Some(std::sync::Arc::new(p)),
            Err(e) => {
                godot_warn!("Invalid Quick Select regex: {e}");
                None
            }
        };
        let mut modal = HashMap::new();
        let maps: VarDictionary = value(d, "modal_bindings", VarDictionary::new());
        for (name, map) in maps.iter_shared() {
            let Ok(name) = name.try_to::<GString>() else {
                continue;
            };
            let Ok(map) = map.try_to::<VarDictionary>() else {
                continue;
            };
            modal.insert(
                name.to_string(),
                map.iter_shared()
                    .filter_map(|(k, v)| {
                        Some((
                            k.try_to::<i64>().ok()?,
                            v.try_to::<GString>().ok()?.to_string(),
                        ))
                    })
                    .collect(),
            );
        }
        let hyperlinks: PackedStringArray =
            value(d, "hyperlink_patterns", PackedStringArray::new());
        let hyperlinks = hyperlinks
            .to_vec()
            .iter()
            .filter_map(|p| match fancy_regex::Regex::new(&p.to_string()) {
                Ok(p) => Some(std::sync::Arc::new(p)),
                Err(e) => {
                    godot_warn!("Invalid hyperlink regex: {e}");
                    None
                }
            })
            .collect();
        let mouse_bindings = d
            .get("mouse_bindings")
            .and_then(|v| v.try_to::<Array<VarDictionary>>().ok())
            .map(|entries| {
                entries
                    .iter_shared()
                    .map(|e| {
                        (
                            (value(&e, "button", 1i32), value(&e, "modifiers", 0i64)),
                            value(&e, "action", GString::new()).to_string(),
                        )
                    })
                    .collect()
            });
        Self {
            cursor_blink: value(d, "cursor_blink", -1i64),
            cursor_period: value(d, "cursor_blink_interval_ms", 500i64).max(1) as f64 / 1000.0,
            beam: value(d, "cursor_beam_thickness", 0.0f32),
            underline: value(d, "cursor_underline_thickness", 0.0f32),
            outline_width: value(d, "text_outline_width", 0.0f32).clamp(0.0, 32.0).round() as i32,
            outline_color: value(d, "text_outline_color", Color::BLACK),
            scroll_multiplier: value(d, "scroll_multiplier", 1.0f64).clamp(0.0, 100.0),
            mouse_bypass: value(
                d,
                "mouse_bypass_modifiers",
                godot::global::KeyModifierMask::SHIFT.ord() as i64,
            ),
            copy_on_select: value(d, "copy_on_select", GString::from("primary")).to_string(),
            word_boundaries: d
                .get("word_boundaries")
                .and_then(|v| v.try_to::<GString>().ok())
                .map(|s| s.to_string().chars().collect()),
            iskeyword: match d.get("iskeyword").and_then(|v| v.try_to::<GString>().ok()) {
                Some(rules) => IsKeyword::parse(&rules.to_string()).unwrap_or_else(|error| {
                    godot_warn!("{error}; using the default iskeyword");
                    IsKeyword::default()
                }),
                None => IsKeyword::default(),
            },
            quick_pattern,
            quick_alphabet: value(
                d,
                "quick_select_alphabet",
                GString::from(crate::quick_select::ALPHABET),
            )
            .to_string(),
            modal,
            hyperlinks,
            audible_bell: value(d, "audible_bell", false),
            visual_bell_duration: value(d, "visual_bell_duration_ms", 0i64).max(0) as f64 / 1000.0,
            visual_bell_color: value(
                d,
                "visual_bell_color",
                Color::from_rgba(1.0, 1.0, 1.0, 0.25),
            ),
            font_features: value(d, "font_features", VarDictionary::new()),
            font_variations: value(d, "font_variations", VarDictionary::new()),
            symbol_maps: value(d, "symbol_maps", Array::new()),
            mouse_bindings,
        }
    }
}
