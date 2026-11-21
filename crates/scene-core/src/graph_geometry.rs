// SPDX-FileCopyrightText: 2005 Blender Authors
// SPDX-FileCopyrightText: 2018-2023 Blender Authors
// SPDX-License-Identifier: GPL-2.0-or-later
//! Portable geometry matching Godot's GraphLinkGeometry and GraphWorkspaceTools.
//! The Blender controls and Vue Flow/n8n routing provenance and notices are in
//! docs/developers/automation-and-extensions/blender-node-links.md, docs/developers/automation-and-extensions/n8n-link-routing.md and licenses/vue-flow-MIT.txt.
use glam::Vec2;

pub type Control = [Vec2; 4];

/// Canvas-space row pitch with non-overlapping screen-space hit targets.
/// Only the visible dots must stay inside the pane; invisible end targets may
/// extend past its top/bottom. `None` means this bank needs a compact connector.
pub fn port_row_pitch(canvas_height: f32, screen_height: f32, count: usize, hit_pitch: f32) -> Option<f32> {
    if count <= 1 { return Some(0.); }
    if !canvas_height.is_finite() || !screen_height.is_finite() || !hit_pitch.is_finite()
        || canvas_height <= 0. || screen_height <= 0. || hit_pitch <= 0. { return None; }
    let available = screen_height - 8.;
    let intervals = (count - 1) as f32;
    if available < intervals * hit_pitch { return None; }
    let scale = screen_height / canvas_height;
    Some((hit_pitch * scale).max(hit_pitch).min(available / intervals) / scale)
}

/// Stable return-wire lane allocation for one destination. Forward wires use -1.
/// Recompute only destinations affected by a changed endpoint/topology.
pub fn return_lanes(outputs: &[Vec2], keys: &[String], target: Vec2) -> Vec<i32> {
    assert_eq!(outputs.len(), keys.len());
    let mut order: Vec<_> = (0..outputs.len()).filter(|&i| outputs[i].x - 20. > target.x).collect();
    order.sort_by(|&a, &b| outputs[b].y.total_cmp(&outputs[a].y)
        .then(outputs[a].x.total_cmp(&outputs[b].x)).then(keys[a].cmp(&keys[b])));
    let mut lanes = vec![-1; outputs.len()];
    for (lane, index) in order.into_iter().enumerate() { lanes[index] = lane as i32; }
    lanes
}

/// Batched dashed line segments, with continuous arc-length phase through bends.
/// Linear in sampled points plus dash count; callers submit one multiline draw.
pub fn dashed_segments(points: &[Vec2], dash: f32, gap: f32) -> Vec<Vec2> {
    if dash <= 0. || gap < 0. || !dash.is_finite() || !gap.is_finite() { return Vec::new(); }
    // Accumulate phase in f64: a tiny remainder near a dash boundary can
    // otherwise round `at + remaining` back to `at`, losing a long segment.
    let period = f64::from(dash) + f64::from(gap);
    let dash = f64::from(dash);
    let mut phase = 0.0_f64;
    let mut result = Vec::new();
    for pair in points.windows(2) {
        let delta = pair[1] - pair[0];
        let length = f64::from(delta.length());
        if !length.is_finite() || length <= f64::EPSILON { continue; }
        let mut at = 0.0;
        while at < length {
            let drawing = phase < dash;
            let remaining = (if drawing { dash } else { period }) - phase;
            let end = (at + remaining).min(length);
            if end <= at { break; }
            if drawing {
                result.extend([pair[0] + delta * (at / length) as f32, pair[0] + delta * (end / length) as f32]);
            }
            phase += end - at;
            if phase >= period - 1e-9 { phase = 0.; }
            else if (phase - dash).abs() < 1e-9 { phase = dash; }
            at = end;
        }
    }
    result
}

