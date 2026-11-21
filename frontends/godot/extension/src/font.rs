use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

use godot::classes::{Font, FontFile, FontVariation, Os, SystemFont, TextServerManager};
use godot::global::Error as GdError;
use godot::prelude::*;

// Font indices into Fonts::fonts. 0..4 are the JetBrains Mono styles.
// Here, I'm basically just trying to match what ghostty does.
const NOTO_MONO: i16 = 4;
const JULIA: i16 = 5;
const COLOR: i16 = 6;
const SYSTEM: i16 = 7;

fn embed(name: &str, bytes: &[u8]) -> Result<Gd<Font>, String> {
    let mut font = FontFile::new_gd();
    font.set_data(&PackedByteArray::from(bytes));
    if font.get_data().is_empty() {
        return Err(format!("font {name} failed to parse"));
    }
    Ok(font.upcast())
}

fn system(family: &str) -> Gd<Font> {
    let mut font = SystemFont::new_gd();
    font.set_font_names(&PackedStringArray::from([GString::from(family)]));
    // resolve() selects a concrete face; draw_char cannot draw a glyph that
    // has_char found only in an implicit system fallback.
    font.set_allow_system_fallback(false);
    font.upcast()
}

/// Explicit per-glyph font resolution.
///
/// Godot's draw_char is a blind first-match-wins over one flat list with no
/// presentation logic, so we order the fallbacks ourselves per codepoint,
/// keyed on the cell width that libghostty already computed.
pub struct Fonts {
    authoritative: bool,
    fonts: Vec<Gd<Font>>,
    /// System fonts discovered per codepoint, appended behind `fonts`.
    extra: RefCell<Vec<Gd<Font>>>,
    tried_paths: RefCell<HashSet<String>>,
    primary_cache: RefCell<HashMap<(u32, u8), bool>>,
    fallback_cache: RefCell<HashMap<(u32, bool, u8), i16>>,
    custom_start: usize,
    custom_end: usize,
    symbol_maps: Vec<(u32, u32, usize)>,
}

impl Fonts {
    /// Shared across terminals (the embedded data is large), dropped with
    /// the last one. A Weak cache avoids leaking font RIDs at exit.
    pub fn shared() -> Result<Rc<Self>, String> {
        thread_local! {
            static FONTS: RefCell<std::rc::Weak<Fonts>> =
                const { RefCell::new(std::rc::Weak::new()) };
        }
        FONTS.with(|cell| {
            let mut weak = cell.borrow_mut();
            if let Some(fonts) = weak.upgrade() {
                return Ok(fonts);
            }
            let fonts = Rc::new(Self::load()?);
            *weak = Rc::downgrade(&fonts);
            Ok(fonts)
        })
    }

