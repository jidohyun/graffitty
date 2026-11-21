use super::*;
use godot::classes::{IRefCounted, RefCounted};
use graffitty_scene_core::{camera_motion::CameraMotion, typing_camera};
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SceneAdaptiveProjection {
    base: Base<RefCounted>,
    filter: graffitty_scene_core::adaptive_projection::AdaptiveProjection,
}
#[godot_api]
impl IRefCounted for SceneAdaptiveProjection {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, filter: Default::default() }
    }
}
#[godot_api]
impl SceneAdaptiveProjection {
    #[func]
    fn reset(&mut self) { self.filter = Default::default(); }
    #[func]
    fn interrupt(&mut self) { self.filter.interrupt(); }
    #[func]
    fn resume(&mut self) { self.filter.resume(); }
    #[func]
    fn project(
        &mut self,
        reference: VarDictionary,
        fitted: VarDictionary,
        focus: Vector3,
        dt: f32,
        zoom_in: f32,
        zoom_out: f32,
    ) -> VarDictionary {
        let base = frame(&reference);
        let focus = v3(focus);
        self.filter.target(base, frame(&fitted), focus);
        // Retarget before advancing; a new destination must not spend its
        // first frame still moving toward the previous destination.
        self.filter.advance(dt, zoom_in, zoom_out);
        gdframe(self.filter.apply(base, focus))
    }
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SceneCameraMotion {
    base: Base<RefCounted>,
    motion: CameraMotion,
    displayed: VarDictionary,
    destination: VarDictionary,
}
#[godot_api]
impl IRefCounted for SceneCameraMotion {
    fn init(base: Base<RefCounted>) -> Self {
        let f = Frame {
            transform: Pose::IDENTITY,
            rect: [-0.5, -0.5, 1., 1.],
        };
        Self {
            base,
            motion: CameraMotion::new(f),
            displayed: gdframe(f),
            destination: gdframe(f),
        }
    }
}
#[godot_api]
impl SceneCameraMotion {
    #[func]
    fn reset(&mut self, value: VarDictionary) {
        self.motion.reset(frame(&value));
        self.displayed = value.duplicate_deep();
        self.destination = value.duplicate_deep();
    }
    #[func]
    fn observe(&mut self, value: VarDictionary, dt: f32) {
        self.motion.observe(frame(&value), dt);
        self.displayed = value.duplicate_deep();
    }
    #[func]
    fn stop(&mut self) {
        self.motion.stop();
    }
    #[func]
    fn retarget(&mut self, value: VarDictionary, seconds: f64, route: PackedVector3Array) {
        self.motion.retarget_seconds(
            frame(&value),
            seconds,
            &route.as_slice().iter().copied().map(v3).collect::<Vec<_>>(),
        );
        self.destination = value.duplicate_deep();
    }
    #[func]
    fn retarget_on_path(&mut self, value: VarDictionary, seconds: f64) -> bool {
        let changed = self.motion.retarget_on_path_seconds(frame(&value), seconds);
        if changed {
            self.destination = value.duplicate_deep();
        }
        changed
    }
    #[func]
    fn retarget_remaining(&mut self, value: VarDictionary) {
        self.motion.retarget_remaining(frame(&value));
        self.destination = value.duplicate_deep();
    }
    #[func]
    fn advance(&mut self, dt: f64) -> VarDictionary {
        if self.motion.moving() && dt > 0. {
            let value = self.motion.advance_seconds(dt);
            self.displayed = if self.motion.moving() {
                gdframe(value)
            } else {
                self.destination.duplicate_shallow()
            };
        }
        self.displayed.duplicate_shallow()
    }
    #[func]
    fn current_frame(&self) -> VarDictionary {
        self.displayed.duplicate_shallow()
    }
    #[func]
    fn target(&self) -> VarDictionary {
        self.destination.duplicate_shallow()
    }
    #[func]
    fn velocity(&self) -> Vector3 {
        g3(self.motion.velocity())
    }
    #[func]
    fn angular_velocity(&self) -> Vector3 {
        g3(self.motion.angular_velocity())
    }
    #[func]
    fn framing_velocity(&self) -> Vector4 {
        g4(self.motion.framing_velocity())
    }
    #[func]
    fn moving(&self) -> bool {
        self.motion.moving()
    }
    #[func]
    fn elapsed(&self) -> f64 {
        self.motion.elapsed_seconds()
    }
    #[func]
    fn duration(&self) -> f64 {
        self.motion.duration_seconds()
    }
    #[func]
    fn route_points(&self) -> PackedVector3Array {
        self.motion.route_points().iter().copied().map(g3).collect()
    }
    #[func]
    fn path_clock(&self, t: f64) -> Vector2 {
        let (a, b) = self.motion.path_clock(t);
        Vector2::new(a as f32, b as f32)
    }
}
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SceneCameraMath {
    base: Base<RefCounted>,
}
#[godot_api]
impl IRefCounted for SceneCameraMath {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}
#[godot_api]
impl SceneCameraMath {
    #[func]
    fn contain_canvas(&self, full: Vector2, visible: Rect2, content: Rect2, center: Vector2, zoom: f32) -> Vector3 {
        let (pan, zoom) = typing_camera::contain_canvas(v2(full),
            [visible.position.x, visible.position.y, visible.size.x, visible.size.y],
            [content.position.x, content.position.y, content.size.x, content.size.y], v2(center), zoom);
        Vector3::new(pan.x, pan.y, zoom)
    }

