//! A mod loads, renders, re-renders only for keys it read, and handles clicks.
use std::cell::RefCell;
use std::rc::Rc;

use graffitty_mods::engine::Button;
use graffitty_mods::{Draw, Mods, MonospaceMeasure, Options, PointerEvent, Request};
use serde_json::json;

fn host(dir: &std::path::Path) -> (Mods, Rc<RefCell<Vec<String>>>) {
    let log = Rc::new(RefCell::new(Vec::new()));
    let sink = log.clone();
    let mods = Mods::new(Options {
        state_dir: Some(dir.join("state")),
        log: Box::new(move |level, message| sink.borrow_mut().push(format!("{level}: {message}"))),
        translate: Box::new(|text| format!("[{text}]")),
    })
    .unwrap();
    (mods, log)
}

fn write_mod(dir: &std::path::Path, name: &str, source: &str) -> std::path::PathBuf {
    let folder = dir.join(name);
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("main.js"), source).unwrap();
    folder
}

#[test]
fn registered_entries_resolve_siblings_and_keep_storage_by_id() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _) = host(dir.path());
    std::fs::write(dir.path().join("label.mjs"), "export const label = 'Sibling';").unwrap();
    let source = r#"import {View, div} from 'graffitty-ui'; import {label} from './label.mjs';
        export default class extends View { render() { return div().child(label); } }"#;
    let first = dir.path().join("custom.js");
    let second = dir.path().join("replacement.js");
    std::fs::write(&first, source).unwrap();
    std::fs::write(&second, source).unwrap();
    let id = mods.load_entry("agents", &first, serde_json::Value::Null).unwrap();
    let frame = mods.frame(id, (200.0, 40.0), &mut MonospaceMeasure).unwrap();
    assert!(frame.draws.iter().any(|draw| matches!(draw, Draw::Text {text, ..} if text == "Sibling")));
    mods.eval(id, "localStorage.setItem('saved', 'yes')").unwrap();
    mods.unload(id);
    let id = mods.load_entry("agents", &second, serde_json::Value::Null).unwrap();
    assert_eq!(mods.eval(id, "localStorage.getItem('saved')").unwrap(), "\"yes\"");
    let other = mods.load_entry("builds", &second, serde_json::Value::Null).unwrap();
    assert_eq!(mods.eval(other, "localStorage.getItem('saved')").unwrap(), "null");
}

const STATUS: &str = r#"
import { View, div, svg, h_flex } from "graffitty-ui";
import { agents, effects, theme, run, props } from "graffitty";

export default class Status extends View {
  init(_props, cx) {
    this.clicks = 0;
    this.sizes = [];
  }
  render(cx) {
    const t = theme();
    const list = agents();
    const fx = effects();
    const off = fx?.profile === "off";
    return h_flex().id("root").size_full().px(14).gap(16).bg(t.chrome).text_size(11.8).text_color(t.muted)
      .on_size_change((size, cx) => { this.sizes.push(size.width); })
      .child(div().id("count").child(`${list.length} agents`))
      .child(div().flex_1())
      .child(div().id("fx").cursor_pointer().hover((s) => s.text_color(t.foreground))
        .tooltip(off ? "Typing effects are off" : "Typing effects are on")
        .on_click((_e, cx) => { this.clicks += 1; run("SetEffectsProfile", { profile: off ? "world" : "off" }); cx.notify(); })
        .child(svg("icons/sparkles.svg").size(13).when(!off, (el) => el.spin(900)))
        .child(off ? "FX off" : "FX"))
      .child(div().id("who").child(String(props()?.who ?? "")));
  }
}
"#;

