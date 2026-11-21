//! Touchpad scroll phases on Wayland.
//!
//! Godot turns `wl_pointer.axis` into pan gestures but drops `axis_source`
//! and `axis_stop`, which tell a finger from a wheel and say when the fingers
//! lift. Chromium's rubber band needs both, so a second `wl_pointer` on
//! Godot's own connection listens for them through a private event queue.
//! Godot's Wayland thread keeps reading the socket; this only dispatches what
//! that read queued here, on the main thread.
use godot::classes::{DisplayServer, display_server::HandleType};
use godot::obj::Singleton;
use std::cell::RefCell;
use std::ffi::{CStr, c_char, c_int, c_void};

const WL_POINTER_AXIS_VERTICAL_SCROLL: u32 = 0;
const WL_POINTER_AXIS_SOURCE_FINGER: u32 = 1;
const WL_SEAT_CAPABILITY_POINTER: u32 = 1;
/// The first version with `frame`, `axis_source` and `axis_stop`.
const POINTER_VERSION: u32 = 5;
const WL_DISPLAY_GET_REGISTRY: u32 = 1;
const WL_REGISTRY_BIND: u32 = 0;
const WL_SEAT_GET_POINTER: u32 = 0;
/// `set_cursor` is request 0.
const WL_POINTER_RELEASE: u32 = 1;
const RTLD_NOW: c_int = 2;

unsafe extern "C" {
    fn dlopen(filename: *const c_char, flags: c_int) -> *mut c_void;
    fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
}

#[repr(C)]
#[derive(Clone, Copy)]
union Argument {
    uint: u32,
    string: *const c_char,
    object: *mut c_void,
}

/// The parts of libwayland-client this needs, from the copy Godot loaded.
struct Library {
    create_queue: unsafe extern "C" fn(*mut c_void) -> *mut c_void,
    create_wrapper: unsafe extern "C" fn(*mut c_void) -> *mut c_void,
    wrapper_destroy: unsafe extern "C" fn(*mut c_void),
    set_queue: unsafe extern "C" fn(*mut c_void, *mut c_void),
    marshal_constructor:
        unsafe extern "C" fn(*mut c_void, u32, *mut Argument, *const c_void, u32) -> *mut c_void,
    marshal: unsafe extern "C" fn(*mut c_void, u32, *mut Argument),
    destroy: unsafe extern "C" fn(*mut c_void),
    add_listener: unsafe extern "C" fn(*mut c_void, *const c_void, *mut c_void) -> c_int,
    dispatch_pending: unsafe extern "C" fn(*mut c_void, *mut c_void) -> c_int,
    flush: unsafe extern "C" fn(*mut c_void) -> c_int,
    registry_interface: *const c_void,
    seat_interface: *const c_void,
    pointer_interface: *const c_void,
}

impl Library {
    fn load() -> Option<Self> {
        unsafe {
            let handle = dlopen(c"libwayland-client.so.0".as_ptr(), RTLD_NOW);
            if handle.is_null() {
                return None;
            }
            let symbol = |name: &CStr| {
                let address = dlsym(handle, name.as_ptr());
                (!address.is_null()).then_some(address)
            };
            Some(Self {
                create_queue: std::mem::transmute(symbol(c"wl_display_create_queue")?),
                create_wrapper: std::mem::transmute(symbol(c"wl_proxy_create_wrapper")?),
                wrapper_destroy: std::mem::transmute(symbol(c"wl_proxy_wrapper_destroy")?),
                set_queue: std::mem::transmute(symbol(c"wl_proxy_set_queue")?),
                marshal_constructor: std::mem::transmute(symbol(c"wl_proxy_marshal_array_constructor_versioned")?),
                marshal: std::mem::transmute(symbol(c"wl_proxy_marshal_array")?),
                destroy: std::mem::transmute(symbol(c"wl_proxy_destroy")?),
                add_listener: std::mem::transmute(symbol(c"wl_proxy_add_listener")?),
                dispatch_pending: std::mem::transmute(symbol(c"wl_display_dispatch_queue_pending")?),
                flush: std::mem::transmute(symbol(c"wl_display_flush")?),
                registry_interface: symbol(c"wl_registry_interface")?,
                seat_interface: symbol(c"wl_seat_interface")?,
                pointer_interface: symbol(c"wl_pointer_interface")?,
            })
        }
    }
}

/// What the listeners share. Boxed so its address outlives every proxy.
struct Tracker {
    library: Library,
    display: *mut c_void,
    queue: *mut c_void,
    registry: *mut c_void,
    seat: *mut c_void,
    pointer: *mut c_void,
    /// This frame so far.
    source: Option<u32>,
    moved: bool,
    stopped: bool,
    /// The finger scroll under way, and how many there have been.
    active: bool,
    serial: u64,
}

