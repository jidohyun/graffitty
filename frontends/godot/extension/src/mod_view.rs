//! Godot boundary for JavaScript mods: one engine per process, one Control per copy.
//!
//! The engine (`graffitty-mods`) runs the scripts and lays them out; this file
//! only paints its draw list with RenderingServer primitives and forwards
//! pointer events. Nothing here knows what a mod shows.
use godot::builtin::{Corner, Side};
use godot::classes::control::{CursorShape, MouseFilter};
use godot::classes::notify::ControlNotification;
use godot::classes::text_server::{LineBreakFlag, OverrunBehavior};
use godot::classes::{
    Control, FileAccess, Font, FontVariation, IControl, Image, ImageTexture, InputEvent, InputEventMouseButton, InputEventMouseMotion, InputEventPanGesture, InputEventScreenDrag,
    InputEventScreenTouch, RefCounted,
    RenderingServer, ResourceLoader, StyleBoxFlat, TextParagraph, Texture2D, ThemeDb, Time, TranslationServer,
};
use godot::global::{HorizontalAlignment, MouseButton};
use godot::prelude::*;
use graffitty_mods::engine::Button;
use graffitty_scene_core::scroll::{ElasticConfig, ElasticGesture, ScrollGesture, Scroller};
use graffitty_scene_core::fling::ScrollMotion;

use crate::elastic_gesture::{PAN_TO_PIXELS, PanPhases};
use graffitty_mods::{CopyId, Cursor, Draw, FontSpec, Frame, Mods, Options, PointerEvent, Request, TextAlign, TextMeasure};
use std::cell::RefCell;
use std::collections::HashMap;

thread_local! {
    static HOST: RefCell<Option<Mods>> = const { RefCell::new(None) };
}

fn with_host<R>(f: impl FnOnce(&mut Mods) -> R) -> Option<R> {
    HOST.with(|host| host.borrow_mut().as_mut().map(f))
}

fn color_of(c: graffitty_mods::Color) -> Color {
    Color::from_rgba(c.r, c.g, c.b, c.a)
}

/// The SVG source with the root element's width and height replaced by `px`.
/// Node artwork declares its own size; the badge needs it icon-sized.
fn size_inline_svg(source: &str, px: f32) -> String {
    let Some(start) = source.find("<svg") else { return source.to_owned() };
    let Some(end_rel) = source[start..].find('>') else { return source.to_owned() };
    let end = start + end_rel;
    let header = &source[start..end];
    // Drop existing width/height attributes (quoted values), keep everything else.
    let mut cleaned = String::with_capacity(header.len());
    let mut rest = header;
    loop {
        let next = ["width", "height"]
            .iter()
            .filter_map(|attr| rest.find(&format!(" {attr}")).map(|i| (i, *attr)))
            .min_by_key(|(i, _)| *i);
        let Some((index, attr)) = next else {
            cleaned.push_str(rest);
            break;
        };
        let after = &rest[index + 1 + attr.len()..];
        let trimmed = after.trim_start();
        let Some(value) = trimmed.strip_prefix('=') else {
            cleaned.push_str(&rest[..index + 1 + attr.len()]);
            rest = after;
            continue;
        };
        let value = value.trim_start();
        let Some(quote) = value.chars().next().filter(|c| *c == '"' || *c == '\'') else {
            cleaned.push_str(&rest[..index + 1 + attr.len()]);
            rest = after;
            continue;
        };
        let Some(close) = value[1..].find(quote) else {
            cleaned.push_str(rest);
            break;
        };
        cleaned.push_str(&rest[..index]);
        let consumed = rest.len() - value.len() + 1 + close + 1;
        rest = &rest[consumed..];
    }
    let px = px.round();
    format!("{}{} width=\"{px}\" height=\"{px}\">{}", &source[..start], cleaned.trim_end_matches('/').trim_end(), &source[end + 1..])
}

/// Top-left, top-right, bottom-right, bottom-left, each no more than half the box.
fn set_corners(style: &mut Gd<StyleBoxFlat>, radius: &[f32; 4], limit: f32) {
    style.set_corner_radius(Corner::TOP_LEFT, radius[0].min(limit).round() as i32);
    style.set_corner_radius(Corner::TOP_RIGHT, radius[1].min(limit).round() as i32);
    style.set_corner_radius(Corner::BOTTOM_RIGHT, radius[2].min(limit).round() as i32);
    style.set_corner_radius(Corner::BOTTOM_LEFT, radius[3].min(limit).round() as i32);
}

fn rect_of(r: graffitty_mods::Rect) -> Rect2 {
    Rect2::new(Vector2::new(r.x, r.y), Vector2::new(r.w, r.h))
}

/// A square box rounded by at least half its side is a circle.
///
/// StyleBoxFlat only takes whole-pixel radii and border widths, which leaves
/// a 7 px status ring with a 1.5 px stroke visibly lopsided; those are drawn
/// as real circles.
fn circle_of(r: Rect2, radius: &[f32; 4]) -> Option<(Vector2, f32)> {
    let half = r.size.x.min(r.size.y) / 2.0;
    let square = (r.size.x - r.size.y).abs() < 0.5 && half > 0.0;
    (square && radius.iter().all(|v| *v + 0.01 >= half)).then(|| (r.position + r.size / 2.0, half))
}

/// A closed ring of `radius` around `center`, as polyline points.
fn ring_points(center: Vector2, radius: f32) -> PackedVector2Array {
    let segments = ((radius * 4.0) as usize).clamp(24, 96);
    (0..=segments)
        .map(|i| {
            let angle = i as f32 / segments as f32 * std::f32::consts::TAU;
            center + Vector2::new(angle.cos(), angle.sin()) * radius
        })
        .collect()
}

/// The process-wide mod engine, driven from GDScript.
#[derive(GodotClass)]
#[class(base=RefCounted, init)]
struct ModHost {
    base: Base<RefCounted>,
}