    /// Explicit files win; otherwise resolve an installed family and its styles.
    pub fn configured(
        paths: &[GString],
        family: &str,
        fallbacks: &[GString],
        options: &crate::options::Options,
    ) -> Result<Rc<Self>, String> {
        let base = Self::configured_primary(paths, family)?;
        if fallbacks.is_empty()
            && options.font_features.is_empty()
            && options.font_variations.is_empty()
            && options.symbol_maps.is_empty()
        {
            return Ok(base);
        }
        let mut result = Self::with_fonts(base.fonts.clone());
        let installed = Os::singleton().get_system_fonts();
        for family in fallbacks {
            let requested = family.to_string();
            let Some(name) = installed
                .as_slice()
                .iter()
                .find(|name| name.to_string().eq_ignore_ascii_case(requested.trim()))
            else {
                godot_warn!("[graffitty] fallback font '{requested}' is not installed; skipping");
                continue;
            };
            for (weight, italic) in [(400, false), (700, false), (400, true), (700, true)] {
                let mut font = SystemFont::new_gd();
                font.set_font_names(&PackedStringArray::from([name.clone()]));
                font.set_font_weight(weight);
                font.set_font_italic(italic);
                // Each entry must only cover its own family, or an implicit OS
                // fallback would steal glyphs from later configured families.
                font.set_allow_system_fallback(false);
                result.fonts.push(font.upcast());
            }
        }
        result.custom_end = result.fonts.len();
        for mapping in options.symbol_maps.iter_shared() {
            let first: u32 = crate::options::value(&mapping, "first", 0u32);
            let last: u32 = crate::options::value(&mapping, "last", first);
            let name: GString = crate::options::value(&mapping, "family", GString::new());
            if !installed
                .as_slice()
                .iter()
                .any(|n| n.to_string().eq_ignore_ascii_case(&name.to_string()))
            {
                godot_warn!("[graffitty] symbol-map font '{name}' is not installed; skipping");
                continue;
            }
            let index = result.fonts.len();
            let mut font = SystemFont::new_gd();
            font.set_font_names(&PackedStringArray::from([name]));
            font.set_allow_system_fallback(false);
            result.fonts.push(font.upcast());
            result.symbol_maps.push((first, last, index));
        }
        if !options.font_features.is_empty() || !options.font_variations.is_empty() {
            let tags = |source: &VarDictionary| {
                let mut out = VarDictionary::new();
                if let Some(ts) = TextServerManager::singleton().get_primary_interface() {
                    for (key, value) in source.iter_shared() {
                        if let Ok(name) = key.try_to::<GString>() {
                            out.set(ts.name_to_tag(&name), &value);
                        }
                    }
                }
                out
            };
            let features = tags(&options.font_features);
            let axes = tags(&options.font_variations);
            for font in &mut result.fonts {
                let mut varied = FontVariation::new_gd();
                varied.set_base_font(&*font);
                varied.set_variation_opentype(&axes);
                varied.set_opentype_features(&features);
                *font = varied.upcast();
            }
        }
        Ok(Rc::new(result))
    }

    fn configured_primary(paths: &[GString], family: &str) -> Result<Rc<Self>, String> {
        if paths.first().is_some_and(|p| !p.is_empty()) {
            return Self::from_paths(paths);
        }
        let family = family.trim();
        if family.is_empty() {
            return Self::shared();
        }
        let installed = Os::singleton().get_system_fonts();
        let name = installed
            .as_slice()
            .iter()
            .find(|name| name.to_string().eq_ignore_ascii_case(family))
            .map(|name| name.to_string());
        let name = match name {
            Some(name) => name,
            None if ["monospace", "sans-serif", "serif"].contains(&family) => family.to_owned(),
            None => {
                godot_warn!(
                    "[graffitty] font family '{family}' is not installed; using bundled fonts"
                );
                return Self::shared();
            }
        };
        let mut fonts = Vec::new();
        for (weight, italic) in [(400, false), (700, false), (400, true), (700, true)] {
            let mut font = SystemFont::new_gd();
            font.set_font_names(&PackedStringArray::from([GString::from(name.as_str())]));
            font.set_font_weight(weight);
            font.set_font_italic(italic);
            // Preserve our per-glyph emoji/CJK fallback ordering.
            font.set_allow_system_fallback(false);
            fonts.push(font.upcast());
        }
        fonts.extend(Self::fallbacks()?);
        Ok(Rc::new(Self::with_fonts(fonts)))
    }

    /// Four style faces a host supplied as files, with the bundled fallback
    /// chain behind them.
    ///
    /// Not shared: these belong to one terminal, where the embedded set is
    /// shared by every terminal that did not ask for its own.
    pub fn from_paths(paths: &[GString]) -> Result<Rc<Self>, String> {
        if paths.is_empty() || paths[0].is_empty() {
            return Self::shared();
        }
        let load_one = |path: &GString| -> Result<Gd<Font>, String> {
            let mut font = FontFile::new_gd();
            if font.load_dynamic_font(path) != GdError::OK {
                return Err(format!("font {path} failed to load"));
            }
            Ok(font.upcast())
        };
        let regular = load_one(&paths[0])?;
        // A missing style is the regular face rather than an error: a world
        // that ships one file should not lose bold text over it.
        let style = |i: usize| -> Result<Gd<Font>, String> {
            match paths.get(i) {
                Some(p) if !p.is_empty() => load_one(p),
                _ => Ok(regular.clone()),
            }
        };
        let mut fonts = vec![regular.clone(), style(1)?, style(2)?, style(3)?];
        fonts.extend(Self::fallbacks()?);
        Ok(Rc::new(Self::with_fonts(fonts)))
    }