#[repr(C)]
struct RegistryListener {
    global: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, *const c_char, u32),
    global_remove: unsafe extern "C" fn(*mut c_void, *mut c_void, u32),
}

#[repr(C)]
struct SeatListener {
    capabilities: unsafe extern "C" fn(*mut c_void, *mut c_void, u32),
    name: unsafe extern "C" fn(*mut c_void, *mut c_void, *const c_char),
}

#[repr(C)]
struct PointerListener {
    enter: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, *mut c_void, i32, i32),
    leave: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, *mut c_void),
    motion: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, i32, i32),
    button: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, u32, u32, u32),
    axis: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, u32, i32),
    frame: unsafe extern "C" fn(*mut c_void, *mut c_void),
    axis_source: unsafe extern "C" fn(*mut c_void, *mut c_void, u32),
    axis_stop: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, u32),
    axis_discrete: unsafe extern "C" fn(*mut c_void, *mut c_void, u32, i32),
}

static REGISTRY_LISTENER: RegistryListener = RegistryListener { global, global_remove };
static SEAT_LISTENER: SeatListener = SeatListener { capabilities, name: seat_name };
static POINTER_LISTENER: PointerListener = PointerListener {
    enter,
    leave,
    motion,
    button,
    axis,
    frame,
    axis_source,
    axis_stop,
    axis_discrete,
};

unsafe extern "C" fn global(data: *mut c_void, registry: *mut c_void, name: u32, interface: *const c_char, version: u32) {
    let tracker = unsafe { &mut *data.cast::<Tracker>() };
    // One seat is enough: a second one's pointer would only repeat the first.
    if !tracker.seat.is_null()
        || unsafe { CStr::from_ptr(interface) } != c"wl_seat"
        || version < POINTER_VERSION
    {
        return;
    }
    let mut arguments = [
        Argument { uint: name },
        Argument { string: c"wl_seat".as_ptr() },
        Argument { uint: POINTER_VERSION },
        Argument { object: std::ptr::null_mut() },
    ];
    unsafe {
        tracker.seat = (tracker.library.marshal_constructor)(
            registry,
            WL_REGISTRY_BIND,
            arguments.as_mut_ptr(),
            tracker.library.seat_interface,
            POINTER_VERSION,
        );
        if !tracker.seat.is_null() {
            (tracker.library.add_listener)(tracker.seat, (&raw const SEAT_LISTENER).cast(), data);
        }
    }
}

unsafe extern "C" fn global_remove(_: *mut c_void, _: *mut c_void, _: u32) {}

unsafe extern "C" fn capabilities(data: *mut c_void, seat: *mut c_void, capabilities: u32) {
    let tracker = unsafe { &mut *data.cast::<Tracker>() };
    if capabilities & WL_SEAT_CAPABILITY_POINTER == 0 {
        // The last pointing device went away. Its wl_pointer reports nothing
        // more, even when a device comes back: let go of it so the next
        // capability change asks for a new one.
        if !tracker.pointer.is_null() {
            unsafe {
                (tracker.library.marshal)(tracker.pointer, WL_POINTER_RELEASE, std::ptr::null_mut());
                (tracker.library.destroy)(tracker.pointer);
            }
            tracker.pointer = std::ptr::null_mut();
            tracker.active = false;
            (tracker.source, tracker.moved, tracker.stopped) = (None, false, false);
        }
        return;
    }
    if !tracker.pointer.is_null() {
        return;
    }
    let mut arguments = [Argument { object: std::ptr::null_mut() }];
    unsafe {
        tracker.pointer = (tracker.library.marshal_constructor)(
            seat,
            WL_SEAT_GET_POINTER,
            arguments.as_mut_ptr(),
            tracker.library.pointer_interface,
            POINTER_VERSION,
        );
        if !tracker.pointer.is_null() {
            (tracker.library.add_listener)(tracker.pointer, (&raw const POINTER_LISTENER).cast(), data);
        }
    }
}

unsafe extern "C" fn seat_name(_: *mut c_void, _: *mut c_void, _: *const c_char) {}
unsafe extern "C" fn enter(_: *mut c_void, _: *mut c_void, _: u32, _: *mut c_void, _: i32, _: i32) {}
unsafe extern "C" fn motion(_: *mut c_void, _: *mut c_void, _: u32, _: i32, _: i32) {}
unsafe extern "C" fn button(_: *mut c_void, _: *mut c_void, _: u32, _: u32, _: u32, _: u32) {}
unsafe extern "C" fn axis_discrete(_: *mut c_void, _: *mut c_void, _: u32, _: i32) {}

