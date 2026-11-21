//! Directional focus and camera reveal, independent of frontend or projection.
//! Callers supply all shown panes in layout coordinates, including offscreen
//! and outside-main-area panes. Hidden panes and other tabs are excluded upstream.
use crate::tiling::Rect;
use std::collections::BTreeMap;

fn valid(r: Rect) -> bool {
    r.iter().all(|n| n.is_finite()) && r[2] > 0. && r[3] > 0.
}
fn center(r: Rect, axis: usize) -> f64 {
    r[axis] as f64 + r[axis + 2] as f64 * 0.5
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Algorithm {
    #[default]
    Weighted,
    Spatial,
    Nearest,
}

impl Algorithm {
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "weighted" => Some(Self::Weighted),
            "spatial" => Some(Self::Spatial),
            "nearest" => Some(Self::Nearest),
            _ => None,
        }
    }
}

fn overlap(a: Rect, b: Rect, axis: usize) -> f64 {
    ((a[axis] as f64 + a[axis + 2] as f64).min(b[axis] as f64 + b[axis + 2] as f64)
        - (a[axis] as f64).max(b[axis] as f64))
    .max(0.)
}

/// Every center in the requested half-plane is eligible.
///
/// Edge distance keeps large panes easy to reach; a 2x cross-axis cost favors
/// directional intent without letting an arbitrarily distant aligned pane
/// beat a nearby diagonal.
///
/// A small center-distance term distinguishes overlapping/touching
/// rectangles. BTreeMap order provides deterministic ID ties. Moves are
/// intentionally local, not reciprocal: reversing direction can choose a
/// different, closer pane.
pub fn neighbor(rects: &BTreeMap<String, Rect>, source: &str, direction: &str) -> Option<String> {
    neighbor_with_algorithm(rects, source, direction, Algorithm::default())
}

/// All algorithms share candidate eligibility and deterministic ID ties.
/// Spatial adapts https://www.w3.org/TR/css-nav-1/#heuristics scoring: equal
/// cross-axis weight (2) in both directions, but retains the draft's
/// alignment weight (5) and overlap reward.
///
/// This is not the full CSS navigation policy: offscreen candidates and
/// overlapping centers remain eligible in Graffitty.
pub fn neighbor_with_algorithm(
    rects: &BTreeMap<String, Rect>,
    source: &str,
    direction: &str,
    algorithm: Algorithm,
) -> Option<String> {
    let (axis, sign) = match direction {
        "left" => (0, -1.),
        "right" => (0, 1.),
        "up" => (1, -1.),
        "down" => (1, 1.),
        _ => return None,
    };
    let origin = *rects.get(source)?;
    if !valid(origin) {
        return None;
    }
    let cross = 1 - axis;
    let mut best = None;
    let mut score = f64::INFINITY;
    for (key, &r) in rects {
        if key == source || !valid(r) {
            continue;
        }
        let along = (center(r, axis) - center(origin, axis)) * sign;
        if along <= 0. {
            continue;
        }
        let across = (center(r, cross) - center(origin, cross)).abs();
        let gap = (along - (r[axis + 2] as f64 + origin[axis + 2] as f64) * 0.5).max(0.);
        let cross_gap = (across - (r[cross + 2] as f64 + origin[cross + 2] as f64) * 0.5).max(0.);
        let rank = match algorithm {
            Algorithm::Weighted => gap.hypot(2. * cross_gap) + 0.1 * along.hypot(2. * across),
            Algorithm::Nearest => along.hypot(across),
            Algorithm::Spatial => {
                let projected_overlap = overlap(origin, r, cross);
                let area = projected_overlap * overlap(origin, r, axis);
                gap.hypot(cross_gap) + (cross_gap + origin[cross + 2] as f64 * 0.5) * 2.
                    - projected_overlap / origin[cross + 2] as f64 * 5.
                    - area.sqrt()
            }
        };
        if rank < score {
            score = rank;
            best = Some(key.clone());
        }
    }
    best
}

fn contains(outer: Rect, inner: Rect) -> bool {
    (0..2).all(|a| inner[a] >= outer[a] && inner[a] + inner[a + 2] <= outer[a] + outer[a + 2])
}

