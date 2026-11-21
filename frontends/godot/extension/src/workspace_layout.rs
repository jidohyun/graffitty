//! Godot values at the boundary; all tiling policy lives in workspace-core.
use crate::options::value;
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_workspace_core::tiling::{Axis, Divider, Kind, Node, Rect, TabLayout, Window};
use graffitty_workspace_core::status_strip;
use std::collections::{BTreeMap, BTreeSet};

fn axis(name: GString) -> Axis {
    if name == "v" {
        Axis::Vertical
    } else {
        Axis::Horizontal
    }
}
fn rect(r: Rect2) -> Rect {
    [r.position.x, r.position.y, r.size.x, r.size.y]
}
fn gd_rect(r: Rect) -> Rect2 {
    Rect2::new(Vector2::new(r[0], r[1]), Vector2::new(r[2], r[3]))
}
fn dictionaries(d: &VarDictionary, key: &str) -> Vec<VarDictionary> {
    d.get(key)
        .map(|v| {
            v.to::<godot::builtin::AnyArray>()
                .iter_shared()
                .map(|v| v.to::<VarDictionary>())
                .collect()
        })
        .unwrap_or_default()
}

fn node(d: &VarDictionary) -> Option<Node> {
    if d.is_empty() {
        return None;
    }
    let kind = if d.contains_key("pane") {
        Kind::Leaf {
            pane: value(d, "pane", GString::new()).to_string(),
        }
    } else {
        Kind::Split {
            axis: axis(value(d, "axis", GString::from("h"))),
            children: dictionaries(d, "children")
                .iter()
                .filter_map(node)
                .collect(),
        }
    };
    Some(Node {
        kind,
        weight: d.get("weight").map(|v| v.to::<f32>()),
    })
}
fn gd_node(n: Option<&Node>) -> VarDictionary {
    let mut d = VarDictionary::new();
    if let Some(n) = n {
        match &n.kind {
            Kind::Leaf { pane } => d.set("pane", pane.as_str()),
            Kind::Split { axis, children } => {
                d.set("axis", if *axis == Axis::Horizontal { "h" } else { "v" });
                let mut array = Array::<VarDictionary>::new();
                for child in children {
                    array.push(&gd_node(Some(child)));
                }
                d.set("children", &array);
            }
        }
        if let Some(w) = n.weight {
            d.set("weight", w);
        }
    }
    d
}
fn strings(items: Vec<String>) -> Array<GString> {
    items.iter().map(|s| GString::from(s.as_str())).collect()
}
fn windows(d: &VarDictionary) -> Vec<VarDictionary> {
    if d.contains_key("pane") {
        vec![d.clone()]
    } else {
        dictionaries(d, "windows")
    }
}
fn layout(d: &VarDictionary, focused: GString) -> TabLayout {
    TabLayout {
        enabled: value(d, "tiling", false),
        axis: axis(value(
            d,
            "tiling_axis",
            value(d, "split", GString::from("h")),
        )),
        gap: d.get("tiling_gap").map(|v| v.to::<f32>()),
        focused: focused.to_string(),
        windows: windows(d)
            .iter()
            .map(|w| Window {
                key: value(w, "pane", GString::new()).to_string(),
                shown: value(w, "shown", true),
                stashed: value(w, "stashed", false),
                graph_floating: value(w, "graph_floating", false),
                rect: rect(value(w, "rect", Rect2::default())),
            })
            .collect(),
        tiles: node(&value(d, "tiles", VarDictionary::new())),
        ..Default::default()
    }
}
fn gd_rects(rects: BTreeMap<String, Rect>) -> VarDictionary {
    let mut d = VarDictionary::new();
    for (key, r) in rects {
        d.set(key.as_str(), gd_rect(r));
    }
    d
}
#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
struct StatusStripPath {
    base: Base<RefCounted>,
    motion: status_strip::Motion,
}
#[godot_api]
impl StatusStripPath {
    #[func]
    fn sample(&self, weight: f32) -> Rect2 {
        self.motion.sample(weight).map(gd_rect).unwrap_or_default()
    }
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct WorkspaceLayoutCore {
    base: Base<RefCounted>,
}
#[godot_api]
impl IRefCounted for WorkspaceLayoutCore {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}
#[godot_api]
impl WorkspaceLayoutCore {
    #[func]
    fn status_place(&self, desired: Array<Rect2>, bounds: Rect2, owners: Array<Rect2>,
        obstacles: Array<Rect2>, ports: Array<Rect2>, previous: Array<Rect2>) -> Array<Rect2> {
        let strips: Vec<_> = desired.iter_shared().enumerate().map(|(i, wanted)| status_strip::Strip {
            desired: rect(wanted), owner: rect(owners.get(i).unwrap_or_default()),
            previous: previous.get(i).map(rect),
        }).collect();
        let obstacles: Vec<_> = obstacles.iter_shared().map(rect).collect();
        let ports: Vec<_> = ports.iter_shared().map(rect).collect();
        status_strip::place(&strips, rect(bounds), &obstacles, &ports).into_iter()
            .map(|r| r.map(gd_rect).unwrap_or_default()).collect()
    }
    #[func]
    fn status_carry(&self, previous: Rect2, old_owner: Rect2, owner: Rect2, extent: Vector2) -> Rect2 {
        status_strip::carry(rect(previous), rect(old_owner), rect(owner), [extent.x, extent.y])
            .map(gd_rect).unwrap_or_default()
    }
    #[func]
    fn status_reanchor(&self, previous: Rect2, owner: Rect2, extent: Vector2, margin: Vector2) -> Rect2 {
        status_strip::reanchor(rect(previous), rect(owner), [extent.x, extent.y], [margin.x, margin.y])
            .map(gd_rect).unwrap_or_default()
    }
    #[func]
    fn status_motion(&self, owner: Rect2, start: Rect2, end: Rect2) -> Option<Gd<StatusStripPath>> {
        let motion = status_strip::Motion::new(rect(owner), rect(start), rect(end))?;
        Some(Gd::from_init_fn(|base| StatusStripPath { base, motion }))
    }

