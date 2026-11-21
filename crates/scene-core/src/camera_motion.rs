//! Camera flight state shared with Godot's `scenes/CameraMotion.gd`.
//!
//! The caller supplies displayed and destination frames, including saved framing
//! and interactive effects. This component does not cap delta or choose routes.
use crate::Pose;
use glam::{Quat, Vec3, Vec4};
use std::ops::{Add, Mul};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Frame {
    pub transform: Pose,
    /// Tangent-space frustum: left, bottom, width, height at unit depth.
    pub rect: [f32; 4],
}

#[derive(Clone, Debug)]
pub struct CameraMotion {
    frame: Frame,
    velocity: Vec3,
    angular_velocity: Vec3,
    framing_velocity: Vec4,
    moving: bool,
    // GDScript clocks are double precision; accumulating display deltas in f32
    // can leave a 96-frame/60 Hz flight one frame short of its endpoint.
    elapsed: f64,
    duration: f64,
    start: Frame,
    target: Frame,
    points: Vec<Vec3>,
    times: Vec<f32>,
    tangents: Vec<Vec3>,
    angular_start: Vec3,
    framing_start: Vec4,
    route_start_rate: f32,
    /// retarget_on_path: re-time the existing spatial curve (route time from,
    /// to and initial rate), with an optional braking segment before a turn.
    clock: Option<PathClock>,
}

#[derive(Clone, Copy, Debug)]
struct PathClock {
    from: f64,
    to: f64,
    velocity: f64,
    brake: f64,
    turn: f64,
}

impl CameraMotion {
    pub fn new(frame: Frame) -> Self {
        Self {
            frame,
            start: frame,
            target: frame,
            velocity: Vec3::ZERO,
            angular_velocity: Vec3::ZERO,
            framing_velocity: Vec4::ZERO,
            moving: false,
            elapsed: 0.,
            duration: 1.,
            points: Vec::new(),
            times: Vec::new(),
            tangents: Vec::new(),
            angular_start: Vec3::ZERO,
            framing_start: Vec4::ZERO,
            route_start_rate: 0.,
            clock: None,
        }
    }

    pub fn frame(&self) -> Frame {
        self.frame
    }
    pub fn route_points(&self) -> &[Vec3] {
        &self.points
    }
    pub fn stop(&mut self) {
        self.moving = false;
    }
    pub fn target(&self) -> Frame {
        self.target
    }
    pub fn velocity(&self) -> Vec3 {
        self.velocity
    }
    pub fn angular_velocity(&self) -> Vec3 {
        self.angular_velocity
    }
    pub fn framing_velocity(&self) -> Vec4 {
        self.framing_velocity
    }
    pub fn moving(&self) -> bool {
        self.moving
    }
    pub fn elapsed(&self) -> f32 {
        self.elapsed as f32
    }
    pub fn duration(&self) -> f32 {
        self.duration as f32
    }
    pub fn elapsed_seconds(&self) -> f64 {
        self.elapsed
    }
    pub fn duration_seconds(&self) -> f64 {
        self.duration
    }

    pub fn reset(&mut self, frame: Frame) {
        self.frame = frame;
        self.start = frame;
        self.target = frame;
        self.velocity = Vec3::ZERO;
        self.angular_velocity = Vec3::ZERO;
        self.framing_velocity = Vec4::ZERO;
        self.moving = false;
        self.elapsed = 0.;
        self.clock = None;
    }

    /// Observe the frame actually displayed between flights. Its measured
    /// translation, local angular velocity and lens velocity seed the next one.
    pub fn observe(&mut self, frame: Frame, dt: f32) {
        if dt > 0. {
            self.velocity = (frame.transform.translation - self.frame.transform.translation) / dt;
            self.angular_velocity =
                rotation_vector(self.frame.transform.rotation.inverse() * frame.transform.rotation)
                    / dt;
            self.framing_velocity = (lens(frame.rect) - lens(self.frame.rect)) / dt;
        }
        self.frame = frame;
    }

