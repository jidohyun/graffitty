//! Godot type conversion and scene bindings. Algorithms belong in graffitty-scene-core.
mod camera;
mod geometry;
mod navigation;
mod physics;
mod touch;
use godot::prelude::*;
use graffitty_scene_core::{
    Pose,
    camera_motion::Frame,
    glam::{Mat3, Quat, Vec2, Vec3, Vec4},
};
fn v2(v: Vector2) -> Vec2 {
    Vec2::new(v.x, v.y)
}
fn g2(v: Vec2) -> Vector2 {
    Vector2::new(v.x, v.y)
}
fn v3(v: Vector3) -> Vec3 {
    Vec3::new(v.x, v.y, v.z)
}
fn g3(v: Vec3) -> Vector3 {
    Vector3::new(v.x, v.y, v.z)
}
fn g4(v: Vec4) -> Vector4 {
    Vector4::new(v.x, v.y, v.z, v.w)
}
fn frame(d: &VarDictionary) -> Frame {
    let t = d.get("transform").unwrap().to::<Transform3D>();
    let r = d.get("rect").unwrap().to::<Vector4>();
    let rotation = Quat::from_mat3(&Mat3::from_cols(
        v3(t.basis.col_a()),
        v3(t.basis.col_b()),
        v3(t.basis.col_c()),
    ));
    Frame {
        transform: Pose {
            translation: v3(t.origin),
            rotation,
        },
        rect: [r.x, r.y, r.z, r.w],
    }
}
fn gdframe(f: Frame) -> VarDictionary {
    let m = Mat3::from_quat(f.transform.rotation);
    let mut d = VarDictionary::new();
    d.set(
        "transform",
        Transform3D::new(
            Basis::from_cols(g3(m.x_axis), g3(m.y_axis), g3(m.z_axis)),
            g3(f.transform.translation),
        ),
    );
    d.set(
        "rect",
        Vector4::new(f.rect[0], f.rect[1], f.rect[2], f.rect[3]),
    );
    d
}
fn points(p: PackedVector2Array) -> Vec<Vec2> {
    p.as_slice().iter().copied().map(v2).collect()
}
fn gdpoints(p: impl IntoIterator<Item = Vec2>) -> PackedVector2Array {
    p.into_iter().map(g2).collect()
}
