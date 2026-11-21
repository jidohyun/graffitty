//! Custom nodes use the same authenticated JSON API as `gft`.
//! No UI, provider integration, or graph execution lives in this crate.
#![doc = include_str!("../README.md")]
mod claim;
mod client;
mod models;
mod node;
mod session;

pub use claim::{local_server, local_server_descriptor, tmux_context};
pub use client::{Client, MAX_MESSAGE, MAX_REQUEST, Result, Rpc, read_message, response};
pub use models::{
    Checkpoint, Event, Icon, InputPort, LineStyle, Manifest, Output, OutputPort, PortMode,
    SessionReference,
};
pub use node::{IntoOutputs, Node};
pub use session::{Restore, Session, restored_state};