unsafe extern "C" fn leave(data: *mut c_void, _: *mut c_void, _: u32, _: *mut c_void) {
    // No stop can follow once the pointer has left.
    unsafe { &mut *data.cast::<Tracker>() }.active = false;
}

unsafe extern "C" fn axis(data: *mut c_void, _: *mut c_void, _: u32, axis: u32, _: i32) {
    if axis == WL_POINTER_AXIS_VERTICAL_SCROLL {
        unsafe { &mut *data.cast::<Tracker>() }.moved = true;
    }
}

unsafe extern "C" fn axis_source(data: *mut c_void, _: *mut c_void, source: u32) {
    unsafe { &mut *data.cast::<Tracker>() }.source = Some(source);
}

unsafe extern "C" fn axis_stop(data: *mut c_void, _: *mut c_void, _: u32, axis: u32) {
    if axis == WL_POINTER_AXIS_VERTICAL_SCROLL {
        unsafe { &mut *data.cast::<Tracker>() }.stopped = true;
    }
}

unsafe extern "C" fn frame(data: *mut c_void, _: *mut c_void) {
    let tracker = unsafe { &mut *data.cast::<Tracker>() };
    let finger = tracker.source == Some(WL_POINTER_AXIS_SOURCE_FINGER);
    if tracker.stopped || (tracker.moved && !finger) {
        tracker.active = false;
    } else if tracker.moved && !tracker.active {
        tracker.active = true;
        tracker.serial += 1;
    }
    (tracker.source, tracker.moved, tracker.stopped) = (None, false, false);
}

impl Tracker {
    fn connect() -> Option<Box<Self>> {
        let server = DisplayServer::singleton();
        if server.get_name().to_string() != "Wayland" {
            return None;
        }
        let display = server.window_get_native_handle_ex(HandleType::DISPLAY_HANDLE).done() as *mut c_void;
        if display.is_null() {
            return None;
        }
        let library = Library::load()?;
        unsafe {
            let queue = (library.create_queue)(display);
            if queue.is_null() {
                return None;
            }
            let mut tracker = Box::new(Self {
                library,
                display,
                queue,
                registry: std::ptr::null_mut(),
                seat: std::ptr::null_mut(),
                pointer: std::ptr::null_mut(),
                source: None,
                moved: false,
                stopped: false,
                active: false,
                serial: 0,
            });
            // Objects made through a wrapper on this queue deliver their
            // events here, never on Godot's queue.
            let wrapper = (tracker.library.create_wrapper)(display);
            if wrapper.is_null() {
                return None;
            }
            (tracker.library.set_queue)(wrapper, queue);
            let mut arguments = [Argument { object: std::ptr::null_mut() }];
            tracker.registry = (tracker.library.marshal_constructor)(
                wrapper,
                WL_DISPLAY_GET_REGISTRY,
                arguments.as_mut_ptr(),
                tracker.library.registry_interface,
                1,
            );
            (tracker.library.wrapper_destroy)(wrapper);
            if tracker.registry.is_null() {
                return None;
            }
            let data: *mut Self = &raw mut *tracker;
            (tracker.library.add_listener)(tracker.registry, (&raw const REGISTRY_LISTENER).cast(), data.cast());
            (tracker.library.flush)(display);
            Some(tracker)
        }
    }

    fn dispatch(&mut self) {
        unsafe {
            (self.library.dispatch_pending)(self.display, self.queue);
            // Binding the seat and its pointer queued requests of our own.
            (self.library.flush)(self.display);
        }
    }
}

thread_local! {
    /// `None` until first asked; `Some(None)` where there is no Wayland.
    static TRACKER: RefCell<Option<Option<Box<Tracker>>>> = const { RefCell::new(None) };
}

fn with<R>(read: impl FnOnce(&Tracker) -> R) -> Option<R> {
    TRACKER.with_borrow_mut(|slot| {
        let tracker = slot.get_or_insert_with(Tracker::connect).as_mut()?;
        tracker.dispatch();
        Some(read(tracker))
    })
}

/// Start listening before the first scroll, since the seat and its pointer
/// arrive over a few frames.
pub(crate) fn prepare() {
    with(|_| ());
}

/// The finger scroll now under way, if the last scroll came from fingers on
/// a touchpad.
pub(crate) fn finger_scroll() -> Option<u64> {
    with(|tracker| tracker.active.then_some(tracker.serial)).flatten()
}

/// Whether the fingers of that scroll have lifted.
pub(crate) fn stopped(serial: u64) -> bool {
    with(|tracker| !(tracker.active && tracker.serial == serial)).unwrap_or(true)
}
