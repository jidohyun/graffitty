//! Frontend defaults used by the session owner's terminal colour queries.
//! Application OSC overrides are not part of this document.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ColorScheme {
    Dark,
    Light,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Theme {
    pub foreground: [u8; 3],
    pub background: [u8; 3],
    pub cursor: [u8; 3],
    pub scheme: ColorScheme,
    /// Exactly 256 resolved defaults, including sparse frontend overrides.
    #[serde(deserialize_with = "palette")]
    pub palette: Vec<[u8; 3]>,
}

fn palette<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Vec<[u8; 3]>, D::Error> {
    let colors = Vec::<[u8; 3]>::deserialize(deserializer)?;
    if colors.len() != 256 {
        return Err(serde::de::Error::custom(
            "Terminal theme requires 256 palette colors",
        ));
    }
    Ok(colors)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn theme_requires_one_complete_validated_schema() {
        let valid = json!({"foreground":[255,255,255],"background":[40,44,52],
            "cursor":[255,255,255],"scheme":"dark","palette":vec![[0,0,0];256]});
        let theme: Theme = serde_json::from_value(valid.clone()).unwrap();
        assert_eq!(serde_json::to_value(theme).unwrap(), valid);
        for (key, value) in [
            ("palette", json!([[0, 0, 0]])),
            ("palette", json!(vec![[0, 0, 0]; 257])),
            ("background", json!([256, 0, 0])),
            ("foreground", json!("#ffffff")),
            ("scheme", json!("auto")),
            ("opacity", json!(0.85)),
        ] {
            let mut invalid = valid.clone();
            invalid[key] = value;
            assert!(serde_json::from_value::<Theme>(invalid).is_err(), "{key}");
        }
        for key in ["foreground", "background", "cursor", "scheme", "palette"] {
            let mut invalid = valid.clone();
            invalid.as_object_mut().unwrap().remove(key);
            assert!(serde_json::from_value::<Theme>(invalid).is_err(), "{key}");
        }
    }
}