#[cfg(test)]
mod dash_tests {
    use super::*;
    #[test]
    fn stable_lanes_exclude_forward_wires() {
        let positions = [Vec2::new(40., 5.), Vec2::new(40., 5.), Vec2::ZERO, Vec2::new(50., 10.)];
        let keys = ["b", "a", "c", "d"].map(String::from);
        assert_eq!(return_lanes(&positions, &keys, Vec2::ZERO), [2, 1, -1, 0]);
    }
    #[test]
    fn phase_survives_bends_and_duplicate_points() {
        let p = [Vec2::ZERO, Vec2::new(6., 0.), Vec2::new(6., 0.), Vec2::new(6., 14.)];
        assert_eq!(dashed_segments(&p, 10., 6.), vec![Vec2::ZERO, p[1], p[1], Vec2::new(6., 4.), Vec2::new(6., 10.), p[3]]);
    }
    #[test]
    fn long_fractional_segments_do_not_drop_dashes() {
        let route = feedback_route(Vec2::new(980., 480.), Vec2::new(80., 350.), 620., 58., true);
        let segments = dashed_segments(&route.points, 10., 6.);
        let painted: f32 = segments.chunks_exact(2).map(|p| p[0].distance(p[1])).sum();
        let total = *distances(&route.points).last().unwrap();
        assert!((painted - total * 10. / 16.).abs() < 10., "painted {painted} / {total}");
    }
    #[test]
    fn empty_and_invalid_patterns_are_safe() {
        assert!(dashed_segments(&[], 10., 6.).is_empty());
        assert!(dashed_segments(&[Vec2::ZERO, Vec2::ONE], 0., 6.).is_empty());
        assert!(dashed_segments(&[Vec2::ZERO, Vec2::ONE], f32::NAN, 6.).is_empty());
    }
}

pub fn controls(a: Vec2, b: Vec2, curving: f32) -> Control {
    if curving == 0. {
        return [a, a.lerp(b, 1. / 3.), a.lerp(b, 2. / 3.), b];
    }
    let delta = (b - a).abs();
    let slope = if delta.x != 0. { delta.y / delta.x } else { 0. };
    let offset = curving * 0.1 * delta.x * (slope * (4.5 - 0.25 * curving)).min(1.);
    [a, a + Vec2::X * offset, b - Vec2::X * offset, b]
}
pub fn evaluate(c: Control, t: f32) -> Vec2 {
    let u = 1. - t;
    c[0] * u.powi(3) + c[1] * (3. * u * u * t) + c[2] * (3. * u * t * t) + c[3] * t.powi(3)
}
pub fn tangent(c: Control, t: f32) -> Vec2 {
    let u = 1. - t;
    let direction =
        (c[1] - c[0]) * (3. * u * u) + (c[2] - c[1]) * (6. * t * u) + (c[3] - c[2]) * (3. * t * t);
    (if direction == Vec2::ZERO {
        c[3] - c[0]
    } else {
        direction
    })
    .normalize_or_zero()
}
pub fn distance_to_segment(point: Vec2, a: Vec2, b: Vec2) -> f32 {
    let delta = b - a;
    let t = if delta.length_squared() > 0. {
        ((point - a).dot(delta) / delta.length_squared()).clamp(0., 1.)
    } else {
        0.
    };
    point.distance(a + delta * t)
}
/// Intersection of two finite segments. Parallel/collinear paths do not cut.
pub fn intersection(a: Vec2, b: Vec2, c: Vec2, d: Vec2) -> Option<Vec2> {
    let r = (b - a).as_dvec2();
    let s = (d - c).as_dvec2();
    let offset = (c - a).as_dvec2();
    let denominator = r.perp_dot(s);
    if denominator == 0. {
        return None;
    }
    let t = offset.perp_dot(s) / denominator;
    let u = offset.perp_dot(r) / denominator;
    ((0. ..=1.).contains(&t) && (0. ..=1.).contains(&u)).then(|| a + (b - a) * t as f32)
}
pub fn sample(c: Control) -> Vec<Vec2> {
    fn subdivide(c: Control, out: &mut Vec<Vec2>, depth: u8) {
        let error =
            distance_to_segment(c[1], c[0], c[3]).max(distance_to_segment(c[2], c[0], c[3]));
        if error <= 0.05 || depth >= 12 {
            out.push(c[3]);
            return;
        }
        let a = c[0].lerp(c[1], 0.5);
        let b = c[1].lerp(c[2], 0.5);
        let d = c[2].lerp(c[3], 0.5);
        let e = a.lerp(b, 0.5);
        let f = b.lerp(d, 0.5);
        let middle = e.lerp(f, 0.5);
        subdivide([c[0], a, e, middle], out, depth + 1);
        subdivide([middle, f, d, c[3]], out, depth + 1);
    }
    let mut out = vec![c[0]];
    subdivide(c, &mut out, 0);
    out
}
pub fn arrival_direction(a: Vec2, b: Vec2) -> Vec2 {
    let delta = b - a;
    let direction = Vec2::new(delta.x.max(0.), delta.y);
    if direction.length_squared() > 0.000001 {
        direction.normalize()
    } else {
        Vec2::X
    }
}
pub fn arrival_controls(a: Vec2, b: Vec2) -> Control {
    let mut c = controls(a, b, 4.);
    c[2] = b - arrival_direction(a, b) * a.distance(b) / 3.;
    c
}
pub fn directed_controls(a: Vec2, b: Vec2, outgoing: Vec2, incoming: Vec2) -> Control {
    let distance = a.distance(b) / 3.;
    [a, a + outgoing * distance, b - incoming * distance, b]
}
pub fn reroute_direction(previous: Vec2, at: Vec2, next: Vec2) -> Vec2 {
    let incoming = (at - previous).normalize_or_zero();
    let outgoing = (next - at).normalize_or_zero();
    let mut direction = incoming + outgoing;
    if direction.length_squared() < 0.000001 {
        direction = if outgoing != Vec2::ZERO {
            outgoing
        } else {
            incoming
        };
    }
    if direction == Vec2::ZERO {
        Vec2::X
    } else {
        direction.normalize()
    }
}

