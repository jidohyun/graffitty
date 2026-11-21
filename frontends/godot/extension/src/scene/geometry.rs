use super::*;
use godot::classes::{IRefCounted, RefCounted};
use graffitty_scene_core::graph_geometry as geo;
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SceneGeometry {
    base: Base<RefCounted>,
}
#[godot_api]
impl IRefCounted for SceneGeometry {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}
fn control(p: PackedVector2Array) -> geo::Control {
    let p = p.as_slice();
    assert_eq!(p.len(), 4, "a cubic curve requires four control points");
    [v2(p[0]), v2(p[1]), v2(p[2]), v2(p[3])]
}
fn route(d: VarDictionary) -> geo::Route {
    geo::Route {
        points: points(d.get("points").unwrap().to()),
        first: control(d.get("first").unwrap().to()),
        last: control(d.get("last").unwrap().to()),
    }
}
fn gdroute(r: geo::Route) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("points", &gdpoints(r.points));
    d.set("first", &gdpoints(r.first));
    d.set("last", &gdpoints(r.last));
    d
}
#[godot_api]
impl SceneGeometry {
    #[func]
    fn port_row_pitch(&self, canvas_height: f32, screen_height: f32, count: i32, hit_pitch: f32) -> f32 {
        geo::port_row_pitch(canvas_height, screen_height, count.max(0) as usize, hit_pitch).unwrap_or(-1.)
    }
    #[func]
    fn return_lanes(&self, outputs: PackedVector2Array, keys: PackedStringArray, target: Vector2) -> PackedInt32Array {
        let keys: Vec<String> = keys.as_slice().iter().map(|key| key.to_string()).collect();
        geo::return_lanes(&points(outputs), &keys, v2(target)).as_slice().into()
    }
    #[func]
    fn dashed_segments(&self, p: PackedVector2Array, dash: f32, gap: f32) -> PackedVector2Array {
        gdpoints(geo::dashed_segments(&points(p), dash, gap))
    }
    #[func]
    fn controls(&self, a: Vector2, b: Vector2, curving: f32) -> PackedVector2Array {
        gdpoints(geo::controls(v2(a), v2(b), curving))
    }
    #[func]
    fn evaluate(&self, c: PackedVector2Array, t: f32) -> Vector2 {
        g2(geo::evaluate(control(c), t))
    }
    #[func]
    fn tangent(&self, c: PackedVector2Array, t: f32) -> Vector2 {
        g2(geo::tangent(control(c), t))
    }
    #[func]
    fn curve(&self, a: Vector2, b: Vector2, curving: f32) -> PackedVector2Array {
        gdpoints(geo::sample(geo::controls(v2(a), v2(b), curving)))
    }
    #[func]
    fn sample_controls(&self, c: PackedVector2Array) -> PackedVector2Array {
        gdpoints(geo::sample(control(c)))
    }
    #[func]
    fn distances(&self, p: PackedVector2Array) -> PackedFloat32Array {
        geo::distances(&points(p)).as_slice().into()
    }
    #[func]
    fn at_distance(
        &self,
        p: PackedVector2Array,
        lengths: PackedFloat32Array,
        distance: f32,
    ) -> Vector2 {
        g2(geo::at_distance_mapped(p.as_slice(), lengths.as_slice(), distance, |p| v2(*p)))
    }
    #[func]
    fn parameter_at_distance(&self, lengths: PackedFloat32Array, distance: f32) -> f32 {
        geo::parameter_at_distance(lengths.as_slice(), distance)
    }
    #[func]
    fn arrow(&self, c: PackedVector2Array, reverse: bool) -> PackedVector2Array {
        gdpoints(geo::arrow(control(c), reverse))
    }
    #[func]
    fn deform_endpoints(
        &self,
        r: VarDictionary,
        source: Vector2,
        target: Vector2,
    ) -> VarDictionary {
        if source == Vector2::ZERO && target == Vector2::ZERO {
            r
        } else {
            gdroute(geo::deform_endpoints(&route(r), v2(source), v2(target)))
        }
    }
    #[func]
    fn interaction_curve(&self, a: Vector2, b: Vector2) -> PackedVector2Array {
        gdpoints(geo::interaction_curve(v2(a), v2(b)))
    }
    #[func]
    fn feedback_curve(
        &self,
        a: Vector2,
        b: Vector2,
        return_y: f32,
        clearance: f32,
        natural_end: bool,
    ) -> VarDictionary {
        gdroute(geo::feedback_route(
            v2(a),
            v2(b),
            return_y,
            clearance,
            natural_end,
        ))
    }
    #[func]
    fn smooth_step_same_side(
        &self,
        a: Vector2,
        b: Vector2,
        side: f32,
        clearance: f32,
    ) -> PackedVector2Array {
        gdpoints(geo::smooth_step_same_side(v2(a), v2(b), side, clearance))
    }
    #[func]
    fn rounded_steps(&self, p: PackedVector2Array, radius: f32) -> PackedVector2Array {
        gdpoints(geo::rounded_steps(&points(p), radius))
    }
    #[func]
    fn directed_controls(
        &self,
        a: Vector2,
        b: Vector2,
        outgoing: Vector2,
        incoming: Vector2,
    ) -> PackedVector2Array {
        gdpoints(geo::directed_controls(
            v2(a),
            v2(b),
            v2(outgoing),
            v2(incoming),
        ))
    }
    #[func]
    fn path_arrow(&self, p: PackedVector2Array, fraction: f32) -> PackedVector2Array {
        gdpoints(geo::path_arrow(&points(p), fraction))
    }
    #[func]
    fn arrival_direction(&self, a: Vector2, b: Vector2) -> Vector2 {
        g2(geo::arrival_direction(v2(a), v2(b)))
    }
    #[func]
    fn arrival_controls(&self, a: Vector2, b: Vector2) -> PackedVector2Array {
        gdpoints(geo::arrival_controls(v2(a), v2(b)))
    }
}