#[test]
fn renders_tracks_reads_and_dispatches_clicks() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, log) = host(dir.path());
    mods.set_theme(json!({"chrome": "#202126", "muted": "#a2a4ae", "foreground": "#e4e4e7"}));
    mods.publish("agents", json!([{"id": "a"}, {"id": "b"}]));
    mods.publish("effects", json!({"profile": "world"}));
    let folder = write_mod(dir.path(), "status", STATUS);
    let id = mods.load(&folder, json!({"who": "kiyoon"})).unwrap_or_else(|e| panic!("{e}\n{:?}", log.borrow()));

    let frame = mods.frame(id, (400.0, 28.0), &mut MonospaceMeasure).unwrap();
    assert!(log.borrow().is_empty(), "{:?}", log.borrow());
    assert_eq!(mods.eval(id, r#"globalThis.__gft_tr("Agents")"#).unwrap(), "\"[Agents]\"");
    let texts: Vec<String> = frame
        .draws
        .iter()
        .filter_map(|d| match d {
            Draw::Text { text, .. } => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(texts, vec!["2 agents", "FX", "kiyoon"]);
    assert!(matches!(frame.draws[0], Draw::Rect { color, .. } if (color.r - 0x20 as f32 / 255.0).abs() < 1e-3));
    assert!(frame.animated, "the icon spins while effects are on");
    assert!(!mods.needs_frame(id));

    // An unread key does not wake the copy; a read one does.
    mods.publish("sessions", json!([1, 2, 3]));
    assert!(!mods.needs_frame(id));
    mods.publish("agents", json!([{"id": "a"}]));
    assert!(mods.needs_frame(id));
    let frame = mods.frame(id, (400.0, 28.0), &mut MonospaceMeasure).unwrap();
    assert!(frame.draws.iter().any(|d| matches!(d, Draw::Text { text, .. } if text == "1 agents")));

    // Hover reaches the button through its icon and reports the tooltip.
    let fx = frame.hits.iter().find(|h| h.key == "fx").unwrap();
    let (cx, cy) = (fx.rect.x + 2.0, fx.rect.y + fx.rect.h / 2.0);
    let outcome = mods.pointer(id, PointerEvent::Move { x: cx, y: cy });
    assert_eq!(outcome.cursor, graffitty_mods::Cursor::Pointer);
    assert!(!outcome.handled, "motion is never swallowed");
    assert_eq!(mods.tooltip(id, cx, cy).as_deref(), Some("Typing effects are on"));
    assert!(mods.needs_frame(id), "a hover style needs a relayout, not a render");
    let hovered = mods.frame(id, (400.0, 28.0), &mut MonospaceMeasure).unwrap();
    let fx_text = hovered.draws.iter().find_map(|d| match d {
        Draw::Text { text, color, .. } if text == "FX" => Some(*color),
        _ => None,
    });
    assert!((fx_text.unwrap().r - 0xe4 as f32 / 255.0).abs() < 1e-3, "hover recolours the label");

    // Press and release on the element runs the action and notifies.
    assert!(mods.pointer(id, PointerEvent::Down { x: cx, y: cy, button: Button::Left }).handled);
    mods.pointer(id, PointerEvent::Up { x: cx, y: cy, button: Button::Left });
    assert!(!mods.pointer(id, PointerEvent::Down { x: 150.0, y: cy, button: Button::Left }).handled, "empty space passes through");
    mods.pointer(id, PointerEvent::Up { x: 150.0, y: cy, button: Button::Left });
    let requests = mods.take_requests();
    assert_eq!(requests, vec![Request::Run { copy: id, name: "SetEffectsProfile".into(), args: json!({"profile": "off"}) }]);
    assert!(mods.needs_frame(id), "cx.notify() in a handler re-renders");

    // The host applies the action and publishes; the label follows.
    mods.publish("effects", json!({"profile": "off"}));
    let frame = mods.frame(id, (400.0, 28.0), &mut MonospaceMeasure).unwrap();
    assert!(frame.draws.iter().any(|d| matches!(d, Draw::Text { text, .. } if text == "FX off")));
    assert!(!frame.animated, "no spin while effects are off");
    assert_eq!(mods.tooltip(id, cx, cy).as_deref(), Some("Typing effects are off"));
    assert!(log.borrow().is_empty(), "{:?}", log.borrow());
}

#[test]
fn a_broken_render_keeps_the_last_good_frame_and_names_the_error() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, log) = host(dir.path());
    let folder = write_mod(
        dir.path(),
        "flaky",
        r#"
import { View, div } from "graffitty-ui";
import { live } from "graffitty";
export default class Flaky extends View {
  render() {
    const n = live("n") ?? 0;
    if (n > 0) return div().items_centre();
    return div().id("ok").child("fine");
  }
}
"#,
    );
    let id = mods.load(&folder, serde_json::Value::Null).unwrap();
    let frame = mods.frame(id, (100.0, 20.0), &mut MonospaceMeasure).unwrap();
    assert_eq!(frame.hits.len(), 2);
    mods.publish("n", json!(1));
    let again = mods.frame(id, (100.0, 20.0), &mut MonospaceMeasure).unwrap();
    assert_eq!(again.hits.len(), 2, "the old frame stays up");
    let error = mods.error(id).unwrap();
    assert!(error.contains("items_centre") && error.contains("items_center"), "{error}");
    assert!(log.borrow().iter().any(|line| line.starts_with("error: flaky: render:")), "{:?}", log.borrow());
}

#[test]
fn timers_shared_state_and_storage_work_per_copy() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, log) = host(dir.path());
    let folder = write_mod(
        dir.path(),
        "ticker",
        r#"
import { View, div } from "graffitty-ui";
import { shared, setShared, props } from "graffitty";
export default class Ticker extends View {
  init(_props, cx) {
    this.ticks = Number(localStorage.getItem("ticks") ?? 0);
    cx.timer.every(100, (cx) => { this.ticks += 1; localStorage.setItem("ticks", String(this.ticks)); cx.notify(); });
  }
  render() {
    return div().child(`${props().name}:${this.ticks}:${shared("mode") ?? "-"}`);
  }
}
"#,
    );
    let a = mods.load(&folder, json!({"name": "a"})).unwrap();
    let b = mods.load(&folder, json!({"name": "b"})).unwrap();
    let text = |mods: &mut Mods, id| {
        let frame = mods.frame(id, (300.0, 20.0), &mut MonospaceMeasure).unwrap();
        frame
            .draws
            .iter()
            .find_map(|d| match d {
                Draw::Text { text, .. } => Some(text.clone()),
                _ => None,
            })
            .unwrap()
    };
    assert_eq!(text(&mut mods, a), "a:0:-");
    assert_eq!(text(&mut mods, b), "b:0:-");
    assert!(!mods.tick(50.0));
    assert!(mods.tick(120.0), "the timer fired and notified");
    assert_eq!(text(&mut mods, a), "a:1:-");
    assert_eq!(text(&mut mods, b), "b:1:-");
    // Shared state re-renders every copy.
    mods.eval(a, r#"import("graffitty").then(m => m.setShared("mode", "night"))"#).unwrap();
    assert!(mods.needs_frame(a) && mods.needs_frame(b));
    assert_eq!(text(&mut mods, b), "b:1:night");
    assert!(log.borrow().is_empty(), "{:?}", log.borrow());
    drop(mods);
    // Storage persisted per props: a fresh host picks the count back up.
    let (mut again, _) = host(dir.path());
    let c = again.load(&folder, json!({"name": "a"})).unwrap();
    assert_eq!(text(&mut again, c), "a:1:night");
    let fresh = again.load(&folder, json!({"name": "c"})).unwrap();
    assert_eq!(text(&mut again, fresh), "c:0:night");
}

