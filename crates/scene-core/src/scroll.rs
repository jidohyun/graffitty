//! Pixel scroll presentation over an unchanged, row-based terminal viewport.
/// Match macOS WezTerm's precision-device distance, independent of font size.
pub const PIXELS_PER_ROW: f64 = 15.0;

/// The new top row and fraction, and the rows the viewport could not consume
/// (positive past the bottom, negative past the top).
pub fn position(top: usize, fraction: f64, rows_up: f64, max: usize) -> (usize, f64, f64) {
    let wanted = top as f64 + fraction - rows_up;
    let position = wanted.clamp(0.0, max as f64);
    (position.floor() as usize, position.fract(), wanted - position)
}

/// How a platform's rubber band behaves, as Chromium configures it there.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ElasticConfig {
    pub curve: Curve,
    /// Whether content with nothing to scroll can still be pulled.
    pub pulls_unscrollable: bool,
    /// Android stretches the content from the pulled edge; others shift it.
    pub scales: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Curve {
    /// A linear pull released on a critically damped spring.
    Exponential { amplitude: f64, period: f64 },
    /// Windows: a saturating pull released on cubic bezier bounces.
    Bezier,
}

impl ElasticConfig {
    pub const APPLE: Self = Self {
        curve: Curve::Exponential { amplitude: 0.31, period: 1.6 },
        pulls_unscrollable: true,
        scales: false,
    };
    pub const ANDROID: Self = Self {
        curve: Curve::Exponential { amplitude: 0.2, period: 1.1 },
        pulls_unscrollable: false,
        scales: true,
    };
    pub const WINDOWS: Self = Self { curve: Curve::Bezier, pulls_unscrollable: true, scales: false };

    /// What Chromium itself uses on the platform this was built for.
    pub const fn native() -> Self {
        if cfg!(target_os = "android") {
            Self::ANDROID
        } else if cfg!(target_os = "windows") {
            Self::WINDOWS
        } else {
            Self::APPLE
        }
    }

    /// What terminals use: the Apple rubber band on every platform, so the
    /// content shifts the same way everywhere and even a screen with nothing
    /// to scroll can be pulled both ways. Switch to `native()` to follow each
    /// platform instead.
    pub const fn terminal() -> Self {
        Self::APPLE
    }
}

/// The scroller as the rubber band sees it, in scroll pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Scroller {
    pub offset: f64,
    pub max: f64,
    /// Visible height, which bounds the Windows stretch.
    pub bounds: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Inactive,
    ActiveScroll,
    MomentumScroll,
    MomentumAnimated,
}

const STIFFNESS: f64 = 20.0;
const VELOCITY_ZEROING_SECS: f64 = 0.1;
const MINIMUM_DELTA_BEFORE_STRETCH: f64 = 10.0;
const BEZIER_BOUNDARY: f64 = 0.1;
const BEZIER_IGNORE_VELOCITY: f64 = 200.0;
const BEZIER_OVERBOUNCE_DISTANCE: f64 = 35.0;

/// Chromium's `ElasticOverscrollController` for one vertical scroller.
///
/// Deltas and the stretch are positive toward the bottom of the content.
/// Chromium rounds the stretch to whole pixels for Blink; this keeps fractions.
#[derive(Clone, Debug)]
pub struct Elastic {
    config: ElasticConfig,
    state: State,
    stretch: f64,
    force: f64,
    pending: f64,
    velocity: f64,
    last_event: Option<f64>,
    in_momentum: bool,
    start: f64,
    initial_stretch: f64,
    initial_velocity: f64,
    residual_velocity: f64,
    forward_distance: f64,
    forward_secs: f64,
    backward_secs: f64,
    /// The scroller height the current stretch was mapped against.
    bounds: f64,
}

