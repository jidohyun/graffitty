//! One bounded upload format for CLI, desktop and mobile terminal attachments.
use serde::{Deserialize, Serialize};

pub const MAX_BYTES: usize = 32 * 1024 * 1024;
// Base64 plus the RPC envelope must fit both MAX_HEADER and MAX_COMMAND_PACKET.
pub const CHUNK_BYTES: usize = 24 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Chunk {
    pub id: String,
    pub name: String,
    pub size: usize,
    pub offset: usize,
    pub data: String,
    /// Paste the completed, quoted server path once, without pressing Enter.
    pub paste: bool,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub id: String,
    pub pane: String,
    pub received: usize,
    pub path: Option<String>,
}