    pub fn retarget(&mut self, destination: Frame, seconds: f32, route: &[Vec3]) {
        self.retarget_seconds(destination, f64::from(seconds), route);
    }

    pub fn retarget_seconds(&mut self, destination: Frame, seconds: f64, route: &[Vec3]) {
        self.clock = None;
        self.start = self.frame;
        self.target = destination;
        self.duration = seconds.max(0.001);
        self.elapsed = 0.;
        self.angular_start = self.angular_velocity;
        self.framing_start = self.framing_velocity;
        self.points.clear();
        self.points.push(self.frame.transform.translation);
        for &point in route {
            if point.distance(*self.points.last().unwrap()) > 0.001
                && point.distance(destination.transform.translation) > 0.001
            {
                self.points.push(point);
            }
        }
        self.points.push(destination.transform.translation);
        let total: f32 = self
            .points
            .windows(2)
            .map(|pair| pair[1].distance(pair[0]).max(0.001))
            .sum();
        self.times.clear();
        self.times.push(0.);
        for pair in self.points.windows(2) {
            self.times.push(
                (f64::from(*self.times.last().unwrap())
                    + self.duration * f64::from(pair[1].distance(pair[0]).max(0.001))
                        / f64::from(total)) as f32,
            );
        }
        *self.times.last_mut().unwrap() = self.duration as f32;
        self.tangents.resize(self.points.len(), Vec3::ZERO);
        // Ease the clock over the whole route. A moving interruption begins at
        // unit clock rate so the full incoming velocity vector survives.
        self.route_start_rate = if self.velocity.length_squared() > 0.000001 {
            1.
        } else {
            0.
        };
        self.tangents[0] = if self.route_start_rate > 0. {
            self.velocity
        } else {
            (self.points[1] - self.points[0]) / self.times[1].max(0.001)
        };
        let last = self.points.len() - 1;
        self.tangents[last] = (self.points[last] - self.points[last - 1])
            / (self.duration - f64::from(self.times[last - 1])).max(0.001) as f32;
        if self.points.len() == 2 {
            self.tangents[0] = self.velocity;
            self.tangents[last] = Vec3::ZERO;
        }
        for i in 1..last {
            self.tangents[i] = (self.points[i + 1] - self.points[i - 1])
                / (self.times[i + 1] - self.times[i - 1]).max(0.001);
        }
        self.moving = true;
    }

    /// Route time and its rate along the current spatial curve (Godot
    /// CameraMotion._path_clock), including a re-timed on-path clock.
    pub fn path_clock(&self, t: f64) -> (f64, f64) {
        if let Some(clock) = self.clock {
            if clock.brake > 0. {
                let seconds = t * self.duration;
                if seconds < clock.brake {
                    let u = seconds / clock.brake;
                    return (
                        quintic64(clock.from, clock.turn, clock.velocity * clock.brake, 0., u),
                        quintic_derivative64(
                            clock.from,
                            clock.turn,
                            clock.velocity * clock.brake,
                            0.,
                            u,
                        ) / clock.brake,
                    );
                }
                let span = self.duration - clock.brake;
                let u = (seconds - clock.brake) / span;
                return (
                    quintic64(clock.turn, clock.to, 0., 0., u),
                    quintic_derivative64(clock.turn, clock.to, 0., 0., u) / span,
                );
            }
            return (
                quintic64(clock.from, clock.to, clock.velocity * self.duration, 0., t),
                quintic_derivative64(clock.from, clock.to, clock.velocity * self.duration, 0., t)
                    / self.duration,
            );
        }
        if self.points.len() == 2 {
            return (t * self.duration, 1.);
        }
        let rate = f64::from(self.route_start_rate);
        (
            quintic64(0., 1., rate, 0., t) * self.duration,
            quintic_derivative64(0., 1., rate, 0., t),
        )
    }