#[godot_api]
impl ModHost {
    /// Creates the engine once. `state_dir` holds shared state and per-mod storage.
    #[func]
    fn setup(&self, state_dir: GString) -> GString {
        if HOST.with(|host| host.borrow().is_some()) {
            return GString::new();
        }
        let state_dir = state_dir.to_string();
        let options = Options {
            state_dir: if state_dir.is_empty() { None } else { Some(state_dir.into()) },
            log: Box::new(|level, message| match level {
                "error" => godot_error!("mods: {message}"),
                "warn" => godot_warn!("mods: {message}"),
                _ => godot_print!("mods: {message}"),
            }),
            translate: Box::new(|text| TranslationServer::singleton().translate(&StringName::from(text)).to_string()),
        };
        match Mods::new(options) {
            Ok(mods) => {
                HOST.with(|host| *host.borrow_mut() = Some(mods));
                GString::new()
            }
            Err(error) => GString::from(&error),
        }
    }

    #[func]
    fn is_ready(&self) -> bool {
        HOST.with(|host| host.borrow().is_some())
    }

    /// Publishes one live key as JSON text; mods that read it re-render.
    #[func]
    fn publish(&self, key: GString, json: GString) -> bool {
        let value = serde_json::from_str(&json.to_string()).unwrap_or(serde_json::Value::Null);
        with_host(|host| host.publish(&key.to_string(), value)).unwrap_or(false)
    }

    /// The theme colours, `{name: "#rrggbb"}`.
    #[func]
    fn set_theme(&self, json: GString) {
        let value = serde_json::from_str(&json.to_string()).unwrap_or(serde_json::Value::Null);
        with_host(|host| host.set_theme(value));
    }

    /// Re-renders every copy: a locale change.
    #[func]
    fn invalidate(&self) {
        with_host(|host| host.invalidate_all());
    }

    /// Actions and overlays mods asked for since the last call:
    /// `{copy, kind: "run"|"open"|"close"|"notify", name, args, id, spec}` with JSON strings.
    #[func]
    fn take_requests(&self) -> Array<VarDictionary> {
        let mut result = Array::new();
        for request in with_host(|host| host.take_requests()).unwrap_or_default() {
            let mut entry = VarDictionary::new();
            match request {
                Request::Run { copy, name, args } => {
                    entry.set("copy", copy as i64);
                    entry.set("kind", "run");
                    entry.set("name", name);
                    entry.set("args", args.to_string());
                }
                Request::OpenOverlay { copy, id, spec } => {
                    entry.set("copy", copy as i64);
                    entry.set("kind", "open");
                    entry.set("id", id);
                    entry.set("spec", spec.to_string());
                }
                Request::CloseOverlay { copy, id } => {
                    entry.set("copy", copy as i64);
                    entry.set("kind", "close");
                    entry.set("id", id);
                }
                Request::Notify { copy, spec } => {
                    entry.set("copy", copy as i64);
                    entry.set("kind", "notify");
                    entry.set("spec", spec.to_string());
                }
            }
            result.push(&entry);
        }
        result
    }

    /// `graffitty.d.ts`, for writing beside the user's mods.
    #[func]
    fn declarations(&self) -> GString {
        GString::from(graffitty_mods::DECLARATIONS)
    }
}

struct UiFonts {
    regular: Gd<Font>,
    bold: Gd<Font>,
    /// 800 and heavier: the embolden native controls use for a locked state.
    heavy: Gd<Font>,
}

impl UiFonts {
    fn load() -> Option<UiFonts> {
        let regular = ThemeDb::singleton().get_fallback_font()?;
        let emboldened = |strength: f32| {
            let mut font = FontVariation::new_gd();
            font.set_base_font(&regular);
            font.set_variation_embolden(strength);
            font.upcast::<Font>()
        };
        Some(UiFonts { bold: emboldened(0.6), heavy: emboldened(1.0), regular })
    }

    fn for_spec(&self, spec: &FontSpec) -> &Gd<Font> {
        if spec.weight >= 800 {
            &self.heavy
        } else if spec.weight >= 600 {
            &self.bold
        } else {
            &self.regular
        }
    }
}

struct Measurer<'a> {
    fonts: &'a UiFonts,
    paragraph: Gd<TextParagraph>,
    /// Layout runs in logical units; text is shaped at the size it is painted.
    zoom: f32,
}

impl TextMeasure for Measurer<'_> {
    fn measure(&mut self, text: &str, font: &FontSpec, max_width: Option<f32>) -> (f32, f32) {
        self.paragraph.clear();
        self.paragraph.set_width(max_width.map_or(-1.0, |width| width * self.zoom));
        self.paragraph.set_text_overrun_behavior(OverrunBehavior::NO_TRIMMING);
        // Painting shares this paragraph and leaves one-line settings behind
        // after a nowrap label; measuring must wrap freely, or a wrapped line is
        // laid out one line tall and the next line draws over it.
        self.paragraph.set_break_flags(LineBreakFlag::WORD_BOUND | LineBreakFlag::MANDATORY);
        self.paragraph.set_max_lines_visible(-1);
        self.paragraph.add_string(&GString::from(text), self.fonts.for_spec(font), (font.size * self.zoom).round() as i32);
        let size = self.paragraph.get_size();
        ((size.x / self.zoom).ceil(), (size.y / self.zoom).ceil())
    }
}

/// One copy of a mod on screen. Load it, then it paints and handles input.
#[derive(GodotClass)]
#[class(base=Control)]
struct ModView {
    base: Base<Control>,
    copy: Option<CopyId>,
    /// A mirror paints another view's copy (transition captures) and never unloads it.
    owns: bool,
    /// Wrap the mod's content and report it as the minimum size, instead of
    /// filling this control: a strip the workspace sizes to its mod.
    #[var]
    fit_content: bool,
    /// Magnifies the whole mod: it lays out in `size / zoom` logical units and
    /// paints, and takes input, `zoom` times larger.
    zoom: f32,
    roots: Vec<String>,
    textures: HashMap<String, Gd<Texture2D>>,
    fonts: Option<UiFonts>,
    paragraph: Gd<TextParagraph>,
    items: Vec<Rid>,
    animated: bool,
    error: String,
    /// The active finger, if any.
    touch: Option<Finger>,
    /// Momentum after a finger flicks a list, shared with terminal scrolling.
    momentum: ScrollMotion,
    momentum_at: Vector2,
    /// The flicked list is gliding: its rubber band hears momentum phases
    /// and the end when the glide stops.
    flinging: bool,
    /// Trackpad phases. `pan_band` mirrors only whether a pan gesture is
    /// under way, which Wayland's phase reading needs; the list's own band
    /// lives in the mod host.
    pan_phases: PanPhases,
    pan_band: ElasticGesture,
    pan_at: Vector2,
}

