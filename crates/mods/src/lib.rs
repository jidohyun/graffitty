//! Load JavaScript mods for Graffitty. The mod model comes from herdr-app
//! (Apache-2.0).
//!
//! - A mod is a directory with a `main.js` that exports a `View`.
//! - `render()` describes native UI with builders forked from gpui-kit.
//! - Tracked reads refresh a view only when data it read changes.
//! - Button callbacks call `run(action)`.
//!
//! Rust uses taffy to lay out the result as a [`layout::Frame`]. Godot
//! paints its draw list with native primitives and uses its hit regions for
//! input. The mod script runs in the Rust host.
pub mod engine;
pub mod host;
pub mod layout;
pub mod spec;
pub mod style;
pub mod value;

pub use engine::{CopyId, Cursor, Mods, Options, PointerEvent, PointerOutcome};
pub use host::Request;
pub use layout::{Draw, FontSpec, Frame, Hit, Interaction, MonospaceMeasure, Rect, ScrollInfo, TextMeasure};
pub use style::TextAlign;
pub use value::Color;

/// The TypeScript declarations for the `graffitty` module, written beside the
/// user's mods so editors and agents complete against the real API.
pub const DECLARATIONS: &str = include_str!("../js/graffitty.d.ts");