#[test]
fn a_child_click_that_stops_propagation_keeps_the_parent_mouse_up_from_running() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, log) = host(dir.path());
    let folder = write_mod(
        dir.path(),
        "header",
        r#"
import { View, div, h_flex } from "graffitty-ui";
import { run } from "graffitty";
export default class Header extends View {
  render() {
    return h_flex().id("header").size_full()
      .on_mouse_up("left", () => run("Fold", {}))
      .child(div().id("name").flex_1().child("name"))
      .child(div().id("plus").w(36).h(20).on_click((_e, cx) => { cx.stop_propagation(); run("New", {}); }));
  }
}
"#,
    );
    let id = mods.load(&folder, serde_json::Value::Null).unwrap();
    let frame = mods.frame(id, (200.0, 28.0), &mut MonospaceMeasure).unwrap();
    let plus = frame.hits.iter().find(|h| h.key == "plus").unwrap().rect;
    let (px, py) = (plus.x + plus.w / 2.0, plus.y + plus.h / 2.0);
    mods.pointer(id, PointerEvent::Down { x: px, y: py, button: Button::Left });
    mods.pointer(id, PointerEvent::Up { x: px, y: py, button: Button::Left });
    let names: Vec<String> = mods.take_requests().into_iter().map(|r| match r { Request::Run { name, .. } => name, _ => String::new() }).collect();
    assert_eq!(names, vec!["New"], "the + runs its own action only");
    let name = frame.hits.iter().find(|h| h.key == "name").unwrap().rect;
    let (nx, ny) = (name.x + name.w / 2.0, name.y + name.h / 2.0);
    mods.pointer(id, PointerEvent::Down { x: nx, y: ny, button: Button::Left });
    mods.pointer(id, PointerEvent::Up { x: nx, y: ny, button: Button::Left });
    let names: Vec<String> = mods.take_requests().into_iter().map(|r| match r { Request::Run { name, .. } => name, _ => String::new() }).collect();
    assert_eq!(names, vec!["Fold"], "a release elsewhere on the header bubbles to its mouse-up");
    assert!(log.borrow().is_empty(), "{:?}", log.borrow());
}

#[test]
fn a_cancelled_timer_stops_and_ids_stay_unique() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, log) = host(dir.path());
    let folder = write_mod(
        dir.path(),
        "settle",
        r#"
import { View, div } from "graffitty-ui";
export default class Settle extends View {
  init(_props, cx) {
    this.ticks = 0;
    this.other = cx.timer.every(100, () => {});
    this.id = cx.timer.every(100, (cx) => {
      this.ticks += 1;
      if (this.ticks === 2) cx.timer.cancel(this.id);
      cx.notify();
    });
  }
  render() {
    return div().child(`${this.ticks}:${this.id !== this.other}`);
  }
}
"#,
    );
    let id = mods.load(&folder, json!({})).unwrap();
    for now in [100.0, 200.0, 300.0, 400.0] {
        mods.tick(now);
    }
    mods.frame(id, (100.0, 20.0), &mut MonospaceMeasure).unwrap();
    assert_eq!(mods.texts(id), ["2:true"], "{:?}", log.borrow());
}

#[test]
fn an_overflowing_list_shows_a_scrollbar_whose_thumb_drags() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, log) = host(dir.path());
    let folder = write_mod(
        dir.path(),
        "list",
        r#"
import { View, div, v_flex } from "graffitty-ui";
export default class List extends View {
  render() {
    return v_flex().id("list").size_full().overflow_y_scrollbar()
      .children([...Array(40).keys()].map((i) => div().id(`item-${i}`).h(20).flex_none().child(String(i))));
  }
}
"#,
    );
    let id = mods.load(&folder, json!({})).unwrap();
    mods.frame(id, (200.0, 100.0), &mut MonospaceMeasure).unwrap();
    mods.pointer(id, PointerEvent::Move { x: 100.0, y: 50.0 });
    mods.frame(id, (200.0, 100.0), &mut MonospaceMeasure).unwrap();
    mods.tick(120.0);
    let frame = mods.frame(id, (200.0, 100.0), &mut MonospaceMeasure).unwrap();
    let bar = frame.draws.iter().find_map(|d| match d {
        Draw::Scrollbar { thumb, .. } => Some(*thumb),
        _ => None,
    });
    let thumb = bar.unwrap_or_else(|| panic!("an overflowing list shows its scrollbar under the pointer {:?}", log.borrow()));
    // Drag the thumb to the bottom: the list scrolls to its end.
    let (x, y) = (thumb.x + thumb.w / 2.0, thumb.y + thumb.h / 2.0);
    let down = mods.pointer(id, PointerEvent::Down { x, y, button: Button::Left });
    assert!(down.handled);
    mods.pointer(id, PointerEvent::Move { x, y: y + 200.0 });
    mods.pointer(id, PointerEvent::Up { x, y: y + 200.0, button: Button::Left });
    let frame = mods.frame(id, (200.0, 100.0), &mut MonospaceMeasure).unwrap();
    let info = frame.hits.iter().find(|h| h.key == "list").and_then(|h| h.scroll.clone()).unwrap();
    assert!((info.offset - (info.content - info.viewport)).abs() < 0.5, "{info:?}");
    // A press in the strip below the thumb jumps there; elsewhere the list is untouched.
    mods.pointer(id, PointerEvent::Down { x, y: 5.0, button: Button::Left });
    mods.pointer(id, PointerEvent::Up { x, y: 5.0, button: Button::Left });
    let frame = mods.frame(id, (200.0, 100.0), &mut MonospaceMeasure).unwrap();
    assert!(frame.hits.iter().find(|h| h.key == "list").and_then(|h| h.scroll.clone()).unwrap().offset < 1.0);
}

