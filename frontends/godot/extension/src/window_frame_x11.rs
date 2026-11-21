//! X11 window visuals, frame state and interactive move/resize.
use godot::classes::{DisplayServer, RefCounted, Window, display_server::HandleType};
use godot::prelude::*;
use std::ffi::{CStr, CString, c_long, c_ulong};
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use x11_dl::xlib::{self, Xlib};
use x11_dl::xrender::{PictTypeDirect, Xrender};

struct Client {
    x: &'static Xlib,
    display: *mut xlib::Display,
    window: xlib::Window,
}

impl Client {
    fn for_window(id: i32) -> Option<Self> {
        static XLIB: OnceLock<Option<Xlib>> = OnceLock::new();
        let x = XLIB.get_or_init(|| Xlib::open().ok()).as_ref()?;
        let server = DisplayServer::singleton();
        if id < 0 || server.get_name() != "X11" {
            return None;
        }
        let handle = |kind| {
            server
                .window_get_native_handle_ex(kind)
                .window_id(id)
                .done()
        };
        let display = handle(HandleType::DISPLAY_HANDLE) as *mut xlib::Display;
        let window = handle(HandleType::WINDOW_HANDLE) as xlib::Window;
        (!display.is_null() && window != 0).then_some(Self { x, display, window })
    }

    fn atom(&self, name: &CStr) -> xlib::Atom {
        unsafe { (self.x.XInternAtom)(self.display, name.as_ptr(), xlib::False) }
    }

    fn property(&self, window: xlib::Window, name: &CStr, kind: xlib::Atom) -> Vec<c_ulong> {
        let (mut actual, mut format, mut n, mut rest) = (0, 0, 0, 0);
        let mut data = std::ptr::null_mut();
        let status = unsafe {
            (self.x.XGetWindowProperty)(
                self.display,
                window,
                self.atom(name),
                0,
                4096,
                xlib::False,
                kind,
                &mut actual,
                &mut format,
                &mut n,
                &mut rest,
                &mut data,
            )
        };
        if data.is_null() {
            return Vec::new();
        }
        // Xlib expands protocol format-32 values into native longs.
        let values = if status == 0 && actual == kind && format == 32 {
            unsafe { std::slice::from_raw_parts(data.cast::<c_ulong>(), n as usize).to_vec() }
        } else {
            Vec::new()
        };
        unsafe { (self.x.XFree)(data.cast()) };
        values
    }

    fn pointer(&self) -> Option<(xlib::Window, Vector2i, bool)> {
        let (mut root, mut child, mut x, mut y, mut wx, mut wy, mut mask) = Default::default();
        let same_screen = unsafe {
            (self.x.XQueryPointer)(
                self.display,
                self.window,
                &mut root,
                &mut child,
                &mut x,
                &mut y,
                &mut wx,
                &mut wy,
                &mut mask,
            )
        };
        (same_screen != 0).then_some((root, Vector2i::new(x, y), mask & xlib::Button1Mask != 0))
    }

    fn ungrab(&self) {
        unsafe {
            (self.x.XUngrabPointer)(self.display, xlib::CurrentTime);
            (self.x.XFlush)(self.display);
        }
    }

    fn send_request(&self, root: xlib::Window, point: Vector2i, direction: i32) {
        let data: [c_long; 5] = [point.x.into(), point.y.into(), direction.into(), 1, 1];
        let mut event = xlib::XEvent {
            client_message: xlib::XClientMessageEvent {
                type_: xlib::ClientMessage,
                serial: 0,
                send_event: 0,
                display: self.display,
                window: self.window,
                message_type: self.atom(c"_NET_WM_MOVERESIZE"),
                format: 32,
                data: data.into(),
            },
        };
        unsafe {
            (self.x.XSendEvent)(
                self.display,
                root,
                xlib::False,
                xlib::SubstructureRedirectMask | xlib::SubstructureNotifyMask,
                &mut event,
            );
            (self.x.XFlush)(self.display);
        }
    }

    fn grab(&self) -> bool {
        unsafe {
            (self.x.XGrabPointer)(
                self.display,
                self.window,
                xlib::True,
                (xlib::ButtonReleaseMask | xlib::PointerMotionMask) as u32,
                xlib::GrabModeAsync,
                xlib::GrabModeAsync,
                0,
                0,
                xlib::CurrentTime,
            ) == xlib::GrabSuccess
        }
    }
}

