//! Precision touchpad gestures on Windows.
//!
//! Godot sees a precision touchpad only as wheel messages, with no way to
//! tell finger travel from inertia or to know when the fingers lift. As
//! Chromium does, this hands each touchpad contact to Direct Manipulation,
//! which reports phased scrolling and the scale and translation of a pinch, and re-emits
//! them as Godot gestures. A mouse wheel never becomes a touchpad contact,
//! so it keeps arriving as wheel buttons.
use godot::classes::{
    DisplayServer, Input, InputEventMagnifyGesture, InputEventPanGesture, display_server::HandleType,
};
use godot::global::Key;
use godot::prelude::*;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::DirectManipulation::{
    DIRECTMANIPULATION_CONFIGURATION_INTERACTION, DIRECTMANIPULATION_CONFIGURATION_RAILS_X,
    DIRECTMANIPULATION_CONFIGURATION_RAILS_Y, DIRECTMANIPULATION_CONFIGURATION_SCALING,
    DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_INERTIA, DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_X,
    DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_Y, DIRECTMANIPULATION_INERTIA,
    DIRECTMANIPULATION_INTERACTION_BEGIN, DIRECTMANIPULATION_INTERACTION_END,
    DIRECTMANIPULATION_INTERACTION_TYPE, DIRECTMANIPULATION_READY, DIRECTMANIPULATION_RUNNING,
    DIRECTMANIPULATION_STATUS, DIRECTMANIPULATION_VIEWPORT_OPTIONS_MANUALUPDATE, DirectManipulationManager,
    IDirectManipulationContent, IDirectManipulationInteractionEventHandler,
    IDirectManipulationInteractionEventHandler_Impl, IDirectManipulationManager,
    IDirectManipulationPrimaryContent, IDirectManipulationUpdateManager, IDirectManipulationViewport, IDirectManipulationViewport2,
    IDirectManipulationViewportEventHandler, IDirectManipulationViewportEventHandler_Impl,
};
use windows::Win32::Graphics::Gdi::ScreenToClient;
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::Pointer::GetPointerType;
use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::{
    DM_POINTERHITTEST, GetClientRect, GetCursorPos, POINTER_INPUT_TYPE, PT_TOUCHPAD, WM_DESTROY, WM_SIZE,
};
use windows::core::{Ref, implement};

#[path = "touchpad_windows_transform.rs"]
mod transform;
use transform::pinch_travel;

const SUBCLASS_ID: usize = 0x4746_5450;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Gesture {
    None,
    Scroll,
    Fling,
    Pinch,
}

enum Event {
    /// Finger travel or inertia, in device-independent pixels the content
    /// moved, with its Chromium phase names.
    Pan { delta: (f32, f32), finger: Option<&'static str>, momentum: Option<&'static str> },
    Pinch { position: Vector2, previous: Vector2, center: Vector2, factor: f32 },
}

/// What a window's handler and its owner share.
#[derive(Default)]
struct Shared {
    events: RefCell<Vec<Event>>,
    /// An interaction is under way, so the viewport needs a manual update
    /// every frame to report it.
    interacting: Cell<bool>,
    size: Cell<(i32, i32)>,
}

/// Chromium's `DirectManipulationEventHandler`: content transforms in, one
/// gesture sequence at a time out.
#[implement(IDirectManipulationViewportEventHandler, IDirectManipulationInteractionEventHandler)]
struct Handler {
    window: isize,
    shared: Rc<Shared>,
    gesture: Cell<Gesture>,
    send_scroll_begin: Cell<bool>,
    /// Last native content transform (scale, x pixels, y pixels).
    last: Cell<(f32, f32, f32)>,
    /// Cursor at pinch start and the moving workspace anchor, in client pixels.
    pinch: Cell<Option<(Vector2, Vector2)>>,
    inertia: Cell<bool>,
}

impl Handler {
    fn push(&self, event: Event) {
        self.shared.events.borrow_mut().push(event);
    }