    /// Retarget an endpoint along the current spatial curve, as in Godot's
    /// `retarget_on_path`. Start at the incoming speed, brake, then retrace
    /// the path.
    pub fn retarget_on_path(&mut self, destination: Frame, seconds: f32) -> bool {
        self.retarget_on_path_seconds(destination, f64::from(seconds))
    }

    pub fn retarget_on_path_seconds(&mut self, destination: Frame, seconds: f64) -> bool {
        if !self.moving || self.points.len() < 2 {
            return false;
        }
        let eye = destination.transform.translation;
        let last = f64::from(*self.times.last().unwrap());
        let end = if eye.distance(self.points[0]) < 0.001 {
            0.
        } else if eye.distance(*self.points.last().unwrap()) < 0.001 {
            last
        } else {
            return false;
        };
        let (from, velocity) = self.path_clock(self.elapsed / self.duration);
        self.clock = Some(PathClock {
            from,
            to: end,
            velocity,
            brake: 0.,
            turn: from,
        });
        self.duration = seconds.max(0.001);
        let mut needs_brake = (end - from) * velocity < 0.;
        for i in 1..129 {
            let at = self.path_clock(f64::from(i) / 128.).0;
            if at < -0.00001 || at > last + 0.00001 {
                needs_brake = true;
                break;
            }
        }
        if needs_brake && velocity.abs() > 0.000001 {
            // A short braking segment stays inside the remaining forward
            // clearance; the return still gets the full requested duration.
            let room = if velocity > 0. { last - from } else { from };
            let brake = (self.duration * 0.15).min(room.max(0.) / velocity.abs());
            self.clock = Some(PathClock {
                from,
                to: end,
                velocity,
                brake,
                turn: from + velocity * brake * 0.5,
            });
        }
        self.start = self.frame;
        self.target = destination;
        self.angular_start = self.angular_velocity;
        self.framing_start = self.framing_velocity;
        self.elapsed = 0.;
        true
    }

    /// Retarget a changed destination lens without moving the arrival deadline
    /// or revisiting route waypoints already passed by the eased clock. A
    /// lens-only change keeps the route, its reversal and the deadline.
    pub fn retarget_remaining(&mut self, destination: Frame) {
        if !self.moving {
            return;
        }
        let seconds = (self.duration - self.elapsed).max(0.001);
        if destination
            .transform
            .translation
            .distance(self.target.transform.translation)
            < 0.001
            && self.retarget_on_path_seconds(destination, seconds)
        {
            return;
        }
        let route_time = self.path_clock(self.elapsed / self.duration).0;
        let reversed = self.clock.is_some_and(|clock| clock.to.abs() < 1e-9);
        let remaining: Vec<_> = if reversed {
            (1..self.points.len() - 1)
                .rev()
                .filter(|&i| f64::from(self.times[i]) < route_time)
                .map(|i| self.points[i])
                .collect()
        } else {
            (1..self.points.len() - 1)
                .filter(|&i| f64::from(self.times[i]) > route_time)
                .map(|i| self.points[i])
                .collect()
        };
        self.retarget_seconds(destination, seconds, &remaining);
    }

    pub fn advance(&mut self, dt: f32) -> Frame {
        self.advance_seconds(f64::from(dt))
    }

