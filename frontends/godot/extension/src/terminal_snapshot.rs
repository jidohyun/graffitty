//! Immutable terminal presentation, replayed by the same painter at any density.
//! Owns text/font/image references and resolved decoration geometry, never a PTY,
//! live terminal, viewport texture, or screenshot of the terminal.
use crate::{
    font::Fonts,
    run::{PixelGrid, Run, RunCache},
    sprite,
};
use godot::{
    classes::{
        Control, Font, IControl, IRefCounted, RefCounted, RenderingServer, ShaderMaterial,
        Texture2D,
    },
    prelude::*,
};
use graffitty_terminal_core::vt::style::Underline;
use std::{cell::RefCell, rc::Rc};

enum Drawing {
    Rect(Rect2, Color),
    Image(Rect2, Gd<Texture2D>, Rect2),
    Sprite(Rect2, Color, f32, u32),
    Underline(Rect2, Color, f32, f32, Underline),
    Char(Gd<Font>, Vector2, u32, i32, Color, i32, Color),
    Text(Gd<Font>, Vector2, String, i32, Color, f32, i32, Color),
    Run(Gd<Font>, Run, f32, f32, i32, PixelGrid, i32, Color),
}

impl Drawing {
    fn draw(&self, canvas: Rid, density: f32, runs: &mut RunCache) {
        match self {
            Self::Rect(rect, color) => {
                RenderingServer::singleton().canvas_item_add_rect(canvas, *rect, *color)
            }
            Self::Image(rect, image, source) => RenderingServer::singleton()
                .canvas_item_add_texture_rect_region(canvas, *rect, image.get_rid(), *source),
            Self::Sprite(rect, color, thick, cp) => {
                sprite::draw(canvas, *rect, *color, *thick, *cp);
            }
            Self::Underline(rect, color, thick, y, style) => {
                sprite::underline(canvas, *rect, *color, *thick, *y, *style)
            }
            Self::Char(font, at, cp, size, color, outline, edge) => {
                if *outline > 0 {
                    font.draw_char_outline_ex(canvas, *at, *cp, *size)
                        .size(*outline)
                        .modulate(*edge)
                        .oversampling(density)
                        .done();
                }
                font.draw_char_ex(canvas, *at, *cp, *size)
                    .modulate(*color)
                    .oversampling(density)
                    .done();
            }
            Self::Text(font, at, text, size, color, width, outline, edge) => {
                if *outline > 0 {
                    font.draw_string_outline_ex(canvas, *at, text.as_str())
                        .font_size(*size)
                        .size(*outline)
                        .modulate(*edge)
                        .width(*width)
                        .oversampling(density)
                        .done();
                }
                font.draw_string_ex(canvas, *at, text.as_str())
                    .font_size(*size)
                    .modulate(*color)
                    .width(*width)
                    .oversampling(density)
                    .done();
            }
            Self::Run(font, run, baseline, cell_w, size, grid, outline, edge) => runs.draw(
                canvas,
                font,
                run.clone(),
                *baseline,
                *cell_w,
                *size,
                density,
                *grid,
                *outline,
                *edge,
            ),
        }
    }
}

#[derive(Default)]
pub struct Presentation {
    drawings: Vec<(usize, Drawing)>,
    transforms: [Transform2D; 5],
    image_material: Option<Gd<ShaderMaterial>>,
    background: Color,
}

/// Recording is enabled only when a transition requests an immutable view.
/// Ordinary terminal paints keep their existing immediate native draw path.
pub struct Painter {
    grid: PixelGrid,
    canvases: [Rid; 5],
    recording: Option<RefCell<Presentation>>,
}