    fn pan(&self, delta: (f32, f32), finger: Option<&'static str>, momentum: Option<&'static str>) {
        self.push(Event::Pan { delta, finger, momentum });
    }

    fn transition(&self, gesture: Gesture) {
        let previous = self.gesture.replace(gesture);
        if previous == gesture {
            return;
        }
        self.pinch.set(None);
        if gesture == Gesture::Scroll {
            // The begin travels with the first scroll, which has its delta.
            self.send_scroll_begin.set(true);
        }
        match previous {
            // Inertia continues the same scroll sequence.
            Gesture::Scroll if gesture != Gesture::Fling => self.pan((0.0, 0.0), Some("ended"), None),
            Gesture::Fling => self.pan((0.0, 0.0), None, Some("ended")),
            _ => {}
        }
        if gesture == Gesture::Fling {
            self.pan((0.0, 0.0), None, Some("began"));
        }
    }
}

impl IDirectManipulationViewportEventHandler_Impl for Handler_Impl {
    fn OnViewportStatusChanged(
        &self,
        viewport: Ref<IDirectManipulationViewport>,
        current: DIRECTMANIPULATION_STATUS,
        previous: DIRECTMANIPULATION_STATUS,
    ) -> windows::core::Result<()> {
        if current == previous {
            return Ok(());
        }
        self.inertia.set(current == DIRECTMANIPULATION_INERTIA);
        if current == DIRECTMANIPULATION_INERTIA {
            // A pinch that ends in a quick pan keeps its sequence.
            if previous != DIRECTMANIPULATION_RUNNING || self.gesture.get() != Gesture::Scroll {
                return Ok(());
            }
            self.transition(Gesture::Fling);
        }
        if current == DIRECTMANIPULATION_RUNNING && previous == DIRECTMANIPULATION_INERTIA {
            // Fingers came back down during inertia: a new sequence.
            self.transition(Gesture::None);
        }
        if current != DIRECTMANIPULATION_READY {
            return Ok(());
        }
        // Return the content to its origin for the next gesture. The reset
        // itself reports a second, empty READY, which must not reset again.
        if self.last.get() != (1.0, 0.0, 0.0) {
            let (width, height) = self.shared.size.get();
            if let Some(viewport) = viewport.as_ref() {
                unsafe { viewport.ZoomToRect(0.0, 0.0, width as f32, height as f32, false)? };
            }
        }
        self.last.set((1.0, 0.0, 0.0));
        self.transition(Gesture::None);
        Ok(())
    }

    fn OnViewportUpdated(&self, _: Ref<IDirectManipulationViewport>) -> windows::core::Result<()> {
        Ok(())
    }