/// A rest point for `pan_band`, which never stretches.
const NO_SCROLLER: Scroller = Scroller { offset: 0.0, max: 0.0, bounds: 0.0 };

/// Seconds on the mod host's clock, which phase times must share.
fn host_seconds() -> f64 {
    Time::singleton().get_ticks_msec() as f64 / 1000.0
}

fn touch_phase(began: bool, ended: bool, momentum: bool) -> Option<ScrollGesture> {
    Some(ScrollGesture { began, ended, momentum, time: Some(host_seconds()), hold_end: false })
}

/// How long a still finger rests before it presses like a held mouse button.
const HOLD_MSEC: u64 = 450;

/// A finger on the view. It scrolls once it moves; held still for
/// `HOLD_MSEC` it becomes a pressed mouse button, so press-and-drag
/// gestures (reordering, resizing) work by touch. A held finger that lifts
/// where it rested is a long press: it right-clicks, opening the context menu.
#[derive(Clone, Copy)]
struct Finger {
    index: i32,
    start: Vector2,
    last: Vector2,
    at_msec: u64,
    dragged: bool,
    held: bool,
    /// It landed on a gliding list: it stops the glide, and is not a tap.
    braked: bool,
    /// Held, it then moved past the slop: a press-and-drag, not a long press.
    wandered: bool,
}

#[godot_api]
impl IControl for ModView {
    fn init(base: Base<Control>) -> Self {
        // A default, not a ready-time override: paint-only embedded mods must
        // retain IGNORE or they intercept clicks intended for chrome below.
        base.to_init_gd().set_mouse_filter(MouseFilter::PASS);
        Self { base, copy: None, owns: true, fit_content: false, zoom: 1.0, roots: Vec::new(), textures: HashMap::new(), fonts: None, paragraph: TextParagraph::new_gd(), items: Vec::new(), animated: false, error: String::new(), touch: None, momentum: ScrollMotion::default(), momentum_at: Vector2::ZERO, flinging: false, pan_phases: PanPhases::default(), pan_band: ElasticGesture::new(ElasticConfig::terminal()), pan_at: Vector2::ZERO }
    }

    fn ready(&mut self) {
        self.base_mut().set_process(true);
        self.base_mut().queue_redraw();
    }

    fn exit_tree(&mut self) {
        let mut rs = RenderingServer::singleton();
        for item in self.items.drain(..) {
            rs.free_rid(item);
        }
    }

    fn on_notification(&mut self, what: ControlNotification) {
        match what {
            ControlNotification::MOUSE_EXIT => {
                if let Some(copy) = self.copy {
                    with_host(|host| host.pointer(copy, PointerEvent::Leave));
                    self.base_mut().set_default_cursor_shape(CursorShape::ARROW);
                    self.base_mut().queue_redraw();
                }
            }
            ControlNotification::RESIZED => self.base_mut().queue_redraw(),
            ControlNotification::TRANSLATION_CHANGED | ControlNotification::THEME_CHANGED => {
                self.fonts = None;
                self.textures.clear();
                with_host(|host| host.invalidate_all());
                self.base_mut().queue_redraw();
            }
            ControlNotification::PREDELETE => {
                if let Some(copy) = self.copy.take() {
                    if self.owns {
                        with_host(|host| host.unload(copy));
                    }
                }
            }
            _ => {}
        }
    }

    fn process(&mut self, _delta: f64) {
        let _span = crate::profile::Span::new("ModView");
        let Some(copy) = self.copy else { return };
        let now = Time::singleton().get_ticks_msec() as f64;
        if let Some(finger) = self.touch.as_mut().filter(|f| !f.dragged && !f.held && now as u64 >= f.at_msec + HOLD_MSEC) {
            finger.held = true;
            let at = finger.start;
            with_host(|host| {
                host.pointer(copy, PointerEvent::Move { x: at.x, y: at.y });
                host.pointer(copy, PointerEvent::Down { x: at.x, y: at.y, button: Button::Left });
            });
            self.base_mut().queue_redraw();
        }
        if self.flinging {
            // A flicked list keeps gliding from where the finger landed, and
            // bounces if the glide runs into an end.
            let delta = self.momentum.advance(now as i64);
            let at = self.momentum_at;
            let outcome = with_host(|host| host.pointer(copy, PointerEvent::Wheel { x: at.x, y: at.y, dx: -delta.x, dy: -delta.y, gesture: touch_phase(false, false, true) }));
            // The glide ends where nothing takes it, or where a step that
            // moves stopped moving the list: pinned at an end after its bounce.
            let pinned = delta != graffitty_scene_core::glam::Vec2::ZERO && outcome.is_some_and(|o| !o.scrolled);
            if !outcome.is_some_and(|o| o.handled) || pinned {
                self.momentum.stop();
            }
            if self.momentum.velocity() == graffitty_scene_core::glam::Vec2::ZERO {
                self.end_fling(copy);
            }
            self.base_mut().queue_redraw();
        }
        // A trackpad lift without momentum, or a Wayland scroll that stopped,
        // ends the pan gesture.
        let seconds = host_seconds();
        if self.pan_phases.stopped(&self.pan_band) {
            self.pan_band.end(seconds, NO_SCROLLER);
            let at = self.pan_at;
            with_host(|host| host.pointer(copy, PointerEvent::Wheel { x: at.x, y: at.y, dx: 0.0, dy: 0.0, gesture: Some(ScrollGesture { ended: true, time: Some(seconds), ..Default::default() }) }));
        }
        self.pan_band.tick(seconds, NO_SCROLLER, true);
        let dirty = with_host(|host| {
            host.tick(now);
            host.needs_frame(copy)
        })
        .unwrap_or(false);
        if dirty || self.animated {
            self.base_mut().queue_redraw();
        }
    }

    fn get_tooltip(&self, at: Vector2) -> GString {
        let Some(copy) = self.copy else { return GString::new() };
        let at = at / self.zoom;
        with_host(|host| host.tooltip(copy, at.x, at.y)).flatten().map(|text| GString::from(&text)).unwrap_or_default()
    }