/// Pan to reveal a pane while keeping the current zoom.
///
/// - If the pane fits, keep its position when fully visible. Center it otherwise.
/// - If the pane is oversized, move only when the cursor cell is clipped
///   or more than half the pane is offscreen.
/// - When moving an oversized pane, choose the closest position that maximizes
///   visible pane area and gives the cursor room. Prioritize the cursor if
///   those goals conflict.
pub fn reveal_delta(viewport: Rect, pane: Rect, cursor: Option<Rect>, margin: f32) -> [f32; 2] {
    if !valid(viewport) || !valid(pane) {
        return [0.; 2];
    }
    if pane[2] <= viewport[2] && pane[3] <= viewport[3] {
        if contains(viewport, pane) {
            return [0.; 2];
        }
        return [0, 1].map(|a| (pane[a] + pane[a + 2] * 0.5) - (viewport[a] + viewport[a + 2] * 0.5));
    }
    let cursor = cursor.filter(|r| valid(*r));
    let visible: f64 = (0..2)
        .map(|a| {
            ((viewport[a] as f64 + viewport[a + 2] as f64).min(pane[a] as f64 + pane[a + 2] as f64)
                - (viewport[a] as f64).max(pane[a] as f64))
            .max(0.)
        })
        .product();
    if visible >= pane[2] as f64 * pane[3] as f64 * 0.5
        && cursor.is_none_or(|r| contains(viewport, r))
    {
        return [0.; 2];
    }
    let mut delta = [0.; 2];
    for a in 0..2 {
        let start = pane[a];
        let end = pane[a] + pane[a + 2] - viewport[a + 2];
        let (mut low, mut high) = (start.min(end), start.max(end));
        if let Some(c) = cursor {
            let pad = if margin.is_finite() {
                margin
                    .max(0.)
                    .min((viewport[a + 2] - c[a + 2]).max(0.) * 0.25)
            } else {
                0.
            };
            let c_low = c[a] + c[a + 2] + pad - viewport[a + 2];
            let c_high = c[a] - pad;
            if c_low <= c_high {
                if low.max(c_low) <= high.min(c_high) {
                    low = low.max(c_low);
                    high = high.min(c_high);
                } else {
                    low = c_low;
                    high = c_high;
                }
            }
        }
        delta[a] = viewport[a].clamp(low, high) - viewport[a];
    }
    delta
}