impl Elastic {
    pub fn new(config: ElasticConfig) -> Self {
        Self {
            config,
            state: State::Inactive,
            stretch: 0.0,
            force: 0.0,
            pending: 0.0,
            velocity: 0.0,
            last_event: None,
            in_momentum: false,
            start: 0.0,
            initial_stretch: 0.0,
            initial_velocity: 0.0,
            residual_velocity: 0.0,
            forward_distance: 0.0,
            forward_secs: 0.0,
            backward_secs: 0.0,
            bounds: 0.0,
        }
    }

    pub fn config(&self) -> ElasticConfig {
        self.config
    }

    pub fn stretch(&self) -> f64 {
        self.stretch
    }

    /// Whether `animate` still has a release to play.
    pub fn animating(&self) -> bool {
        self.state == State::MomentumAnimated
    }

    /// Whether a gesture that `end` would finish is under way.
    pub fn scrolling(&self) -> bool {
        matches!(self.state, State::ActiveScroll | State::MomentumScroll)
    }

    pub fn reset(&mut self) {
        *self = Self::new(self.config);
    }

    /// A scroll sequence began: under the fingers, or as momentum alone.
    pub fn begin(&mut self, momentum: bool) {
        if momentum {
            if self.state == State::Inactive {
                self.state = State::MomentumScroll;
            }
        } else {
            self.velocity = 0.0;
            self.last_event = None;
            self.state = State::ActiveScroll;
            self.pending = 0.0;
        }
    }

    /// `delta` is what the event asked for and `unused` what the scroller,
    /// now at `scroller.offset`, could not take.
    pub fn update(&mut self, delta: f64, unused: f64, event_time: f64, now: f64, momentum: bool, scroller: Scroller) {
        if matches!(self.state, State::MomentumAnimated | State::Inactive) {
            return;
        }
        // The event that switches to momentum arrives too soon after the last
        // finger event to give a true velocity.
        if !momentum || self.in_momentum {
            let elapsed = self.last_event.map_or(f64::INFINITY, |last| event_time - last);
            self.velocity = if elapsed > 0.0 && elapsed < VELOCITY_ZEROING_SECS { delta / elapsed } else { 0.0 };
            self.last_event = Some(event_time);
        }
        self.in_momentum = momentum;
        self.overscroll(unused, scroller);
        if momentum && self.stretch != 0.0 {
            self.enter_animated(now, scroller);
        }
    }

    pub fn end(&mut self, now: f64, scroller: Scroller) {
        if matches!(self.state, State::MomentumAnimated | State::Inactive) {
            return;
        }
        if self.stretch == 0.0 {
            self.enter_inactive();
        } else {
            self.enter_animated(now, scroller);
        }
    }

    /// Advance a release. Returns whether the stretch changed.
    pub fn animate(&mut self, now: f64) -> bool {
        if self.state != State::MomentumAnimated {
            return false;
        }
        let stretch = self.stretch_at((now - self.start).max(0.0));
        if stretch.abs() < 1.0 {
            self.stretch = 0.0;
            self.enter_inactive();
        } else {
            self.force = self.overscroll_for(stretch);
            self.stretch = stretch;
        }
        true
    }

    /// Content moved off the pulled edge: trade stretch for scroll offset.
    /// Returns the amount to subtract from the offset.
    pub fn reconcile(&mut self, scroller: Scroller) -> f64 {
        let adjustment = if self.stretch < 0.0 && scroller.offset > 0.0 {
            (-self.stretch).min(scroller.offset)
        } else if self.stretch > 0.0 && scroller.offset < scroller.max {
            (-self.stretch).max(scroller.offset - scroller.max)
        } else {
            return 0.0;
        };
        self.stretch += adjustment;
        if self.state == State::ActiveScroll {
            self.force = self.overscroll_for(self.stretch);
        }
        adjustment
    }

