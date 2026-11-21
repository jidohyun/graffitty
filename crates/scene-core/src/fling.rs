//! Finger flings: Chromium's touch handling with Apple's glide, to match the
//! Apple rubber band every scroller uses (`scroll::ElasticConfig::terminal`).
//!
//! - Release velocity: Chromium's `ui/events/velocity_tracker` (default
//!   `LSQ2`, a quadratic least-squares fit over the last 100 ms).
//! - Fling start: Chromium's `ui/events/gesture_detection/gesture_detector.cc`
//!   with Android's `ViewConfiguration` limits.
//! - Glide: UIScrollView's normal deceleration, velocity × 0.998 per
//!   millisecond. (Chromium itself uses Android's OverScroller spline here.)
//! - Repeated flicks: Chromium's `ui/events/blink/fling_booster.cc`.
//!
//! Positions are logical pixels (Android's dips, Apple's points); times are
//! milliseconds on the caller's monotonic clock.
use glam::Vec2;
use std::collections::VecDeque;
use std::sync::OnceLock;

/// `ViewConfiguration`'s minimum and maximum fling velocity, dips per second.
pub const MIN_FLING_VELOCITY: f32 = 50.;
pub const MAX_FLING_VELOCITY: f32 = 8000.;

// --- Velocity tracker (LSQ2, no weighting) ---------------------------------

const HISTORY: usize = 20;
const HORIZON_MS: i64 = 100;
/// Moves this far apart mean the finger stopped in between.
const MOVE_STOPPED_MS: i64 = 40;
/// A lift this long after the last move means the finger stopped first.
const UP_STOPPED_MS: i64 = 80;

/// Least-squares polynomial fit `y ≈ b0 + b1 x + … + b(n-1) x^(n-1)` by
/// Gram-Schmidt QR, as `SolveLeastSquares` in velocity_tracker.cc.
fn solve_least_squares(x: &[f32], y: &[f32], n: usize) -> Option<[f32; 3]> {
    let m = x.len();
    let mut a = [[0f32; HISTORY]; 3];
    for h in 0..m {
        a[0][h] = 1.;
        for i in 1..n {
            a[i][h] = a[i - 1][h] * x[h];
        }
    }
    let mut q = [[0f32; HISTORY]; 3];
    let mut r = [[0f32; 3]; 3];
    for j in 0..n {
        q[j][..m].copy_from_slice(&a[j][..m]);
        for i in 0..j {
            let dot: f32 = (0..m).map(|h| q[i][h] * q[j][h]).sum();
            for h in 0..m {
                q[j][h] -= dot * q[i][h];
            }
        }
        let norm = (0..m).map(|h| q[j][h] * q[j][h]).sum::<f32>().sqrt();
        if norm < 0.000001 {
            return None;
        }
        for h in 0..m {
            q[j][h] /= norm;
        }
        for i in 0..n {
            r[j][i] = if i < j { 0. } else { (0..m).map(|h| q[j][h] * a[i][h]).sum() };
        }
    }
    let mut b = [0f32; 3];
    for i in (0..n).rev() {
        b[i] = (0..m).map(|h| q[i][h] * y[h]).sum();
        for j in (i + 1..n).rev() {
            b[i] -= r[i][j] * b[j];
        }
        b[i] /= r[i][i];
    }
    Some(b)
}

#[derive(Default, Debug)]
struct VelocityTracker {
    /// (time, position), oldest first.
    samples: VecDeque<(i64, Vec2)>,
}

impl VelocityTracker {
    fn clear(&mut self) {
        self.samples.clear();
    }

    fn last_time(&self) -> Option<i64> {
        self.samples.back().map(|sample| sample.0)
    }

    fn add(&mut self, now: i64, position: Vec2) {
        // A report that does not move the finger (a recognizer replaying the
        // drag it already sampled) is not a new touch event.
        if self.samples.back().is_some_and(|&(_, last)| last == position) {
            return;
        }
        if self.last_time().is_some_and(|last| now - last >= MOVE_STOPPED_MS) {
            self.clear();
        }
        // Moves reported together (several fingers) are one event.
        if self.samples.back().is_some_and(|&(time, _)| time == now) {
            self.samples.pop_back();
        }
        self.samples.push_back((now, position));
        while self.samples.len() > HISTORY {
            self.samples.pop_front();
        }
    }

