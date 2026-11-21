//! Keeps the platform listeners that recover touchpad scroll phases running.
use godot::prelude::*;

/// Add one to the scene tree. It does nothing where the platform already
/// reports phases with its gestures.
#[derive(GodotClass)]
#[class(base = Node, init)]
struct TouchpadPhases {
    base: Base<Node>,
}

#[godot_api]
impl INode for TouchpadPhases {
    fn ready(&mut self) {
        self.base_mut().set_process(cfg!(any(windows, target_os = "linux")));
    }

    /// The scene tree leaves before the platform closes its windows.
    fn exit_tree(&mut self) {
        #[cfg(windows)]
        crate::touchpad_windows::shutdown();
    }

    fn process(&mut self, _delta: f64) {
        #[cfg(windows)]
        crate::touchpad_windows::poll();
        // Drain the private queue every frame, scrolling or not.
        #[cfg(target_os = "linux")]
        crate::touchpad_wayland::prepare();
    }
}
