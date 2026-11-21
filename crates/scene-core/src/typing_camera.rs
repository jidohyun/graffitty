//! Pixel-space controller and spatial framing from TerminalCameraController.gd
//! and CameraMotion.gd. Angles are radians; viewport/cell/pane sizes are pixels.
use crate::Pose;
use crate::camera_motion::Frame;
use glam::{Vec2, Vec3};

#[derive(Clone, Debug)]
pub struct TypingCamera {
    pub zoom: f32,
    pub target_zoom: f32,
    pub pan: Vec2,
    pub render_pan: Vec2,
    pub animated_cursor: Vec2,
    pub cursor_initialized: bool,
    pub tilt: Vec2,
    pub drift_radius: f32,
    pub drift_phase: f32,
    pub drift: Vec2,
    pub shake: Vec2,
    pub shake_left: f32,
    pub shake_amplitude: f32,
    pub rng: u32,
    pub cursor_anchor_pending: bool,
    pub cursor_anchor_set: bool,
    pub cursor_anchor_y: f32,
    pub cursor_anchor_grid_y: f32,
    pub framing_returning: bool,
    pub was_typing: bool,
    pub initialized: bool,
    pub follow_threshold: Vec2,
    pub overscroll: f32,
    pub follow_rect: Option<[f32; 4]>,
    pub unbounded_pan: bool,
    pub follow_top_inset: f32,
    /// Unobstructed screen rectangle in full-viewport logical pixels.
    pub visible_rect: Option<[f32; 4]>,
    viewport_size: Vec2,
}

impl Default for TypingCamera {
    fn default() -> Self {
        Self {
            zoom: 1.0,
            target_zoom: 1.0,
            pan: Vec2::ZERO,
            render_pan: Vec2::ZERO,
            animated_cursor: Vec2::ZERO,
            cursor_initialized: false,
            tilt: Vec2::ZERO,
            drift_radius: 0.0,
            drift_phase: 0.0,
            drift: Vec2::ZERO,
            shake: Vec2::ZERO,
            shake_left: 0.0,
            shake_amplitude: 0.0,
            rng: 0x9e3779b9,
            cursor_anchor_pending: false,
            cursor_anchor_set: false,
            cursor_anchor_y: 0.0,
            cursor_anchor_grid_y: 0.0,
            framing_returning: false,
            was_typing: false,
            initialized: false,
            follow_threshold: Vec2::splat(0.5),
            overscroll: 0.5,
            follow_rect: None,
            unbounded_pan: false,
            follow_top_inset: 0.0,
            visible_rect: None,
            viewport_size: Vec2::ZERO,
        }
    }
}

impl TypingCamera {
    pub fn configure(&mut self, follow_threshold: Vec2, overscroll: f32) {
        self.follow_threshold = follow_threshold.clamp(Vec2::ZERO, Vec2::ONE);
        self.overscroll = overscroll.max(0.0);
    }

    pub fn reset(&mut self, viewport: Vec2) {
        self.viewport_size = viewport;
        self.zoom = 1.0;
        self.target_zoom = 1.0;
        self.pan = viewport * 0.5;
        self.render_pan = self.pan;
        self.animated_cursor = self.pan;
        self.cursor_initialized = false;
        self.tilt = Vec2::ZERO;
        self.drift_radius = 0.0;
        self.drift_phase = 0.0;
        self.drift = Vec2::ZERO;
        self.shake = Vec2::ZERO;
        self.shake_left = 0.0;
        self.shake_amplitude = 0.0;
        self.cursor_anchor_pending = false;
        self.cursor_anchor_set = false;
        self.framing_returning = false;
        self.was_typing = false;
        self.initialized = true;
    }

    pub fn typed(&mut self, amplitude: f32, seconds: f32) {
        if self.shake_left <= 0.0 && amplitude > 0.0 && seconds > 0.0 {
            self.shake_left = seconds;
            self.shake_amplitude = amplitude;
        }
    }

    fn frand(&mut self) -> f32 {
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 17;
        self.rng ^= self.rng << 5;
        (f64::from(self.rng) / 4294967295.0 * 2.0 - 1.0) as f32
    }

