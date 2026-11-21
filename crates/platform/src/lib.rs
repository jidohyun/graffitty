//! Operating-system adapters shared by native frontends.
//! Permission policy and headless/native selection stay with the caller.
#[cfg(feature = "clipboard")]
pub mod clipboard;
pub mod install;
pub mod spawn;
#[cfg(all(feature = "clipboard", target_os = "macos"))]
pub mod clipboard_macos;
#[cfg(feature = "clipboard")]
use graffitty_terminal_core::clipboard_core;
pub mod port_owner;
pub mod process_cwd;
pub mod process_env;