    fn gui_input(&mut self, event: Gd<InputEvent>) {
        let Some(copy) = self.copy else { return };
        // The mod sees logical positions and distances, whatever the zoom.
        let zoom = self.zoom;
        let event = if zoom == 1.0 { event } else {
            let logical = Transform2D::IDENTITY.scaled(Vector2::new(1.0 / zoom, 1.0 / zoom));
            event.xformed_by(logical)
        };
        // A finger scrolls the list it is on, either way; a short touch without
        // movement is a click, and a long one presses until it lifts.
        if let Ok(touch) = event.clone().try_cast::<InputEventScreenTouch>() {
            let p = touch.get_position();
            if touch.is_pressed() {
                let at_msec = Time::singleton().get_ticks_msec();
                // A touch that brakes a glide must not also click what is under
                // it. Holding still or dragging on from there works as usual.
                let braked = self.momentum.velocity() != graffitty_scene_core::glam::Vec2::ZERO;
                if self.flinging {
                    self.end_fling(copy);
                }
                self.momentum.begin(at_msec as i64);
                self.touch = Some(Finger { index: touch.get_index(), start: p, last: p, at_msec, dragged: false, held: false, braked, wandered: false });
                // A finger on a control belongs to the mod; elsewhere it passes
                // to the chrome below, such as a compact dock band's drag.
                if with_host(|host| host.interactive_at(copy, p.x, p.y)).unwrap_or(false) {
                    self.base_mut().accept_event();
                }
            } else if let Some(Finger { index, start, last, dragged, held, braked, wandered, .. }) = self.touch.take() {
                if index == touch.get_index() && dragged && !held && !touch.is_canceled() {
                    self.momentum.release(Time::singleton().get_ticks_msec() as i64);
                    self.momentum_at = start;
                    self.flinging = true;
                    if self.momentum.velocity() == graffitty_scene_core::glam::Vec2::ZERO {
                        // No flick: the lift releases the pull.
                        self.end_fling(copy);
                    }
                } else {
                    self.momentum.stop();
                    if dragged && !held {
                        self.momentum_at = start;
                        self.flinging = true;
                        self.end_fling(copy);
                    }
                }
                if index == touch.get_index() && held {
                    let canceled = touch.is_canceled();
                    with_host(|host| {
                        if canceled {
                            host.pointer(copy, PointerEvent::Cancel { x: last.x, y: last.y });
                        } else if !wandered {
                            // A long press lifted where it rested opens the context
                            // menu, as a right click does. The held press it armed
                            // for dragging ends without a click or drop.
                            host.pointer(copy, PointerEvent::Cancel { x: start.x, y: start.y });
                            host.pointer(copy, PointerEvent::Move { x: start.x, y: start.y });
                            host.pointer(copy, PointerEvent::Down { x: start.x, y: start.y, button: Button::Right });
                            host.pointer(copy, PointerEvent::Up { x: start.x, y: start.y, button: Button::Right });
                        } else {
                            host.pointer(copy, PointerEvent::Up { x: last.x, y: last.y, button: Button::Left });
                        }
                        host.pointer(copy, PointerEvent::Leave);
                    });
                    self.base_mut().accept_event();
                    self.base_mut().queue_redraw();
                } else if index == touch.get_index() && !dragged && !braked && !touch.is_canceled() {
                    with_host(|host| {
                        host.pointer(copy, PointerEvent::Move { x: start.x, y: start.y });
                        host.pointer(copy, PointerEvent::Down { x: start.x, y: start.y, button: Button::Left });
                        host.pointer(copy, PointerEvent::Up { x: start.x, y: start.y, button: Button::Left });
                        host.pointer(copy, PointerEvent::Leave);
                    });
                    self.base_mut().queue_redraw();
                }
            }
            return;
        }
        if let Ok(drag) = event.clone().try_cast::<InputEventScreenDrag>() {
            let Some(mut finger) = self.touch else { return };
            if finger.index != drag.get_index() {
                return;
            }
            let p = drag.get_position();
            finger.last = p;
            if finger.held {
                finger.wandered = finger.wandered || (p - finger.start).length() > 8.0;
                self.touch = Some(finger);
                with_host(|host| host.pointer(copy, PointerEvent::Move { x: p.x, y: p.y }));
                self.base_mut().accept_event();
                self.base_mut().queue_redraw();
                return;
            }
            let began = !finger.dragged && (p - finger.start).length() > 8.0;
            finger.dragged = finger.dragged || began;
            self.touch = Some(finger);
            if finger.dragged {
                // The list under where the finger landed scrolls, even once
                // the finger has slid past its edge, and stretches past an end.
                let (relative, at) = (drag.get_relative(), finger.start);
                self.momentum.track(graffitty_scene_core::glam::Vec2::new(relative.x, relative.y), Time::singleton().get_ticks_msec() as i64);
                let gesture = touch_phase(began, false, false);
                let outcome = with_host(|host| host.pointer(copy, PointerEvent::Wheel { x: at.x, y: at.y, dx: -relative.x, dy: -relative.y, gesture }));
                if outcome.is_some_and(|o| o.handled) {
                    self.base_mut().accept_event();
                }
                self.base_mut().queue_redraw();
            }
            return;
        }
        let pointer = if let Ok(motion) = event.clone().try_cast::<InputEventMouseMotion>() {
            let p = motion.get_position();
            Some(PointerEvent::Move { x: p.x, y: p.y })
        } else if let Ok(button) = event.clone().try_cast::<InputEventMouseButton>() {
            // A finger already produced its click above; the emulated mouse
            // press that follows must not click a second time.
            if button.get_device() == -1 {
                return;
            }
            let p = button.get_position();
            let pressed = button.is_pressed();
            // A touch recognizer cancels its left press when the finger turns
            // into a long press, pinch or scroll; that release is not a click.
            if button.is_canceled() && !pressed && button.get_button_index() == MouseButton::LEFT {
                with_host(|host| host.pointer(copy, PointerEvent::Cancel { x: p.x, y: p.y }));
                self.base_mut().queue_redraw();
                return;
            }
            match button.get_button_index() {
                MouseButton::LEFT => Some(if pressed { PointerEvent::Down { x: p.x, y: p.y, button: Button::Left } } else { PointerEvent::Up { x: p.x, y: p.y, button: Button::Left } }),
                MouseButton::RIGHT => Some(if pressed { PointerEvent::Down { x: p.x, y: p.y, button: Button::Right } } else { PointerEvent::Up { x: p.x, y: p.y, button: Button::Right } }),
                MouseButton::MIDDLE => Some(if pressed { PointerEvent::Down { x: p.x, y: p.y, button: Button::Middle } } else { PointerEvent::Up { x: p.x, y: p.y, button: Button::Middle } }),
                // Shift turns a vertical wheel sideways, as browsers do.
                MouseButton::WHEEL_UP | MouseButton::WHEEL_DOWN | MouseButton::WHEEL_LEFT | MouseButton::WHEEL_RIGHT if pressed => {
                    let step = 48.0 * button.get_factor().max(0.2);
                    let index = button.get_button_index();
                    let sign = if index == MouseButton::WHEEL_UP || index == MouseButton::WHEEL_LEFT { -step } else { step };
                    let sideways = index == MouseButton::WHEEL_LEFT || index == MouseButton::WHEEL_RIGHT || button.is_shift_pressed();
                    let (dx, dy) = if sideways { (sign, 0.0) } else { (0.0, sign) };
                    Some(PointerEvent::Wheel { x: p.x, y: p.y, dx, dy, gesture: None })
                }
                _ => None,
            }
        } else if let Ok(pan) = event.clone().try_cast::<InputEventPanGesture>() {
            // Trackpads scroll by pan gestures, not wheel buttons. Godot's macOS
            // backend scales their native pixels by 0.03; undo it so a swipe
            // moves the list by the distance the fingers travelled.
            //
            // Phased pans (trackpads, and finger scrolls a touch recognizer
            // turned into pans) pull the list past its ends.
            let p = pan.get_position();
            let d = pan.get_delta() * PAN_TO_PIXELS as f32 / zoom;
            let gesture = self.pan_phases.read(&pan, &self.pan_band);
            if let Some(gesture) = gesture {
                self.pan_band.began(gesture, true);
                self.pan_band.ended(gesture, host_seconds(), NO_SCROLLER);
            }
            self.pan_at = p;
            Some(PointerEvent::Wheel { x: p.x, y: p.y, dx: d.x, dy: d.y, gesture })
        } else {
            None
        };
        let Some(pointer) = pointer else { return };
        let Some(outcome) = with_host(|host| host.pointer(copy, pointer)) else { return };
        let shape = match outcome.cursor {
            Cursor::Pointer => CursorShape::POINTING_HAND,
            Cursor::Arrow => CursorShape::ARROW,
            Cursor::ResizeHorizontal => CursorShape::HSIZE,
        };
        self.base_mut().set_default_cursor_shape(shape);
        if outcome.handled {
            self.base_mut().accept_event();
        }
        if with_host(|host| host.needs_frame(copy)).unwrap_or(false) {
            self.base_mut().queue_redraw();
        }
    }