    pub fn follow_target(
        &self,
        cursor: Vec2,
        viewport: Vec2,
        camera_zoom: f32,
        anchored: bool,
        cell: Vec2,
    ) -> Vec2 {
        let [origin, extent] = visible_area(viewport, self.visible_rect);
        let offset = origin + extent * 0.5 - viewport * 0.5;
        let mut bias = ((self.follow_threshold - Vec2::splat(0.5)) * extent + offset) / camera_zoom;
        if anchored {
            bias.y = bias.y.max(self.cursor_anchor_y * viewport.y / camera_zoom);
        }
        let [low, high] = cell_bounds(cursor, viewport, cell, camera_zoom, self.visible_rect);
        let want = (cursor - bias).clamp(low, high);
        if let Some([x, y, w, h]) = self.follow_rect.filter(|r| r[2] > 0.0 && r[3] > 0.0)
            && (camera_zoom > 1.0 || (self.unbounded_pan && self.was_typing))
        {
            let mut focused = Vec2::new(
                pane_follow(want.x, x, w, viewport.x, origin.x, extent.x, camera_zoom),
                pane_follow(want.y, y, h, viewport.y, origin.y, extent.y, camera_zoom),
            );
            focused.y = focused
                .y
                .min(y + (viewport.y * 0.5 - origin.y - self.follow_top_inset) / camera_zoom);
            return focused.clamp(low, high);
        }
        Vec2::new(
            follow_pan(want.x, viewport.x, camera_zoom),
            follow_pan(want.y, viewport.y, camera_zoom),
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn advance(
        &mut self,
        dt: f32,
        cursor: Vec2,
        viewport: Vec2,
        cell: Vec2,
        new_target_zoom: f32,
        tilt_limit: f32,
        drift_target: f32,
        drift_speed: f32,
        typing: bool,
        transition_decay: f32,
        constrain_cursor: bool,
    ) {
        let dt = dt.clamp(0.0, 0.25);
        if !self.initialized {
            self.reset(viewport);
        }
        if viewport.x <= 0.0 || viewport.y <= 0.0 {
            return;
        }
        if self.viewport_size != viewport {
            if self.viewport_size.x > 0.0 && self.viewport_size.y > 0.0 {
                let scale = viewport / self.viewport_size;
                self.pan *= scale;
                self.render_pan *= scale;
                self.animated_cursor *= scale;
                self.cursor_anchor_grid_y *= scale.y;
            }
            self.viewport_size = viewport;
        }
        if typing && !self.was_typing {
            self.cursor_anchor_pending = true;
            self.framing_returning = false;
        } else if !typing && self.was_typing {
            self.framing_returning = self.cursor_anchor_set;
        }
        self.was_typing = typing;
        if self.cursor_anchor_pending {
            self.cursor_anchor_y = (cursor.y - self.pan.y) * self.zoom / viewport.y;
            self.cursor_anchor_grid_y = cursor.y;
            self.cursor_anchor_pending = false;
            self.cursor_anchor_set = true;
        }
        if !self.unbounded_pan {
            self.pan = clamp_pan_vec(self.pan, viewport, self.zoom, self.overscroll);
        }
        self.target_zoom = new_target_zoom.max(0.25);
        let old_zoom = self.zoom;
        self.zoom = decay_step(self.zoom, self.target_zoom, dt, transition_decay);
        if self.cursor_anchor_set
            && cell.y > 0.0
            && (cursor.y - self.cursor_anchor_grid_y).abs() > cell.y * 1.5
        {
            self.cursor_anchor_set = false;
            self.framing_returning = false;
        }
        let visible_cell = if constrain_cursor { cell } else { Vec2::ZERO };
        let destination = self.follow_target(
            cursor,
            viewport,
            self.target_zoom,
            self.cursor_anchor_set && !self.framing_returning,
            visible_cell,
        );
        let old_pan = self.pan;
        let old_shift = (viewport * 0.5 - self.pan) * old_zoom;
        let target_shift = (viewport * 0.5 - destination) * self.target_zoom;
        let shift = decay_vec(old_shift, target_shift, dt, transition_decay);
        self.pan = viewport * 0.5 - shift / self.zoom;
        if !self.unbounded_pan {
            self.pan = clamp_pan_vec(self.pan, viewport, self.zoom, self.overscroll);
        }
        if !self.cursor_initialized {
            self.animated_cursor = cursor;
            self.cursor_initialized = true;
        } else {
            self.animated_cursor = decay_vec(self.animated_cursor, cursor, dt, transition_decay);
        }
        if self.framing_returning
            && (self.zoom - self.target_zoom).abs() < 1e-5
            && (self.pan.distance(destination) < 1e-4
                || (dt > 0. && self.pan == old_pan && self.zoom == old_zoom))
        {
            // At native pixel coordinates, f32 rounding can stop exponential
            // steps before the absolute epsilon is reached.
            //
            // Finish that stationary return exactly instead of keeping a
            // permanent frame deadline for a camera which can no longer move.
            self.pan = destination;
            self.zoom = self.target_zoom;
            self.cursor_anchor_set = false;
            self.framing_returning = false;
        }
        if self.shake_left > 0.0 {
            self.shake_left -= dt;
            self.shake = if self.shake_left <= 0.0 {
                Vec2::ZERO
            } else {
                Vec2::new(self.frand(), self.frand()) * (self.shake_amplitude / self.zoom)
            };
        } else {
            self.shake = Vec2::ZERO;
        }
        self.drift_radius = decay_step(
            self.drift_radius,
            if typing { drift_target } else { 0.0 },
            dt,
            transition_decay,
        );
        if self.drift_radius > 0.01 {
            self.drift_phase += dt * drift_speed;
            self.drift = Vec2::new(self.drift_phase.sin(), self.drift_phase.cos())
                * (self.drift_radius / self.zoom);
        } else {
            self.drift = Vec2::ZERO;
        }
        let [low, high] = cell_bounds(cursor, viewport, visible_cell, self.zoom, self.visible_rect);
        let decorated = Vec2::new(
            decorated_pan(self.pan.x, self.shake.x + self.drift.x, low.x, high.x),
            decorated_pan(self.pan.y, self.shake.y + self.drift.y, low.y, high.y),
        );
        self.render_pan = if !self.unbounded_pan && (self.zoom - 1.0).abs() > 1e-6 {
            clamp_pan_vec(decorated, viewport, self.zoom, self.overscroll)
        } else {
            decorated
        };
        // Bounds constrain the rendered pose, not just the destination or decoration.
        // A dock resize/cursor jump can invalidate the eased base pan immediately.
        if self.visible_rect.is_some() {
            self.render_pan = self.render_pan.clamp(low, high);
        }
        let framed = self.follow_target(
            cursor,
            viewport,
            self.target_zoom,
            self.cursor_anchor_set,
            Vec2::ZERO,
        );
        let lean = ((cursor - framed) * 2.0 * self.target_zoom / viewport)
            .clamp(Vec2::splat(-1.0), Vec2::ONE);
        self.tilt = decay_vec(self.tilt, -lean * tilt_limit, dt, transition_decay);
        if !typing && self.tilt.length_squared() < 1e-10 {
            // Residual exponential tilt changes the exact camera transform
            // indefinitely, keeping the scenery cache dirty after motion is
            // far below a pixel. Retire it at the visible rest pose.
            self.tilt = Vec2::ZERO;
        }
    }
}

/// The projection keeps full-window coordinates; only this region is usable.
/// Owns the offset/extent conversion so camera framing never treats docks as content.
#[derive(Clone, Copy, Debug)]
pub struct CameraViewport {
    full: Vec2,
    origin: Vec2,
    extent: Vec2,
}
impl CameraViewport {
    pub fn new(full: Vec2, rect: Option<[f32; 4]>) -> Self {
        let (origin, extent) = match rect {
            Some([x, y, w, h]) if w > 0.0 && h > 0.0 => (Vec2::new(x, y), Vec2::new(w, h)),
            _ => (Vec2::ZERO, full),
        };
        Self {
            full,
            origin,
            extent,
        }
    }

    fn offset(self, zoom: f32) -> Vec2 {
        (self.origin + self.extent * 0.5 - self.full * 0.5) / zoom
    }

    pub fn cell_bounds(self, cursor: Vec2, cell: Vec2, zoom: f32) -> [Vec2; 2] {
        if cell.x <= 0.0 || cell.y <= 0.0 || zoom <= 0.0 {
            return [Vec2::splat(f32::NEG_INFINITY), Vec2::splat(f32::INFINITY)];
        }
        let progress = (zoom - 1.0).clamp(0.0, 1.0);
        let margin = (self.extent * 0.1).min((cell * zoom).max(Vec2::splat(16.0))) * progress;
        let reach = (cell * 0.5).max((self.extent * 0.5 - margin) / zoom);
        let offset = self.offset(zoom);
        [
            cursor + cell * 0.5 - reach - offset,
            cursor - cell * 0.5 + reach - offset,
        ]
    }
}

pub fn visible_area(viewport: Vec2, rect: Option<[f32; 4]>) -> [Vec2; 2] {
    let area = CameraViewport::new(viewport, rect);
    [area.origin, area.extent]
}

fn pane_follow(
    want: f32,
    origin: f32,
    extent: f32,
    viewport: f32,
    visible_origin: f32,
    visible_extent: f32,
    zoom: f32,
) -> f32 {
    let offset = (visible_origin + visible_extent * 0.5 - viewport * 0.5) / zoom;
    let half = visible_extent / (2.0 * zoom);
    if extent <= half * 2.0 {
        (viewport * 0.5).clamp(origin + extent - half - offset, origin + half - offset)
    } else {
        want.clamp(origin + half - offset, origin + extent - half - offset)
    }
}

pub fn cell_bounds(
    cursor: Vec2,
    viewport: Vec2,
    cell: Vec2,
    zoom: f32,
    visible: Option<[f32; 4]>,
) -> [Vec2; 2] {
    CameraViewport::new(viewport, visible).cell_bounds(cursor, cell, zoom)
}
pub fn decay_step(current: f32, target: f32, dt: f32, decay: f32) -> f32 {
    if dt <= 0.0 || decay <= 0.0 {
        current
    } else {
        current + (target - current) * (1.0 - (-10.0 * dt / decay).exp2())
    }
}
fn decay_vec(current: Vec2, target: Vec2, dt: f32, decay: f32) -> Vec2 {
    Vec2::new(
        decay_step(current.x, target.x, dt, decay),
        decay_step(current.y, target.y, dt, decay),
    )
}
pub fn clamp_pan(value: f32, extent: f32, zoom: f32, overscroll: f32) -> f32 {
    if extent <= 0.0 {
        return 0.0;
    }
    let half = extent / (2.0 * zoom.max(1e-4));
    let slack = if overscroll > 0.0 {
        overscroll * half.min(extent * 0.5)
    } else {
        0.0
    };
    let low = if zoom < 1.0 { extent - half } else { half } - slack;
    let high = if zoom < 1.0 { half } else { extent - half } + slack;
    if low >= high {
        extent * 0.5
    } else {
        value.clamp(low, high)
    }
}
fn clamp_pan_vec(value: Vec2, extent: Vec2, zoom: f32, overscroll: f32) -> Vec2 {
    Vec2::new(
        clamp_pan(value.x, extent.x, zoom, overscroll),
        clamp_pan(value.y, extent.y, zoom, overscroll),
    )
}
/// Fit occupied terminal content with two columns/four rows of breathing room.
/// Coordinates already include manual navigation; max_zoom compensates that
/// scale so an overview can approach a tiny pane without editing saved navigation.
pub fn adaptive_fit(full: Vec2, visible: [f32; 4], content: [f32; 4], cell: Vec2, max_zoom: f32) -> (Vec2, f32) {
    let viewport = CameraViewport::new(full, Some(visible));
    let size = Vec2::new(content[2], content[3]).max(cell);
    let padding = cell * Vec2::new(2.0, 4.0);
    let padded = (size + padding * 2.0).max(Vec2::splat(0.001));
    // This is a typing approach, not a replacement for manual Fit. Padding
    // around a full terminal must not shrink an already comfortable view.
    //
    // Coordinates include manual navigation, so 1 means preserve that view;
    // even an existing manual scale above the automatic cap wins over the
    // cap.
    let zoom = (viewport.extent * 0.9 / padded).min_element().min(max_zoom).max(1.0);
    let center = Vec2::new(content[0], content[1]) + size * 0.5;
    (center - viewport.offset(zoom), zoom)
}

/// The share of a frame around both rectangles that would be empty gap
/// between them: the separation along each axis divided by the union's extent
/// on that axis, the larger of the two.
///
/// Overlapping or touching rectangles score 0. Zoom- and font-size-invariant,
/// so one threshold fits every pane scale.
pub fn gap_fraction(a: [f32; 4], b: [f32; 4]) -> f32 {
    let mut worst = 0.0f32;
    for axis in 0..2 {
        let (a0, a1) = (a[axis], a[axis] + a[axis + 2]);
        let (b0, b1) = (b[axis], b[axis] + b[axis + 2]);
        let gap = (b0 - a1).max(a0 - b1).max(0.0);
        let extent = a1.max(b1) - a0.min(b0);
        if extent > 0.0 {
            worst = worst.max(gap / extent);
        }
    }
    worst
}

/// Frame a companion pane together with the focused content when the gap
/// between them would waste at most `max_gap` of the frame (see
/// [`gap_fraction`]).
///
/// Returns the union to fit, or `None` to keep the focused content alone.
/// `max_gap >= 1` accepts any distance.
pub fn group_fit(content: [f32; 4], companion: [f32; 4], max_gap: f32) -> Option<[f32; 4]> {
    if companion[2] <= 0.0 || companion[3] <= 0.0 || !max_gap.is_finite() || max_gap < 0.0 {
        return None;
    }
    (gap_fraction(content, companion) <= max_gap).then(|| {
        let left = content[0].min(companion[0]);
        let top = content[1].min(companion[1]);
        let right = (content[0] + content[2]).max(companion[0] + companion[2]);
        let bottom = (content[1] + content[3]).max(companion[1] + companion[3]);
        [left, top, right - left, bottom - top]
    })
}

/// How long a smaller content footprint must persist before adaptive framing
/// shrinks (zooms in) to it. Growth is never delayed.
pub const FRAMING_SHRINK_SETTLE_MS: u64 = 600;

/// Stabilize the rectangle adaptive zoom fits, in cells
/// (`[left, top, width, height]`). Programs such as Neovim clear and repaint
/// the alternate screen in stages. Fitting each frame makes zoom jump.
///
/// - Grow immediately to the union of the observed and current rectangles.
/// - Shrink only after the smaller rectangle stays unchanged for
///   [`FRAMING_SHRINK_SETTLE_MS`]. A real change such as `clear` can still retarget.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct FramingSettle {
    pub accepted: Option<[i32; 4]>,
    pub pending: Option<[i32; 4]>,
    pub pending_since_ms: u64,
}

fn rect_union(a: [i32; 4], b: [i32; 4]) -> [i32; 4] {
    let left = a[0].min(b[0]);
    let top = a[1].min(b[1]);
    let right = (a[0] + a[2]).max(b[0] + b[2]);
    let bottom = (a[1] + a[3]).max(b[1] + b[3]);
    [left, top, right - left, bottom - top]
}

impl FramingSettle {
    pub fn observe(&mut self, observed: [i32; 4], now_ms: u64) -> [i32; 4] {
        let Some(mut accepted) = self.accepted else {
            *self = Self { accepted: Some(observed), pending: None, pending_since_ms: now_ms };
            return observed;
        };
        let grown = rect_union(accepted, observed);
        if grown != accepted {
            accepted = grown;
        }
        if observed == accepted {
            self.pending = None;
        } else if self.pending != Some(observed) {
            self.pending = Some(observed);
            self.pending_since_ms = now_ms;
        } else if now_ms.saturating_sub(self.pending_since_ms) >= FRAMING_SHRINK_SETTLE_MS {
            accepted = observed;
            self.pending = None;
        }
        self.accepted = Some(accepted);
        accepted
    }
}

/// Final presentation safety pass. Fit actual projected geometry, not an
/// untransformed text box. No padding is added and an already-fitting frame is
/// unchanged. `visible` is normalized screen space (top-left origin).
pub fn contain_projected(mut frame: Frame, points: &[Vec3], visible: [f32; 4], near: f32) -> Frame {
    if points.is_empty() || points.iter().any(|p| !p.is_finite()) { return frame; }
    let (forward, right, up) = axes(frame);
    let depth = points.iter().map(|p| (*p - frame.transform.translation).dot(forward)).fold(f32::INFINITY, f32::min);
    let safe_depth = near.max(0.001) * 2.0;
    if depth < safe_depth { frame.transform.translation -= forward * (safe_depth - depth); }
    let mut low = Vec2::splat(f32::INFINITY);
    let mut high = Vec2::splat(f32::NEG_INFINITY);
    for point in points {
        let relative = *point - frame.transform.translation;
        let z = relative.dot(forward).max(safe_depth);
        let projected = Vec2::new(relative.dot(right), relative.dot(up)) / z;
        low = low.min(projected);
        high = high.max(projected);
    }
    let safe_origin = Vec2::new(visible[0], 1.0 - visible[1] - visible[3]);
    let safe_size = Vec2::new(visible[2], visible[3]).clamp(Vec2::splat(0.001), Vec2::ONE);
    let size = Vec2::new(frame.rect[2], frame.rect[3]);
    let factor = ((high - low) / (size * safe_size)).max_element().max(1.0);
    let expanded = size * factor;
    let origin = Vec2::new(frame.rect[0], frame.rect[1]) - (expanded - size) * 0.5;
    let lower = high - (safe_origin + safe_size) * expanded;
    let upper = low - safe_origin * expanded;
    // Roundoff can invert an exactly fitted interval by a few ulps.
    let origin = origin.clamp(lower.min(upper), lower.max(upper));
    frame.rect = [origin.x, origin.y, expanded.x, expanded.y];
    frame
}

/// Orthographic adapter using the same projected-envelope solver as 3D.
pub fn contain_canvas(full: Vec2, visible: [f32; 4], content: [f32; 4], center: Vec2, zoom: f32) -> (Vec2, f32) {
    let base = pose(Vec3::new(center.x, -center.y, 1.0 / zoom.max(0.001)),
        -Vec3::Z, Vec3::Y, [-full.x * 0.5, -full.y * 0.5, full.x, full.y]);
    let points = [Vec3::new(content[0], -content[1], 0.0),
        Vec3::new(content[0] + content[2], -content[1] - content[3], 0.0)];
    let fitted = contain_projected(base, &points, visible, 0.00001);
    let r = fitted.rect;
    let depth = fitted.transform.translation.z;
    (Vec2::new(fitted.transform.translation.x + (r[0] + r[2] * 0.5) * depth,
        -fitted.transform.translation.y - (r[1] + r[3] * 0.5) * depth), full.x / (r[2] * depth))
}

pub fn follow_pan(cursor: f32, extent: f32, zoom: f32) -> f32 {
    if zoom <= 1.0 {
        extent * 0.5
    } else {
        clamp_pan(cursor, extent, zoom, 0.0)
    }
}
pub fn decorated_pan(value: f32, offset: f32, low: f32, high: f32) -> f32 {
    let decorated = value + offset;
    decorated
        .clamp(low, high)
        .clamp(value.min(decorated), value.max(decorated))
}

fn pose(eye: Vec3, forward: Vec3, up: Vec3, rect: [f32; 4]) -> Frame {
    Frame {
        transform: Pose::from_translation(eye).looking_to(forward, up),
        rect,
    }
}
fn axes(frame: Frame) -> (Vec3, Vec3, Vec3) {
    let q = frame.transform.rotation;
    (-(q * Vec3::Z), q * Vec3::X, q * Vec3::Y)
}
fn tilted_axes(forward: Vec3, right: Vec3, up: Vec3, tilt: Vec2) -> (Vec3, Vec3, Vec3) {
    let yawed = (forward * tilt.x.cos() + right * tilt.x.sin()).normalize();
    let nf = (yawed * (-tilt.y).cos() + up * (-tilt.y).sin()).normalize();
    let nu = (up * (-tilt.y).cos() - yawed * (-tilt.y).sin()).normalize();
    let nr = nf.cross(nu).normalize();
    (nf, nr, nr.cross(nf).normalize())
}

#[allow(clippy::too_many_arguments)]
pub fn compose(
    base: Frame,
    zoom: f32,
    pan: Vec2,
    tilt: Vec2,
    center: Vec3,
    axis_u: Vec3,
    axis_v: Vec3,
    cursor: Vec3,
    near: f32,
    constrain_cursor: bool,
) -> Frame {
    let (mut forward, mut right, mut up) = axes(base);
    let mut eye = base.transform.translation;
    eye += (center - eye) * (1.0 - 1.0 / zoom.max(0.25)) + (axis_u * pan.x + axis_v * pan.y) * 0.5;
    if tilt.length_squared() > 1e-8 {
        let (nf, nr, nu) = tilted_axes(forward, right, up, tilt);
        let relative = cursor - eye;
        let depth = relative.dot(forward);
        if depth > near {
            let x = relative.dot(right) / depth;
            let y = relative.dot(up) / depth;
            let ray = nf + nr * x + nu * y;
            let normal = axis_u.cross(axis_v).normalize();
            let before = normal.dot(forward + right * x + up * y).abs();
            let after = normal.dot(ray).abs();
            let mut approach = forward.dot(nf).clamp(0.25, 1.0);
            if before > 1e-6 {
                approach *= (after / before).sqrt().min(1.0);
            }
            eye = cursor - ray * (depth * approach).max(near * 2.0);
        }
        forward = nf;
        right = nr;
        up = nu;
    }
    if constrain_cursor {
        eye = keep_cursor_in_view(
            eye,
            forward,
            right,
            up,
            base.rect,
            cursor,
            near,
            0.15 * (zoom - 1.0).clamp(0.0, 1.0),
        );
    }
    pose(eye, forward, up, base.rect)
}

#[allow(clippy::too_many_arguments)]
pub fn keep_cursor_in_view(
    mut eye: Vec3,
    forward: Vec3,
    right: Vec3,
    up: Vec3,
    rect: [f32; 4],
    point: Vec3,
    near: f32,
    margin: f32,
) -> Vec3 {
    let mut relative = point - eye;
    let mut depth = relative.dot(forward);
    if depth <= near * 2.0 {
        eye -= forward * (near * 2.0 - depth);
        relative = point - eye;
        depth = relative.dot(forward);
    }
    let x = relative.dot(right) / depth;
    let y = relative.dot(up) / depth;
    eye + (right
        * (x - x.clamp(
            rect[0] + rect[2] * margin,
            rect[0] + rect[2] * (1.0 - margin),
        ))
        + up * (y - y.clamp(
            rect[1] + rect[3] * margin,
            rect[1] + rect[3] * (1.0 - margin),
        )))
        * depth
}

/// Dolly and pan a pane whose sheet fills the reference frustum at `distance`.
pub fn frame_pane(base: Frame, zoom: f32, pan: Vec2, tilt: Vec2, distance: f32) -> Frame {
    let (forward, right, up) = axes(base);
    let dolly = distance * (1. - 1. / zoom.max(0.25));
    let r = base.rect;
    let center = Vec2::new(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5);
    let eye = base.transform.translation
        + forward * dolly
        + right * (distance * r[2] * pan.x * 0.5 + center.x * dolly)
        + up * (-distance * r[3] * pan.y * 0.5 + center.y * dolly);
    lean(pose(eye, forward, up, r), tilt, distance - dolly)
}

pub fn frame_sheet(
    base: Frame,
    zoom: f32,
    pan: Vec2,
    tilt: Vec2,
    center: Vec3,
    axis_u: Vec3,
    axis_v: Vec3,
) -> Frame {
    let (forward, _, up) = axes(base);
    let mut eye = base.transform.translation;
    eye += (center - eye) * (1.0 - 1.0 / zoom.max(0.01)) + (axis_u * pan.x + axis_v * pan.y) * 0.5;
    lean(
        pose(eye, forward, up, base.rect),
        tilt,
        (center - eye).dot(forward),
    )
}

pub fn lean(frame: Frame, mut tilt: Vec2, depth: f32) -> Frame {
    if tilt == Vec2::ZERO {
        return frame;
    }
    let [left, bottom, width, height] = frame.rect;
    let (forward, right, up) = axes(frame);
    let mut eye = frame.transform.translation;
    let center = Vec2::new(left + width * 0.5, bottom + height * 0.5);
    let span = width.max(height).max(0.0001);
    let reach = (span / 0.5).min(0.5 / span);
    tilt = Vec2::new(
        (tilt.x.sin() * reach).clamp(-1.0, 1.0).asin(),
        (tilt.y.sin() * reach).clamp(-1.0, 1.0).asin(),
    );
    let (nf, nr, nu) = tilted_axes(forward, right, up, tilt);
    let depth = depth.max(0.0001);
    let source = eye;
    let anchor = eye + (forward + right * left + up * center.y) * depth;
    let tilted = depth * (right.dot(nr) - (left + width) * right.dot(nf));
    eye = anchor - (nf + nr * left + nu * center.y) * tilted;
    let mut low = Vec2::splat(f32::INFINITY);
    let mut high = -low;
    for corner in 0..4 {
        let point = source
            + (forward
                + right * (left + if corner & 1 != 0 { width } else { 0.0 })
                + up * (bottom + if corner & 2 != 0 { height } else { 0.0 }))
                * depth;
        let delta = point - eye;
        let projected = Vec2::new(delta.dot(nr), delta.dot(nu)) / delta.dot(nf).max(0.0001);
        low = low.min(projected);
        high = high.max(projected);
    }
    let scale = 1.0_f32.max(((high.x - low.x) / width).max((high.y - low.y) / height));
    pose(
        eye,
        nf,
        nu,
        [
            low.x,
            (low.y + high.y - height * scale) * 0.5,
            width * scale,
            height * scale,
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn combined_pane_scale_tilt_curvature_and_docks_fit_projected_samples() {
        let visible = [0.2, 0.08, 0.7, 0.82];
        for scale in [1.0, 1.4, 2.0] {
            for tilt in [Vec2::ZERO, Vec2::new(0.3, -0.4), Vec2::new(-0.6, 0.5)] {
                for bend in [0.0, 0.4] {
                    let mut points = Vec::new();
                    for y in 0..=16 {
                        for x in 0..=16 {
                            let u = x as f32 / 8.0 - 1.0;
                            let v = y as f32 / 8.0 - 1.0;
                            points.push(Vec3::new(u * scale, v * scale, bend * (u*u-v*v)));
                        }
                    }
                    let base = pose(Vec3::new(0.0, 0.0, 4.0), -Vec3::Z, Vec3::Y, [-0.5, -0.4, 1.0, 0.8]);
                    let proposed = frame_sheet(base, 2.0, Vec2::new(0.1, -0.2), tilt, Vec3::ZERO, Vec3::X * 2.0, -Vec3::Y * 2.0);
                    let fitted = contain_projected(proposed, &points, visible, 0.01);
                    let (forward, right, up) = axes(fitted);
                    for p in &points {
                        let relative = *p - fitted.transform.translation;
                        let z = relative.dot(forward);
                        assert!(z >= 0.02 - 1e-5);
                        let x = (relative.dot(right) / z - fitted.rect[0]) / fitted.rect[2];
                        let y = 1.0 - (relative.dot(up) / z - fitted.rect[1]) / fitted.rect[3];
                        assert!((0.2-1e-5..=0.9+1e-5).contains(&x), "x={x}");
                        assert!((0.08-1e-5..=0.9+1e-5).contains(&y), "y={y}");
                    }
                    let again = contain_projected(fitted, &points, visible, 0.01);
                    for i in 0..4 { assert!((again.rect[i] - fitted.rect[i]).abs() < 1e-5); }
                }
            }
        }
    }

    #[test]
    fn canvas_safety_only_reduces_zoom_for_actual_overflow() {
        let full = Vec2::new(1200.0, 800.0);
        let (center, zoom) = contain_canvas(full, [0.0, 0.0, 1.0, 1.0], [0.0, 0.0, 1200.0, 800.0], full * 0.5, 1.0);
        assert_eq!(zoom, 1.0);
        assert_eq!(center, full * 0.5);
        let (center, zoom) = contain_canvas(full, [0.2, 0.0, 0.8, 0.9], [0.0, 0.0, 1440.0, 960.0], full * 0.5, 1.2);
        for p in [Vec2::ZERO, Vec2::new(1440.0, 960.0)] {
            let shown = full * 0.5 + (p-center) * zoom;
            assert!(shown.x >= 240.0-0.001 && shown.x <= 1200.001);
            assert!(shown.y >= -0.001 && shown.y <= 720.001);
        }
    }

    #[test]
    fn framing_settle_ignores_transient_alternate_screen_frames() {
        let prompt = [0, 0, 40, 6];
        let mut settle = FramingSettle::default();
        assert_eq!(settle.observe(prompt, 0), prompt);
        // nvim: clear to a lone cursor, partial paint, then the full screen.
        assert_eq!(settle.observe([0, 0, 1, 1], 16), prompt, "a transient clear does not zoom in");
        assert_eq!(settle.observe([0, 0, 80, 3], 32), [0, 0, 80, 6], "partial paint only expands");
        let full = [0, 0, 80, 24];
        assert_eq!(settle.observe(full, 48), full);
        for t in (64..2000).step_by(16) {
            assert_eq!(settle.observe(full, t), full, "stable full screen holds");
        }
        // A real `clear` retargets once it has persisted.
        let cleared = [0, 0, 20, 1];
        assert_eq!(settle.observe(cleared, 2000), full);
        assert_eq!(settle.observe(cleared, 2000 + FRAMING_SHRINK_SETTLE_MS - 1), full);
        assert_eq!(settle.observe(cleared, 2000 + FRAMING_SHRINK_SETTLE_MS), cleared);
        // A flickering shrink never settles.
        let mut flicker = FramingSettle::default();
        flicker.observe(full, 0);
        for i in 0..100u64 {
            let frame = if i % 2 == 0 { [0, 0, 5, 1] } else { [0, 0, 6, 1] };
            assert_eq!(flicker.observe(frame, i * 100), full);
        }
    }

    #[test]
    fn adaptive_content_fit_is_absolute_and_keeps_context() {
        let viewport = Vec2::new(1200.0, 800.0);
        let visible = [240.0, 40.0, 860.0, 700.0];
        let (pan, zoom) = adaptive_fit(viewport, visible, [400.0, 200.0, 160.0, 120.0], Vec2::new(10.0, 20.0), 3.0);
        for point in [Vec2::new(400.0, 200.0), Vec2::new(560.0, 320.0)] {
            let screen = viewport * 0.5 + (point - pan) * zoom;
            assert!(screen.x > 240.0 && screen.x < 1100.0);
            assert!(screen.y > 40.0 && screen.y < 740.0);
        }
        for scale in [0.02, 0.1, 1.0, 2.0] {
            let origin = (Vec2::new(400.0, 200.0) - viewport * 0.5) * scale + viewport * 0.5;
            let (_, scaled) = adaptive_fit(viewport, visible,
                [origin.x, origin.y, 160.0 * scale, 120.0 * scale], Vec2::new(10.0, 20.0) * scale, 3.0 / scale);
            assert!((scaled * scale - zoom).abs() < 0.0001);
        }
        let (_, dense) = adaptive_fit(viewport, visible, [0.0, 0.0, 1200.0, 800.0], Vec2::new(10.0, 20.0), 3.0);
        assert!(dense < zoom);
        assert_eq!(dense, 1.0);
        let (_, magnified) = adaptive_fit(viewport, visible, [0.0, 0.0, 100.0, 80.0], Vec2::new(40.0, 80.0), 0.75);
        assert_eq!(magnified, 1.0);
    }

    #[test]
    fn companions_join_the_frame_only_when_the_gap_is_a_small_share_of_it() {
        let content = [400.0, 200.0, 300.0, 400.0];
        // A filetree one gutter to the left: the gap is 8 of 608 framed pixels.
        let beside = [92.0, 200.0, 300.0, 400.0];
        assert!(gap_fraction(content, beside) < 0.02);
        assert_eq!(group_fit(content, beside, 0.25), Some([92.0, 200.0, 608.0, 400.0]));
        // The same pair at half the font size has the same fraction.
        let half = |r: [f32; 4]| r.map(|v| v * 0.5);
        assert!((gap_fraction(half(content), half(beside)) - gap_fraction(content, beside)).abs() < 1e-6);
        // Far away: 300 of the 900 framed pixels would be empty.
        let far = [1000.0, 200.0, 300.0, 400.0];
        assert!((gap_fraction(content, far) - 300.0 / 900.0).abs() < 1e-6);
        assert_eq!(group_fit(content, far, 0.25), None);
        assert!(group_fit(content, far, 1.0).is_some(), "a limit of one or more accepts any distance");
        // Diagonal separation takes the worse axis; overlap scores zero.
        let diagonal = [800.0, 700.0, 100.0, 100.0];
        assert!((gap_fraction(content, diagonal) - 100.0 / 500.0).abs() < 1e-6);
        assert_eq!(gap_fraction(content, [450.0, 250.0, 50.0, 50.0]), 0.0);
        assert_eq!(group_fit(content, [0.0, 0.0, 0.0, 10.0], 1.0), None, "empty companions never group");
        assert_eq!(group_fit(content, beside, -0.1), None);
    }

    #[test]
    fn matches_actual_godot_controller_and_spatial_framing_samples() {
        // Generated by the unmodified frozen Godot scripts, not by this port.
        // Reproducer: tests/typing-camera-reference.gd in a private project with
        // TerminalCameraController.gd and CameraMotion.gd copied beside it.
        let expected: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/typing-camera-godot.json"))
                .unwrap();
        let compare = |camera: &TypingCamera, name: &str| {
            let sample = &expected[name];
            assert!(
                (camera.zoom as f64 - sample["zoom"].as_f64().unwrap()).abs() < 2e-6,
                "{name} zoom"
            );
            for (field, value) in [
                ("pan", camera.pan),
                ("render_pan", camera.render_pan),
                ("animated_cursor", camera.animated_cursor),
                ("tilt", camera.tilt),
                ("drift", camera.drift),
                ("shake", camera.shake),
            ] {
                for (i, actual) in value.to_array().iter().enumerate() {
                    assert!(
                        (*actual as f64 - sample[field][i].as_f64().unwrap()).abs() < 0.003,
                        "{name} {field}[{i}]: {actual} vs {}",
                        sample[field][i]
                    );
                }
            }
            assert_eq!(
                camera.cursor_anchor_set,
                sample["anchor_set"].as_bool().unwrap()
            );
            assert_eq!(camera.rng as u64, sample["rng"].as_u64().unwrap());
        };
        let mut camera = TypingCamera::default();
        camera.configure(Vec2::splat(0.7), 1.0);
        camera.follow_rect = Some([8.0, 42.0, 1264.0, 750.0]);
        camera.follow_top_inset = 38.0;
        camera.reset(Vec2::new(1280.0, 800.0));
        for i in 0..30 {
            if i == 0 || i == 6 {
                camera.typed(4.0, 0.1);
            }
            camera.advance(
                1.0 / 60.0,
                Vec2::new(800.0, 400.0),
                Vec2::new(1280.0, 800.0),
                Vec2::new(10.0, 20.0),
                2.0,
                18_f32.to_radians(),
                20.0,
                2.0,
                true,
                0.8,
                true,
            );
        }
        compare(&camera, "typing");
        for _ in 0..20 {
            camera.advance(
                1.0 / 60.0,
                Vec2::new(1000.0, 700.0),
                Vec2::new(1280.0, 800.0),
                Vec2::new(10.0, 20.0),
                2.0,
                18_f32.to_radians(),
                20.0,
                2.0,
                true,
                0.8,
                true,
            );
        }
        compare(&camera, "newline");
        camera.follow_rect = Some([16.0, 84.0, 2528.0, 1500.0]);
        camera.follow_top_inset = 76.0;
        camera.advance(
            0.0,
            Vec2::new(2000.0, 1400.0),
            Vec2::new(2560.0, 1600.0),
            Vec2::new(20.0, 40.0),
            2.0,
            18_f32.to_radians(),
            20.0,
            2.0,
            true,
            0.8,
            true,
        );
        compare(&camera, "resize");
        for _ in 0..60 {
            camera.advance(
                1.0 / 60.0,
                Vec2::new(2000.0, 1400.0),
                Vec2::new(2560.0, 1600.0),
                Vec2::new(20.0, 40.0),
                1.0,
                0.0,
                20.0,
                2.0,
                false,
                2.5,
                true,
            );
        }
        compare(&camera, "rest");
        let base = Frame {
            transform: Pose::from_xyz(2.0, 3.0, 10.0),
            rect: [-0.3, -0.18, 0.55, 0.4],
        };
        for (name, frame) in [
            (
                "sheet",
                frame_sheet(
                    base,
                    1.7,
                    Vec2::new(0.2, -0.15),
                    Vec2::new(0.25, -0.18),
                    Vec3::new(1.0, 1.0, 0.0),
                    Vec3::X * 5.0,
                    Vec3::NEG_Y * 4.0,
                ),
            ),
            (
                "compose",
                compose(
                    base,
                    1.7,
                    Vec2::new(0.2, -0.15),
                    Vec2::new(0.25, -0.18),
                    Vec3::new(1.0, 1.0, 0.0),
                    Vec3::X * 5.0,
                    Vec3::NEG_Y * 4.0,
                    Vec3::new(2.0, 1.0, 0.0),
                    0.05,
                    true,
                ),
            ),
        ] {
            for (field, values) in [
                ("position", frame.transform.translation.to_array().to_vec()),
                ("rotation", frame.transform.rotation.to_array().to_vec()),
                ("rect", frame.rect.to_vec()),
            ] {
                for (i, actual) in values.iter().enumerate() {
                    assert!(
                        (*actual as f64 - expected[name][field][i].as_f64().unwrap()).abs() < 1e-5,
                        "{name} {field}[{i}]"
                    );
                }
            }
        }
    }
    #[test]
    fn easing_keeps_zoom_and_screen_translation_on_one_curve() {
        let mut camera = TypingCamera::default();
        camera.reset(Vec2::new(1000.0, 600.0));
        camera.configure(Vec2::splat(0.5), 0.0);
        camera.advance(
            0.05,
            Vec2::new(750.0, 300.0),
            Vec2::new(1000.0, 600.0),
            Vec2::ZERO,
            2.0,
            0.0,
            0.0,
            0.0,
            true,
            0.5,
            true,
        );
        assert!((camera.zoom - 1.5).abs() < 1e-6);
        assert!((camera.pan.x - 666.6667).abs() < 0.001);
        assert_eq!(camera.pan.y, 300.0);
    }
    #[test]
    fn asymmetric_docks_frame_cursor_in_unobstructed_screen() {
        let viewport = Vec2::new(1000.0, 700.0);
        let cell = Vec2::new(10.0, 20.0);
        for visible in [
            [300.0, 40.0, 700.0, 660.0],
            [0.0, 40.0, 650.0, 660.0],
            [220.0, 40.0, 500.0, 400.0],
        ] {
            let [x, y, w, h] = visible;
            for zoom in [1.15, 2.0, 3.5] {
                for cursor in [
                    Vec2::new(x + 10.0, y + 35.0),
                    Vec2::new(x + w - 10.0, y + h - 20.0),
                ] {
                    let mut camera = TypingCamera {
                        visible_rect: Some(visible),
                        follow_rect: Some(visible),
                        follow_top_inset: 4.0,
                        ..Default::default()
                    };
                    for _ in 0..180 {
                        camera.advance(
                            1.0 / 60.0,
                            cursor,
                            viewport,
                            cell,
                            zoom,
                            0.0,
                            0.0,
                            0.0,
                            true,
                            0.2,
                            true,
                        );
                    }
                    let shown = viewport * 0.5 + (cursor - camera.render_pan) * camera.zoom;
                    let half_cell = cell * camera.zoom * 0.5;
                    assert!(
                        shown.x - half_cell.x >= x - 0.1 && shown.x + half_cell.x <= x + w + 0.1,
                        "cursor {shown:?} behind horizontal dock {visible:?} at {zoom}"
                    );
                    assert!(
                        shown.y - half_cell.y >= y - 0.1 && shown.y + half_cell.y <= y + h + 0.1,
                        "cursor {shown:?} behind vertical chrome {visible:?} at {zoom}"
                    );
                }
            }
        }
    }

    #[test]
    fn dock_changes_keep_cursor_visible_during_every_zoom_frame() {
        let viewport = Vec2::new(1000.0, 700.0);
        let cell = Vec2::new(10.0, 20.0);
        let mut camera = TypingCamera::default();
        camera.reset(viewport);
        for visible in [
            [300.0, 40.0, 700.0, 660.0],
            [0.0, 40.0, 650.0, 660.0],
            [220.0, 40.0, 500.0, 400.0],
        ] {
            camera.visible_rect = Some(visible);
            camera.follow_rect = Some(visible);
            for cursor in [Vec2::new(30.0, 100.0), Vec2::new(970.0, 650.0)] {
                for target in [2.0, 1.15, 3.5] {
                    for frame in 0..30 {
                        camera.advance(
                            1.0 / 60.0,
                            cursor,
                            viewport,
                            cell,
                            target,
                            0.0,
                            4.0,
                            1.0,
                            true,
                            0.8,
                            true,
                        );
                        let shown = viewport * 0.5 + (cursor - camera.render_pan) * camera.zoom;
                        let half = cell * camera.zoom * 0.5;
                        let [x, y, w, h] = visible;
                        assert!(
                            shown.x - half.x >= x - 0.01
                                && shown.x + half.x <= x + w + 0.01
                                && shown.y - half.y >= y - 0.01
                                && shown.y + half.y <= y + h + 0.01,
                            "frame {frame}: {shown:?} outside {visible:?}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn resize_preserves_normalized_framing_and_typing_anchor() {
        let mut camera = TypingCamera::default();
        camera.reset(Vec2::new(1000.0, 600.0));
        camera.pan = Vec2::new(650.0, 350.0);
        camera.render_pan = camera.pan;
        camera.animated_cursor = Vec2::new(700.0, 400.0);
        camera.cursor_anchor_set = true;
        camera.cursor_anchor_grid_y = 400.0;
        camera.was_typing = true;
        camera.advance(
            0.0,
            Vec2::new(1400.0, 800.0),
            Vec2::new(2000.0, 1200.0),
            Vec2::splat(20.0),
            1.0,
            0.0,
            0.0,
            0.0,
            true,
            0.5,
            true,
        );
        assert_eq!(camera.pan, Vec2::new(1300.0, 700.0));
        assert_eq!(camera.cursor_anchor_grid_y, 800.0);
        assert!(camera.cursor_anchor_set);
    }
    #[test]
    fn repeating_keys_never_restart_an_existing_jolt() {
        let mut camera = TypingCamera::default();
        camera.reset(Vec2::new(1000.0, 600.0));
        camera.typed(8.0, 0.1);
        camera.typed(80.0, 1.0);
        assert_eq!(camera.shake_left, 0.1);
        assert_eq!(camera.shake_amplitude, 8.0);
        camera.advance(
            0.1,
            Vec2::new(500.0, 300.0),
            Vec2::new(1000.0, 600.0),
            Vec2::ZERO,
            1.0,
            0.0,
            0.0,
            0.0,
            true,
            0.5,
            true,
        );
        assert_eq!(camera.shake, Vec2::ZERO);
        camera.typed(4.0, 0.2);
        assert_eq!(camera.shake_amplitude, 4.0);
    }
    #[test]
    fn decoration_damps_but_never_reverses_and_small_pane_remains_visible() {
        assert_eq!(decorated_pan(80.0, -5.0, 100.0, 200.0), 80.0);
        assert_eq!(decorated_pan(80.0, 30.0, 100.0, 200.0), 110.0);
        assert_eq!(
            pane_follow(100.0, 100.0, 200.0, 1000.0, 0.0, 1000.0, 2.0),
            350.0
        );
    }
    #[test]
    fn sheet_dolly_and_lean_preserve_base_corner_visibility() {
        let base = Frame {
            transform: Pose::from_xyz(0.0, 0.0, 10.0),
            rect: [-0.25, -0.2, 0.5, 0.4],
        };
        let frame = frame_sheet(
            base,
            2.0,
            Vec2::new(0.2, -0.1),
            Vec2::ZERO,
            Vec3::ZERO,
            Vec3::X * 5.0,
            Vec3::NEG_Y * 4.0,
        );
        assert!((frame.transform.translation - Vec3::new(0.5, 0.2, 5.0)).length() < 1e-5);
        let tilted = lean(base, Vec2::new(0.25, -0.2), 10.0);
        let (f, r, u) = axes(tilted);
        for x in [-2.5, 2.5] {
            for y in [-2.0, 2.0] {
                let d = Vec3::new(x, y, 0.0) - tilted.transform.translation;
                let p = Vec2::new(d.dot(r), d.dot(u)) / d.dot(f);
                assert!(
                    p.x >= tilted.rect[0] - 1e-5 && p.x <= tilted.rect[0] + tilted.rect[2] + 1e-5
                );
                assert!(
                    p.y >= tilted.rect[1] - 1e-5 && p.y <= tilted.rect[1] + tilted.rect[3] + 1e-5
                );
            }
        }
    }
}
