//! The QuickJS side: loading mods, rendering, dispatching input, timers.
//!
//! Follows herdr-app `src/mods.rs` and gpui-kit's quickjs engine (both
//! Apache-2.0). One runtime hosts every copy; module code runs once per source
//! and is shared, each copy has its own instance, reads, storage and timers.
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use rquickjs::function::{Func, This};
use rquickjs::loader::{BuiltinLoader, BuiltinResolver, ImportAttributes, Resolver, ScriptLoader};
use rquickjs::{Array, CatchResultExt, Context, Ctx, Exception, Function, Module, Object, Persistent, Runtime, Value};
use serde_json::Value as Json;

use graffitty_scene_core::scroll::{ElasticConfig, ElasticGesture, ScrollGesture, Scroller};

use crate::host::{LiveReads, Request, SharedStore, Snapshot, Storage};
use crate::layout::{self, Frame, Hit, Interaction, SCROLLBAR_GRAB, TextMeasure};
use crate::spec::{CallbackId, Component, SpecArena, SpecId, SpecOp};
use crate::style;
use crate::value::{Bridged, Color};

pub type CopyId = u64;

const PRELUDE: &str = include_str!("../js/prelude.js");
const UI: &str = include_str!("../js/ui.js");
const GRAFFITTY: &str = include_str!("../js/graffitty.js");

/// Entry names are absolute OS paths. RelativePath's filesystem resolver treats
/// those as relative paths, so resolve sibling modules with the platform's Path.
struct ModResolver;
impl Resolver for ModResolver {
    fn resolve<'js>(&mut self, _ctx: &Ctx<'js>, base: &str, name: &str, _attributes: Option<ImportAttributes<'js>>) -> rquickjs::Result<String> {
        if !name.starts_with("./") && !name.starts_with("../") {
            return Err(rquickjs::Error::new_resolving(base, name));
        }
        let path = Path::new(base).parent().unwrap_or(Path::new(".")).join(name);
        let path = path.canonicalize().map_err(|_| rquickjs::Error::new_resolving(base, name))?;
        Ok(path.to_string_lossy().into_owned())
    }
}

/// Element methods that are not styles. Interned so the arena stores `&'static str`.
const BEHAVIORS: &[&str] = &[
    "id",
    "tooltip",
    "mode",
    "spin",
    "frames",
    "loop",
    "transition",
    "spring",
    "cursor",
    "on_click",
    "on_mouse_down",
    "on_mouse_up",
    "on_mouse_move",
    "on_hover",
    "on_size_change",
    "on_scroll_wheel",
    "on_key_down",
];

pub struct Options {
    /// Where `shared.json` and each copy's `localStorage` live. `None`: memory only.
    pub state_dir: Option<PathBuf>,
    /// `(level, message)` for `console.*` and script errors.
    pub log: Box<dyn Fn(&str, &str)>,
    /// `tr(text)` for mods: the frontend's translation of a catalog string.
    pub translate: Box<dyn Fn(&str) -> String>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PointerEvent {
    Move { x: f32, y: f32 },
    Down { x: f32, y: f32, button: Button },
    Up { x: f32, y: f32, button: Button },
    /// `dx` scrolls sideways (a trackpad, Shift+wheel, or a finger); only
    /// `on_scroll_wheel` handlers see it, as `delta_x`.
    ///
    /// Scrolling hovers nothing: rows pass under a resting pointer or a
    /// finger, and a moving highlight would read as the selection changing.
    /// The next `Move` hovers.
    ///
    /// `gesture` carries the phases of a trackpad or finger scroll: those pull
    /// a list past either end and spring back, like a terminal. A mouse wheel
    /// has none and only scrolls. A gesture's later phases stay with the list
    /// it began on; its end may carry no movement.
    Wheel { x: f32, y: f32, dx: f32, dy: f32, gesture: Option<ScrollGesture> },
    Leave,
    /// The platform took the press back (a touch became a long press, pinch or
    /// scroll): a left release that ends drags and mouse-up handlers but
    /// never clicks.
    Cancel { x: f32, y: f32 },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Button {
    Left,
    Right,
    Middle,
}

impl Button {
    fn name(self) -> &'static str {
        match self {
            Button::Left => "left",
            Button::Right => "right",
            Button::Middle => "middle",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cursor {
    Arrow,
    Pointer,
    ResizeHorizontal,
}

/// What a pointer event did: the cursor to show, and whether an element took
/// it (so the frontend stops it reaching whatever is behind the mod).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PointerOutcome {
    pub cursor: Cursor,
    pub handled: bool,
    /// A wheel moved or pulled a list. A glide whose momentum stops moving
    /// anything (pinned at an end after its bounce) has nothing left to do.
    pub scrolled: bool,
}

struct Recording {
    arena: SpecArena,
    callbacks: Vec<Persistent<Function<'static>>>,
}

struct Spec {
    arena: SpecArena,
    root: SpecId,
    callbacks: Vec<Persistent<Function<'static>>>,
}

struct Timer {
    /// What `timer.every` returned, for `timer.cancel`.
    id: u32,
    copy: CopyId,
    every: f64,
    due: f64,
    body: Persistent<Function<'static>>,
}

struct Copy {
    name: String,
    props: Json,
    instance: Option<Persistent<Object<'static>>>,
    spec: Option<Spec>,
    /// `render()` has to run again: a read key changed, `cx.notify()`, shared state.
    dirty: bool,
    /// Geometry has to be recomputed: hover, scroll, size, or a new spec.
    layout_dirty: bool,
    error: Option<String>,
    reads: LiveReads,
    interaction: Interaction,
    frame: Option<Frame>,
    size: (f32, f32),
    /// Wraps its content instead of filling `size` (a strip over a pane).
    fit: bool,
    storage: Storage,
    pressed: Option<String>,
    press_chain: Vec<String>,
    thumb_drag: Option<ThumbDrag>,
    /// The last wheel event reached a list.
    wheel_taken: bool,
    /// The last wheel event moved or pulled a list.
    wheel_scrolled: bool,
}

/// A scroll thumb held by the pointer: the list, where the press began, and
/// how many content pixels one pointer pixel moves.
#[derive(Clone)]
struct ThumbDrag {
    key: String,
    /// The pointer along the bar's axis when the drag began.
    at: f32,
    horizontal: bool,
    offset: f32,
    scale: f32,
    max: f32,
}

struct State {
    copies: HashMap<CopyId, Copy>,
    next_copy: CopyId,
    next_timer: u32,
    /// The copy whose script is running; reads and `props()` belong to it.
    current: Option<CopyId>,
    recording: Option<Recording>,
    snapshot: Snapshot,
    shared: SharedStore,
    requests: Vec<Request>,
    theme: Json,
    palette: HashMap<String, Color>,
    timers: Vec<Timer>,
    stop: bool,
    now: f64,
    log: Box<dyn Fn(&str, &str)>,
    translate: Box<dyn Fn(&str) -> String>,
    state_dir: Option<PathBuf>,
    classes: HashMap<PathBuf, Persistent<Function<'static>>>,
}

impl State {
    fn log(&self, level: &str, message: &str) {
        (self.log)(level, message);
    }
}

/// The mod host: owns the runtime and every loaded copy.
pub struct Mods {
    rt: Runtime,
    ctx: Context,
    state: Rc<RefCell<State>>,
}

type Shared = Rc<RefCell<State>>;

fn throw<T>(ctx: &Ctx<'_>, message: &str) -> rquickjs::Result<T> {
    Err(Exception::throw_message(ctx, message))
}

fn record<T>(state: &Shared, ctx: &Ctx<'_>, f: impl FnOnce(&mut Recording) -> Result<T, String>) -> rquickjs::Result<T> {
    let mut s = state.borrow_mut();
    let Some(recording) = s.recording.as_mut() else {
        return throw(ctx, "elements can only be described inside render()");
    };
    match f(recording) {
        Ok(value) => Ok(value),
        Err(message) => throw(ctx, &message),
    }
}

fn bridge(value: &Value<'_>) -> Bridged {
    if value.is_null() || value.is_undefined() {
        Bridged::Null
    } else if let Some(b) = value.as_bool() {
        Bridged::Bool(b)
    } else if let Some(n) = value.as_number() {
        Bridged::Number(n)
    } else if let Some(s) = value.as_string() {
        Bridged::Str(s.to_string().unwrap_or_default())
    } else if let Some(array) = value.as_array() {
        Bridged::List(array.iter::<Value>().filter_map(Result::ok).map(|v| bridge(&v)).collect())
    } else {
        Bridged::Null
    }
}

fn mouse_event_value<'js>(ctx: &Ctx<'js>, x: f32, y: f32, button: Option<Button>) -> rquickjs::Result<Value<'js>> {
    let object = Object::new(ctx.clone())?;
    object.set("x", x)?;
    object.set("y", y)?;
    if let Some(button) = button {
        object.set("button", button.name())?;
    }
    object.set("click_count", 1)?;
    object.set("modifiers", Object::new(ctx.clone())?)?;
    Ok(object.into_value())
}

fn describe(ctx: &Ctx<'_>, error: rquickjs::Error) -> String {
    match rquickjs::CaughtError::from_error(ctx, error) {
        rquickjs::CaughtError::Exception(exception) => {
            let message = exception.message().unwrap_or_else(|| "error".into());
            match exception.stack() {
                Some(stack) if !stack.trim().is_empty() => format!("{message}\n{stack}"),
                _ => message,
            }
        }
        other => other.to_string(),
    }
}

fn json_of<'js>(ctx: &Ctx<'js>, value: Value<'js>) -> Json {
    match ctx.json_stringify(value) {
        Ok(Some(text)) => serde_json::from_str(&text.to_string().unwrap_or_default()).unwrap_or(Json::Null),
        _ => Json::Null,
    }
}

