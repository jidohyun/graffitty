//! Presentation replication: text transactions refer to immutable image assets.
//! Pixels never belong to a terminal checkpoint. Asset delivery may complete
//! later without delaying publication of text or placement removals.
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, Serialize, Deserialize)]
pub struct AssetKey(pub String);

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Image {
    pub id: u32,
    pub asset: AssetKey,
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Placement {
    pub image: u32,
    pub id: u32,
    pub z: i32,
    pub virtual_: bool,
    /// Retained screen coordinates, including history. Virtual placements use
    /// the Unicode cells in the text replica instead of this anchor.
    pub column: u16,
    pub row: u32,
    pub columns: u32,
    pub rows: u32,
    pub offset: [u32; 2],
    pub source: [u32; 4],
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Graphics {
    pub images: Vec<Image>,
    pub placements: Vec<Placement>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Transaction {
    pub revision: u64,
    pub base: u64,
    pub snapshot: bool,
    /// An explicit attach/resync may discard an unfinished staging buffer.
    /// The visible presentation is still retained until the new commit.
    pub replace: bool,
    pub offset: usize,
    pub total: usize,
    /// JSON placement metadata occupies the tail of the binary transaction,
    /// so even large placement sets never exceed the envelope header limit.
    pub graphics_bytes: usize,
    pub commit: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AssetChunk {
    pub asset: AssetKey,
    pub width: u32,
    pub height: u32,
    /// png or rgba; no base64 and no VT escapes.
    pub format: String,
    pub offset: usize,
    pub total: usize,
}

#[cfg(test)]
mod tests {
    use super::Transaction;
    use serde_json::json;

    #[test]
    fn transaction_requires_current_metadata_shape() {
        let current = json!({"revision":1,"base":0,"snapshot":true,"replace":true,
            "offset":0,"total":0,"graphics_bytes":0,"commit":true});
        assert!(serde_json::from_value::<Transaction>(current.clone()).is_ok());
        for field in ["replace", "graphics_bytes"] {
            let mut omitted = current.clone();
            omitted.as_object_mut().unwrap().remove(field);
            assert!(serde_json::from_value::<Transaction>(omitted).is_err());
        }
        let mut inline = current;
        inline["graphics"] = json!({"images":[],"placements":[]});
        assert!(serde_json::from_value::<Transaction>(inline).is_err());
    }
}
