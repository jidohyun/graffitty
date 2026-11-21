use super::*;
use godot::classes::{IRefCounted, RefCounted};
use graffitty_scene_core::fling::ScrollMotion;
use graffitty_scene_core::touch::{Action, Button, Contact, ScrollStage, TouchArena, Zone};
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SceneScrollMotion {
    base: Base<RefCounted>,
    motion: ScrollMotion,
}
#[godot_api]
impl IRefCounted for SceneScrollMotion {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            motion: ScrollMotion::default(),
        }
    }
}
#[godot_api]
impl SceneScrollMotion {
    #[func]
    fn begin(&mut self, now: i64) {
        self.motion.begin(now);
    }
    #[func]
    fn track(&mut self, delta: Vector2, now: i64) {
        self.motion.track(v2(delta), now);
    }
    #[func]
    fn release(&mut self, now: i64) {
        self.motion.release(now);
    }
    #[func]
    fn advance(&mut self, now: i64) -> Vector2 {
        g2(self.motion.advance(now))
    }
    #[func]
    fn stop(&mut self) {
        self.motion.stop();
    }
    #[func]
    fn velocity(&self) -> Vector2 {
        g2(self.motion.velocity())
    }
}
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SceneTouchNavigation {
    base: Base<RefCounted>,
    arena: TouchArena,
}
#[godot_api]
impl IRefCounted for SceneTouchNavigation {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            arena: TouchArena::default(),
        }
    }
}
fn actions(values: Vec<Action>) -> Array<VarDictionary> {
    values
        .into_iter()
        .map(|value| {
            let mut d = VarDictionary::new();
            match value {
                Action::Canceled => {
                    d.set("kind", "canceled");
                }
                Action::Motion { position, relative } => {
                    d.set("kind", "motion");
                    d.set("position", g2(position));
                    d.set("relative", g2(relative));
                }
                Action::Button {
                    button,
                    pressed,
                    position,
                    double,
                    canceled,
                    held,
                } => {
                    d.set("kind", "button");
                    d.set(
                        "button",
                        match button {
                            Button::Left => 1,
                            Button::Right => 2,
                        },
                    );
                    d.set("pressed", pressed);
                    d.set("position", g2(position));
                    d.set("double", double);
                    d.set("canceled", canceled);
                    d.set("held", held);
                }
                Action::Pinch {
                    previous,
                    center,
                    factor,
                } => {
                    d.set("kind", "pinch");
                    d.set("previous", g2(previous));
                    d.set("center", g2(center));
                    d.set("factor", factor);
                }
                Action::RemoteSwipe { progress, finished, commit } => {
                    d.set("kind", "remote_swipe");
                    d.set("progress", progress);
                    d.set("finished", finished);
                    d.set("commit", commit);
                }
                Action::Scroll { anchor, delta, stage } => {
                    d.set("kind", "scroll");
                    d.set("anchor", g2(anchor));
                    d.set("delta", g2(delta));
                    d.set(
                        "stage",
                        match stage {
                            ScrollStage::Began => "began",
                            ScrollStage::Changed => "changed",
                            ScrollStage::Momentum => "momentum",
                            ScrollStage::Ended => "ended",
                        },
                    );
                }
            }
            d
        })
        .collect()
}
#[godot_api]
impl SceneTouchNavigation {
    #[func]
    fn set_drag_scroll(&mut self, enabled: bool) {
        self.arena.gesture.set_drag_scroll(enabled);
    }
    #[func]
    fn set_remote_swipe_width(&mut self, width: f32) {
        self.arena.gesture.set_remote_swipe_width(width);
    }
    #[func]
    fn stop_scroll(&mut self) {
        self.arena.gesture.stop_scroll();
    }
    /// `zone`: 0 workspace, 1 yielding surface, anything else exclusive.
    #[func]
    fn handle(&mut self, kind: i64, id: i32, position: Vector2, zone: i64, now: i64) -> VarDictionary {
        let position = v2(position);
        let event = match kind {
            0 => Contact::Down { id, position },
            1 => Contact::Up { id, position },
            2 => Contact::Move { id, position },
            _ => Contact::Cancel,
        };
        let zone = match zone {
            0 => Zone::Workspace,
            1 => Zone::Yielding,
            _ => Zone::Exclusive,
        };
        let routed = self.arena.handle(event, zone, now);
        let yielded: Array<VarDictionary> = routed
            .yielded
            .into_iter()
            .map(|contact| {
                let mut d = VarDictionary::new();
                d.set("id", contact.id);
                d.set("position", g2(contact.position));
                d.set("mouse", contact.mouse);
                d
            })
            .collect();
        let mut d = VarDictionary::new();
        d.set("handled", routed.workspace);
        d.set("actions", &actions(routed.actions));
        d.set("yielded", &yielded);
        d
    }
    #[func]
    fn forget(&mut self, id: i32) {
        self.arena.forget(id);
    }
    #[func]
    fn advance(&mut self, now: i64) -> Array<VarDictionary> {
        actions(self.arena.gesture.advance(now))
    }
    #[func]
    fn cancel(&mut self) -> Array<VarDictionary> {
        actions(self.arena.cancel())
    }
    #[func]
    fn fingers(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        for (&id, &p) in self.arena.gesture.fingers() {
            d.set(id, g2(p));
        }
        d
    }
    #[func]
    fn held(&self) -> bool {
        self.arena.gesture.held()
    }
    #[func]
    fn scrolling(&self) -> bool {
        self.arena.gesture.scrolling()
    }
    #[func]
    fn navigating(&self) -> bool {
        self.arena.gesture.navigating()
    }
    #[func]
    fn long_pressed(&self) -> bool {
        self.arena.gesture.long_pressed()
    }
    #[func]
    fn center(&self) -> Vector2 {
        g2(self.arena.gesture.center())
    }
}