pub(super) fn has_composited_alpha(id: i32) -> bool {
    let Some(client) = Client::for_window(id) else {
        return false;
    };
    static XRENDER: OnceLock<Option<Xrender>> = OnceLock::new();
    let Some(render) = XRENDER.get_or_init(|| Xrender::open().ok()) else {
        return false;
    };
    // NVIDIA's X11 Vulkan WSI can advertise OPAQUE while Mutter still
    // composites the alpha channel of the window's ARGB visual.
    unsafe {
        let mut attrs = std::mem::MaybeUninit::uninit();
        if (client.x.XGetWindowAttributes)(client.display, client.window, attrs.as_mut_ptr()) == 0 {
            return false;
        }
        let attrs = attrs.assume_init();
        let format = (render.XRenderFindVisualFormat)(client.display, attrs.visual);
        if attrs.depth != 32
            || format.is_null()
            || (*format).type_ != PictTypeDirect
            || (*format).direct.alphaMask == 0
        {
            return false;
        }
        let screen = (client.x.XScreenNumberOfScreen)(attrs.screen);
        let name = CString::new(format!("_NET_WM_CM_S{screen}")).unwrap();
        let selection = (client.x.XInternAtom)(client.display, name.as_ptr(), xlib::True);
        selection != 0 && (client.x.XGetSelectionOwner)(client.display, selection) != 0
    }
}

pub(super) fn is_tiled(id: i32) -> bool {
    let Some(client) = Client::for_window(id) else {
        return false;
    };
    if let Some(flags) = client
        .property(client.window, c"_GTK_EDGE_CONSTRAINTS", xlib::XA_CARDINAL)
        .first()
    {
        // Each edge has a tiled bit followed by a resizable bit.
        return flags & 0x55 != 0;
    }
    let states = client.property(client.window, c"_NET_WM_STATE", xlib::XA_ATOM);
    states.contains(&client.atom(c"_NET_WM_STATE_MAXIMIZED_VERT"))
        || states.contains(&client.atom(c"_NET_WM_STATE_MAXIMIZED_HORZ"))
}

// EWMH numbers the edges clockwise. Godot numbers them in reading order.
const DIRECTIONS: [i32; 8] = [0, 1, 2, 7, 3, 6, 5, 4];
const MOVE: i32 = 8;
const CANCEL: i32 = 11;

#[derive(Default)]
enum Phase {
    #[default]
    Armed,
    WaitingForWm(Instant),
    Released(Instant, Vector2i),
    Manual,
}

#[derive(GodotClass)]
#[class(init, base=RefCounted)]
struct X11FrameGesture {
    base: Base<RefCounted>,
    phase: Phase,
    id: i32,
    press: Vector2i,
    initial: Rect2i,
    direction: i32,
    advertised: bool,
}

#[godot_api]
impl X11FrameGesture {
    #[func]
    fn begin(&mut self, window: Gd<Window>, local_press: Vector2i, edge: i32) -> bool {
        self.cancel();
        let Some(client) = Client::for_window(window.get_window_id()) else {
            return false;
        };
        let Some((root, _, true)) = client.pointer() else {
            return false;
        };
        self.id = window.get_window_id();
        self.direction = if edge == -1 {
            MOVE
        } else if let Some(&dir) = DIRECTIONS.get(edge as usize) {
            dir
        } else {
            return false;
        };
        self.initial = Rect2i::new(window.get_position(), window.get_size());
        self.press = self.initial.position + local_press;
        self.advertised = client
            .property(root, c"_NET_SUPPORTED", xlib::XA_ATOM)
            .contains(&client.atom(c"_NET_WM_MOVERESIZE"));
        self.update(window)
    }

