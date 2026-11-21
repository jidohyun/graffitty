//! Deterministic direct-touch recognition. The frontend supplies contact events and a clock;
//! the core emits semantic actions, never engine input objects.
use glam::Vec2;
use std::collections::BTreeMap;

use crate::fling::ScrollMotion;
/// The longest pause between the taps of a double tap.
pub const TAP_MS: i64 = 300;
pub const HOLD_MS: i64 = 500;
pub const PINCH_GRACE_MS: i64 = 120;
pub const SCROLL_GRACE_MS: i64 = 120;
/// Movement past the slop shows intent, so it only waits for nearly simultaneous contacts.
pub const MOVING_GRACE_MS: i64 = 50;
/// A resting contact on a yielding surface can still join a workspace pinch for
/// this long. Shorter than any surface's own long press, which keeps the contact.
pub const YIELD_MS: i64 = 400;
const SLOP: f32 = 10.;
const DOUBLE_TAP_DISTANCE: f32 = 48.;
const TERMINAL_DOUBLE_TAP_DISTANCE: f32 = 24.;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Left,
    Right,
}
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    Button {
        button: Button,
        pressed: bool,
        position: Vec2,
        double: bool,
        canceled: bool,
        held: bool,
    },
    Motion {
        position: Vec2,
        relative: Vec2,
    },
    Pinch {
        previous: Vec2,
        center: Vec2,
        factor: f32,
    },
    Scroll {
        anchor: Vec2,
        delta: Vec2,
        stage: ScrollStage,
    },
    RemoteSwipe { progress: f32, finished: bool, commit: bool },
    Canceled,
}
/// Where a scroll action falls in its gesture, as a rubber band needs it:
/// finger travel can pull content past an edge, momentum only bounces off it,
/// and the end releases the pull.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrollStage {
    Began,
    Changed,
    Momentum,
    /// Carries no movement.
    Ended,
}
#[derive(Clone, Copy, Debug)]
pub enum Contact {
    Down { id: i32, position: Vec2 },
    Up { id: i32, position: Vec2 },
    Move { id: i32, position: Vec2 },
    Cancel,
}
/// Exclusive gesture modes prevent a surviving pinch/scroll contact from becoming a click.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode {
    Idle,
    Pointer,
    MultiPending,
    SwipePending,
    Swiping,
    Suppressed,
    Navigating,
    Scrolling,
    LongPressed,
}
pub struct TouchNavigation {
    fingers: BTreeMap<i32, Vec2>,
    drag_scroll: bool,
    swipe_width: f32,
    swipe_offset: f32,
    swipe_velocity: f32,
    swipe_time: i64,
    mode: Mode,
    origin: Vec2,
    started: i64,
    last_tap: i64,
    last_tap_position: Vec2,
    moved: bool,
    suppress_tap: bool,
    held: bool,
    pending: bool,
    pending_double: bool,
    pointer_position: Vec2,
    scroll_anchor: Vec2,
    scroll_contacts: usize,
    pinch_pending: bool,
    pinch_started: i64,
    pinch_center: Vec2,
    pinch_distance: f32,
    scroll: ScrollMotion,
    /// A scroll gesture has begun and its end is still owed.
    scroll_open: bool,
}
impl Default for TouchNavigation {
    fn default() -> Self {
        Self {
            fingers: BTreeMap::new(),
            drag_scroll: false,
            swipe_width: 0.,
            swipe_offset: 0.,
            swipe_velocity: 0.,
            swipe_time: 0,
            mode: Mode::Idle,
            origin: Vec2::ZERO,
            started: 0,
            last_tap: -1000,
            last_tap_position: Vec2::ZERO,
            moved: false,
            suppress_tap: false,
            held: false,
            pending: false,
            pending_double: false,
            pointer_position: Vec2::ZERO,
            scroll_anchor: Vec2::ZERO,
            scroll_contacts: 3,
            pinch_pending: false,
            pinch_started: 0,
            pinch_center: Vec2::ZERO,
            pinch_distance: 0.,
            scroll: ScrollMotion::default(),
            scroll_open: false,
        }
    }
}
impl TouchNavigation {
    /// The frontend chooses this for terminal content at the start of a gesture.
    /// Chrome and other draggable controls keep direct pointer semantics.
    pub fn set_drag_scroll(&mut self, enabled: bool) {
        if self.fingers.is_empty() {
            if self.drag_scroll != enabled {
                self.scroll.stop();
                self.last_tap = -1000;
            }
            self.drag_scroll = enabled;
        }
    }
    /// Opt in only for clients with a remote-workspace switcher.
    pub fn set_remote_swipe_width(&mut self, width: f32) {
        if self.fingers.is_empty() {
            self.swipe_width = if width.is_finite() { width.max(0.) } else { 0. };
        }
    }
    pub fn stop_scroll(&mut self) {
        self.scroll.stop();
    }
    pub fn fingers(&self) -> &BTreeMap<i32, Vec2> {
        &self.fingers
    }
    pub fn held(&self) -> bool {
        self.held
    }
    pub fn scrolling(&self) -> bool {
        self.mode == Mode::Scrolling
    }
    pub fn navigating(&self) -> bool {
        self.mode == Mode::Navigating
    }
    pub fn long_pressed(&self) -> bool {
        self.mode == Mode::LongPressed
    }
    /// Whether a contact on a yielding surface may turn this gesture into a
    /// pinch: one resting or navigating finger, never a drag or scroll under way.
    pub fn joinable(&self) -> bool {
        self.fingers.len() == 1
            && match self.mode {
                Mode::Pointer => !self.moved,
                Mode::MultiPending | Mode::Navigating => true,
                _ => false,
            }
    }
    pub fn center(&self) -> Vec2 {
        self.fingers.values().copied().sum::<Vec2>() / self.fingers.len().max(1) as f32
    }
    fn distance(&self) -> f32 {
        if self.fingers.len() != 2 {
            0.
        } else {
            let mut p = self.fingers.values();
            p.next().unwrap().distance(*p.next().unwrap())
        }
    }
    fn button(
        &self,
        out: &mut Vec<Action>,
        button: Button,
        pressed: bool,
        position: Vec2,
        double: bool,
        canceled: bool,
    ) {
        out.push(Action::Button {
            button,
            pressed,
            position,
            double,
            canceled,
            held: self.held,
        });
    }
    fn release_pointer(&mut self, out: &mut Vec<Action>, canceled: bool) {
        if self.held {
            self.held = false;
            self.button(
                out,
                Button::Left,
                false,
                if canceled {
                    self.pointer_position
                } else if !self.moved {
                    self.origin
                } else {
                    self.center()
                },
                false,
                canceled,
            );
        }
    }
    fn scroll_action(&mut self, out: &mut Vec<Action>, delta: Vec2) {
        let stage = if self.scroll_open { ScrollStage::Changed } else { ScrollStage::Began };
        self.scroll_open = true;
        out.push(Action::Scroll { anchor: self.scroll_anchor, delta, stage });
    }
    fn end_scroll(&mut self, out: &mut Vec<Action>) {
        if std::mem::take(&mut self.scroll_open) {
            out.push(Action::Scroll { anchor: self.scroll_anchor, delta: Vec2::ZERO, stage: ScrollStage::Ended });
        }
    }
    fn motion(&mut self, out: &mut Vec<Action>, position: Vec2) {
        out.push(Action::Motion {
            position,
            relative: position - self.pointer_position,
        });
        self.pointer_position = position;
    }
    fn commit_pointer(&mut self, now: i64, force: bool, out: &mut Vec<Action>) {
        if !self.pending
            || self.mode != Mode::Pointer
            || self.fingers.len() != 1
            || (!force
                && now - self.started
                    < if self.drag_scroll && self.moved {
                        MOVING_GRACE_MS
                    } else {
                        PINCH_GRACE_MS
                    })
        {
            return;
        }
        if self.drag_scroll && !self.pending_double {
            if self.moved {
                self.pending = false;
                self.mode = Mode::Scrolling;
                self.scroll_contacts = 1;
                self.scroll_anchor = self.origin;
                let delta = self.center() - self.origin;
                self.scroll.track(delta, now);
                self.scroll_action(out, delta);
                return;
            }
            // A stationary contact can still become a scroll or long press.
            // Only a completed tap may send a plain left click to the terminal.
            // A still contact stays a tap until it becomes a long press.
            if !force {
                return;
            }
            if self.suppress_tap || now - self.started >= HOLD_MS {
                self.pending = false;
                return;
            }
        }
        self.pending = false;
        self.scroll.stop();
        self.held = true;
        self.pointer_position = self.origin;
        self.button(
            out,
            Button::Left,
            true,
            self.origin,
            self.pending_double,
            false,
        );
        if self.moved {
            self.motion(out, self.center());
        }
    }
    fn commit_pinch(&mut self, now: i64, out: &mut Vec<Action>) {
        if !self.pinch_pending || self.mode == Mode::Scrolling || self.fingers.len() != 2 {
            return;
        }
        let center = self.center();
        let distance = self.distance();
        let moved = center.distance(self.pinch_center) >= SLOP
            || (distance - self.pinch_distance).abs() >= SLOP;
        if now - self.pinch_started
            < if moved {
                MOVING_GRACE_MS
            } else {
                SCROLL_GRACE_MS
            }
        {
            return;
        }
        self.pinch_pending = false;
        self.scroll.stop();
        self.mode = Mode::Navigating;
        if center == self.pinch_center
            && (distance - self.pinch_distance).abs() < (distance.abs() * 0.00001).max(0.00001)
        {
            return;
        }
        out.push(Action::Pinch {
            previous: self.pinch_center,
            center,
            factor: Self::factor(self.pinch_distance, distance),
        });
    }
    fn factor(old: f32, new: f32) -> f32 {
        if old > SLOP && new > SLOP {
            new / old
        } else {
            1.
        }
    }
    pub fn handle(&mut self, event: Contact, now: i64) -> (bool, Vec<Action>) {
        let mut out = vec![];
        match event {
            Contact::Cancel => {
                return (true, self.cancel());
            }
            Contact::Down { id, position } => {
                if self.fingers.is_empty() {
                    // Touching moving content brakes the fling; it must not also
                    // click that content or arm a double-tap selection.
                    self.suppress_tap = self.drag_scroll && self.scroll.velocity() != Vec2::ZERO;
                    self.scroll.begin(now);
                }
                self.fingers.insert(id, position);
                if self.fingers.len() == 1 {
                    self.origin = position;
                    self.started = now;
                    self.moved = false;
                    self.mode = Mode::Pointer;
                    self.pinch_pending = false;
                    let double_distance = if self.drag_scroll {
                        TERMINAL_DOUBLE_TAP_DISTANCE
                    } else {
                        DOUBLE_TAP_DISTANCE
                    };
                    self.pending_double = !self.suppress_tap
                        && now - self.last_tap <= TAP_MS
                        && self.origin.distance(self.last_tap_position) <= double_distance;
                    self.last_tap = -1000;
                    self.pending = true;
                } else if matches!(self.mode, Mode::Pointer | Mode::LongPressed)
                    || (self.mode == Mode::Scrolling && self.scroll_contacts == 1)
                {
                    // Keep a pending repeat candidate until we know whether
                    // these contacts form a pinch or a three-finger scroll.
                    if self.mode == Mode::Scrolling {
                        self.scroll.stop();
                        self.end_scroll(&mut out);
                    }
                    self.mode = Mode::MultiPending;
                    self.pending = false;
                    out.push(Action::Canceled);
                    self.release_pointer(&mut out, true);
                }
                if self.fingers.len() == 2 && !matches!(self.mode, Mode::Scrolling | Mode::Suppressed) {
                    self.pinch_pending = self.mode != Mode::Navigating;
                    self.pinch_started = now;
                    self.pinch_center = self.center();
                    self.pinch_distance = self.distance();
                }
                if self.fingers.len() >= 3 {
                    self.pinch_pending = false;
                }
                if self.fingers.len() > 3 && self.swipe_width > 0. {
                    if self.mode == Mode::Swiping {
                        out.push(Action::RemoteSwipe { progress: self.swipe_offset / self.swipe_width, finished: true, commit: false });
                    }
                    self.mode = Mode::Suppressed;
                    self.scroll.stop();
                }
                if self.fingers.len() == 3 && self.mode != Mode::Scrolling && self.mode != Mode::Suppressed {
                    self.mode = if self.swipe_width > 0. { Mode::SwipePending } else { Mode::Scrolling };
                    self.swipe_offset = 0.;
                    self.swipe_velocity = 0.;
                    self.swipe_time = now;
                    self.scroll_contacts = 3;
                    self.scroll_anchor = self.center();
                    self.scroll.reset_samples(now);
                }
            }
            Contact::Up { id, position } => {
                if self.fingers.contains_key(&id) {
                    self.pinch_pending = false;
                    self.fingers.insert(id, position);
                    if self.mode == Mode::Swiping {
                        let offset = self.center().x - self.scroll_anchor.x;
                        let progress = (offset / self.swipe_width).clamp(-1., 1.);
                        let fling = now - self.swipe_time < 100 && offset.abs() >= 36.
                            && self.swipe_velocity.abs() >= 0.6 && offset * self.swipe_velocity > 0.;
                        out.push(Action::RemoteSwipe { progress, finished: true, commit: progress.abs() >= 0.2 || fling });
                        self.mode = Mode::Suppressed;
                    } else if self.mode == Mode::SwipePending {
                        self.mode = Mode::Suppressed;
                    }
                    if self.fingers.len() == 1 && self.mode == Mode::Pointer {
                        // Some devices coalesce the final movement into finger-up.
                        // Never turn that displacement into a click.
                        self.moved |= position.distance(self.origin) >= SLOP;
                        self.commit_pointer(now, true, &mut out);
                        if !self.moved && !self.suppress_tap && now - self.started < HOLD_MS {
                            self.last_tap = now;
                            self.last_tap_position = position;
                        }
                    }
                    self.release_pointer(&mut out, false);
                    self.fingers.remove(&id);
                    if self.fingers.is_empty() {
                        if self.mode == Mode::Scrolling {
                            self.scroll.release(now);
                            if self.scroll.velocity() == Vec2::ZERO {
                                self.end_scroll(&mut out);
                            }
                        } else {
                            self.scroll.stop();
                            self.mode = Mode::Idle;
                        }
                    }
                }
            }
            Contact::Move { id, position } => {
                if !self.fingers.contains_key(&id) {
                    return (false, out);
                }
                let old_center = self.center();
                let old_distance = self.distance();
                self.fingers.insert(id, position);
                if self.fingers.len() == 1 && self.mode == Mode::Pointer {
                    // The fling measures the drag from the first move, before
                    // this recognizer decides it is a scroll.
                    if self.pending {
                        self.scroll.sample(position - self.origin, now);
                    }
                    if !self.moved && position.distance(self.origin) < SLOP {
                        return (true, out);
                    }
                    self.moved = true;
                    if self.pending {
                        self.commit_pointer(now, false, &mut out);
                    } else {
                        self.motion(&mut out, position);
                    }
                } else if matches!(self.mode, Mode::SwipePending | Mode::Swiping) {
                    let delta = self.center() - self.scroll_anchor;
                    if self.mode == Mode::SwipePending && delta.length() >= 12. {
                        if delta.x.abs() > delta.y.abs() * 1.25 {
                            self.mode = Mode::Swiping;
                            self.scroll.stop();
                        } else if delta.y.abs() > delta.x.abs() * 1.25 {
                            self.mode = Mode::Scrolling;
                            self.scroll.track(delta, now);
                            self.scroll_action(&mut out, delta);
                        }
                    }
                    if self.mode == Mode::Swiping {
                        let dt = (now - self.swipe_time).max(1) as f32;
                        self.swipe_velocity = self.swipe_velocity * 0.5 + (delta.x - self.swipe_offset) / dt * 0.5;
                        self.swipe_offset = delta.x;
                        self.swipe_time = now;
                        out.push(Action::RemoteSwipe { progress: (delta.x / self.swipe_width).clamp(-1., 1.), finished: false, commit: false });
                    }
                } else if self.mode == Mode::Suppressed {
                    // Captured chord owns all remaining contacts until they lift.
                } else if self.mode == Mode::Scrolling {
                    if self.fingers.len() == self.scroll_contacts {
                        let delta = self.center() - old_center;
                        self.scroll.track(delta, now);
                        self.scroll_action(&mut out, delta);
                    }
                } else if self.fingers.len() == 2 {
                    if self.pinch_pending {
                        self.commit_pinch(now, &mut out);
                    } else {
                        out.push(Action::Pinch {
                            previous: old_center,
                            center: self.center(),
                            factor: Self::factor(old_distance, self.distance()),
                        });
                    }
                } else if self.fingers.len() == 1 && self.mode == Mode::Navigating {
                    out.push(Action::Pinch {
                        previous: old_center,
                        center: self.center(),
                        factor: 1.,
                    });
                }
            }
        }
        (true, out)
    }
    pub fn advance(&mut self, now: i64) -> Vec<Action> {
        let mut out = vec![];
        if self.fingers.is_empty() {
            let delta = self.scroll.advance(now);
            if delta != Vec2::ZERO {
                out.push(Action::Scroll {
                    anchor: self.scroll_anchor,
                    delta,
                    stage: ScrollStage::Momentum,
                });
            }
        }
        // The fling ran out, or a tap, key or new target stopped it.
        if self.scroll.velocity() == Vec2::ZERO && (self.fingers.is_empty() || self.mode != Mode::Scrolling) {
            self.end_scroll(&mut out);
        }
        self.commit_pinch(now, &mut out);
        if self.fingers.len() == 1
            && self.mode == Mode::Pointer
            && !self.moved
            && !self.suppress_tap
            && now - self.started >= HOLD_MS
        {
            self.mode = Mode::LongPressed;
            self.scroll.stop();
            self.pending = false;
            out.push(Action::Canceled);
            self.release_pointer(&mut out, true);
            self.button(&mut out, Button::Right, true, self.origin, false, false);
            self.button(&mut out, Button::Right, false, self.origin, false, false);
        } else {
            self.commit_pointer(now, false, &mut out);
        }
        out
    }
    pub fn cancel(&mut self) -> Vec<Action> {
        self.scroll.stop();
        self.pending = false;
        self.pinch_pending = false;
        let mut out = vec![Action::Canceled];
        self.end_scroll(&mut out);
        if self.mode == Mode::Swiping {
            out.push(Action::RemoteSwipe { progress: self.swipe_offset / self.swipe_width, finished: true, commit: false });
        }
        self.release_pointer(&mut out, true);
        self.fingers.clear();
        self.last_tap = -1000;
        self.mode = Mode::Idle;
        out
    }
}
/// Where a new contact landed, as the frontend's hit test reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Zone {
    /// Workspace content, which the recognizer owns.
    Workspace,
    /// A surface that owns its touches but gives a resting one up to a pinch.
    Yielding,
    /// A control that never joins a workspace gesture.
    Exclusive,
}
struct SurfaceContact {
    yielding: bool,
    origin: Vec2,
    position: Vec2,
    started: i64,
    moved: bool,
    mouse: bool,
}
/// A contact taken from its surface, which must now see it canceled.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Yielded {
    pub id: i32,
    pub position: Vec2,
    /// The platform's emulated mouse follows this contact.
    pub mouse: bool,
}
#[derive(Debug, Default, PartialEq)]
pub struct Routed {
    /// The recognizer owns this event; no surface may see it.
    pub workspace: bool,
    pub actions: Vec<Action>,
    pub yielded: Vec<Yielded>,
}
/// Gives every contact one owner, the workspace recognizer or the surface it
/// landed on, for as long as it stays down.
///
/// The only handover is a resting contact on a yielding surface joining a
/// workspace contact as a pinch.
#[derive(Default)]
pub struct TouchArena {
    pub gesture: TouchNavigation,
    surface: BTreeMap<i32, SurfaceContact>,
}
impl TouchArena {
    fn feed(&mut self, event: Contact, now: i64, routed: &mut Routed) {
        routed.workspace = true;
        routed.actions.extend(self.gesture.handle(event, now).1);
    }
    /// The one surface contact a new workspace contact may take along.
    fn resting(&self, now: i64) -> Option<i32> {
        let mut resting = self
            .surface
            .iter()
            .filter(|(_, c)| c.yielding && !c.moved && now - c.started < YIELD_MS)
            .map(|(&id, _)| id);
        let id = resting.next()?;
        resting.next().is_none().then_some(id)
    }
    /// `zone` matters only for a contact going down.
    pub fn handle(&mut self, event: Contact, zone: Zone, now: i64) -> Routed {
        let mut routed = Routed::default();
        match event {
            Contact::Cancel => {
                self.surface.clear();
                self.feed(event, now, &mut routed);
            }
            Contact::Down { id, position } => {
                // A reused id replaces a contact whose release never arrived.
                self.surface.remove(&id);
                match zone {
                    Zone::Workspace => {
                        if self.gesture.fingers().is_empty()
                            && let Some(taken) = self.resting(now)
                        {
                            let contact = self.surface.remove(&taken).unwrap();
                            routed.yielded.push(Yielded { id: taken, position: contact.position, mouse: contact.mouse });
                            self.feed(Contact::Down { id: taken, position: contact.position }, now, &mut routed);
                        }
                        self.feed(event, now, &mut routed);
                    }
                    Zone::Yielding if self.gesture.joinable() => self.feed(event, now, &mut routed),
                    _ => {
                        let mouse = self.surface.is_empty() && self.gesture.fingers().is_empty();
                        self.surface.insert(
                            id,
                            SurfaceContact { yielding: zone == Zone::Yielding, origin: position, position, started: now, moved: false, mouse },
                        );
                    }
                }
            }
            Contact::Move { id, position } => {
                if let Some(contact) = self.surface.get_mut(&id) {
                    contact.position = position;
                    contact.moved |= position.distance(contact.origin) >= SLOP;
                } else if self.gesture.fingers().contains_key(&id) {
                    self.feed(event, now, &mut routed);
                }
            }
            Contact::Up { id, .. } => {
                if self.surface.remove(&id).is_none() && self.gesture.fingers().contains_key(&id) {
                    self.feed(event, now, &mut routed);
                }
            }
        }
        routed
    }
    /// A surface contact lifted where the router could not see it.
    pub fn forget(&mut self, id: i32) {
        self.surface.remove(&id);
    }
    /// Abandon every contact, for focus loss or teardown.
    pub fn cancel(&mut self) -> Vec<Action> {
        self.surface.clear();
        self.gesture.cancel()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn down(id: i32, x: f32) -> Contact {
        Contact::Down { id, position: Vec2::new(x, 0.) }
    }
    fn pinches(routed: &Routed) -> bool {
        routed.actions.iter().any(|a| matches!(a, Action::Pinch { .. }))
    }
    #[test]
    fn resting_sidebar_contact_joins_a_workspace_contact_as_a_pinch() {
        let mut arena = TouchArena::default();
        assert_eq!(arena.handle(down(0, 10.), Zone::Yielding, 0), Routed::default());
        let routed = arena.handle(down(1, 300.), Zone::Workspace, 100);
        assert!(routed.workspace);
        assert_eq!(routed.yielded, [Yielded { id: 0, position: Vec2::new(10., 0.), mouse: true }]);
        assert_eq!(arena.gesture.fingers().len(), 2);
        // No press reaches the pane: the two contacts are a pinch from the start.
        assert!(!routed.actions.iter().any(|a| matches!(a, Action::Button { pressed: true, .. })));
        arena.gesture.advance(100 + SCROLL_GRACE_MS);
        let routed = arena.handle(Contact::Move { id: 0, position: Vec2::new(60., 0.) }, Zone::Workspace, 300);
        assert!(routed.workspace && pinches(&routed));
        for id in 0..2 {
            assert!(arena.handle(Contact::Up { id, position: Vec2::ZERO }, Zone::Workspace, 400).workspace);
        }
        assert!(arena.gesture.fingers().is_empty());
    }
    #[test]
    fn workspace_contact_takes_a_later_sidebar_contact_only_while_resting() {
        let mut arena = TouchArena::default();
        arena.handle(down(0, 300.), Zone::Workspace, 0);
        // The press is already committed, but the finger has not moved.
        arena.gesture.advance(PINCH_GRACE_MS);
        assert!(arena.gesture.held());
        let routed = arena.handle(down(1, 10.), Zone::Yielding, 200);
        assert!(routed.workspace && routed.yielded.is_empty());
        assert!(routed.actions.iter().any(|a| matches!(a, Action::Button { pressed: false, canceled: true, .. })));
        arena.cancel();

        // A drag under way keeps its pane; the sidebar keeps the second finger.
        arena.handle(down(0, 300.), Zone::Workspace, 1000);
        arena.gesture.advance(1000 + PINCH_GRACE_MS);
        arena.handle(Contact::Move { id: 0, position: Vec2::new(340., 0.) }, Zone::Workspace, 1200);
        let routed = arena.handle(down(1, 10.), Zone::Yielding, 1210);
        assert_eq!(routed, Routed::default());
        let routed = arena.handle(Contact::Move { id: 0, position: Vec2::new(360., 0.) }, Zone::Workspace, 1220);
        assert!(matches!(routed.actions[..], [Action::Motion { .. }]));
        assert!(!arena.handle(Contact::Move { id: 1, position: Vec2::new(10., 50.) }, Zone::Workspace, 1230).workspace);
        assert!(!arena.handle(Contact::Up { id: 1, position: Vec2::ZERO }, Zone::Workspace, 1240).workspace);
        assert!(arena.gesture.held());
    }
    #[test]
    fn decided_or_exclusive_surface_contacts_never_yield() {
        // Scrolling the sidebar, a long rest on it, or two fingers on it.
        for (moved, wait, extra) in [(true, 100, false), (false, YIELD_MS, false), (false, 100, true)] {
            let mut arena = TouchArena::default();
            arena.handle(down(0, 10.), Zone::Yielding, 0);
            if moved {
                arena.handle(Contact::Move { id: 0, position: Vec2::new(10., SLOP) }, Zone::Workspace, 50);
            }
            if extra {
                arena.handle(down(2, 20.), Zone::Yielding, 50);
            }
            let routed = arena.handle(down(1, 300.), Zone::Workspace, wait);
            assert!(routed.workspace && routed.yielded.is_empty());
            assert_eq!(arena.gesture.fingers().len(), 1);
        }
        let mut arena = TouchArena::default();
        arena.handle(down(0, 10.), Zone::Exclusive, 0);
        assert!(arena.handle(down(1, 300.), Zone::Workspace, 50).yielded.is_empty());
        // Nor does an exclusive control join a gesture already in the workspace.
        assert_eq!(arena.handle(down(2, 20.), Zone::Exclusive, 60), Routed::default());
        assert_eq!(arena.gesture.fingers().len(), 1);
    }
    #[test]
    fn only_the_first_contact_carries_the_emulated_mouse() {
        let mut arena = TouchArena::default();
        arena.handle(down(0, 500.), Zone::Exclusive, 0);
        arena.handle(down(1, 10.), Zone::Yielding, 10);
        assert_eq!(arena.handle(down(2, 300.), Zone::Workspace, 20).yielded, [Yielded { id: 1, position: Vec2::new(10., 0.), mouse: false }]);
    }
    #[test]
    fn unseen_release_and_reused_id_leave_no_stale_contact() {
        let mut arena = TouchArena::default();
        arena.handle(down(0, 10.), Zone::Yielding, 0);
        arena.forget(0);
        assert!(arena.handle(down(1, 300.), Zone::Workspace, 50).yielded.is_empty());
        arena.cancel();
        arena.handle(down(0, 10.), Zone::Yielding, 1000);
        // The same id lands again, in the workspace, without a release between.
        let routed = arena.handle(down(0, 300.), Zone::Workspace, 1050);
        assert!(routed.workspace && routed.yielded.is_empty());
        assert_eq!(arena.gesture.fingers().len(), 1);
    }
    fn swipe_chord(g: &mut TouchNavigation) {
        g.set_remote_swipe_width(400.);
        for id in 0..3 {
            g.handle(Contact::Down { id, position: Vec2::new(200., 50. + id as f32 * 30.) }, id as i64 * 10);
        }
    }
    #[test]
    fn horizontal_three_finger_swipe_commits_without_scroll_or_click() {
        let mut g = TouchNavigation::default();
        swipe_chord(&mut g);
        for id in 0..3 {
            let (_, actions) = g.handle(Contact::Move { id, position: Vec2::new(80., 50. + id as f32 * 30.) }, 100 + id as i64 * 10);
            assert!(actions.iter().all(|a| matches!(a, Action::RemoteSwipe { finished: false, .. })));
        }
        let (_, actions) = g.handle(Contact::Up { id: 0, position: Vec2::new(80., 50.) }, 130);
        assert!(actions.iter().any(|a| matches!(a, Action::RemoteSwipe { finished: true, commit: true, .. })));
        assert!(g.handle(Contact::Move { id: 1, position: Vec2::new(60., 90.) }, 140).1.is_empty());
        for id in 1..3 { g.handle(Contact::Up { id, position: Vec2::ZERO }, 150); }
        assert!(g.advance(200).is_empty());
    }
    #[test]
    fn short_swipe_and_cancel_do_not_commit() {
        let mut g = TouchNavigation::default();
        swipe_chord(&mut g);
        g.handle(Contact::Move { id: 0, position: Vec2::new(155., 50.) }, 300);
        assert!(g.cancel().iter().any(|a| matches!(a, Action::RemoteSwipe { finished: true, commit: false, .. })));
        swipe_chord(&mut g);
        g.handle(Contact::Move { id: 0, position: Vec2::new(155., 50.) }, 300);
        let (_, actions) = g.handle(Contact::Up { id: 0, position: Vec2::new(155., 50.) }, 500);
        assert!(actions.iter().any(|a| matches!(a, Action::RemoteSwipe { finished: true, commit: false, .. })));
    }
    #[test]
    fn vertical_three_finger_motion_still_scrolls_and_fourth_cancels_swipe() {
        let mut g = TouchNavigation::default();
        swipe_chord(&mut g);
        let (_, actions) = g.handle(Contact::Move { id: 0, position: Vec2::new(200., 110.) }, 100);
        assert!(actions.iter().any(|a| matches!(a, Action::Scroll { .. })));
        g.cancel();
        swipe_chord(&mut g);
        g.handle(Contact::Move { id: 0, position: Vec2::new(100., 50.) }, 100);
        let (_, actions) = g.handle(Contact::Down { id: 3, position: Vec2::ZERO }, 110);
        assert!(actions.iter().any(|a| matches!(a, Action::RemoteSwipe { finished: true, commit: false, .. })));
        g.handle(Contact::Up { id: 3, position: Vec2::ZERO }, 120);
        assert!(g.handle(Contact::Move { id: 0, position: Vec2::new(50., 50.) }, 140).1.is_empty());
    }
    #[test]
    fn pinch_survivor_and_rejoin_never_become_pointer_events() {
        let mut g = TouchNavigation::default();
        g.handle(
            Contact::Down {
                id: 0,
                position: Vec2::ZERO,
            },
            0,
        );
        g.handle(
            Contact::Down {
                id: 1,
                position: Vec2::new(100., 0.),
            },
            10,
        );
        g.advance(150);
        g.handle(
            Contact::Up {
                id: 1,
                position: Vec2::new(100., 0.),
            },
            160,
        );
        let (_, actions) = g.handle(
            Contact::Move {
                id: 0,
                position: Vec2::new(20., 0.),
            },
            170,
        );
        assert_eq!(
            actions,
            [Action::Pinch {
                previous: Vec2::ZERO,
                center: Vec2::new(20., 0.),
                factor: 1.
            }]
        );
        assert!(g.advance(1000).is_empty());
        assert!(
            g.handle(
                Contact::Down {
                    id: 7,
                    position: Vec2::new(120., 0.)
                },
                1010
            )
            .1
            .is_empty()
        );
        assert!(
            matches!(g.handle(Contact::Move{id:7,position:Vec2::new(140.,0.)},1020).1[0],Action::Pinch{factor,..} if (factor-1.2).abs()<1e-6)
        );
        g.cancel();
        assert!(g.fingers().is_empty());
    }
    #[test]
    fn clear_movement_commits_before_the_stationary_grace() {
        let mut g = TouchNavigation::default();
        g.set_drag_scroll(true);
        g.handle(
            Contact::Down {
                id: 0,
                position: Vec2::ZERO,
            },
            0,
        );
        let (_, early) = g.handle(
            Contact::Move {
                id: 0,
                position: Vec2::new(0., 30.),
            },
            30,
        );
        assert!(early.is_empty());
        assert_eq!(
            g.advance(MOVING_GRACE_MS),
            [Action::Scroll {
                anchor: Vec2::ZERO,
                delta: Vec2::new(0., 30.),
                stage: ScrollStage::Began,
            }]
        );
        assert!(g.cancel().contains(&Action::Scroll {
            anchor: Vec2::ZERO,
            delta: Vec2::ZERO,
            stage: ScrollStage::Ended,
        }));
        g.set_drag_scroll(false);
        g.handle(
            Contact::Down {
                id: 0,
                position: Vec2::ZERO,
            },
            1000,
        );
        g.handle(
            Contact::Down {
                id: 1,
                position: Vec2::new(100., 0.),
            },
            1010,
        );
        assert!(g.advance(1010 + MOVING_GRACE_MS).is_empty());
        g.handle(
            Contact::Move {
                id: 1,
                position: Vec2::new(150., 0.),
            },
            1020,
        );
        assert_eq!(
            g.advance(1010 + MOVING_GRACE_MS),
            [Action::Pinch {
                previous: Vec2::new(50., 0.),
                center: Vec2::new(75., 0.),
                factor: 1.5
            }]
        );
    }
    fn navigation_flick(g: &mut TouchNavigation, start: i64, contacts: i32) {
        let origin = |id| Vec2::new(id as f32 * 30., 100.);
        for id in 0..contacts {
            g.handle(
                Contact::Down {
                    id,
                    position: origin(id),
                },
                start,
            );
        }
        for elapsed in [20, 40, 60, 80] {
            for id in 0..contacts {
                let (_, actions) = g.handle(
                    Contact::Move {
                        id,
                        position: origin(id) + Vec2::Y * elapsed as f32,
                    },
                    start + elapsed,
                );
                assert!(actions.iter().all(|a| matches!(a, Action::Scroll { .. })));
            }
        }
        for id in 0..contacts {
            g.handle(
                Contact::Up {
                    id,
                    position: origin(id) + Vec2::Y * 80.,
                },
                start + 80,
            );
        }
    }

    #[test]
    fn recognizer_preserves_repeated_one_and_three_finger_flicks() {
        for contacts in [1, 3] {
            let mut g = TouchNavigation::default();
            g.set_drag_scroll(contacts == 1);
            navigation_flick(&mut g, 0, contacts);
            let single = g.scroll.velocity().y;
            assert!(single > 900. && single < 1300., "{single}");
            navigation_flick(&mut g, 180, contacts);
            // Chromium's booster adds the gliding flick's launch velocity.
            assert!((g.scroll.velocity().y - 2. * single).abs() < 1., "{}", g.scroll.velocity());
            g.cancel();
            navigation_flick(&mut g, 360, contacts);
            assert!((g.scroll.velocity().y - single).abs() < 0.5, "{}", g.scroll.velocity());
        }
    }

    #[test]
    fn braking_tap_consumes_the_click_and_the_repeat_candidate() {
        let mut g = TouchNavigation::default();
        g.set_drag_scroll(true);
        navigation_flick(&mut g, 0, 1);
        let down = g
            .handle(
                Contact::Down {
                    id: 0,
                    position: Vec2::ZERO,
                },
                100,
            )
            .1;
        assert!(down.is_empty());
        // The brake ends the fling's scroll; nothing else happens.
        assert_eq!(stages(&g.advance(120)), [ScrollStage::Ended]);
        assert_eq!(g.advance(121), []);
        let up = g
            .handle(
                Contact::Up {
                    id: 0,
                    position: Vec2::ZERO,
                },
                140,
            )
            .1;
        assert!(up.is_empty());
        navigation_flick(&mut g, 180, 1);
        let speed = g.scroll.velocity().y;
        assert!(speed > 900. && speed < 1300., "not boosted: {speed}");
    }

    #[test]
    fn pinch_discards_a_pending_repeat_candidate() {
        let mut g = TouchNavigation::default();
        g.set_drag_scroll(true);
        navigation_flick(&mut g, 0, 1);
        for id in 0..2 {
            g.handle(
                Contact::Down {
                    id,
                    position: Vec2::X * id as f32 * 100.,
                },
                100,
            );
        }
        g.advance(100 + SCROLL_GRACE_MS);
        assert!(g.navigating());
        assert!(!g.scroll.boosting());
        g.handle(
            Contact::Down {
                id: 2,
                position: Vec2::X * 200.,
            },
            230,
        );
        // Steady moves: Chromium treats a 40 ms gap as a finger that stopped.
        for step in 1..=4 {
            for id in 0..3 {
                g.handle(
                    Contact::Move {
                        id,
                        position: Vec2::new(id as f32 * 100., 20. * step as f32),
                    },
                    230 + 20 * step,
                );
            }
        }
        for id in 0..3 {
            g.handle(
                Contact::Up {
                    id,
                    position: Vec2::new(id as f32 * 100., 80.),
                },
                310,
            );
        }
        let speed = g.scroll.velocity().y;
        assert!(speed > 900. && speed < 1500., "not boosted: {speed}");
    }

    fn stages(actions: &[Action]) -> Vec<ScrollStage> {
        actions
            .iter()
            .filter_map(|action| match action {
                Action::Scroll { stage, .. } => Some(*stage),
                _ => None,
            })
            .collect()
    }
    #[test]
    fn a_slow_tap_still_clicks_until_the_long_press() {
        let presses = |actions: &[Action]| {
            actions
                .iter()
                .filter(|action| matches!(action, Action::Button { button: Button::Left, pressed: true, .. }))
                .count()
        };
        let mut g = TouchNavigation::default();
        g.set_drag_scroll(true);
        g.handle(Contact::Down { id: 0, position: Vec2::ZERO }, 0);
        assert!(g.advance(HOLD_MS - 50).is_empty());
        let up = g.handle(Contact::Up { id: 0, position: Vec2::ZERO }, HOLD_MS - 40).1;
        assert_eq!(presses(&up), 1, "a deliberate tap is a click");
        // Held until the long press, the lift adds no click.
        g.handle(Contact::Down { id: 0, position: Vec2::ZERO }, 2000);
        let held = g.advance(2000 + HOLD_MS);
        assert!(held.iter().any(|action| matches!(action, Action::Button { button: Button::Right, .. })));
        let up = g.handle(Contact::Up { id: 0, position: Vec2::ZERO }, 2000 + HOLD_MS + 20).1;
        assert_eq!(presses(&up), 0);
    }
    #[test]
    fn a_drag_scroll_reports_its_begin_travel_momentum_and_end() {
        use ScrollStage::*;
        let mut g = TouchNavigation::default();
        g.set_drag_scroll(true);
        // A slow drag that rests before lifting ends with the lift.
        g.handle(Contact::Down { id: 0, position: Vec2::ZERO }, 0);
        let mut seen = vec![];
        for step in 1..=5 {
            let position = Vec2::new(0., step as f32 * 20.);
            seen.extend(stages(&g.handle(Contact::Move { id: 0, position }, 40 + step * 16).1));
        }
        seen.extend(stages(&g.handle(Contact::Up { id: 0, position: Vec2::new(0., 100.) }, 500).1));
        assert_eq!(seen.first(), Some(&Began));
        assert_eq!(seen.last(), Some(&Ended));
        assert!(seen[1..seen.len() - 1].iter().all(|stage| *stage == Changed));
        assert!(stages(&g.advance(520)).is_empty());
        // A flick carries on as momentum and ends when it runs out.
        g.handle(Contact::Down { id: 0, position: Vec2::ZERO }, 1000);
        let mut seen = vec![];
        for step in 1..=5 {
            let position = Vec2::new(0., step as f32 * 20.);
            seen.extend(stages(&g.handle(Contact::Move { id: 0, position }, 1040 + step * 16).1));
        }
        seen.extend(stages(&g.handle(Contact::Up { id: 0, position: Vec2::new(0., 100.) }, 1121).1));
        assert_eq!(seen.first(), Some(&Began));
        assert!(!seen.contains(&Ended), "momentum follows the lift");
        let mut flung = vec![];
        for frame in 1..400 {
            flung.extend(stages(&g.advance(1121 + frame * 16)));
        }
        assert!(flung.len() > 2);
        assert_eq!(flung.iter().filter(|stage| **stage == Ended).count(), 1);
        assert_eq!(flung.last(), Some(&Ended));
        assert!(flung[..flung.len() - 1].iter().all(|stage| *stage == Momentum));
        // Touching moving content stops it, which ends that gesture too.
        g.handle(Contact::Down { id: 0, position: Vec2::ZERO }, 9000);
        for step in 1..=5 {
            g.handle(Contact::Move { id: 0, position: Vec2::new(0., step as f32 * 20.) }, 9040 + step * 16);
        }
        g.handle(Contact::Up { id: 0, position: Vec2::new(0., 100.) }, 9121);
        assert_eq!(stages(&g.advance(9137)), [Momentum]);
        g.handle(Contact::Down { id: 0, position: Vec2::ZERO }, 9140);
        assert_eq!(stages(&g.advance(9150)), [Ended]);
    }
    #[test]
    fn fling_integrates_the_same_distance_across_frame_rates() {
        fn run(step: i64) -> f32 {
            let mut m = ScrollMotion::default();
            m.begin(0);
            m.track(Vec2::new(100., 0.), 100);
            m.release(100);
            let mut x = 0.;
            for now in (100 + step..2000).step_by(step as usize) {
                x += m.advance(now).x;
            }
            x
        }
        assert!((run(8) - run(33)).abs() < 0.01);
    }
}