    /// The order here is load-bearing: resolve() indexes it with NOTO_MONO,
    /// JULIA, COLOR and SYSTEM, which count from the four style faces.
    fn fallbacks() -> Result<Vec<Gd<Font>>, String> {
        Ok(vec![
            embed(
                "NotoEmoji",
                crate::font_assets::NOTO_EMOJI,
            )?,
            embed(
                "JuliaMono",
                crate::font_assets::JULIA_MONO,
            )?,
            embed(
                "NotoColorEmoji",
                crate::font_assets::NOTO_COLOR_EMOJI,
            )?,
            system("monospace"),
            system("sans-serif"),
        ])
    }

    fn with_fonts(fonts: Vec<Gd<Font>>) -> Self {
        Self {
            authoritative: false,
            custom_start: fonts.len(),
            custom_end: fonts.len(),
            symbol_maps: Vec::new(),
            fonts,
            extra: RefCell::new(Vec::new()),
            tried_paths: RefCell::new(HashSet::new()),
            primary_cache: RefCell::new(HashMap::new()),
            fallback_cache: RefCell::new(HashMap::new()),
        }
    }

    /// Fonts are embedded so the extension works in any project without
    /// assets; system fonts fill scripts we cannot bundle (e.g. CJK).
    fn load() -> Result<Self, String> {
        let mut fonts = vec![
            embed(
                "Regular",
                crate::font_assets::REGULAR,
            )?,
            embed(
                "Bold",
                crate::font_assets::BOLD,
            )?,
            embed(
                "Italic",
                crate::font_assets::ITALIC,
            )?,
            embed(
                "BoldItalic",
                crate::font_assets::BOLD_ITALIC,
            )?,
        ];
        fonts.extend(Self::fallbacks()?);
        Ok(Self::with_fonts(fonts))
    }