    #[func]
    fn update(&mut self, window: Gd<Window>) -> bool {
        if !window.is_visible() || self.id != window.get_window_id() {
            self.cancel();
            return false;
        }
        let Some(client) = Client::for_window(self.id) else {
            return false;
        };
        let Some((root, point, held)) = client.pointer() else {
            self.cancel();
            return false;
        };
        let mut delta = point - self.press;
        match self.phase {
            Phase::Armed => {
                // Openbox consumes the second click if a stationary first click is
                // handed to the WM. Hold the implicit grab until motion starts.
                if self.direction == MOVE && delta.x.abs().max(delta.y.abs()) < 3 {
                    return held;
                }
                if held && self.advertised {
                    client.ungrab();
                    client.send_request(root, self.press, self.direction);
                    self.phase = Phase::WaitingForWm(Instant::now());
                    return true;
                }
                if held {
                    if !client.grab() {
                        return false;
                    }
                    self.phase = Phase::Manual;
                }
            }
            Phase::WaitingForWm(sent) => {
                if window.get_position() != self.initial.position
                    || window.get_size() != self.initial.size
                {
                    return false; // The WM has taken ownership.
                }
                if !held {
                    client.send_request(root, point, CANCEL);
                    self.phase = Phase::Released(Instant::now(), delta);
                    return delta != Vector2i::ZERO;
                }
                if delta == Vector2i::ZERO || sent.elapsed() < Duration::from_millis(150) {
                    return true;
                }
                // An outline-only WM can own the grab without configuring the
                // window until release. Never compete with its interactive loop.
                if !client.grab() {
                    return false;
                }
                client.send_request(root, point, CANCEL);
                self.phase = Phase::Manual;
            }
            Phase::Released(at, end_delta) => {
                // The WM may configure only on release. Give that event time to
                // arrive before completing a short drag the WM ignored.
                if held
                    || window.get_position() != self.initial.position
                    || window.get_size() != self.initial.size
                {
                    return false;
                }
                if at.elapsed() < Duration::from_millis(150) {
                    return true;
                }
                delta = end_delta;
            }
            Phase::Manual => {}
        }

        let rect = drag_bounds(
            self.initial,
            delta,
            self.direction,
            window.get_min_size(),
            window.get_max_size(),
        );
        unsafe {
            (client.x.XMoveResizeWindow)(
                client.display,
                client.window,
                rect.position.x,
                rect.position.y,
                rect.size.x as u32,
                rect.size.y as u32,
            );
            (client.x.XFlush)(client.display);
        }
        if !held {
            self.cancel();
        }
        held
    }

    #[func]
    fn cancel(&mut self) {
        if matches!(self.phase, Phase::Manual) {
            // X automatically releases grabs when a window is unmapped.
            // The display connection is shared with the still-mapped main window.
            if let Some(client) = Client::for_window(0) {
                client.ungrab();
            }
        }
        self.phase = Phase::Armed;
    }
}

fn drag_bounds(initial: Rect2i, delta: Vector2i, dir: i32, min: Vector2i, max: Vector2i) -> Rect2i {
    if dir == MOVE {
        return Rect2i::new(initial.position + delta, initial.size);
    }
    let mut rect = initial;
    let dim = |size: i32, min: i32, max: i32| {
        size.clamp(min.max(1), if max > 0 { max.max(min) } else { i32::MAX })
    };
    if matches!(dir, 0 | 6 | 7) {
        rect.size.x = dim(initial.size.x - delta.x, min.x, max.x);
        rect.position.x += initial.size.x - rect.size.x;
    } else if matches!(dir, 2..=4) {
        rect.size.x = dim(initial.size.x + delta.x, min.x, max.x);
    }
    if matches!(dir, 0..=2) {
        rect.size.y = dim(initial.size.y - delta.y, min.y, max.y);
        rect.position.y += initial.size.y - rect.size.y;
    } else if matches!(dir, 4..=6) {
        rect.size.y = dim(initial.size.y + delta.y, min.y, max.y);
    }
    rect
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manual_resize_anchors_the_opposite_edge_at_the_size_limit() {
        let initial = Rect2i::from_components(10, 20, 300, 200);
        let min = Vector2i::new(200, 100);
        let max = Vector2i::new(320, 240);
        for (edge, expected) in [
            (0, (110, 120, 200, 100)),
            (1, (10, 120, 300, 100)),
            (2, (10, 120, 320, 100)),
            (7, (110, 20, 200, 200)),
            (3, (10, 20, 320, 200)),
            (6, (110, 20, 200, 240)),
            (5, (10, 20, 300, 240)),
            (4, (10, 20, 320, 240)),
            (MOVE, (210, 220, 300, 200)),
        ] {
            let (x, y, w, h) = expected;
            assert_eq!(
                drag_bounds(initial, Vector2i::new(200, 200), edge, min, max),
                Rect2i::from_components(x, y, w, h)
            );
        }
    }
}
