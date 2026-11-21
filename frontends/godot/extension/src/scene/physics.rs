use super::*;
use godot::classes::{IRefCounted, RefCounted};
use graffitty_scene_core::pane_physics::{
    self as physics, Movable, PanePhysics, Placement, Rect, Rectangles,
};
fn rect(r: Rect2) -> Rect {
    Rect {
        position: v2(r.position),
        size: v2(r.size),
    }
}
fn gdrect(r: Rect) -> Rect2 {
    Rect2::new(g2(r.position), g2(r.size))
}
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct ScenePanePhysics {
    base: Base<RefCounted>,
    simulation: PanePhysics,
}
#[godot_api]
impl IRefCounted for ScenePanePhysics {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            simulation: PanePhysics::default(),
        }
    }
}
#[godot_api]
impl ScenePanePhysics {
    #[func]
    fn reset(&mut self) {
        self.simulation.reset();
    }
    #[func]
    fn sleeping(&self) -> bool {
        self.simulation.sleeping()
    }
    #[func]
    fn pair_checks(&self) -> i64 {
        self.simulation.pair_checks() as i64
    }
    #[func]
    fn velocities(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        for (k, &v) in self.simulation.velocities() {
            d.set(k.as_str(), g2(v));
        }
        d
    }
    #[func]
    fn indexed(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        for (k, &v) in self.simulation.indexed() {
            d.set(k.as_str(), gdrect(v));
        }
        d
    }
    #[func]
    fn sleep(&mut self) {
        self.simulation.sleep();
    }
    #[func]
    fn step(
        &mut self,
        rectangles: godot::builtin::AnyDictionary,
        movable: godot::builtin::AnyDictionary,
        area: Rect2,
        dt: f32,
        constrain: Callable,
    ) -> VarDictionary {
        let rectangles: Rectangles = rectangles
            .iter_shared()
            .map(|(k, v)| {
                (
                    if k.get_type() == VariantType::STRING_NAME {
                        k.to::<StringName>().to_string()
                    } else {
                        k.to::<GString>().to_string()
                    },
                    rect(v.to()),
                )
            })
            .collect();
        let movable: Movable = movable
            .iter_shared()
            .map(|(k, v)| {
                (
                    if k.get_type() == VariantType::STRING_NAME {
                        k.to::<StringName>().to_string()
                    } else {
                        k.to::<GString>().to_string()
                    },
                    if v.to::<bool>() {
                        Placement::Stashed
                    } else {
                        Placement::Free
                    },
                )
            })
            .collect();
        let area = rect(area);
        let result = self
            .simulation
            .step(&rectangles, &movable, area, dt, |key, r| {
                if constrain.is_valid() {
                    rect(
                        constrain
                            .call(&[key.to_variant(), gdrect(r).to_variant()])
                            .to(),
                    )
                } else {
                    physics::reachable(r, area)
                }
            });
        let mut d = VarDictionary::new();
        for (k, v) in result {
            d.set(k.as_str(), gdrect(v));
        }
        d
    }
}