    fn draw(&mut self) {
        let _span = crate::profile::Span::new("ModView.draw");
        let Some(copy) = self.copy else { return };
        if self.fonts.is_none() {
            self.fonts = UiFonts::load();
        }
        let Some(fonts) = self.fonts.take() else { return };
        let frame = self.compute_frame(copy, &fonts);
        match frame {
            Some(Ok(frame)) => {
                self.error.clear();
                self.animated = frame.animated;
                self.paint(&frame, &fonts);
            }
            Some(Err(error)) => self.error = error,
            None => self.error = "the mod host is not set up".into(),
        }
        self.fonts = Some(fonts);
    }
}

impl ModView {
    /// The glide (or a drag without one) is over: the list's band releases.
    fn end_fling(&mut self, copy: CopyId) {
        if !std::mem::take(&mut self.flinging) {
            return;
        }
        let at = self.momentum_at;
        with_host(|host| host.pointer(copy, PointerEvent::Wheel { x: at.x, y: at.y, dx: 0.0, dy: 0.0, gesture: touch_phase(false, true, true) }));
        self.base_mut().queue_redraw();
    }
}

#[godot_api]
impl ModView {
    /// Loads a registered filesystem entry with stable mod identity.
    #[func]
    fn load_entry(&mut self, name: GString, entry: GString, props: GString) -> GString {
        let props = serde_json::from_str(&props.to_string()).unwrap_or(serde_json::Value::Null);
        let entry = std::path::PathBuf::from(entry.to_string());
        self.finish_load(with_host(|host| host.load_entry(&name.to_string(), &entry, props)))
    }

    /// Loads a mod from its source text (one bundled inside the application).
    #[func]
    fn load_source(&mut self, name: GString, source: GString, props: GString) -> GString {
        let props = serde_json::from_str(&props.to_string()).unwrap_or(serde_json::Value::Null);
        self.finish_load(with_host(|host| host.load_source(&name.to_string(), &source.to_string(), props)))
    }

    /// Replaces `props()` for this copy and re-renders: dock state the window owns.
    #[func]
    fn set_props(&mut self, props: GString) {
        let Some(copy) = self.copy else { return };
        let props = serde_json::from_str(&props.to_string()).unwrap_or(serde_json::Value::Null);
        with_host(|host| host.set_props(copy, props));
        self.base_mut().queue_redraw();
    }

    /// Sets the magnification; 1 is the mod's own size.
    #[func]
    fn set_zoom(&mut self, zoom: f32) {
        let zoom = if zoom.is_finite() { zoom.clamp(0.5, 3.0) } else { 1.0 };
        if zoom == self.zoom { return; }
        self.zoom = zoom;
        self.textures.clear();
        self.base_mut().queue_redraw();
    }

    #[func]
    fn get_zoom(&self) -> f32 {
        self.zoom
    }

    /// Moves the pointer to a point, as a hover would. Tests drive hover styles through this.
    #[func]
    fn hover_at(&mut self, at: Vector2) {
        let Some(copy) = self.copy else { return };
        let at = at / self.zoom;
        with_host(|host| host.pointer(copy, PointerEvent::Move { x: at.x, y: at.y }));
        self.base_mut().queue_redraw();
    }

    /// Scrolls the scrollable element under the point by `dy` logical pixels.
    #[func]
    fn scroll_at(&mut self, at: Vector2, dy: f32) -> bool {
        let Some(copy) = self.copy else { return false };
        let at = at / self.zoom;
        let handled = with_host(|host| host.pointer(copy, PointerEvent::Wheel { x: at.x, y: at.y, dx: 0.0, dy, gesture: None })).is_some_and(|o| o.handled);
        self.base_mut().queue_redraw();
        handled
    }