    fn OnContentUpdated(
        &self,
        viewport: Ref<IDirectManipulationViewport>,
        content: Ref<IDirectManipulationContent>,
    ) -> windows::core::Result<()> {
        let Some(content) = content.as_ref() else {
            return Ok(());
        };
        let mut transform = [0f32; 6];
        unsafe { content.GetContentTransform(&mut transform)? };
        let (scale, x, y) = (transform[0], transform[4], transform[5]);
        let (last_scale, last_x, last_y) = self.last.get();
        let same = |a: f32, b: f32| (a - b).abs() < f32::EPSILON;
        if !scale.is_finite() || scale <= 0.0 || !x.is_finite() || !y.is_finite() {
            return Ok(());
        }
        if same(scale, last_scale) && x == last_x && y == last_y {
            return Ok(());
        }
        // One sequence is a scroll or a pinch. A slow pinch may start out
        // looking like a scroll, so a scroll can still turn into a pinch.
        if same(scale, 1.0) {
            if self.gesture.get() == Gesture::None {
                self.transition(Gesture::Scroll);
            }
        } else {
            self.transition(Gesture::Pinch);
        }
        let device_scale = unsafe { GetDpiForWindow(HWND(self.window as _)) }.max(96) as f32 / 96.0;
        let delta = ((x - last_x) / device_scale, (y - last_y) / device_scale);
        match self.gesture.get() {
            Gesture::Scroll if self.send_scroll_begin.replace(false) => self.pan(delta, Some("began"), None),
            Gesture::Scroll => self.pan(delta, Some("changed"), None),
            Gesture::Fling => self.pan(delta, None, Some("changed")),
            Gesture::Pinch if !self.inertia.get() => {
                let (position, previous) = self.pinch.get().unwrap_or_else(|| {
                    let cursor = cursor_position(self.window);
                    (cursor, cursor)
                });
                let travel = if scale == last_scale {
                    Vector2::new(x - last_x, y - last_y)
                } else if let Some(pivot) = content_pivot(viewport) {
                    let (dx, dy) = pinch_travel(self.last.get(), (scale, x, y), pivot);
                    Vector2::new(dx, dy)
                } else {
                    // Without a pivot the scale is known, but its contribution
                    // to translation cannot be separated from finger travel.
                    Vector2::ZERO
                };
                let center = previous + travel;
                self.pinch.set(Some((position, center)));
                self.push(Event::Pinch { position, previous, center, factor: scale / last_scale });
            }
            Gesture::Pinch | Gesture::None => {}
        }
        self.last.set((scale, x, y));
        Ok(())
    }
}

impl IDirectManipulationInteractionEventHandler_Impl for Handler_Impl {
    fn OnInteraction(
        &self,
        _: Ref<IDirectManipulationViewport2>,
        interaction: DIRECTMANIPULATION_INTERACTION_TYPE,
    ) -> windows::core::Result<()> {
        if interaction == DIRECTMANIPULATION_INTERACTION_BEGIN {
            self.shared.interacting.set(true);
        } else if interaction == DIRECTMANIPULATION_INTERACTION_END {
            self.shared.interacting.set(false);
        }
        Ok(())
    }
}

/// One Godot window handing its touchpad contacts to Direct Manipulation.
#[derive(Clone)]
struct Attached {
    window: isize,
    id: i32,
    manager: IDirectManipulationManager,
    updates: IDirectManipulationUpdateManager,
    viewport: IDirectManipulationViewport,
    cookie: u32,
    shared: Rc<Shared>,
}

thread_local! {
    static ATTACHED: RefCell<Vec<Attached>> = const { RefCell::new(Vec::new()) };
    /// Windows where Direct Manipulation would not start; they keep wheels.
    static REFUSED: RefCell<Vec<isize>> = const { RefCell::new(Vec::new()) };
    /// Set by `shutdown`: nothing may be adopted while the app is quitting.
    static STOPPED: Cell<bool> = const { Cell::new(false) };
}

fn client_size(window: HWND) -> (i32, i32) {
    let mut rect = RECT::default();
    let _ = unsafe { GetClientRect(window, &mut rect) };
    ((rect.right - rect.left).max(1), (rect.bottom - rect.top).max(1))
}

