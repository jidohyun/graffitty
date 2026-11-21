//! Rigid camera pose, independent of a rendering engine or entity hierarchy.
use glam::{Mat3, Quat, Vec3};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pose {
    pub translation: Vec3,
    pub rotation: Quat,
}

impl Default for Pose {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl Pose {
    pub const IDENTITY: Self = Self {
        translation: Vec3::ZERO,
        rotation: Quat::IDENTITY,
    };

    pub const fn from_translation(translation: Vec3) -> Self {
        Self {
            translation,
            ..Self::IDENTITY
        }
    }

    pub const fn from_xyz(x: f32, y: f32, z: f32) -> Self {
        Self::from_translation(Vec3::new(x, y, z))
    }

    pub const fn with_rotation(mut self, rotation: Quat) -> Self {
        self.rotation = rotation;
        self
    }

    /// Orient local -Z toward `direction`, keeping local +Y toward `up`.
    /// Degenerate inputs use the same fallback axes as the existing renderer.
    pub fn looking_to(mut self, direction: Vec3, up: Vec3) -> Self {
        // Preserve direction normalization order at the former engine boundary:
        // dividing by length can round differently from multiplying its inverse.
        let normalize = |value: Vec3, fallback| {
            let length = value.length();
            if length.is_finite() && length > 0.0 {
                value / length
            } else {
                fallback
            }
        };
        let back = -normalize(direction, Vec3::NEG_Z);
        let up = normalize(up, Vec3::Y);
        let right = up
            .cross(back)
            .try_normalize()
            .unwrap_or_else(|| up.any_orthonormal_vector());
        let up = back.cross(right);
        self.rotation = Quat::from_mat3(&Mat3::from_cols(right, up, back));
        self
    }
}