    /// The scroll offset of the element with `id(key)`, or -1 when it does not scroll.
    #[func]
    fn scroll_offset(&self, key: GString) -> f32 {
        let key = key.to_string();
        self.copy
            .and_then(|copy| with_host(|host| host.hits(copy).into_iter().find(|h| h.key == key).and_then(|h| h.scroll.map(|s| s.offset))))
            .flatten()
            .unwrap_or(-1.0)
    }

    /// Where `svg("icons/x.svg")` looks, in order. `res://` and absolute paths skip this.
    #[func]
    fn set_asset_roots(&mut self, roots: PackedStringArray) {
        self.roots = roots.as_slice().iter().map(GString::to_string).collect();
        self.textures.clear();
    }

    #[func]
    fn copy_id(&self) -> i64 {
        self.copy.map_or(-1, |c| c as i64)
    }

    /// The last script or layout error, or "".
    #[func]
    fn last_error(&self) -> GString {
        if !self.error.is_empty() {
            return GString::from(&self.error);
        }
        self.copy.and_then(|copy| with_host(|host| host.error(copy)).flatten()).map(|text| GString::from(&text)).unwrap_or_default()
    }

    /// Bounds of the element with `id(key)` in the last frame; empty when absent.
    #[func]
    fn hit_rect(&self, key: GString) -> Rect2 {
        let key = key.to_string();
        self.copy
            .and_then(|copy| with_host(|host| host.hits(copy).into_iter().find(|h| h.key == key).map(|h| rect_of(h.rect))))
            .flatten()
            .map(|rect| Rect2::new(rect.position * self.zoom, rect.size * self.zoom))
            .unwrap_or_default()
    }

    /// Every element key in the last frame, in paint order.
    #[func]
    fn hit_keys(&self) -> PackedStringArray {
        self.copy.map(|copy| with_host(|host| host.hits(copy).iter().map(|h| GString::from(&h.key)).collect()).unwrap_or_default()).unwrap_or_default()
    }

    /// Every text run in the last frame, in paint order.
    #[func]
    fn texts(&self) -> PackedStringArray {
        self.copy.map(|copy| with_host(|host| host.texts(copy).iter().map(GString::from).collect()).unwrap_or_default()).unwrap_or_default()
    }

    /// Presses and releases the left button at the element's centre, as a
    /// pointer would. Tests drive mods through this.
    #[func]
    fn click(&mut self, key: GString) -> bool {
        let rect = self.hit_rect(key);
        if rect.size.x <= 0.0 || rect.size.y <= 0.0 {
            return false;
        }
        let Some(copy) = self.copy else { return false };
        let center = rect.position + rect.size / 2.0;
        with_host(|host| {
            host.pointer(copy, PointerEvent::Move { x: center.x, y: center.y });
            host.pointer(copy, PointerEvent::Down { x: center.x, y: center.y, button: Button::Left });
            host.pointer(copy, PointerEvent::Up { x: center.x, y: center.y, button: Button::Left });
        });
        self.base_mut().queue_redraw();
        true
    }

    /// Renders now, without waiting for a draw: tests read `texts()` after this.
    #[func]
    fn render_now(&mut self) -> GString {
        if self.fonts.is_none() {
            self.fonts = UiFonts::load();
        }
        let Some(copy) = self.copy else { return GString::from("no mod loaded") };
        let Some(fonts) = self.fonts.take() else { return GString::from("no UI font") };
        let result = self.compute_frame(copy, &fonts);
        self.fonts = Some(fonts);
        match result {
            Some(Ok(_)) => GString::new(),
            Some(Err(error)) => GString::from(&error),
            None => GString::from("the mod host is not set up"),
        }
    }

    /// The current element tree as text, for diagnostics.
    #[func]
    fn describe(&self) -> GString {
        self.copy.and_then(|copy| with_host(|host| host.describe(copy)).flatten()).map(|text| GString::from(&text)).unwrap_or_default()
    }

    /// Paints the same copy as `source`, without owning it: transition
    /// captures duplicate the scene tree, and a duplicate has no script of its own.
    #[func]
    fn mirror(&mut self, source: Gd<ModView>) {
        if let Some(previous) = self.copy.take() {
            if self.owns {
                with_host(|host| host.unload(previous));
            }
        }
        let source = source.bind();
        self.copy = source.copy;
        self.owns = false;
        self.fit_content = source.fit_content;
        self.zoom = source.zoom;
        self.roots = source.roots.clone();
        self.base_mut().set_mouse_filter(MouseFilter::IGNORE);
        self.base_mut().queue_redraw();
    }

    /// Lays the copy out in this control's box, or around its content when
    /// `fit_content` is set, in which case the content size becomes the minimum size.
    fn compute_frame(&mut self, copy: CopyId, fonts: &UiFonts) -> Option<Result<Frame, String>> {
        let zoom = self.zoom;
        let size = self.base().get_size() / zoom;
        let mut measurer = Measurer { fonts, paragraph: self.paragraph.clone(), zoom };
        let mut result = if self.fit_content {
            with_host(|host| host.frame_fit(copy, &mut measurer))
        } else {
            with_host(|host| host.frame(copy, (size.x, size.y), &mut measurer))
        };
        if let Some(Ok(frame)) = &mut result {
            frame.scale(zoom);
        }
        if self.fit_content {
            if let Some(Ok(frame)) = &result {
                let wanted = Vector2::new(frame.size.0, frame.size.1);
                if self.base().get_custom_minimum_size() != wanted {
                    self.base_mut().set_custom_minimum_size(wanted);
                }
            }
        }
        result
    }

    fn finish_load(&mut self, result: Option<Result<CopyId, String>>) -> GString {
        if let Some(previous) = self.copy.take() {
            if self.owns {
                with_host(|host| host.unload(previous));
            }
        }
        self.owns = true;
        match result {
            Some(Ok(copy)) => {
                self.copy = Some(copy);
                self.error.clear();
                self.base_mut().queue_redraw();
                GString::new()
            }
            Some(Err(error)) => {
                self.error = error.clone();
                GString::from(&error)
            }
            None => GString::from("the mod host is not set up"),
        }
    }

