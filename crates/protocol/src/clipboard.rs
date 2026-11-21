//! Ephemeral, owner-routed clipboard operations, separate from scene replication.
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Operation {
    Rich { packet: String },
    ReadText { selector: u8, bel: bool },
    WriteText { selector: u8, encoded: String },
}
impl Operation {
    pub fn payload_bytes(&self) -> usize {
        match self {
            Self::Rich { packet } => packet.len(),
            Self::WriteText { encoded, .. } => encoded.len(),
            Self::ReadText { .. } => 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clipboard_operation_rejects_incomplete_and_obsolete_messages() {
        for invalid in [
            r#"{"packet":"type=read"}"#,
            r#"{"kind":"read_text","selector":99}"#,
            r#"{"kind":"read_text","selector":99,"bel":true,"text":"unexpected"}"#,
            r#"{"kind":"write_text","selector":999,"encoded":""}"#,
        ] { assert!(serde_json::from_str::<Operation>(invalid).is_err()); }
        assert!(matches!(serde_json::from_str::<Operation>(r#"{"kind":"read_text","selector":99,"bel":true}"#).unwrap(), Operation::ReadText { selector: b'c', bel: true }));
    }
}
