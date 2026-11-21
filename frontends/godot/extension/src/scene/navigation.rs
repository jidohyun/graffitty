use super::*;
use godot::{
    builtin::AnyArray,
    classes::{IRefCounted, RefCounted},
};
use graffitty_scene_core::navigation::NavigationGraph;

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SceneNavigationGraph {
    base: Base<RefCounted>,
    graph: NavigationGraph,
}
#[godot_api]
impl IRefCounted for SceneNavigationGraph {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            graph: NavigationGraph::default(),
        }
    }
}
#[godot_api]
impl SceneNavigationGraph {
    #[func]
    fn replace(&mut self, adjacency: AnyArray) {
        let edges: Vec<Vec<(usize, f64)>> = adjacency
            .iter_shared()
            .map(|links| {
                links
                    .to::<AnyArray>()
                    .iter_shared()
                    .filter_map(|link| {
                        let pair = link.to::<AnyArray>();
                        let next = pair.get(0)?.try_to::<i64>().ok()?;
                        let raw_cost = pair.get(1)?;
                        let cost = if raw_cost.get_type() == VariantType::INT {
                            raw_cost.try_to::<i64>().ok()? as f64
                        } else {
                            raw_cost.try_to::<f64>().ok()?
                        };
                        Some((usize::try_from(next).ok()?, cost))
                    })
                    .collect()
            })
            .collect();
        self.graph.replace(edges);
    }
    #[func]
    fn clear(&mut self) {
        self.graph.clear();
    }
    #[func]
    fn reweight(&mut self, positions: PackedVector3Array) -> bool {
        self.graph.reweight(
            &positions
                .as_slice()
                .iter()
                .copied()
                .map(v3)
                .collect::<Vec<_>>(),
        )
    }
    #[func]
    fn route(&self, from: i64, to: i64) -> PackedInt32Array {
        let (Ok(from), Ok(to)) = (usize::try_from(from), usize::try_from(to)) else {
            return PackedInt32Array::new();
        };
        self.graph
            .route(from, to)
            .into_iter()
            .map(|node| node as i32)
            .collect()
    }
}