    pub fn server(faces: &serde_json::Value) -> Result<Rc<Self>, String> {
        thread_local! { static CACHE: RefCell<HashMap<String, std::rc::Weak<Fonts>>> = RefCell::new(HashMap::new()); }
        let key = faces.to_string();
        CACHE.with(|cache| {
            if let Some(fonts) = cache.borrow().get(&key).and_then(std::rc::Weak::upgrade) { return Ok(fonts); }
            let entries = faces.as_array().ok_or("Missing font faces")?;
            if entries.len() < 7 || entries.len() > 167 || (entries.len()-7)%4 != 0 { return Err("Invalid font set".into()); }
            let mut loaded: Vec<Option<Gd<Font>>> = Vec::new();
            let mut files: HashMap<String, Gd<FontFile>> = HashMap::new();
            for entry in entries {
                let path = entry["path"].as_str().ok_or("Missing font path")?;
                // Still downloading in the background.
                if path.is_empty() { loaded.push(None); continue; }
                let file = if let Some(file) = files.get(path) { file.clone() } else {
                    let disk;
                    let bytes = if let Some(hash) = path.strip_prefix("bundled://") {
                        crate::font_assets::bundled(hash).ok_or("Unknown bundled font hash")?
                    } else {
                        disk = std::fs::read(path).map_err(|e| e.to_string())?;
                        &disk
                    };
                    let mut file = FontFile::new_gd();
                    file.set_data(&PackedByteArray::from(bytes));
                    file.set_allow_system_fallback(false);
                    files.insert(path.to_owned(), file.clone());
                    file
                };
                let index = entry["index"].as_i64().unwrap_or(0);
                if index < 0 || index >= file.get_face_count() { return Err("Invalid server font face index".into()); }
                let mut face = FontVariation::new_gd();
                face.set_base_font(&file.upcast::<Font>());
                face.set_variation_face_index(entry["index"].as_i64().unwrap_or(0) as i32);
                let ts = TextServerManager::singleton().get_primary_interface().ok_or("Missing text server")?;
                let mut features = VarDictionary::new();
                for (tag, value) in entry["features"].as_object().ok_or("Missing font features")? {
                    features.set(ts.name_to_tag(&GString::from(tag.as_str())), value.as_i64().ok_or("Invalid font feature")?);
                }
                let mut axes = VarDictionary::new();
                for (tag, value) in entry["variations"].as_object().ok_or("Missing font variations")? {
                    axes.set(ts.name_to_tag(&GString::from(tag.as_str())), value.as_f64().ok_or("Invalid font axis")?);
                }
                face.set_opentype_features(&features);
                face.set_variation_opentype(&axes);
                loaded.push(Some(face.upcast()));
            }
            // The owner measures only the regular primary face, so pending
            // faces change glyph appearance, never rows, columns or cells.
            //
            // Stand in with the regular style, this client's bundled emoji
            // and math fonts, and OS discovery for missing fallback families.
            let regular = loaded[0].clone().ok_or("Primary server font is not available")?;
            let partial = loaded.iter().any(Option::is_none);
            let embedded = if loaded[4..7].iter().any(Option::is_none) { Self::fallbacks()? } else { Vec::new() };
            let mut fonts = vec![regular.clone()];
            fonts.extend(loaded[1..4].iter().map(|face| face.clone().unwrap_or_else(|| regular.clone())));
            fonts.extend((4..7).map(|i| loaded[i].clone().unwrap_or_else(|| embedded[i - 4].clone())));
            for family in loaded[7..].chunks(4) {
                let first = family.iter().flatten().next().unwrap_or(&regular);
                fonts.extend(family.iter().map(|face| face.clone().unwrap_or_else(|| first.clone())));
            }
            let mut result = Self::with_fonts(fonts);
            result.authoritative = !partial;
            result.custom_start = 7;
            result.custom_end = result.fonts.len();
            for (index, entry) in entries.iter().enumerate().skip(7) {
                if let Some(range) = entry["symbol_range"].as_array() {
                    if range.len() != 2 { return Err("Invalid symbol range".into()); }
                    let first = range[0].as_u64().ok_or("Invalid symbol range")?;
                    let last = range[1].as_u64().ok_or("Invalid symbol range")?;
                    if first > last || last > 0x10ffff || (first <= 0xdfff && last >= 0xd800) { return Err("Invalid symbol scalar range".into()); }
                    result.custom_end = result.custom_end.min(index);
                    if (index-7)%4 == 0 { result.symbol_maps.push((first as u32,last as u32,index)); }
                }
            }
            let result = Rc::new(result);
            cache.borrow_mut().retain(|_, v| v.strong_count() > 0);
            cache.borrow_mut().insert(key, Rc::downgrade(&result));
            Ok(result)
        })
    }

    pub fn primary(&self) -> &Gd<Font> {
        &self.fonts[0]
    }

    pub fn style_font(&self, style: u8) -> &Gd<Font> {
        &self.fonts[style as usize]
    }

    pub fn style_index(bold: bool, italic: bool) -> u8 {
        match (bold, italic) {
            (false, false) => 0,
            (true, false) => 1,
            (false, true) => 2,
            (true, true) => 3,
        }
    }

    /// The font to draw a codepoint with, or None if nothing covers it.
    /// `wide` is evaluated only when the primary font lacks the glyph.
    pub fn resolve(&self, cp: u32, style: u8, wide: impl FnOnce() -> bool) -> Option<Gd<Font>> {
        match usize::try_from(self.resolve_index(cp, style, wide)) {
            Err(_) => None,
            Ok(i) if i < self.fonts.len() => Some(self.fonts[i].clone()),
            Ok(i) => Some(self.extra.borrow()[i - self.fonts.len()].clone()),
        }
    }

