//! Presentation-only weighted tiling, matching Godot's WorkspaceLayout semantics.
use anyhow::{Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

pub type Rect = [f32; 4];
pub const AREA: Rect = [0., 0., 960., 600.];
/// The persisted layout's coordinate/extent limit, not an Overview framing size.
pub const RECT_LIMIT: f32 = 1_000_000.;
/// Share of a divider's span each side keeps when the tiles' minima cannot fit.
pub const CRAMPED_TILE_FLOOR: f32 = 0.25;

/// Keep a dragged window inside the actual placement range without resizing it.
pub fn clamp_window_position(mut rect: Rect) -> Rect {
    for coordinate in &mut rect[..2] {
        *coordinate = coordinate.clamp(-RECT_LIMIT, RECT_LIMIT);
    }
    rect
}

// Internally tagged command enums buffer nested keys as strings. Decode JSON
// object IDs explicitly so snapshots behave identically standalone and in Edit.
pub(crate) fn deserialize_tab_map<'de, D, T>(deserializer: D) -> Result<BTreeMap<u64, T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    BTreeMap::<String, T>::deserialize(deserializer)?
        .into_iter()
        .map(|(key, value)| {
            key.parse()
                .map(|id| (id, value))
                .map_err(serde::de::Error::custom)
        })
        .collect()
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Axis {
    #[default]
    #[serde(rename = "h")]
    Horizontal,
    #[serde(rename = "v")]
    Vertical,
}
impl Axis {
    pub fn name(self) -> &'static str {
        if self == Self::Horizontal {
            "horizontal"
        } else {
            "vertical"
        }
    }
    pub fn opposite(self) -> Self {
        if self == Self::Horizontal {
            Self::Vertical
        } else {
            Self::Horizontal
        }
    }
    fn dimension(self) -> usize {
        if self == Self::Horizontal { 0 } else { 1 }
    }
}
/// Where a pane goes relative to another, as the CLI and API spell it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Left,
    Right,
    Above,
    Below,
}
impl Side {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "left" => Some(Self::Left),
            "right" => Some(Self::Right),
            "above" | "up" | "top" => Some(Self::Above),
            "below" | "down" | "bottom" => Some(Self::Below),
            _ => None,
        }
    }
    pub fn axis(self) -> Axis {
        if matches!(self, Self::Left | Self::Right) { Axis::Horizontal } else { Axis::Vertical }
    }
    pub fn before(self) -> bool {
        matches!(self, Self::Left | Self::Above)
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Kind {
    Leaf { pane: String },
    Split { axis: Axis, children: Vec<Node> },
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Node {
    #[serde(flatten)]
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub weight: Option<f32>,
}
impl Node {
    pub fn leaf(key: impl Into<String>) -> Self {
        Self {
            kind: Kind::Leaf { pane: key.into() },
            weight: None,
        }
    }
    pub fn branch(axis: Axis, children: Vec<Self>) -> Self {
        Self {
            kind: Kind::Split { axis, children },
            weight: None,
        }
    }
    pub fn keys(&self) -> Vec<String> {
        match &self.kind {
            Kind::Leaf { pane } => vec![pane.clone()],
            Kind::Split { children, .. } => children.iter().flat_map(Node::keys).collect(),
        }
    }
    pub fn axis(&self) -> Option<Axis> {
        match &self.kind {
            Kind::Split { axis, .. } => Some(*axis),
            _ => None,
        }
    }
    fn is_leaf(&self, key: &str) -> bool {
        matches!(&self.kind,Kind::Leaf{pane} if pane==key)
    }
    pub fn prune(mut self, eligible: &BTreeSet<String>) -> Option<Self> {
        match self.kind {
            Kind::Leaf { ref pane } => eligible.contains(pane).then_some(self),
            Kind::Split { axis, children } => {
                let mut kept: Vec<_> = children
                    .into_iter()
                    .filter_map(|n| n.prune(eligible))
                    .collect();
                match kept.len() {
                    0 => None,
                    1 => {
                        let mut only = kept.pop().unwrap();
                        only.weight = self.weight;
                        Some(only)
                    }
                    _ => {
                        self.kind = Kind::Split {
                            axis,
                            children: kept,
                        };
                        Some(self)
                    }
                }
            }
        }
    }
    pub fn insert(mut self, target: &str, key: &str, axis: Axis, before: bool) -> Self {
        if self.is_leaf(target) {
            return self.wrap(key, axis, before);
        }
        if let Kind::Split {
            axis: parent_axis,
            children,
        } = &mut self.kind
        {
            for index in 0..children.len() {
                if *parent_axis == axis && children[index].is_leaf(target) {
                    let weighted = children.iter().any(|n| n.weight.is_some());
                    let mut new = Node::leaf(key);
                    if weighted {
                        let weight = children[index].weight.unwrap_or(1.) * 0.5;
                        children[index].weight = Some(weight);
                        new.weight = Some(weight);
                    }
                    children.insert(if before { index } else { index + 1 }, new);
                    return self;
                }
                if children[index].keys().iter().any(|k| k == target) {
                    children[index] = children[index].clone().insert(target, key, axis, before);
                    return self;
                }
            }
        }
        Self::branch(axis, vec![self, Self::leaf(key)])
    }
    fn wrap(mut self, key: &str, axis: Axis, before: bool) -> Self {
        let weight = self.weight.take();
        let leaf = Self::leaf(key);
        Self {
            weight,
            kind: Kind::Split {
                axis,
                children: if before {
                    vec![leaf, self]
                } else {
                    vec![self, leaf]
                },
            },
        }
    }
    pub fn join(mut self, target: &str, key: &str, axis: Axis, before: bool) -> Self {
        if self.is_leaf(target) {
            return self.wrap(key, axis, before);
        }
        if let Kind::Split { children, .. } = &mut self.kind {
            if let Some(child) = children
                .iter_mut()
                .find(|n| n.keys().iter().any(|k| k == target))
            {
                *child = child.clone().join(target, key, axis, before);
            }
        }
        self
    }
    pub fn rename(&mut self, old: &str, new: &str) {
        match &mut self.kind {
            Kind::Leaf { pane } => {
                if pane == old {
                    *pane = new.into();
                }
            }
            Kind::Split { children, .. } => {
                for child in children {
                    child.rename(old, new);
                }
            }
        }
    }
    pub fn balance(&mut self) {
        self.weight = None;
        if let Kind::Split { children, .. } = &mut self.kind {
            for child in children {
                child.balance();
            }
        }
    }
    pub fn child_rects(&self, area: Rect, gap: f32) -> Vec<Rect> {
        let Kind::Split { axis, children } = &self.kind else {
            return vec![];
        };
        if children.is_empty() {
            return vec![];
        }
        let dim = axis.dimension();
        let extent = area[dim + 2];
        let gap = gap
            .max(0.)
            .min(extent / (children.len() as f32 * 2.).max(1.));
        let available = (extent - gap * (children.len() - 1) as f32).max(0.);
        let total: f32 = children
            .iter()
            .map(|c| c.weight.unwrap_or(1.).max(0.001))
            .sum();
        let mut offset = 0.;
        children
            .iter()
            .map(|child| {
                let length = available * child.weight.unwrap_or(1.).max(0.001) / total;
                let mut rect = area;
                rect[dim] += offset;
                rect[dim + 2] = length;
                offset += length + gap;
                rect
            })
            .collect()
    }
    pub fn rectangles(&self, area: Rect, gap: f32, out: &mut BTreeMap<String, Rect>) {
        match &self.kind {
            Kind::Leaf { pane } => {
                out.insert(pane.clone(), area);
            }
            Kind::Split { children, .. } => {
                for (child, rect) in children.iter().zip(self.child_rects(area, gap)) {
                    child.rectangles(rect, gap, out);
                }
            }
        }
    }
    pub fn minimum(&self, gap: f32, minima: &BTreeMap<String, [f32; 2]>) -> [f32; 2] {
        match &self.kind {
            Kind::Leaf { pane } => minima.get(pane).copied().unwrap_or([216., 149.]),
            Kind::Split { axis, children } => {
                let dim = axis.dimension();
                let mut size = [0_f32; 2];
                for c in children {
                    let child = c.minimum(gap, minima);
                    size[dim] += child[dim];
                    size[1 - dim] = size[1 - dim].max(child[1 - dim]);
                }
                size[dim] += gap * children.len().saturating_sub(1) as f32;
                size
            }
        }
    }
    fn validate(&self, depth: usize, keys: &mut BTreeSet<String>) -> Result<()> {
        ensure!(depth < 64, "Tiling tree is too deep");
        ensure!(
            self.weight
                .is_none_or(|w| w.is_finite() && w > 0. && w < 1_000_000.),
            "Invalid tile weight"
        );
        match &self.kind {
            Kind::Leaf { pane } => {
                ensure!(
                    surface_key(pane) && keys.insert(pane.clone()),
                    "Invalid or duplicate tile surface"
                );
            }
            Kind::Split { children, .. } => {
                ensure!((2..=256).contains(&children.len()), "Invalid tile branch");
                for c in children {
                    c.validate(depth + 1, keys)?;
                }
            }
        }
        Ok(())
    }
    pub fn dividers(&self, area: Rect, gap: f32, path: Vec<usize>, out: &mut Vec<Divider>) {
        let Kind::Split { axis, children } = &self.kind else {
            return;
        };
        let rects = self.child_rects(area, gap);
        let dim = axis.dimension();
        for (index, rect) in rects.iter().enumerate() {
            if index + 1 < rects.len() {
                let mut line = area;
                line[dim] = rect[dim] + rect[dim + 2];
                line[dim + 2] = rects[index + 1][dim] - line[dim];
                out.push(Divider {
                    path: path.clone(),
                    index,
                    rect: line,
                    area,
                    gap,
                    axis: *axis,
                });
            }
            let mut child_path = path.clone();
            child_path.push(index);
            children[index].dividers(*rect, gap, child_path, out);
        }
    }
    pub fn resize(&mut self, divider: &Divider, delta: f32) -> Result<()> {
        self.resize_with_minima(divider, delta, &BTreeMap::new())
    }
    pub fn resize_with_minima(
        &mut self,
        divider: &Divider,
        delta: f32,
        minima: &BTreeMap<String, [f32; 2]>,
    ) -> Result<()> {
        ensure!(delta.is_finite(), "Invalid divider motion");
        let mut parent = self;
        for index in &divider.path {
            let Kind::Split { children, .. } = &mut parent.kind else {
                bail!("Divider branch changed")
            };
            parent = children
                .get_mut(*index)
                .ok_or_else(|| anyhow::anyhow!("Divider branch changed"))?;
        }
        let rects = parent.child_rects(divider.area, divider.gap);
        let dim = divider.axis.dimension();
        let Kind::Split { axis, children } = &mut parent.kind else {
            bail!("Divider branch changed")
        };
        ensure!(
            *axis == divider.axis && divider.index + 1 < children.len(),
            "Divider branch changed"
        );
        let index = divider.index;
        let first = rects[index][dim + 2];
        let total = first + rects[index + 1][dim + 2];
        if total <= 0. {
            return Ok(());
        }
        let mut a = children[index].minimum(divider.gap, minima)[dim];
        let mut b = children[index + 1].minimum(divider.gap, minima)[dim];
        if a + b > total {
            // A cramped area (a phone between docks) cannot honor both minima.
            // Scaling them would pin the divider; keep it movable instead.
            let floor = total * CRAMPED_TILE_FLOOR;
            (a, b) = (a.min(floor), b.min(floor));
        }
        let next = (first + delta).clamp(a, total - b);
        for c in children.iter_mut() {
            c.weight = Some(c.weight.unwrap_or(1.).max(0.001));
        }
        let combined = children[index].weight.unwrap() + children[index + 1].weight.unwrap();
        children[index].weight = Some(combined * next / total);
        children[index + 1].weight = Some(combined * (total - next) / total);
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Window {
    pub key: String,
    pub shown: bool,
    pub stashed: bool,
    pub graph_floating: bool,
    pub rect: Rect,
}
impl Window {
    pub fn new(key: impl Into<String>, rect: Rect) -> Self {
        Self {
            key: key.into(),
            shown: true,
            stashed: false,
            graph_floating: false,
            rect,
        }
    }
    /// Shown in the Main view: neither stashed nor floating as a graph node.
    pub fn in_main(&self) -> bool {
        self.shown && !self.stashed && !self.graph_floating
    }
}
/// Shared graph geometry, expressed in workspace coordinates (never screen pixels).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct GraphVisual {
    pub routes: BTreeMap<String, Vec<String>>,
    pub reroutes: BTreeMap<String, Reroute>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Reroute {
    pub position: [f32; 2],
}
impl GraphVisual {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.routes.len() <= 4096 && self.reroutes.len() <= 4096, "Too many graph routes");
        for (id, point) in &self.reroutes {
            ensure!(!id.is_empty() && id.len() <= 128, "Invalid reroute ID");
            ensure!(point.position.iter().all(|n| n.is_finite() && n.abs() <= 1_000_000.), "Invalid reroute position");
        }
        for (edge, route) in &self.routes {
            ensure!(edge.len() <= 1024 && route.len() <= 256, "Invalid graph route");
            ensure!(route.iter().all(|id| self.reroutes.contains_key(id)), "Unknown reroute");
        }
        Ok(())
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TabLayout {
    pub graph_visual: GraphVisual,
    pub enabled: bool,
    pub physics: bool,
    pub physics_anchor: Option<String>,
    pub axis: Axis,
    pub gap: Option<f32>,
    pub focused: String,
    pub windows: Vec<Window>,
    pub tiles: Option<Node>,
}
impl Default for TabLayout {
    fn default() -> Self {
        Self {
            graph_visual: GraphVisual::default(),
            enabled: false,
            physics: true,
            physics_anchor: None,
            axis: Axis::Horizontal,
            gap: None,
            focused: String::new(),
            windows: vec![],
            tiles: None,
        }
    }
}
impl TabLayout {
    /// One-based pane addresses use Main first, then the remaining panes in
    /// stored order. Only tiled Main panes are sorted left-to-right by row.
    pub fn numbered_keys(&self) -> Vec<String> {
        let mut main: Vec<_> = self.windows.iter().filter(|w| w.in_main()).collect();
        if self.enabled && main.len() > 1 {
            let mut rects = BTreeMap::new();
            if let Some(tiles) = self.normalized_tiles() {
                // No camera, viewport size or decorative gaps in pane numbering.
                tiles.rectangles([0., 0., 1., 1.], 0., &mut rects);
            }
            main.sort_by_key(|w| {
                let rect = rects[&w.key];
                // Equivalent nested splits share a row despite float rounding.
                ((rect[1] * 1_000_000.).round() as i64,
                 (rect[0] * 1_000_000.).round() as i64)
            });
        }
        main.into_iter()
            .chain(self.windows.iter().filter(|w| !w.in_main()))
            .map(|w| w.key.clone())
            .collect()
    }

    pub fn window(&self, key: &str) -> Option<&Window> {
        self.windows.iter().find(|w| w.key == key)
    }
    pub fn window_mut(&mut self, key: &str) -> Option<&mut Window> {
        self.windows.iter_mut().find(|w| w.key == key)
    }
    pub fn remove(&mut self, key: &str) -> Option<Window> {
        let index = self.windows.iter().position(|w| w.key == key)?;
        let window = self.windows.remove(index);
        let eligible = self.windows.iter().map(|w| w.key.clone()).collect();
        self.tiles = self.tiles.take().and_then(|n| n.prune(&eligible));
        if self.focused == key {
            self.focused = self
                .windows
                .first()
                .map(|w| w.key.clone())
                .unwrap_or_default();
        }
        Some(window)
    }
    /// Add a managed split or a floating neighbor with the authored Godot
    /// placement rules, retaining the selected tab mode and source flags.
    pub fn add_neighbor(
        &mut self,
        source: &str,
        key: &str,
        axis: Axis,
        before: bool,
        area: Rect,
    ) -> Result<()> {
        ensure!(self.window(key).is_none(), "Surface already exists");
        let mut incoming = self
            .window(source)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("Unknown split source"))?;
        ensure!(incoming.shown, "Split source is hidden");
        self.arrange(area); // Materialize any implicit existing tree before adding the new member.
        incoming.key = key.into();
        let dimension = axis.dimension();
        let offset = (incoming.rect[dimension + 2] - 40.).max(40.);
        incoming.rect[dimension] += if before { -offset } else { offset };
        if self.enabled && !incoming.stashed && !incoming.graph_floating {
            self.tiles = Some(match self.tiles.take() {
                Some(node) => node.insert(source, key, axis, before),
                None => Node::leaf(key),
            });
        }
        self.windows.push(incoming);
        self.focused = key.into();
        self.physics_anchor = Some(source.into());
        Ok(())
    }
    /// Place `key` fully beside `source`.
    ///
    /// Tiled tabs split the source's tile; floating tabs put the whole window
    /// next to the source, one gap apart, so a planned graph reads left to
    /// right or top to bottom.
    pub fn add_beside(&mut self, source: &str, key: &str, side: Side, area: Rect) -> Result<()> {
        ensure!(self.window(key).is_none(), "Surface already exists");
        let mut incoming = self
            .window(source)
            .cloned()
            .ok_or_else(|| anyhow::anyhow!("Unknown placement source"))?;
        ensure!(incoming.shown, "Placement source is hidden");
        incoming.key = key.into();
        self.insert_beside(incoming, source, side, area)
    }
    /// Move an existing pane beside another one in the same tab.
    pub fn move_beside(&mut self, key: &str, source: &str, side: Side, area: Rect) -> Result<()> {
        ensure!(key != source, "A pane cannot be placed beside itself");
        ensure!(self.window(source).is_some(), "Unknown placement source");
        let focused = self.focused.clone();
        let mut window = self.remove(key).ok_or_else(|| anyhow::anyhow!("Unknown pane"))?;
        let anchor = self.window(source).unwrap();
        // The pane joins its anchor's layer, as a new neighbour does: beside a
        // pane outside Main View it floats there too, instead of tiling into Main.
        window.graph_floating = anchor.graph_floating;
        window.stashed = anchor.stashed;
        let anchor = anchor.rect;
        window.rect[2] = anchor[2];
        window.rect[3] = anchor[3];
        self.insert_beside(window, source, side, area)?;
        self.focused = focused;
        Ok(())
    }
    fn insert_beside(&mut self, mut window: Window, source: &str, side: Side, area: Rect) -> Result<()> {
        self.arrange(area);
        let anchor = self.window(source).unwrap().rect;
        let gap = self.gap.unwrap_or(8.).max(0.);
        let dimension = side.axis().dimension();
        window.rect[dimension] = if side.before() {
            anchor[dimension] - gap - window.rect[dimension + 2]
        } else {
            anchor[dimension] + anchor[dimension + 2] + gap
        };
        window.rect[1 - dimension] = anchor[1 - dimension];
        window.rect = clamp_window_position(window.rect);
        let key = window.key.clone();
        if self.enabled && window.in_main() && self.window(source).is_some_and(Window::in_main) {
            self.tiles = Some(match self.tiles.take() {
                Some(node) => node.insert(source, &key, side.axis(), side.before()),
                None => Node::leaf(&key),
            });
        }
        self.windows.push(window);
        self.focused = key;
        self.physics_anchor = Some(source.into());
        Ok(())
    }
    /// Absolute placement in workspace coordinates. Tiled main panes take
    /// their geometry from the tree, so only floating panes accept it.
    pub fn set_rect(&mut self, key: &str, position: Option<[f32; 2]>, size: Option<[f32; 2]>) -> Result<()> {
        let tiled = self.enabled;
        let window = self.window_mut(key).ok_or_else(|| anyhow::anyhow!("Unknown pane"))?;
        ensure!(!(tiled && window.in_main()), "Pane is tiled; use a side (left/right/above/below) or switch the tab to floating");
        if let Some([x, y]) = position {
            ensure!(x.is_finite() && y.is_finite(), "Position must be finite");
            window.rect[0] = x;
            window.rect[1] = y;
        }
        if let Some([width, height]) = size {
            ensure!(width.is_finite() && height.is_finite() && width >= 40. && height >= 40. && width <= RECT_LIMIT && height <= RECT_LIMIT,
                "Size must be at least 40 by 40 workspace pixels");
            window.rect[2] = width;
            window.rect[3] = height;
        }
        window.rect = clamp_window_position(window.rect);
        Ok(())
    }
    pub fn inner_area(&self, area: Rect) -> Rect {
        let gap = self.gap.unwrap_or(0.).max(0.);
        let x = gap.min(area[2] * 0.25);
        // Match WorkspaceLayout: outer gutters yield before short IME content.
        let y = gap.min(area[3] * 0.25).min((area[3] - 100.).max(0.) * 0.5);
        [area[0] + x, area[1] + y, area[2] - 2. * x, area[3] - 2. * y]
    }
    pub fn normalized_tiles(&self) -> Option<Node> {
        let eligible: BTreeSet<_> = self
            .windows
            .iter()
            .filter(|w| w.in_main())
            .map(|w| w.key.clone())
            .collect();
        let mut tiles = self.tiles.clone().and_then(|n| n.prune(&eligible));
        for window in self.windows.iter().filter(|w| eligible.contains(&w.key)) {
            let keys = tiles.as_ref().map(Node::keys).unwrap_or_default();
            if keys.contains(&window.key) {
                continue;
            }
            let target = if keys.contains(&self.focused) {
                self.focused.as_str()
            } else {
                keys.last().map(String::as_str).unwrap_or("")
            };
            tiles = Some(match tiles {
                Some(node) => node.insert(target, &window.key, self.axis, false),
                None => Node::leaf(&window.key),
            });
        }
        tiles
    }
    pub fn arrange(&mut self, area: Rect) -> BTreeMap<String, Rect> {
        let mut rects: BTreeMap<_, _> = self
            .windows
            .iter()
            .filter(|w| w.shown)
            .map(|w| (w.key.clone(), w.rect))
            .collect();
        if !self.enabled {
            return rects;
        }
        self.tiles = self.normalized_tiles();
        if let Some(node) = &self.tiles {
            node.rectangles(self.inner_area(area), self.gap.unwrap_or(8.), &mut rects);
        }
        rects
    }
    /// Balance the managed Main tree, or size an untiled pane like the only
    /// tile in Main. Resizing never moves a pane or changes its membership.
    pub fn resize_to_fit_main(&mut self, key: &str, area: Rect) -> Result<()> {
        ensure!(area.iter().all(|n| n.is_finite()) && area[2] > 0. && area[3] > 0.,
            "Invalid main area");
        let window = self.window(key).ok_or_else(|| anyhow::anyhow!("Unknown surface"))?;
        ensure!(window.shown, "Surface is hidden");
        if self.enabled && window.in_main() {
            self.tiles = self.normalized_tiles();
            if let Some(node) = &mut self.tiles {
                node.balance();
            }
        } else {
            let fitted = self.inner_area(area);
            let window = self.window_mut(key).unwrap();
            window.rect[2] = fitted[2];
            window.rect[3] = fitted[3];
        }
        Ok(())
    }

    pub fn cycle(&mut self, modes: &[String], area: Rect) -> Result<()> {
        ensure!(!modes.is_empty(), "Expected a nonempty layouts array");
        for mode in modes {
            ensure!(
                [
                    "tiles",
                    "tiling",
                    "floating",
                    "horizontal",
                    "vertical",
                    "h_tiles",
                    "v_tiles"
                ]
                .contains(&mode.as_str()),
                "Unsupported layout {mode}"
            );
        }
        let rects = self.arrange(area);
        let axis = self
            .tiles
            .as_ref()
            .and_then(Node::axis)
            .unwrap_or(self.axis);
        for mode in modes {
            let matched = match mode.as_str() {
                "tiles" | "tiling" => self.enabled,
                "floating" => !self.enabled,
                "horizontal" => axis == Axis::Horizontal,
                "vertical" => axis == Axis::Vertical,
                "h_tiles" => self.enabled && axis == Axis::Horizontal,
                "v_tiles" => self.enabled && axis == Axis::Vertical,
                _ => false,
            };
            if matched {
                continue;
            }
            match mode.as_str() {
                "floating" => {
                    for w in &mut self.windows {
                        if let Some(r) = rects.get(&w.key) {
                            w.rect = *r;
                        }
                    }
                    self.enabled = false;
                }
                "tiles" | "tiling" | "h_tiles" | "v_tiles" => self.enabled = true,
                _ => (),
            }
            if matches!(
                mode.as_str(),
                "horizontal" | "vertical" | "h_tiles" | "v_tiles"
            ) {
                self.axis = if matches!(mode.as_str(), "horizontal" | "h_tiles") {
                    Axis::Horizontal
                } else {
                    Axis::Vertical
                };
                if let Some(Node {
                    kind: Kind::Split { axis, .. },
                    ..
                }) = &mut self.tiles
                {
                    *axis = self.axis;
                }
            }
            break;
        }
        Ok(())
    }
    pub fn place(
        &mut self,
        key: &str,
        rect: Rect,
        area: Rect,
        target: &str,
        edge: &str,
        point: [f32; 2],
    ) -> Result<()> {
        let tiled = self.enabled;
        let item = self
            .window_mut(key)
            .ok_or_else(|| anyhow::anyhow!("Unknown surface"))?;
        item.rect = rect;
        item.graph_floating = false;
        item.stashed = !contains(area, point);
        let stashed = item.stashed;
        if !tiled && !stashed {
            return Ok(());
        }
        let mut eligible: BTreeSet<_> = self
            .tiles
            .as_ref()
            .map(Node::keys)
            .unwrap_or_default()
            .into_iter()
            .collect();
        eligible.remove(key);
        self.tiles = self.tiles.take().and_then(|n| n.prune(&eligible));
        if tiled && !stashed {
            let axis = if edge == "left" || edge == "right" {
                Axis::Horizontal
            } else {
                Axis::Vertical
            };
            let before = edge == "left" || edge == "top";
            self.tiles = Some(match self.tiles.take() {
                Some(node) => node.insert(target, key, axis, before),
                None => Node::leaf(key),
            });
        }
        Ok(())
    }
    pub fn direction(&mut self, verb: &str, direction: &str, area: Rect) -> Result<()> {
        ensure!(self.enabled, "Use tiling layout tiles first");
        let rects = self.arrange(area);
        let source = self.focused.clone();
        let keys = self.tiles.as_ref().map(Node::keys).unwrap_or_default();
        let rects = rects
            .into_iter()
            .filter(|(key, _)| keys.contains(key))
            .collect();
        let target = neighbor(&rects, &source, direction)?;
        if verb == "focus" {
            self.focused = target;
            return Ok(());
        }
        let mut eligible: BTreeSet<_> = self
            .tiles
            .as_ref()
            .map(Node::keys)
            .unwrap_or_default()
            .into_iter()
            .collect();
        eligible.remove(&source);
        let node = self
            .tiles
            .take()
            .and_then(|n| n.prune(&eligible))
            .ok_or_else(|| anyhow::anyhow!("No tiled neighbor"))?;
        let horizontal = direction == "left" || direction == "right";
        self.tiles = Some(if verb == "join-with" {
            node.join(
                &target,
                &source,
                if horizontal {
                    Axis::Vertical
                } else {
                    Axis::Horizontal
                },
                direction == "right" || direction == "down",
            )
        } else {
            node.insert(
                &target,
                &source,
                if horizontal {
                    Axis::Horizontal
                } else {
                    Axis::Vertical
                },
                direction == "left" || direction == "up",
            )
        });
        Ok(())
    }
    pub fn dividers(&self, area: Rect) -> Vec<Divider> {
        let mut out = vec![];
        if self.enabled {
            if let Some(node) = &self.tiles {
                node.dividers(
                    self.inner_area(area),
                    self.gap.unwrap_or(8.),
                    vec![],
                    &mut out,
                );
            }
        }
        out
    }
    pub fn preview(
        &self,
        tab: u64,
        incoming: Vec<Window>,
        rect: Rect,
        area: Rect,
        point: [f32; 2],
    ) -> Result<Proposal> {
        self.preview_placements(tab, incoming, rect, area, point, &BTreeMap::new())
    }
    pub fn preview_placements(
        &self, tab: u64, incoming: Vec<Window>, rect: Rect, area: Rect,
        point: [f32; 2], placements: &BTreeMap<String, Rect>,
    ) -> Result<Proposal> {
        let mut layout = self.clone();
        let keys: Vec<_> = incoming.iter().map(|w| w.key.clone()).collect();
        let baseline = layout.arrange(area);
        let original_tiles = layout.tiles.clone();
        let mut target = String::new();
        let mut edge = "right";
        let mut nearest = f32::INFINITY;
        let tiled = layout.tiles.as_ref().map(Node::keys).unwrap_or_default();
        for window in &layout.windows {
            // Choose drop targets from the original rectangles of the other panes,
            // even when the pointer is over a dragged pane's original slot.
            // Reflowing those rectangles during the drag would move the hit regions.
            if keys.contains(&window.key)
                || window.stashed
                || (layout.enabled && !tiled.contains(&window.key))
            {
                continue;
            }
            if let Some(other) = baseline.get(&window.key) {
                let dx = point[0] - point[0].clamp(other[0], other[0] + other[2]);
                let dy = point[1] - point[1].clamp(other[1], other[1] + other[3]);
                let distance = dx * dx + dy * dy;
                if distance >= nearest { continue; }
                nearest = distance;
                target = window.key.clone();
                let x = (point[0] - other[0] - other[2] * 0.5) / other[2];
                let y = (point[1] - other[1] - other[3] * 0.5) / other[3];
                // Give left/right a full-height quarter of the destination.
                // Pure diagonal sectors narrow to a point near the header and
                // bottom edge, making a clear sideways drop select
                // top/bottom.
                //
                // The middle retains all four sectors, including horizontal
                // reordering along the centerline of a row of panes.
                edge = if x.abs() >= 0.25 || x.abs() >= y.abs() {
                    if x < 0. { "left" } else { "right" }
                } else if y < 0. {
                    "top"
                } else {
                    "bottom"
                };
            }
        }
        // Within its old slot, keep a pane only when the requested side is
        // already its relationship to the neighbor. A different side can
        // reorient the split without first crossing into that neighbor.
        let keep_position = layout.enabled
            && keys.len() == 1
            && tiled.contains(&keys[0])
            && baseline.get(&keys[0]).zip(baseline.get(&target)).is_some_and(
                |(source, other)| {
                    contains(area, point) && contains(*source, point) && match edge {
                        "left" => source[0] + source[2] <= other[0],
                        "right" => other[0] + other[2] <= source[0],
                        "top" => source[1] + source[3] <= other[1],
                        _ => other[1] + other[3] <= source[1],
                    }
                },
            );
        for window in incoming {
            let key = window.key.clone();
            let rect = placements.get(&key).copied().unwrap_or(rect);
            let preserve = window.graph_floating && placements.contains_key(&key);
            if preserve { layout.remove(&key); }
            if layout.window(&key).is_none() {
                layout.windows.push(window);
            }
            if preserve {
                let item = layout.window_mut(&key).unwrap();
                item.rect = rect;
                item.stashed = false;
            } else if keep_position {
                layout.window_mut(&key).unwrap().rect = rect;
            } else {
                layout.place(&key, rect, area, &target, edge, point)?;
            }
            target = key;
        }
        // Reinserting into the same arrangement is a no-op, even with resized
        // tiles. Preserve its weights rather than splitting the neighbor again.
        if let (Some(original), Some(proposed)) = (&original_tiles, &layout.tiles) {
            let mut original_shape = original.clone();
            let mut proposed_shape = proposed.clone();
            original_shape.balance();
            proposed_shape.balance();
            if original_shape == proposed_shape {
                layout.tiles = original_tiles;
            }
        }
        let rectangles = layout.arrange(area);
        Ok(Proposal {
            tab,
            layout,
            rectangles,
            incoming: keys,
            point,
            edge: edge.into(),
            label: if contains(area, point) {
                format!("Tile {edge}")
            } else {
                "Stash".into()
            },
        })
    }
    pub fn validate(&self) -> Result<()> {
        self.graph_visual.validate()?;
        ensure!(self.windows.len() <= 256, "Too many layout surfaces");
        ensure!(
            self.gap
                .is_none_or(|v| v.is_finite() && (0. ..=512.).contains(&v)),
            "Invalid tiling gap"
        );
        let mut keys = BTreeSet::new();
        for w in &self.windows {
            ensure!(
                surface_key(&w.key) && keys.insert(w.key.clone()),
                "Invalid or duplicate layout surface"
            );
            ensure!(
                w.rect
                    .iter()
                    .all(|v| v.is_finite() && v.abs() <= RECT_LIMIT)
                    && w.rect[2] > 0.
                    && w.rect[3] > 0.,
                "Invalid layout rectangle"
            );
        }
        ensure!(
            self.windows.is_empty() || keys.contains(&self.focused),
            "Invalid focused layout surface"
        );
        if let Some(node) = &self.tiles {
            let mut tiled = BTreeSet::new();
            node.validate(0, &mut tiled)?;
            ensure!(tiled.is_subset(&keys), "Tile refers to missing surface");
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Divider {
    pub path: Vec<usize>,
    pub index: usize,
    pub rect: Rect,
    pub area: Rect,
    pub gap: f32,
    pub axis: Axis,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Proposal {
    pub tab: u64,
    pub layout: TabLayout,
    pub rectangles: BTreeMap<String, Rect>,
    pub incoming: Vec<String>,
    pub point: [f32; 2],
    pub edge: String,
    pub label: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Workspace {
    #[serde(deserialize_with = "deserialize_tab_map")]
    pub tabs: BTreeMap<u64, TabLayout>,
    pub default_enabled: bool,
    pub default_axis: Axis,
    pub default_gap: Option<f32>,
}
impl Default for Workspace {
    fn default() -> Self {
        Self {
            tabs: BTreeMap::new(),
            default_enabled: true,
            default_axis: Axis::Horizontal,
            default_gap: Some(8.),
        }
    }
}
impl Workspace {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.default_gap
                .is_none_or(|gap| gap.is_finite() && (0.0..=128.0).contains(&gap)),
            "Invalid default tiling gap"
        );
        ensure!(self.tabs.len() <= 256, "Too many layout tabs");
        let mut keys = BTreeSet::new();
        for (id, tab) in &self.tabs {
            ensure!(*id > 0, "Invalid layout tab");
            tab.validate()?;
            for w in &tab.windows {
                ensure!(keys.insert(&w.key), "Surface appears in more than one tab");
            }
        }
        Ok(())
    }
    pub fn reconcile(&mut self, live: &[(u64, Window)], tabs: &[u64]) {
        self.tabs.retain(|id, _| tabs.contains(id));
        for (id, tab) in &mut self.tabs {
            // Older saved tabs omit the configured gap. Godot applies the
            // workspace preference during refresh, before arranging a tree.
            // Keep explicit zero/custom tab gaps intact.
            tab.gap.get_or_insert(self.default_gap.unwrap_or(8.));
            let removed: Vec<_> = tab
                .windows
                .iter()
                .filter(|w| !live.iter().any(|(t, p)| t == id && p.key == w.key))
                .map(|w| w.key.clone())
                .collect();
            for key in removed {
                tab.remove(&key);
            }
        }
        for (id, window) in live {
            let enabled = self.default_enabled;
            let axis = self.default_axis;
            let gap = Some(self.default_gap.unwrap_or(8.));
            let tab = self.tabs.entry(*id).or_insert_with(|| TabLayout {
                enabled,
                axis,
                gap,
                ..Default::default()
            });
            let enabled = tab.enabled;
            if let Some(existing) = tab.window_mut(&window.key) {
                existing.shown = window.shown;
                if !enabled {
                    existing.rect = window.rect;
                    existing.stashed = window.stashed;
                }
            } else {
                tab.windows.push(window.clone());
            }
            if !tab.windows.iter().any(|w| w.key == tab.focused) {
                tab.focused = window.key.clone();
            }
        }
    }
}

pub fn contains(rect: Rect, point: [f32; 2]) -> bool {
    point[0] >= rect[0]
        && point[1] >= rect[1]
        && point[0] < rect[0] + rect[2]
        && point[1] < rect[1] + rect[3]
}
fn surface_key(key: &str) -> bool {
    crate::pane_id::parse(key).is_some()
}
pub fn neighbor(rects: &BTreeMap<String, Rect>, key: &str, direction: &str) -> Result<String> {
    let (origin, dim, sign) = match (rects.get(key), direction) {
        (Some(r), "left") => (*r, 0, -1.),
        (Some(r), "right") => (*r, 0, 1.),
        (Some(r), "up") => (*r, 1, -1.),
        (Some(r), "down") => (*r, 1, 1.),
        (None, _) => bail!("Focused surface is not tiled"),
        _ => bail!("Expected left, right, up or down"),
    };
    let mut best = (f32::INFINITY, f32::INFINITY);
    let mut target = None;
    for (other, r) in rects {
        if other == key {
            continue;
        }
        let cross = 1 - dim;
        if r[cross] + r[cross + 2] <= origin[cross] || r[cross] >= origin[cross] + origin[cross + 2]
        {
            continue;
        }
        let forward = (r[dim] + r[dim + 2] * 0.5 - origin[dim] - origin[dim + 2] * 0.5) * sign;
        if forward <= 0.5 {
            continue;
        }
        let sideways =
            (r[cross] + r[cross + 2] * 0.5 - origin[cross] - origin[cross + 2] * 0.5).abs();
        let gap = if sign > 0. { r[dim] - origin[dim] - origin[dim + 2] }
            else { origin[dim] - r[dim] - r[dim + 2] };
        let score = (gap.max(0.), sideways);
        if score < best {
            best = score;
            target = Some(other.clone());
        }
    }
    target.ok_or_else(|| anyhow::anyhow!("No tiled pane in that direction"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn floating_tab() -> TabLayout {
        let mut tab = TabLayout::default();
        tab.gap = Some(10.);
        tab.windows.push(Window::new("%1", [100., 100., 400., 300.]));
        tab
    }

    #[test]
    fn beside_places_a_whole_floating_window_one_gap_away() {
        let mut tab = floating_tab();
        tab.add_beside("%1", "%2", Side::Right, AREA).unwrap();
        assert_eq!(tab.window("%2").unwrap().rect, [510., 100., 400., 300.]);
        tab.add_beside("%1", "%3", Side::Above, AREA).unwrap();
        assert_eq!(tab.window("%3").unwrap().rect, [100., -210., 400., 300.]);
        assert_eq!(tab.focused, "%3");
        assert!(tab.add_beside("%1", "%2", Side::Left, AREA).is_err(), "duplicate keys are rejected");
        assert!(tab.add_beside("%9", "%4", Side::Left, AREA).is_err(), "unknown sources are rejected");
        assert_eq!(Side::parse("down"), Some(Side::Below));
        assert_eq!(Side::parse("sideways"), None);
    }

    #[test]
    fn move_beside_and_set_rect_edit_existing_floating_windows() {
        let mut tab = floating_tab();
        tab.windows.push(Window::new("%2", [900., 900., 200., 100.]));
        tab.focused = "%1".into();
        tab.move_beside("%2", "%1", Side::Below, AREA).unwrap();
        assert_eq!(tab.window("%2").unwrap().rect, [100., 410., 400., 300.], "moved panes adopt the anchor's size");
        assert_eq!(tab.focused, "%1", "moving does not steal focus");
        tab.set_rect("%2", Some([5., 6.]), Some([300., 200.])).unwrap();
        assert_eq!(tab.window("%2").unwrap().rect, [5., 6., 300., 200.]);
        assert!(tab.set_rect("%2", None, Some([10., 10.])).is_err(), "tiny sizes are rejected");
        assert!(tab.move_beside("%2", "%2", Side::Left, AREA).is_err());
    }

    #[test]
    fn move_beside_joins_the_anchor_outside_main_view() {
        let mut tab = floating_tab();
        tab.enabled = true;
        tab.window_mut("%1").unwrap().graph_floating = true;
        tab.windows.push(Window::new("%2", [60., 50., 1000., 700.]));
        tab.move_beside("%2", "%1", Side::Above, AREA).unwrap();
        let moved = tab.window("%2").unwrap();
        assert!(moved.graph_floating && !moved.in_main(), "a pane placed beside a floating pane floats with it");
        assert_eq!(moved.rect[1] + moved.rect[3], tab.window("%1").unwrap().rect[1] - tab.gap.unwrap_or(8.));
        tab.window_mut("%1").unwrap().graph_floating = false;
        tab.move_beside("%2", "%1", Side::Right, AREA).unwrap();
        assert!(tab.window("%2").unwrap().in_main(), "beside a Main View pane, it tiles into Main View");
    }

    #[test]
    fn beside_splits_tiled_tabs_and_set_rect_refuses_them() {
        let mut tab = floating_tab();
        tab.enabled = true;
        tab.add_beside("%1", "%2", Side::Right, AREA).unwrap();
        tab.add_beside("%2", "%3", Side::Below, AREA).unwrap();
        let rects = tab.arrange(AREA);
        assert!(rects["%1"][0] < rects["%2"][0] && rects["%2"][0] == rects["%3"][0] && rects["%2"][1] < rects["%3"][1]);
        assert!(tab.set_rect("%3", Some([0., 0.]), None).is_err());
        tab.move_beside("%3", "%1", Side::Left, AREA).unwrap();
        let rects = tab.arrange(AREA);
        assert!(rects["%3"][0] < rects["%1"][0] && rects["%1"][0] < rects["%2"][0]);
    }

    #[test]
    fn drag_placement_uses_the_validated_layout_range() {
        for position in [[20_000., -30_000.], [RECT_LIMIT, -RECT_LIMIT], [-RECT_LIMIT, RECT_LIMIT]] {
            let rect = [position[0], position[1], 480., 300.];
            assert_eq!(clamp_window_position(rect), rect);
            let mut tab = TabLayout {
                focused: "%1".into(),
                windows: vec![Window::new("%1", rect)],
                ..Default::default()
            };
            assert!(tab.validate().is_ok());
            for axis in 0..2 {
                tab.windows[0].rect[axis] = position[axis].signum() * (RECT_LIMIT + 100.);
            }
            assert!(tab.validate().is_err());
            tab.windows[0].rect = clamp_window_position(tab.windows[0].rect);
            assert!(tab.validate().is_ok());
            assert_eq!(tab.windows[0].rect[2..], [480., 300.]);
        }
    }

    #[test]
    fn pane_numbers_read_main_rows_before_stored_outside_order() {
        let mut tab = TabLayout {
            enabled: true,
            windows: [20, 9, 21, 3, 8, 22, 23].map(|id|
                Window::new(format!("%{id}"), [0., 0., 100., 100.])).into(),
            tiles: Some(Node::branch(Axis::Horizontal, vec![
                Node::branch(Axis::Vertical, vec![Node::leaf("%3"), Node::leaf("%9")]),
                Node::branch(Axis::Vertical, vec![Node::leaf("%8"), Node::leaf("%22")]),
            ])),
            ..Default::default()
        };
        tab.window_mut("%20").unwrap().stashed = true;
        tab.window_mut("%21").unwrap().shown = false;
        tab.window_mut("%23").unwrap().graph_floating = true;
        let before = tab.clone();
        let expected = ["%3", "%8", "%9", "%22", "%20", "%21", "%23"];
        assert_eq!(tab.numbered_keys(), expected);
        assert_eq!(tab, before, "Numbering is a read-only projection");
        for area in [[0., 0., 1280., 720.], [-100., 250., 720., 1280.]] {
            tab.gap = Some(24.);
            tab.arrange(area);
            assert_eq!(tab.numbered_keys(), expected);
        }
        if let Kind::Split { children, .. } = &mut tab.tiles.as_mut().unwrap().kind {
            children.reverse();
        }
        assert_eq!(tab.numbered_keys(), ["%8", "%3", "%22", "%9", "%20", "%21", "%23"]);
        tab.enabled = false;
        let free = ["%9", "%3", "%8", "%22", "%20", "%21", "%23"];
        assert_eq!(tab.numbered_keys(), free);
        tab.window_mut("%9").unwrap().rect = [800., 600., 100., 100.];
        tab.window_mut("%20").unwrap().rect = [-5000., -5000., 100., 100.];
        assert_eq!(tab.numbered_keys(), free);
    }

    #[test]
    fn pane_numbers_track_stash_restore_close_and_pending_tiles() {
        let mut tab = TabLayout {
            enabled: true,
            windows: (1..=3).map(|id| Window::new(format!("%{id}"), [0., 0., 100., 100.])).collect(),
            tiles: Some(Node::branch(Axis::Horizontal, vec![Node::leaf("%3"), Node::leaf("%2")])),
            ..Default::default()
        };
        tab.window_mut("%1").unwrap().stashed = true;
        let area = [0., 0., 1000., 600.];
        assert_eq!(tab.numbered_keys(), ["%3", "%2", "%1"]);
        tab.place("%2", [1500., 0., 300., 200.], area, "", "right", [1650., 100.]).unwrap();
        assert_eq!(tab.numbered_keys(), ["%3", "%1", "%2"]);
        tab.place("%1", [0., 0., 300., 200.], area, "%3", "left", [150., 100.]).unwrap();
        assert_eq!(tab.numbered_keys(), ["%1", "%3", "%2"]);
        tab.remove("%1");
        assert_eq!(tab.numbered_keys(), ["%3", "%2"]);
        tab.windows.push(Window::new("%4", [0., 0., 300., 200.]));
        tab.focused = "%3".into();
        let before = tab.clone();
        assert_eq!(tab.numbered_keys(), ["%3", "%4", "%2"]);
        assert_eq!(tab, before);
        tab.arrange(area);
        assert_eq!(tab.numbered_keys(), ["%3", "%4", "%2"]);
    }

    #[test]
    fn new_pane_honors_nested_direction_before_and_floating_policy() {
        let area = [0., 34., 1280., 766.];
        let mut tab = TabLayout {
            enabled: true,
            gap: Some(8.),
            windows: vec![Window::new("%1", [24., 60., 800., 500.])],
            focused: "%1".into(),
            ..Default::default()
        };
        tab.add_neighbor("%1", "%2", Axis::Horizontal, false, area)
            .unwrap();
        tab.add_neighbor("%2", "%3", Axis::Vertical, false, area)
            .unwrap();
        let rects = tab.arrange(area);
        assert!(rects["%1"][3] > rects["%2"][3] * 1.9);
        assert!(rects["%2"][1] + rects["%2"][3] < rects["%3"][1]);
        tab.add_neighbor("%2", "%4", Axis::Vertical, true, area)
            .unwrap();
        let rects = tab.arrange(area);
        assert!(rects["%4"][1] + rects["%4"][3] < rects["%2"][1]);
        assert_eq!(tab.focused, "%4");
        tab.enabled = false;
        let source = tab.window_mut("%4").unwrap();
        source.rect = [300., 200., 600., 400.];
        source.stashed = true;
        source.graph_floating = true;
        tab.add_neighbor("%4", "%5", Axis::Horizontal, true, area)
            .unwrap();
        let new = tab.window("%5").unwrap();
        assert_eq!(new.rect, [-260., 200., 600., 400.]);
        assert!(new.stashed && new.graph_floating);
        assert!(!tab.enabled);
        assert_eq!(tab.physics_anchor.as_deref(), Some("%4"));
    }

    #[test]
    fn clean_workspace_tiles_new_panes_but_preserves_saved_floating_choice() {
        let live = [(1, Window::new("%1", [40., 70., 320., 200.]))];
        let area = [0., 34., 1280., 766.];
        let mut clean = Workspace::default();
        clean.reconcile(&live, &[1]);
        assert_eq!(
            clean.tabs.get_mut(&1).unwrap().arrange(area)["%1"],
            [8., 42., 1264., 750.]
        );
        let mut saved: Workspace = serde_json::from_value(serde_json::json!({
            "default_enabled": false,
            "tabs": {"1": {"enabled": false}}
        }))
        .unwrap();
        saved.reconcile(&live, &[1]);
        assert_eq!(
            saved.tabs.get_mut(&1).unwrap().arrange(area)["%1"],
            live[0].1.rect
        );
        saved.reconcile(
            &[
                live[0].clone(),
                (2, Window::new("%2", live[0].1.rect)),
            ],
            &[1, 2],
        );
        assert!(!saved.tabs[&2].enabled);
        // Switching an older saved floating tab to tiles inherits the
        // configured gap exactly once; explicit zero remains edge-to-edge.
        for (default_gap, saved_gap, expected) in [
            (None, None, [8., 42., 1264., 750.]),
            (Some(16.), None, [16., 50., 1248., 734.]),
            (Some(16.), Some(0.), area),
            (Some(16.), Some(4.), [4., 38., 1272., 758.]),
        ] {
            saved.default_gap = default_gap;
            saved.tabs.get_mut(&1).unwrap().gap = saved_gap;
            saved.reconcile(&live, &[1]);
            let layout = saved.tabs.get_mut(&1).unwrap();
            layout.enabled = true;
            assert_eq!(layout.arrange(area)["%1"], expected);
        }
    }
    fn key(n: u64) -> String {
        format!("%{n}")
    }
    fn leaf(n: u64) -> Node {
        Node::leaf(key(n))
    }
    fn tab(count: u64) -> TabLayout {
        TabLayout {
            enabled: true,
            focused: key(1),
            windows: (1..=count).map(|n| Window::new(key(n), AREA)).collect(),
            ..Default::default()
        }
    }
    fn close(a: f32, b: f32) {
        assert!((a - b).abs() < 0.02, "{a} != {b}");
    }
    #[test]
    fn same_axis_additions_flatten_and_stash_stays_free() {
        let mut t = tab(3);
        let mut stash = Window::new(key(4), [1300., -40., 600., 400.]);
        stash.stashed = true;
        t.windows.push(stash);
        let r = t.arrange(AREA);
        let Kind::Split { children, .. } = &t.tiles.as_ref().unwrap().kind else {
            panic!()
        };
        assert_eq!(children.len(), 3);
        close(r[&key(1)][2], r[&key(2)][2]);
        close(r[&key(3)][2], (960. - 16.) / 3.);
        assert_eq!(r[&key(4)], [1300., -40., 600., 400.]);
    }
    #[test]
    fn weighted_dividers_keep_other_branch_and_rescale_proportionally() {
        let area = [0., 80., 1200., 720.];
        let mut n = Node::branch(
            Axis::Horizontal,
            vec![
                leaf(1),
                Node::branch(Axis::Vertical, vec![leaf(2), leaf(3)]),
            ],
        );
        let mut d = vec![];
        n.dividers(area, 8., vec![], &mut d);
        let outer = d.iter().find(|d| d.path.is_empty()).unwrap().clone();
        n.resize(&outer, 160.).unwrap();
        let mut r = BTreeMap::new();
        n.rectangles(area, 8., &mut r);
        close(r[&key(1)][2], 756.);
        close(r[&key(2)][2], 436.);
        d.clear();
        n.dividers(area, 8., vec![], &mut d);
        let inner = d.iter().find(|d| !d.path.is_empty()).unwrap();
        n.resize(inner, 10000.).unwrap();
        r.clear();
        n.rectangles(area, 8., &mut r);
        close(r[&key(3)][3], 149.);
        close(r[&key(1)][2], 756.);
        let ratio = r[&key(1)][2] / (1200. - 8.);
        r.clear();
        n.rectangles([0., 0., 1800., 900.], 8., &mut r);
        close(r[&key(1)][2] / (1800. - 8.), ratio);
        n.balance();
        r.clear();
        n.rectangles(area, 8., &mut r);
        close(r[&key(1)][2], 596.);
        close(r[&key(2)][3], 356.);
    }
    #[test]
    fn resize_to_fit_main_balances_nested_tiles_without_changing_membership() {
        let mut t = tab(3);
        t.gap = Some(8.);
        let mut nested = Node::branch(Axis::Vertical, vec![leaf(2), leaf(3)]);
        if let Kind::Split { children, .. } = &mut nested.kind {
            children[0].weight = Some(3.);
        }
        nested.weight = Some(2.);
        t.tiles = Some(Node::branch(Axis::Horizontal, vec![leaf(1), nested]));
        let mut stash = Window::new(key(4), [1400., 100., 320., 240.]);
        stash.stashed = true;
        t.windows.push(stash);
        let windows = t.windows.clone();
        t.resize_to_fit_main(&key(2), AREA).unwrap();
        let r = t.arrange(AREA);
        close(r[&key(1)][2], r[&key(2)][2]);
        close(r[&key(2)][3], r[&key(3)][3]);
        assert_eq!(t.tiles.as_ref().unwrap().keys(), vec![key(1), key(2), key(3)]);
        assert_eq!(t.windows, windows);
        assert_eq!(t.focused, key(1));
        let balanced = t.clone();
        t.resize_to_fit_main(&key(2), AREA).unwrap();
        assert_eq!(t, balanced);
    }

    #[test]
    fn resize_to_fit_main_sizes_only_the_selected_free_pane() {
        for enabled in [false, true] {
            for (stashed, graph_floating) in [(false, false), (true, false), (false, true)] {
                if enabled && !stashed && !graph_floating { continue; }
                let mut t = tab(2);
                t.gap = Some(8.);
                t.arrange(AREA);
                t.enabled = enabled;
                let selected = t.window_mut(&key(2)).unwrap();
                selected.rect = [-500., 900., 320., 240.];
                selected.stashed = stashed;
                selected.graph_floating = graph_floating;
                let before = t.clone();
                t.resize_to_fit_main(&key(2), AREA).unwrap();
                let fitted = t.inner_area(AREA);
                let mut expected = before;
                expected.window_mut(&key(2)).unwrap().rect = [-500., 900., fitted[2], fitted[3]];
                assert_eq!(t, expected);
                t.resize_to_fit_main(&key(2), AREA).unwrap();
                assert_eq!(t, expected);
            }
        }
    }

    #[test]
    fn resize_to_fit_main_matches_an_empty_main_view_including_gutters() {
        for gap in [0., 8., 32.] {
            for area in [AREA, [20., 40., 800., 110.], [0., 0., 862., 73.]] {
                let mut single = tab(1);
                single.gap = Some(gap);
                let expected = single.arrange(area)[&key(1)];
                let mut free = single.clone();
                free.enabled = false;
                free.resize_to_fit_main(&key(1), area).unwrap();
                assert_eq!(&free.windows[0].rect[2..], &expected[2..]);
            }
        }
    }

    #[test]
    fn shown_hidden_pane_placed_beside_joins_the_tiles() {
        let mut t = tab(3);
        t.window_mut(&key(3)).unwrap().shown = false;
        t.move_beside(&key(3), &key(1), Side::Left, AREA).unwrap();
        assert!(!t.window(&key(3)).unwrap().in_main(), "placement alone keeps a hidden pane hidden");
        t.window_mut(&key(3)).unwrap().shown = true;
        t.move_beside(&key(3), &key(1), Side::Left, AREA).unwrap();
        assert!(t.window(&key(3)).unwrap().in_main());
        assert!(t.tiles.as_ref().unwrap().keys().contains(&key(3)), "a shown placed pane is tiled");
    }

    #[test]
    fn resize_to_fit_main_normalizes_pending_tiles_and_rejects_invalid_targets() {
        let mut t = tab(3);
        let expected = t.normalized_tiles();
        t.resize_to_fit_main(&key(2), AREA).unwrap();
        assert_eq!(t.tiles, expected);
        t.window_mut(&key(3)).unwrap().shown = false;
        let before = t.clone();
        assert!(t.resize_to_fit_main("missing", AREA).is_err());
        assert!(t.resize_to_fit_main(&key(3), AREA).is_err());
        assert!(t.resize_to_fit_main(&key(1), [0., 0., 0., 100.]).is_err());
        assert_eq!(t, before);
    }

    #[test]
    fn divider_clamps_to_real_terminal_and_chromium_minima() {
        let mut t = TabLayout {
            enabled: true,
            windows: vec![Window::new(key(1), AREA), Window::new("%9", AREA)],
            tiles: Some(Node::branch(
                Axis::Vertical,
                vec![leaf(1), Node::leaf("%9")],
            )),
            ..Default::default()
        };
        let d = t.dividers(AREA).remove(0);
        t.tiles.as_mut().unwrap().resize_with_minima(&d, 1_000_000., &[("%9".into(), [200., 136.])].into()).unwrap();
        let r = t.arrange(AREA);
        close(r["%9"][3], 136.);
        assert!(r[&key(1)][3] >= 149.);
        t.tiles.as_mut().unwrap().resize_with_minima(&d, -1_000_000., &[("%9".into(), [200., 136.])].into()).unwrap();
        let r = t.arrange(AREA);
        close(r[&key(1)][3], 149.);
        assert!(r["%9"][3] >= 136.);
    }
    #[test]
    fn cramped_divider_still_moves_within_a_quarter_floor() {
        // Two tiles that cannot both reach their minimum width, as on a phone.
        let area = [0., 0., 308., 600.];
        let mut n = Node::branch(Axis::Horizontal, vec![leaf(1), leaf(2)]);
        let mut dividers = vec![];
        n.dividers(area, 8., vec![], &mut dividers);
        let minima = [(key(1), [160., 100.]), (key(2), [160., 100.])].into_iter().collect();
        n.resize_with_minima(&dividers[0], 60., &minima).unwrap();
        let mut rects = BTreeMap::new();
        n.rectangles(area, 8., &mut rects);
        close(rects[&key(1)][2], 150. + 60.);
        n.resize_with_minima(&dividers[0], 1_000_000., &minima).unwrap();
        rects.clear();
        n.rectangles(area, 8., &mut rects);
        close(rects[&key(2)][2], 300. * CRAMPED_TILE_FLOOR);
    }
    #[test]
    fn divider_uses_each_leafs_selected_font_minimum() {
        let mut n = Node::branch(Axis::Horizontal, vec![leaf(1), leaf(2)]);
        let mut dividers = vec![];
        n.dividers(AREA, 8., vec![], &mut dividers);
        let minima = [(key(1), [200., 120.]), (key(2), [316., 194.])]
            .into_iter()
            .collect();
        n.resize_with_minima(&dividers[0], -1_000_000., &minima)
            .unwrap();
        let mut rects = BTreeMap::new();
        n.rectangles(AREA, 8., &mut rects);
        close(rects[&key(1)][2], 200.);
        n.resize_with_minima(&dividers[0], 1_000_000., &minima)
            .unwrap();
        rects.clear();
        n.rectangles(AREA, 8., &mut rects);
        close(rects[&key(2)][2], 316.);
    }
    #[test]
    fn short_keyboard_area_spends_height_on_content_before_gutters() {
        let layout = TabLayout { gap: Some(8.), ..Default::default() };
        assert_eq!(layout.inner_area([0., 0., 862., 73.]), [8., 0., 846., 73.]);
        assert_eq!(layout.inner_area([0., 0., 862., 110.]), [8., 5., 846., 100.]);
        assert_eq!(layout.inner_area([0., 45., 862., 283.]), [8., 53., 846., 267.]);
    }
    #[test]
    fn weighted_insert_collapse_preserves_outer_share() {
        let mut a = leaf(1);
        a.weight = Some(0.7);
        let mut b = leaf(2);
        b.weight = Some(0.3);
        let n = Node::branch(Axis::Horizontal, vec![a, b]).insert(
            &key(1),
            &key(3),
            Axis::Vertical,
            false,
        );
        let mut r = BTreeMap::new();
        n.rectangles(AREA, 8., &mut r);
        close(r[&key(1)][2], 952. * 0.7);
        close(r[&key(3)][2], 952. * 0.7);
        let n = n.prune(&[key(1), key(2)].into_iter().collect()).unwrap();
        r.clear();
        n.rectangles(AREA, 8., &mut r);
        close(r[&key(1)][2], 952. * 0.7);
    }
    #[test]
    fn floating_roundtrip_keeps_weights_and_free_rectangles() {
        let mut t = tab(2);
        t.arrange(AREA);
        let mut d = vec![];
        t.tiles.as_ref().unwrap().dividers(AREA, 8., vec![], &mut d);
        t.tiles.as_mut().unwrap().resize(&d[0], 100.).unwrap();
        let saved = t.tiles.clone();
        t.cycle(&["floating".into()], AREA).unwrap();
        let r = [90., 120., 500., 300.];
        t.place(&key(1), r, AREA, "", "right", [200., 200.])
            .unwrap();
        assert_eq!(t.arrange(AREA)[&key(1)], r);
        assert_eq!(t.tiles, saved);
        t.cycle(&["tiles".into()], AREA).unwrap();
        assert_eq!(t.tiles, saved);
        assert_ne!(t.arrange(AREA)[&key(1)], r);
    }
    #[test]
    fn preview_is_pure_and_commit_geometry_matches_each_edge() {
        let mut t = tab(2);
        let baseline = t.arrange(AREA);
        let before = t.clone();
        for point in [[5., 300.], [470., 300.], [230., 5.], [230., 590.]] {
            let proposal = t
                .preview(
                    7,
                    vec![Window::new("%9", [0., 0., 300., 250.])],
                    [0., 0., 300., 250.],
                    AREA,
                    point,
                )
                .unwrap();
            assert_eq!(t, before);
            let mut committed = proposal.layout.clone();
            assert_eq!(proposal.rectangles, committed.arrange(AREA));
            assert!(proposal.rectangles.contains_key("%9"));
            assert_ne!(proposal.rectangles[&key(1)], baseline[&key(1)]);
        }
    }
    #[test]
    fn dragging_across_three_columns_never_reverses_order() {
        let mut layout = tab(3);
        layout.gap = Some(8.);
        let original = layout.arrange(AREA);
        let incoming = layout.window(&key(1)).unwrap().clone();
        let before = layout.clone();
        let rect = original[&key(1)];
        let initial = layout.preview(7, vec![incoming.clone()], rect, AREA,
            [rect[0] + 20., rect[1] + 10.]).unwrap();
        assert_eq!(initial.layout.tiles, before.tiles, "Picking up the header keeps its original slot");
        let mut last_index = 0;
        for x in 0..AREA[2] as usize {
            let proposal = layout.preview(7, vec![incoming.clone()], rect, AREA,
                [x as f32, AREA[3] * 0.5]).unwrap();
            let tiles = proposal.layout.tiles.as_ref().unwrap().keys();
            let index = tiles.iter().position(|key| key == &incoming.key).unwrap();
            assert!(index >= last_index, "Moving right reversed the pane order at x={x}");
            last_index = index;
            assert_eq!(proposal.rectangles[&key(1)][3], original[&key(1)][3], "Horizontal drag does not create vertical splits");
        }
        assert_eq!(last_index, 2);
        assert_eq!(layout, before, "Hover never mutates the starting layout");
    }
    #[test]
    fn stacked_panes_accept_side_drops_inside_the_full_height_of_each_quarter() {
        for area in [AREA, [40., 80., 850., 1060.], [-200., 50., 1700., 530.]] {
            let mut layout = tab(2);
            layout.gap = Some(8.);
            layout.tiles = Some(Node::branch(Axis::Vertical, vec![leaf(1), leaf(2)]));
            let original = layout.arrange(area);
            let before = layout.clone();
            // Cover both directions of a local drag and an incoming tab pane.
            for (source, destination) in [(1, 2), (2, 1), (9, 1)] {
                let incoming = layout
                    .window(&key(source))
                    .cloned()
                    .unwrap_or_else(|| Window::new(key(source), [0., 0., 320., 200.]));
                let target = original[&key(destination)];
                for (x, edge) in [
                    (0.05, "left"),
                    (0.2, "left"),
                    (0.25, "left"),
                    (0.75, "right"),
                    (0.8, "right"),
                    (0.95, "right"),
                ] {
                    for y in [0.01, 0.1, 0.5, 0.9, 0.99] {
                        let point = [target[0] + target[2] * x, target[1] + target[3] * y];
                        let proposal = layout
                            .preview(7, vec![incoming.clone()], incoming.rect, area, point)
                            .unwrap();
                        assert_eq!(proposal.edge, edge, "source={source}, point={point:?}");
                        let moved = proposal.rectangles[&key(source)];
                        let other = proposal.rectangles[&key(destination)];
                        close(moved[1], other[1]);
                        close(moved[3], other[3]);
                        if edge == "left" {
                            assert!(moved[0] + moved[2] <= other[0]);
                        } else {
                            assert!(other[0] + other[2] <= moved[0]);
                        }
                        let mut committed = proposal.layout.clone();
                        assert_eq!(proposal.rectangles, committed.arrange(area));
                        assert_eq!(layout, before, "Preview leaves live geometry unchanged");
                    }
                }
                for (y, edge) in [(0.1, "top"), (0.9, "bottom")] {
                    let point = [target[0] + target[2] * 0.5, target[1] + target[3] * y];
                    let proposal = layout
                        .preview(7, vec![incoming.clone()], incoming.rect, area, point)
                        .unwrap();
                    assert_eq!(
                        proposal.edge, edge,
                        "Middle of the pane retains vertical targets"
                    );
                }
            }
        }
    }
    #[test]
    fn source_slots_do_not_block_side_drops_across_stacked_panes() {
        let area = [40., 80., 850., 1060.];
        let mut layout = tab(2);
        layout.gap = Some(8.);
        layout.tiles = Some(Node::branch(Axis::Vertical, vec![leaf(1), leaf(2)]));
        let original = layout.arrange(area);
        let before = layout.clone();
        for source in [1, 2] {
            let incoming = layout.window(&key(source)).unwrap().clone();
            let other = key(3 - source);
            for (x, edge) in [(0.2, "left"), (0.8, "right")] {
                let mut expected = None;
                for y in [0.02, 0.25, 0.49, 0.5, 0.51, 0.75, 0.98] {
                    let point = [area[0] + area[2] * x, area[1] + area[3] * y];
                    let mut rect = original[&incoming.key];
                    rect[0] = point[0] - rect[2] * 0.5;
                    rect[1] = point[1] - 20.;
                    let proposal = layout
                        .preview(7, vec![incoming.clone()], rect, area, point)
                        .unwrap();
                    assert_eq!(proposal.edge, edge);
                    let moved = proposal.rectangles[&incoming.key];
                    let neighbor = proposal.rectangles[&other];
                    close(moved[1], neighbor[1]);
                    close(moved[3], neighbor[3]);
                    assert_eq!(moved[0] < neighbor[0], edge == "left");
                    if let Some(ref expected) = expected {
                        assert_eq!(
                            &proposal.rectangles, expected,
                            "Crossing the old divider must not change the side preview"
                        );
                    } else {
                        expected = Some(proposal.rectangles.clone());
                    }
                    let mut committed = proposal.layout;
                    assert_eq!(proposal.rectangles, committed.arrange(area));
                    assert_eq!(layout, before);
                }
            }
        }
    }
    #[test]
    fn dropping_in_the_same_slot_preserves_nested_tiles_and_weights() {
        let mut first = leaf(1);
        first.weight = Some(0.7);
        let mut second = leaf(2);
        second.weight = Some(0.3);
        let mut nested = Node::branch(Axis::Vertical, vec![leaf(2), leaf(3)]);
        nested.weight = Some(0.3);
        for tree in [
            first.clone(),
            Node::branch(Axis::Vertical, vec![first.clone(), second.clone()]),
            Node::branch(Axis::Horizontal, vec![first.clone(), second]),
            Node::branch(Axis::Horizontal, vec![first, nested]),
        ] {
            let mut layout = tab(tree.keys().len() as u64);
            layout.tiles = Some(tree);
            let original = layout.arrange(AREA);
            let before = layout.clone();
            for incoming in &layout.windows {
                let rect = original[&incoming.key];
                let point = [rect[0] + rect[2] * 0.5, rect[1] + rect[3] * 0.5];
                let proposal = layout
                    .preview(7, vec![incoming.clone()], rect, AREA, point)
                    .unwrap();
                assert_eq!(proposal.layout.tiles, layout.tiles);
                assert_eq!(proposal.rectangles, original);
                assert_eq!(layout, before);
            }
            if layout.windows.len() == 2 {
                let source = &layout.windows[0];
                let target = original[&layout.windows[1].key];
                let mut point = [target[0] + target[2] * 0.5, target[1] + target[3] * 0.5];
                let dim = layout.tiles.as_ref().unwrap().axis().unwrap().dimension();
                point[dim] = target[dim] + 4.;
                let proposal = layout
                    .preview(7, vec![source.clone()], source.rect, AREA, point)
                    .unwrap();
                assert_eq!(
                    proposal.layout.tiles, layout.tiles,
                    "An equivalent drop over the neighbor also retains weights"
                );
                assert_eq!(proposal.rectangles, original);
            }
        }
    }
    #[test]
    fn stash_hide_remove_prune_and_rejoin() {
        let mut t = tab(3);
        t.arrange(AREA);
        t.place(
            &key(2),
            [1000., 0., 300., 300.],
            AREA,
            "",
            "right",
            [1100., 100.],
        )
        .unwrap();
        t.arrange(AREA);
        assert!(!t.tiles.as_ref().unwrap().keys().contains(&key(2)));
        t.place(
            &key(2),
            [0., 0., 300., 300.],
            AREA,
            &key(1),
            "right",
            [100., 100.],
        )
        .unwrap();
        assert!(t.tiles.as_ref().unwrap().keys().contains(&key(2)));
        t.window_mut(&key(3)).unwrap().shown = false;
        t.arrange(AREA);
        assert!(!t.tiles.as_ref().unwrap().keys().contains(&key(3)));
        t.remove(&key(1));
        t.arrange(AREA);
        assert_eq!(t.tiles.as_ref().unwrap().keys(), vec![key(2)]);
    }
    #[test]
    fn join_wraps_neighbor_without_reorienting_outer_branch() {
        let mut t = tab(3);
        t.arrange(AREA);
        t.tiles = Some(Node::branch(
            Axis::Horizontal,
            vec![leaf(1), leaf(2), leaf(3)],
        ));
        t.focused = key(3);
        t.direction("join-with", "left", AREA).unwrap();
        assert_eq!(t.tiles.as_ref().unwrap().axis(), Some(Axis::Horizontal));
        let Kind::Split { children, .. } = &t.tiles.as_ref().unwrap().kind else {
            panic!()
        };
        assert!(
            children
                .iter()
                .any(|n| n.axis() == Some(Axis::Vertical) && n.keys() == vec![key(2), key(3)])
        );
    }
    #[test]
    fn directional_focus_excludes_stash_and_diagonal_and_never_wraps() {
        let mut t = tab(2);
        t.arrange(AREA);
        let mut w = Window::new(key(3), [0., -250., 300., 200.]);
        w.stashed = true;
        t.windows.push(w);
        assert!(t.direction("focus", "up", AREA).is_err());
        let r = [
            (key(1), [0., 0., 100., 100.]),
            (key(2), [110., 110., 100., 100.]),
        ]
        .into_iter()
        .collect();
        assert!(neighbor(&r, &key(1), "right").is_err());
        t.direction("focus", "right", AREA).unwrap();
        assert_eq!(t.focused, key(2));
        assert!(t.direction("focus", "right", AREA).is_err());
    }
    #[test]
    fn configured_gaps_tiny_viewports_and_weights_remain_nonoverlapping() {
        for gap in [0., 8., 24., 128.] {
            let mut t = tab(3);
            t.gap = Some(gap);
            let r = t.arrange([0., 0., 10., 10.]);
            let mut previous = 0.;
            for k in t.tiles.as_ref().unwrap().keys() {
                let v = r[&k];
                assert!(v[0] >= previous - 0.001 && v[2] > 0.);
                previous = v[0] + v[2];
                assert!(previous <= 10.001);
            }
        }
    }
    #[test]
    fn layout_cycle_first_nonmatching_and_new_tab_default_is_independent() {
        let mut t = tab(2);
        t.arrange(AREA);
        t.cycle(&["h_tiles".into(), "v_tiles".into()], AREA)
            .unwrap();
        assert_eq!(t.tiles.as_ref().unwrap().axis(), Some(Axis::Vertical));
        t.cycle(&["h_tiles".into(), "v_tiles".into()], AREA)
            .unwrap();
        assert_eq!(t.tiles.as_ref().unwrap().axis(), Some(Axis::Horizontal));
        let mut w = Workspace {
            default_enabled: true,
            default_axis: Axis::Vertical,
            ..Default::default()
        };
        w.tabs.insert(1, TabLayout::default());
        w.reconcile(
            &[
                (1, Window::new(key(1), AREA)),
                (2, Window::new(key(2), AREA)),
            ],
            &[1, 2],
        );
        assert!(!w.tabs[&1].enabled);
        assert!(w.tabs[&2].enabled);
        assert_eq!(w.tabs[&1].axis, Axis::Horizontal);
        assert_eq!(w.tabs[&2].axis, Axis::Vertical);
        let json = serde_json::to_vec(&w).unwrap();
        let round: Workspace = serde_json::from_slice(&json).unwrap();
        round.validate().unwrap();
        assert_eq!(w, round);
    }
    #[test]
    fn reconciliation_moves_membership_once_without_losing_live_surface() {
        let mut w = Workspace::default();
        for step in 0..100 {
            let live: Vec<_> = (1..=8)
                .map(|n| ((n + step) % 3 + 1, Window::new(key(n), AREA)))
                .collect();
            w.reconcile(&live, &[1, 2, 3]);
            w.validate().unwrap();
            assert_eq!(w.tabs.values().map(|t| t.windows.len()).sum::<usize>(), 8);
            for (id, win) in live {
                assert!(w.tabs[&id].window(&win.key).is_some());
            }
        }
    }
}