impl Mods {
    pub fn new(options: Options) -> Result<Mods, String> {
        let rt = Runtime::new().map_err(|e| e.to_string())?;
        let ctx = Context::full(&rt).map_err(|e| e.to_string())?;
        let resolver = (BuiltinResolver::default().with_module("graffitty-ui").with_module("graffitty"), ModResolver);
        let loader = (
            BuiltinLoader::default().with_module("graffitty-ui", UI).with_module("graffitty", GRAFFITTY),
            ScriptLoader::default().with_extension("mjs"),
        );
        rt.set_loader(resolver, loader);
        let shared_path = options.state_dir.as_ref().map(|d| d.join("mods").join("shared.json"));
        let state = Rc::new(RefCell::new(State {
            copies: HashMap::new(),
            next_copy: 1,
            next_timer: 1,
            current: None,
            recording: None,
            snapshot: Snapshot::default(),
            shared: SharedStore::load(shared_path),
            requests: Vec::new(),
            theme: Json::Object(Default::default()),
            palette: HashMap::new(),
            timers: Vec::new(),
            stop: false,
            now: 0.0,
            log: options.log,
            translate: options.translate,
            state_dir: options.state_dir,
            classes: HashMap::new(),
        }));
        let mods = Mods { rt, ctx, state };
        mods.ctx.with(|ctx| mods.install(&ctx).map_err(|e| describe(&ctx, e)))?;
        Ok(mods)
    }

