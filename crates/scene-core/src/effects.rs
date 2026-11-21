//! Typed world effects and bounded cursor geometry in canonical terminal pixels.
use anyhow::{Result, ensure};
use glam::Vec2;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Particles {
    None,
    Dots,
    Fireworks,
    Flames,
    Glitter,
    #[default]
    Sparks,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TrailStyle {
    #[default]
    None,
    Smear,
    Blaze,
    Lightning,
}
/// Godot `scene.tab_switch.effect`: none or scatter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TabTransition {
    /// Content changes at once; the camera still flies to the destination.
    None,
    /// Dust plus a density-dependent share of intact flying letters.
    #[default]
    Scatter,
}
impl TabTransition {
    pub const ALL: [Self; 2] = [Self::None, Self::Scatter];
    /// Godot's config/command value.
    pub fn name(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Scatter => "scatter",
        }
    }
    /// Godot's menu label (View › Tab Transition › …), a localization key.
    pub fn label(self) -> &'static str {
        match self {
            Self::None => "None",
            Self::Scatter => "Scatter",
        }
    }
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|value| value.name() == name)
    }
    pub fn animated(self) -> bool {
        self != Self::None
    }
    pub fn dust(self) -> bool {
        self == Self::Scatter
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct BlazeConfig {
    pub duration_ms: Option<u32>,
    pub color: String,
    pub accent_color: String,
}
impl Default for BlazeConfig {
    fn default() -> Self {
        Self {
            duration_ms: None,
            color: "#ffb929".into(),
            accent_color: "#ff0000".into(),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct LightningConfig {
    pub duration_ms: Option<u32>,
    pub color: String,
    pub glow_color: String,
    pub jaggedness: f32,
    pub core_width: f32,
    pub glow_width: f32,
}
impl Default for LightningConfig {
    fn default() -> Self {
        Self {
            duration_ms: None,
            color: "#ffb929".into(),
            glow_color: "#bd0000".into(),
            jaggedness: 0.085,
            core_width: 1.15,
            glow_width: 5.5,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct TrailConfig {
    pub style: TrailStyle,
    pub blaze: BlazeConfig,
    pub lightning: LightningConfig,
    pub delay_ms: u32,
    pub decay: [f32; 2],
    pub threshold: [f32; 2],
    pub duration_ms: u32,
    pub color: String,
    pub width: f32,
    pub jaggedness: f32,
}
impl Default for TrailConfig {
    fn default() -> Self {
        Self {
            style: TrailStyle::None,
            blaze: Default::default(),
            lightning: Default::default(),
            delay_ms: 40,
            decay: [0.1, 0.4],
            threshold: [2., 2.],
            duration_ms: 400,
            color: "#00000000".into(),
            width: 5.5,
            jaggedness: 0.085,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub intensity: f32,
    pub zoom: f32,
    pub tilt_degrees: f32,
    pub enter_ms: u32,
    pub hold_ms: u32,
    pub leave_ms: u32,
    pub ripple_degrees: f32,
    pub curvature_degrees: f32,
    pub particles: Particles,
    pub particle_amount: u32,
    pub particle_scale: f32,
    pub particle_speed: f32,
    pub particle_lifetime: f32,
    pub cursor_trail: TrailConfig,
    pub drift_pixels: f32,
    pub drift_speed: f32,
    pub shake_pixels: f32,
    pub shake_seconds: f32,
    pub follow_threshold: [f32; 2],
    pub overscroll: f32,
    pub ripple_wavelength: f32,
    pub ripple_falloff: f32,
    pub ripple_speed: f32,
    pub splash_scale: f32,
    pub splash_speed: f32,
    pub splash_life: f32,
    pub dof_blur_amount: f32,
    pub dof_tint: String,
    pub dof_tint_strength: f32,
    pub lighting_strength: f32,
    pub lighting_minimum: f32,
    pub lighting_maximum: f32,
    pub corner_radius: f32,
    pub edge_blur: f32,
    pub edge_shadow: f32,
    pub edge_shadow_width: f32,
    pub content_gloss: f32,
    pub tab_transition: TabTransition,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            intensity: 1.,
            zoom: 2.0,
            tilt_degrees: 18.,
            enter_ms: 800,
            hold_ms: 1500,
            leave_ms: 2500,
            ripple_degrees: 1.5,
            curvature_degrees: 3.,
            particles: Particles::Sparks,
            particle_amount: 12,
            particle_scale: 1.,
            particle_speed: 1.,
            particle_lifetime: 1.,
            cursor_trail: Default::default(),
            drift_pixels: 20.,
            drift_speed: 2.,
            shake_pixels: 0.,
            shake_seconds: 0.18,
            follow_threshold: [0.7, 0.7],
            overscroll: 1.,
            ripple_wavelength: 0.35,
            ripple_falloff: 0.3,
            ripple_speed: 2.5,
            splash_scale: 2.5,
            splash_speed: 900.,
            splash_life: 1.1,
            dof_blur_amount: 0.125,
            dof_tint: "#6f5fa8".into(),
            dof_tint_strength: 0.2,
            lighting_strength: 1.8,
            lighting_minimum: 0.,
            lighting_maximum: 1.4,
            corner_radius: 18.,
            edge_blur: 32.,
            edge_shadow: 0.,
            edge_shadow_width: 48.,
            content_gloss: 0.,
            tab_transition: TabTransition::default(),
        }
    }
}
impl Config {
    pub fn validate(&self) -> Result<()> {
        for (value, min, max, name) in [
            (self.intensity, 0., 2., "Intensity"),
            (self.zoom, 1., 3., "Typing zoom"),
            (self.tilt_degrees, 0., 90., "Tilt"),
            (self.ripple_degrees, 0., 5., "Ripple"),
            (self.curvature_degrees, 0., 15., "Curvature"),
            (self.particle_scale, 0.01, 100., "Particle scale"),
            (self.particle_speed, 0.05, 8., "Particle speed"),
            (self.particle_lifetime, 0.05, 8., "Particle lifetime"),
            (self.drift_pixels, 0., 10000., "Camera drift"),
            (self.drift_speed, 0., 100., "Drift speed"),
            (self.shake_pixels, 0., 10000., "Camera shake"),
            (self.shake_seconds, 0., 60., "Shake duration"),
            (
                self.follow_threshold[0],
                0.,
                1.,
                "Horizontal follow threshold",
            ),
            (
                self.follow_threshold[1],
                0.,
                1.,
                "Vertical follow threshold",
            ),
            (self.overscroll, 0., 10., "Overscroll"),
            (self.ripple_wavelength, 0.001, 100., "Ripple wavelength"),
            (self.ripple_falloff, 0.001, 100., "Ripple falloff"),
            (self.ripple_speed, 0., 100., "Ripple speed"),
            (self.splash_scale, 0., 100., "Splash scale"),
            (self.splash_speed, 0., 10000., "Splash speed"),
            (self.splash_life, 0.001, 60., "Splash life"),
            (self.dof_blur_amount, 0., 10., "Depth of field"),
            (self.dof_tint_strength, 0., 1., "Defocus tint"),
            (self.lighting_strength, 0., 10., "Ink lighting"),
            (
                self.lighting_minimum,
                0.,
                self.lighting_maximum,
                "Minimum ink light",
            ),
            (self.lighting_maximum, 0., 10., "Maximum ink light"),
            (self.corner_radius, 0., 10000., "Corner radius"),
            (self.edge_blur, 0., 10000., "Edge blur"),
            (self.edge_shadow, 0., 1., "Edge shadow"),
            (self.edge_shadow_width, 0., 10000., "Edge shadow width"),
            (self.content_gloss, 0., 1., "Content gloss"),
        ] {
            ensure!(
                value.is_finite() && (min..=max).contains(&value),
                "{name} must be {min}–{max}"
            );
        }
        ensure!(
            (1..=2048).contains(&self.particle_amount),
            "Particle amount must be 1–2048"
        );
        ensure!(
            (1..=10000).contains(&self.enter_ms)
                && (1..=10000).contains(&self.leave_ms)
                && self.hold_ms <= 10000,
            "Effect timing is outside 1–10000 ms (hold may be zero)"
        );
        crate::color::rgba(&self.dof_tint)?;
        let t = &self.cursor_trail;
        ensure!(
            t.delay_ms <= 10000 && (1..=60000).contains(&t.duration_ms),
            "Invalid cursor trail timing"
        );
        ensure!(
            t.decay
                .iter()
                .all(|v| v.is_finite() && (0.001..=60.).contains(v))
                && t.decay[0] <= t.decay[1],
            "Trail decay must be ordered within 0.001–60 seconds"
        );
        ensure!(
            t.threshold
                .iter()
                .all(|v| v.is_finite() && (0.0..=10000.).contains(v)),
            "Invalid cursor trail threshold"
        );
        ensure!(
            t.width.is_finite()
                && (0.1..=30.).contains(&t.width)
                && t.jaggedness.is_finite()
                && (0.0..=0.5).contains(&t.jaggedness),
            "Invalid trail width or jaggedness"
        );
        for value in [
            &t.color,
            &t.blaze.color,
            &t.blaze.accent_color,
            &t.lightning.color,
            &t.lightning.glow_color,
        ] {
            crate::color::rgba(value)?;
        }
        for value in [t.blaze.duration_ms, t.lightning.duration_ms]
            .into_iter()
            .flatten()
        {
            ensure!(
                (1..=60000).contains(&value),
                "Trail style duration must be 1–60000 ms"
            );
        }
        for (value, name) in [
            (t.lightning.core_width, "core width"),
            (t.lightning.glow_width, "glow width"),
        ] {
            ensure!(
                value.is_finite() && (0.001..=100.).contains(&value),
                "Lightning {name} must be 0.001–100"
            );
        }
        ensure!(
            t.lightning.jaggedness.is_finite() && (0.0..=1.).contains(&t.lightning.jaggedness),
            "Invalid lightning jaggedness"
        );
        Ok(())
    }
}

#[cfg(test)]
mod config_tests {
    use super::{Config, TabTransition};

    #[test]
    fn tab_transition_defaults_to_godot_scatter_and_round_trips() {
        assert_eq!(Config::default().tab_transition, TabTransition::Scatter);
        for effect in TabTransition::ALL {
            let json = serde_json::to_value(effect).unwrap();
            assert_eq!(json, effect.name());
            assert_eq!(TabTransition::from_name(effect.name()), Some(effect));
            assert_eq!(
                serde_json::from_value::<TabTransition>(json).unwrap(),
                effect
            );
        }
        // Older saved effects have no tab_transition key.
        let mut saved = serde_json::to_value(Config::default()).unwrap();
        saved.as_object_mut().unwrap().remove("tab_transition");
        assert_eq!(
            serde_json::from_value::<Config>(saved)
                .unwrap()
                .tab_transition,
            TabTransition::Scatter
        );
        // Removed choices are rejected.
        for legacy in ["dust_scatter", "dust", "push_pull"] {
            assert!(TabTransition::from_name(legacy).is_none());
            assert!(serde_json::from_value::<TabTransition>(legacy.into()).is_err());
        }
        assert!(TabTransition::from_name("shatter").is_none());
    }
}
impl TrailConfig {
    fn duration(&self) -> f32 {
        let value = match self.style {
            TrailStyle::Blaze => self.blaze.duration_ms,
            TrailStyle::Lightning => self.lightning.duration_ms,
            _ => None,
        };
        value.unwrap_or_else(|| {
            if self.duration_ms != 400 {
                self.duration_ms
            } else if self.style == TrailStyle::Lightning {
                140
            } else {
                500
            }
        }) as f32
            / 1000.
    }
}
fn effect_color(value: &str) -> [f32; 4] {
    crate::color::rgba(value)
        .unwrap_or([255; 4])
        .map(|c| c as f32 / 255.)
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Cursor {
    pub owner: u64,
    pub center: [f32; 2],
    pub size: [f32; 2],
    pub cell: [f32; 2],
    pub color: [f32; 4],
}
#[derive(Clone)]
pub struct Quad {
    pub points: [[f32; 2]; 4],
    pub color: [f32; 4],
}
#[derive(Default)]
pub struct Trail {
    owner: Option<u64>,
    pending: Option<Cursor>,
    target: Option<Cursor>,
    previous: Option<Cursor>,
    corners: [Vec2; 4],
    stable: f32,
    age: f32,
    active: bool,
    seed: u32,
}
fn corners(cursor: Cursor) -> [Vec2; 4] {
    let c = Vec2::from_array(cursor.center);
    let s = Vec2::from_array(cursor.size) * 0.5;
    [
        c + Vec2::new(s.x, -s.y),
        c - s,
        c + Vec2::new(-s.x, s.y),
        c + s,
    ]
}
impl Trail {
    pub fn clear(&mut self) {
        *self = Self::default();
    }
    pub fn active(&self) -> bool {
        self.active
    }
    pub fn update(&mut self, config: &TrailConfig, cursor: Option<Cursor>, dt: f32) -> Vec<Quad> {
        let Some(cursor) = cursor.filter(|c| {
            c.center.iter().chain(c.size.iter()).all(|v| v.is_finite())
                && c.size.iter().all(|v| *v > 0.)
        }) else {
            self.clear();
            return vec![];
        };
        if config.style == TrailStyle::None || config.delay_ms == 0 {
            self.clear();
            return vec![];
        }
        if self.owner != Some(cursor.owner) || self.target.is_none_or(|old| old.size != cursor.size)
        {
            self.clear();
            self.owner = Some(cursor.owner);
            self.pending = Some(cursor);
            self.target = Some(cursor);
            self.corners = corners(cursor);
            return vec![];
        }
        let dt = dt.max(0.);
        if self.pending != Some(cursor) {
            self.pending = Some(cursor);
            self.stable = 0.;
        } else {
            self.stable += dt;
        }
        if self.target != self.pending && self.stable * 1000. >= config.delay_ms as f32 {
            let old = self.target.unwrap();
            let distance = (Vec2::from_array(cursor.center) - Vec2::from_array(old.center)).abs()
                / Vec2::from_array(cursor.cell);
            self.previous = Some(old);
            self.target = Some(cursor);
            if self.active || distance.x > config.threshold[0] || distance.y > config.threshold[1] {
                self.active = true;
                self.age = 0.;
                self.seed = self.seed.wrapping_add(1);
            } else {
                self.corners = corners(cursor);
            }
        }
        if !self.active {
            return vec![];
        }
        self.age += dt;
        let target = self.target.unwrap();
        let target_corners = corners(target);
        let configured = effect_color(&config.color);
        let color = if configured[3] == 0. {
            cursor.color
        } else {
            configured
        };
        if config.style == TrailStyle::Smear {
            // Kitty's four-corner exponential response: leading corners arrive
            // sooner than trailing corners, independent of render frame rate.
            let center = Vec2::from_array(target.center);
            let dots: [f32; 4] = std::array::from_fn(|i| {
                (target_corners[i] - self.corners[i])
                    .normalize_or_zero()
                    .dot((target_corners[i] - center).normalize_or_zero())
            });
            let low = dots.iter().copied().fold(f32::INFINITY, f32::min);
            let high = dots.iter().copied().fold(f32::NEG_INFINITY, f32::max);
            for i in 0..4 {
                let mix = if high - low < 0.00001 {
                    0.
                } else {
                    (dots[i] - low) / (high - low)
                };
                let seconds = config.decay[1] + (config.decay[0] - config.decay[1]) * mix;
                self.corners[i] =
                    self.corners[i].lerp(target_corners[i], 1. - 2_f32.powf(-10. * dt / seconds));
            }
            self.active =
                (0..4).any(|i| (self.corners[i] - target_corners[i]).abs().max_element() >= 0.5);
            if !self.active {
                return vec![];
            }
            return vec![Quad {
                points: self.corners.map(|p| p.to_array()),
                color: [color[0], color[1], color[2], color[3] * 0.65],
            }];
        }
        let remaining = 1. - self.age / config.duration();
        if remaining <= 0. {
            self.active = false;
            return vec![];
        }
        let from = Vec2::from_array(self.previous.unwrap().center);
        let to = Vec2::from_array(target.center);
        let direction = (to - from).normalize_or_zero();
        let side = Vec2::new(-direction.y, direction.x);
        let length = from.distance(to);
        let segments = if config.style == TrailStyle::Lightning {
            20
        } else {
            12
        };
        let mut output = Vec::with_capacity(segments * 3);
        let point = |index: usize| {
            let t = index as f32 / segments as f32;
            let jitter = if index == 0 || index == segments {
                0.
            } else {
                let n = (index as u32)
                    .wrapping_mul(1664525)
                    .wrapping_add(self.seed.wrapping_mul(1013904223));
                ((n ^ (n >> 13)) % 1000) as f32 / 500. - 1.
            };
            let amplitude = if config.style == TrailStyle::Lightning {
                (if config.lightning.jaggedness != 0.085 {
                    config.lightning.jaggedness
                } else {
                    config.jaggedness
                }) * length
            } else {
                config.width * 0.5
            };
            from.lerp(to, t) + side * jitter * amplitude * remaining
        };
        for index in 0..segments {
            let a = point(index);
            let b = point(index + 1);
            let normal = Vec2::new(-(b - a).y, (b - a).x).normalize_or_zero();
            let layers = if config.style == TrailStyle::Blaze {
                [
                    (
                        config.width * 2.,
                        effect_color(&config.blaze.accent_color),
                        0.08,
                    ),
                    (config.width, effect_color(&config.blaze.color), 0.35),
                    (
                        config.width * 0.3,
                        effect_color(&config.blaze.accent_color),
                        0.8,
                    ),
                ]
            } else {
                let glow = if config.lightning.glow_width != 5.5 {
                    config.lightning.glow_width
                } else {
                    config.width
                };
                [
                    (glow * 2., effect_color(&config.lightning.glow_color), 0.06),
                    (glow, effect_color(&config.lightning.glow_color), 0.18),
                    (
                        config.lightning.core_width,
                        effect_color(&config.lightning.color),
                        0.8,
                    ),
                ]
            };
            for (width, tint, alpha) in layers {
                let w = width * remaining;
                output.push(Quad {
                    points: [
                        a - normal * w,
                        a + normal * w,
                        b + normal * w,
                        b - normal * w,
                    ]
                    .map(|p| p.to_array()),
                    color: [tint[0], tint[1], tint[2], tint[3] * alpha * remaining],
                });
            }
        }
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn cursor(x: f32) -> Cursor {
        Cursor {
            owner: 1,
            color: [1., 1., 1., 1.],
            center: [x, 30.],
            size: [10., 20.],
            cell: [10., 20.],
        }
    }
    #[test]
    fn transparent_smear_uses_actual_cursor_color_and_zero_delay_disables() {
        let mut config = TrailConfig {
            style: TrailStyle::Smear,
            delay_ms: 1,
            ..Default::default()
        };
        let mut old = cursor(10.);
        old.color = [0.1, 0.7, 0.3, 1.];
        let mut next = old;
        next.center[0] = 200.;
        let mut trail = Trail::default();
        trail.update(&config, Some(old), 0.);
        trail.update(&config, Some(next), 0.);
        let quads = trail.update(&config, Some(next), 0.002);
        assert_eq!(&quads[0].color[..3], &old.color[..3]);
        config.color = "#ff000080".into();
        let quads = trail.update(&config, Some(next), 0.);
        assert_eq!(&quads[0].color[..3], &[1., 0., 0.]);
        assert!((quads[0].color[3] - 128. / 255. * 0.65).abs() < 0.0001);
        config.delay_ms = 0;
        assert!(trail.update(&config, Some(next), 0.).is_empty());
        assert!(!trail.active());
    }
    #[test]
    fn per_style_colors_widths_and_duration_change_real_trail_quads() {
        let mut config = TrailConfig {
            style: TrailStyle::Blaze,
            delay_ms: 1,
            ..Default::default()
        };
        config.blaze.color = "#00ff00".into();
        config.blaze.accent_color = "#0000ff".into();
        let mut trail = Trail::default();
        trail.update(&config, Some(cursor(10.)), 0.);
        trail.update(&config, Some(cursor(200.)), 0.);
        let quads = trail.update(&config, Some(cursor(200.)), 0.002);
        assert_eq!(&quads[0].color[..3], &[0., 0., 1.]);
        assert_eq!(&quads[1].color[..3], &[0., 1., 0.]);
        config.style = TrailStyle::Lightning;
        config.lightning.color = "#ff0000".into();
        config.lightning.glow_color = "#0000ff".into();
        config.lightning.core_width = 2.;
        config.lightning.glow_width = 9.;
        config.lightning.jaggedness = 0.;
        config.lightning.duration_ms = Some(20);
        trail.clear();
        trail.update(&config, Some(cursor(10.)), 0.);
        trail.update(&config, Some(cursor(200.)), 0.);
        let quads = trail.update(&config, Some(cursor(200.)), 0.002);
        assert_eq!(quads.len(), 60);
        assert_eq!(&quads[0].color[..3], &[0., 0., 1.]);
        assert_eq!(&quads[2].color[..3], &[1., 0., 0.]);
        let width =
            |q: &Quad| Vec2::from_array(q.points[0]).distance(Vec2::from_array(q.points[1]));
        assert!((width(&quads[0]) / width(&quads[2]) - 9.).abs() < 0.001);
        assert!(trail.update(&config, Some(cursor(200.)), 0.03).is_empty());
    }
    #[test]
    fn validates_bounded_effects_and_rejects_nonfinite_parameters() {
        let mut c = Config::default();
        c.validate().unwrap();
        c.particle_amount = 2049;
        assert!(c.validate().is_err());
        c.particle_amount = 12;
        c.intensity = f32::NAN;
        assert!(c.validate().is_err());
        c.intensity = 1.;
        c.cursor_trail.decay = [0.4, 0.1];
        assert!(c.validate().is_err());
    }
    #[test]
    fn trail_waits_for_stable_cursor_and_decays_without_typing_input() {
        let config = TrailConfig {
            style: TrailStyle::Smear,
            ..Default::default()
        };
        let mut t = Trail::default();
        assert!(t.update(&config, Some(cursor(10.)), 0.).is_empty());
        assert!(t.update(&config, Some(cursor(200.)), 0.).is_empty());
        assert!(t.update(&config, Some(cursor(200.)), 0.02).is_empty());
        assert!(!t.update(&config, Some(cursor(200.)), 0.03).is_empty());
        for _ in 0..100 {
            t.update(&config, Some(cursor(200.)), 0.01);
        }
        assert!(!t.active());
    }
    #[test]
    fn trail_resets_on_owner_size_hidden_cursor_and_has_bounded_geometry() {
        for style in [TrailStyle::Smear, TrailStyle::Blaze, TrailStyle::Lightning] {
            let config = TrailConfig {
                style,
                delay_ms: 1,
                ..Default::default()
            };
            let mut t = Trail::default();
            t.update(&config, Some(cursor(10.)), 0.);
            t.update(&config, Some(cursor(800.)), 0.);
            let q = t.update(&config, Some(cursor(800.)), 0.002);
            assert!(!q.is_empty() && q.len() <= 60);
            let mut next = cursor(10.);
            next.owner = 2;
            assert!(t.update(&config, Some(next), 0.).is_empty());
            assert!(t.update(&config, None, 0.).is_empty());
            assert!(!t.active());
        }
    }
}