#[test]
fn pane_status_draws_icon_rows_that_scroll_instead_of_squashing() {
    let mut mods = Mods::new(Options { state_dir: None, log: Box::new(|level, message| panic!("{level}: {message}")), translate: Box::new(str::to_owned) }).unwrap();
    mods.set_theme(json!({"foreground": "#e4e4e7", "dim": "#8b93a1"}));
    let metrics: Vec<_> = (0..8).map(|i| json!({"id": format!("m{i}"), "icon": "cpu.svg", "value": format!("{i}%"), "tooltip": format!("Reading {i}")})).collect();
    mods.publish("resources", json!({"pane": "%1", "kind": "terminal", "label": "Pane %1", "status": "running", "status_label": "running", "message": "",
        "cpu": "1%", "memory": "1M", "metrics": metrics, "tooltip": "Pane %1 · running", "agent": {}}));
    let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../frontends/godot/project/mods/pane-status");
    let id = mods.load(&folder, json!({})).unwrap();
    let frame = mods.frame(id, (300.0, 120.0), &mut MonospaceMeasure).unwrap();
    let readout = frame.hits.iter().find(|h| h.key == "readout").unwrap();
    let info = readout.scroll.clone().expect("the readout scrolls");
    assert!(info.content > info.viewport, "{info:?}");
    let first = frame.hits.iter().find(|h| h.key == "metric-m0").unwrap();
    assert!(first.rect.h >= 18.0, "a row keeps its height: {:?}", first.rect);
    mods.pointer(id, PointerEvent::Move { x: 150.0, y: 60.0 });
    mods.frame(id, (300.0, 120.0), &mut MonospaceMeasure).unwrap();
    mods.tick(120.0);
    assert!(mods.frame(id, (300.0, 120.0), &mut MonospaceMeasure).unwrap().draws.iter().any(|d| matches!(d, Draw::Scrollbar { .. })));
    // The reading's name lives in its tooltip, not beside the value.
    let (x, y) = (first.rect.x + 4.0, first.rect.y + first.rect.h / 2.0);
    assert_eq!(mods.tooltip(id, x, y).as_deref(), Some("Reading 0"));
    assert!(!mods.texts(id).iter().any(|t| t.contains("Reading")));
    // A starting monitor and an agent: icons with tooltips, the queue count as text.
    mods.publish("resources", json!({"pane": "%2", "kind": "chromium", "label": "Chromium 2", "status": "starting", "status_label": "starting", "message": "Waiting",
        "cpu": "—", "memory": "—", "metrics": [], "tooltip": "Chromium 2 · starting\nWaiting",
        "agent": {"provider": "codex", "status": "idle", "name": "", "label": "Idle", "since": -1, "session": "Session abc", "queued": 3, "queued_label": "3 messages awaiting delivery", "detail": "note"}}));
    let frame = mods.frame(id, (300.0, 200.0), &mut MonospaceMeasure).unwrap();
    for key in ["pane", "agent", "queued", "detail"] {
        assert!(frame.hits.iter().any(|h| h.key == key), "{key} is drawn");
    }
    let queued = frame.hits.iter().find(|h| h.key == "queued").unwrap();
    assert_eq!(mods.tooltip(id, queued.rect.x + 2.0, queued.rect.y + queued.rect.h / 2.0).as_deref(), Some("3 messages awaiting delivery"));
    assert!(mods.texts(id).iter().any(|t| t == "3"));
}

/// Rows pass under a resting pointer or a finger while a list scrolls; a
/// highlight following them would read as the selection moving.
#[test]
fn scrolling_hovers_nothing_until_the_pointer_moves() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _log) = host(dir.path());
    let folder = write_mod(dir.path(), "list", r##"
import { View, div, v_flex } from "graffitty-ui";
export default class List extends View {
  render() {
    return v_flex().id("list").size_full().overflow_y_scrollbar().children(
      [...Array(20).keys()].map((i) => div().id(`row-${i}`).h(30).flex_none().hover((s) => s.bg("#ff0000")).child(`${i}`)));
  }
}
    "##);
    let id = mods.load(&folder, json!({})).unwrap();
    let reds = |mods: &mut Mods| {
        let frame = mods.frame(id, (200.0, 120.0), &mut MonospaceMeasure).unwrap();
        frame.draws.iter().filter(|d| matches!(d, Draw::Rect { color, .. } if color.r > 0.99 && color.g < 0.01)).count()
    };
    assert_eq!(reds(&mut mods), 0);
    mods.pointer(id, PointerEvent::Move { x: 50.0, y: 60.0 });
    assert_eq!(reds(&mut mods), 1, "a resting pointer hovers its row");
    let outcome = mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: 45.0, gesture: None });
    assert!(outcome.handled, "the wheel scrolls the list");
    let frame = mods.frame(id, (200.0, 120.0), &mut MonospaceMeasure).unwrap();
    assert_eq!(frame.hits.iter().find(|h| h.key == "list").unwrap().scroll.as_ref().unwrap().offset, 45.0);
    assert_eq!(reds(&mut mods), 0, "no row hovers while the list scrolls");
    mods.pointer(id, PointerEvent::Move { x: 51.0, y: 60.0 });
    assert_eq!(reds(&mut mods), 1, "moving the pointer hovers again");
}