    pub fn advance_seconds(&mut self, dt: f64) -> Frame {
        if !self.moving || dt <= 0. {
            return self.frame;
        }
        self.elapsed = (self.elapsed + dt).min(self.duration);
        let t = (self.elapsed / self.duration) as f32;
        let (route_time, route_rate) = self.path_clock(self.elapsed / self.duration);
        let route_rate = route_rate as f32;
        let mut segment = 0;
        while segment < self.points.len() - 2 && route_time > f64::from(self.times[segment + 1]) {
            segment += 1;
        }
        let span = (self.times[segment + 1] - self.times[segment]).max(0.00001);
        let u =
            ((route_time - f64::from(self.times[segment])) / f64::from(span)).clamp(0., 1.) as f32;
        let interpolate = if self.points.len() == 2 {
            quintic::<Vec3>
        } else {
            hermite::<Vec3>
        };
        let derivative = if self.points.len() == 2 {
            quintic_derivative::<Vec3>
        } else {
            hermite_derivative::<Vec3>
        };
        let eye = interpolate(
            self.points[segment],
            self.points[segment + 1],
            self.tangents[segment] * span,
            self.tangents[segment + 1] * span,
            u,
        );
        self.velocity = derivative(
            self.points[segment],
            self.points[segment + 1],
            self.tangents[segment] * span,
            self.tangents[segment + 1] * span,
            u,
        ) / span
            * route_rate;
        let from_q = self.start.transform.rotation;
        let delta = rotation_vector(from_q.inverse() * self.target.transform.rotation);
        let rotation = quintic(
            Vec3::ZERO,
            delta,
            self.angular_start * self.duration as f32,
            Vec3::ZERO,
            t,
        );
        let rotation_rate = quintic_derivative(
            Vec3::ZERO,
            delta,
            self.angular_start * self.duration as f32,
            Vec3::ZERO,
            t,
        ) / self.duration as f32;
        self.angular_velocity = rotation_velocity(rotation, rotation_rate);
        let lens_from = lens(self.start.rect);
        let lens_to = lens(self.target.rect);
        let value = quintic(
            lens_from,
            lens_to,
            self.framing_start * self.duration as f32,
            Vec4::ZERO,
            t,
        );
        self.framing_velocity = quintic_derivative(
            lens_from,
            lens_to,
            self.framing_start * self.duration as f32,
            Vec4::ZERO,
            t,
        ) / self.duration as f32;
        self.frame = Frame {
            transform: Pose::from_translation(eye)
                .with_rotation(from_q * rotation_quaternion(rotation)),
            rect: rect(value),
        };
        if self.elapsed >= self.duration {
            self.frame = self.target;
            self.moving = false;
            self.velocity = Vec3::ZERO;
            self.angular_velocity = Vec3::ZERO;
            self.framing_velocity = Vec4::ZERO;
        }
        self.frame
    }
}

// GDScript floats are doubles: route clocks keep that precision.
fn quintic64(a: f64, b: f64, va: f64, vb: f64, t: f64) -> f64 {
    let t3 = t * t * t;
    let blend = t3 * (10. + t * (-15. + 6. * t));
    a * (1. - blend)
        + b * blend
        + va * (t + t3 * (-6. + t * (8. - 3. * t)))
        + vb * (t3 * (-4. + t * (7. - 3. * t)))
}

fn quintic_derivative64(a: f64, b: f64, va: f64, vb: f64, t: f64) -> f64 {
    let rest = (1. - t) * (1. - t);
    (b - a) * 30. * t * t * rest
        + va * (rest * (1. + 2. * t - 15. * t * t))
        + vb * (t * t * (-12. + t * (28. - 15. * t)))
}

// Preserve endpoint velocity while landing with zero acceleration.
fn quintic<T>(a: T, b: T, va: T, vb: T, t: f32) -> T
where
    T: Copy + Mul<f32, Output = T> + Add<Output = T>,
{
    let t3 = t * t * t;
    let blend = t3 * (10. + t * (-15. + 6. * t));
    a * (1. - blend)
        + b * blend
        + va * (t + t3 * (-6. + t * (8. - 3. * t)))
        + vb * (t3 * (-4. + t * (7. - 3. * t)))
}