    fn install<'js>(&self, ctx: &Ctx<'js>) -> rquickjs::Result<()> {
        let globals = ctx.globals();
        let s = self.state.clone();
        globals.set("__gft_div", Func::from(move |ctx: Ctx<'_>| record(&s, &ctx, |r| Ok(r.arena.push(Component::Div)))))?;
        let s = self.state.clone();
        globals.set("__gft_text", Func::from(move |ctx: Ctx<'_>, text: String| record(&s, &ctx, |r| Ok(r.arena.push(Component::Text(text))))))?;
        let s = self.state.clone();
        globals.set("__gft_svg", Func::from(move |ctx: Ctx<'_>, path: String| record(&s, &ctx, |r| Ok(r.arena.push(Component::Svg(path))))))?;
        let s = self.state.clone();
        globals.set("__gft_image", Func::from(move |ctx: Ctx<'_>, path: String| record(&s, &ctx, |r| Ok(r.arena.push(Component::Image(path))))))?;
        let s = self.state.clone();
        globals.set("__gft_attach", Func::from(move |ctx: Ctx<'_>, parent: u32, child: u32| record(&s, &ctx, |r| r.arena.attach(parent, child))))?;
        let s = self.state.clone();
        globals.set("__gft_state", Func::from(move |ctx: Ctx<'_>, id: u32, name: String| {
            record(&s, &ctx, |r| {
                let detached = r.arena.detached();
                let name: &'static str = match name.as_str() {
                    "hover" => "hover",
                    "active" => "active",
                    "focus" => "focus",
                    other => return Err(format!("unknown state style {other:?}")),
                };
                r.arena.record(id, SpecOp::StateStyle(name, detached))?;
                Ok(detached)
            })
        }))?;
        let s = self.state.clone();
        globals.set("__gft_nullary", Func::from(move |ctx: Ctx<'_>, id: u32, index: u16| record(&s, &ctx, |r| r.arena.record(id, SpecOp::NullaryStyle(index)))))?;
        let s = self.state.clone();
        globals.set("__gft_param", Func::from(move |ctx: Ctx<'js>, id: u32, index: u32, value: Value<'js>| {
            let bridged = bridge(&value);
            record(&s, &ctx, |r| {
                let name = style::param_style_at(index as usize).ok_or_else(|| format!("unknown style index {index}"))?;
                // Validate now, so a bad colour names its call site rather than failing at layout.
                let mut probe = style::Style::default();
                style::apply_param(name, &bridged, &mut probe, &HashMap::new()).or_else(|error| {
                    // Palette names resolve at layout time; only reject what can never parse.
                    if bridged.as_str().is_some_and(|text| !text.starts_with('#')) && (name == "bg" || name == "text_color" || name == "border_color" || name == "text_bg") {
                        Ok(())
                    } else {
                        Err(error)
                    }
                })?;
                r.arena.record(id, SpecOp::ParamStyle(name, bridged))
            })
        }))?;
        let s = self.state.clone();
        globals.set("__gft_apply", Func::from(move |ctx: Ctx<'js>, id: u32, name: String, args: Array<'js>| {
            let Some(name) = BEHAVIORS.iter().copied().find(|known| *known == name) else {
                return throw(&ctx, &style::unknown_message(&name));
            };
            let mut plain = Vec::new();
            let mut callback: Option<Function> = None;
            for value in args.iter::<Value>() {
                let value = value?;
                if let Some(function) = value.as_function() {
                    callback = Some(function.clone());
                } else {
                    plain.push(bridge(&value));
                }
            }
            if name.starts_with("on_") && callback.is_none() {
                return throw(&ctx, &format!("{name}(...) needs a handler function"));
            }
            let persistent = callback.map(|f| Persistent::save(&ctx, f));
            record(&s, &ctx, |r| match persistent {
                Some(function) => {
                    let callback = r.arena.next_callback();
                    r.callbacks.push(function);
                    r.arena.record(id, SpecOp::Callback(name, plain, callback))
                }
                None => r.arena.record(id, SpecOp::Method(name, plain)),
            })
        }))?;
        globals.set("__gft_nullary_styles", Func::from(|ctx: Ctx<'js>| -> rquickjs::Result<Array<'js>> {
            let array = Array::new(ctx.clone())?;
            for (i, (name, index)) in style::nullary_styles().into_iter().enumerate() {
                let pair = Array::new(ctx.clone())?;
                pair.set(0, name)?;
                pair.set(1, index)?;
                array.set(i, pair)?;
            }
            Ok(array)
        }))?;
        globals.set("__gft_param_styles", Func::from(|ctx: Ctx<'js>| -> rquickjs::Result<Array<'js>> {
            let array = Array::new(ctx.clone())?;
            for (i, (name, _)) in style::PARAM_STYLES.iter().enumerate() {
                array.set(i, *name)?;
            }
            Ok(array)
        }))?;
        globals.set("__gft_behaviors", Func::from(|ctx: Ctx<'js>| -> rquickjs::Result<Array<'js>> {
            let array = Array::new(ctx.clone())?;
            for (i, name) in BEHAVIORS.iter().enumerate() {
                array.set(i, *name)?;
            }
            Ok(array)
        }))?;
        globals.set("__gft_unknown", Func::from(|name: String| style::unknown_message(&name)))?;
        let s = self.state.clone();
        globals.set("__gft_notify", Func::from(move |copy: u64| {
            let mut st = s.borrow_mut();
            // Notifying the copy being rendered is a loop; the render already runs.
            if st.recording.is_some() && st.current == Some(copy) {
                return;
            }
            if let Some(c) = st.copies.get_mut(&copy) {
                c.dirty = true;
            }
        }))?;
        let s = self.state.clone();
        globals.set("__gft_stop", Func::from(move || s.borrow_mut().stop = true))?;
        let s = self.state.clone();
        globals.set("__gft_timer_every", Func::from(move |ctx: Ctx<'js>, copy: u64, ms: f64, body: Function<'js>| -> rquickjs::Result<u32> {
            let body = Persistent::save(&ctx, body);
            let mut st = s.borrow_mut();
            let due = st.now + ms;
            let id = st.next_timer;
            st.next_timer += 1;
            st.timers.push(Timer { id, copy, every: ms, due, body });
            Ok(id)
        }))?;
        let s = self.state.clone();
        // A copy cancels only its own timers.
        globals.set("__gft_timer_cancel", Func::from(move |copy: u64, id: u32| {
            s.borrow_mut().timers.retain(|t| !(t.id == id && t.copy == copy));
        }))?;
        let s = self.state.clone();
        globals.set("__gft_read", Func::from(move |key: String| -> String {
            let mut st = s.borrow_mut();
            let current = st.current;
            // For a copy opened with `{window: N}`, first look up `key@N`. The host
            // uses that form for per-window focus, resource, and effect data.
            //
            // Fall back to the plain key for app-wide data such as sessions and agents.
            let scoped = current
                .and_then(|id| st.copies.get(&id))
                .and_then(|copy| copy.props.get("window"))
                .and_then(|w| w.as_i64().map(|n| n.to_string()).or_else(|| w.as_str().map(str::to_owned)))
                .map(|window| format!("{key}@{window}"));
            let resolved = match &scoped {
                Some(scoped) if st.snapshot.get(scoped).is_some() => scoped.clone(),
                _ => key.clone(),
            };
            if let Some(mut copy) = current.and_then(|id| st.copies.remove(&id)) {
                copy.reads.record(&key, &st.snapshot);
                if let Some(scoped) = &scoped {
                    copy.reads.record(scoped, &st.snapshot);
                }
                st.copies.insert(current.unwrap(), copy);
            }
            st.snapshot.get(&resolved).map_or_else(|| "null".to_owned(), |v| v.to_string())
        }))?;
        let s = self.state.clone();
        globals.set("__gft_theme", Func::from(move || s.borrow().theme.to_string()))?;
        let s = self.state.clone();
        // An element's scroll offset along one axis; with `value`, scrolls it
        // there (clamped to what the last frame could scroll) and returns that.
        globals.set("__gft_scroll", Func::from(move |key: String, horizontal: bool, value: Option<f64>| -> f64 {
            let mut st = s.borrow_mut();
            let Some(copy) = st.current.and_then(|id| st.copies.get_mut(&id)) else { return 0.0 };
            let key = layout::axis_key(&key, horizontal);
            let max = copy.frame.as_ref().and_then(|frame| frame.hits.iter().find_map(|hit| hit.scroll_for(&key))).map_or(0.0, layout::ScrollInfo::max_offset);
            let current = copy.interaction.scroll.get(&key).copied().unwrap_or(0.0).clamp(0.0, max);
            let Some(value) = value else { return f64::from(current) };
            if value.is_nan() { return f64::from(current) }
            let next = (value as f32).clamp(0.0, max);
            if next != current {
                copy.interaction.scroll.insert(key.clone(), next);
                copy.interaction.scrolled.insert(key, copy.interaction.now);
                copy.layout_dirty = true;
            }
            f64::from(next)
        }))?;
        let s = self.state.clone();
        globals.set("__gft_props", Func::from(move || -> String {
            let st = s.borrow();
            st.current.and_then(|id| st.copies.get(&id)).map_or_else(|| "null".to_owned(), |c| c.props.to_string())
        }))?;
        let s = self.state.clone();
        globals.set("__gft_run", Func::from(move |name: String, args: String| {
            let mut st = s.borrow_mut();
            let copy = st.current.unwrap_or(0);
            let args = serde_json::from_str(&args).unwrap_or(Json::Null);
            st.requests.push(Request::Run { copy, name, args });
        }))?;
        let s = self.state.clone();
        globals.set("__gft_shared", Func::from(move |key: String| -> String { s.borrow().shared.get(&key).map_or_else(|| "null".to_owned(), |v| v.to_string()) }))?;
        let s = self.state.clone();
        globals.set("__gft_set_shared", Func::from(move |key: String, value: String| {
            let value = serde_json::from_str(&value).unwrap_or(Json::Null);
            let mut st = s.borrow_mut();
            if st.shared.set(key, value) {
                // Every mod sees shared state: setting re-renders all, as in Herdr.
                for copy in st.copies.values_mut() {
                    copy.dirty = true;
                }
            }
        }))?;
        let s = self.state.clone();
        globals.set("__gft_overlay", Func::from(move |kind: String, spec: String| -> String {
            let mut st = s.borrow_mut();
            let copy = st.current.unwrap_or(0);
            let spec = serde_json::from_str(&spec).unwrap_or(Json::Null);
            match kind.as_str() {
                "open" => {
                    let id = format!("o{}", st.requests.len() + 1);
                    st.requests.push(Request::OpenOverlay { copy, id: id.clone(), spec });
                    id
                }
                "close" => {
                    let id = spec.as_str().unwrap_or_default().to_owned();
                    st.requests.push(Request::CloseOverlay { copy, id: id.clone() });
                    id
                }
                _ => {
                    let id = format!("n{}", st.requests.len() + 1);
                    st.requests.push(Request::Notify { copy, spec });
                    id
                }
            }
        }))?;
        let s = self.state.clone();
        globals.set("__gft_path", Func::from(move |kind: String| -> String {
            let st = s.borrow();
            match kind.as_str() {
                "app" => st.state_dir.as_ref().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default(),
                _ => std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_default(),
            }
        }))?;
        let s = self.state.clone();
        globals.set("__gft_storage", Func::from(move |op: String, key: String, value: Option<String>| -> Option<String> {
            let mut st = s.borrow_mut();
            let Some(copy) = st.current else { return None };
            let Some(copy) = st.copies.get_mut(&copy) else { return None };
            match op.as_str() {
                "get" => copy.storage.get(&key).map(str::to_owned),
                "set" => {
                    copy.storage.set(&key, value);
                    None
                }
                _ => {
                    copy.storage.set(&key, None);
                    None
                }
            }
        }))?;
        let s = self.state.clone();
        globals.set("__gft_log", Func::from(move |level: String, message: String| s.borrow().log(&level, &message)))?;
        let s = self.state.clone();
        globals.set("__gft_tr", Func::from(move |text: String| -> String { (s.borrow().translate)(&text) }))?;
        ctx.eval::<(), _>(PRELUDE)?;
        Ok(())
    }

    fn drain_jobs(&self) {
        while self.rt.is_job_pending() {
            if let Err(job) = self.rt.execute_pending_job() {
                let message = job.0.with(|ctx| {
                    let caught = ctx.catch();
                    caught.as_exception().and_then(|e| e.message()).unwrap_or_else(|| format!("{caught:?}"))
                });
                self.state.borrow().log("error", &format!("unhandled promise rejection: {message}"));
            }
        }
    }

    /// Replaces the theme: `name → "#rrggbb"`. Mods read it through `theme()`;
    /// style methods accept the names too.
    pub fn set_theme(&mut self, theme: Json) {
        let mut st = self.state.borrow_mut();
        let empty = HashMap::new();
        st.palette = theme
            .as_object()
            .map(|map| map.iter().filter_map(|(name, value)| value.as_str().and_then(|hex| Color::parse(hex, &empty)).map(|color| (name.clone(), color))).collect())
            .unwrap_or_default();
        if st.theme != theme {
            st.theme = theme;
            for copy in st.copies.values_mut() {
                copy.dirty = true;
            }
        }
    }

    /// Publishes one snapshot key; copies that read it re-render on the next frame.
    pub fn publish(&mut self, key: &str, value: Json) -> bool {
        let mut st = self.state.borrow_mut();
        let changed = st.snapshot.publish(key, value);
        if changed {
            let State { copies, snapshot, .. } = &mut *st;
            for copy in copies.values_mut() {
                if copy.reads.changed(snapshot) {
                    copy.dirty = true;
                }
            }
        }
        changed
    }

    /// Loads `dir/main.js` and creates one copy with `props`. The constructor
    /// is cached per folder, so a second copy shares module code. Relative
    /// imports (`./ui.js`) resolve against the folder.
    pub fn load(&mut self, dir: &Path, props: Json) -> Result<CopyId, String> {
        let name = dir.file_name().and_then(|s| s.to_str()).unwrap_or("mod");
        self.load_entry(name, &dir.join("main.js"), props)
    }

    /// Load an explicitly registered entry point. State belongs to its registry ID.
    pub fn load_entry(&mut self, name: &str, entry: &Path, props: Json) -> Result<CopyId, String> {
        let main = entry.canonicalize().map_err(|e| format!("{}: {e}", entry.display()))?;
        let source = std::fs::read(&main).map_err(|e| format!("{}: {e}", main.display()))?;
        self.load_module(name, main.clone(), main.to_string_lossy().into_owned(), source, props)
    }

    /// Loads source bundled inside the application. Relative imports require a file entry.
    pub fn load_source(&mut self, name: &str, source: &str, props: Json) -> Result<CopyId, String> {
        let key = PathBuf::from(format!("gft://mods/{name}"));
        self.load_module(name, key, format!("gft://mods/{name}/main.js"), source.as_bytes().to_vec(), props)
    }

    /// Replaces a copy's props (what `props()` returns) and re-renders it.
    /// Hosts use it for presentation state the dock owns: compact, row, window.
    pub fn set_props(&mut self, id: CopyId, props: Json) -> bool {
        let mut st = self.state.borrow_mut();
        let Some(copy) = st.copies.get_mut(&id) else { return false };
        if copy.props != props {
            copy.props = props;
            copy.dirty = true;
        }
        true
    }

    /// Marks every copy for a new render: a locale or theme change.
    pub fn invalidate_all(&mut self) {
        for copy in self.state.borrow_mut().copies.values_mut() {
            copy.dirty = true;
        }
    }

    fn load_module(&mut self, name: &str, dir: PathBuf, module_name: String, source: Vec<u8>, props: Json) -> Result<CopyId, String> {
        let main = PathBuf::from(&module_name);
        let name = name.to_owned();
        let (id, storage) = {
            let mut st = self.state.borrow_mut();
            let id = st.next_copy;
            st.next_copy += 1;
            // As in Herdr: one store per mod, or one per distinct props when the
            // same mod is opened with different props.
            let file = if props.is_null() {
                "store.json".to_owned()
            } else {
                use std::hash::{Hash, Hasher};
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                props.to_string().hash(&mut hasher);
                format!("store-{:016x}.json", hasher.finish())
            };
            let storage = Storage::load(st.state_dir.as_ref().map(|d| d.join("mods").join(&name).join(file)));
            (id, storage)
        };
        let result = self.ctx.with(|ctx| -> Result<(), String> {
            let class = {
                let cached = self.state.borrow().classes.get(&dir).cloned();
                match cached {
                    Some(class) => class.restore(&ctx).map_err(|e| describe(&ctx, e))?,
                    None => {
                        let declared = Module::declare(ctx.clone(), module_name.clone(), source.clone()).map_err(|e| describe(&ctx, e))?;
                        let (module, promise) = declared.eval().map_err(|e| describe(&ctx, e))?;
                        // Module evaluation is a job; run the queue on this ctx (the
                        // runtime lock is held here, so the Runtime methods would deadlock).
                        while ctx.execute_pending_job() {}
                        promise.finish::<Value>().map_err(|e| describe(&ctx, e))?;
                        let namespace = module.namespace().map_err(|e| describe(&ctx, e))?;
                        let class: Function = namespace.get("default").map_err(|_| format!("{}: main.js must default-export a class extending View", main.display()))?;
                        self.state.borrow_mut().classes.insert(dir.clone(), Persistent::save(&ctx, class.clone()));
                        class
                    }
                }
            };
            let props_value = ctx.json_parse(props.to_string()).map_err(|e| describe(&ctx, e))?;
            let constructor = class.as_constructor().ok_or_else(|| format!("{}: the default export must be a class", main.display()))?;
            let instance: Object = constructor.construct((props_value.clone(),)).catch(&ctx).map_err(|e| e.to_string())?;
            {
                let mut st = self.state.borrow_mut();
                st.copies.insert(
                    id,
                    Copy {
                        name: name.clone(),
                        props: props.clone(),
                        instance: Some(Persistent::save(&ctx, instance.clone())),
                        spec: None,
                        dirty: true,
                        layout_dirty: true,
                        error: None,
                        reads: LiveReads::default(),
                        interaction: Interaction::default(),
                        frame: None,
                        size: (0.0, 0.0),
                        fit: false,
                        storage,
                        pressed: None,
                        press_chain: Vec::new(),
                        thumb_drag: None,
                        wheel_taken: false,
                        wheel_scrolled: false,
                    },
                );
                st.current = Some(id);
            }
            let init: Option<Function> = instance.get("init").ok();
            let outcome = match init {
                Some(init) => {
                    let cx = self.cx(&ctx, id).map_err(|e| describe(&ctx, e))?;
                    init.call::<_, ()>((This(instance.clone()), props_value, cx)).map_err(|e| describe(&ctx, e))
                }
                None => Ok(()),
            };
            self.state.borrow_mut().current = None;
            outcome
        });
        self.drain_jobs();
        match result {
            Ok(()) => Ok(id),
            Err(error) => {
                self.state.borrow_mut().copies.remove(&id);
                Err(error)
            }
        }
    }

    pub fn unload(&mut self, id: CopyId) {
        let mut st = self.state.borrow_mut();
        st.copies.remove(&id);
        st.timers.retain(|t| t.copy != id);
    }

    pub fn copies(&self) -> Vec<CopyId> {
        let mut ids: Vec<CopyId> = self.state.borrow().copies.keys().copied().collect();
        ids.sort_unstable();
        ids
    }

    pub fn name(&self, id: CopyId) -> Option<String> {
        self.state.borrow().copies.get(&id).map(|c| c.name.clone())
    }

    /// The last script error of a copy, if its most recent render failed.
    pub fn error(&self, id: CopyId) -> Option<String> {
        self.state.borrow().copies.get(&id).and_then(|c| c.error.clone())
    }

    fn cx<'js>(&self, ctx: &Ctx<'js>, copy: CopyId) -> rquickjs::Result<Object<'js>> {
        let make: Function = ctx.globals().get("__gft_cx")?;
        make.call((copy,))
    }

    /// Advances timers and tells the host whether any copy needs a new frame.
    pub fn tick(&mut self, now: f64) -> bool {
        let due: Vec<(CopyId, Persistent<Function<'static>>)> = {
            let mut st = self.state.borrow_mut();
            st.now = now;
            // Wake at the idle deadline, then redraw only while opacity changes.
            for copy in st.copies.values_mut() {
                let expired = copy.interaction.scrolled.values().copied().chain(copy.interaction.pointer_at)
                    .any(|at| copy.interaction.now < at + layout::SCROLLBAR_IDLE_MS && now >= at + layout::SCROLLBAR_IDLE_MS);
                let fading = copy.interaction.scrollbar_fades.values().any(|fade| fade.animating(copy.interaction.now));
                if fading || expired {
                    copy.layout_dirty = true;
                }
                copy.interaction.now = now;
                // Play rubber band releases.
                let hits = copy.frame.as_ref().map(|frame| frame.hits.as_slice()).unwrap_or_default();
                for (key, band) in copy.interaction.bands.iter_mut().filter(|(_, band)| band.active()) {
                    let info = hits.iter().find_map(|hit| hit.scroll_for(key));
                    let max = info.map_or(0.0, |info| info.max_offset());
                    let offset = copy.interaction.scroll.get(key).copied().unwrap_or(0.0).clamp(0.0, max);
                    let bounds = info.map_or(0.0, |info| info.viewport);
                    let scroller = Scroller { offset: f64::from(offset), max: f64::from(max), bounds: f64::from(bounds) };
                    if band.tick(now / 1000.0, scroller, true) {
                        copy.layout_dirty = true;
                    }
                }
            }
            let mut fired = Vec::new();
            for timer in &mut st.timers {
                if timer.due <= now {
                    timer.due = now + timer.every;
                    fired.push((timer.copy, timer.body.clone()));
                }
            }
            fired
        };
        for (copy, body) in due {
            if !self.state.borrow().copies.contains_key(&copy) {
                continue;
            }
            self.ctx.with(|ctx| {
                self.state.borrow_mut().current = Some(copy);
                let result = (|| -> rquickjs::Result<()> {
                    let body = body.restore(&ctx)?;
                    let cx = self.cx(&ctx, copy)?;
                    body.call::<_, ()>((cx,))
                })();
                self.state.borrow_mut().current = None;
                if let Err(error) = result {
                    let message = describe(&ctx, error);
                    self.state.borrow().log("error", &format!("timer: {message}"));
                }
            });
            self.drain_jobs();
        }
        self.state.borrow().copies.values().any(|c| c.dirty || c.layout_dirty || c.interaction.bands.values().any(ElasticGesture::active))
    }

    /// A rubber band still pulled, releasing, or waiting for its gesture's
    /// end also needs frames until it rests.
    pub fn needs_frame(&self, id: CopyId) -> bool {
        self.state.borrow().copies.get(&id).is_some_and(|c| {
            c.dirty || c.layout_dirty || c.frame.is_none() || c.interaction.bands.values().any(ElasticGesture::active)
        })
    }

    /// Renders if the script has to run again, lays out if geometry changed,
    /// and returns the frame to paint. Errors keep the last good frame.
    pub fn frame(&mut self, id: CopyId, size: (f32, f32), measure: &mut dyn TextMeasure) -> Result<Frame, String> {
        self.frame_in(id, Some(size), measure)
    }

    /// Like [`Self::frame`], but the root wraps its content; `Frame::size` is
    /// what it took. For a strip over a pane, which the host sizes to the mod.
    pub fn frame_fit(&mut self, id: CopyId, measure: &mut dyn TextMeasure) -> Result<Frame, String> {
        self.frame_in(id, None, measure)
    }

    fn frame_in(&mut self, id: CopyId, size: Option<(f32, f32)>, measure: &mut dyn TextMeasure) -> Result<Frame, String> {
        let (dirty, size_changed) = {
            let mut st = self.state.borrow_mut();
            let copy = st.copies.get_mut(&id).ok_or_else(|| format!("no mod copy {id}"))?;
            let fit = size.is_none();
            let size = size.unwrap_or_default();
            let size_changed = copy.size != size || copy.fit != fit;
            if size_changed {
                copy.size = size;
                copy.fit = fit;
                copy.layout_dirty = true;
            }
            (copy.dirty, size_changed)
        };
        if dirty {
            self.render(id);
        }
        let needs_layout = self.state.borrow().copies.get(&id).is_some_and(|c| c.layout_dirty || c.frame.is_none());
        if needs_layout {
            let outcome = {
                let mut st = self.state.borrow_mut();
                let palette = st.palette.clone();
                let copy = st.copies.get_mut(&id).ok_or_else(|| format!("no mod copy {id}"))?;
                match &copy.spec {
                    Some(spec) => Some(layout::compute(&spec.arena, spec.root, size, &mut copy.interaction, measure, &palette)),
                    None => None,
                }
            };
            let mut size_callbacks = Vec::new();
            {
                let mut st = self.state.borrow_mut();
                let copy = st.copies.get_mut(&id).unwrap();
                copy.layout_dirty = false;
                match outcome {
                    Some(Ok(frame)) => {
                        if size_changed || copy.frame.is_none() {
                            size_callbacks = frame.hits.iter().filter_map(|h| h.size_change.map(|cb| (cb, h.size))).collect();
                        }
                        copy.frame = Some(frame);
                    }
                    Some(Err(error)) => {
                        copy.error = Some(error.clone());
                        st.log("error", &format!("{}: layout: {error}", st.copies[&id].name));
                    }
                    None => copy.frame = Some(Frame { size: size.unwrap_or_default(), ..Default::default() }),
                }
            }
            for (callback, (width, height)) in size_callbacks {
                self.invoke(id, callback, |ctx| {
                    let object = Object::new(ctx.clone())?;
                    object.set("width", width)?;
                    object.set("height", height)?;
                    Ok(object.into_value())
                });
            }
        }
        let st = self.state.borrow();
        let copy = st.copies.get(&id).ok_or_else(|| format!("no mod copy {id}"))?;
        copy.frame.clone().ok_or_else(|| copy.error.clone().unwrap_or_else(|| "no frame".into()))
    }

    fn render(&mut self, id: CopyId) {
        let instance = {
            let mut st = self.state.borrow_mut();
            let Some(copy) = st.copies.get_mut(&id) else { return };
            copy.dirty = false;
            let Some(instance) = copy.instance.clone() else { return };
            st.current = Some(id);
            st.recording = Some(Recording { arena: SpecArena::default(), callbacks: Vec::new() });
            instance
        };
        let result = self.ctx.with(|ctx| -> Result<SpecId, String> {
            let instance = instance.restore(&ctx).map_err(|e| describe(&ctx, e))?;
            let render: Function = instance.get("render").map_err(|_| "the view has no render() method".to_owned())?;
            let cx = self.cx(&ctx, id).map_err(|e| describe(&ctx, e))?;
            let out: Value = render.call((This(instance), cx)).map_err(|e| describe(&ctx, e))?;
            if let Some(object) = out.as_object() {
                return object.get::<_, u32>("__id").map_err(|_| "render() must return an element".to_owned());
            }
            if let Some(text) = out.as_string() {
                let text = text.to_string().unwrap_or_default();
                return record(&self.state, &ctx, |r| Ok(r.arena.push(Component::Text(text)))).map_err(|e| describe(&ctx, e));
            }
            Err("render() must return an element or a string".into())
        });
        let mut st = self.state.borrow_mut();
        st.current = None;
        let recording = st.recording.take();
        let name = st.copies.get(&id).map(|c| c.name.clone()).unwrap_or_default();
        let Some(copy) = st.copies.get_mut(&id) else { return };
        match (result, recording) {
            (Ok(root), Some(recording)) => {
                copy.spec = Some(Spec { arena: recording.arena, root, callbacks: recording.callbacks });
                copy.error = None;
                copy.layout_dirty = true;
            }
            (Err(error), _) => {
                copy.error = Some(error.clone());
                drop(st);
                self.state.borrow().log("error", &format!("{name}: render: {error}"));
                return;
            }
            (Ok(_), None) => {}
        }
        drop(st);
        self.drain_jobs();
    }

    fn invoke(&mut self, id: CopyId, callback: CallbackId, argument: impl for<'js> FnOnce(&Ctx<'js>) -> rquickjs::Result<Value<'js>>) -> bool {
        let function = {
            let st = self.state.borrow();
            let Some(copy) = st.copies.get(&id) else { return false };
            let Some(spec) = &copy.spec else { return false };
            let Some(function) = spec.callbacks.get(callback as usize) else { return false };
            function.clone()
        };
        self.state.borrow_mut().current = Some(id);
        self.state.borrow_mut().stop = false;
        let result = self.ctx.with(|ctx| -> rquickjs::Result<()> {
            let function = function.restore(&ctx)?;
            let argument = argument(&ctx)?;
            let cx = self.cx(&ctx, id)?;
            function.call::<_, ()>((argument, cx))
        });
        self.state.borrow_mut().current = None;
        if let Err(error) = result {
            let message = self.ctx.with(|ctx| describe(&ctx, error));
            let name = self.state.borrow().copies.get(&id).map(|c| c.name.clone()).unwrap_or_default();
            self.state.borrow().log("error", &format!("{name}: handler: {message}"));
        }
        self.drain_jobs();
        let stopped = self.state.borrow().stop;
        self.state.borrow_mut().stop = false;
        stopped
    }

    /// The hit under a point and its ancestors, deepest first.
    fn chain(frame: &Frame, x: f32, y: f32) -> Vec<usize> {
        // Children are pushed after their parents and later siblings after
        // earlier ones, so the last hit containing the point is the topmost.
        let Some(deepest) = frame.hits.iter().rposition(|h| h.rect.contains(x, y)) else { return Vec::new() };
        let mut chain = vec![deepest];
        let mut current = deepest;
        while let Some(parent) = frame.hits[current].parent {
            chain.push(parent);
            current = parent;
        }
        chain
    }

    /// Delivers a pointer event.
    pub fn pointer(&mut self, id: CopyId, event: PointerEvent) -> PointerOutcome {
        // Pointer activity keeps scrollbars up; the first after a rest brings them back.
        if !matches!(event, PointerEvent::Leave) {
            let mut st = self.state.borrow_mut();
            let now = st.now;
            if let Some(copy) = st.copies.get_mut(&id) {
                if copy.interaction.pointer_at.is_none_or(|at| now - at >= layout::SCROLLBAR_IDLE_MS) {
                    copy.layout_dirty = true;
                }
                copy.interaction.pointer_at = Some(now);
            }
        }
        if self.thumb(id, event) {
            return PointerOutcome { cursor: Cursor::Arrow, handled: true, scrolled: false };
        }
        let captured = matches!(event, PointerEvent::Move { .. } | PointerEvent::Up { .. } | PointerEvent::Cancel { .. })
            && self.state.borrow().copies.get(&id).is_some_and(|c| !c.press_chain.is_empty());
        if let Some(copy) = self.state.borrow_mut().copies.get_mut(&id) {
            copy.wheel_taken = false;
            copy.wheel_scrolled = false;
        }
        let cursor = self.dispatch(id, event);
        let wheel = matches!(event, PointerEvent::Wheel { .. });
        let taken = wheel && self.state.borrow().copies.get(&id).is_some_and(|c| c.wheel_taken);
        let scrolled = wheel && self.state.borrow().copies.get(&id).is_some_and(|c| c.wheel_scrolled);
        let handled = captured || taken || {
            let st = self.state.borrow();
            match (event, st.copies.get(&id).and_then(|c| c.frame.as_ref())) {
                (PointerEvent::Leave | PointerEvent::Cancel { .. }, _) | (PointerEvent::Move { .. }, _) | (_, None) => false,
                (PointerEvent::Wheel { x, y, .. }, Some(frame)) => Self::chain(frame, x, y).iter().any(|i| frame.hits[*i].handlers.iter().any(|h| h.0 == "on_scroll_wheel")),
                (PointerEvent::Down { x, y, .. } | PointerEvent::Up { x, y, .. }, Some(frame)) => Self::chain(frame, x, y).iter().any(|i| frame.hits[*i].handlers.iter().any(|h| h.0 != "on_hover" && h.0 != "on_scroll_wheel")),
            }
        };
        PointerOutcome { cursor, handled, scrolled }
    }

    /// A press on an overflowing list's scrollbar strip takes its thumb, and
    /// the content follows the pointer until release. A press off the thumb
    /// first moves it under the pointer.
    ///
    /// True when the scrollbar took the event.
    fn thumb(&mut self, id: CopyId, event: PointerEvent) -> bool {
        let mut st = self.state.borrow_mut();
        let Some(copy) = st.copies.get_mut(&id) else { return false };
        match event {
            PointerEvent::Down { x, y, button: Button::Left } => {
                let Some(frame) = copy.frame.as_ref() else { return false };
                let found = Self::chain(frame, x, y).into_iter().rev().find_map(|i| {
                    let hit = &frame.hits[i];
                    [&hit.scroll_x, &hit.scroll].into_iter().flatten().find(|info| {
                        let strip = if info.horizontal { y >= hit.rect.y + hit.rect.h - SCROLLBAR_GRAB } else { x >= hit.rect.x + hit.rect.w - SCROLLBAR_GRAB };
                        strip && hit.rect.w >= 6.0 && hit.rect.h >= 6.0 && info.overflows()
                    }).map(|info| (layout::axis_key(&hit.key, info.horizontal), hit.rect, info.clone()))
                });
                let Some((key, rect, info)) = found else { return false };
                let (track, thumb) = info.bar(rect, copy.interaction.stretch(&key));
                copy.interaction.bands.remove(&key);
                // Along the bar: x for a sideways bar, y for a vertical one.
                let (at, track_start, track_length, thumb_start, thumb_length) = if info.horizontal {
                    (x, track.x, track.w, thumb.x, thumb.w)
                } else {
                    (y, track.y, track.h, thumb.y, thumb.h)
                };
                let scale = info.max_offset() / (track_length - thumb_length).max(1.0);
                let offset = if at < thumb_start || at > thumb_start + thumb_length {
                    ((at - track_start - thumb_length / 2.0) * scale).clamp(0.0, info.max_offset())
                } else {
                    info.offset
                };
                copy.interaction.scroll.insert(key.clone(), offset);
                copy.interaction.scrolled.insert(key.clone(), copy.interaction.now);
                copy.interaction.thumb = Some(key.clone());
                copy.thumb_drag = Some(ThumbDrag { key, at, horizontal: info.horizontal, offset, scale, max: info.max_offset() });
                copy.pressed = None;
                copy.press_chain.clear();
                copy.layout_dirty = true;
                true
            }
            PointerEvent::Move { x, y } => {
                let Some(drag) = copy.thumb_drag.clone() else { return false };
                let at = if drag.horizontal { x } else { y };
                let offset = (drag.offset + (at - drag.at) * drag.scale).clamp(0.0, drag.max);
                copy.interaction.scrolled.insert(drag.key.clone(), copy.interaction.now);
                copy.interaction.scroll.insert(drag.key, offset);
                copy.layout_dirty = true;
                true
            }
            PointerEvent::Up { button: Button::Left, .. } | PointerEvent::Cancel { .. } => {
                let Some(drag) = copy.thumb_drag.take() else { return false };
                copy.interaction.scrolled.insert(drag.key, copy.interaction.now);
                copy.interaction.thumb = None;
                copy.layout_dirty = true;
                true
            }
            _ => false,
        }
    }

    fn dispatch(&mut self, id: CopyId, event: PointerEvent) -> Cursor {
        let Some(frame) = self.state.borrow().copies.get(&id).and_then(|c| c.frame.clone()) else { return Cursor::Arrow };
        let (x, y) = match event {
            PointerEvent::Move { x, y } | PointerEvent::Down { x, y, .. } | PointerEvent::Up { x, y, .. } | PointerEvent::Cancel { x, y } | PointerEvent::Wheel { x, y, .. } => (x, y),
            PointerEvent::Leave => (-1.0, -1.0),
        };
        let chain = if matches!(event, PointerEvent::Leave) { Vec::new() } else { Self::chain(&frame, x, y) };
        let keys: Vec<String> = if matches!(event, PointerEvent::Wheel { .. }) { Vec::new() } else { chain.iter().map(|i| frame.hits[*i].key.clone()).collect() };
        // Hover bookkeeping on every event: a press without a prior move still hovers.
        let previous: Vec<String> = self.state.borrow().copies.get(&id).map(|c| c.interaction.hovered.clone()).unwrap_or_default();
        if previous != keys {
            // A list's scrollbar shows while the pointer is over it.
            let affects_style = frame.hits.iter().any(|h| (h.hover_style || h.scroll.is_some() || h.scroll_x.is_some()) && (previous.contains(&h.key) != keys.contains(&h.key)));
            {
                let mut st = self.state.borrow_mut();
                if let Some(copy) = st.copies.get_mut(&id) {
                    copy.interaction.hovered = keys.clone();
                    if affects_style {
                        copy.layout_dirty = true;
                    }
                }
            }
            for hit in &frame.hits {
                let was = previous.contains(&hit.key);
                let is = keys.contains(&hit.key);
                if was != is {
                    for (name, _, callback) in &hit.handlers {
                        if *name == "on_hover" {
                            self.invoke(id, *callback, |ctx| Ok(Value::new_bool(ctx.clone(), is)));
                        }
                    }
                }
            }
        }
        // Drag ownership follows the press, not hover. Resolve stable keys
        // against the latest frame because a drag may have rebuilt the view.
        let captured = self.state.borrow().copies.get(&id).map(|c| c.press_chain.clone()).unwrap_or_default();
        let drag_chain: Vec<usize> = if captured.is_empty() { chain.clone() } else {
            captured.iter().filter_map(|key| frame.hits.iter().position(|h| &h.key == key)).collect()
        };
        let cursor = drag_chain.iter().find_map(|i| {
            let hit = &frame.hits[*i];
            if hit.cursor_ew_resize { Some(Cursor::ResizeHorizontal) }
            else if hit.cursor_pointer { Some(Cursor::Pointer) } else { None }
        }).unwrap_or(Cursor::Arrow);
        match event {
            PointerEvent::Move { .. } => {
                for index in &drag_chain {
                    let handlers = frame.hits[*index].handlers.clone();
                    for (name, _, callback) in handlers {
                        if name == "on_mouse_move" && self.invoke(id, callback, |ctx| mouse_event_value(ctx, x, y, None)) {
                            return cursor;
                        }
                    }
                }
            }
            PointerEvent::Down { button, .. } => {
                if let Some(copy) = self.state.borrow_mut().copies.get_mut(&id) {
                    copy.pressed = if button == Button::Left { keys.first().cloned() } else { None };
                    copy.press_chain = if button == Button::Left { keys.clone() } else { Vec::new() };
                }
                for index in &chain {
                    let handlers = frame.hits[*index].handlers.clone();
                    for (name, args, callback) in handlers {
                        let wanted = args.first().and_then(Bridged::as_str) == Some(button.name());
                        if name == "on_mouse_down" && wanted && self.invoke(id, callback, |ctx| mouse_event_value(ctx, x, y, Some(button))) {
                            return cursor;
                        }
                    }
                }
            }
            PointerEvent::Up { .. } | PointerEvent::Cancel { .. } => {
                let (button, canceled) = match event {
                    PointerEvent::Up { button, .. } => (button, false),
                    _ => (Button::Left, true),
                };
                let pressed = self.state.borrow_mut().copies.get_mut(&id).and_then(|c| {
                    c.press_chain.clear();
                    c.pressed.take()
                });
                // A click is a press and a release on the same element, as in GPUI.
                let clicked = !canceled && button == Button::Left && pressed.is_some() && pressed == keys.first().cloned();
                // Bubble per element, deepest first: a child's click handler that
                // stops propagation keeps its parent's mouse-up from running.
                for index in &drag_chain {
                    let handlers = frame.hits[*index].handlers.clone();
                    for (name, args, callback) in handlers {
                        let wanted = args.first().and_then(Bridged::as_str) == Some(button.name());
                        let fire = (name == "on_mouse_up" && wanted) || (name == "on_click" && clicked);
                        if fire && self.invoke(id, callback, |ctx| mouse_event_value(ctx, x, y, Some(button))) {
                            return cursor;
                        }
                    }
                }
            }
            PointerEvent::Wheel { dx, dy, gesture, .. } => {
                if gesture.is_none()
                    && let Some(copy) = self.state.borrow_mut().copies.get_mut(&id)
                {
                    // A physical wheel interrupts a trackpad pull or release.
                    copy.interaction.gesture_list = None;
                    copy.layout_dirty |= copy.interaction.bands.values().any(ElasticGesture::active);
                    copy.interaction.bands.clear();
                }
                let previous = self.state.borrow().copies.get(&id).and_then(|copy| copy.interaction.gesture_list.clone());
                if let Some(key) = previous
                    && let Some(info) = frame.hits.iter().find_map(|hit| hit.scroll_for(&key))
                    && let Some(phase) = gesture
                {
                    if !phase.began || phase.momentum {
                        self.scroll_list(id, &key, info, if info.horizontal { dx } else { dy }, gesture);
                        return cursor;
                    }
                    // A new finger gesture may select another list or axis.
                    if let Some(copy) = self.state.borrow_mut().copies.get_mut(&id) {
                        if let Some(band) = copy.interaction.bands.get_mut(&key) {
                            let offset = copy.interaction.scroll.get(&key).copied().unwrap_or(info.offset);
                            band.end(copy.interaction.now / 1000.0, Scroller {
                                offset: offset.into(), max: info.max_offset().into(), bounds: info.viewport.into(),
                            });
                        }
                        copy.interaction.gesture_list = None;
                    }
                }
                for (position, index) in chain.iter().enumerate() {
                    let hit = &frame.hits[*index];
                    let handlers = hit.handlers.clone();
                    for (name, _, callback) in handlers {
                        if name == "on_scroll_wheel" {
                            let stopped = self.invoke(id, callback, |ctx| {
                                let object = Object::new(ctx.clone())?;
                                object.set("x", x)?;
                                object.set("y", y)?;
                                object.set("delta_x", dx)?;
                                object.set("delta_y", dy)?;
                                Ok(object.into_value())
                            });
                            if stopped {
                                return cursor;
                            }
                        }
                    }
                    // A zero-delta begin has no direction yet. Acquire the
                    // axis on the first movement, then keep it through momentum.
                    if dx == 0.0 && dy == 0.0 {
                        if gesture.is_some_and(|phase| phase.began) && (hit.scroll.is_some() || hit.scroll_x.is_some()) {
                            self.state.borrow_mut().copies.get_mut(&id).unwrap().wheel_taken = true;
                            return cursor;
                        }
                        continue;
                    }
                    let horizontal = dx.abs() > dy.abs();
                    let axis = |i: usize| {
                        let hit = &frame.hits[i];
                        if horizontal { hit.scroll_x.as_ref() } else { hit.scroll.as_ref() }
                    };
                    if let Some(info) = axis(*index) {
                        if info.max_offset() <= 0.0 {
                            let outer = chain[position + 1..].iter().any(|i| axis(*i).is_some_and(|s| s.max_offset() > 0.0));
                            if gesture.is_none() || outer { continue; }
                        }
                        let gesture = gesture.map(|g| ScrollGesture { began: true, ..g });
                        self.scroll_list(id, &layout::axis_key(&hit.key, horizontal), info, if horizontal { dx } else { dy }, gesture);
                        return cursor;
                    }
                }
            }
            // Leaving changes hover only; release ends pointer ownership.
            PointerEvent::Leave => {}
        }
        cursor
    }

    /// Scrolls one list along its axis by `delta`; a phased gesture pulls it
    /// past either end. `key` is the axis key (`layout::axis_key`).
    fn scroll_list(&mut self, id: CopyId, key: &str, info: &layout::ScrollInfo, delta: f32, gesture: Option<ScrollGesture>) {
        let mut st = self.state.borrow_mut();
        let now = st.now;
        let Some(copy) = st.copies.get_mut(&id) else { return };
        let max = info.max_offset();
        let offset = copy.interaction.scroll.get(key).copied().unwrap_or(info.offset).clamp(0.0, max);
        let band = copy.interaction.bands.entry(key.to_string()).or_insert_with(|| ElasticGesture::new(ElasticConfig::terminal()));
        let pulled = band.elastic.stretch();
        let next = band.scroll(f64::from(offset), f64::from(max), f64::from(info.viewport), f64::from(delta), gesture, now / 1000.0) as f32;
        let moved = (next - offset).abs() > 0.01 || band.elastic.stretch() != pulled;
        if gesture.is_some_and(|g| g.ended && !g.hold_end) {
            copy.interaction.gesture_list = None;
        } else if gesture.is_some_and(|g| g.began) {
            copy.interaction.gesture_list = Some(key.to_string());
        }
        copy.wheel_taken = true;
        copy.wheel_scrolled |= moved;
        if moved {
            copy.interaction.scroll.insert(key.to_string(), next);
            copy.interaction.scrolled.insert(key.to_string(), now);
            copy.layout_dirty = true;
        }
    }

    /// Whether a press at `(x, y)` reaches something the mod acts on: a
    /// handler other than hover/wheel, or an overflowing list it scrolls.
    ///
    /// Frontends leave other points to their own chrome, such as a dock drag.
    pub fn interactive_at(&self, id: CopyId, x: f32, y: f32) -> bool {
        let st = self.state.borrow();
        let Some(frame) = st.copies.get(&id).and_then(|c| c.frame.as_ref()) else { return false };
        Self::chain(frame, x, y).iter().any(|i| {
            let hit = &frame.hits[*i];
            hit.handlers.iter().any(|h| h.0 != "on_hover" && h.0 != "on_scroll_wheel")
                || [&hit.scroll, &hit.scroll_x].into_iter().flatten().any(|s| s.content > s.viewport)
        })
    }

    /// The current frame's hit regions, for frontends and tests.
    pub fn hits(&self, id: CopyId) -> Vec<Hit> {
        self.state.borrow().copies.get(&id).and_then(|c| c.frame.as_ref()).map(|f| f.hits.clone()).unwrap_or_default()
    }

    /// Every text run in the current frame, in paint order.
    pub fn texts(&self, id: CopyId) -> Vec<String> {
        let st = self.state.borrow();
        let Some(frame) = st.copies.get(&id).and_then(|c| c.frame.as_ref()) else { return Vec::new() };
        frame
            .draws
            .iter()
            .filter_map(|d| match d {
                layout::Draw::Text { text, .. } => Some(text.clone()),
                _ => None,
            })
            .collect()
    }

    /// The tooltip of the deepest element under the point that has one.
    pub fn tooltip(&self, id: CopyId, x: f32, y: f32) -> Option<String> {
        let st = self.state.borrow();
        let frame = st.copies.get(&id)?.frame.as_ref()?;
        Self::chain(frame, x, y).into_iter().find_map(|i| frame.hits[i].tooltip.clone())
    }

    /// Requests mods made since the last call: actions to run, overlays to open.
    pub fn take_requests(&mut self) -> Vec<Request> {
        std::mem::take(&mut self.state.borrow_mut().requests)
    }

    /// Runs `source` as the given copy (so `props()`, reads and storage are
    /// its own) and returns the result as JSON text. For diagnostics and tests.
    pub fn eval(&mut self, id: CopyId, source: &str) -> Result<String, String> {
        if !self.state.borrow().copies.contains_key(&id) {
            return Err(format!("no mod copy {id}"));
        }
        self.state.borrow_mut().current = Some(id);
        let result = self.ctx.with(|ctx| -> Result<String, String> {
            let value: Value = ctx.eval(source).map_err(|e| describe(&ctx, e))?;
            Ok(json_of(&ctx, value).to_string())
        });
        self.drain_jobs();
        self.state.borrow_mut().current = None;
        result
    }

    /// The current description as indented text, for diagnostics.
    pub fn describe(&self, id: CopyId) -> Option<String> {
        let st = self.state.borrow();
        let spec = st.copies.get(&id)?.spec.as_ref()?;
        Some(spec.arena.debug_tree(spec.root))
    }
}

impl Drop for Mods {
    fn drop(&mut self) {
        // Persistent handles must be released inside a context before the runtime goes.
        let mut st = self.state.borrow_mut();
        st.copies.clear();
        st.timers.clear();
        st.classes.clear();
        st.recording = None;
    }
}
