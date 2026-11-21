//! Frontend-independent `client.toml` configuration.
//!
//! Frontends consume resolved bindings rather than maintaining independent menu
//! accelerators, prefix maps, or command-line names.
pub mod bindings;
pub mod config;
pub mod mods;
pub mod remembered;
pub mod rendering;