    fn overscroll(&mut self, unused: f64, scroller: Scroller) {
        if unused == 0.0 {
            return;
        }
        let mut delta = unused + self.pending;
        self.pending = 0.0;
        if !self.config.pulls_unscrollable && scroller.max <= 0.0 {
            delta = 0.0;
        }
        // Only an edge the scroller is resting on can be pulled.
        let pinned = if delta < 0.0 {
            scroller.offset <= 0.0
        } else {
            delta > 0.0 && scroller.offset >= scroller.max
        };
        if !pinned {
            delta = 0.0;
        }
        // Stray motion at an edge must not start a stretch.
        if self.stretch == 0.0 && delta.abs() < MINIMUM_DELTA_BEFORE_STRETCH {
            self.pending = delta;
            return;
        }
        if delta == 0.0 {
            return;
        }
        self.force += delta;
        self.stretch = self.stretch_for(self.force, scroller.bounds);
        self.bounds = scroller.bounds;
    }

    fn enter_inactive(&mut self) {
        self.state = State::Inactive;
        self.force = 0.0;
    }

    fn enter_animated(&mut self, now: f64, scroller: Scroller) {
        self.state = State::MomentumAnimated;
        self.start = now;
        self.initial_stretch = self.stretch;
        self.initial_velocity = if scroller.max > 0.0 { self.velocity } else { 0.0 };
        if self.config.curve == Curve::Bezier {
            // Pixels per millisecond; a slow lift plays no forward bounce.
            let velocity = if self.velocity.abs() > BEZIER_IGNORE_VELOCITY { self.velocity / 1000.0 } else { 0.0 };
            self.residual_velocity = velocity;
            let forward = velocity.abs().sqrt() * BEZIER_OVERBOUNCE_DISTANCE;
            let distance = (scroller.bounds * BEZIER_BOUNDARY).min(self.initial_stretch.abs() + forward);
            self.forward_distance =
                distance.copysign(if self.initial_stretch == 0.0 { velocity } else { self.initial_stretch });
            self.forward_secs = (2.5 * forward).min(150.0) / 1000.0;
            self.backward_secs = (15.0 * distance).min(300.0) / 1000.0;
        }
    }

    fn stretch_for(&self, overscroll: f64, bounds: f64) -> f64 {
        match self.config.curve {
            Curve::Exponential { .. } => overscroll / STIFFNESS,
            Curve::Bezier if bounds > 0.0 => (2.0 * overscroll / bounds).tanh() * bounds * BEZIER_BOUNDARY,
            Curve::Bezier => 0.0,
        }
    }

    fn overscroll_for(&self, stretch: f64) -> f64 {
        match self.config.curve {
            Curve::Exponential { .. } => stretch * STIFFNESS,
            Curve::Bezier if self.bounds > 0.0 => {
                // The forward bounce may reach the boundary, where atanh diverges.
                let ratio = (stretch / (self.bounds * BEZIER_BOUNDARY)).clamp(-0.999_999, 0.999_999);
                ratio.atanh() / 2.0 * self.bounds
            }
            Curve::Bezier => 0.0,
        }
    }

    fn stretch_at(&self, elapsed: f64) -> f64 {
        match self.config.curve {
            Curve::Exponential { amplitude, period } => {
                (self.initial_stretch + self.initial_velocity * elapsed * amplitude)
                    * (-elapsed * STIFFNESS / period).exp()
            }
            Curve::Bezier => {
                if elapsed < self.forward_secs {
                    let progress = velocity_bezier(self.residual_velocity, 0.25, 1.0, 0.99, 1.0)
                        .solve(elapsed / self.forward_secs);
                    let stretch = self.initial_stretch * (1.0 - progress) + self.forward_distance * progress;
                    if stretch.round() != 0.0 {
                        return stretch;
                    }
                }
                let elapsed = elapsed - self.forward_secs;
                if elapsed < self.backward_secs {
                    let progress = velocity_bezier(self.residual_velocity, 0.05, 0.7, 0.25, 1.0)
                        .solve(elapsed / self.backward_secs);
                    self.forward_distance * (1.0 - progress)
                } else {
                    0.0
                }
            }
        }
    }
}

