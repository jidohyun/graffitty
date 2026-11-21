//! Frontend-independent status placement and navigation animation geometry.
//! Solve only settled endpoints. A Motion follows its owner's outside edges;
//! neighboring panes may be crossed in transit, but never at final placement.
use crate::tiling::Rect;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Edge {
    Top,
    Right,
    Bottom,
    Left,
}

fn valid(r: Rect) -> bool {
    r.iter().all(|n| n.is_finite() && n.abs() <= 100_000_000.) && r[2] > 0. && r[3] > 0.
}
fn end(r: Rect, axis: usize) -> f32 {
    r[axis] + r[axis + 2]
}
fn intersects(a: Rect, b: Rect) -> bool {
    (0..2).all(|axis| a[axis] < end(b, axis) && end(a, axis) > b[axis])
}
fn encloses(a: Rect, b: Rect) -> bool {
    (0..2).all(|axis| a[axis] <= b[axis] && end(a, axis) >= end(b, axis))
}
fn grow(r: Rect, by: f32) -> Rect {
    [r[0] - by, r[1] - by, r[2] + by * 2., r[3] + by * 2.]
}
fn area(r: Rect) -> f64 {
    r[2] as f64 * r[3] as f64
}
fn overlap(a: Rect, b: Rect, axis: usize) -> f32 {
    (end(a, axis).min(end(b, axis)) - a[axis].max(b[axis])).max(0.)
}
fn side(r: Rect, owner: Rect) -> Edge {
    if end(r, 1) <= owner[1] {
        Edge::Top
    } else if r[1] >= end(owner, 1) {
        Edge::Bottom
    } else if end(r, 0) <= owner[0] {
        Edge::Left
    } else {
        Edge::Right
    }
}
fn axis(edge: Edge) -> usize {
    if matches!(edge, Edge::Top | Edge::Bottom) {
        0
    } else {
        1
    }
}
fn approx(a: f64, b: f64) -> bool {
    a == b || (a - b).abs() < (a.abs() * 0.00001).max(0.00001)
}

#[derive(Clone, Copy, Debug)]
pub struct Strip {
    pub owner: Rect,
    pub desired: Rect,
    pub previous: Option<Rect>,
}

fn usable(rect: Rect, owner: Rect, bounds: Rect, occupied: &[Rect], ports: &[Rect]) -> bool {
    if !valid(rect)
        || !encloses(bounds, rect)
        || occupied.iter().any(|&r| intersects(grow(rect, 1.), r))
        || ports.iter().any(|&r| intersects(rect, r))
    {
        return false;
    }
    let a = axis(side(rect, owner));
    overlap(rect, owner, a) >= 24f32.min(rect[a + 2].min(owner[a + 2]))
}

/// Reserve usable previous positions first. If a strip is blocked, look
/// along the same edge before trying other edges.
///
/// Return `None` when there is no onscreen space clear of panes.
pub fn place(
    strips: &[Strip],
    bounds: Rect,
    obstacles: &[Rect],
    ports: &[Rect],
) -> Vec<Option<Rect>> {
    let mut placed = vec![None; strips.len()];
    if !valid(bounds) {
        return placed;
    }
    let mut occupied: Vec<Rect> = strips
        .iter()
        .map(|s| s.owner)
        .chain(obstacles.iter().copied())
        .filter(|r| valid(*r))
        .collect();
    let ports: Vec<Rect> = ports.iter().copied().filter(|r| valid(*r)).collect();
    for (i, strip) in strips.iter().enumerate() {
        if !valid(strip.owner) || !valid(strip.desired) {
            continue;
        }
        if let Some(prior) = strip
            .previous
            .filter(|&r| usable(r, strip.owner, bounds, &occupied, &ports))
        {
            placed[i] = Some(prior);
            occupied.push(prior);
        }
    }
    for (i, strip) in strips.iter().enumerate() {
        if placed[i].is_some() || !valid(strip.owner) || !valid(strip.desired) {
            continue;
        }
        let owner = strip.owner;
        let extent = [strip.desired[2], strip.desired[3]];
        if extent[0] > bounds[2] || extent[1] > bounds[3] {
            continue;
        }
        let prior = strip.previous.filter(|r| valid(*r));
        let anchor = prior.unwrap_or(strip.desired);
        let mut xs = vec![
            owner[0],
            end(owner, 0) - extent[0],
            bounds[0],
            end(bounds, 0) - extent[0],
        ];
        let mut ys = vec![
            owner[1],
            end(owner, 1) - extent[1],
            bounds[1],
            end(bounds, 1) - extent[1],
        ];
        for &r in occupied.iter().chain(&ports) {
            xs.extend([end(r, 0) + 3., r[0] - extent[0] - 3.]);
            ys.extend([end(r, 1) + 3., r[1] - extent[1] - 3.]);
        }
        if let Some(p) = prior {
            xs.push(p[0].clamp(bounds[0], end(bounds, 0) - extent[0]));
            ys.push(p[1].clamp(bounds[1], end(bounds, 1) - extent[1]));
        }
        let mut candidates = Vec::new();
        for x in xs {
            if x + extent[0] <= owner[0] || x >= end(owner, 0) {
                continue;
            }
            candidates.extend([
                [x, owner[1] - extent[1] - 3., extent[0], extent[1]],
                [x, end(owner, 1) + 3., extent[0], extent[1]],
            ]);
        }
        for y in ys {
            if y + extent[1] <= owner[1] || y >= end(owner, 1) {
                continue;
            }
            candidates.extend([
                [owner[0] - extent[0] - 3., y, extent[0], extent[1]],
                [end(owner, 0) + 3., y, extent[0], extent[1]],
            ]);
        }
        let (mut least_penalty, mut nearest) = (f64::INFINITY, f64::INFINITY);
        for candidate in candidates {
            if !encloses(bounds, candidate)
                || occupied.iter().any(|&r| intersects(grow(candidate, 1.), r))
            {
                continue;
            }
            let a = axis(side(candidate, owner));
            let mut penalty =
                1. - (overlap(candidate, owner, a) / extent[a].min(owner[a + 2]).max(1.)) as f64;
            for &port in &ports {
                penalty += overlap(candidate, port, 0) as f64 * overlap(candidate, port, 1) as f64
                    / area(candidate).min(area(port)).max(1.);
            }
            let mut distance = (candidate[0] as f64 - anchor[0] as f64).powi(2)
                + (candidate[1] as f64 - anchor[1] as f64).powi(2);
            if prior.is_some_and(|p| side(candidate, owner) != side(p, owner)) {
                distance += (bounds[2] as f64).powi(2) + (bounds[3] as f64).powi(2) + 1.;
            }
            if (penalty < least_penalty && !approx(penalty, least_penalty))
                || (approx(penalty, least_penalty) && distance < nearest)
            {
                placed[i] = Some(candidate);
                least_penalty = penalty;
                nearest = distance;
            }
        }
        if let Some(r) = placed[i] {
            occupied.push(r);
        }
    }
    placed
}