    #[func]
    fn contain_projected(&self, value: VarDictionary, points: PackedVector3Array, visible: Rect2, near: f32) -> VarDictionary {
        let points: Vec<_> = points.as_slice().iter().copied().map(v3).collect();
        gdframe(typing_camera::contain_projected(frame(&value), &points,
            [visible.position.x, visible.position.y, visible.size.x, visible.size.y], near))
    }

    #[func]
    fn adaptive_fit(&self, full: Vector2, visible: Rect2, content: Rect2, cell: Vector2, max_zoom: f32) -> Vector3 {
        let (pan, zoom) = typing_camera::adaptive_fit(v2(full),
            [visible.position.x, visible.position.y, visible.size.x, visible.size.y],
            [content.position.x, content.position.y, content.size.x, content.size.y], v2(cell), max_zoom);
        Vector3::new(pan.x, pan.y, zoom)
    }

    /// `typing_camera::group_fit`: the union to frame, or an empty Rect2 when
    /// the companion is too far (its gap would waste more than `max_gap`).
    #[func]
    fn group_fit(&self, content: Rect2, companion: Rect2, max_gap: f32) -> Rect2 {
        let r = |v: Rect2| [v.position.x, v.position.y, v.size.x, v.size.y];
        match typing_camera::group_fit(r(content), r(companion), max_gap) {
            Some(u) => Rect2::new(Vector2::new(u[0], u[1]), Vector2::new(u[2], u[3])),
            None => Rect2::default(),
        }
    }

    #[func]
    fn gap_fraction(&self, a: Rect2, b: Rect2) -> f32 {
        let r = |v: Rect2| [v.position.x, v.position.y, v.size.x, v.size.y];
        typing_camera::gap_fraction(r(a), r(b))
    }

    /// Stateless adapter over `typing_camera::FramingSettle`; GDScript keeps
    /// the returned dictionary per terminal and passes it back next frame.
    #[func]
    fn settle_framing(&self, state: VarDictionary, observed: Rect2i, now_ms: i64) -> VarDictionary {
        let rect = |key: &str| state.get(key).and_then(|v| v.try_to::<Rect2i>().ok())
            .map(|r| [r.position.x, r.position.y, r.size.x, r.size.y]);
        let mut settle = typing_camera::FramingSettle {
            accepted: rect("accepted"),
            pending: rect("pending"),
            pending_since_ms: state.get("since").and_then(|v| v.try_to::<i64>().ok()).unwrap_or(0).max(0) as u64,
        };
        settle.observe([observed.position.x, observed.position.y, observed.size.x, observed.size.y], now_ms.max(0) as u64);
        let mut out = VarDictionary::new();
        let gd = |r: [i32; 4]| Rect2i::new(Vector2i::new(r[0], r[1]), Vector2i::new(r[2], r[3]));
        if let Some(r) = settle.accepted { out.set("accepted", gd(r)); }
        if let Some(r) = settle.pending { out.set("pending", gd(r)); }
        out.set("since", settle.pending_since_ms as i64);
        out
    }