/// Scale the first control point by the release velocity (pixels per millisecond).
fn velocity_bezier(velocity: f64, x1: f64, y1: f64, x2: f64, y2: f64) -> CubicBezier {
    let velocity = velocity.abs();
    if x1 * velocity < y1 {
        CubicBezier { x1, y1: x1 * velocity, x2, y2 }
    } else {
        CubicBezier { x1: y1 / velocity, y1, x2, y2 }
    }
}

struct CubicBezier {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
}

impl CubicBezier {
    fn sample(a: f64, b: f64, t: f64) -> f64 {
        let inverse = 1.0 - t;
        3.0 * inverse * inverse * t * a + 3.0 * inverse * t * t * b + t * t * t
    }

    /// The curve's y where its x equals `x`. x is monotonic for control
    /// points within 0..=1, so bisection converges.
    fn solve(&self, x: f64) -> f64 {
        let x = x.clamp(0.0, 1.0);
        let (mut low, mut high) = (0.0, 1.0);
        for _ in 0..48 {
            let middle = (low + high) / 2.0;
            if Self::sample(self.x1, self.x2, middle) < x {
                low = middle;
            } else {
                high = middle;
            }
        }
        Self::sample(self.y1, self.y2, (low + high) / 2.0)
    }
}

/// One phased scroll event, as Chromium's rubber band reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ScrollGesture {
    pub began: bool,
    pub ended: bool,
    /// Inertia after the fingers lifted, not finger travel.
    pub momentum: bool,
    /// The platform's event time in seconds, where frame time would blur the
    /// release velocity.
    pub time: Option<f64>,
    /// Wait for momentum before treating this end as final.
    pub hold_end: bool,
}

/// A rubber band and the gesture bookkeeping around it.
///
/// Terminals, mod lists and Godot scrollers drive one each, so a pull past
/// either end stretches and springs back the same way everywhere.
#[derive(Clone, Debug)]
pub struct ElasticGesture {
    pub elastic: Elastic,
    /// When a finger lift not followed by momentum ends the gesture.
    end_at: Option<f64>,
}

impl ElasticGesture {
    pub fn new(config: ElasticConfig) -> Self {
        Self { elastic: Elastic::new(config), end_at: None }
    }

    /// Whether the band is pulled, playing a release, or waiting for one.
    pub fn active(&self) -> bool {
        self.elastic.stretch() != 0.0 || self.elastic.animating() || self.elastic.scrolling() || self.end_at.is_some()
    }

    /// `allowed` is false where the content cannot be pulled at all.
    pub fn began(&mut self, gesture: ScrollGesture, allowed: bool) {
        if !gesture.began {
            return;
        }
        if !allowed {
            self.elastic.reset();
        } else if !gesture.momentum {
            self.end_at = None;
            self.elastic.begin(false);
        } else if self.end_at.take().is_none() && !self.elastic.scrolling() {
            self.elastic.begin(true);
        }
    }

    pub fn ended(&mut self, gesture: ScrollGesture, now: f64, scroller: Scroller) {
        if !gesture.ended {
            return;
        }
        if gesture.hold_end {
            self.end_at = Some(now + 0.1);
        } else {
            self.end_at = None;
            self.elastic.end(now, scroller);
        }
    }

    /// End a gesture whose phases stopped arriving, such as a Wayland finger
    /// scroll the compositor reported as stopped.
    pub fn end(&mut self, now: f64, scroller: Scroller) {
        self.end_at = None;
        self.elastic.end(now, scroller);
    }

    /// Advance the rubber band. Returns whether the pull changed.
    pub fn tick(&mut self, now: f64, scroller: Scroller, allowed: bool) -> bool {
        if self.end_at.is_some_and(|at| now >= at) {
            self.end(now, scroller);
        }
        if self.elastic.stretch() != 0.0 && !allowed {
            self.elastic.reset();
            return true;
        }
        self.elastic.animate(now)
    }