    /// Pixels per second at the newest sample: the slope of a quadratic fit
    /// over the last `HORIZON_MS`, evaluated there.
    fn velocity(&self) -> Vec2 {
        let Some(&(newest, _)) = self.samples.back() else { return Vec2::ZERO };
        let recent: Vec<_> = self.samples.iter().rev().take_while(|(time, _)| newest - time <= HORIZON_MS).collect();
        let m = recent.len();
        if m < 2 {
            return Vec2::ZERO;
        }
        let time: Vec<f32> = recent.iter().map(|(t, _)| -((newest - t) as f32) / 1000.).collect();
        let xs: Vec<f32> = recent.iter().map(|(_, p)| p.x).collect();
        let ys: Vec<f32> = recent.iter().map(|(_, p)| p.y).collect();
        let n = m.min(3);
        match (solve_least_squares(&time, &xs, n), solve_least_squares(&time, &ys, n)) {
            (Some(bx), Some(by)) => Vec2::new(bx[1], by[1]),
            _ => Vec2::ZERO,
        }
    }
}

// --- Apple deceleration -----------------------------------------------------

/// `UIScrollView.DecelerationRate.normal`: velocity keeps this share per ms.
const DECELERATION_RATE: f32 = 0.998;
/// A glide this close to its end has ended, in pixels.
const END_THRESHOLD: f32 = 0.5;

/// Exponential decay constant, per second.
fn decay() -> f32 {
    -1000. * DECELERATION_RATE.ln()
}

/// How far a fling at `speed` px/s glides.
pub fn fling_distance(speed: f32) -> f32 {
    speed / decay()
}

/// How long a fling at `speed` px/s glides before it ends, in seconds.
pub fn fling_duration(speed: f32) -> f32 {
    (speed / (decay() * END_THRESHOLD)).ln().max(0.) / decay()
}

#[derive(Clone, Copy, Debug)]
struct Glide {
    started: i64,
    /// The velocity it started with, after any boost.
    launch: Vec2,
    direction: Vec2,
    speed: f32,
    /// Distance already handed out by `advance`.
    travelled: f32,
}

impl Glide {
    fn new(velocity: Vec2, now: i64) -> Self {
        let speed = velocity.length();
        Self { started: now, launch: velocity, direction: velocity / speed, speed, travelled: 0. }
    }

    fn elapsed(&self, now: i64) -> f32 {
        ((now - self.started) as f32 / 1000.).max(0.)
    }

    fn velocity_at(&self, now: i64) -> Vec2 {
        self.direction * self.speed * (-decay() * self.elapsed(now)).exp()
    }
}

// --- Fling booster ----------------------------------------------------------

/// Both the gliding fling and the new one must be this fast to add up.
const MIN_BOOST_FLING_SPEED: f32 = 350.;
/// The drag between them must keep at least this speed.
const MIN_BOOST_SCROLL_SPEED: f32 = 150.;
/// …with no pause longer than this.
const BOOST_TIMEOUT_MS: i64 = 50;
/// From landing on a glide to the drag's first movement. Chromium allows
/// `BOOST_TIMEOUT_MS` before its scroll begins; touch recognizers here also
/// wait up to that long to tell one finger from several before scrolling.
const BOOST_LANDING_MS: i64 = 2 * BOOST_TIMEOUT_MS;

#[derive(Clone, Copy, Debug)]
struct Boost {
    /// The interrupted fling's launch and its velocity when the finger landed.
    launch: Vec2,
    current: Vec2,
    cutoff: i64,
    last_drag: Option<i64>,
}

// --- Scroll motion ----------------------------------------------------------

/// A finger drag and the glide after it.
#[derive(Default, Debug)]
pub struct ScrollMotion {
    tracker: VelocityTracker,
    /// Finger travel since it landed.
    pub position: Vec2,
    glide: Option<Glide>,
    velocity: Vec2,
    boost: Option<Boost>,
}

impl ScrollMotion {
    /// The glide's current velocity; zero once it rests.
    pub fn velocity(&self) -> Vec2 {
        self.velocity
    }

    /// A finger landed. A glide stops here; it may still boost the next flick.
    pub fn begin(&mut self, now: i64) {
        self.boost = self.glide.map(|glide| Boost {
            launch: glide.launch,
            current: glide.velocity_at(now),
            cutoff: now + BOOST_LANDING_MS,
            last_drag: None,
        });
        self.glide = None;
        self.velocity = Vec2::ZERO;
        self.reset_samples(now);
    }

    /// Restart velocity tracking from here, as when a scroll begins after the
    /// finger rested.
    pub fn reset_samples(&mut self, now: i64) {
        self.tracker.clear();
        self.position = Vec2::ZERO;
        self.tracker.add(now, self.position);
    }

    /// Record where the finger is, as travel since it landed, before the
    /// content moves: Chromium's tracker sees every move from touch-down, so
    /// a recognizer that starts scrolling late still measures the whole drag.
    pub fn sample(&mut self, travel: Vec2, now: i64) {
        self.tracker.add(now, travel);
    }

