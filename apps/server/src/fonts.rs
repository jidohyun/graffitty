//! Owner-side font assets and logical geometry. No renderer or display needed.
use crate::Error;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Arc,
};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub family: String,
    pub paths: Vec<String>,
    pub fallbacks: Vec<String>,
    pub size: u16,
    pub line_height: f32,
    pub column_width: f32,
    pub cell_width: u16,
    pub cell_height: u16,
    pub ligatures: bool,
    pub features: BTreeMap<String, u32>,
    pub variations: BTreeMap<String, f32>,
    pub symbol_maps: Vec<SymbolMap>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SymbolMap {
    pub first: u32,
    pub last: u32,
    pub family: String,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            family: String::new(),
            paths: vec![],
            fallbacks: vec![],
            size: 16,
            line_height: 1.,
            column_width: 1.,
            cell_width: 0,
            cell_height: 0,
            ligatures: true,
            features: BTreeMap::new(),
            variations: BTreeMap::new(),
            symbol_maps: vec![],
        }
    }
}
impl Config {
    pub fn validate(&self) -> Result<(), String> {
        let tag = |name: &String| name.len() == 4 && name.bytes().all(|b| (0x20..=0x7e).contains(&b));
        if self.features.len() > 64 || self.variations.len() > 32
            || self.features.keys().any(|key| !tag(key))
            || self.variations.iter().any(|(key, value)| !tag(key) || !value.is_finite())
            || self.cell_width > 512 || self.cell_height > 512
            || self.symbol_maps.len() > 16
            || self.symbol_maps.iter().any(|m| m.first > m.last || m.last > 0x10ffff
                || (m.first <= 0xdfff && m.last >= 0xd800) || m.family.trim().is_empty())
        { return Err("Invalid advanced font settings: four-character OpenType tags, finite axes, scalar Unicode ranges and cells up to 512 pixels required".into()); }
        if !(1..=72).contains(&self.size)
            || self.paths.len() > 4
            || self.fallbacks.len() > 24
            || !self.line_height.is_finite()
            || !(0.5..=3.).contains(&self.line_height)
            || !self.column_width.is_finite()
            || !(0.5..=3.).contains(&self.column_width)
        {
            return Err("Invalid terminal.font: size 1–72, up to four style paths, 24 fallback families, metric multipliers 0.5–3".into());
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Serialize)]
pub struct Metrics {
    pub width: u32,
    pub height: u32,
    pub baseline: f32,
    pub underline: f32,
    pub thickness: f32,
}
pub struct Fonts {
    config: Config,
    faces: Vec<Value>,
    assets: BTreeMap<String, Arc<Vec<u8>>>,
    paths: BTreeMap<String, PathBuf>,
    advance: f32,
    ascent: f32,
    descent: f32,
    gap: f32,
    underline: f32,
    thickness: f32,
}
impl Fonts {
    pub fn load(config: &Config, base: &Path) -> Result<Self, Error> {
        config.validate()?;
        let mut db = fontdb::Database::new();
        db.load_system_fonts();
        let mut raw: Vec<(Arc<Vec<u8>>, u32)> = vec![];
        let mut files = BTreeMap::new();
        let bundled: [&[u8]; 4] = [
            include_bytes!(
                "../../../frontends/godot/extension/fonts/JetBrainsMonoNerdFont-Regular.ttf"
            ),
            include_bytes!(
                "../../../frontends/godot/extension/fonts/JetBrainsMonoNerdFont-Bold.ttf"
            ),
            include_bytes!(
                "../../../frontends/godot/extension/fonts/JetBrainsMonoNerdFont-Italic.ttf"
            ),
            include_bytes!(
                "../../../frontends/godot/extension/fonts/JetBrainsMonoNerdFont-BoldItalic.ttf"
            ),
        ];
        for style in 0..4 {
            if !config.paths.is_empty() {
                let path = config
                    .paths
                    .get(style)
                    .filter(|p| !p.is_empty())
                    .unwrap_or(&config.paths[0]);
                let path = base.join(path);
                raw.push((Self::read_file(&path, &mut files)?, 0));
            } else if !config.family.is_empty() {
                raw.push(Self::family(&db, &config.family, style, &mut files)?);
            } else {
                raw.push((Arc::new(bundled[style].to_vec()), 0));
            }
        }
        // Stable bundled emoji/math coverage; configured families take priority
        // for missing primary glyphs on every client, independent of its OS.
        for bytes in [
            include_bytes!("../../../frontends/godot/extension/fonts/NotoEmoji-Regular.ttf")
                .as_slice(),
            include_bytes!("../../../frontends/godot/extension/fonts/JuliaMono-Regular.ttf")
                .as_slice(),
            include_bytes!("../../../frontends/godot/extension/fonts/NotoColorEmoji.ttf")
                .as_slice(),
        ] {
            raw.push((Arc::new(bytes.to_vec()), 0));
        }
        let mut fallbacks = config.fallbacks.clone();
        if fallbacks.is_empty() {
            for name in [
                "Noto Sans CJK KR",
                "Noto Sans KR",
                "Apple SD Gothic Neo",
                "Malgun Gothic",
            ] {
                if db
                    .query(&fontdb::Query {
                        families: &[fontdb::Family::Name(name)],
                        ..Default::default()
                    })
                    .is_some()
                {
                    fallbacks.push(name.into());
                    break;
                }
            }
        }
        for name in &fallbacks {
            for style in 0..4 {
                raw.push(Self::family(&db, name, style, &mut files)?);
            }
        }
        let symbol_start = raw.len();
        for mapping in &config.symbol_maps {
            for style in 0..4 { raw.push(Self::family(&db, &mapping.family, style, &mut files)?); }
        }
        let mut face = ttf_parser::Face::parse(&raw[0].0, raw[0].1)
            .map_err(|e| format!("Invalid primary font: {e:?}"))?;
        for (tag, value) in &config.variations {
            let tag = ttf_parser::Tag::from_bytes(tag.as_bytes().try_into().unwrap());
            let axis = face.variation_axes().into_iter().find(|axis| axis.tag == tag)
                .ok_or("Requested variation axis is not present in the primary font")?;
            if *value < axis.min_value || *value > axis.max_value { return Err("Font variation is outside the installed axis range".into()); }
            face.set_variation(tag, *value).ok_or("Cannot apply font variation")?;
        }
        let unit = f32::from(face.units_per_em());
        let advance = face
            .glyph_index('M')
            .and_then(|g| face.glyph_hor_advance(g))
            .ok_or("Primary font lacks M advance")? as f32
            / unit;
        let underline = face.underline_metrics();
        let mut result = Self {
            config: config.clone(),
            faces: vec![],
            assets: BTreeMap::new(),
            paths: BTreeMap::new(),
            advance,
            ascent: f32::from(face.ascender()) / unit,
            descent: -f32::from(face.descender()) / unit,
            gap: f32::from(face.line_gap()).max(0.) / unit,
            underline: underline.map_or(0.1, |m| -f32::from(m.position) / unit),
            thickness: underline.map_or(0.05, |m| f32::from(m.thickness) / unit),
        };
        let mut hashes = std::collections::HashMap::new();
        for (slot, (bytes, index)) in raw.into_iter().enumerate() {
            if bytes.len() > 64 * 1024 * 1024 {
                return Err("Font exceeds 64 MiB".into());
            }
            let face = ttf_parser::Face::parse(&bytes, index)
                .map_err(|e| format!("Invalid font face: {e:?}"))?;
            let families: Vec<String> = face.names().into_iter()
                .filter(|n| matches!(n.name_id, 1 | 16)).filter_map(|n| n.to_string()).collect();
            let hash = hashes
                .entry(Arc::as_ptr(&bytes))
                .or_insert_with(|| {
                    Sha256::digest(bytes.as_slice())
                        .iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect::<String>()
                })
                .clone();
            result
                .faces
                .push(json!({"sha256":hash,"bytes":bytes.len(),"index":index,"families":families,"weight":face.weight().to_number(),"italic":face.is_italic(),
                    "features":config.features,"variations":config.variations,
                    "symbol_range":if slot >= symbol_start { let mapping=&config.symbol_maps[(slot-symbol_start)/4]; json!([mapping.first,mapping.last]) } else { Value::Null }}));
            if let Some((path, _)) = files.iter().find(|(_, data)| Arc::ptr_eq(data, &bytes)) {
                result.paths.insert(hash.clone(), path.clone());
            }
            result.assets.entry(hash).or_insert(bytes);
        }
        Ok(result)
    }
    fn read_file(
        path: &Path,
        files: &mut BTreeMap<PathBuf, Arc<Vec<u8>>>,
    ) -> Result<Arc<Vec<u8>>, Error> {
        if let Some(bytes) = files.get(path) {
            return Ok(bytes.clone());
        }
        if std::fs::metadata(path).map_err(|error| format!("Font {}: {error}",path.display()))?.len() > 64 * 1024 * 1024 {
            return Err("Font exceeds 64 MiB".into());
        }
        let bytes = Arc::new(std::fs::read(path).map_err(|error| format!("Font {}: {error}",path.display()))?);
        files.insert(path.to_owned(), bytes.clone());
        Ok(bytes)
    }
    fn family(
        db: &fontdb::Database,
        family: &str,
        style: usize,
        files: &mut BTreeMap<PathBuf, Arc<Vec<u8>>>,
    ) -> Result<(Arc<Vec<u8>>, u32), Error> {
        let id = db
            .query(&fontdb::Query {
                families: &[fontdb::Family::Name(family)],
                weight: if style % 2 == 1 {
                    fontdb::Weight::BOLD
                } else {
                    fontdb::Weight::NORMAL
                },
                style: if style >= 2 {
                    fontdb::Style::Italic
                } else {
                    fontdb::Style::Normal
                },
                ..Default::default()
            })
            .ok_or_else(|| format!("Server font family is not installed: {family}"))?;
        let face = db.face(id).ok_or("Missing font face")?;
        if let fontdb::Source::File(path) | fontdb::Source::SharedFile(path, _) = &face.source {
            return Ok((Self::read_file(path, files)?, face.index));
        }
        db.with_face_data(id, |bytes, index| (Arc::new(bytes.to_vec()), index))
            .ok_or_else(|| "Cannot read font face".into())
    }
    pub fn manifest(&self) -> Value {
        json!({"faces":self.faces,"default_size":self.config.size,"config":self.config})
    }
    pub fn local_path(&self, hash: &str) -> Option<&Path> { self.paths.get(hash).map(PathBuf::as_path) }
    pub fn asset(&self, hash: &str, offset: usize, max_bytes: usize) -> Result<Value, Error> {
        use base64::Engine;
        let bytes = self.assets.get(hash).ok_or("Unknown font asset")?;
        if offset >= bytes.len() {
            return Err("Invalid font offset".into());
        }
        let end = (offset + max_bytes.clamp(32 * 1024, 512 * 1024)).min(bytes.len());
        Ok(
            json!({"sha256":hash,"offset":offset,"total":bytes.len(),"data":base64::engine::general_purpose::STANDARD.encode(&bytes[offset..end])}),
        )
    }
    pub fn metrics(&self, size: u16) -> Metrics {
        let size = size as f32;
        let line =
            (self.ascent * size).ceil() + (self.descent * size).ceil() + (self.gap * size).ceil();
        let height = if self.config.cell_height > 0 { u32::from(self.config.cell_height) } else { (line * self.config.line_height).ceil().max(1.) as u32 };
        let baseline = ((self.ascent * size).ceil() + (height as f32 - line) * 0.5).round();
        Metrics {
            width: if self.config.cell_width > 0 { u32::from(self.config.cell_width) } else { (self.advance * size * self.config.column_width)
                .ceil()
                .max(1.) as u32 },
            height,
            baseline,
            underline: (baseline + self.underline * size).round(),
            thickness: (self.thickness * size).round().max(1.),
        }
    }
}