impl Painter {
    pub fn new(canvases: [Rid; 5], record: bool, grid: PixelGrid) -> Self {
        Self {
            grid,
            canvases,
            recording: record.then(|| RefCell::new(Presentation::default())),
        }
    }
    fn record(&self, canvas: Rid, drawing: impl FnOnce() -> Drawing) {
        if let Some(recording) = &self.recording {
            let layer = self
                .canvases
                .iter()
                .position(|id| *id == canvas)
                .expect("terminal canvas");
            recording.borrow_mut().drawings.push((layer, drawing()));
        }
    }
    pub fn finish(
        self,
        material: Option<&Gd<ShaderMaterial>>,
        background: Color,
    ) -> Option<Presentation> {
        self.recording.map(|recording| {
            let mut value = recording.into_inner();
            value.image_material = material.map(|m| m.duplicate_resource());
            value.background = background;
            value
        })
    }
    pub fn canvas_item_clear(&self, canvas: Rid) {
        RenderingServer::singleton().canvas_item_clear(canvas);
    }
    pub fn canvas_item_set_transform(&self, canvas: Rid, transform: Transform2D) {
        RenderingServer::singleton().canvas_item_set_transform(canvas, transform);
        if let Some(recording) = &self.recording {
            let layer = self
                .canvases
                .iter()
                .position(|id| *id == canvas)
                .expect("terminal canvas");
            recording.borrow_mut().transforms[layer] = transform;
        }
    }
    pub fn canvas_item_add_rect(&self, canvas: Rid, rect: Rect2, color: Color) {
        let rect = self.grid.rect(rect);
        RenderingServer::singleton().canvas_item_add_rect(canvas, rect, color);
        self.record(canvas, || Drawing::Rect(rect, color));
    }
    pub fn image(&self, canvas: Rid, rect: Rect2, texture: Gd<Texture2D>, source: Rect2) {
        let rect = self.grid.rect(rect);
        RenderingServer::singleton().canvas_item_add_texture_rect_region(
            canvas,
            rect,
            texture.get_rid(),
            source,
        );
        self.record(canvas, || Drawing::Image(rect, texture, source));
    }
    pub fn sprite(&self, canvas: Rid, rect: Rect2, color: Color, thick: f32, cp: u32) -> bool {
        let rect = self.grid.rect(rect);
        let drawn = sprite::draw(canvas, rect, color, thick, cp);
        if drawn {
            self.record(canvas, || Drawing::Sprite(rect, color, thick, cp));
        }
        drawn
    }
    pub fn underline(
        &self,
        canvas: Rid,
        rect: Rect2,
        color: Color,
        thick: f32,
        y: f32,
        style: Underline,
    ) {
        let rect = self.grid.rect(rect);
        sprite::underline(canvas, rect, color, thick, y, style);
        self.record(canvas, || Drawing::Underline(rect, color, thick, y, style));
    }
    pub fn character(
        &self,
        font: &Gd<Font>,
        canvas: Rid,
        at: Vector2,
        cp: u32,
        size: i32,
        color: Color,
        density: f32,
        outline: i32,
        edge: Color,
    ) {
        let at = self.grid.point(at);
        if outline > 0 {
            font.draw_char_outline_ex(canvas, at, cp, size)
                .size(outline)
                .modulate(edge)
                .oversampling(density)
                .done();
        }
        font.draw_char_ex(canvas, at, cp, size)
            .modulate(color)
            .oversampling(density)
            .done();
        self.record(canvas, || {
            Drawing::Char(font.clone(), at, cp, size, color, outline, edge)
        });
    }
    pub fn text(
        &self,
        font: &Gd<Font>,
        canvas: Rid,
        at: Vector2,
        text: &str,
        size: i32,
        color: Color,
        width: f32,
        density: f32,
        outline: i32,
        edge: Color,
    ) {
        let at = self.grid.point(at);
        if outline > 0 {
            font.draw_string_outline_ex(canvas, at, text)
                .font_size(size)
                .size(outline)
                .modulate(edge)
                .width(width)
                .oversampling(density)
                .done();
        }
        font.draw_string_ex(canvas, at, text)
            .font_size(size)
            .modulate(color)
            .width(width)
            .oversampling(density)
            .done();
        self.record(canvas, || {
            Drawing::Text(
                font.clone(),
                at,
                text.to_owned(),
                size,
                color,
                width,
                outline,
                edge,
            )
        });
    }
    pub fn grapheme(
        &self,
        fonts: &Fonts,
        canvas: Rid,
        at: Vector2,
        chars: &[char],
        style: u8,
        wide: bool,
        size: i32,
        color: Color,
        density: f32,
        outline: i32,
        edge: Color,
    ) -> bool {
        if chars.len() < 2 {
            return false;
        }
        let Some(font) = fonts.resolve(chars[0] as u32, style, || wide) else {
            return false;
        };
        self.text(
            &font,
            canvas,
            at,
            &chars.iter().collect::<String>(),
            size,
            color,
            -1.0,
            density,
            outline,
            edge,
        );
        true
    }
    pub fn run(
        &self,
        runs: &mut RunCache,
        canvas: Rid,
        font: &Gd<Font>,
        run: Run,
        baseline: f32,
        cell_w: f32,
        size: i32,
        density: f32,
        outline: i32,
        edge: Color,
    ) {
        self.record(canvas, || {
            Drawing::Run(
                font.clone(),
                run.clone(),
                baseline,
                cell_w,
                size,
                self.grid,
                outline,
                edge,
            )
        });
        runs.draw(
            canvas, font, run, baseline, cell_w, size, density, self.grid, outline, edge,
        );
    }
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct TerminalRenderSnapshot {
    base: Base<RefCounted>,
    presentation: Rc<Presentation>,
    size: Vector2,
    position: Vector2,
}
#[godot_api]
impl IRefCounted for TerminalRenderSnapshot {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            presentation: Rc::default(),
            size: Vector2::ZERO,
            position: Vector2::ZERO,
        }
    }
}
impl TerminalRenderSnapshot {
    pub fn new(presentation: Presentation, size: Vector2, position: Vector2) -> Gd<Self> {
        Gd::from_init_fn(|base| Self {
            base,
            presentation: Rc::new(presentation),
            size,
            position,
        })
    }
}
#[godot_api]
impl TerminalRenderSnapshot {
    #[func]
    fn create_view(&self, density: f32) -> Gd<Control> {
        let mut view = Gd::from_init_fn(|base| TerminalSnapshotView {
            base,
            presentation: self.presentation.clone(),
            canvases: [Rid::Invalid; 5],
            density: density.clamp(1.0, 16.0),
            runs: RunCache::new(),
        });
        view.set_size(self.size);
        view.set_position(self.position);
        view.set_clip_contents(true);
        view.set_mouse_filter(godot::classes::control::MouseFilter::IGNORE);
        view.upcast()
    }
    #[func]
    fn drawing_count(&self) -> i64 {
        self.presentation.drawings.len() as i64
    }
}

