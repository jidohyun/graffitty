//! Lay out a frozen UI description with taffy. The result contains
//! rectangles, text runs, icons, and hit regions.
//!
//! Godot draws that list and uses the hit regions for input. The mod
//! script runs in the Rust host. GPUI inspired the layout pipeline.
use std::collections::HashMap;

use graffitty_scene_core::scroll::ElasticGesture;

use taffy::prelude::*;

use crate::spec::{CallbackId, Component, SpecArena, SpecId, SpecOp};
use crate::style::{self, Paint, ScrollbarMode, Style, TextAlign, DEFAULT_TEXT_SIZE};
use crate::value::{Bridged, Color};

#[derive(Clone, Debug, PartialEq)]
pub struct FontSpec {
    pub size: f32,
    pub weight: u16,
    pub italic: bool,
}

/// The frontend's text metrics: the only thing layout cannot know by itself.
pub trait TextMeasure {
    /// Width and height of `text` at `font`; wrapped at `max_width` when given.
    fn measure(&mut self, text: &str, font: &FontSpec, max_width: Option<f32>) -> (f32, f32);
}

/// Fixed-advance metrics for tests and `check`: 0.6 em per character, 1.3 em lines.
pub struct MonospaceMeasure;

impl TextMeasure for MonospaceMeasure {
    fn measure(&mut self, text: &str, font: &FontSpec, max_width: Option<f32>) -> (f32, f32) {
        let advance = font.size * 0.6;
        let width = text.chars().count() as f32 * advance;
        let line = font.size * 1.3;
        match max_width {
            Some(max) if max > advance && width > max => {
                let lines = (width / max).ceil();
                (max, lines * line)
            }
            _ => (width, line),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    pub fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        Rect { x, y, w, h }
    }

    pub fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && y >= self.y && x < self.x + self.w && y < self.y + self.h
    }

    pub fn intersect(&self, other: &Rect) -> Rect {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let right = (self.x + self.w).min(other.x + other.w);
        let bottom = (self.y + self.h).min(other.y + other.h);
        Rect { x, y, w: (right - x).max(0.0), h: (bottom - y).max(0.0) }
    }