// Vue Flow portions copyright 2019-2025 webkid GmbH, 2021-2025 Burak Cakmakoglu.
// MIT notice: licenses/vue-flow-MIT.txt.
pub fn rounded_steps(vertices: &[Vec2], radius: f32) -> Vec<Vec2> {
    let Some(first) = vertices.first() else {
        return vec![];
    };
    let mut out = vec![*first];
    for triple in vertices.windows(3) {
        let [a, b, c] = [triple[0], triple[1], triple[2]];
        if (a.x == b.x && b.x == c.x) || (a.y == b.y && b.y == c.y) {
            out.push(b);
            continue;
        }
        let bend = radius.min(a.distance(b).min(b.distance(c)) * 0.5);
        let (entry, leave) = if a.y == b.y {
            (
                b + Vec2::X * if a.x < c.x { -bend } else { bend },
                b + Vec2::Y * if a.y < c.y { bend } else { -bend },
            )
        } else {
            (
                b + Vec2::Y * if a.y < c.y { -bend } else { bend },
                b + Vec2::X * if a.x < c.x { bend } else { -bend },
            )
        };
        out.push(entry);
        out.extend(
            sample([entry, entry.lerp(b, 2. / 3.), leave.lerp(b, 2. / 3.), leave])
                .into_iter()
                .skip(1),
        );
    }
    if vertices.len() > 1 {
        out.push(*vertices.last().unwrap());
    }
    out
}
pub fn smooth_step_same_side(a: Vec2, b: Vec2, side: f32, clearance: f32) -> Vec<Vec2> {
    let mut ag = a + Vec2::X * side * clearance;
    let mut bg = b + Vec2::X * side * clearance;
    let direction = if ag.x < bg.x { 1. } else { -1. };
    let corner = if side == direction {
        Vec2::new(bg.x, ag.y)
    } else {
        Vec2::new(ag.x, bg.y)
    };
    let difference = (a.x - b.x).abs();
    if difference <= 40. {
        let adjustment = (40. - difference).min(39.);
        if side == direction {
            ag.x -= side * adjustment;
        } else {
            bg.x -= side * adjustment;
        }
    }
    rounded_steps(&[a, ag, corner, bg, b], 16.)
}
pub fn feedback(a: Vec2, b: Vec2, return_y: f32, clearance: f32) -> Vec<Vec2> {
    feedback_route(a, b, return_y, clearance, true).points
}
#[derive(Clone, Debug, PartialEq)]
pub struct Route {
    pub points: Vec<Vec2>,
    pub first: Control,
    pub last: Control,
}
pub fn feedback_route(a: Vec2, b: Vec2, return_y: f32, clearance: f32, natural_end: bool) -> Route {
    let join = Vec2::new(
        (a.x + b.x) * 0.5,
        if return_y.is_nan() {
            a.y + 130.
        } else {
            return_y
        },
    );
    let mut points = smooth_step_same_side(a, join, 1., clearance);
    let last = if natural_end {
        let left = join.x.min(b.x) - clearance;
        let anchor = Vec2::new(left, join.y.min(b.y + 56_f32.max(clearance)));
        points.extend(
            rounded_steps(&[join, Vec2::new(left, join.y), anchor], 16.)
                .into_iter()
                .skip(1),
        );
        let tail = directed_controls(
            anchor,
            b,
            if anchor.y < join.y {
                -Vec2::Y
            } else {
                -Vec2::X
            },
            arrival_direction(anchor, b),
        );
        points.extend(sample(tail).into_iter().skip(1));
        tail
    } else {
        points.extend(
            smooth_step_same_side(join, b, -1., clearance)
                .into_iter()
                .skip(1),
        );
        controls(join, b, 4.)
    };
    Route {
        points,
        first: controls(a, join, 4.),
        last,
    }
}
/// Preserve resting route topology while presentation effects move socket endpoints.
pub fn deform_endpoints(route: &Route, source: Vec2, target: Vec2) -> Route {
    let mut out = route.clone();
    // Adaptive sampling packs points into bends and leaves straight runs as
    // one segment. Index-based weights therefore pull tight corners much more
    // sharply than straight runs, creating hooks when zoom spreads the ports.
    //
    // Blend by traveled distance so the deformation has a bounded local slope
    // and does not depend on how finely any bend was sampled.
    let length: f32 = if source == target { 0. } else {
        route.points.windows(2).map(|p| p[0].distance(p[1])).sum()
    };
    let mut traveled = 0.;
    for (i, point) in out.points.iter_mut().enumerate() {
        let t = if length > 0. {
            if i > 0 { traveled += route.points[i - 1].distance(route.points[i]); }
            traveled / length
        } else {
            // A coincident pair can still separate into two moved sockets.
            i as f32 / route.points.len().saturating_sub(1).max(1) as f32
        };
        *point += source.lerp(target, t * t * (3. - 2. * t));
    }
    for point in &mut out.first {
        *point += source;
    }
    for point in &mut out.last {
        *point += target;
    }
    if route.first == route.last {
        out.first[2] = out.last[2];
        out.first[3] = out.last[3];
        out.last = out.first;
    }
    out
}
pub fn parameter_at_distance(lengths: &[f32], distance: f32) -> f32 {
    if lengths.len() < 2 || *lengths.last().unwrap() <= 0. {
        return 0.;
    }
    for i in 1..lengths.len() {
        if distance <= lengths[i] {
            let span = lengths[i] - lengths[i - 1];
            let fraction = if span > 0. {
                ((distance - lengths[i - 1]) / span).clamp(0., 1.)
            } else {
                0.
            };
            return (i as f32 - 1. + fraction) / (lengths.len() - 1) as f32;
        }
    }
    1.
}
pub fn interaction_curve(a: Vec2, b: Vec2) -> Vec<Vec2> {
    let c = controls(a, b, 4.);
    (0..=24).map(|i| evaluate(c, i as f32 / 24.)).collect()
}
pub fn arrow(c: Control, reverse: bool) -> Vec<Vec2> {
    let samples: Vec<_> = (0..24).map(|i| evaluate(c, i as f32 / 23.)).collect();
    let lengths = distances(&samples);
    let total = *lengths.last().unwrap();
    if total <= 0.001 {
        return vec![];
    }
    let inset = 10_f32.min(total * 0.2);
    let t = parameter_at_distance(&lengths, if reverse { inset } else { total - inset });
    let tip = evaluate(c, t);
    let direction = tangent(c, t) * if reverse { -1. } else { 1. };
    if direction == Vec2::ZERO {
        return vec![];
    }
    let normal = Vec2::new(-direction.y, direction.x);
    let length = 8_f32.min(total * 0.35);
    vec![
        tip,
        tip - direction * length + normal * length * 0.5,
        tip - direction * length - normal * length * 0.5,
    ]
}
pub fn distances(points: &[Vec2]) -> Vec<f32> {
    let mut lengths = vec![0.; points.len()];
    for index in 1..points.len() {
        lengths[index] = lengths[index - 1] + points[index - 1].distance(points[index]);
    }
    lengths
}
pub fn at_distance(points: &[Vec2], lengths: &[f32], distance: f32) -> Vec2 {
    at_distance_mapped(points, lengths, distance, |p| *p)
}