    /// Scroll a pixel scroller by `delta`, positive toward the bottom, from
    /// `offset` in `0..=max`; `bounds` is the visible extent. Returns the new
    /// offset. Phased motion past an edge pulls the band; a plain wheel
    /// (`gesture` none) only scrolls.
    pub fn scroll(&mut self, offset: f64, max: f64, bounds: f64, delta: f64, gesture: Option<ScrollGesture>, now: f64) -> f64 {
        let max = max.max(0.0);
        if let Some(gesture) = gesture {
            self.began(gesture, true);
        }
        let wanted = offset + delta;
        let mut position = wanted.clamp(0.0, max);
        if let Some(gesture) = gesture {
            if delta != 0.0 {
                let at = Scroller { offset: position, max, bounds };
                self.elastic.update(delta, wanted - position, gesture.time.unwrap_or(now), now, gesture.momentum, at);
                // Scrolling away from a pulled edge first lets the pull go.
                position = (position - self.elastic.reconcile(at)).clamp(0.0, max);
            }
            self.ended(gesture, now, Scroller { offset: position, max, bounds });
        }
        position
    }
}

/// A scrollbar thumb as `(start, length)` along a `track`, macOS style.
///
/// `page` of `max + page` content shows from `offset` (any one unit). At rest
/// this is Godot's own layout, so a drawn thumb matches the one a pointer
/// grabs: `min_length` plus the page's share of the rest of the track. A
/// rubber-band `stretch` (either sign) leaves that share of the view empty; the
/// thumb shortens by it and stays against the pulled end.
pub fn scroll_thumb(track: f64, offset: f64, max: f64, page: f64, stretch: f64, min_length: f64) -> (f64, f64) {
    let (max, page) = (max.max(0.0), page.max(0.0));
    let content = max + page;
    if track <= 0.0 || content <= 0.0 {
        return (0.0, track.max(0.0));
    }
    let min_length = min_length.clamp(0.0, track);
    let resting = (min_length + (track - min_length) * page / content).min(track);
    let shown = if page > 0.0 { ((page - stretch.abs()) / page).clamp(0.0, 1.0) } else { 1.0 };
    let length = (resting * shown).max(min_length.min(resting) * 0.5);
    let ratio = if max > 0.0 { (offset / max).clamp(0.0, 1.0) } else if stretch > 0.0 { 1.0 } else { 0.0 };
    ((track - length) * ratio, length)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tiny_input_moves_immediately_and_reverses_without_dead_zone() {
        let (top, fraction, unused) = position(100, 0.0, 0.1, 100);
        assert_eq!(top, 99);
        assert!((fraction - 0.9).abs() < 1e-10);
        assert_eq!(unused, 0.0);
        let (top, fraction, _) = position(top, fraction, -0.05, 100);
        assert_eq!(top, 99);
        assert!((fraction - 0.95).abs() < 1e-10);
    }
    #[test]
    fn boundaries_clamp_and_report_the_unused_rows() {
        assert_eq!(position(0, 0.1, 3.0, 100), (0, 0.0, -2.9));
        let (top, fraction, unused) = position(99, 0.9, -3.0, 100);
        assert_eq!((top, fraction), (100, 0.0));
        assert!((unused - 2.9).abs() < 1e-10);
        assert_eq!(position(0, 0.0, 0.1, 0), (0, 0.0, -0.1));
    }
    #[test]
    fn equal_finger_distance_means_equal_rows_at_any_font_size() {
        assert_eq!(position(100, 0.0, 150.0 / PIXELS_PER_ROW, 100), (90, 0.0, 0.0));
    }

    const TOP: Scroller = Scroller { offset: 0.0, max: 1500.0, bounds: 600.0 };
    const BOTTOM: Scroller = Scroller { offset: 1500.0, max: 1500.0, bounds: 600.0 };

    /// Drag `count` events of `delta` past an edge, 8 ms apart from `time`.
    fn drag(elastic: &mut Elastic, scroller: Scroller, delta: f64, count: usize, time: f64) -> f64 {
        let mut time = time;
        for _ in 0..count {
            time += 0.008;
            elastic.update(delta, delta, time, time, false, scroller);
        }
        time
    }

    #[test]
    fn unphased_scrolling_never_stretches() {
        let mut elastic = Elastic::new(ElasticConfig::APPLE);
        elastic.update(-40.0, -40.0, 1.0, 1.0, false, TOP);
        elastic.end(1.0, TOP);
        assert_eq!(elastic.stretch(), 0.0);
        assert!(!elastic.animate(1.1));
    }

    #[test]
    fn a_pull_follows_the_fingers_at_one_twentieth() {
        let mut elastic = Elastic::new(ElasticConfig::APPLE);
        elastic.begin(false);
        drag(&mut elastic, TOP, -20.0, 10, 0.0);
        assert!((elastic.stretch() + 10.0).abs() < 1e-9);
    }

    #[test]
    fn stray_motion_at_an_edge_is_held_until_ten_pixels() {
        let mut elastic = Elastic::new(ElasticConfig::APPLE);
        elastic.begin(false);
        elastic.update(-4.0, -4.0, 0.0, 0.0, false, TOP);
        assert_eq!(elastic.stretch(), 0.0);
        elastic.update(-4.0, -4.0, 0.01, 0.01, false, TOP);
        assert_eq!(elastic.stretch(), 0.0);
        elastic.update(-4.0, -4.0, 0.02, 0.02, false, TOP);
        assert!((elastic.stretch() + 0.6).abs() < 1e-9);
    }

    #[test]
    fn only_the_resting_edge_can_be_pulled() {
        let mut elastic = Elastic::new(ElasticConfig::APPLE);
        elastic.begin(false);
        let middle = Scroller { offset: 700.0, ..TOP };
        drag(&mut elastic, middle, -50.0, 4, 0.0);
        assert_eq!(elastic.stretch(), 0.0);
    }

    #[test]
    fn release_springs_back_and_goes_inactive() {
        let mut elastic = Elastic::new(ElasticConfig::APPLE);
        elastic.begin(false);
        let time = drag(&mut elastic, BOTTOM, 40.0, 10, 0.0);
        assert!((elastic.stretch() - 20.0).abs() < 1e-9);
        // A rest before lifting leaves no velocity.
        elastic.update(1.0, 1.0, time + 0.5, time + 0.5, false, BOTTOM);
        assert!((elastic.stretch() - 20.05).abs() < 1e-9);
        elastic.end(time + 0.5, BOTTOM);
        assert!(elastic.animating());
        assert!(elastic.animate(time + 0.5 + 0.08));
        let expected = 20.05 * (-0.08f64 * 20.0 / 1.6).exp();
        assert!((elastic.stretch() - expected).abs() < 1e-9);
        assert!(elastic.animate(time + 2.0));
        assert_eq!(elastic.stretch(), 0.0);
        assert!(!elastic.animating());
        // Scrolling during the release is ignored until a new gesture begins.
        elastic.update(40.0, 40.0, time + 3.0, time + 3.0, false, BOTTOM);
        assert_eq!(elastic.stretch(), 0.0);
    }

    #[test]
    fn momentum_into_an_edge_bounces_out_and_back() {
        let mut elastic = Elastic::new(ElasticConfig::APPLE);
        elastic.begin(true);
        // Two momentum events establish the velocity; the second hits the edge.
        elastic.update(-30.0, 0.0, 0.0, 0.0, true, Scroller { offset: 30.0, ..TOP });
        elastic.update(-30.0, 0.0, 0.008, 0.008, true, TOP);
        elastic.update(-30.0, -30.0, 0.016, 0.016, true, TOP);
        assert!(elastic.animating());
        let start = elastic.stretch();
        assert!((start + 1.5).abs() < 1e-9);
        assert!(elastic.animate(0.016 + 0.05));
        assert!(elastic.stretch() < start * 10.0, "velocity carries the stretch further");
        assert!(elastic.animate(3.0));
        assert_eq!(elastic.stretch(), 0.0);
    }

    #[test]
    fn momentum_while_pulled_releases_at_once() {
        let mut elastic = Elastic::new(ElasticConfig::APPLE);
        elastic.begin(false);
        let time = drag(&mut elastic, TOP, -40.0, 5, 0.0);
        elastic.update(-40.0, -40.0, time + 0.008, time + 0.008, true, TOP);
        assert!(elastic.animating());
    }

    #[test]
    fn scrolling_off_a_pulled_edge_trades_stretch_for_offset() {
        let mut elastic = Elastic::new(ElasticConfig::APPLE);
        elastic.begin(false);
        drag(&mut elastic, TOP, -40.0, 5, 0.0);
        assert!((elastic.stretch() + 10.0).abs() < 1e-9);
        assert_eq!(elastic.reconcile(Scroller { offset: 4.0, ..TOP }), 4.0);
        assert!((elastic.stretch() + 6.0).abs() < 1e-9);
        assert_eq!(elastic.reconcile(Scroller { offset: 30.0, ..TOP }), 6.0);
        assert_eq!(elastic.stretch(), 0.0);
    }

    #[test]
    fn android_leaves_unscrollable_content_alone() {
        let empty = Scroller { offset: 0.0, max: 0.0, bounds: 600.0 };
        let mut android = Elastic::new(ElasticConfig::ANDROID);
        android.begin(false);
        drag(&mut android, empty, -40.0, 5, 0.0);
        assert_eq!(android.stretch(), 0.0);
        let mut apple = Elastic::new(ElasticConfig::APPLE);
        apple.begin(false);
        drag(&mut apple, empty, -40.0, 5, 0.0);
        assert!((apple.stretch() + 10.0).abs() < 1e-9);
    }

    #[test]
    fn windows_pull_saturates_at_a_tenth_of_the_scroller() {
        let mut elastic = Elastic::new(ElasticConfig::WINDOWS);
        elastic.begin(false);
        drag(&mut elastic, BOTTOM, 30.0, 1, 0.0);
        assert!((elastic.stretch() - (2.0f64 * 30.0 / 600.0).tanh() * 60.0).abs() < 1e-9);
        let time = drag(&mut elastic, BOTTOM, 300.0, 20, 1.0);
        assert!(elastic.stretch() <= 60.0 && elastic.stretch() > 59.9);
        // A rested lift bounces straight back within 300 ms.
        elastic.update(0.0, 0.0, time + 0.5, time + 0.5, false, BOTTOM);
        elastic.end(time + 0.5, BOTTOM);
        let before = elastic.stretch();
        assert!(elastic.animate(time + 0.5 + 0.05));
        assert!(elastic.stretch() < before && elastic.stretch() > 0.0);
        assert!(elastic.animate(time + 0.5 + 0.31));
        assert_eq!(elastic.stretch(), 0.0);
        assert!(!elastic.animating());
    }

    #[test]
    fn windows_fling_bounces_forward_first() {
        let mut elastic = Elastic::new(ElasticConfig::WINDOWS);
        elastic.begin(false);
        // 30 px every 8 ms is 3750 px/s, above the 200 px/s threshold.
        let time = drag(&mut elastic, BOTTOM, 30.0, 2, 0.0);
        let pulled = elastic.stretch();
        elastic.end(time, BOTTOM);
        assert!(elastic.animate(time + 0.1));
        assert!(elastic.stretch() > pulled);
        assert!(elastic.animate(time + 1.0));
        assert_eq!(elastic.stretch(), 0.0);
    }

    #[test]
    fn bezier_solver_matches_its_end_points_and_a_straight_line() {
        let line = CubicBezier { x1: 0.25, y1: 0.25, x2: 0.75, y2: 0.75 };
        for x in [0.0, 0.2, 0.5, 0.9, 1.0] {
            assert!((line.solve(x) - x).abs() < 1e-9);
        }
    }

    fn phase(began: bool, ended: bool, time: f64) -> Option<ScrollGesture> {
        Some(ScrollGesture { began, ended, momentum: false, time: Some(time), hold_end: false })
    }

    #[test]
    fn pixel_scroller_pulls_past_an_edge_and_springs_back() {
        let mut band = ElasticGesture::new(ElasticConfig::APPLE);
        let mut offset = band.scroll(40.0, 400.0, 300.0, -10.0, phase(true, false, 0.0), 0.0);
        assert_eq!(offset, 30.0, "inside the range it only scrolls");
        for step in 1..=10 {
            let t = step as f64 * 0.016;
            offset = band.scroll(offset, 400.0, 300.0, -20.0, phase(false, false, t), t);
        }
        assert_eq!(offset, 0.0, "the scroller rests on its top edge");
        assert!(band.elastic.stretch() < 0.0, "the rest of the pull stretches past the top");
        let pulled = band.elastic.stretch();
        offset = band.scroll(offset, 400.0, 300.0, 5.0, phase(false, false, 0.2), 0.2);
        assert_eq!(offset, 0.0, "scrolling back first lets the pull go");
        assert!(band.elastic.stretch() > pulled);
        band.scroll(offset, 400.0, 300.0, 0.0, phase(false, true, 0.21), 0.21);
        let mut t = 0.21;
        while band.active() && t < 5.0 {
            t += 0.016;
            band.tick(t, Scroller { offset: 0.0, max: 400.0, bounds: 300.0 }, true);
        }
        assert_eq!(band.elastic.stretch(), 0.0, "the release returns to rest");
        assert!(!band.active());
    }

    #[test]
    fn wheel_scrolling_never_stretches() {
        let mut band = ElasticGesture::new(ElasticConfig::APPLE);
        assert_eq!(band.scroll(5.0, 100.0, 50.0, -50.0, None, 0.0), 0.0);
        assert_eq!(band.elastic.stretch(), 0.0);
        assert_eq!(band.scroll(95.0, 100.0, 50.0, 50.0, None, 0.0), 100.0);
        assert!(!band.active());
    }

    #[test]
    fn thumbs_rest_like_godot_and_shrink_against_a_pulled_end() {
        // Godot: start = (track - min) * offset / content, length = min + (track - min) * page / content.
        let (start, length) = scroll_thumb(200.0, 300.0, 600.0, 200.0, 0.0, 20.0);
        assert!((start - 180.0 * 300.0 / 800.0).abs() < 1e-9 && (length - (20.0 + 180.0 * 0.25)).abs() < 1e-9);
        assert_eq!(scroll_thumb(200.0, 600.0, 600.0, 200.0, 0.0, 20.0).0 + length, 200.0, "the end touches the track's end");
        let (top, pulled) = scroll_thumb(200.0, 0.0, 600.0, 200.0, -50.0, 20.0);
        assert_eq!(top, 0.0, "a pull at the top keeps the thumb on the top");
        assert!((pulled - length * 0.75).abs() < 1e-9, "a quarter of the view pulled empty takes a quarter off");
        let (bottom, shorter) = scroll_thumb(200.0, 600.0, 600.0, 200.0, 50.0, 20.0);
        assert!((bottom + shorter - 200.0).abs() < 1e-9, "a pull at the bottom keeps it on the bottom");
        assert_eq!(scroll_thumb(200.0, 0.0, 600.0, 200.0, -1000.0, 20.0).1, 10.0, "it never vanishes");
        assert_eq!(scroll_thumb(200.0, 0.0, 0.0, 200.0, 40.0, 20.0).0 + scroll_thumb(200.0, 0.0, 0.0, 200.0, 40.0, 20.0).1, 200.0, "content that fits still shows the pull");
    }
}