#[derive(GodotClass)]
#[class(base=Control)]
struct TerminalSnapshotView {
    base: Base<Control>,
    presentation: Rc<Presentation>,
    canvases: [Rid; 5],
    density: f32,
    runs: RunCache,
}
#[godot_api]
impl IControl for TerminalSnapshotView {
    fn init(base: Base<Control>) -> Self {
        Self {
            base,
            presentation: Rc::default(),
            canvases: [Rid::Invalid; 5],
            density: 1.0,
            runs: RunCache::new(),
        }
    }
    fn ready(&mut self) {
        let mut rs = RenderingServer::singleton();
        for (i, (mask, z)) in [
            (1 << 17, 0),
            (1 << 18, 2),
            (1 << 19, 1),
            (1 << 19, 3),
            (1 << 18, 4),
        ]
        .into_iter()
        .enumerate()
        {
            let canvas = rs.canvas_item_create();
            rs.canvas_item_set_parent(canvas, self.base().get_canvas_item());
            rs.canvas_item_set_visibility_layer(canvas, mask);
            rs.canvas_item_set_z_index(canvas, z);
            rs.canvas_item_set_transform(canvas, self.presentation.transforms[i]);
            if (i == 2 || i == 3)
                && let Some(material) = &self.presentation.image_material
            {
                rs.canvas_item_set_material(canvas, material.get_rid());
            }
            self.canvases[i] = canvas;
        }
        self.base_mut().queue_redraw();
    }
    fn draw(&mut self) {
        let background = self.presentation.background;
        if background.a > 0.0 {
            let rect = Rect2::new(Vector2::ZERO, self.base().get_size());
            self.base_mut().draw_rect(rect, background);
        }
        let mut rs = RenderingServer::singleton();
        for canvas in self.canvases {
            if canvas.is_valid() {
                rs.canvas_item_clear(canvas);
            }
        }
        for (layer, drawing) in &self.presentation.drawings {
            drawing.draw(self.canvases[*layer], self.density, &mut self.runs);
        }
        self.runs.end_frame();
    }
}
#[godot_api]
impl TerminalSnapshotView {
    #[func]
    fn presentation_copy(&self) -> Gd<Control> {
        let snapshot = Gd::from_init_fn(|base| TerminalRenderSnapshot {
            base,
            presentation: self.presentation.clone(),
            size: self.base().get_size(),
            position: self.base().get_position(),
        });
        snapshot.bind().create_view(self.density)
    }

    #[func]
    fn set_raster_scale(&mut self, density: f32) {
        if !density.is_finite() {
            return;
        }
        let density = density.clamp(1.0, 16.0);
        if (self.density - density).abs() < 0.001 {
            return;
        }
        self.density = density;
        self.base_mut().queue_redraw();
    }
}
impl Drop for TerminalSnapshotView {
    fn drop(&mut self) {
        let mut rs = RenderingServer::singleton();
        for canvas in self.canvases {
            if canvas.is_valid() {
                rs.free_rid(canvas);
            }
        }
    }
}