    fn resolve(&self, path: &str) -> String {
        if path.starts_with("res://") || path.starts_with("user://") || path.starts_with('/') {
            return path.to_owned();
        }
        for root in &self.roots {
            let candidate = format!("{}/{}", root.trim_end_matches('/'), path);
            if FileAccess::file_exists(&GString::from(&candidate)) || ResourceLoader::singleton().exists(&GString::from(&candidate)) {
                return candidate;
            }
        }
        path.to_owned()
    }

    fn texture(&mut self, path: &str, px: f32, tinted: bool, grayscale: bool) -> Option<Gd<Texture2D>> {
        let source = self.source_texture(path, px, tinted)?;
        if !grayscale { return Some(source); }
        let key = format!("grayscale:{}", source.instance_id());
        if let Some(texture) = self.textures.get(&key) { return Some(texture.clone()); }
        // Keep the live artwork intact: offline copies share only a cached
        // desaturated texture, including PNGs and multicolour inline SVGs.
        let mut image = source.get_image()?.duplicate()?.try_cast::<Image>().ok()?;
        if image.is_compressed() && image.decompress() != godot::global::Error::OK { return None; }
        image.adjust_bcs(1.0, 1.0, 0.0);
        let texture: Gd<Texture2D> = ImageTexture::create_from_image(&image)?.upcast();
        self.textures.insert(key, texture.clone());
        Some(texture)
    }

    fn source_texture(&mut self, path: &str, px: f32, tinted: bool) -> Option<Gd<Texture2D>> {
        let key = format!("{path}@{}", px.round());
        if let Some(texture) = self.textures.get(&key) {
            return Some(texture.clone());
        }
        let mut texture: Option<Gd<Texture2D>> = None;
        // Inline artwork: `svg("<svg …>…</svg>")`, as a graph node's manifest
        // icon arrives. Its own width/height are replaced so it draws icon-sized
        // and crisp at HiDPI, as NodeIcon.gd does for native badges.
        if path.trim_start().starts_with("<svg") {
            let sized = size_inline_svg(path, (px * 2.0).max(1.0));
            let mut image = Image::new_gd();
            if image.load_svg_from_string(&GString::from(&sized)) == godot::global::Error::OK {
                texture = ImageTexture::create_from_image(&image).map(|t| t.upcast());
            }
            if let Some(texture) = &texture {
                self.textures.insert(key, texture.clone());
            } else {
                godot_warn!("mods: cannot rasterize inline svg");
            }
            return texture;
        }
        let resolved = self.resolve(path);
        let resolved_g = GString::from(&resolved);
        if resolved.ends_with(".svg") {
            // Rasterize at twice the drawn size so HiDPI stays crisp. Lucide
            // sources are 24 units; other sizes still scale into the rect.
            let source = if FileAccess::file_exists(&resolved_g) { FileAccess::get_file_as_string(&resolved_g).to_string() } else { String::new() };
            if !source.is_empty() {
                // Tinting multiplies the rasterized pixels, so the artwork has to
                // be white: `currentColor` (which the rasterizer paints black)
                // becomes white here, as a CSS `color: white` would make it.
                let source = source.replace("currentColor", "#ffffff");
                let mut image = Image::new_gd();
                if image.load_svg_from_string_ex(&GString::from(&source)).scale((px * 2.0 / 24.0).max(0.1)).done() == godot::global::Error::OK {
                    texture = ImageTexture::create_from_image(&image).map(|t| t.upcast());
                }
            }
        } else if FileAccess::file_exists(&resolved_g) && !resolved.starts_with("res://") {
            let bytes = FileAccess::get_file_as_bytes(&resolved_g);
            let mut image = Image::new_gd();
            if image.load_png_from_buffer(&bytes) == godot::global::Error::OK {
                texture = ImageTexture::create_from_image(&image).map(|t| t.upcast());
            }
        }
        if texture.is_none() && ResourceLoader::singleton().exists(&resolved_g) {
            texture = ResourceLoader::singleton().load(&resolved_g).and_then(|r| r.try_cast::<Texture2D>().ok());
        }
        if texture.is_none() {
            godot_warn!("mods: cannot load {} ({})", path, if tinted { "svg" } else { "image" });
        }
        if let Some(texture) = &texture {
            self.textures.insert(key, texture.clone());
        }
        texture
    }

