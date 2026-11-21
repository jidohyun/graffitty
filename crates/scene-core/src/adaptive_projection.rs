//! One eased final frame, relative to manual navigation. Lens coordinates are
//! interpolated at the sheet's focus depth, not independently of the dolly:
//! interpolating lens width and eye depth separately can overshoot their product.
use crate::{camera_motion::Frame, pose::Pose, typing_camera::decay_step};
use glam::Vec3;

fn depth(frame: Frame, focus: Vec3) -> f32 {
    (focus - frame.transform.translation)
        .dot(frame.transform.rotation * -Vec3::Z)
        .max(0.00001)
}

#[derive(Default)]
pub struct AdaptiveProjection {
    current: Correction,
    target: Correction,
    interrupted: bool,
}

#[derive(Clone, Copy)]
struct Correction {
    pose: Pose,
    rect: [f32; 4],
}
impl Default for Correction {
    fn default() -> Self {
        Self {
            pose: Pose::IDENTITY,
            rect: [0.0, 0.0, 1.0, 1.0],
        }
    }
}
impl AdaptiveProjection {
    /// Manual navigation takes over at the displayed correction, without
    /// snapping to either the automatic destination or the resting frame.
    pub fn interrupt(&mut self) {
        self.interrupted = true;
    }

    pub fn resume(&mut self) {
        self.interrupted = false;
    }