#[cfg(test)]
mod tests {
    use super::*;
    fn panes(items: &[(&str, Rect)]) -> BTreeMap<String, Rect> {
        items.iter().map(|(k, r)| (k.to_string(), *r)).collect()
    }
    #[test]
    fn nearby_diagonal_beats_far_aligned_and_outside_panes_are_reachable() {
        let mut r = panes(&[
            ("a", [0., 0., 100., 100.]),
            ("diagonal", [120., 140., 100., 100.]),
            ("far", [1200., 0., 100., 100.]),
        ]);
        assert_eq!(neighbor(&r, "a", "right").as_deref(), Some("diagonal"));
        r.remove("diagonal");
        assert_eq!(neighbor(&r, "a", "right").as_deref(), Some("far"));
        assert_eq!(neighbor(&r, "a", "left"), None);
    }
    #[test]
    fn direction_is_local_and_need_not_reverse() {
        let r = panes(&[
            ("a", [0., 0., 100., 100.]),
            ("b", [130., 110., 100., 100.]),
            ("c", [0., 110., 100., 100.]),
        ]);
        assert_eq!(neighbor(&r, "a", "right").as_deref(), Some("b"));
        assert_eq!(neighbor(&r, "b", "left").as_deref(), Some("c"));
        assert_eq!(neighbor(&r, "a", "down").as_deref(), Some("c"));
        assert_eq!(neighbor(&r, "c", "up").as_deref(), Some("a"));
    }
    #[test]
    fn ties_are_stable_and_bad_geometry_is_ignored() {
        let r = panes(&[
            ("source", [0., 0., 100., 100.]),
            ("b", [120., 0., 100., 100.]),
            ("a", [120., 0., 100., 100.]),
            ("bad", [f32::NAN, 0., 100., 100.]),
        ]);
        for algorithm in [Algorithm::Weighted, Algorithm::Spatial, Algorithm::Nearest] {
            assert_eq!(
                neighbor_with_algorithm(&r, "source", "right", algorithm).as_deref(),
                Some("a")
            );
            assert_eq!(
                neighbor_with_algorithm(&r, "source", "invalid", algorithm),
                None
            );
            assert_eq!(neighbor_with_algorithm(&r, "bad", "right", algorithm), None);
        }
        assert_eq!(Algorithm::parse("unknown"), None);
    }
    #[test]
    fn algorithms_offer_distinct_choices_and_are_directionally_symmetric() {
        // Large nearby edge vs aligned pane vs closest center. These are
        // intentionally competing preferences, not one universal UX answer.
        let r = panes(&[
            ("source", [0., 0., 100., 100.]),
            ("large", [410., 140., 400., 200.]),
            ("aligned", [470., -100., 200., 100.]),
            ("close", [250., 320., 100., 100.]),
        ]);
        for (name, expected) in [
            ("weighted", "large"),
            ("spatial", "aligned"),
            ("nearest", "close"),
        ] {
            let algorithm = Algorithm::parse(name).unwrap();
            for (dir, swap, reflect) in [
                ("right", false, false),
                ("left", false, true),
                ("down", true, false),
                ("up", true, true),
            ] {
                let transformed = r
                    .iter()
                    .map(|(key, &v)| {
                        let [mut x, y, w, h] = v;
                        if reflect {
                            x = -x - w;
                        }
                        let v = if swap { [y, x, h, w] } else { [x, y, w, h] };
                        (key.clone(), [v[0] - 700., v[1] + 350., v[2], v[3]])
                    })
                    .collect();
                assert_eq!(
                    neighbor_with_algorithm(&transformed, "source", dir, algorithm).as_deref(),
                    Some(expected),
                    "{name} {dir}"
                );
            }
        }
    }
    #[test]
    fn every_algorithm_reaches_off_axis_panes_and_handles_containment() {
        for algorithm in [Algorithm::Weighted, Algorithm::Spatial, Algorithm::Nearest] {
            for target in [
                [1200., 900., 100., 100.],
                [75., 20., 10., 10.],
                [-10., -10., 200., 200.],
            ] {
                let r = panes(&[("source", [0., 0., 100., 100.]), ("target", target)]);
                assert_eq!(
                    neighbor_with_algorithm(&r, "source", "right", algorithm).as_deref(),
                    Some("target")
                );
                assert_eq!(
                    neighbor_with_algorithm(&r, "source", "left", algorithm),
                    None
                );
            }
        }
    }
    #[test]
    fn fitting_pane_is_centered_only_when_not_fully_visible() {
        let v = [0., 0., 200., 100.];
        assert_eq!(reveal_delta(v, [20., 10., 100., 80.], None, 10.), [0., 0.], "fully visible stays still");
        assert_eq!(reveal_delta(v, [0., 0., 200., 100.], None, 10.), [0., 0.], "exact fit stays still");
        // Partly or entirely offscreen: center it rather than stopping at an edge.
        assert_eq!(reveal_delta(v, [150., 0., 100., 100.], None, 10.), [100., 0.]);
        assert_eq!(reveal_delta(v, [-400., 300., 100., 50.], Some([-390., 310., 5., 10.]), 10.), [-450., 275.]);
        let d = reveal_delta(v, [150., 0., 100., 100.], None, 10.);
        assert_eq!(reveal_delta([d[0], d[1], 200., 100.], [150., 0., 100., 100.], None, 10.), [0., 0.], "no repeated motion");
    }
    #[test]
    fn oversized_threshold_is_strict_and_cursor_can_independently_trigger_reveal() {
        let v = [0., 0., 100., 100.];
        assert_eq!(reveal_delta(v, [25., 0., 150., 100.], None, 10.), [0., 0.]);
        assert_eq!(reveal_delta(v, [26., 0., 150., 100.], None, 10.), [26., 0.]);
        assert_eq!(
            reveal_delta(v, [20., 0., 150., 100.], Some([105., 40., 5., 10.]), 10.),
            [20., 0.]
        );
        assert_eq!(
            reveal_delta(v, [20., 0., 150., 100.], Some([90., 40., 5., 10.]), 10.),
            [0., 0.]
        );
    }
    #[test]
    fn oversized_pane_reveals_cursor_without_zoom_or_repeated_motion() {
        let v = [0., 0., 100., 100.];
        let p = [-100., -100., 500., 500.];
        let c = Some([300., 300., 10., 10.]);
        let d = reveal_delta(v, p, c, 10.);
        assert_eq!(d, [220., 220.]);
        assert_eq!(reveal_delta([d[0], d[1], 100., 100.], p, c, 10.), [0., 0.]);
    }
    #[test]
    fn reveal_is_translation_and_scale_invariant() {
        let v = [10., 20., 200., 120.];
        let p = [250., 180., 100., 80.];
        let d = reveal_delta(v, p, None, 12.);
        let transform = |r: Rect| [r[0] * 2. - 300., r[1] * 2. + 50., r[2] * 2., r[3] * 2.];
        let scaled = reveal_delta(transform(v), transform(p), None, 24.);
        assert_eq!(scaled, [d[0] * 2., d[1] * 2.]);
    }
}