    #[func]
    fn navigation_neighbor(
        &self,
        rectangles: VarDictionary,
        source: GString,
        direction: GString,
        algorithm: GString,
    ) -> GString {
        let Some(algorithm) = graffitty_workspace_core::navigation::Algorithm::parse(&algorithm.to_string()) else {
            return GString::new();
        };
        let rects = rectangles
            .iter_shared()
            .map(|(k, v)| (k.to::<GString>().to_string(), rect(v.to::<Rect2>())))
            .collect();
        graffitty_workspace_core::navigation::neighbor_with_algorithm(
            &rects,
            &source.to_string(),
            &direction.to_string(),
            algorithm,
        )
        .unwrap_or_default()
        .as_str()
        .into()
    }
    #[func]
    fn clamp_window_position(&self, window: Rect2) -> Rect2 {
        gd_rect(graffitty_workspace_core::tiling::clamp_window_position(rect(window)))
    }
    #[func]
    fn navigation_reveal(
        &self,
        viewport: Rect2,
        pane: Rect2,
        cursor: Rect2,
        margin: f32,
    ) -> Vector2 {
        let d = graffitty_workspace_core::navigation::reveal_delta(
            rect(viewport),
            rect(pane),
            (cursor.size.x > 0. && cursor.size.y > 0.).then(|| rect(cursor)),
            margin,
        );
        Vector2::new(d[0], d[1])
    }
    #[func]
    fn numbered_keys(&self, tree: VarDictionary, focused: GString) -> Array<GString> {
        strings(layout(&tree, focused).numbered_keys())
    }
    #[func]
    fn normalized_tiles(&self, tree: VarDictionary, focused: GString) -> VarDictionary {
        gd_node(layout(&tree, focused).normalized_tiles().as_ref())
    }
    #[func]
    fn prune_tiles(&self, tree: VarDictionary, eligible: Array<GString>) -> VarDictionary {
        let keys: BTreeSet<_> = eligible.iter_shared().map(|s| s.to_string()).collect();
        gd_node(node(&tree).and_then(|n| n.prune(&keys)).as_ref())
    }
    #[func]
    fn tile_keys(&self, tree: VarDictionary) -> Array<GString> {
        strings(node(&tree).map(|n| n.keys()).unwrap_or_default())
    }
    #[func]
    fn split_tile(
        &self,
        tree: VarDictionary,
        target: GString,
        key: GString,
        direction: GString,
        before: bool,
    ) -> VarDictionary {
        let n = node(&tree)
            .map(|n| {
                n.insert(
                    &target.to_string(),
                    &key.to_string(),
                    axis(direction),
                    before,
                )
            })
            .unwrap_or_else(|| Node::leaf(key.to_string()));
        gd_node(Some(&n))
    }
    #[func]
    fn tile_children(&self, tree: VarDictionary, area: Rect2, gap: f32) -> Array<Rect2> {
        node(&tree)
            .map(|n| n.child_rects(rect(area), gap))
            .unwrap_or_default()
            .into_iter()
            .map(gd_rect)
            .collect()
    }
    #[func]
    fn tile_rectangles(&self, tree: VarDictionary, area: Rect2, gap: f32) -> VarDictionary {
        let mut out = BTreeMap::new();
        if let Some(n) = node(&tree) {
            n.rectangles(rect(area), gap, &mut out);
        }
        gd_rects(out)
    }
    #[func]
    fn tile_dividers(
        &self,
        tree: VarDictionary,
        area: Rect2,
        path: VarArray,
        gap: f32,
    ) -> Array<VarDictionary> {
        let mut out = vec![];
        if let Some(n) = node(&tree) {
            n.dividers(
                rect(area),
                gap,
                path.iter_shared().map(|v| v.to::<i64>() as usize).collect(),
                &mut out,
            );
        }
        out.into_iter()
            .map(|v| {
                let mut d = VarDictionary::new();
                d.set(
                    "path",
                    &v.path
                        .into_iter()
                        .map(|v| (v as i64).to_variant())
                        .collect::<VarArray>(),
                );
                d.set("index", v.index as i64);
                d.set("rect", gd_rect(v.rect));
                d.set("area", gd_rect(v.area));
                d.set("gap_size", v.gap);
                d.set("axis", if v.axis == Axis::Horizontal { "h" } else { "v" });
                d
            })
            .collect()
    }
    #[func]
    fn tile_minimum(&self, tree: VarDictionary, gap: f32) -> Vector2 {
        let Some(n) = node(&tree) else {
            return Vector2::ZERO;
        };
        let minima = n.keys().into_iter().map(|k| (k, [160., 100.])).collect();
        let m = n.minimum(gap, &minima);
        Vector2::new(m[0], m[1])
    }
    #[func]
    fn resize_tiles(
        &self,
        tree: VarDictionary,
        divider: VarDictionary,
        delta: f32,
    ) -> VarDictionary {
        let Some(mut n) = node(&tree) else {
            return tree;
        };
        let v = Divider {
            path: value(&divider, "path", VarArray::new())
                .iter_shared()
                .map(|v| v.to::<i64>() as usize)
                .collect(),
            index: value(&divider, "index", 0i64) as usize,
            area: rect(value(&divider, "area", Rect2::default())),
            rect: rect(value(&divider, "rect", Rect2::default())),
            gap: value(&divider, "gap_size", 8f32),
            axis: axis(value(&divider, "axis", GString::from("h"))),
        };
        let minima = n.keys().into_iter().map(|k| (k, [160., 100.])).collect();
        if let Err(e) = n.resize_with_minima(&v, delta, &minima) {
            godot_error!("Cannot resize tiles: {e}");
            return tree;
        }
        gd_node(Some(&n))
    }
    #[func]
    fn balance_tiles(&self, tree: VarDictionary) -> VarDictionary {
        let mut n = node(&tree);
        if let Some(n) = &mut n {
            n.balance();
        }
        gd_node(n.as_ref())
    }
    #[func]
    fn resize_to_fit_main(
        &self,
        mut tree: VarDictionary,
        key: GString,
        area: Rect2,
        focused: GString,
    ) -> bool {
        let mut l = layout(&tree, focused);
        let previous = l.clone();
        if let Err(e) = l.resize_to_fit_main(&key.to_string(), rect(area)) {
            godot_error!("Cannot resize pane to Main: {e}");
            return false;
        }
        if l.tiles != previous.tiles {
            tree.set("tiles", &gd_node(l.tiles.as_ref()));
        }
        for mut w in windows(&tree) {
            let name = value(&w, "pane", GString::new()).to_string();
            let updated = l.window(&name).unwrap();
            if updated.rect != previous.window(&name).unwrap().rect {
                w.set("rect", gd_rect(updated.rect));
            }
        }
        true
    }
    #[func]
    fn tiling_area(&self, tree: VarDictionary, area: Rect2) -> Rect2 {
        gd_rect(layout(&tree, GString::new()).inner_area(rect(area)))
    }
    #[func]
    fn arrange(
        &self,
        mut tree: VarDictionary,
        area: Rect2,
        focused: GString,
        moving: GString,
    ) -> VarDictionary {
        let mut index = 0;
        for mut w in windows(&tree) {
            if !value(&w, "shown", true) {
                continue;
            }
            if !w.contains_key("rect") {
                let extent = Vector2::new(
                    (area.size.x * 0.85).min(960.).max(320.),
                    (area.size.y * 0.85).min(720.).max(200.),
                );
                w.set(
                    "rect",
                    Rect2::new(
                        area.position + Vector2::splat(24. + 32. * (index % 6) as f32),
                        extent,
                    ),
                );
            }
            index += 1;
        }
        let mut l = layout(&tree, focused);
        let mut rects = l.arrange(rect(area));
        if l.enabled {
            tree.set("tiles", &gd_node(l.tiles.as_ref()));
        }
        if let Some(w) = l.window(&moving.to_string()).filter(|w| w.shown) {
            rects.insert(w.key.clone(), w.rect);
        }
        gd_rects(rects)
    }
    #[func]
    fn place(
        &self,
        mut tree: VarDictionary,
        key: GString,
        bounds: Rect2,
        area: Rect2,
        target: GString,
        edge: GString,
        point: Vector2,
    ) {
        let mut l = layout(&tree, GString::new());
        if l.window(&key.to_string()).is_none() {
            return;
        }
        let previous_tiles = l.tiles.clone();
        if let Err(e) = l.place(
            &key.to_string(),
            rect(bounds),
            rect(area),
            &target.to_string(),
            &edge.to_string(),
            [point.x, point.y],
        ) {
            godot_error!("Cannot place pane: {e}");
            return;
        }
        if l.tiles != previous_tiles {
            tree.set("tiles", &gd_node(l.tiles.as_ref()));
        }
        for mut w in windows(&tree) {
            if value(&w, "pane", GString::new()) == key {
                let value = l.window(&key.to_string()).unwrap();
                w.set("rect", gd_rect(value.rect));
                w.set("stashed", value.stashed);
                w.remove("graph_floating");
            }
        }
    }
    #[func]
    fn rectangles(&self, tree: VarDictionary, area: Rect2) -> VarDictionary {
        let mut floating = tree.duplicate_shallow();
        floating.set("tiling", false);
        self.arrange(floating, area, GString::new(), GString::new())
    }
    #[func]
    fn preview_placement(
        &self,
        tree: VarDictionary,
        incoming: VarDictionary,
        bounds: Rect2,
        area: Rect2,
        point: Vector2,
        placements: VarDictionary,
    ) -> VarDictionary {
        let mut proposed = tree.duplicate_deep();
        self.arrange(proposed.clone(), area, GString::new(), GString::new());
        let base = layout(&proposed, GString::new());
        let incoming_copy = incoming.duplicate_deep();
        let added = layout(&incoming_copy, GString::new());
        let placement_map = placements
            .iter_shared()
            .map(|(k, v)| (k.to::<GString>().to_string(), rect(v.to::<Rect2>())))
            .collect();
        let proposal = match base.preview_placements(
            0,
            added.windows,
            rect(bounds),
            rect(area),
            [point.x, point.y],
            &placement_map,
        ) {
            Ok(p) => p,
            Err(e) => {
                godot_error!("Cannot preview placement: {e}");
                return VarDictionary::new();
            }
        };
        let mut items = windows(&proposed);
        for w in windows(&incoming_copy) {
            if !items
                .iter()
                .any(|old| value(old, "pane", GString::new()) == value(&w, "pane", GString::new()))
            {
                items.push(w);
            }
        }
        let mut output = Array::<VarDictionary>::new();
        for mut w in items {
            let key = value(&w, "pane", GString::new()).to_string();
            if let Some(changed) = proposal.layout.window(&key) {
                w.set("rect", gd_rect(changed.rect));
                w.set("stashed", changed.stashed);
                w.set("graph_floating", changed.graph_floating);
            }
            output.push(&w);
        }
        proposed.remove("pane");
        proposed.set("windows", &output);
        proposed.set("tiles", &gd_node(proposal.layout.tiles.as_ref()));
        if let Some(first) = proposal.incoming.first() {
            proposed.set("physics_anchor", first.as_str());
        }
        let mut result = VarDictionary::new();
        result.set("tree", &proposed);
        result.set("rectangles", &gd_rects(proposal.rectangles));
        result.set("incoming", &strings(proposal.incoming));
        result.set("point", point);
        result.set("edge", proposal.edge.as_str());
        result
    }
}