    pub fn target(&mut self, base: Frame, fitted: Frame, focus: Vec3) {
        let ratio = depth(fitted, focus) / depth(base, focus);
        let inverse = base.transform.rotation.inverse();
        self.target = Correction {
            pose: Pose {
                translation: inverse * (fitted.transform.translation - base.transform.translation),
                rotation: inverse * fitted.transform.rotation,
            },
            rect: [
                (fitted.rect[0] * ratio - base.rect[0]) / base.rect[2],
                (fitted.rect[1] * ratio - base.rect[1]) / base.rect[3],
                fitted.rect[2] * ratio / base.rect[2],
                fitted.rect[3] * ratio / base.rect[3],
            ],
        };
    }
    pub fn advance(&mut self, dt: f32, zoom_in: f32, zoom_out: f32) {
        if self.interrupted { return; }
        let expanding = self.target.rect[2] > self.current.rect[2]
            || self.target.rect[3] > self.current.rect[3];
        let weight = decay_step(
            0.0,
            1.0,
            dt.clamp(0.0, 0.25),
            if expanding { zoom_out } else { zoom_in },
        );
        self.current.pose.translation = self
            .current
            .pose
            .translation
            .lerp(self.target.pose.translation, weight);
        self.current.pose.rotation = self
            .current
            .pose
            .rotation
            .slerp(self.target.pose.rotation, weight)
            .normalize();
        for (current, target) in self.current.rect.iter_mut().zip(self.target.rect) {
            *current += (target - *current) * weight;
        }
        // Finish below visual precision. An asymptotic pose keeps changing
        // depth-plane uniforms after the eye can no longer see any motion,
        // preventing render-on-demand clients from returning to sleep.
        if self.current.pose.translation.distance(self.target.pose.translation)
            <= 0.000001 * self.target.pose.translation.length().max(1.0)
            && self.current.pose.rotation.angle_between(self.target.pose.rotation).abs() <= 0.000001
            && self.current.rect.iter().zip(self.target.rect)
                .all(|(current, target)| (current - target).abs() <= 0.000001 * target.abs().max(1.0))
        {
            self.current = self.target;
        }
    }
    pub fn apply(&self, base: Frame, focus: Vec3) -> Frame {
        let c = self.current;
        let mut result = Frame {
            transform: Pose {
                translation: base.transform.translation
                    + base.transform.rotation * c.pose.translation,
                rotation: base.transform.rotation * c.pose.rotation,
            },
            rect: [
                base.rect[0] + c.rect[0] * base.rect[2],
                base.rect[1] + c.rect[1] * base.rect[3],
                base.rect[2] * c.rect[2],
                base.rect[3] * c.rect[3],
            ],
        };
        let ratio = depth(base, focus) / depth(result, focus);
        for coordinate in &mut result.rect {
            *coordinate *= ratio;
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use glam::{Quat, Vec3};
    #[test]
    fn settled_projection_stops_changing_and_can_move_again() {
        let base = Frame {
            transform: Pose::from_xyz(0.0, 0.0, 4.0),
            rect: [-0.5, -0.5, 1.0, 1.0],
        };
        let fitted = Frame {
            transform: Pose::from_xyz(0.4, 0.2, 3.0)
                .with_rotation(Quat::from_rotation_y(0.1)),
            rect: [-0.6, -0.6, 1.2, 1.2],
        };
        let mut filter = AdaptiveProjection::default();
        filter.target(base, fitted, Vec3::ZERO);
        for _ in 0..600 { filter.advance(1.0 / 60.0, 0.6, 0.3); }
        filter.target(base, base, Vec3::ZERO);
        for _ in 0..3600 { filter.advance(1.0 / 60.0, 10.0, 1.5); }
        for _ in 0..120 {
            assert_eq!(filter.apply(base, Vec3::ZERO), base);
            filter.advance(1.0 / 60.0, 10.0, 1.5);
        }
        filter.target(base, fitted, Vec3::ZERO);
        filter.advance(1.0 / 60.0, 10.0, 1.5);
        assert_ne!(filter.apply(base, Vec3::ZERO), base);
    }
    #[test]
    fn manual_navigation_holds_the_displayed_frame_until_resumed() {
        let base = Frame {
            transform: Pose::from_xyz(0.0, 0.0, 4.0),
            rect: [-0.5, -0.5, 1.0, 1.0],
        };
        let fitted = Frame {
            transform: Pose::from_xyz(0.4, 0.2, 1.0),
            rect: [-1.5, -1.5, 3.0, 3.0],
        };
        let mut filter = AdaptiveProjection::default();
        filter.target(base, fitted, Vec3::ZERO);
        filter.advance(0.1, 10.0, 1.5);
        let shown = filter.apply(base, Vec3::ZERO);
        assert_ne!(shown, base);
        assert_ne!(shown, fitted);
        filter.interrupt();
        // Content changes and the typing idle timeout cannot resume motion.
        for target in [base, fitted] {
            for _ in 0..600 {
                filter.target(base, target, Vec3::ZERO);
                filter.advance(1.0 / 60.0, 10.0, 1.5);
                assert_eq!(filter.apply(base, Vec3::ZERO), shown);
            }
        }
        // User pan/zoom remains immediate while the correction is frozen.
        let manual = Frame {
            transform: Pose::from_xyz(2.0, 3.0, 4.0),
            rect: [-0.25, -0.25, 0.5, 0.5],
        };
        let moved = filter.apply(manual, Vec3::ZERO);
        assert_eq!(moved.transform.translation - shown.transform.translation, Vec3::new(2.0, 3.0, 0.0));
        assert_eq!(moved.rect[2], shown.rect[2] * 0.5);
        filter.resume();
        assert_eq!(filter.apply(manual, Vec3::ZERO), moved);
        filter.target(manual, manual, Vec3::ZERO);
        filter.advance(1.0 / 60.0, 10.0, 1.5);
        assert_ne!(filter.apply(manual, Vec3::ZERO), moved);
    }

    #[test]
    fn dolly_and_lens_fit_have_one_monotonic_screen_scale() {
        let base = Frame {
            transform: Pose::from_xyz(0.0, 0.0, 4.0),
            rect: [-0.5, -0.5, 1.0, 1.0],
        };
        let fitted = Frame {
            transform: Pose::from_xyz(0.4, 0.2, 1.0),
            rect: [-1.5, -1.5, 3.0, 3.0],
        };
        let focus = Vec3::ZERO;
        let mut filter = AdaptiveProjection::default();
        let mut previous = 4.0;
        for target in [fitted, base] {
            let endpoint = depth(target, focus) * target.rect[2];
            let direction = (endpoint - previous).signum();
            for _ in 0..900 {
                filter.target(base, target, focus);
                filter.advance(1.0 / 60.0, 0.6, 0.3);
                let shown = filter.apply(base, focus);
                let size = depth(shown, focus) * shown.rect[2];
                assert!((size - previous) * direction >= -0.00001,
                    "screen scale reversed: {previous} -> {size}, goal {endpoint}");
                previous = size;
            }
            assert!((previous - endpoint).abs() < 0.0001);
        }
    }

    #[test]
    fn fit_and_release_never_jump_or_advance_on_queries() {
        let base = Frame {
            transform: Pose::IDENTITY,
            rect: [-0.5, -0.5, 1.0, 1.0],
        };
        let fitted = Frame {
            transform: Pose::from_xyz(2.0, 1.0, 0.0).with_rotation(Quat::from_rotation_y(0.2)),
            rect: [-1.0, -0.8, 2.0, 2.0],
        };
        let mut filter = AdaptiveProjection::default();
        let focus = Vec3::new(0.0, 0.0, -4.0);
        for _ in 0..20 {
            filter.target(base, fitted, focus);
            assert_eq!(filter.apply(base, focus), base);
        }
        filter.advance(1.0 / 60.0, 10.0, 1.5);
        let first = filter.apply(base, focus);
        assert!(first.rect[2] > 1.0 && first.rect[2] < 1.1);
        assert!(first.transform.translation.length() < 0.2);
        for _ in 0..600 {
            filter.advance(1.0 / 60.0, 10.0, 1.5);
        }
        let held = filter.apply(base, focus);
        assert!((held.rect[2] - 2.0).abs() < 0.001);
        filter.target(base, base, focus); // typing ends, or adaptive ownership goes away
        assert_eq!(filter.apply(base, focus), held);
        filter.advance(1.0 / 60.0, 10.0, 1.5);
        let released = filter.apply(base, focus);
        assert!(released.rect[2] < held.rect[2] && released.rect[2] > 1.95);
        assert!(
            released
                .transform
                .translation
                .distance(held.transform.translation)
                < 0.05
        );
        // Manual navigation stays live; it is not passed through a second camera spring.
        let moved = Frame {
            transform: Pose::from_translation(Vec3::new(20.0, 0.0, 0.0)),
            ..base
        };
        assert!(
            (filter.apply(moved, focus + Vec3::new(20.0, 0.0, 0.0)).transform.translation.x - released.transform.translation.x - 20.0)
                .abs()
                < 0.001
        );
    }
}
