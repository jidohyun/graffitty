use godot::classes::{
    DisplayServer, Input, InputEventMagnifyGesture, InputEventPanGesture, display_server::HandleType,
};
use godot::prelude::*;

unsafe extern "C" {
    pub(crate) fn graffitty_install_trackpad();
}

/// The Godot window showing an NSWindow, and the map from its content view's
/// points to that window's pixels.
fn godot_window(
    window: *mut std::ffi::c_void,
    width: f64,
    height: f64,
) -> Option<(i32, impl Fn(f64, f64) -> Vector2)> {
    let ds = DisplayServer::singleton();
    let id = ds.get_window_list().as_slice().iter().copied().find(|id| {
        ds.window_get_native_handle_ex(HandleType::WINDOW_HANDLE)
            .window_id(*id)
            .done()
            == window as i64
    })?;
    let size = ds.window_get_size_ex().window_id(id).done();
    Some((id, move |x: f64, y: f64| {
        Vector2::new(
            (x * size.x as f64 / width) as f32,
            (y * size.y as f64 / height) as f32,
        )
    }))
}

// AppKit and Godot input dispatch both run on the application's main thread.
#[unsafe(no_mangle)]
extern "C" fn graffitty_trackpad_event(
    window: *mut std::ffi::c_void,
    width: f64,
    height: f64,
    x: f64,
    y: f64,
    px: f64,
    py: f64,
    cx: f64,
    cy: f64,
    factor: f64,
) {
    let Some((id, point)) = godot_window(window, width, height) else {
        return;
    };
    let mut event = InputEventMagnifyGesture::new_gd();
    event.set_window_id(i64::from(id));
    event.set_position(point(x, y));
    event.set_factor(factor as f32);
    event.set_meta("pinch_pan", &point(cx - px, cy - py).to_variant());
    event.set_meta("pinch_previous", &point(px, py).to_variant());
    event.set_meta("pinch_center", &point(cx, cy).to_variant());
    Input::singleton().parse_input_event(&event);
}

/// NSEventPhase, as named in Chromium scroll input.
fn phase_name(phase: u64) -> Option<&'static str> {
    match phase {
        1 => Some("began"),
        2 | 4 => Some("changed"),
        8 => Some("ended"),
        16 => Some("cancelled"),
        32 => Some("may_begin"),
        _ => None,
    }
}

/// Godot's own pan gesture plus the AppKit phases it drops.
#[unsafe(no_mangle)]
extern "C" fn graffitty_pan_event(
    window: *mut std::ffi::c_void,
    width: f64,
    height: f64,
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
    phase: u64,
    momentum: u64,
    flags: u64,
    time: f64,
) -> bool {
    let Some((id, point)) = godot_window(window, width, height) else {
        return false;
    };
    let mut event = InputEventPanGesture::new_gd();
    event.set_window_id(i64::from(id));
    event.set_position(point(x, y));
    event.set_delta(Vector2::new(dx as f32, dy as f32));
    // NSEventModifierFlags, mapped as Godot's macOS backend does.
    event.set_shift_pressed(flags & (1 << 17) != 0);
    event.set_ctrl_pressed(flags & (1 << 18) != 0);
    event.set_alt_pressed(flags & (1 << 19) != 0);
    event.set_meta_pressed(flags & (1 << 20) != 0);
    if let Some(name) = phase_name(phase) {
        event.set_meta("scroll_phase", &name.to_variant());
    }
    if let Some(name) = phase_name(momentum) {
        event.set_meta("momentum_phase", &name.to_variant());
    }
    // NSEvent time, seconds since boot. Godot dispatches input once per frame;
    // only the original spacing gives Chromium a true release velocity.
    event.set_meta("event_time", &time.to_variant());
    Input::singleton().parse_input_event(&event);
    true
}
