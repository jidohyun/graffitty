//! Versioned wire contract shared by the session owner and its frontends.
//! This crate contains no terminal engine, transport, operating-system or UI code.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{error::Error, fmt};
pub mod clipboard;
pub mod file_transfer;
pub mod controller;
pub mod osc;

pub const VERSION: u64 = 1;

/// The directory one user's session server keeps its descriptor, lock and
/// authentication in: `$XDG_STATE_HOME/graffitty`, else
/// `%LOCALAPPDATA%\graffitty` on Windows and `~/.local/state/graffitty`
/// elsewhere.
///
/// The server and everything that looks for it use this one rule. A server
/// started by hand and the app must find each other, or the app starts a
/// second server beside the first.
pub fn server_state_directory() -> Option<std::path::PathBuf> {
    use std::path::PathBuf;
    let base = std::env::var_os("XDG_STATE_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).or_else(|| {
        if cfg!(windows) {
            std::env::var_os("LOCALAPPDATA").map(PathBuf::from)
        } else {
            std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state"))
        }
    })?;
    Some(base.join("graffitty"))
}

/// The descriptor a server writes when no other is named: `server.json` in
/// `server_state_directory`.
pub fn default_server_descriptor() -> Option<std::path::PathBuf> {
    server_state_directory().map(|directory| directory.join("server.json"))
}
pub const DEFAULT_REMOTE_PORT: u16 = 7183;
pub const MAGIC: &[u8; 4] = b"GRT2";
pub const MAX_HEADER: usize = 65_536;
pub const MAX_COMMAND_PACKET: usize = 131_072;

macro_rules! id {
    ($name:ident) => {
        #[derive(Clone, Copy, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub u64);
        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { self.0.fmt(f) }
        }
        impl From<u64> for $name { fn from(value: u64) -> Self { Self(value) } }
        impl From<$name> for u64 { fn from(value: $name) -> Self { value.0 } }
    };
}
id!(SessionId);
id!(TabId);
id!(ChromiumId);
id!(RequestId);
id!(FrontendId);

/// Encoded chromium frames always carry both encoded and original input dimensions.
/// Required fields deliberately have no deserialization defaults.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename = "chromium", remote = "Self")]
pub struct ChromiumVideoHeader {
    pub session: u64,
    pub format: String,
    pub frame: u64,
    pub epoch: u64,
    pub sequence: u64,
    pub key: bool,
    pub width: u32,
    pub height: u32,
    pub source_width: u32,
    pub source_height: u32,
}

impl Serialize for ChromiumVideoHeader {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        Self::serialize(self, serializer)
    }
}

impl<'de> Deserialize<'de> for ChromiumVideoHeader {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        // A tagged struct's derived deserializer ignores the tag's value. An
        // enum validates it, so obsolete frame types cannot enter this schema.
        #[derive(Deserialize)]
        #[serde(tag = "type")]
        enum Envelope {
            #[serde(rename = "chromium")]
            Chromium(#[serde(with = "ChromiumVideoHeader")] ChromiumVideoHeader),
        }
        let Envelope::Chromium(header) = Envelope::deserialize(deserializer)?;
        Ok(header)
    }
}

/// Terminal presentation data. A frame is not a complete VT checkpoint.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct Cell(pub u16, pub u16, pub String, pub String, pub String, pub u8);
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct Frame {
    pub columns: u16,
    pub rows: u16,
    pub foreground: String,
    pub background: String,
    pub title: String,
    pub exited: bool,
    pub font_size: u16,
    pub cursor: Vec<u16>,
    #[serde(default)]
    pub cursor_style: u8,
    pub input_modes: Vec<u16>,
    pub kitty_keys: u32,
    pub lines: Vec<Vec<Cell>>,
}

/// Command arguments are flattened alongside the type and request identifier.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Command {
    #[serde(rename = "type")]
    pub action: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<RequestId>,
    #[serde(default, flatten)]
    pub fields: serde_json::Map<String, Value>,
}

#[derive(Debug)]
pub struct WireError(&'static str);
impl fmt::Display for WireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result { f.write_str(self.0) }
}
impl Error for WireError {}