/// A scrollbar comes with the pointer or a scroll and leaves after a rest.
#[test]
fn a_scrollbar_shows_on_hover_or_scroll_and_hides_when_idle() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _log) = host(dir.path());
    let folder = write_mod(dir.path(), "list", r##"
import { View, div, v_flex } from "graffitty-ui";
export default class List extends View {
  render() {
    return v_flex().id("list").size_full().overflow_y_scrollbar().children(
      [...Array(20).keys()].map((i) => div().id(`row-${i}`).h(30).flex_none().child(`${i}`)));
  }
}
    "##);
    let id = mods.load(&folder, json!({})).unwrap();
    let alpha = |mods: &mut Mods, now: f64| {
        mods.tick(now);
        let frame = mods.frame(id, (200.0, 120.0), &mut MonospaceMeasure).unwrap();
        let list = frame.hits.iter().find(|h| h.key == "list").unwrap();
        assert_eq!((list.rect.w, list.rect.h), (200.0, 120.0), "fading never changes layout");
        frame.draws.iter().find_map(|d| match d {
            Draw::Scrollbar { color, .. } => Some(color.a),
            _ => None,
        }).unwrap_or(0.0)
    };
    assert_eq!(alpha(&mut mods, 10_000.0), 0.0, "untouched list hides the bar");
    mods.pointer(id, PointerEvent::Move { x: 50.0, y: 60.0 });
    assert_eq!(alpha(&mut mods, 10_000.0), 0.0, "appearance starts transparently");
    let half = alpha(&mut mods, 10_060.0);
    let full = alpha(&mut mods, 10_120.0);
    assert!(half > 0.0 && half < full, "appearance has an intermediate opacity");
    assert_eq!(alpha(&mut mods, 11_200.0), full, "idle deadline starts the fade");
    let fading = alpha(&mut mods, 11_340.0);
    assert!(fading > 0.0 && fading < full, "idle fades gradually");
    assert_eq!(alpha(&mut mods, 11_480.0), 0.0);
    assert!(!mods.tick(11_500.0), "a settled scrollbar requests no more frames");
    mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: 30.0, gesture: None });
    assert_eq!(alpha(&mut mods, 11_500.0), 0.0);
    assert_eq!(alpha(&mut mods, 11_620.0), full, "touch/wheel activity fades in too");
    mods.pointer(id, PointerEvent::Leave);
    assert_eq!(alpha(&mut mods, 12_700.0), full, "a recent scroll outlasts pointer exit");
    let halfway_out = alpha(&mut mods, 12_840.0);
    mods.pointer(id, PointerEvent::Move { x: 50.0, y: 60.0 });
    assert_eq!(alpha(&mut mods, 12_840.0), halfway_out, "new activity reverses without a jump");
    let reversing = alpha(&mut mods, 12_900.0);
    assert!(reversing > halfway_out && reversing < full);
    assert_eq!(alpha(&mut mods, 12_960.0), full);
    mods.pointer(id, PointerEvent::Leave);
    assert_eq!(alpha(&mut mods, 12_960.0), full, "leaving also fades instead of blinking");
    assert!(alpha(&mut mods, 13_100.0) < full);
    assert_eq!(alpha(&mut mods, 13_240.0), 0.0);
    mods.pointer(id, PointerEvent::Down { x: 198.0, y: 60.0, button: Button::Left });
    alpha(&mut mods, 13_240.0);
    assert_eq!(alpha(&mut mods, 13_360.0), full);
    assert_eq!(alpha(&mut mods, 17_000.0), full, "a held thumb never fades while idle");
    mods.pointer(id, PointerEvent::Up { x: 198.0, y: 60.0, button: Button::Left });
    assert_eq!(alpha(&mut mods, 17_500.0), full, "release retains the idle grace period");

}

/// The compact readout keeps its values and drops the CPU and memory icons
/// when the band is too narrow, or the rail too short, for both.
#[test]
fn compact_pane_status_drops_its_metric_icons_when_short_of_room() {
    let mut mods = Mods::new(Options { state_dir: None, log: Box::new(|level, message| panic!("{level}: {message}")), translate: Box::new(str::to_owned) }).unwrap();
    mods.set_theme(json!({"foreground": "#e4e4e7", "dim": "#8b93a1"}));
    mods.publish("resources", json!({"pane": "%12", "kind": "terminal", "label": "Pane %12", "status": "running", "status_label": "running", "message": "",
        "cpu": "100.0%", "memory": "12.5G", "metrics": [], "tooltip": "Pane %12 · CPU 100.0% · Memory 12.5G",
        "agent": {"provider": "codex", "status": "idle", "name": "", "label": "Idle", "since": -1, "session": "", "queued": 0, "queued_label": "", "detail": ""}}));
    let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../frontends/godot/project/mods/pane-status");
    for (row, roomy, tight) in [(true, (400.0, 28.0), (150.0, 28.0)), (false, (48.0, 300.0), (48.0, 110.0))] {
        let id = mods.load(&folder, json!({"compact": true, "row": row})).unwrap();
        let mut icons = |size: (f32, f32)| {
            // The first frame reports the size; the mod then lays out for it.
            mods.frame(id, size, &mut MonospaceMeasure).unwrap();
            let frame = mods.frame(id, size, &mut MonospaceMeasure).unwrap();
            let texts = mods.texts(id);
            assert!(texts.iter().any(|t| t == "100.0%") && texts.iter().any(|t| t == "12.5G"), "row={row} {size:?}: the values stay");
            frame.draws.iter().filter(|d| matches!(d, Draw::Svg { path, .. } if path == "cpu.svg" || path == "ram.svg")).count()
        };
        assert_eq!(icons(roomy), 2, "row={row}: icons with room");
        assert_eq!(icons(tight), 0, "row={row}: no icons when the text would be cut");
        assert_eq!(icons(roomy), 2, "row={row}: icons return with the room");
    }
}

