//! Compare the portable router with fixtures exported by the actual Godot code.
use glam::Vec2;
use graffitty_scene_core::graph_geometry as geometry;
use serde_json::Value;

#[test]
fn port_rows_use_screen_hit_targets_and_only_collapse_when_they_do_not_fit() {
    // Five touch targets fit in a 200px pane; the old five-row threshold
    // required 220px even though only four gaps separate their centres.
    let pitch = geometry::port_row_pitch(800., 200., 5, 44.).unwrap();
    assert!((pitch * 0.25 - 44.).abs() < 0.001);
    assert!(geometry::port_row_pitch(800., 183., 5, 44.).is_none());
    assert!(geometry::port_row_pitch(800., 184., 5, 44.).is_some());
    assert!(geometry::port_row_pitch(800., 120., 5, 28.).is_some());
    assert!(geometry::port_row_pitch(800., 119., 5, 28.).is_none());
}

#[test]
fn port_rows_respect_zoom_theme_size_and_visible_dot_bounds() {
    for (canvas, screen, count, hit) in [(800., 200., 5, 44.), (60., 240., 5, 44.), (800., 600., 9, 52.)] {
        let pitch = geometry::port_row_pitch(canvas, screen, count, hit).unwrap() * screen / canvas;
        assert!(pitch >= hit - 0.001, "separate hit targets: {pitch} < {hit}");
        assert!((count - 1) as f32 * pitch + 8. <= screen + 0.001, "dots fit the pane");
    }
    assert!(geometry::port_row_pitch(800., 200., 5, 52.).is_none());
    assert_eq!(geometry::port_row_pitch(0., 0., 1, 44.), Some(0.));
    assert_eq!(geometry::port_row_pitch(0., 0., 0, 44.), Some(0.));
    for height in [0., -1., f32::NAN, f32::INFINITY] {
        assert!(geometry::port_row_pitch(800., height, 5, 44.).is_none());
    }
}

fn point(value: &Value) -> Vec2 {
    Vec2::new(
        value[0].as_f64().unwrap() as f32,
        value[1].as_f64().unwrap() as f32,
    )
}

#[test]
fn cuts_require_finite_crossings_and_include_endpoint_contacts() {
    let a = Vec2::new(0., 0.);
    let b = Vec2::new(10., 0.);
    assert_eq!(
        geometry::intersection(a, b, Vec2::new(4., -3.), Vec2::new(4., 3.)),
        Some(Vec2::new(4., 0.))
    );
    assert_eq!(geometry::intersection(a, b, b, Vec2::new(10., 5.)), Some(b));
    for (c, d) in [
        (Vec2::new(11., -3.), Vec2::new(11., 3.)),
        (Vec2::new(1., 1.), Vec2::new(9., 1.)),
        (a, b),
        (a, a),
    ] {
        assert!(geometry::intersection(a, b, c, d).is_none());
    }
}
fn compare(actual: &[Vec2], expected: &Value, label: &str) {
    let expected = expected.as_array().unwrap();
    assert_eq!(actual.len(), expected.len(), "{label}: sample count");
    for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
        let expected = point(expected);
        assert!(
            actual.distance(expected) < 0.003,
            "{label}[{index}]: {actual:?} != {expected:?}"
        );
    }
}

#[test]
fn godot_controls_feedback_sampling_arc_lengths_and_arrows() {
    let reference: Value =
        serde_json::from_str(include_str!("fixtures/graph-geometry-godot.json")).unwrap();
    for (index, fixture) in reference["fixtures"].as_array().unwrap().iter().enumerate() {
        let a = point(&fixture["a"]);
        let b = point(&fixture["b"]);
        let mode = fixture["mode"].as_str().unwrap();
        let label = format!("{index}/{mode}");
        let control = match mode {
            "arrival" => geometry::arrival_controls(a, b),
            "directed" => {
                geometry::directed_controls(a, b, Vec2::new(0.6, 0.8), Vec2::new(-0.8, 0.6))
            }
            _ => geometry::controls(a, b, 4.),
        };
        compare(&control, &fixture["control"], &label);
        let points = if mode == "feedback" {
            geometry::feedback(a, b, fixture["return_y"].as_f64().unwrap() as f32, 58.)
        } else {
            geometry::sample(control)
        };
        compare(&points, &fixture["points"], &label);
        let lengths = geometry::distances(&points);
        for (actual, expected) in lengths.iter().zip(fixture["lengths"].as_array().unwrap()) {
            assert!(
                (actual - expected.as_f64().unwrap() as f32).abs() < 0.003,
                "{label}: arc length"
            );
        }
        compare(
            &geometry::path_arrow(&points, 0.5),
            &fixture["arrow"],
            &format!("{label}/arrow"),
        );
        compare(
            &[geometry::at_distance(
                &points,
                &lengths,
                lengths.last().unwrap() * 0.371,
            )],
            &fixture["sample"],
            &format!("{label}/arc sample"),
        );
    }
}

#[test]
fn collinear_reversals_are_not_flattened_to_the_endpoint_chord() {
    let points = geometry::sample([Vec2::ZERO, Vec2::X * 400., Vec2::X * -400., Vec2::X * 20.]);
    assert!(points.iter().any(|p| p.x > 100.));
    assert!(points.iter().any(|p| p.x < -80.));
    assert!(geometry::distances(&points).last().unwrap() > &400.);
}

#[test]
fn spreading_ports_does_not_stretch_dense_return_corners_into_spikes() {
    let route = geometry::feedback_route(Vec2::new(400., 200.), Vec2::new(0., 200.), 600., 40., true);
    let length = *geometry::distances(&route.points).last().unwrap();
    // Zoom spreads the bottom output down while the receiver stays centered.
    // Smoothstep's maximum slope is 1.5, so local stretch must be bounded by
    // physical distance along the wire, even in densely sampled bends.
    for shift in [-300., 0., 300.] {
        let moved = geometry::deform_endpoints(&route, Vec2::Y * shift, Vec2::ZERO);
        assert_eq!(moved.points[0], route.points[0] + Vec2::Y * shift);
        assert_eq!(moved.points.last(), route.points.last());
        let bound = 1. + 1.5 * shift.abs() / length;
        for (before, after) in route.points.windows(2).zip(moved.points.windows(2)) {
            assert!(after[0].distance(after[1]) <= before[0].distance(before[1]) * bound + 0.001,
                "corner stretched from {before:?} to {after:?}");
        }
    }
}

#[test]
fn endpoint_motion_is_independent_of_straight_segment_subdivision() {
    let route = geometry::feedback_route(Vec2::new(400., 200.), Vec2::new(0., 200.), 600., 40., true);
    let mut denser = route.clone();
    denser.points.insert(1, route.points[0].lerp(route.points[1], 0.5));
    let source = Vec2::new(15., 300.);
    let target = Vec2::new(-20., -40.);
    let moved = geometry::deform_endpoints(&route, source, target);
    let mut dense_moved = geometry::deform_endpoints(&denser, source, target);
    dense_moved.points.remove(1);
    for (a, b) in moved.points.iter().zip(&dense_moved.points) {
        assert!(a.distance(*b) < 0.001, "sample density changed the visible wire: {a:?} vs {b:?}");
    }
    let coincident = geometry::Route { points: vec![Vec2::ZERO; 2], first: [Vec2::ZERO; 4], last: [Vec2::ZERO; 4] };
    assert_eq!(geometry::deform_endpoints(&coincident, source, target).points, vec![source, target]);
}