/// Encode the existing GRT2 envelope, including arbitrary binary payload bytes.
pub fn pack(header: &Value, payload: &[u8]) -> Result<Vec<u8>, WireError> {
    if !header.is_object() { return Err(WireError("Expected object")); }
    let header = serde_json::to_vec(header).map_err(|_| WireError("Invalid header"))?;
    if header.len() > MAX_HEADER { return Err(WireError("Invalid header")); }
    let capacity = 8usize.checked_add(header.len()).and_then(|n| n.checked_add(payload.len()))
        .ok_or(WireError("Oversized binary packet"))?;
    let mut bytes = Vec::with_capacity(capacity);
    bytes.extend_from_slice(MAGIC);
    bytes.extend_from_slice(&(header.len() as u32).to_le_bytes());
    bytes.extend_from_slice(&header);
    bytes.extend_from_slice(payload);
    Ok(bytes)
}

/// Each channel supplies its existing bound: commands are smaller than frames.
pub fn unpack(bytes: &[u8], maximum_packet: usize) -> Result<(Value, &[u8]), WireError> {
    if bytes.len() < 8 || bytes.len() > maximum_packet || &bytes[..4] != MAGIC {
        return Err(WireError("Invalid binary packet"));
    }
    let length = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
    if length > MAX_HEADER || length > bytes.len() - 8 { return Err(WireError("Invalid header")); }
    let header: Value = serde_json::from_slice(&bytes[8..8 + length])
        .map_err(|_| WireError("Invalid header"))?;
    if !header.is_object() { return Err(WireError("Expected object")); }
    Ok((header, &bytes[8 + length..]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn existing_envelope_and_binary_payload_are_preserved() {
        let header = json!({"session": 7, "kind": "stream", "revision": 9});
        let payload = b"\0\xff\x1b[31m";
        let bytes = pack(&header, payload).unwrap();
        let (decoded, data) = unpack(&bytes, MAX_COMMAND_PACKET).unwrap();
        assert_eq!(decoded, header);
        assert_eq!(data, payload);
        assert_eq!(&bytes[..4], b"GRT2");
    }
    #[test]
    fn malformed_and_over_budget_packets_are_rejected() {
        let valid = pack(&json!({}), b"data").unwrap();
        assert!(unpack(&valid, valid.len() - 1).is_err());
        for bytes in [b"".as_slice(), b"GRT2\xff\xff\xff\xff", b"GRT2\x02\0\0\0[]", b"BAD2\x02\0\0\0{}"] {
            assert!(unpack(bytes, MAX_COMMAND_PACKET).is_err());
        }
        assert!(pack(&json!([]), b"").is_err());
        assert!(pack(&json!({"large": "x".repeat(MAX_HEADER)}), b"").is_err());
    }
    #[test]
    fn ids_remain_numeric_on_the_wire() {
        assert_eq!(serde_json::to_value(SessionId(42)).unwrap(), json!(42));
        assert_eq!(serde_json::from_value::<TabId>(json!(7)).unwrap(), TabId(7));
    }
}
pub mod limits;
pub mod spawn;
pub mod terminal_scene;
pub mod terminal_theme;

#[cfg(test)]
mod chromium_video_header_tests {
    use super::*;
    #[test]
    fn chromium_dimensions_are_required_and_preserved() {
        let header = ChromiumVideoHeader {
            session: 7, format: "h264".into(), frame: 1, epoch: 2, sequence: 3,
            key: true, width: 640, height: 360, source_width: 1920, source_height: 1080,
        };
        let mut value = serde_json::to_value(&header).unwrap();
        assert_eq!(value["type"], "chromium");
        assert_eq!(serde_json::from_value::<ChromiumVideoHeader>(value.clone()).unwrap(), header);
        let mut obsolete = value.clone();
        obsolete["type"] = serde_json::json!("browser");
        assert!(serde_json::from_value::<ChromiumVideoHeader>(obsolete).is_err());
        value.as_object_mut().unwrap().remove("source_width");
        assert!(serde_json::from_value::<ChromiumVideoHeader>(value).is_err());
    }
}

pub mod graph;