    pub fn is_empty(&self) -> bool {
        self.w <= 0.0 || self.h <= 0.0
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Draw {
    Rect {
        rect: Rect,
        color: Color,
        radius: [f32; 4],
    },
    Border {
        rect: Rect,
        /// Top, right, bottom, left.
        width: [f32; 4],
        color: Color,
        radius: [f32; 4],
    },
    Text {
        rect: Rect,
        text: String,
        font: FontSpec,
        color: Color,
        truncate: bool,
        /// One line, never wrapped: `truncate` or `whitespace_nowrap`.
        nowrap: bool,
        align: TextAlign,
        /// `frames(list, ms)`: the frontend shows one string after another.
        frames: Option<(Vec<String>, f32)>,
    },
    Svg {
        rect: Rect,
        path: String,
        color: Color,
        /// `spin(ms)`: one turn per period, driven by the frontend's clock.
        spin_ms: Option<f32>,
        grayscale: bool,
    },
    Image {
        rect: Rect,
        path: String,
        opacity: f32,
        grayscale: bool,
    },
    Clip {
        rect: Rect,
    },
    Unclip,
    Scrollbar {
        track: Rect,
        thumb: Rect,
        color: Color,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct ScrollInfo {
    /// Content and viewport length along the scrolling axis.
    pub content: f32,
    pub viewport: f32,
    pub offset: f32,
    pub horizontal: bool,
}

/// Prefix both axes so arbitrary JS element IDs cannot collide.
pub fn axis_key(key: &str, horizontal: bool) -> String {
    format!("{}{key}", if horizontal { 'x' } else { 'y' })
}

/// How long a scrollbar stays after the last pointer movement or scroll.
pub const SCROLLBAR_IDLE_MS: f64 = 1200.0;
const SCROLLBAR_FADE_IN_MS: f64 = 120.0;
const SCROLLBAR_FADE_OUT_MS: f64 = 280.0;
/// Wider than the drawn bar, so a pointer can take the thumb.
pub const SCROLLBAR_GRAB: f32 = 10.0;

impl ScrollInfo {
    pub fn max_offset(&self) -> f32 {
        (self.content - self.viewport).max(0.0)
    }

    pub fn overflows(&self) -> bool {
        self.content > self.viewport + 0.5
    }

    /// The bar's track and thumb inside a scrolling element's bounds. A
    /// rubber-band `stretch` shortens the thumb against the pulled end
    /// (`scroll_thumb`), as everywhere else.
    pub fn bar(&self, rect: Rect, stretch: f32) -> (Rect, Rect) {
        let track = if self.horizontal {
            Rect::new(rect.x + 2.0, rect.y + rect.h - 6.0, (rect.w - 4.0).max(0.0), 4.0)
        } else {
            Rect::new(rect.x + rect.w - 6.0, rect.y + 2.0, 4.0, (rect.h - 4.0).max(0.0))
        };
        let (start, length) = graffitty_scene_core::scroll::scroll_thumb(
            f64::from(if self.horizontal { track.w } else { track.h }), f64::from(self.offset), f64::from(self.max_offset()),
            f64::from(self.viewport), f64::from(stretch), 18.0);
        if self.horizontal {
            (track, Rect::new(track.x + start as f32, track.y, length as f32, track.h))
        } else {
            (track, Rect::new(track.x, track.y + start as f32, track.w, length as f32))
        }
    }
}

/// One element input can reach: its key, bounds, parent and what it handles.
#[derive(Clone, Debug, PartialEq)]
pub struct Hit {
    pub key: String,
    pub rect: Rect,
    pub parent: Option<usize>,
    pub cursor_pointer: bool,
    pub cursor_ew_resize: bool,
    pub tooltip: Option<String>,
    pub handlers: Vec<(&'static str, Vec<Bridged>, CallbackId)>,
    pub hover_style: bool,
    pub scroll: Option<ScrollInfo>,
    pub scroll_x: Option<ScrollInfo>,
    pub size: (f32, f32),
    pub size_change: Option<CallbackId>,
}

impl Hit {
    /// The scroll geometry interaction state `key` (see `axis_key`) refers to.
    pub fn scroll_for(&self, key: &str) -> Option<&ScrollInfo> {
        if key.strip_prefix('y') == Some(self.key.as_str()) {
            self.scroll.as_ref()
        } else if key.strip_prefix('x') == Some(self.key.as_str()) {
            self.scroll_x.as_ref()
        } else {
            None
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Frame {
    pub size: (f32, f32),
    pub draws: Vec<Draw>,
    pub hits: Vec<Hit>,
    /// Something turns or cycles frames: the frontend keeps redrawing.
    pub animated: bool,
}

impl Rect {
    fn scaled(self, zoom: f32) -> Self {
        Self { x: self.x * zoom, y: self.y * zoom, w: self.w * zoom, h: self.h * zoom }
    }
}

impl Frame {
    /// Scale the draw list's lengths, radii, strokes, font sizes, and frame size.
    ///
    /// Hit regions stay in layout units. Divide pointer positions by the same
    /// zoom factor before sending them.
    pub fn scale(&mut self, zoom: f32) {
        if zoom == 1.0 { return; }
        self.size = (self.size.0 * zoom, self.size.1 * zoom);
        for draw in &mut self.draws {
            match draw {
                Draw::Rect { rect, radius, .. } => {
                    *rect = rect.scaled(zoom);
                    radius.iter_mut().for_each(|v| *v *= zoom);
                }
                Draw::Border { rect, width, radius, .. } => {
                    *rect = rect.scaled(zoom);
                    width.iter_mut().for_each(|v| *v *= zoom);
                    radius.iter_mut().for_each(|v| *v *= zoom);
                }
                Draw::Text { rect, font, .. } => {
                    *rect = rect.scaled(zoom);
                    font.size *= zoom;
                }
                Draw::Svg { rect, .. } | Draw::Image { rect, .. } | Draw::Clip { rect } => *rect = rect.scaled(zoom),
                Draw::Scrollbar { track, thumb, .. } => {
                    *track = track.scaled(zoom);
                    *thumb = thumb.scaled(zoom);
                }
                Draw::Unclip => {}
            }
        }
    }
}

/// Pointer state that changes what layout produces without a new render.
#[derive(Clone, Debug, Default)]
pub struct Interaction {
    /// The hovered element and its ancestors, deepest first.
    pub hovered: Vec<String>,
    pub scroll: HashMap<String, f32>,
    /// The list whose scroll thumb is being dragged.
    pub thumb: Option<String>,
    /// Host time in milliseconds, and when the pointer last acted on the mod
    /// and each list last scrolled: an idle scrollbar hides.
    pub now: f64,
    pub pointer_at: Option<f64>,
    pub scrolled: HashMap<String, f64>,
    pub scrollbar_fades: HashMap<String, ScrollbarFade>,
    /// Each list's rubber band; its pull shifts the list's content past an end.
    pub bands: HashMap<String, ElasticGesture>,
    /// The list a phased scroll gesture began on: it keeps the gesture until
    /// the next one begins, wherever the pointer or finger goes.
    pub gesture_list: Option<String>,
}

impl Interaction {
    fn clamp_offset(&mut self, key: &str, max: f32) -> f32 {
        let Some(offset) = self.scroll.get_mut(key) else { return 0.0 };
        *offset = offset.clamp(0.0, max);
        *offset
    }

    /// How far a list's content is pulled past an end: negative past the top.
    pub fn stretch(&self, key: &str) -> f32 {
        self.bands.get(key).map_or(0.0, |band| band.elastic.stretch() as f32)
    }
}

#[derive(Clone, Debug, Default)]
pub struct ScrollbarFade {
    from: f32,
    target: f32,
    started: f64,
}

impl ScrollbarFade {
    fn duration(&self) -> f64 {
        if self.target > self.from { SCROLLBAR_FADE_IN_MS } else { SCROLLBAR_FADE_OUT_MS }
    }

    fn value(&self, now: f64) -> f32 {
        let t = ((now - self.started) / self.duration()).clamp(0.0, 1.0) as f32;
        self.from + (self.target - self.from) * t * t * (3.0 - 2.0 * t)
    }

    pub(crate) fn animating(&self, now: f64) -> bool {
        self.from != self.target && now < self.started + self.duration()
    }

    fn update(&mut self, shown: bool, now: f64) -> f32 {
        let target = if shown { 1.0 } else { 0.0 };
        if target != self.target {
            self.from = self.value(now);
            self.target = target;
            self.started = now;
        }
        self.value(now)
    }
}

#[derive(Clone)]
struct Resolved {
    style: Style,
    key: String,
    tooltip: Option<String>,
    handlers: Vec<(&'static str, Vec<Bridged>, CallbackId)>,
    size_change: Option<CallbackId>,
    hover_style: bool,
    spin_ms: Option<f32>,
    frames: Option<(Vec<String>, f32)>,
}

enum Leaf {
    Text { text: String, font: FontSpec, nowrap: bool },
    Fixed,
}

#[derive(Clone, Copy)]
struct Inherited {
    color: Color,
    size: f32,
    weight: u16,
    italic: bool,
    align: TextAlign,
    opacity: f32,
    grayscale: bool,
    /// `truncate` / `whitespace_nowrap` are set on the element holding the
    /// text, as in GPUI, so the text run inherits them.
    truncate: bool,
    tooltip_on_truncate: bool,
    nowrap: bool,
}

struct Build<'a> {
    arena: &'a SpecArena,
    interaction: &'a mut Interaction,
    palette: &'a HashMap<String, Color>,
    resolved: HashMap<SpecId, Resolved>,
    tree: TaffyTree<Leaf>,
    nodes: HashMap<SpecId, NodeId>,
    order: Vec<(SpecId, Vec<SpecId>)>,
}

/// Lays out `root` and paints it into a [`Frame`].
///
/// With `size`, the root fills that box (a dock window); without, it wraps
/// its content (a strip over a pane) and the frame reports the size it took.
pub fn compute(
    arena: &SpecArena,
    root: SpecId,
    size: Option<(f32, f32)>,
    interaction: &mut Interaction,
    measure: &mut dyn TextMeasure,
    palette: &HashMap<String, Color>,
) -> Result<Frame, String> {
    let mut build = Build { arena, interaction, palette, resolved: HashMap::new(), tree: TaffyTree::new(), nodes: HashMap::new(), order: Vec::new() };
    let foreground = palette.get("foreground").copied().unwrap_or(Color::rgba(0.9, 0.9, 0.92, 1.0));
    let inherited = Inherited { color: foreground, size: DEFAULT_TEXT_SIZE, weight: 400, italic: false, align: TextAlign::Left, opacity: 1.0, grayscale: false, truncate: false, tooltip_on_truncate: false, nowrap: false };
    let root_node = build.add(root, "", 0, inherited)?;
    build
        .tree
        .compute_layout_with_measure(root_node, match size {
            Some((w, h)) => Size { width: AvailableSpace::Definite(w), height: AvailableSpace::Definite(h) },
            None => Size { width: AvailableSpace::MaxContent, height: AvailableSpace::MaxContent },
        }, |inputs, _node, context, taffy_style| {
            match context {
                Some(Leaf::Text { text, font, nowrap }) => taffy::compute_leaf_layout(inputs, taffy_style, |_, _| 0.0, |known, available| {
                    let limit = known.width.or(match available.width {
                        AvailableSpace::Definite(w) => Some(w),
                        _ => None,
                    });
                    let (w, h) = measure.measure(text, font, if *nowrap { None } else { limit });
                    Size { width: known.width.unwrap_or(w), height: known.height.unwrap_or(h) }
                }),
                Some(Leaf::Fixed) => taffy::compute_leaf_layout(inputs, taffy_style, |_, _| 0.0, |known, _| Size {
                    width: known.width.unwrap_or(16.0),
                    height: known.height.unwrap_or(16.0),
                }),
                None => taffy::compute_leaf_layout(inputs, taffy_style, |_, _| 0.0, |known, _| Size {
                    width: known.width.unwrap_or(0.0),
                    height: known.height.unwrap_or(0.0),
                }),
            }
        })
        .map_err(|e| format!("layout failed: {e}"))?;
    let size = match size {
        Some(size) => size,
        None => {
            let root_layout = build.tree.layout(root_node).map_err(|e| e.to_string())?;
            (root_layout.size.width.ceil(), root_layout.size.height.ceil())
        }
    };
    let mut frame = Frame { size, draws: Vec::new(), hits: Vec::new(), animated: false };
    let clip = Rect::new(0.0, 0.0, size.0, size.1);
    build.paint(root, (0.0, 0.0), clip, None, inherited, &mut frame, measure)?;
    build.interaction.scrollbar_fades.retain(|key, _| frame.hits.iter().any(|hit| hit.scroll_for(key).is_some()));
    build.interaction.bands.retain(|key, _| frame.hits.iter().any(|hit| hit.scroll_for(key).is_some()));
    if build.interaction.gesture_list.as_ref().is_some_and(|key| !build.interaction.bands.contains_key(key) && !frame.hits.iter().any(|hit| hit.scroll_for(key).is_some())) {
        build.interaction.gesture_list = None;
    }
    Ok(frame)
}

impl<'a> Build<'a> {
    fn resolve(&self, id: SpecId, parent_key: &str, index: usize) -> Result<Resolved, String> {
        let node = self.arena.node(id)?;
        let mut style = Style::default();
        let mut key = None;
        let mut tooltip = None;
        let mut handlers = Vec::new();
        let mut size_change = None;
        let mut hover_style = false;
        let mut spin_ms = None;
        let mut frames = None;
        let mut hover_ops: Vec<SpecId> = Vec::new();
        for op in &node.ops {
            match op {
                SpecOp::NullaryStyle(index) => style::apply_nullary(*index, &mut style, self.palette),
                SpecOp::ParamStyle(name, value) => style::apply_param(name, value, &mut style, self.palette)?,
                SpecOp::Method(name, args) => match *name {
                    "id" => key = args.first().map(|v| match v {
                        Bridged::Str(s) => s.clone(),
                        other => format!("{other:?}"),
                    }),
                    "tooltip" => tooltip = args.first().and_then(Bridged::as_str).map(str::to_owned),
                    "mode" => {
                        style.paint.scrollbar = match args.first().and_then(Bridged::as_str) {
                            Some("always") => ScrollbarMode::Always,
                            Some("hover") => ScrollbarMode::Hover,
                            Some("scrolling") => ScrollbarMode::Scrolling,
                            _ => ScrollbarMode::Auto,
                        }
                    }
                    "spin" => spin_ms = args.first().and_then(Bridged::as_f32),
                    "frames" => {
                        let step = args.first().and_then(Bridged::as_f32).unwrap_or(100.0);
                        let list: Vec<String> = args.iter().skip(1).filter_map(Bridged::as_str).map(str::to_owned).collect();
                        if !list.is_empty() {
                            frames = Some((list, step));
                        }
                    }
                    "cursor" => {
                        style.paint.cursor_pointer = args.first().and_then(Bridged::as_str) == Some("pointer");
                        style.paint.cursor_ew_resize = args.first().and_then(Bridged::as_str) == Some("ew-resize");
                    }
                    // Motion without a native primitive here; harmless to accept.
                    "loop" | "transition" | "spring" => {}
                    other => return Err(format!("unknown element method {other:?}")),
                },
                SpecOp::Callback(name, args, callback) => match *name {
                    "on_size_change" => size_change = Some(*callback),
                    _ => handlers.push((*name, args.clone(), *callback)),
                },
                SpecOp::StateStyle(name, detached) => {
                    if *name == "hover" {
                        hover_style = true;
                        hover_ops.push(*detached);
                    }
                }
            }
        }
        let key = key.unwrap_or_else(|| format!("{parent_key}/{index}"));
        if self.interaction.hovered.iter().any(|k| *k == key) {
            for detached in hover_ops {
                for op in &self.arena.node(detached)?.ops {
                    match op {
                        SpecOp::NullaryStyle(index) => style::apply_nullary(*index, &mut style, self.palette),
                        SpecOp::ParamStyle(name, value) => style::apply_param(name, value, &mut style, self.palette)?,
                        _ => {}
                    }
                }
            }
        }
        Ok(Resolved { style, key, tooltip, handlers, size_change, hover_style, spin_ms, frames })
    }

    fn add(&mut self, id: SpecId, parent_key: &str, index: usize, inherited: Inherited) -> Result<NodeId, String> {
        let resolved = self.resolve(id, parent_key, index)?;
        let node = self.arena.node(id)?;
        let next = inherit(inherited, &resolved.style.paint);
        let taffy_style = resolved.style.layout.clone();
        let key = resolved.key.clone();
        let taffy_node = match &node.component {
            Some(Component::Text(text)) => {
                let font = FontSpec { size: next.size, weight: next.weight, italic: next.italic };
                let nowrap = next.nowrap;
                self.tree.new_leaf_with_context(taffy_style, Leaf::Text { text: text.clone(), font, nowrap }).map_err(|e| e.to_string())?
            }
            Some(Component::Svg(_)) | Some(Component::Image(_)) => self.tree.new_leaf_with_context(taffy_style, Leaf::Fixed).map_err(|e| e.to_string())?,
            Some(Component::Div) | None => {
                let mut children = Vec::with_capacity(node.children.len());
                for (child_index, child) in node.children.iter().enumerate() {
                    children.push(self.add(*child, &key, child_index, next)?);
                }
                self.tree.new_with_children(taffy_style, &children).map_err(|e| e.to_string())?
            }
        };
        self.nodes.insert(id, taffy_node);
        self.resolved.insert(id, resolved);
        self.order.push((id, node.children.clone()));
        Ok(taffy_node)
    }

    #[allow(clippy::too_many_arguments)]
    fn paint(&mut self, id: SpecId, origin: (f32, f32), clip: Rect, parent_hit: Option<usize>, inherited: Inherited, frame: &mut Frame, measure: &mut dyn TextMeasure) -> Result<(), String> {
        let resolved = self.resolved[&id].clone();
        let taffy_node = self.nodes[&id];
        let layout = *self.tree.layout(taffy_node).map_err(|e| e.to_string())?;
        let paint = &resolved.style.paint;
        if resolved.style.layout.display == Display::None {
            return Ok(());
        }
        let x = origin.0 + layout.location.x;
        let y = origin.1 + layout.location.y;
        let rect = Rect::new(x, y, layout.size.width, layout.size.height);
        let next = inherit(inherited, paint);
        let opacity = next.opacity;
        let visible_rect = rect.intersect(&clip);
        let node = self.arena.node(id)?;
        let fade = |mut c: Color| {
            if next.grayscale {
                let luminance = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722;
                c.r = luminance; c.g = luminance; c.b = luminance;
            }
            c.with_opacity(opacity)
        };
        if paint.visible {
            if let Some(bg) = paint.background {
                frame.draws.push(Draw::Rect { rect, color: fade(bg), radius: paint.radius });
            }
            let border = [layout.border.top, layout.border.right, layout.border.bottom, layout.border.left];
            if border.iter().any(|w| *w > 0.0)
                && let Some(color) = paint.border_color
            {
                frame.draws.push(Draw::Border { rect, width: border, color: fade(color), radius: paint.radius });
            }
        }
        // Scroll geometry first: hits need it, and so do the children below.
        let mut scroll_offset = 0.0;
        let mut scroll = None;
        let mut scroll_offset_x = 0.0;
        let mut scroll_x = None;
        if paint.scroll_y || paint.scroll_x {
            let (mut content_right, mut content_bottom): (f32, f32) = (0.0, 0.0);
            for child in &node.children {
                if let (Some(child_node), Some(child_resolved)) = (self.nodes.get(child), self.resolved.get(child)) {
                    if child_resolved.style.layout.display == Display::None || child_resolved.style.layout.position == Position::Absolute {
                        continue;
                    }
                    let child_layout = self.tree.layout(*child_node).map_err(|e| e.to_string())?;
                    content_bottom = content_bottom.max(child_layout.location.y + child_layout.size.height + child_layout.margin.bottom);
                    content_right = content_right.max(child_layout.location.x + child_layout.size.width + child_layout.margin.right);
                }
            }
            if paint.scroll_y {
                let content = content_bottom + layout.padding.bottom + layout.border.bottom;
                let max_offset = (content - layout.size.height).max(0.0);
                scroll_offset = self.interaction.clamp_offset(&axis_key(&resolved.key, false), max_offset);
                scroll = Some(ScrollInfo { content, viewport: layout.size.height, offset: scroll_offset, horizontal: false });
            }
            if paint.scroll_x {
                let content = content_right + layout.padding.right + layout.border.right;
                let max_offset = (content - layout.size.width).max(0.0);
                let key = axis_key(&resolved.key, true);
                scroll_offset_x = self.interaction.clamp_offset(&key, max_offset);
                scroll_x = Some(ScrollInfo { content, viewport: layout.size.width, offset: scroll_offset_x, horizontal: true });
            }
        }
        let hit_index = frame.hits.len();
        frame.hits.push(Hit {
            key: resolved.key.clone(),
            rect: visible_rect,
            parent: parent_hit,
            cursor_pointer: paint.cursor_pointer,
            cursor_ew_resize: paint.cursor_ew_resize,
            tooltip: resolved.tooltip.clone(),
            handlers: resolved.handlers.clone(),
            hover_style: resolved.hover_style,
            scroll: scroll.clone(),
            scroll_x: scroll_x.clone(),
            size: (layout.size.width, layout.size.height),
            size_change: resolved.size_change,
        });
        if !paint.visible {
            return Ok(());
        }
        match &node.component {
            Some(Component::Text(text)) => {
                let content = Rect::new(x + layout.padding.left + layout.border.left, y + layout.padding.top + layout.border.top, (layout.size.width - layout.padding.left - layout.padding.right - layout.border.left - layout.border.right).max(0.0), (layout.size.height - layout.padding.top - layout.padding.bottom - layout.border.top - layout.border.bottom).max(0.0));
                if resolved.frames.is_some() {
                    frame.animated = true;
                }
                let font = FontSpec { size: next.size, weight: next.weight, italic: next.italic };
                if next.tooltip_on_truncate && next.truncate && measure.measure(text, &font, None).0 > content.w {
                    frame.hits[hit_index].tooltip = Some(text.clone());
                }
                frame.draws.push(Draw::Text {
                    rect: content,
                    text: text.clone(),
                    font,
                    color: fade(next.color),
                    truncate: next.truncate,
                    nowrap: next.nowrap,
                    align: next.align,
                    frames: resolved.frames.clone(),
                });
            }
            Some(Component::Svg(path)) => {
                if resolved.spin_ms.is_some() {
                    frame.animated = true;
                }
                frame.draws.push(Draw::Svg { rect, path: path.clone(), color: fade(next.color), spin_ms: resolved.spin_ms, grayscale: next.grayscale });
            }
            Some(Component::Image(path)) => frame.draws.push(Draw::Image { rect, path: path.clone(), opacity, grayscale: next.grayscale }),
            Some(Component::Div) | None => {
                let clipped = paint.overflow_hidden || paint.scroll_y || paint.scroll_x;
                let child_clip = if clipped { visible_rect } else { clip };
                if clipped {
                    frame.draws.push(Draw::Clip { rect: visible_rect });
                }
                // The content follows a pull past either end.
                let shift = scroll_offset + if scroll.is_some() { self.interaction.stretch(&axis_key(&resolved.key, false)) } else { 0.0 };
                let shift_x = scroll_offset_x + if scroll_x.is_some() { self.interaction.stretch(&axis_key(&resolved.key, true)) } else { 0.0 };
                for child in &node.children {
                    self.paint(*child, (x - shift_x, y - shift), child_clip, Some(hit_index), next, frame, measure)?;
                }
                if clipped {
                    frame.draws.push(Draw::Unclip);
                }
                // Each overflowing axis draws its bar at the element's visible
                // edge, so a list inside a sideways scroller keeps its bar in view.
                for info in [&scroll, &scroll_x].into_iter().flatten().filter(|info| info.overflows()) {
                    let key = axis_key(&resolved.key, info.horizontal);
                    let dragged = self.interaction.thumb.as_deref() == Some(key.as_str());
                    let hovered = self.interaction.hovered.iter().any(|k| *k == resolved.key);
                    let recent = |at: Option<f64>| at.is_some_and(|at| self.interaction.now - at < SCROLLBAR_IDLE_MS);
                    let shown = dragged || match paint.scrollbar {
                        ScrollbarMode::Auto => (hovered && recent(self.interaction.pointer_at)) || recent(self.interaction.scrolled.get(&key).copied()),
                        ScrollbarMode::Always => true,
                        ScrollbarMode::Hover => hovered,
                        ScrollbarMode::Scrolling => false,
                    };
                    let alpha = if paint.scrollbar == ScrollbarMode::Always {
                        1.0
                    } else {
                        self.interaction.scrollbar_fades.entry(key.clone()).or_default()
                            .update(shown, self.interaction.now)
                    };
                    if alpha > 0.0 && visible_rect.w >= 6.0 && visible_rect.h >= 6.0 {
                        let (track, thumb) = info.bar(visible_rect, self.interaction.stretch(&key));
                        let mut color = fade(self.palette.get("dim").copied().unwrap_or(Color::rgba(1.0, 1.0, 1.0, 0.35)));
                        color.a *= alpha;
                        frame.draws.push(Draw::Scrollbar {
                            track,
                            thumb,
                            color,
                        });
                    }
                }
            }
        }
        Ok(())
    }
}

fn inherit(parent: Inherited, paint: &Paint) -> Inherited {
    Inherited {
        color: paint.text_color.unwrap_or(parent.color),
        size: paint.text_size.unwrap_or(parent.size),
        weight: paint.font_weight.unwrap_or(parent.weight),
        italic: paint.italic.unwrap_or(parent.italic),
        align: paint.align.unwrap_or(parent.align),
        opacity: parent.opacity * paint.opacity,
        grayscale: parent.grayscale || paint.grayscale,
        truncate: parent.truncate || paint.truncate,
        tooltip_on_truncate: parent.tooltip_on_truncate || paint.tooltip_on_truncate,
        nowrap: parent.nowrap || paint.nowrap,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::Component;

    fn arena_with_row() -> (SpecArena, SpecId) {
        let mut arena = SpecArena::default();
        let root = arena.push(Component::Div);
        for name in ["flex", "flex_row", "items_center", "size_full"] {
            arena.record(root, SpecOp::NullaryStyle(style::nullary_index(name).unwrap())).unwrap();
        }
        arena.record(root, SpecOp::ParamStyle("gap", Bridged::Number(8.0))).unwrap();
        arena.record(root, SpecOp::ParamStyle("bg", Bridged::Str("#202126".into()))).unwrap();
        let label = arena.push(Component::Text("hello".into()));
        arena.record(label, SpecOp::Method("id", vec![Bridged::Str("label".into())])).unwrap();
        arena.attach(root, label).unwrap();
        let spacer = arena.push(Component::Div);
        arena.record(spacer, SpecOp::NullaryStyle(style::nullary_index("flex_1").unwrap())).unwrap();
        arena.attach(root, spacer).unwrap();
        let icon = arena.push(Component::Svg("icons/x.svg".into()));
        arena.record(icon, SpecOp::ParamStyle("size", Bridged::Number(12.0))).unwrap();
        arena.record(icon, SpecOp::Method("spin", vec![Bridged::Number(900.0)])).unwrap();
        arena.attach(root, icon).unwrap();
        (arena, root)
    }

    #[test]
    fn a_row_lays_its_children_out_left_to_right() {
        let (arena, root) = arena_with_row();
        let frame = compute(&arena, root, Some((200.0, 28.0)), &mut Interaction::default(), &mut MonospaceMeasure, &HashMap::new()).unwrap();
        assert!(matches!(frame.draws[0], Draw::Rect { rect, .. } if rect == Rect::new(0.0, 0.0, 200.0, 28.0)));
        let text = frame.draws.iter().find_map(|d| match d {
            Draw::Text { rect, text, .. } => Some((*rect, text.clone())),
            _ => None,
        });
        let (rect, text) = text.unwrap();
        assert_eq!(text, "hello");
        assert!((rect.w - 5.0 * 14.0 * 0.6).abs() < 0.01, "text takes its measured width: {rect:?}");
        assert!((rect.y - (28.0 - 14.0 * 1.3) / 2.0).abs() < 0.6, "items_center centers the text vertically: {rect:?}");
        let icon = frame.draws.iter().find_map(|d| match d {
            Draw::Svg { rect, spin_ms, .. } => Some((*rect, *spin_ms)),
            _ => None,
        });
        let (icon_rect, spin) = icon.unwrap();
        assert_eq!(spin, Some(900.0));
        assert!((icon_rect.x - 188.0).abs() < 0.01, "flex_1 spacer pushes the icon to the right edge: {icon_rect:?}");
        assert!(frame.animated);
        assert_eq!(frame.hits[1].key, "label");
        assert_eq!(frame.hits[1].parent, Some(0));
    }

    #[test]
    fn hover_styles_apply_only_while_hovered() {
        let mut arena = SpecArena::default();
        let root = arena.push(Component::Div);
        arena.record(root, SpecOp::Method("id", vec![Bridged::Str("row".into())])).unwrap();
        let hover = arena.detached();
        arena.record(hover, SpecOp::ParamStyle("bg", Bridged::Str("#ff0000".into()))).unwrap();
        arena.record(root, SpecOp::StateStyle("hover", hover)).unwrap();
        let plain = compute(&arena, root, Some((10.0, 10.0)), &mut Interaction::default(), &mut MonospaceMeasure, &HashMap::new()).unwrap();
        assert!(plain.draws.is_empty());
        let mut interaction = Interaction { hovered: vec!["row".into()], ..Default::default() };
        let hovered = compute(&arena, root, Some((10.0, 10.0)), &mut interaction, &mut MonospaceMeasure, &HashMap::new()).unwrap();
        assert!(matches!(hovered.draws[0], Draw::Rect { color, .. } if color.r == 1.0));
        assert!(hovered.hits[0].hover_style);
    }

    #[test]
    fn scrolling_clips_and_offsets_children() {
        let mut arena = SpecArena::default();
        let root = arena.push(Component::Div);
        for name in ["flex", "flex_col", "overflow_y_scrollbar", "size_full"] {
            arena.record(root, SpecOp::NullaryStyle(style::nullary_index(name).unwrap())).unwrap();
        }
        arena.record(root, SpecOp::Method("id", vec![Bridged::Str("list".into())])).unwrap();
        arena.record(root, SpecOp::Method("mode", vec![Bridged::Str("always".into())])).unwrap();
        for i in 0..10 {
            let row = arena.push(Component::Div);
            arena.record(row, SpecOp::ParamStyle("h", Bridged::Number(20.0))).unwrap();
            arena.record(row, SpecOp::NullaryStyle(style::nullary_index("flex_none").unwrap())).unwrap();
            arena.record(row, SpecOp::Method("id", vec![Bridged::Str(format!("row{i}"))])).unwrap();
            arena.attach(root, row).unwrap();
        }
        let mut interaction = Interaction::default();
        interaction.scroll.insert(axis_key("list", false), 30.0);
        interaction.scrolled.insert(axis_key("list", false), 0.0);
        let frame = compute(&arena, root, Some((100.0, 50.0)), &mut interaction, &mut MonospaceMeasure, &HashMap::new()).unwrap();
        let info = frame.hits[0].scroll.clone().unwrap();
        assert_eq!(info.content, 200.0);
        assert_eq!(info.offset, 30.0);
        let row0 = frame.hits.iter().find(|h| h.key == "row0").unwrap();
        assert!(row0.rect.is_empty(), "a row scrolled out is not hittable: {:?}", row0.rect);
        let row2 = frame.hits.iter().find(|h| h.key == "row2").unwrap();
        assert_eq!(row2.rect, Rect::new(0.0, 10.0, 100.0, 20.0));
        assert!(frame.draws.iter().any(|d| matches!(d, Draw::Scrollbar { .. })));
        assert!(matches!(frame.draws[0], Draw::Clip { .. }));
    }

    #[test]
    fn truncate_on_the_container_makes_its_text_one_line() {
        let mut arena = SpecArena::default();
        let root = arena.push(Component::Div);
        for name in ["flex", "flex_row", "size_full"] {
            arena.record(root, SpecOp::NullaryStyle(style::nullary_index(name).unwrap())).unwrap();
        }
        let holder = arena.push(Component::Div);
        for name in ["flex_1", "min_w_0", "truncate"] {
            arena.record(holder, SpecOp::NullaryStyle(style::nullary_index(name).unwrap())).unwrap();
        }
        let text = arena.push(Component::Text("a very long session name that will not fit in the row".into()));
        arena.attach(holder, text).unwrap();
        arena.attach(root, holder).unwrap();
        let frame = compute(&arena, root, Some((120.0, 32.0)), &mut Interaction::default(), &mut MonospaceMeasure, &HashMap::new()).unwrap();
        let run = frame.draws.iter().find_map(|d| match d {
            Draw::Text { rect, truncate, nowrap, .. } => Some((*rect, *truncate, *nowrap)),
            _ => None,
        });
        let (rect, truncate, nowrap) = run.unwrap();
        assert!(truncate && nowrap, "the text run inherits truncate from its holder");
        assert!((rect.h - 18.0).abs() < 1.0, "measured as one line, not wrapped: {rect:?}");
        assert!(rect.w <= 120.0, "and no wider than the row: {rect:?}");
    }

    #[test]
    fn truncated_text_shrinks_to_its_container() {
        let mut arena = SpecArena::default();
        let root = arena.push(Component::Div);
        for name in ["flex", "flex_row", "size_full"] {
            arena.record(root, SpecOp::NullaryStyle(style::nullary_index(name).unwrap())).unwrap();
        }
        let text = arena.push(Component::Text("a very long label that does not fit".into()));
        for name in ["flex_1", "min_w_0", "truncate"] {
            arena.record(text, SpecOp::NullaryStyle(style::nullary_index(name).unwrap())).unwrap();
        }
        arena.attach(root, text).unwrap();
        let fixed = arena.push(Component::Div);
        arena.record(fixed, SpecOp::ParamStyle("w", Bridged::Number(40.0))).unwrap();
        arena.record(fixed, SpecOp::NullaryStyle(style::nullary_index("flex_none").unwrap())).unwrap();
        arena.attach(root, fixed).unwrap();
        let frame = compute(&arena, root, Some((100.0, 20.0)), &mut Interaction::default(), &mut MonospaceMeasure, &HashMap::new()).unwrap();
        let text_rect = frame.draws.iter().find_map(|d| match d {
            Draw::Text { rect, truncate: true, .. } => Some(*rect),
            _ => None,
        });
        assert_eq!(text_rect.unwrap().w, 60.0, "the text yields to the fixed sibling");
    }
}