fn attach(window: isize, id: i32) -> windows::core::Result<Attached> {
    let hwnd = HWND(window as _);
    unsafe {
        let manager: IDirectManipulationManager =
            CoCreateInstance(&DirectManipulationManager, None, CLSCTX_INPROC_SERVER)?;
        let updates: IDirectManipulationUpdateManager = manager.GetUpdateManager()?;
        let viewport: IDirectManipulationViewport = manager.CreateViewport(None, hwnd)?;
        let shared = Rc::new(Shared::default());
        shared.size.set(client_size(hwnd));
        let started = (|| {
            viewport.ActivateConfiguration(
                DIRECTMANIPULATION_CONFIGURATION_INTERACTION
                    | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_X
                    | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_Y
                    | DIRECTMANIPULATION_CONFIGURATION_TRANSLATION_INERTIA
                    | DIRECTMANIPULATION_CONFIGURATION_RAILS_X
                    | DIRECTMANIPULATION_CONFIGURATION_RAILS_Y
                    | DIRECTMANIPULATION_CONFIGURATION_SCALING,
            )?;
            // Report only when asked, once per frame, as the app renders.
            viewport.SetViewportOptions(DIRECTMANIPULATION_VIEWPORT_OPTIONS_MANUALUPDATE)?;
            let (width, height) = shared.size.get();
            viewport.SetViewportRect(&RECT { left: 0, top: 0, right: width, bottom: height })?;
            manager.Activate(hwnd)?;
            let handler: IDirectManipulationViewportEventHandler = Handler {
                window,
                shared: shared.clone(),
                gesture: Cell::new(Gesture::None),
                send_scroll_begin: Cell::new(false),
                last: Cell::new((1.0, 0.0, 0.0)),
                pinch: Cell::new(None),
                inertia: Cell::new(false),
            }
            .into();
            let enabled = viewport.Enable().and_then(|()| viewport.AddEventHandler(Some(hwnd), &handler));
            if enabled.is_err() {
                let _ = manager.Deactivate(hwnd);
            }
            enabled
        })();
        let cookie = match started {
            Ok(cookie) => cookie,
            Err(error) => {
                let _ = viewport.Abandon();
                return Err(error);
            }
        };
        if !SetWindowSubclass(hwnd, Some(window_proc), SUBCLASS_ID, 0).as_bool() {
            detach(&Attached { window, id, manager, updates, viewport, cookie, shared });
            return Err(windows::core::Error::from_thread());
        }
        let _ = updates.Update(None);
        Ok(Attached { window, id, manager, updates, viewport, cookie, shared })
    }
}

/// Release a window's viewport while its window still exists. A viewport or
/// an activated manager left alive keeps Direct Manipulation's threads
/// waiting on it, and the process then never exits.
fn detach(attached: &Attached) {
    unsafe {
        let _ = RemoveWindowSubclass(HWND(attached.window as _), Some(window_proc), SUBCLASS_ID);
        let _ = attached.viewport.Stop();
        let _ = attached.viewport.RemoveEventHandler(attached.cookie);
        let _ = attached.viewport.Abandon();
        let _ = attached.manager.Deactivate(HWND(attached.window as _));
    }
}

fn find(window: HWND) -> Option<Attached> {
    ATTACHED.with_borrow(|attached| attached.iter().find(|entry| entry.window == window.0 as isize).cloned())
}

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _: usize,
    _: usize,
) -> LRESULT {
    // Nothing here may hold a borrow across a Direct Manipulation call: those
    // can run the handler, and Windows can send messages from inside them.
    match message {
        // Only this message opens a touchpad contact's input sequence.
        DM_POINTERHITTEST => {
            let pointer = (wparam.0 & 0xffff) as u32;
            let mut kind = POINTER_INPUT_TYPE::default();
            if unsafe { GetPointerType(pointer, &mut kind) }.is_ok()
                && kind == PT_TOUCHPAD
                && let Some(attached) = find(window)
            {
                let _ = unsafe { attached.viewport.SetContact(pointer) };
            }
        }
        WM_SIZE => {
            if let Some(attached) = find(window) {
                let (width, height) = client_size(window);
                if attached.shared.size.replace((width, height)) != (width, height) {
                    let rect = RECT { left: 0, top: 0, right: width, bottom: height };
                    let _ = unsafe { attached.viewport.SetViewportRect(&rect) };
                }
            }
        }
        // The last message for which the window is still whole.
        WM_DESTROY => {
            let gone = ATTACHED.with_borrow_mut(|attached| {
                let index = attached.iter().position(|entry| entry.window == window.0 as isize)?;
                Some(attached.swap_remove(index))
            });
            if let Some(gone) = gone {
                detach(&gone);
            }
        }
        _ => {}
    }
    unsafe { DefSubclassProc(window, message, wparam, lparam) }
}