/// Carry a settled placement with its owner, retaining its edge and relative
/// along-edge position. Sizes and the three-pixel gap are in destination units.
pub fn carry(rect: Rect, old_owner: Rect, owner: Rect, extent: [f32; 2]) -> Option<Rect> {
    if !valid(rect) || !valid(old_owner) || !valid(owner) || !valid([0., 0., extent[0], extent[1]])
    {
        return None;
    }
    let mut result = [
        owner[0] + (rect[0] - old_owner[0]) / old_owner[2] * owner[2],
        owner[1] + (rect[1] - old_owner[1]) / old_owner[3] * owner[3],
        extent[0],
        extent[1],
    ];
    match side(rect, old_owner) {
        Edge::Top => result[1] = owner[1] - extent[1] - 3.,
        Edge::Bottom => result[1] = end(owner, 1) + 3.,
        Edge::Left => result[0] = owner[0] - extent[0] - 3.,
        Edge::Right => result[0] = end(owner, 0) + 3.,
    }
    valid(result).then_some(result)
}

fn gap(r: Rect, owner: Rect) -> f32 {
    match side(r, owner) {
        Edge::Top => owner[1] - end(r, 1),
        Edge::Right => r[0] - end(owner, 0),
        Edge::Bottom => r[1] - end(owner, 1),
        Edge::Left => owner[0] - end(r, 0),
    }
}
fn track(owner: Rect, extent: [f32; 2], margin: f32) -> Rect {
    [
        owner[0] - extent[0] - margin,
        owner[1] - extent[1] - margin,
        owner[2] + extent[0] + margin * 2.,
        owner[3] + extent[1] + margin * 2.,
    ]
}
fn anchor(r: Rect, owner: Rect) -> f32 {
    let t = track(owner, [r[2], r[3]], gap(r, owner));
    match side(r, owner) {
        Edge::Top => (r[0] - t[0]) / t[2],
        Edge::Right => 1. + (r[1] - t[1]) / t[3],
        Edge::Bottom => 2. + (end(t, 0) - r[0]) / t[2],
        Edge::Left => 3. + (end(t, 1) - r[1]) / t[3],
    }
}
fn point(owner: Rect, extent: [f32; 2], margin: f32, at: f32) -> Rect {
    let t = track(owner, extent, margin);
    let at = at.rem_euclid(4.);
    let f = at.fract();
    let p = match at as u8 {
        0 => [t[0] + t[2] * f, t[1]],
        1 => [end(t, 0), t[1] + t[3] * f],
        2 => [end(t, 0) - t[2] * f, end(t, 1)],
        _ => [t[0], end(t, 1) - t[3] * f],
    };
    [p[0], p[1], extent[0], extent[1]]
}