    pub fn track(&mut self, delta: Vec2, now: i64) {
        self.position += delta;
        self.tracker.add(now, self.position);
        if let Some(boost) = &mut self.boost {
            let pace = boost.last_drag.map(|last| (now - last) as f32 / 1000.).filter(|elapsed| *elapsed >= 0.001);
            let keeps = now <= boost.cutoff
                && boost.launch.dot(delta) > 0.
                && pace.is_none_or(|elapsed| (delta / elapsed).length() >= MIN_BOOST_SCROLL_SPEED);
            if keeps {
                boost.last_drag = Some(now);
                boost.cutoff = now + BOOST_TIMEOUT_MS;
            } else {
                self.boost = None;
            }
        }
    }

    /// The finger lifted: a fast enough release glides on.
    pub fn release(&mut self, now: i64) {
        let boost = self.boost.take();
        self.glide = None;
        self.velocity = Vec2::ZERO;
        let stopped = self.tracker.last_time().is_none_or(|last| now - last >= UP_STOPPED_MS);
        let mut velocity = if stopped { Vec2::ZERO } else { self.tracker.velocity() };
        velocity = velocity.clamp(Vec2::splat(-MAX_FLING_VELOCITY), Vec2::splat(MAX_FLING_VELOCITY));
        if velocity.x.abs() <= MIN_FLING_VELOCITY && velocity.y.abs() <= MIN_FLING_VELOCITY {
            return;
        }
        if let Some(boost) = boost.filter(|boost| {
            now <= boost.cutoff
                && boost.launch.dot(velocity) > 0.
                && boost.current.length() >= MIN_BOOST_FLING_SPEED
                && velocity.length() >= MIN_BOOST_FLING_SPEED
        }) {
            velocity += boost.launch;
        }
        self.glide = Some(Glide::new(velocity, now));
        self.velocity = velocity;
    }

    /// Distance the glide moved since the last call.
    pub fn advance(&mut self, now: i64) -> Vec2 {
        let Some(glide) = &mut self.glide else { return Vec2::ZERO };
        let distance = fling_distance(glide.speed);
        let fade = (-decay() * glide.elapsed(now)).exp();
        let mut covered = distance * (1. - fade);
        if distance - covered < END_THRESHOLD {
            covered = distance;
        }
        let delta = glide.direction * (covered - glide.travelled);
        glide.travelled = covered;
        if covered >= distance {
            self.glide = None;
            self.velocity = Vec2::ZERO;
        } else {
            self.velocity = glide.direction * glide.speed * fade;
        }
        delta
    }

    /// Whether a recent glide may still boost the next flick.
    pub fn boosting(&self) -> bool {
        self.boost.is_some()
    }