    #[func]
    fn follow_target(
        &self,
        cursor: Vector2,
        viewport: Vector2,
        zoom: f32,
        cell: Vector2,
        pane: Rect2,
        visible: Rect2,
        threshold: Vector2,
        anchor_y: f32,
        anchored: bool,
        top_inset: f32,
        navigation_typing: bool,
    ) -> Vector2 {
        let mut camera = typing_camera::TypingCamera::default();
        camera.follow_rect = Some([pane.position.x, pane.position.y, pane.size.x, pane.size.y]);
        camera.visible_rect = Some([
            visible.position.x,
            visible.position.y,
            visible.size.x,
            visible.size.y,
        ]);
        camera.follow_threshold = v2(threshold);
        camera.cursor_anchor_y = anchor_y;
        camera.follow_top_inset = top_inset;
        camera.unbounded_pan = navigation_typing;
        camera.was_typing = navigation_typing;
        g2(camera.follow_target(v2(cursor), v2(viewport), zoom, anchored, v2(cell)))
    }
    #[func]
    fn cursor_pan_bounds(
        &self,
        cursor: Vector2,
        viewport: Vector2,
        cell: Vector2,
        zoom: f32,
        visible: Rect2,
    ) -> PackedVector2Array {
        typing_camera::cell_bounds(
            v2(cursor),
            v2(viewport),
            v2(cell),
            zoom,
            Some([
                visible.position.x,
                visible.position.y,
                visible.size.x,
                visible.size.y,
            ]),
        )
        .into_iter()
        .map(g2)
        .collect()
    }
    #[func]
    fn compose(
        &self,
        base: VarDictionary,
        zoom: f32,
        pan: Vector2,
        tilt: Vector2,
        center: Vector3,
        axis_u: Vector3,
        axis_v: Vector3,
        cursor: Vector3,
        near: f32,
        constrain: bool,
    ) -> VarDictionary {
        gdframe(typing_camera::compose(
            frame(&base),
            zoom,
            v2(pan),
            v2(tilt),
            v3(center),
            v3(axis_u),
            v3(axis_v),
            v3(cursor),
            near,
            constrain,
        ))
    }
    #[func]
    fn frame_pane(
        &self,
        base: VarDictionary,
        zoom: f32,
        pan: Vector2,
        tilt: Vector2,
        distance: f32,
    ) -> VarDictionary {
        gdframe(typing_camera::frame_pane(
            frame(&base),
            zoom,
            v2(pan),
            v2(tilt),
            distance,
        ))
    }
    #[func]
    fn frame_sheet(
        &self,
        base: VarDictionary,
        zoom: f32,
        pan: Vector2,
        tilt: Vector2,
        center: Vector3,
        axis_u: Vector3,
        axis_v: Vector3,
    ) -> VarDictionary {
        gdframe(typing_camera::frame_sheet(
            frame(&base),
            zoom,
            v2(pan),
            v2(tilt),
            v3(center),
            v3(axis_u),
            v3(axis_v),
        ))
    }
    #[func]
    fn lean(&self, value: VarDictionary, tilt: Vector2, depth: f32) -> VarDictionary {
        if tilt == Vector2::ZERO {
            value
        } else {
            gdframe(typing_camera::lean(frame(&value), v2(tilt), depth))
        }
    }
    #[func]
    fn keep_cursor_in_view(
        &self,
        eye: Vector3,
        forward: Vector3,
        right: Vector3,
        up: Vector3,
        rect: Vector4,
        point: Vector3,
        near: f32,
        margin: f32,
    ) -> Vector3 {
        g3(typing_camera::keep_cursor_in_view(
            v3(eye),
            v3(forward),
            v3(right),
            v3(up),
            [rect.x, rect.y, rect.z, rect.w],
            v3(point),
            near,
            margin,
        ))
    }
}
