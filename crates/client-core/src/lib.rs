//! Shared session client and local terminal mirrors, without a UI framework.
//!
//! The session server owns PTYs and authoritative workspace state. This crate
//! connects to that owner, correlates requests, and maintains replayable VT
//! mirrors. Native clipboard, fonts, textures and window actions stay in adapters.
pub mod client;
pub mod connection_worker;
pub mod effects;
pub mod graph_flow;
pub mod graph_inspector;
pub mod graph_stop;
pub mod images;
pub mod input;
pub mod localization;
pub mod command_line;
pub mod metrics;
pub mod mirror;
pub mod scene;
mod scene_mailbox;
pub mod scene_worker;
pub mod server;
pub mod tools;
pub mod transport;
pub mod wakeup;

pub mod font_cache;
pub mod remote_state;

pub mod graph_state;
pub mod agent_attention;
pub mod agents;
pub mod agents_tree;
pub mod pane_resources;
pub use graffitty_transport::controller;

pub use graffitty_transport::file_transfer;
pub mod clipboard_paste;