/// Sample frontend-owned points without copying the whole curve across an adapter.
/// Only the one or two points needed for interpolation are converted.
pub fn at_distance_mapped<T>(
    points: &[T],
    lengths: &[f32],
    distance: f32,
    convert: impl Fn(&T) -> Vec2,
) -> Vec2 {
    let Some(first) = points.first() else {
        return Vec2::ZERO;
    };
    if distance <= 0. || points.len() == 1 || lengths.len() != points.len() {
        return convert(first);
    }
    if distance >= *lengths.last().unwrap() {
        return convert(points.last().unwrap());
    }
    let index = lengths
        .partition_point(|length| *length < distance)
        .max(1)
        .min(points.len() - 1);
    let span = lengths[index] - lengths[index - 1];
    convert(&points[index - 1]).lerp(
        convert(&points[index]),
        if span > 0. {
            (distance - lengths[index - 1]) / span
        } else {
            0.
        },
    )
}

pub fn path_arrow(points: &[Vec2], fraction: f32) -> Vec<Vec2> {
    let lengths = distances(points);
    let total = *lengths.last().unwrap_or(&0.);
    if points.len() < 2 || total < 1. {
        return vec![];
    }
    let distance = total * fraction;
    let tip = at_distance(points, &lengths, distance);
    let direction = (at_distance(points, &lengths, (distance + 2.).min(total))
        - at_distance(points, &lengths, (distance - 2.).max(0.)))
    .normalize_or_zero();
    let normal = Vec2::new(-direction.y, direction.x);
    vec![
        tip + direction * 5.,
        tip - direction * 5. + normal * 4.,
        tip - direction * 5. - normal * 4.,
    ]
}

#[cfg(test)]
mod adapter_tests {
    use super::*;
    #[test]
    fn sampling_converts_only_the_interpolated_endpoints() {
        let points: Vec<_> = (0..1000).map(|i| Vec2::new(i as f32, 0.)).collect();
        let lengths = distances(&points);
        let conversions = std::cell::Cell::new(0);
        let result = at_distance_mapped(&points, &lengths, 456.25, |p| {
            conversions.set(conversions.get() + 1);
            *p
        });
        assert_eq!(result, Vec2::new(456.25, 0.));
        assert_eq!(conversions.get(), 2);
        assert_eq!(at_distance(&points[..1], &[0.], 2.), points[0]);
        assert_eq!(at_distance(&points, &[], 2.), points[0]);
    }
}
