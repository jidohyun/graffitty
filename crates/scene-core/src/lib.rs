//! Engine-independent scene motion, projection, and effect configuration.
//!
//! All distances and angles retain the source scene's units. Rendering engines
//! convert their transforms to [`Pose`] at their own boundary.

pub mod adaptive_projection;
pub mod camera_motion;
pub mod color;
pub mod effects;
pub mod graph_geometry;
pub mod pose;
pub mod typing_camera;

pub use pose::Pose;

pub mod navigation;
pub mod pane_physics;
pub mod fling;
pub mod scroll;
pub mod touch;

// Re-export the shared math types so adapters cannot select a mismatched glam version.
pub use glam;