fn quintic_derivative<T>(a: T, b: T, va: T, vb: T, t: f32) -> T
where
    T: Copy + Mul<f32, Output = T> + Add<Output = T>,
{
    let rest = (1. - t) * (1. - t);
    let rate = 30. * t * t * rest;
    a * -rate
        + b * rate
        + va * (rest * (1. + 2. * t - 15. * t * t))
        + vb * (t * t * (-12. + t * (28. - 15. * t)))
}

fn hermite<T>(a: T, b: T, va: T, vb: T, t: f32) -> T
where
    T: Copy + Mul<f32, Output = T> + Add<Output = T>,
{
    a * (2. * t * t * t - 3. * t * t + 1.)
        + b * (-2. * t * t * t + 3. * t * t)
        + va * (t * t * t - 2. * t * t + t)
        + vb * (t * t * t - t * t)
}

fn hermite_derivative<T>(a: T, b: T, va: T, vb: T, t: f32) -> T
where
    T: Copy + Mul<f32, Output = T> + Add<Output = T>,
{
    a * (6. * t * t - 6. * t)
        + b * (-6. * t * t + 6. * t)
        + va * (3. * t * t - 4. * t + 1.)
        + vb * (3. * t * t - 2. * t)
}

fn rotation_vector(q: Quat) -> Vec3 {
    let mut q = q.normalize();
    if q.w < 0. {
        q = -q;
    }
    let xyz = Vec3::new(q.x, q.y, q.z);
    let length = xyz.length();
    if length > 0.000001 {
        xyz * (2. * length.atan2(q.w) / length)
    } else {
        Vec3::ZERO
    }
}

fn rotation_quaternion(value: Vec3) -> Quat {
    let angle = value.length();
    if angle > 0.000001 {
        Quat::from_axis_angle(value / angle, angle)
    } else {
        Quat::IDENTITY
    }
}

fn rotation_velocity(rotation: Vec3, rate: Vec3) -> Vec3 {
    let angle = rotation.length();
    let cross = rotation.cross(rate);
    if angle < 0.0001 {
        return rate - cross * 0.5;
    }
    rate - cross * ((1. - angle.cos()) / (angle * angle))
        + rotation.cross(cross) * ((angle - angle.sin()) / (angle * angle * angle))
}

fn lens(rect: [f32; 4]) -> Vec4 {
    Vec4::new(
        rect[0] + rect[2] * 0.5,
        rect[1] + rect[3] * 0.5,
        rect[2].max(0.000001).ln(),
        rect[3].max(0.000001).ln(),
    )
}

