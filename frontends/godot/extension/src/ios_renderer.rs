//! Renderer selection for iOS GPUs that Godot's Metal driver rejects.
//!
//! Godot's Metal renderers require an Apple4-family GPU (A11 and newer).
//!
//! On older GPUs such as the A9X, Godot 4.7's iOS display server fails after
//! creating the Metal context and never reaches its OpenGL fallback, so the
//! app aborts.
//!
//! Core extensions are initialized before Main reads the rendering method, so
//! choose the Compatibility (OpenGL ES 3) renderer here for those devices
//! only.
use godot::classes::ProjectSettings;
use godot::prelude::*;

const RENDERING_METHOD: [&str; 2] =
    ["rendering/renderer/rendering_method", "rendering/renderer/rendering_method.mobile"];

unsafe extern "C" {
    fn gft_ios_metal_renderer_supported() -> i32;
}

pub(crate) fn select() {
    // SAFETY: no arguments; the adapter only queries the default Metal device.
    if unsafe { gft_ios_metal_renderer_supported() } != 0 {
        return;
    }
    let mut settings = ProjectSettings::singleton();
    for key in RENDERING_METHOD {
        settings.set_setting(key, &"gl_compatibility".to_variant());
    }
    godot_print!("Graffitty: this GPU predates Apple4; using the Compatibility renderer.");
}