/// Windows reports the manipulation pivot before the content transform.
fn content_pivot(viewport: Ref<IDirectManipulationViewport>) -> Option<(f32, f32)> {
    let viewport = viewport.as_ref()?;
    let primary = unsafe { viewport.GetPrimaryContent::<IDirectManipulationPrimaryContent>() }.ok()?;
    let (mut x, mut y) = (0.0, 0.0);
    unsafe { primary.GetCenterPoint(&mut x, &mut y) }.ok()?;
    (x.is_finite() && y.is_finite()).then_some((x, y))
}

fn cursor_position(window: isize) -> Vector2 {
    let hwnd = HWND(window as _);
    let mut point = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut point);
        let _ = ScreenToClient(hwnd, &mut point);
    }
    Vector2::new(point.x as f32, point.y as f32)
}

fn emit(attached: &Attached, event: Event) {
    let mut input = Input::singleton();
    match event {
        Event::Pan { delta, finger, momentum } => {
            let mut pan = InputEventPanGesture::new_gd();
            pan.set_window_id(i64::from(attached.id));
            pan.set_position(cursor_position(attached.window));
            // Godot's pan delta is the scroll direction, opposite to the
            // way the content moved.
            pan.set_delta(Vector2::new(-delta.0, -delta.1));
            pan.set_shift_pressed(input.is_key_pressed(Key::SHIFT));
            pan.set_ctrl_pressed(input.is_key_pressed(Key::CTRL));
            pan.set_alt_pressed(input.is_key_pressed(Key::ALT));
            pan.set_meta_pressed(input.is_key_pressed(Key::META));
            if let Some(phase) = finger {
                pan.set_meta("scroll_phase", &phase.to_variant());
            }
            if let Some(phase) = momentum {
                pan.set_meta("momentum_phase", &phase.to_variant());
            }
            input.parse_input_event(&pan);
        }
        Event::Pinch { position, previous, center, factor } => {
            let mut magnify = InputEventMagnifyGesture::new_gd();
            magnify.set_window_id(i64::from(attached.id));
            magnify.set_position(position);
            magnify.set_factor(factor);
            magnify.set_meta("pinch_previous", &previous.to_variant());
            magnify.set_meta("pinch_center", &center.to_variant());
            magnify.set_meta("pinch_pan", &(center - previous).to_variant());
            input.parse_input_event(&magnify);
        }
    }
}

/// Once a frame: adopt new windows, let Direct Manipulation report, and pass
/// its gestures on to Godot.
pub(crate) fn poll() {
    if STOPPED.get() {
        return;
    }
    let server = DisplayServer::singleton();
    for id in server.get_window_list().as_slice().iter().copied() {
        let window = server.window_get_native_handle_ex(HandleType::WINDOW_HANDLE).window_id(id).done() as isize;
        if window == 0
            || find(HWND(window as _)).is_some()
            || REFUSED.with_borrow(|refused| refused.contains(&window))
        {
            continue;
        }
        match attach(window, id) {
            Ok(attached) => ATTACHED.with_borrow_mut(|all| all.push(attached)),
            Err(_) => REFUSED.with_borrow_mut(|refused| refused.push(window)),
        }
    }
    let attached = ATTACHED.with_borrow(Clone::clone);
    for entry in &attached {
        if entry.shared.interacting.get() {
            let _ = unsafe { entry.updates.Update(None) };
        }
        let events = std::mem::take(&mut *entry.shared.events.borrow_mut());
        for event in events {
            emit(entry, event);
        }
    }
}

/// Before the app's windows close: give every contact back and release
/// Direct Manipulation, so nothing of it outlives the windows.
pub(crate) fn shutdown() {
    STOPPED.set(true);
    for attached in ATTACHED.with_borrow_mut(std::mem::take) {
        detach(&attached);
    }
}