/// Same outside anchor at a new size/margin, useful when fading into/out of a
/// view with no visible status. Margins are supplied per axis by the frontend.
pub fn reanchor(rect: Rect, owner: Rect, extent: [f32; 2], margin: [f32; 2]) -> Option<Rect> {
    if !valid(rect)
        || !valid(owner)
        || intersects(rect, owner)
        || !valid([0., 0., extent[0], extent[1]])
        || !margin
            .iter()
            .all(|v| v.is_finite() && *v >= 0. && *v <= 100_000_000.)
    {
        return None;
    }
    let result = point(
        owner,
        extent,
        margin[1 - axis(side(rect, owner))],
        anchor(rect, owner),
    );
    valid(result).then_some(result)
}

/// A checked immutable route. Sampling does not rerun placement or learn from
/// transient positions. Restart from the displayed rectangle when interrupted.
#[derive(Clone, Debug)]
pub struct Motion {
    owner: Rect,
    start: Rect,
    end: Rect,
    from: f32,
    distance: f32,
    start_gap: f32,
    end_gap: f32,
}
impl Motion {
    pub fn new(owner: Rect, start: Rect, end: Rect) -> Option<Self> {
        if !valid(owner)
            || !valid(start)
            || !valid(end)
            || intersects(start, owner)
            || intersects(end, owner)
        {
            return None;
        }
        let from = anchor(start, owner);
        let to = anchor(end, owner);
        if !(0. ..=4.).contains(&from) || !(0. ..=4.).contains(&to) {
            return None;
        }
        Some(Self {
            owner,
            start,
            end,
            from,
            distance: (to - from + 2.).rem_euclid(4.) - 2.,
            start_gap: gap(start, owner),
            end_gap: gap(end, owner),
        })
    }
    pub fn sample(&self, weight: f32) -> Option<Rect> {
        if !weight.is_finite() {
            return None;
        }
        if weight <= 0. {
            return Some(self.start);
        }
        if weight >= 1. {
            return Some(self.end);
        }
        let extent = [
            self.start[2] + (self.end[2] - self.start[2]) * weight,
            self.start[3] + (self.end[3] - self.start[3]) * weight,
        ];
        Some(point(
            self.owner,
            extent,
            self.start_gap + (self.end_gap - self.start_gap) * weight,
            self.from + self.distance * weight,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const OWNER: Rect = [200., 200., 300., 200.];
    #[test]
    fn routes_stay_outside_owner_with_changing_sizes_and_allow_reversal() {
        let starts = [
            [230., 133., 108., 64.],
            [503., 230., 108., 64.],
            [230., 403., 108., 64.],
            [89., 230., 108., 64.],
        ];
        for start in starts {
            for original_end in starts {
                let end = reanchor(original_end, OWNER, [216., 128.], [6., 6.]).unwrap();
                let motion = Motion::new(OWNER, start, end).unwrap();
                assert_eq!(motion.sample(0.), Some(start));
                assert_eq!(motion.sample(1.), Some(end));
                let mut previous = start;
                for frame in 1..=1000 {
                    let next = motion.sample(frame as f32 / 1000.).unwrap();
                    assert!(!intersects(next, OWNER));
                    assert!((next[0] - previous[0]).hypot(next[1] - previous[1]) < 3.);
                    previous = next;
                }
                let shown = motion.sample(0.37).unwrap();
                let reverse = Motion::new(OWNER, shown, start).unwrap();
                assert_eq!(reverse.sample(0.), Some(shown));
                assert_eq!(reverse.sample(1.), Some(start));
            }
        }
    }
    #[test]
    fn placement_retains_good_locations_and_rejects_overlapping_endpoints() {
        let prior = [230., 403., 108., 64.];
        let strip = Strip {
            owner: OWNER,
            desired: [200., 133., 108., 64.],
            previous: Some(prior),
        };
        let bounds = [0., 0., 900., 700.];
        assert_eq!(place(&[strip], bounds, &[], &[]), [Some(prior)]);
        let result = place(&[strip], bounds, &[prior], &[])[0].unwrap();
        assert!(!intersects(result, OWNER) && !intersects(result, prior));
        assert_eq!(place(&[strip], OWNER, &[], &[]), [None]);
    }
    #[test]
    fn invalid_geometry_is_rejected_without_panics_or_nan_output() {
        for bad in [
            [f32::NAN, 0., 10., 10.],
            [0., 0., -1., 10.],
            [0., 0., f32::INFINITY, 10.],
        ] {
            assert!(Motion::new(OWNER, bad, [230., 133., 108., 64.]).is_none());
            assert!(carry(bad, OWNER, OWNER, [108., 64.]).is_none());
            assert_eq!(
                place(
                    &[Strip {
                        owner: OWNER,
                        desired: bad,
                        previous: None
                    }],
                    [0., 0., 900., 700.],
                    &[],
                    &[]
                ),
                [None]
            );
        }
        assert!(Motion::new(OWNER, OWNER, OWNER).is_none());
        let motion = Motion::new(OWNER, [200., 133., 108., 64.], [200., 403., 108., 64.]).unwrap();
        assert!(motion.sample(f32::NAN).is_none());
    }
}
