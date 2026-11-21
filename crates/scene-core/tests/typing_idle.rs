use glam::Vec2;
use graffitty_scene_core::typing_camera::TypingCamera;

#[test]
fn typing_return_reaches_rest_at_native_viewport_sizes() {
    for viewport in [Vec2::new(1200., 800.), Vec2::new(3840., 2160.)] {
        for fps in [30, 60, 120] {
            let mut camera = TypingCamera::default();
            camera.unbounded_pan = true;
            camera.follow_rect = Some([8., 42., viewport.x - 16., viewport.y - 50.]);
            camera.follow_top_inset = 38.;
            camera.configure(Vec2::splat(0.7), 1.);
            let cursor = Vec2::new(80., 95.);
            for frame in 0..fps * 9 {
                let typing = frame < fps * 3 / 2;
                camera.advance(
                    1. / fps as f32,
                    cursor,
                    viewport,
                    Vec2::new(10., 20.),
                    if typing { 2. } else { 1. },
                    if typing { 18_f32.to_radians() } else { 0. },
                    if typing { 20. } else { 0. },
                    2.,
                    typing,
                    if typing { 0.8 } else { 2.5 },
                    true,
                );
            }
            assert!(
                !camera.framing_returning,
                "Typing leaves a permanent animation deadline at {viewport:?}/{fps} FPS: {camera:?}"
            );
            assert!((camera.zoom - 1.).abs() < 1e-5);
            assert_eq!(
                camera.tilt,
                Vec2::ZERO,
                "Invisible residual tilt keeps invalidating scenery at {viewport:?}/{fps} FPS"
            );
        }
    }
}
