use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;

#[cfg(any(target_os = "macos", target_os = "linux", windows))]
unsafe extern "C" {
    fn graffitty_desktop_blur(window: u64, enabled: bool, material: i32, display: u64) -> bool;
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct DesktopBlur {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for DesktopBlur {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl DesktopBlur {
    #[func]
    fn apply(
        &self,
        window: i64,
        enabled: bool,
        material: i32,
        display: i64,
        backend: GString,
    ) -> bool {
        #[cfg(any(target_os = "macos", target_os = "linux", windows))]
        {
            let backend = backend.to_string();
            let supported = if cfg!(target_os = "macos") {
                backend == "macOS"
            } else if cfg!(windows) {
                backend == "Windows"
            } else {
                backend == "X11"
            };
            supported
                && window != 0
                && unsafe { graffitty_desktop_blur(window as u64, enabled, material, display as u64) }
        }
        #[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
        {
            let _ = (window, enabled, material, display, backend);
            false
        }
    }
}