    fn paint(&mut self, frame: &Frame, fonts: &UiFonts) {
        let mut rs = RenderingServer::singleton();
        for item in self.items.drain(..) {
            rs.free_rid(item);
        }
        let root = self.base().get_canvas_item();
        // Canvas items draw their own commands before their children. Start a new
        // item when the clip changes.
        //
        // Put clipped content under its clip. Put later content, such as a
        // scrollbar, in a sibling created afterwards so it paints on top.
        let mut stack: Vec<Rid> = vec![root];
        // Assign each canvas child a distinct index in paint order.
        // Godot's sort can swap children with equal indices, which could put
        // a popup behind the rows it should cover.
        let mut order = 0;
        let mut current = root;
        let now = Time::singleton().get_ticks_msec() as f64;
        let mut fill = StyleBoxFlat::new_gd();
        fill.set_anti_aliased(true);
        fill.set_corner_detail(8);
        let mut stroke = StyleBoxFlat::new_gd();
        stroke.set_anti_aliased(true);
        stroke.set_corner_detail(8);
        stroke.set_draw_center(false);
        for draw in &frame.draws {
            match draw {
                Draw::Rect { rect, color, radius } => {
                    let r = rect_of(*rect);
                    if radius.iter().all(|v| *v <= 0.0) {
                        rs.canvas_item_add_rect(current, r, color_of(*color));
                    } else if let Some((center, half)) = circle_of(r, radius) {
                        rs.canvas_item_add_circle_ex(current, center, half, color_of(*color)).antialiased(true).done();
                    } else {
                        fill.set_bg_color(color_of(*color));
                        let limit = (r.size.x.min(r.size.y) / 2.0).max(0.0);
                        set_corners(&mut fill, radius, limit);
                        fill.set_border_width_all(0);
                        fill.draw(current, r);
                    }
                }
                Draw::Border { rect, width, color, radius } => {
                    let r = rect_of(*rect);
                    // Layout rounds each edge to whole pixels, so one 1.5 px
                    // border arrives as 2 px on one side and 1 px on the
                    // other.
                    //
                    // Sides within a pixel of each other are one stroke; their
                    // mean restores the width.
                    let mean = width.iter().sum::<f32>() / 4.0;
                    let uniform = mean > 0.0 && width.iter().all(|w| (*w - mean).abs() <= 0.5);
                    if let Some((center, half)) = circle_of(r, radius).filter(|_| uniform) {
                        // Stroke centred on the ring, inside the box, at its exact width.
                        let stroke_width = mean.min(half);
                        let points = ring_points(center, half - stroke_width / 2.0);
                        let colors = PackedColorArray::from(&[color_of(*color)][..]);
                        rs.canvas_item_add_polyline_ex(current, &points, &colors).width(stroke_width).antialiased(true).done();
                        continue;
                    }
                    stroke.set_border_color(color_of(*color));
                    stroke.set_border_width(Side::TOP, width[0].round() as i32);
                    stroke.set_border_width(Side::RIGHT, width[1].round() as i32);
                    stroke.set_border_width(Side::BOTTOM, width[2].round() as i32);
                    stroke.set_border_width(Side::LEFT, width[3].round() as i32);
                    let limit = (r.size.x.min(r.size.y) / 2.0).max(0.0);
                    set_corners(&mut stroke, radius, limit);
                    stroke.draw(current, r);
                }
                Draw::Text { rect, text, font, color, truncate, nowrap, align, frames } => {
                    let shown: &str = match frames {
                        Some((list, step)) if !list.is_empty() => {
                            let index = ((now / f64::from(*step)) as usize) % list.len();
                            &list[index]
                        }
                        _ => text,
                    };
                    self.paragraph.clear();
                    self.paragraph.set_width(rect.w.max(0.0));
                    self.paragraph.set_text_overrun_behavior(if *truncate { OverrunBehavior::TRIM_ELLIPSIS } else { OverrunBehavior::NO_TRIMMING });
                    // Layout measured a single line for nowrap text; painting must not
                    // wrap it into several, or the extra lines spill over the neighbours.
                    self.paragraph.set_break_flags(if *nowrap { LineBreakFlag::NONE } else { LineBreakFlag::WORD_BOUND | LineBreakFlag::MANDATORY });
                    self.paragraph.set_max_lines_visible(if *nowrap { 1 } else { -1 });
                    self.paragraph.set_alignment(match align {
                        TextAlign::Left => HorizontalAlignment::LEFT,
                        TextAlign::Center => HorizontalAlignment::CENTER,
                        TextAlign::Right => HorizontalAlignment::RIGHT,
                    });
                    self.paragraph.add_string(&GString::from(shown), fonts.for_spec(font), font.size.round() as i32);
                    self.paragraph.draw_ex(current, Vector2::new(rect.x, rect.y)).color(color_of(*color)).done();
                }
                Draw::Svg { rect, path, color, spin_ms, grayscale } => {
                    let r = rect_of(*rect);
                    let Some(texture) = self.texture(path, rect.w.max(rect.h), true, *grayscale) else { continue };
                    if let Some(period) = spin_ms {
                        let angle = ((now % f64::from(*period)) / f64::from(*period)) as f32 * std::f32::consts::TAU;
                        let center = r.position + r.size / 2.0;
                        let (sin, cos) = angle.sin_cos();
                        let rotated_center = Vector2::new(cos * center.x - sin * center.y, sin * center.x + cos * center.y);
                        rs.canvas_item_add_set_transform(current, Transform2D::from_cols(Vector2::new(cos, sin), Vector2::new(-sin, cos), center - rotated_center));
                    }
                    rs.canvas_item_add_texture_rect_ex(current, r, texture.get_rid()).modulate(color_of(*color)).done();
                    if spin_ms.is_some() {
                        rs.canvas_item_add_set_transform(current, Transform2D::IDENTITY);
                    }
                }
                Draw::Image { rect, path, opacity, grayscale } => {
                    let r = rect_of(*rect);
                    let Some(texture) = self.texture(path, rect.w.max(rect.h), false, *grayscale) else { continue };
                    rs.canvas_item_add_texture_rect_ex(current, r, texture.get_rid()).modulate(Color::from_rgba(1.0, 1.0, 1.0, *opacity)).done();
                }
                Draw::Clip { rect } => {
                    // Clip a canvas item's children to the item's drawn rectangle.
                    // Give the clip item one invisible draw command for the clip bounds,
                    // then put the content in a child item.
                    let parent = *stack.last().unwrap_or(&root);
                    let clip = rs.canvas_item_create();
                    rs.canvas_item_set_parent(clip, parent);
                    rs.canvas_item_set_draw_index(clip, order);
                    order += 1;
                    rs.canvas_item_set_clip(clip, true);
                    rs.canvas_item_add_rect(clip, rect_of(*rect), Color::from_rgba(0.0, 0.0, 0.0, 0.0));
                    let content = rs.canvas_item_create();
                    rs.canvas_item_set_parent(content, clip);
                    rs.canvas_item_set_draw_index(content, order);
                    order += 1;
                    self.items.push(clip);
                    self.items.push(content);
                    stack.push(clip);
                    current = content;
                }
                Draw::Unclip => {
                    stack.pop();
                    // Whatever follows paints on top of the clipped content, so it
                    // needs a later sibling: inside the enclosing clip's content item
                    // when there is one, else under the root.
                    let parent = match stack.last() {
                        Some(clip) => {
                            let content = rs.canvas_item_create();
                            rs.canvas_item_set_parent(content, *clip);
                            rs.canvas_item_set_draw_index(content, order);
                            order += 1;
                            self.items.push(content);
                            content
                        }
                        None => {
                            let item = rs.canvas_item_create();
                            rs.canvas_item_set_parent(item, root);
                            rs.canvas_item_set_draw_index(item, order);
                            order += 1;
                            self.items.push(item);
                            item
                        }
                    };
                    current = parent;
                }
                Draw::Scrollbar { track: _, thumb, color } => {
                    fill.set_bg_color(color_of(*color));
                    fill.set_corner_radius_all(2);
                    fill.set_border_width_all(0);
                    fill.draw(current, rect_of(*thumb));
                }
            }
        }
    }
}