fn phase(began: bool, ended: bool, momentum: bool, time: f64) -> Option<graffitty_scene_core::scroll::ScrollGesture> {
    Some(graffitty_scene_core::scroll::ScrollGesture { began, ended, momentum, time: Some(time), hold_end: false })
}

fn list_mod(dir: &std::path::Path, rows: usize) -> std::path::PathBuf {
    write_mod(dir, &format!("list{rows}"), &format!(r##"
import {{ View, div, v_flex }} from "graffitty-ui";
export default class List extends View {{
  render() {{
    return v_flex().id("list").size_full().overflow_y_scrollbar().children(
      [...Array({rows}).keys()].map((i) => div().id(`row-${{i}}`).h(30).flex_none().child(`${{i}}`)));
  }}
}}
    "##))
}

/// Where the first row is painted: a pull past the top moves it down.
fn first_row_top(mods: &mut Mods, id: u64) -> f32 {
    let frame = mods.frame(id, (200.0, 120.0), &mut MonospaceMeasure).unwrap();
    frame.hits.iter().find(|h| h.key.ends_with("row-0")).map(|h| h.rect.y).unwrap_or(f32::NAN)
}

/// Trackpad and finger scrolls pull a list past its end like a terminal, and
/// the release springs back over frames.
#[test]
fn a_phased_scroll_pulls_a_list_past_its_end_and_springs_back() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _log) = host(dir.path());
    let id = mods.load(&list_mod(dir.path(), 20), json!({})).unwrap();
    mods.tick(1000.0);
    assert_eq!(first_row_top(&mut mods, id), 0.0);
    let outcome = mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: -20.0, gesture: phase(true, false, false, 1.0) });
    assert!(outcome.handled, "a pull at the top is taken by the list");
    for step in 1..=8 {
        let t = 1.0 + step as f64 * 0.016;
        mods.tick(t * 1000.0);
        mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: -20.0, gesture: phase(false, false, false, t) });
    }
    let pulled = first_row_top(&mut mods, id);
    // The terminal's curve: 160 pixels of travel past the top pull 8.
    assert!(pulled > 5.0, "the content follows the pull past the top: {pulled}");
    // The finger slides off the list; the gesture still belongs to it.
    mods.pointer(id, PointerEvent::Wheel { x: 500.0, y: 500.0, dx: 0.0, dy: 0.0, gesture: phase(false, true, false, 1.2) });
    assert!(mods.needs_frame(id), "a release keeps frames coming");
    let mut now = 1200.0;
    // Like the terminal, the release carries the finger's last velocity
    // before the spring returns it; it never crosses into the content.
    let mut crossed = false;
    while mods.needs_frame(id) && now < 5000.0 {
        now += 16.0;
        mods.tick(now);
        crossed |= first_row_top(&mut mods, id) < 0.0;
    }
    assert!(!crossed, "the release settles without overshooting the top");
    assert_eq!(first_row_top(&mut mods, id), 0.0, "the list comes to rest at its top");
    assert!(!mods.tick(now + 16.0), "a rested band requests no frames");
}

/// A flick's glide that runs into an end bounces there; once the list is
/// back at rest its momentum moves nothing, so the frontend's glide ends
/// rather than coasting on unseen (and swallowing the next tap as a brake).
/// The list still takes the momentum, so it never scrolls what is beneath.
#[test]
fn a_glide_pinned_at_an_end_stops_scrolling() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _log) = host(dir.path());
    let id = mods.load(&list_mod(dir.path(), 20), json!({})).unwrap();
    mods.tick(1000.0);
    first_row_top(&mut mods, id);
    mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: 40.0, gesture: phase(true, false, false, 1.0) });
    mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: 40.0, gesture: phase(false, false, false, 1.016) });
    first_row_top(&mut mods, id);
    let mut now = 1016.0;
    let mut taken = Vec::new();
    let mut pulled = 0.0f32;
    while now < 6000.0 {
        now += 16.0;
        mods.tick(now);
        pulled = pulled.max(first_row_top(&mut mods, id));
        let outcome = mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: -60.0, gesture: phase(false, false, true, now / 1000.0) });
        assert!(outcome.handled, "a list keeps the glide's momentum from what lies beneath");
        taken.push(outcome.scrolled);
        if !outcome.scrolled { break; }
    }
    assert!(taken[0] && pulled > 0.0, "the glide reaches the top and pulls past it: {pulled}");
    assert_eq!(taken.last(), Some(&false), "back at rest, the glide no longer scrolls: {} frames", taken.len());
}

#[test]
fn a_mouse_wheel_never_stretches_a_list() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _log) = host(dir.path());
    let id = mods.load(&list_mod(dir.path(), 20), json!({})).unwrap();
    mods.tick(1000.0);
    first_row_top(&mut mods, id);
    mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: -200.0, gesture: None });
    assert_eq!(first_row_top(&mut mods, id), 0.0);
    mods.tick(1016.0);
    assert!(!mods.needs_frame(id), "a wheel leaves no band to release");
}