    /// Return the cached font slot `resolve` would draw from.
    /// The first four slots are style faces. Later slots are fallback fonts.
    ///
    /// Effects can use these slots to group fallback glyphs such as emoji,
    /// CJK characters, or Nerd Font icons.
    pub fn resolve_index(&self, cp: u32, style: u8, wide: impl FnOnce() -> bool) -> i32 {
        for &(first, last, index) in &self.symbol_maps {
            if (first..=last).contains(&cp) && self.fonts[index].has_char(cp) {
                return index as i32;
            }
        }
        let primary = *self
            .primary_cache
            .borrow_mut()
            .entry((cp, style))
            .or_insert_with(|| self.fonts[style as usize].has_char(cp));
        if primary {
            return i32::from(style);
        }
        let wide = wide();
        i32::from(
            *self
                .fallback_cache
                .borrow_mut()
                .entry((cp, wide, style))
                .or_insert_with(|| self.compute_fallback(cp, wide, style)),
        )
    }

    /// Emoji cells prefer color; text cells prefer monochrome, taking Noto's
    /// mono emoji first (matching ghostty for media/clock symbols), except
    /// single-cell dingbats, whose emoji glyphs exceed the text cell.
    ///
    /// Prefer JuliaMono for those text symbols; system fonts cover uncovered
    /// scripts, with remaining scripts discovered from the OS per codepoint.
    fn compute_fallback(&self, cp: u32, wide: bool, style: u8) -> i16 {
        for first in (self.custom_start..self.custom_end).step_by(4) {
            let i = first + style as usize;
            if self.fonts[i].has_char(cp) {
                return i as i16;
            }
        }
        let head: [i16; 3] = if wide {
            [COLOR, NOTO_MONO, JULIA]
        } else if (0x2700..=0x27bf).contains(&cp) {
            [JULIA, NOTO_MONO, COLOR]
        } else {
            [NOTO_MONO, JULIA, COLOR]
        };
        let order = head.into_iter().chain(SYSTEM..self.custom_start as i16);
        for i in order {
            if self.fonts[i as usize].has_char(cp) {
                return i;
            }
        }
        for (i, font) in self.extra.borrow().iter().enumerate() {
            if font.has_char(cp) {
                return (self.fonts.len() + i) as i16;
            }
        }
        if self.authoritative { return -1; }
        self.discover(cp)
    }

    /// Ask the OS for fonts that cover `cp` and load the first suitable one.
    /// `draw_char` skips shaping, so Godot's shaping fallback cannot find it.
    /// Leave the cell blank if the search finds no font, as Ghostty does.
    fn discover(&self, cp: u32) -> i16 {
        let Some(ch) = char::from_u32(cp) else {
            return -1;
        };
        #[allow(unused_mut)]
        let mut paths =
            Os::singleton().get_system_font_path_for_text("monospace", ch.to_string().as_str());
        // Android export templates do not expose system font discovery through
        // Godot's OS API. The platform CJK collection is still readable. Load
        // it lazily only when the bundled fonts lack a glyph, not at startup.
        #[cfg(target_os = "android")]
        {
            for path in [
                "/system/fonts/NotoSansCJK-Regular.ttc",
                "/system/fonts/NotoSansCJK-VF.ttc",
            ] {
                if std::path::Path::new(path).is_file() {
                    paths.push(&GString::from(path));
                }
            }
        }
        for path in paths.as_slice() {
            let key = path.to_string();
            if !self.tried_paths.borrow_mut().insert(key) {
                continue;
            }
            let mut font = FontFile::new_gd();
            if font.load_dynamic_font(path) != GdError::OK {
                continue;
            }
            // Keep every loaded font: the extra scan serves codepoints this
            // one covers even when the requested one is missing from it.
            let covers = font.has_char(cp);
            let mut extra = self.extra.borrow_mut();
            extra.push(font.upcast());
            if covers {
                return (self.fonts.len() + extra.len() - 1) as i16;
            }
        }
        -1
    }
}
