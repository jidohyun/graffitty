//! Values that cross the script boundary, and colours.
//!
//! Adapted from gpui-kit's `value::Bridged` (Apache-2.0, Longbridge): numbers
//! are pixels, strings are colours or lengths, and nothing else is coerced.
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq)]
pub enum Bridged {
    Null,
    Bool(bool),
    Number(f64),
    Str(String),
    List(Vec<Bridged>),
}

impl Bridged {
    pub fn as_f32(&self) -> Option<f32> {
        match self {
            Bridged::Number(n) if n.is_finite() => Some(*n as f32),
            _ => None,
        }
    }

    pub fn as_str(&self) -> Option<&str> {
        match self {
            Bridged::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Bridged::Bool(b) => Some(*b),
            _ => None,
        }
    }

    pub fn to_json(&self) -> serde_json::Value {
        match self {
            Bridged::Null => serde_json::Value::Null,
            Bridged::Bool(b) => serde_json::Value::Bool(*b),
            Bridged::Number(n) => serde_json::Number::from_f64(*n).map_or(serde_json::Value::Null, serde_json::Value::Number),
            Bridged::Str(s) => serde_json::Value::String(s.clone()),
            Bridged::List(list) => serde_json::Value::Array(list.iter().map(Bridged::to_json).collect()),
        }
    }
}

/// sRGB with straight alpha, components in 0..=1.
#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Color {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Color {
    pub const fn rgba(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    /// `#rgb`, `#rrggbb`, `#rrggbbaa`, or a palette name. Herdr mods append a
    /// two-digit alpha to a theme colour (`t.blocked + "26"`), so an 8-digit
    /// hex is the common case, not an edge case.
    pub fn parse(text: &str, palette: &HashMap<String, Color>) -> Option<Color> {
        if let Some(hex) = text.strip_prefix('#') {
            let digits: Vec<u8> = hex.chars().map(|c| c.to_digit(16).map(|d| d as u8)).collect::<Option<_>>()?;
            let channel = |hi: u8, lo: u8| f32::from(hi * 16 + lo) / 255.0;
            return match digits.len() {
                3 => Some(Color::rgba(channel(digits[0], digits[0]), channel(digits[1], digits[1]), channel(digits[2], digits[2]), 1.0)),
                6 => Some(Color::rgba(channel(digits[0], digits[1]), channel(digits[2], digits[3]), channel(digits[4], digits[5]), 1.0)),
                8 => Some(Color::rgba(
                    channel(digits[0], digits[1]),
                    channel(digits[2], digits[3]),
                    channel(digits[4], digits[5]),
                    channel(digits[6], digits[7]),
                )),
                _ => None,
            };
        }
        if let Some((name, alpha)) = text.rsplit_once('/') {
            // `border/50`: a palette colour at a percentage, gpui-kit's token grammar.
            let color = palette.get(name)?;
            let percent: f32 = alpha.parse().ok()?;
            return Some(Color { a: color.a * (percent / 100.0).clamp(0.0, 1.0), ..*color });
        }
        palette.get(text).copied()
    }

    pub fn with_opacity(self, factor: f32) -> Color {
        Color { a: self.a * factor, ..self }
    }

    pub fn to_hex(self) -> String {
        let byte = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        if (self.a - 1.0).abs() < 1e-6 {
            format!("#{:02x}{:02x}{:02x}", byte(self.r), byte(self.g), byte(self.b))
        } else {
            format!("#{:02x}{:02x}{:02x}{:02x}", byte(self.r), byte(self.g), byte(self.b), byte(self.a))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_hex_forms_and_palette_names() {
        let mut palette = HashMap::new();
        palette.insert("accent".to_owned(), Color::rgba(1.0, 0.0, 0.0, 1.0));
        assert_eq!(Color::parse("#fff", &palette), Some(Color::rgba(1.0, 1.0, 1.0, 1.0)));
        assert_eq!(Color::parse("#ff000080", &palette).map(|c| (c.a * 255.0).round()), Some(128.0));
        assert_eq!(Color::parse("accent", &palette), Some(Color::rgba(1.0, 0.0, 0.0, 1.0)));
        assert_eq!(Color::parse("accent/50", &palette).map(|c| c.a), Some(0.5));
        assert_eq!(Color::parse("nope", &palette), None);
        assert_eq!(Color::rgba(1.0, 0.5, 0.0, 1.0).to_hex(), "#ff8000");
    }
}