/// Like a terminal with a short screen, a list whose rows fit still gives
/// under a gesture, but leaves a wheel to whatever encloses it.
#[test]
fn a_fitting_list_pulls_under_a_gesture_only() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _log) = host(dir.path());
    let id = mods.load(&list_mod(dir.path(), 2), json!({})).unwrap();
    mods.tick(1000.0);
    first_row_top(&mut mods, id);
    assert!(!mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 20.0, dx: 0.0, dy: 30.0, gesture: None }).handled);
    mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 20.0, dx: 0.0, dy: -20.0, gesture: phase(true, false, false, 1.0) });
    for step in 1..=6 {
        let t = 1.0 + step as f64 * 0.016;
        mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 20.0, dx: 0.0, dy: -20.0, gesture: phase(false, false, false, t) });
    }
    assert!(first_row_top(&mut mods, id) > 0.0, "the fitting list stretches");
}

/// A fling's momentum bounces off the end instead of stopping dead.
#[test]
fn momentum_into_an_end_bounces() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _log) = host(dir.path());
    let id = mods.load(&list_mod(dir.path(), 20), json!({})).unwrap();
    mods.tick(1000.0);
    first_row_top(&mut mods, id);
    mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: 40.0, gesture: phase(true, false, false, 1.0) });
    mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: 40.0, gesture: phase(false, false, false, 1.016) });
    first_row_top(&mut mods, id);
    let mut bounced: f32 = 0.0;
    for step in 0..40 {
        let t = 1.03 + step as f64 * 0.016;
        mods.tick(t * 1000.0);
        mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: -60.0, gesture: phase(false, false, true, t) });
        bounced = bounced.max(first_row_top(&mut mods, id));
    }
    assert!(bounced > 0.0, "momentum past the top shows the bounce: {bounced}");
    mods.pointer(id, PointerEvent::Wheel { x: 50.0, y: 60.0, dx: 0.0, dy: 0.0, gesture: phase(false, true, true, 1.7) });
    let mut now = 1700.0;
    while mods.needs_frame(id) && now < 6000.0 {
        now += 16.0;
        mods.tick(now);
        first_row_top(&mut mods, id);
    }
    assert_eq!(first_row_top(&mut mods, id), 0.0);
}

const SIDEWAYS: &str = r##"
import { View, div, h_flex, v_flex } from "graffitty-ui";
import { scrollOffset, scrollTo } from "graffitty";
globalThis.offset = scrollOffset;
globalThis.moveTo = scrollTo;
export default class extends View {
  render() {
    return h_flex().id("table").size_full().overflow_x_scrollbar().mode("always")
      .child(v_flex().id("table#x").w(480).h_full().flex_none().overflow_y_scroll().mode("always")
        .child(div().id("body").w_full().h(320).flex_none().bg("#123456")));
  }
}
"##;

fn wheel(dx: f32, dy: f32, gesture: Option<graffitty_scene_core::scroll::ScrollGesture>) -> PointerEvent {
    PointerEvent::Wheel { x: 45.0, y: 30.0, dx, dy, gesture }
}

#[test]
fn sideways_and_nested_vertical_scrolls_keep_their_axes_through_momentum() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _) = host(dir.path());
    let id = mods.load(&write_mod(dir.path(), "nested", SIDEWAYS), json!({})).unwrap();
    mods.frame(id, (160.0, 100.0), &mut MonospaceMeasure).unwrap();
    assert!(mods.pointer(id, wheel(25.0, 1.0, None)).scrolled);
    assert_eq!(mods.eval(id, "offset('table')").unwrap(), r#"{"x":25,"y":0}"#);
    mods.pointer(id, wheel(0.0, 0.0, phase(true, false, false, 1.0)));
    mods.pointer(id, wheel(15.0, 2.0, phase(false, false, false, 1.01)));
    mods.pointer(id, wheel(0.0, 0.0, Some(graffitty_scene_core::scroll::ScrollGesture {
        ended: true, hold_end: true, ..Default::default()
    })));
    mods.pointer(id, wheel(5.0, 30.0, phase(true, false, true, 1.02)));
    assert_eq!(mods.eval(id, "offset('table').x").unwrap(), "45");
    assert_eq!(mods.eval(id, "offset('table#x').y").unwrap(), "0");
    mods.pointer(id, wheel(1.0, 19.0, phase(true, false, false, 2.0)));
    mods.pointer(id, wheel(50.0, 4.0, phase(false, false, false, 2.01)));
    assert_eq!(mods.eval(id, "offset('table#x').y").unwrap(), "23");
    assert_eq!(mods.eval(id, "offset('table').x").unwrap(), "45");

    let frame = mods.frame(id, (160.0, 100.0), &mut MonospaceMeasure).unwrap();
    let bars: Vec<_> = frame.draws.iter().filter_map(|d| match d {
        Draw::Scrollbar { track, thumb, .. } => Some((*track, *thumb)),
        _ => None,
    }).collect();
    assert_eq!(bars.len(), 2);
    let (v, _) = bars[0];
    assert_eq!((v.x, v.w), (154.0, 4.0), "the wide inner list paints its bar at the visible edge");
    let (h, thumb) = bars[1];
    assert_eq!((h.y, h.h), (94.0, 4.0));
    let x = thumb.x + thumb.w / 2.0;
    let y = thumb.y + 2.0;
    mods.pointer(id, PointerEvent::Down { x, y, button: Button::Left });
    mods.pointer(id, PointerEvent::Move { x: 300.0, y });
    mods.pointer(id, PointerEvent::Up { x: 300.0, y, button: Button::Left });
    assert_eq!(mods.eval(id, "offset('table').x").unwrap(), "320");
    assert_eq!(mods.eval(id, "offset('table#x').y").unwrap(), "23");
}