    pub fn stop(&mut self) {
        self.glide = None;
        self.boost = None;
        self.velocity = Vec2::ZERO;
        self.tracker.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A drag sampled every 8 ms at `velocity`, lifted 8 ms after its last move.
    fn flick(motion: &mut ScrollMotion, start: i64, velocity: Vec2) -> i64 {
        motion.begin(start);
        for step in 1..=10 {
            motion.track(velocity * 0.008, start + step * 8);
        }
        motion.release(start + 88);
        start + 88
    }

    fn glide_all(motion: &mut ScrollMotion, from: i64, step: i64) -> Vec2 {
        let mut total = Vec2::ZERO;
        let mut now = from;
        while motion.velocity() != Vec2::ZERO && now < from + 10_000 {
            now += step;
            total += motion.advance(now);
        }
        total
    }

    #[test]
    fn glides_decelerate_like_uiscrollview() {
        // Velocity × 0.998 per ms: about half a second of the release speed.
        assert!((fling_distance(2000.) - 999.).abs() < 1., "{}", fling_distance(2000.));
        assert!((fling_distance(8000.) - 3996.).abs() < 2., "{}", fling_distance(8000.));
        assert!((fling_duration(2000.) - 3.80).abs() < 0.01, "{}", fling_duration(2000.));
        let mut motion = ScrollMotion::default();
        let lifted = flick(&mut motion, 0, Vec2::Y * 2000.);
        assert!((motion.velocity().y - 2000.).abs() < 1., "LSQ2 recovers a steady drag: {}", motion.velocity());
        motion.advance(lifted + 100);
        assert!((motion.velocity().y - 2000. * 0.998f32.powi(100)).abs() < 1., "{}", motion.velocity());
        let travelled = glide_all(&mut motion, lifted + 100, 16);
        assert!((travelled.y + (2000. - 2000. * 0.998f32.powi(100)) / decay() - fling_distance(2000.)).abs() < 0.5, "{travelled}");
    }

    #[test]
    fn the_glide_does_not_depend_on_frame_rate() {
        let mut distances = Vec::new();
        for step in [4, 8, 16, 33, 100] {
            let mut motion = ScrollMotion::default();
            let lifted = flick(&mut motion, 0, Vec2::Y * 3000.);
            distances.push(glide_all(&mut motion, lifted, step).y);
        }
        assert!(distances.windows(2).all(|pair| (pair[0] - pair[1]).abs() < 0.01), "{distances:?}");
    }

    #[test]
    fn an_accelerating_finger_flings_at_its_final_speed() {
        // A quadratic fit sees the speed at release, not the average.
        let mut motion = ScrollMotion::default();
        motion.begin(0);
        let mut y = 0.;
        for step in 1..=10 {
            let t = step as f32 * 0.008;
            let next = 20_000. * t * t; // 40 000 px/s², ending at 3200 px/s.
            motion.track(Vec2::Y * (next - y), step * 8);
            y = next;
        }
        motion.release(88);
        assert!((motion.velocity().y - 3200.).abs() < 40., "{}", motion.velocity());
    }

    #[test]
    fn limits_and_pauses_follow_android() {
        let mut motion = ScrollMotion::default();
        flick(&mut motion, 0, Vec2::new(30_000., 0.));
        assert_eq!(motion.velocity().x, MAX_FLING_VELOCITY, "capped per axis");
        flick(&mut motion, 10_000, Vec2::Y * 40.);
        assert_eq!(motion.velocity(), Vec2::ZERO, "slower than the minimum does not fling");
        motion.begin(20_000);
        for step in 1..=10 {
            motion.track(Vec2::Y * 16., 20_000 + step * 8);
        }
        motion.release(20_080 + UP_STOPPED_MS);
        assert_eq!(motion.velocity(), Vec2::ZERO, "a rest before lifting does not fling");
        motion.begin(30_000);
        motion.track(Vec2::Y * 400., 30_008); // A jump, then a pause.
        motion.track(Vec2::Y * 1., 30_008 + MOVE_STOPPED_MS);
        motion.track(Vec2::Y * 1., 30_016 + MOVE_STOPPED_MS);
        motion.release(30_024 + MOVE_STOPPED_MS);
        assert!(motion.velocity().y < 200., "a pause forgets the earlier jump: {}", motion.velocity());
    }

    #[test]
    fn a_quick_flick_in_the_same_direction_adds_the_previous_launch() {
        let mut motion = ScrollMotion::default();
        let lifted = flick(&mut motion, 0, Vec2::Y * 2000.);
        motion.advance(lifted + 100);
        flick(&mut motion, lifted + 100, Vec2::Y * 2000.);
        assert!((motion.velocity().y - 4000.).abs() < 2., "{}", motion.velocity());
        let again = flick(&mut motion, lifted + 300, Vec2::Y * 2000.);
        assert!((motion.velocity().y - 6000.).abs() < 3., "boosts accumulate: {}", motion.velocity());
        assert!(again > 0);
    }

    #[test]
    fn reversal_slow_drags_pauses_and_slow_glides_do_not_boost() {
        for case in 0..4 {
            let mut motion = ScrollMotion::default();
            let lifted = flick(&mut motion, 0, Vec2::Y * 2000.);
            let landed = match case {
                3 => lifted + 900, // The glide has slowed below 350 px/s.
                _ => lifted + 100,
            };
            motion.advance(landed);
            match case {
                0 => {
                    flick(&mut motion, landed, -Vec2::Y * 2000.);
                    assert!((motion.velocity().y + 2000.).abs() < 1., "reversal: {}", motion.velocity());
                    continue;
                }
                1 => {
                    motion.begin(landed);
                    for step in 1..=10 {
                        motion.track(Vec2::Y * 0.5, landed + step * 8); // 62 px/s.
                    }
                    for step in 11..=20 {
                        motion.track(Vec2::Y * 16., landed + step * 8);
                    }
                    motion.release(landed + 168);
                }
                2 => {
                    motion.begin(landed);
                    for step in 1..=10 {
                        motion.track(Vec2::Y * 16., landed + BOOST_LANDING_MS + step * 8); // Rested first.
                    }
                    motion.release(landed + BOOST_LANDING_MS + 88);
                }
                _ => {
                    flick(&mut motion, landed, Vec2::Y * 2000.);
                }
            }
            // Unboosted: a boost would add the earlier 2000 px/s launch.
            assert!(motion.velocity().y > 1500. && motion.velocity().y < 3000., "case {case}: {}", motion.velocity());
        }
    }

    #[test]
    fn a_tap_on_a_glide_stops_it() {
        let mut motion = ScrollMotion::default();
        let lifted = flick(&mut motion, 0, Vec2::Y * 3000.);
        motion.advance(lifted + 50);
        motion.begin(lifted + 60);
        assert_eq!(motion.advance(lifted + 70), Vec2::ZERO);
        motion.release(lifted + 120);
        assert_eq!(motion.velocity(), Vec2::ZERO);
    }
}
