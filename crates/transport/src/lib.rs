//! Local IPC, authenticated remote connections and optional chromium video wire
//! support. No terminal emulator, workspace state or UI framework is required.
#[cfg(feature = "chromium-video")]
pub use graffitty_chromium_video as chromium_video;
pub use graffitty_remote_auth as auth;
pub use graffitty_session_transport as ipc;
pub mod client;
pub mod controller;
pub mod file_transfer;
pub use client::{Authentication, ClientTransport, PendingCode, authenticate};
