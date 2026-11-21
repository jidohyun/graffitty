use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;

/// Called before Godot selects system DPI awareness and creates its first HWND.
#[cfg(windows)]
pub(super) fn enable_per_monitor_dpi() {
    use windows::Win32::UI::HiDpi::{
        DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
    };
    if !godot::classes::Engine::singleton().is_editor_hint() && godot::classes::ProjectSettings::singleton()
        .get_setting_with_override("display/window/dpi/allow_hidpi").to::<bool>()
    {
        let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
    }
}

#[cfg(windows)]
unsafe extern "C" {
    fn graffitty_window_round_corners(window: u64, small: bool);
    fn graffitty_watch_dpi(window: u64, receiver: i64) -> u32;
    fn graffitty_window_frame_attach(window: u64, receiver: i64, callback: extern "C" fn(i64, *const i32)) -> bool;
    fn graffitty_window_frame_detach(window: u64);
    fn graffitty_window_frame_update(
        window: u64,
        enabled: bool,
        passthrough: bool,
        title: *const i32,
        controls: *const i32,
        count: i32,
    );
    fn graffitty_window_frame_margins(window: u64, margins: *mut i32);
    fn graffitty_window_frame_move(window: u64, x: i32, y: i32) -> bool;
    fn graffitty_window_frame_resize(window: u64, width: i32, height: i32) -> bool;
}

#[cfg(windows)]
#[unsafe(no_mangle)]
extern "C" fn graffitty_dpi_changed(receiver: i64) {
    let Some(id) = godot::obj::InstanceId::try_from_i64(receiver) else { return; };
    if let Ok(mut window) = Gd::<godot::classes::Window>::try_from_instance_id(id) {
        window.call_deferred("emit_signal", &[StringName::from("dpi_changed").to_variant()]);
    }
}

// Called on the native window/Godot main thread. Only retain an instance ID:
// closing a window must neither keep its controller alive nor call a freed one.
#[cfg(windows)]
extern "C" fn caption_changed(receiver: i64, values: *const i32) {
    let Some(id) = godot::obj::InstanceId::try_from_i64(receiver) else { return; };
    let Ok(mut object) = Gd::<godot::classes::Object>::try_from_instance_id(id) else { return; };
    // The native adapter supplies exactly seventeen values for this call.
    let state = PackedInt32Array::from(unsafe { std::slice::from_raw_parts(values, 17) });
    object.call_deferred("_caption_changed", &[state.to_variant()]);
}

/// Native window frame operations that the Godot Window API does not expose.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct NativeWindowFrame {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for NativeWindowFrame {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl NativeWindowFrame {
    #[func]
    fn x11_has_composited_alpha(window_id: i32) -> bool {
        #[cfg(target_os = "linux")]
        { super::window_frame_x11::has_composited_alpha(window_id) }
        #[cfg(not(target_os = "linux"))]
        { let _ = window_id; false }
    }

    #[func]
    fn x11_is_tiled(window_id: i32) -> bool {
        #[cfg(target_os = "linux")]
        { super::window_frame_x11::is_tiled(window_id) }
        #[cfg(not(target_os = "linux"))]
        { let _ = window_id; false }
    }

    #[func]
    fn round_corners(window: i64, small: bool) {
        #[cfg(windows)]
        unsafe { graffitty_window_round_corners(window as u64, small) };
        #[cfg(not(windows))]
        let _ = (window, small);
    }

    /// Watch this HWND until Windows destroys it. Showing a hidden Godot
    /// window creates a new HWND, even when the Window node is reused.
    #[func]
    fn watch_dpi(window: i64, receiver: i64) -> u32 {
        #[cfg(windows)]
        { unsafe { graffitty_watch_dpi(window as u64, receiver) } }
        #[cfg(not(windows))]
        { let _ = (window, receiver); 0 }
    }

    #[func]
    fn fullscreen_content(&self, window: i64) {
        #[cfg(target_os = "macos")]
        unsafe {
            unsafe extern "C" { fn graffitty_window_fullscreen_content(window: u64); }
            graffitty_window_fullscreen_content(window as u64);
        }
        #[cfg(not(target_os = "macos"))]
        let _ = window;
    }

    #[func]
    fn resize_client(&self, window: i64, size: Vector2i) -> bool {
        #[cfg(windows)]
        { unsafe { graffitty_window_frame_resize(window as u64, size.x, size.y) } }
        #[cfg(not(windows))]
        { let _ = (window, size); false }
    }

    /// The foreground application grants activation to its owned chromium.
    #[func]
    fn allow_foreground(&self, process_id: i64) -> bool {
        #[cfg(windows)]
        {
            unsafe extern "system" { fn AllowSetForegroundWindow(process_id: u32) -> i32; }
            let Ok(pid) = u32::try_from(process_id) else { return false; };
            pid != 0 && unsafe { AllowSetForegroundWindow(pid) } != 0
        }
        #[cfg(not(windows))]
        { let _ = process_id; false }
    }

    #[func]
    fn attach(&self, window: i64, receiver: i64) -> bool {
        #[cfg(windows)]
        {
            unsafe { graffitty_window_frame_attach(window as u64, receiver, caption_changed) }
        }
        #[cfg(not(windows))]
        {
            let _ = (window, receiver);
            false
        }
    }

    #[func]
    fn detach(&self, window: i64) {
        #[cfg(windows)]
        unsafe {
            graffitty_window_frame_detach(window as u64)
        };
        #[cfg(not(windows))]
        let _ = window;
    }

    #[func]
    fn update(
        &self,
        window: i64,
        enabled: bool,
        passthrough: bool,
        title: Rect2i,
        controls: Array<Rect2i>,
    ) {
        #[cfg(windows)]
        {
            let rect = |r: Rect2i| [r.position.x, r.position.y, r.end().x, r.end().y];
            let title = rect(title);
            let controls: Vec<i32> = controls.iter_shared().flat_map(rect).collect();
            unsafe {
                graffitty_window_frame_update(
                    window as u64,
                    enabled,
                    passthrough,
                    title.as_ptr(),
                    controls.as_ptr(),
                    (controls.len() / 4) as i32,
                )
            };
        }
        #[cfg(not(windows))]
        let _ = (window, enabled, passthrough, title, controls);
    }

    #[func]
    fn margins(&self, window: i64) -> Vector3i {
        #[cfg(windows)]
        {
            let mut margins = [0; 3];
            unsafe { graffitty_window_frame_margins(window as u64, margins.as_mut_ptr()) };
            Vector3i::new(margins[0], margins[1], margins[2])
        }
        #[cfg(not(windows))]
        {
            let _ = window;
            Vector3i::ZERO
        }
    }

    #[func]
    fn move_by(&self, window: i64, position: Vector2i) -> bool {
        #[cfg(windows)]
        {
            unsafe { graffitty_window_frame_move(window as u64, position.x, position.y) }
        }
        #[cfg(not(windows))]
        {
            let _ = (window, position);
            false
        }
    }
}