fn rect(lens: Vec4) -> [f32; 4] {
    let width = lens.z.exp();
    let height = lens.w.exp();
    [lens.x - width * 0.5, lens.y - height * 0.5, width, height]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(position: Vec3) -> Frame {
        Frame {
            transform: Pose::from_translation(position),
            rect: [-0.5, -0.3, 1., 0.6],
        }
    }
    fn close(a: f32, b: f32, tolerance: f32) {
        assert!(
            (a - b).abs() <= tolerance,
            "{a} != {b} (tolerance {tolerance})"
        );
    }

    #[test]
    fn world_reset_retires_the_previous_destination_and_motion() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        motion.retarget(at(Vec3::X * 50.), 2., &[]);
        motion.advance(0.5);
        let destination = at(Vec3::new(-15., 2.4, -8.));
        motion.reset(destination);
        assert_eq!(motion.target(), destination);
        assert_eq!(motion.advance(1.), destination);
        assert_eq!(motion.velocity(), Vec3::ZERO);
        assert!(!motion.moving());
    }

    #[test]
    fn double_precision_deadline_lands_without_an_extra_frame() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        let target = at(Vec3::X * 16.);
        motion.retarget_seconds(target, 3.2, &[]);
        motion.advance_seconds(0.65);
        motion.retarget_remaining(target);
        for remaining in [0.8, 0.4, 0.25, 0.1, 0.025, 0.0] {
            motion
                .advance_seconds(motion.duration_seconds() - motion.elapsed_seconds() - remaining);
        }
        assert!(!motion.moving());
        assert_eq!(motion.frame(), target);
    }

    #[test]
    fn direct_flight_has_authored_duration_and_analytic_quarter_samples() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        let target = at(Vec3::new(16., 0., 0.));
        motion.retarget(target, 1.6, &[]);
        motion.advance(0.4);
        close(motion.frame().transform.translation.x, 1.65625, 0.00001);
        close(motion.velocity().x, 10.546875, 0.00001);
        motion.advance(0.8);
        close(motion.frame().transform.translation.x, 14.34375, 0.00001);
        close(motion.velocity().x, 10.546875, 0.00001);
        assert!(motion.moving());
        motion.advance(10.);
        assert_eq!(motion.frame(), target);
        assert_eq!(motion.elapsed(), 1.6);
        assert_eq!(motion.velocity(), Vec3::ZERO);
        assert_eq!(motion.angular_velocity(), Vec3::ZERO);
        assert_eq!(motion.framing_velocity(), Vec4::ZERO);
        assert!(!motion.moving());
    }

    #[test]
    fn direct_and_routed_landings_have_vanishing_acceleration() {
        for route in [
            vec![],
            vec![Vec3::new(20., 0., 0.), Vec3::new(40., 0., 0.95)],
        ] {
            let mut motion = CameraMotion::new(at(Vec3::ZERO));
            let mut target = at(Vec3::new(40., 0., 1.));
            target.transform.rotation = Quat::from_rotation_y(0.8);
            target.rect = [-0.25, -0.2, 0.5, 0.4];
            motion.retarget(target, 2.1, &route);
            motion.advance(1.6);
            assert!(motion.moving() && motion.velocity().length() > 0.01);
            let speed = motion.velocity().length();
            motion.advance(0.25);
            assert!(motion.velocity().length() < speed);
            motion.advance(2.1 - motion.elapsed() - 0.001);
            // Final velocity divided by time remaining tends to zero too:
            // unlike a cubic stop, landing has no acceleration discontinuity.
            assert!(motion.velocity().length() / 0.001 < 0.4);
            assert!(motion.angular_velocity().length() / 0.001 < 0.01);
            assert!(motion.framing_velocity().length() / 0.001 < 0.01);
            motion.advance(0.002);
            assert!(!motion.moving());
            assert_eq!(motion.frame(), target);
        }
    }

    #[test]
    fn sixty_hertz_flight_lands_on_the_ninety_sixth_frame() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        let target = at(Vec3::new(16., 0., 0.));
        motion.retarget(target, 1.6, &[]);
        for _ in 0..95 {
            motion.advance(1. / 60.);
        }
        assert!(motion.moving());
        motion.advance(1. / 60.);
        assert!(!motion.moving());
        assert_eq!(motion.frame(), target);
    }

    #[test]
    fn lens_extents_interpolate_geometrically_and_orientation_uses_shortest_arc() {
        let mut start = at(Vec3::ZERO);
        start.rect = [-0.5, -1., 1., 2.];
        let mut target = start;
        target.rect = [-3.5, -2., 9., 8.];
        target.transform.rotation = -Quat::from_rotation_y(120_f32.to_radians());
        let mut motion = CameraMotion::new(start);
        motion.retarget(target, 1.6, &[]);
        motion.advance(0.8);
        for (actual, expected) in motion.frame().rect.into_iter().zip([-1., -1., 3., 4.]) {
            close(actual, expected, 0.000001);
        }
        assert!(
            motion
                .frame()
                .transform
                .rotation
                .angle_between(Quat::from_rotation_y(60_f32.to_radians()))
                < 0.001
        );
        close(
            motion.angular_velocity().y,
            120_f32.to_radians() * 1.875 / 1.6,
            0.00001,
        );
    }

    // The route and thresholds are Godot's tests/unit/routed_camera_test.gd.
    #[test]
    fn short_final_route_leg_decelerates_before_landing() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        let target = at(Vec3::new(40., 0., 1.));
        motion.retarget(
            target,
            1.6,
            &[
                Vec3::new(20., 0., 0.),
                Vec3::new(40., 0., 0.),
                Vec3::new(40., 0., 0.95),
            ],
        );
        let mut peak = 0_f32;
        let mut late = 0_f32;
        for i in 0..160 {
            motion.advance(0.01);
            peak = peak.max(motion.velocity().length());
            if i >= 151 {
                late = late.max(motion.velocity().length());
            }
        }
        assert!(
            late < peak * 0.35,
            "short final leg retained cruising speed: {late}/{peak}"
        );
        assert!(
            motion
                .frame()
                .transform
                .translation
                .distance(target.transform.translation)
                < 0.0001
        );
        assert!(motion.velocity().length() < 0.0001);
    }

    #[test]
    fn routed_interruption_preserves_incoming_vector_velocity() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        motion.retarget(at(Vec3::new(30., 0., 0.)), 1.6, &[]);
        motion.advance(0.6);
        let before = motion.velocity();
        let position = motion.frame().transform.translation;
        motion.retarget(
            at(Vec3::new(10., 0., 20.)),
            1.6,
            &[position + Vec3::new(3., 0., 2.), Vec3::new(10., 0., 18.)],
        );
        motion.advance(0.00001);
        assert!(motion.velocity().distance(before) < 0.02);
        let measured = (motion.frame().transform.translation - position) / 0.00001;
        assert!(
            measured.distance(before) < 0.2,
            "displayed velocity {measured} != {before}"
        );
    }

    #[test]
    fn changing_rotation_axis_retains_angular_and_lens_derivatives() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        let mut target = at(Vec3::X * 5.);
        target.transform.rotation = Quat::from_rotation_y(1.2);
        target.rect = [-1., -0.6, 2., 1.2];
        motion.retarget(target, 1.6, &[]);
        motion.advance(0.6);
        let before = motion.frame();
        let angular = motion.angular_velocity();
        let framing = motion.framing_velocity();
        target.transform.rotation = Quat::from_rotation_x(-0.9);
        target.rect = [-0.2, -0.5, 0.4, 1.];
        motion.retarget(target, 1.6, &[]);
        assert_eq!(motion.frame(), before);
        motion.advance(0.0001);
        assert!(motion.angular_velocity().distance(angular) < 0.001);
        assert!(motion.framing_velocity().distance(framing) < 0.001);
        let measured = rotation_vector(
            before.transform.rotation.inverse() * motion.frame().transform.rotation,
        ) / 0.0001;
        assert!(measured.distance(angular) < 0.005);
    }

    #[test]
    fn resize_keeps_current_frame_derivatives_waypoints_and_arrival_deadline() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        let mut destination = at(Vec3::new(40., 0., 10.));
        motion.retarget(
            destination,
            1.6,
            &[Vec3::new(10., 0., 0.), Vec3::new(30., 0., 10.)],
        );
        motion.advance(0.7);
        let before = motion.frame();
        let velocity = motion.velocity();
        // A moved destination eye re-fits only the unvisited waypoints.
        destination.transform.translation = Vec3::new(40., 0., 11.);
        motion.retarget_remaining(destination);
        assert_eq!(motion.frame(), before);
        close(motion.duration(), 0.9, 0.00001);
        assert!(
            !motion.points.contains(&Vec3::new(10., 0., 0.)),
            "passed waypoint was revisited"
        );
        assert!(
            motion.points.contains(&Vec3::new(30., 0., 10.)),
            "unvisited waypoint was dropped"
        );
        motion.advance(0.00001);
        assert!(motion.velocity().distance(velocity) < 0.02);
        motion.advance(motion.duration());
        assert_eq!(motion.frame(), destination);
        assert!(!motion.moving());
    }

    #[test]
    fn lens_only_resize_keeps_the_route_clock_and_arrival_deadline() {
        // Godot retarget_remaining: same eye, new frustum -> retarget_on_path.
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        let mut destination = at(Vec3::new(40., 0., 10.));
        let route = [Vec3::new(10., 0., 0.), Vec3::new(30., 0., 10.)];
        motion.retarget(destination, 1.6, &route);
        motion.advance(0.7);
        let before = motion.frame();
        let velocity = motion.velocity();
        destination.rect = [-0.25, -0.5, 0.5, 1.];
        motion.retarget_remaining(destination);
        assert_eq!(motion.frame(), before);
        close(motion.duration(), 0.9, 0.00001);
        assert_eq!(
            motion.points.len(),
            route.len() + 2,
            "the spatial route is kept"
        );
        motion.advance(0.00001);
        assert!(motion.velocity().distance(velocity) < 0.05);
        motion.advance(motion.duration());
        assert_eq!(motion.frame(), destination);
        assert!(!motion.moving());
    }

    #[test]
    fn returning_to_the_departure_brakes_and_retraces_the_same_path() {
        let start = at(Vec3::ZERO);
        let route = [Vec3::new(10., 5., 0.), Vec3::new(30., 5., 10.)];
        let mut outbound = CameraMotion::new(start);
        outbound.retarget(at(Vec3::new(40., 0., 10.)), 2.1, &route);
        let mut highest = 0_f32;
        for _ in 0..300 {
            highest = highest.max(outbound.advance(1. / 120.).transform.translation.y);
        }
        let mut motion = CameraMotion::new(start);
        motion.retarget(at(Vec3::new(40., 0., 10.)), 2.1, &route);
        motion.advance(0.9);
        let velocity = motion.velocity();
        assert!(motion.retarget_on_path(start, 2.1));
        // The camera keeps its forward speed, brakes, then comes back along
        // the outbound curve and lands exactly at the departure.
        motion.advance(0.01);
        assert!(motion.velocity().dot(velocity) > 0., "no instant reversal");
        let mut furthest = 0_f32;
        for _ in 0..300 {
            let frame = motion.advance(1. / 120.);
            furthest = furthest.max(frame.transform.translation.y);
        }
        assert!(
            furthest <= highest + 0.001,
            "the return stays on the outbound curve ({furthest} > {highest})"
        );
        assert_eq!(motion.frame(), start);
        assert!(!motion.moving());
        // An eye that is not a route endpoint cannot be resumed on path.
        motion.retarget(at(Vec3::new(40., 0., 10.)), 2.1, &route);
        motion.advance(0.5);
        assert!(!motion.retarget_on_path(at(Vec3::new(5., 5., 5.)), 2.1));
    }

    #[test]
    fn observing_displayed_effects_seeds_next_flight_and_zero_delta_keeps_velocity() {
        let mut motion = CameraMotion::new(at(Vec3::ZERO));
        let mut displayed = at(Vec3::new(1., 2., 3.));
        displayed.transform.rotation = Quat::from_rotation_y(0.2);
        displayed.rect = [-1., -0.6, 2., 1.2];
        motion.observe(displayed, 0.1);
        assert_eq!(motion.velocity(), Vec3::new(10., 20., 30.));
        close(motion.angular_velocity().y, 2., 0.00001);
        close(motion.framing_velocity().z, 2_f32.ln() / 0.1, 0.00001);
        let velocity = motion.velocity();
        motion.observe(displayed, 0.);
        assert_eq!(motion.velocity(), velocity);
        motion.retarget(at(Vec3::new(10., 0., 0.)), 1.6, &[]);
        assert_eq!(motion.advance(0.), displayed);
        assert_eq!(motion.advance(-1.), displayed);
        motion.reset(displayed);
        assert!(!motion.moving());
        assert_eq!(motion.velocity(), Vec3::ZERO);
    }
}