#[test]
fn sideways_pulls_at_both_ends_release_even_outside_the_list() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _) = host(dir.path());
    let id = mods.load(&write_mod(dir.path(), "pull", SIDEWAYS), json!({})).unwrap();
    let body_x = |mods: &mut Mods| {
        mods.frame(id, (160.0, 100.0), &mut MonospaceMeasure).unwrap().draws.iter()
            .find_map(|d| if let Draw::Rect { rect, .. } = d { Some(rect.x) } else { None }).unwrap()
    };
    for (start, direction, rest) in [(1000.0, -1.0, 0.0), (6000.0, 1.0, -320.0)] {
        mods.tick(start);
        body_x(&mut mods);
        mods.eval(id, &format!("moveTo('table', {{ x: {} }})", -rest)).unwrap();
        for i in 0..10 {
            let now = start + 16.0 * i as f64;
            mods.tick(now);
            mods.pointer(id, wheel(direction * 20.0, 0.0, phase(i == 0, false, false, now / 1000.0)));
        }
        assert!((rest - body_x(&mut mods)) * direction > 5.0);
        mods.pointer(id, PointerEvent::Wheel { x: 500.0, y: 500.0, dx: 0.0, dy: 0.0, gesture: phase(false, true, false, (start + 160.0) / 1000.0) });
        for i in 10..240 {
            mods.tick(start + i as f64 * 16.0);
            assert!((rest - body_x(&mut mods)) * direction >= 0.0);
        }
        assert_eq!(body_x(&mut mods), rest);
        assert!(!mods.needs_frame(id));
    }
}

#[test]
fn scroll_api_preserves_the_other_axis_and_clamps_after_layout() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _) = host(dir.path());
    let source = r#"
        import { View, div } from "graffitty-ui";
        import { scrollOffset, scrollTo, props } from "graffitty";
        globalThis.offset = scrollOffset;
        globalThis.moveTo = scrollTo;
        export default class extends View {
          render() {
            return div().id("table").size_full().overflow_y_scroll().overflow_x_scroll()
              .child(div().w(props().width).h(props().height).flex_none());
          }
        }
    "#;
    let initial = json!({"width": 480, "height": 320});
    let id = mods.load(&write_mod(dir.path(), "both", source), initial.clone()).unwrap();
    mods.frame(id, (160.0, 100.0), &mut MonospaceMeasure).unwrap();
    assert_eq!(mods.eval(id, "moveTo('table', {x: 50, y: 70})").unwrap(), r#"{"x":50,"y":70}"#);
    assert_eq!(mods.eval(id, "moveTo('table', {x: 999})").unwrap(), r#"{"x":320,"y":70}"#);
    mods.set_props(id, json!({"width": 180, "height": 120}));
    mods.frame(id, (160.0, 100.0), &mut MonospaceMeasure).unwrap();
    assert_eq!(mods.eval(id, "offset('table')").unwrap(), r#"{"x":20,"y":20}"#);
    mods.set_props(id, initial);
    mods.frame(id, (160.0, 100.0), &mut MonospaceMeasure).unwrap();
    assert_eq!(mods.eval(id, "offset('table')").unwrap(), r#"{"x":20,"y":20}"#);
    assert_eq!(mods.eval(id, "moveTo('absent', {x: 50})").unwrap(), r#"{"x":0,"y":0}"#);
}

#[test]
fn a_sideways_fling_bounces_then_reports_pinned_and_its_bar_fades() {
    let dir = tempfile::tempdir().unwrap();
    let (mut mods, _) = host(dir.path());
    let id = mods.load(&write_mod(dir.path(), "fling", &SIDEWAYS.replace(".mode(\"always\")", "")), json!({})).unwrap();
    let frame = |mods: &mut Mods| mods.frame(id, (160.0, 100.0), &mut MonospaceMeasure).unwrap();
    mods.tick(1000.0);
    frame(&mut mods);
    mods.pointer(id, wheel(30.0, 0.0, phase(true, false, false, 1.0)));
    frame(&mut mods);
    let mut pulled = false;
    let mut pinned = false;
    for step in 1..180 {
        let now = 1000.0 + step as f64 * 16.0;
        mods.tick(now);
        let outcome = mods.pointer(id, wheel(-40.0, 0.0, phase(false, false, true, now / 1000.0)));
        assert!(outcome.handled);
        let scene = frame(&mut mods);
        pulled |= scene.draws.iter().any(|d| matches!(d, Draw::Rect { rect, .. } if rect.x > 0.0));
        assert!(!scene.draws.iter().any(|d| matches!(d, Draw::Scrollbar { track, .. } if track.h > track.w)));
        if !outcome.scrolled {
            pinned = true;
            assert!(scene.draws.iter().any(|d| matches!(d, Draw::Scrollbar { track, .. } if track.w > track.h)));
            break;
        }
    }
    assert!(pulled && pinned);
    mods.pointer(id, wheel(0.0, 0.0, phase(false, true, true, 4.0)));
    mods.tick(6000.0);
    frame(&mut mods);
    mods.tick(7000.0);
    assert!(!frame(&mut mods).draws.iter().any(|d| matches!(d, Draw::Scrollbar { .. })));
}
