//! The bundled Resource Monitor table: every pane with its samples, sortable,
//! resizable and reorderable columns, server/session filters, a pinned
//! totals row, and click-to-focus.
use graffitty_mods::engine::Button;
use graffitty_mods::{Hit, Mods, MonospaceMeasure, Options, PointerEvent, Request};
use graffitty_scene_core::scroll::ScrollGesture;
use serde_json::json;

const SIZE: (f32, f32) = (900.0, 400.0);

fn host() -> Mods {
    let mut mods = Mods::new(Options {
        state_dir: None,
        log: Box::new(|level, message| panic!("{level}: {message}")),
        translate: Box::new(str::to_owned),
    })
    .unwrap();
    mods.set_theme(json!({"chrome": "#202126", "foreground": "#e4e4e7", "dim": "#8b93a1", "muted": "#a2a4ae",
        "idle": "#8b93a1", "border": "#42444d", "hover": "#303238", "accent": "#c6a0f6", "input": "#ffffff2e",
        "popover": "#24262c", "selected": "#303238", "raised": "#303238", "background": "#202126", "surface": "#202126"}));
    mods
}

fn folder() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../frontends/godot/project/mods/resource-monitor")
}

fn row(id: &str, key: &str, title: &str, cpu: Option<f64>, memory: Option<u64>, processes: Option<u32>, pid: i64) -> serde_json::Value {
    json!({"id": id, "host": 7, "key": key, "icon": "terminal", "title": title, "focused": false, "status": "running",
        "cpu": cpu, "memory": memory, "processes": processes, "pid": pid})
}

fn publish(mods: &mut Mods) {
    mods.publish("pane_resources", json!([
        {"server": "", "local": true, "session": "main", "rows": [
            row("a", "%1", "editor", Some(10.0), Some(100 << 20), Some(2), 300),
            row("b", "%2", "build", Some(30.0), Some(2 << 30), Some(9), 100),
        ]},
        {"server": "box", "local": false, "session": "work", "rows": [
            row("c", "%3", "agent", Some(50.0), Some(50 << 20), Some(1), 200),
            row("d", "%4", "idle", None, None, None, 400),
        ]},
    ]));
}

fn hit(hits: &[Hit], key: &str) -> Hit {
    hits.iter().find(|h| h.key == key).unwrap_or_else(|| panic!("no hit {key}: {:?}", hits.iter().map(|h| &h.key).collect::<Vec<_>>())).clone()
}

fn center(h: &Hit) -> (f32, f32) {
    (h.rect.x + h.rect.w / 2.0, h.rect.y + h.rect.h / 2.0)
}

fn press(mods: &mut Mods, copy: u64, from: (f32, f32), to: (f32, f32)) {
    mods.pointer(copy, PointerEvent::Move { x: from.0, y: from.1 });
    mods.pointer(copy, PointerEvent::Down { x: from.0, y: from.1, button: Button::Left });
    if from != to {
        mods.pointer(copy, PointerEvent::Move { x: (from.0 + to.0) / 2.0, y: to.1 });
        mods.pointer(copy, PointerEvent::Move { x: to.0, y: to.1 });
    }
    mods.pointer(copy, PointerEvent::Up { x: to.0, y: to.1, button: Button::Left });
}

thread_local! {
    static NOW: std::cell::Cell<f64> = const { std::cell::Cell::new(0.0) };
}

/// Runs the copy's timers for `ms`, a 60 Hz frame at a time.
fn advance(mods: &mut Mods, ms: f64) {
    for _ in 0..(ms / 16.0) as usize {
        let now = NOW.with(|n| {
            n.set(n.get() + 16.0);
            n.get()
        });
        mods.tick(now);
    }
}

/// The settled frame: the first layout reports the panel's width, and the
/// title column takes the room left over on the next; sliding columns land.
fn frame_at(mods: &mut Mods, copy: u64, size: (f32, f32)) -> Vec<Hit> {
    mods.frame(copy, size, &mut MonospaceMeasure).unwrap();
    advance(mods, 1000.0);
    mods.frame(copy, size, &mut MonospaceMeasure).unwrap().hits
}

fn frame(mods: &mut Mods, copy: u64) -> Vec<Hit> {
    frame_at(mods, copy, SIZE)
}

/// Row ids top to bottom.
fn order(hits: &[Hit]) -> Vec<String> {
    let mut rows: Vec<&Hit> = hits.iter().filter(|h| h.key.starts_with("row-") && !h.key.contains('/')).collect();
    rows.sort_by(|a, b| a.rect.y.total_cmp(&b.rect.y));
    rows.iter().map(|h| h.key.trim_start_matches("row-").to_owned()).collect()
}

fn columns(hits: &[Hit]) -> Vec<String> {
    let mut cols: Vec<&Hit> = hits.iter().filter(|h| h.key.starts_with("col-") && !h.key.contains('/')).collect();
    cols.sort_by(|a, b| a.rect.x.total_cmp(&b.rect.x));
    cols.iter().map(|h| h.key.trim_start_matches("col-").to_owned()).collect()
}

fn texts(mods: &Mods, copy: u64) -> String {
    mods.texts(copy).join("|")
}

#[test]
fn horizontal_thumb_drags_and_stops_on_release() {
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let size = (360.0, 400.0);
    let hits = frame_at(&mut mods, copy, size);
    let columns = hit(&hits, "columns");
    let (_, thumb) = columns.scroll_x.unwrap().bar(columns.rect, 0.0);
    let start = (thumb.x + thumb.w / 2.0, thumb.y + thumb.h / 2.0);
    let before = hit(&hits, "col-cpu").rect.x;
    press(&mut mods, copy, start, (start.0 + 70.0, start.1));
    let hits = frame_at(&mut mods, copy, size);
    let after = hit(&hits, "col-cpu").rect.x;
    let offset = hit(&hits, "columns").scroll_x.unwrap().offset;
    assert!(offset > 70.0, "thumb movement scrolls the columns");
    assert!((before - after - offset).abs() < 0.5);
    assert!(mods.take_requests().is_empty(), "drag must not focus a row");
    mods.pointer(copy, PointerEvent::Move { x: start.0, y: start.1 });
    assert_eq!(hit(&frame_at(&mut mods, copy, size), "columns").scroll_x.unwrap().offset, offset);
}

#[test]
fn header_drag_survives_leave_and_resize_has_directional_cursor() {
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame(&mut mods, copy);
    let handle = center(&hit(&hits, "resize-memory"));
    assert_eq!(mods.pointer(copy, PointerEvent::Move { x: handle.0, y: handle.1 }).cursor,
        graffitty_mods::Cursor::ResizeHorizontal);
    let pid = center(&hit(&hits, "col-pid"));
    mods.pointer(copy, PointerEvent::Down { x: pid.0, y: pid.1, button: Button::Left });
    mods.pointer(copy, PointerEvent::Move { x: pid.0 - 20.0, y: pid.1 });
    mods.pointer(copy, PointerEvent::Leave);
    mods.pointer(copy, PointerEvent::Move { x: 8.0, y: -30.0 });
    frame(&mut mods, copy);
    mods.pointer(copy, PointerEvent::Move { x: 8.0, y: pid.1 });
    mods.pointer(copy, PointerEvent::Up { x: 8.0, y: pid.1, button: Button::Left });
    assert_eq!(columns(&frame(&mut mods, copy))[0], "pid", "leaving must not commit the old drop position");
    assert!(texts(&mods, copy).contains("#procs"));
    let handle = center(&hit(&frame(&mut mods, copy), "resize-memory"));
    mods.pointer(copy, PointerEvent::Down { x: handle.0, y: handle.1, button: Button::Left });
    mods.pointer(copy, PointerEvent::Leave);
    assert_eq!(mods.pointer(copy, PointerEvent::Move { x: handle.0 + 10.0, y: -30.0 }).cursor,
        graffitty_mods::Cursor::ResizeHorizontal);
    mods.pointer(copy, PointerEvent::Up { x: handle.0 + 10.0, y: -30.0, button: Button::Left });
    let width = hit(&frame(&mut mods, copy), "col-memory").rect.w;
    mods.pointer(copy, PointerEvent::Move { x: handle.0 + 50.0, y: handle.1 });
    assert_eq!(hit(&frame(&mut mods, copy), "col-memory").rect.w, width, "release outside ends resize");
}

#[test]
fn lists_panes_with_captions_and_totals() {
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame(&mut mods, copy);
    assert_eq!(order(&hits), ["a", "b", "c", "d"]);
    assert_eq!(columns(&hits), ["title", "pane", "cpu", "memory", "processes", "pid", "server", "session"]);
    let shown = texts(&mods, copy);
    for caption in ["This Computer · main", "box · work"] {
        assert!(shown.contains(caption), "{shown}");
    }
    // CPU over all servers: the mean of each server's total, (40 + 50) / 2.
    let totals = hit(&hits, "totals");
    assert!(totals.rect.y + totals.rect.h <= SIZE.1 + 0.5 && totals.rect.y > hit(&hits, "row-d").rect.y, "totals pinned under the rows");
    assert!(shown.contains("Total · 4 panes||45%|2.1G|12|"), "{shown}");
    assert!(shown.contains("|—|"), "unknown samples show a dash: {shown}");

    press(&mut mods, copy, center(&hit(&hits, "row-c")), center(&hit(&hits, "row-c")));
    let requests = mods.take_requests();
    assert!(matches!(&requests[..], [Request::Run { name, args, .. }] if name == "FocusPane" && *args == json!({"host": 7, "key": "%3"})), "{requests:?}");
}

#[test]
fn header_sorts_resizes_and_reorders() {
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame(&mut mods, copy);

    // CPU: largest first, then smallest first, then the list order. Unknown stays last.
    let cpu = center(&hit(&hits, "col-cpu"));
    press(&mut mods, copy, cpu, cpu);
    assert_eq!(order(&frame(&mut mods, copy)), ["c", "b", "a", "d"]);
    press(&mut mods, copy, cpu, cpu);
    assert_eq!(order(&frame(&mut mods, copy)), ["a", "b", "c", "d"]);
    press(&mut mods, copy, cpu, cpu);
    let hits = frame(&mut mods, copy);
    assert_eq!(order(&hits), ["a", "b", "c", "d"]);
    let pid = center(&hit(&hits, "col-pid"));
    press(&mut mods, copy, pid, pid);
    let hits = frame(&mut mods, copy);
    assert_eq!(order(&hits), ["b", "c", "a", "d"]);
    // Sorted rows from different servers each get their caption back.
    assert!(texts(&mods, copy).matches("This Computer · main").count() == 2, "{}", texts(&mods, copy));

    // Resize RAM from its right edge.
    let before = hit(&hits, "col-memory").rect.w;
    let handle = center(&hit(&hits, "resize-memory"));
    press(&mut mods, copy, handle, (handle.0 + 40.0, handle.1));
    let hits = frame(&mut mods, copy);
    assert!((hit(&hits, "col-memory").rect.w - (before + 40.0)).abs() < 1.0);
    assert_eq!(order(&hits), ["b", "c", "a", "d"], "a resize is not a sort click");

    // Drag PID to the front.
    let pid = center(&hit(&hits, "col-pid"));
    let title = hit(&hits, "col-title").rect;
    press(&mut mods, copy, pid, (title.x + 5.0, pid.1));
    let hits = frame(&mut mods, copy);
    assert_eq!(columns(&hits), ["pid", "title", "pane", "cpu", "memory", "processes", "server", "session"]);
    assert_eq!(order(&hits), ["b", "c", "a", "d"], "a reorder is not a sort click");

    // The layout and sort survive a reload of the panel, in another window too.
    let again = mods.load(&folder(), json!({"window": 2})).unwrap();
    let hits = frame(&mut mods, again);
    assert_eq!(columns(&hits)[0], "pid");
    assert_eq!(order(&hits), ["b", "c", "a", "d"]);
    // A change in one window's copy reaches the copy already open in another.
    let pid = center(&hit(&hits, "col-pid"));
    press(&mut mods, again, pid, pid);
    assert_eq!(order(&frame(&mut mods, again)), ["d", "a", "c", "b"]);
    assert_eq!(order(&frame(&mut mods, copy)), ["d", "a", "c", "b"]);
}

#[test]
fn filters_by_server_and_session_with_several_choices() {
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame(&mut mods, copy);
    let pick = |mods: &mut Mods, key: &str| {
        let at = center(&hit(&frame(mods, copy), key));
        press(mods, copy, at, at);
    };
    let ticked = |mods: &mut Mods, key: &str| {
        let tick = key.replacen("pick-", "tick-", 1);
        frame(mods, copy).iter().any(|h| h.key == tick)
    };

    let open = center(&hit(&hits, "filter-server"));
    press(&mut mods, copy, open, open);
    // All ticks every server.
    assert!(ticked(&mut mods, "pick-server-") && ticked(&mut mods, "pick-server-box") && ticked(&mut mods, "pick-server-This Computer"));
    // Unticking one server keeps the rest; the list stays open for more.
    pick(&mut mods, "pick-server-box");
    let hits = frame(&mut mods, copy);
    assert_eq!(order(&hits), ["a", "b"]);
    assert!(hits.iter().any(|h| h.key == "menu-server"), "the list stays open while choosing");
    assert!(!ticked(&mut mods, "pick-server-") && !ticked(&mut mods, "pick-server-box") && ticked(&mut mods, "pick-server-This Computer"));
    let shown = texts(&mods, copy);
    assert!(!shown.contains("This Computer · main") && shown.contains("|main|"), "the one chosen server is not repeated: {shown}");
    // One server: CPU adds up.
    assert!(shown.contains("Total · 2 panes||40%|"), "{shown}");
    // Ticking the last server back is All again.
    pick(&mut mods, "pick-server-box");
    assert!(ticked(&mut mods, "pick-server-"));
    assert_eq!(order(&frame(&mut mods, copy)), ["a", "b", "c", "d"]);
    // All clears every tick, and one choice then shows only it.
    pick(&mut mods, "pick-server-");
    assert!(order(&frame(&mut mods, copy)).is_empty());
    pick(&mut mods, "pick-server-box");
    assert_eq!(order(&frame(&mut mods, copy)), ["c", "d"]);
    // A click outside closes the list.
    let outside = center(&hit(&frame(&mut mods, copy), "row-c"));
    press(&mut mods, copy, outside, outside);
    assert!(!frame(&mut mods, copy).iter().any(|h| h.key.starts_with("menu-")));
    // The filter survives a reload.
    let again = mods.load(&folder(), json!({"window": 2})).unwrap();
    assert_eq!(order(&frame(&mut mods, again)), ["c", "d"]);

    // Every server again, then one session.
    let open = center(&hit(&frame(&mut mods, copy), "filter-server"));
    press(&mut mods, copy, open, open);
    pick(&mut mods, "pick-server-This Computer");
    assert_eq!(order(&frame(&mut mods, copy)), ["a", "b", "c", "d"]);
    let open = center(&hit(&frame(&mut mods, copy), "filter-session"));
    press(&mut mods, copy, open, open);
    pick(&mut mods, "pick-session-main");
    assert_eq!(order(&frame(&mut mods, copy)), ["c", "d"]);
    pick(&mut mods, "pick-session-main");

    // Server and session sort like any column.
    let server = hit(&frame(&mut mods, copy), "col-server").rect;
    let label = (server.x + 10.0, server.y + server.h / 2.0);
    press(&mut mods, copy, label, label);
    assert_eq!(order(&frame(&mut mods, copy)), ["c", "d", "a", "b"], "box before This Computer");
}

/// Mid-drag the column follows the pointer and the others slide aside to show
/// where it lands; the columns ease there rather than jump.
#[test]
fn dragging_a_header_previews_the_move() {
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame(&mut mods, copy);
    let pid = hit(&hits, "col-pid").rect;
    let cpu = hit(&hits, "col-cpu").rect;
    let from = center(&hit(&hits, "col-pid"));
    mods.pointer(copy, PointerEvent::Move { x: from.0, y: from.1 });
    mods.pointer(copy, PointerEvent::Down { x: from.0, y: from.1, button: Button::Left });
    let to = (cpu.x + 5.0, from.1);
    mods.pointer(copy, PointerEvent::Move { x: to.0, y: to.1 });
    mods.frame(copy, SIZE, &mut MonospaceMeasure).unwrap();
    let held = mods.frame(copy, SIZE, &mut MonospaceMeasure).unwrap().hits;
    // Under the pointer, where it was grabbed.
    assert!((hit(&held, "col-pid").rect.x - (to.0 - pid.w / 2.0)).abs() < 1.0, "{:?}", hit(&held, "col-pid").rect);
    // The column it covers has started to slide, not jumped.
    let start = hit(&held, "col-cpu").rect.x;
    advance(&mut mods, 32.0);
    let sliding = mods.frame(copy, SIZE, &mut MonospaceMeasure).unwrap().hits;
    let mid = hit(&sliding, "col-cpu").rect.x;
    assert!(mid > start + 1.0 && mid < cpu.x + pid.w - 1.0, "start {start}, mid {mid}");
    // It lands one PID width to the right; the rows' cells move with the header.
    let landed = frame(&mut mods, copy);
    assert!((hit(&landed, "col-cpu").rect.x - (cpu.x + pid.w)).abs() < 1.0);
    assert_eq!(columns(&landed)[..4], ["title", "pane", "pid", "cpu"], "the preview shows the new order before release");
    mods.pointer(copy, PointerEvent::Up { x: to.0, y: to.1, button: Button::Left });
    let after = frame(&mut mods, copy);
    assert_eq!(columns(&after)[..4], ["title", "pane", "pid", "cpu"]);
    assert!((hit(&after, "col-pid").rect.x - cpu.x).abs() < 1.0, "the dropped column eases into its slot");
}

#[test]
fn wide_title_can_reach_both_ends_regardless_of_grab_position() {
    for grab in [12.0, 90.0, 166.0] {
        let mut mods = host();
        publish(&mut mods);
        let copy = mods.load(&folder(), json!({})).unwrap();
        let hits = frame(&mut mods, copy);
        let title = hit(&hits, "col-title").rect;
        let y = title.y + title.h / 2.0;
        press(&mut mods, copy, (title.x + grab, y), (SIZE.0 - 10.0, y));
        let hits = frame(&mut mods, copy);
        assert_eq!(columns(&hits).last().unwrap(), "title", "grab {grab}: pointer reaches last slot");
        let title = hit(&hits, "col-title").rect;
        press(&mut mods, copy, (title.x + grab, y), (5.0, y));
        let hits = frame(&mut mods, copy);
        assert_eq!(columns(&hits).first().unwrap(), "title", "grab {grab}: wide title reaches first slot");
        assert_eq!(order(&hits), ["a", "b", "c", "d"], "reordering must not sort rows");
    }
}

#[test]
fn title_drag_scrolls_at_edges_until_hidden_columns_are_reachable() {
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let size = (500.0, 400.0);
    let hits = frame_at(&mut mods, copy, size);
    let resize = center(&hit(&hits, "resize-title"));
    press(&mut mods, copy, resize, (resize.0 + 900.0, resize.1));
    let hits = frame_at(&mut mods, copy, size);
    let y = center(&hit(&hits, "col-title")).1;
    mods.pointer(copy, PointerEvent::Down { x: 40.0, y, button: Button::Left });
    mods.pointer(copy, PointerEvent::Move { x: 495.0, y });
    // No further pointer movement: holding the edge must continue scrolling.
    advance(&mut mods, 3000.0);
    mods.pointer(copy, PointerEvent::Up { x: 495.0, y, button: Button::Left });
    let hits = frame_at(&mut mods, copy, size);
    assert_eq!(columns(&hits).last().unwrap(), "title");
    let right_offset = hit(&hits, "columns").scroll_x.unwrap().offset;
    assert!(right_offset > 100.0, "table actually scrolled, not just reordered");
    mods.pointer(copy, PointerEvent::Down { x: 450.0, y, button: Button::Left });
    mods.pointer(copy, PointerEvent::Move { x: 5.0, y });
    advance(&mut mods, 3000.0);
    mods.pointer(copy, PointerEvent::Up { x: 5.0, y, button: Button::Left });
    let hits = frame_at(&mut mods, copy, size);
    assert_eq!(columns(&hits).first().unwrap(), "title");
    assert!(hit(&hits, "columns").scroll_x.unwrap().offset < right_offset);
    assert!(mods.take_requests().is_empty(), "drag must not focus a pane");
}

#[test]
fn connection_summary_folds_without_focusing_or_double_counting() {
    let mut mods = host();
    let members = vec![row("a", "%1", "agent", Some(10.0), Some(100 << 20), Some(2), 300),
        row("b", "%2", "filetree", Some(20.0), Some(200 << 20), Some(3), 301)];
    let mut summary = row("group", "", "", Some(30.0), Some(300 << 20), Some(5), 0);
    summary["pid"] = json!(null);
    summary["members"] = json!(members);
    mods.publish("pane_resources", json!([{"server": "", "local": true, "session": "main", "rows": [summary]}]));
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame(&mut mods, copy);
    assert_eq!(order(&hits), ["group", "a", "b"]);
    assert!(texts(&mods, copy).contains("Total · 2 panes"));
    let fold = center(&hit(&hits, "row-group"));
    press(&mut mods, copy, fold, fold);
    assert_eq!(order(&frame(&mut mods, copy)), ["group"]);
    assert!(mods.take_requests().is_empty(), "summary is not a focus target");
    assert!(texts(&mods, copy).contains("Total · 2 panes"), "folding cannot change totals");
    press(&mut mods, copy, fold, fold);
    let hits = frame(&mut mods, copy);
    assert_eq!(order(&hits), ["group", "a", "b"]);
    let child = center(&hit(&hits, "row-b"));
    press(&mut mods, copy, child, child);
    assert!(matches!(&mods.take_requests()[..], [Request::Run { name, args, .. }] if name == "FocusPane" && args["key"] == "%2"));
}

#[test]
fn compact_rail_lists_every_pane_and_focuses() {
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({"compact": true})).unwrap();
    let hits = mods.frame(copy, (44.0, 400.0), &mut MonospaceMeasure).unwrap().hits;
    assert_eq!(order(&hits), ["a", "b", "c", "d"]);
    assert!(!hits.iter().any(|h| h.key == "header" || h.key == "totals"));
    press(&mut mods, copy, center(&hit(&hits, "row-b")), center(&hit(&hits, "row-b")));
    assert!(matches!(&mods.take_requests()[..], [Request::Run { name, args, .. }] if name == "FocusPane" && args["key"] == "%2"));
}

#[test]
fn shows_the_pane_and_sorts_it_by_number() {
    let mut mods = host();
    mods.publish("pane_resources", json!([{"server": "", "local": true, "session": "main", "rows": [
        row("a", "%10", "ten", None, None, None, 1),
        row("b", "%2", "two", None, None, None, 2),
    ]}]));
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame(&mut mods, copy);
    assert!(texts(&mods, copy).contains("|%10|"), "{}", texts(&mods, copy));
    let pane = center(&hit(&hits, "col-pane"));
    press(&mut mods, copy, pane, pane);
    assert_eq!(order(&frame(&mut mods, copy)), ["b", "a"], "%2 before %10");
}

/// A phone's panel is narrower than the columns: they slide sideways, and a
/// mostly vertical gesture still scrolls the rows.
#[test]
fn narrow_panel_scrolls_columns_sideways() {
    const NARROW: (f32, f32) = (360.0, 400.0);
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let settle = |mods: &mut Mods| frame_at(mods, copy, NARROW);
    let hits = settle(&mut mods);
    assert!(hit(&hits, "columns").scroll_x.unwrap().overflows(), "a scroll thumb shows the columns overflow");
    let session = hit(&hits, "col-session").rect;
    assert!(session.w < 1.0, "Session starts past the panel's edge: {session:?}");
    let title = hit(&hits, "col-title").rect.x;
    let row = center(&hit(&hits, "row-a"));

    // Vertical gestures do not move the columns.
    mods.pointer(copy, PointerEvent::Wheel { x: row.0, y: row.1, dx: 3.0, dy: 40.0, gesture: None });
    assert_eq!(hit(&settle(&mut mods), "col-title").rect.x, title);

    // Slide far right: the last column comes fully into view, rows follow the header.
    for _ in 0..20 {
        mods.pointer(copy, PointerEvent::Wheel { x: row.0, y: row.1, dx: 60.0, dy: 0.0, gesture: None });
    }
    let hits = settle(&mut mods);
    let session = hit(&hits, "col-session").rect;
    assert!(session.w > 99.0 && session.x + session.w <= NARROW.0 + 0.5, "{session:?}");
    assert!(hit(&hits, "col-title").rect.w < 1.0 || hit(&hits, "col-title").rect.x <= 0.5, "the title scrolled away");

    // A drag still finds its drop position after scrolling: PID after Server.
    let pid = center(&hit(&hits, "col-pid"));
    let server = hit(&hits, "col-server").rect;
    press(&mut mods, copy, pid, (server.x + server.w * 0.75, pid.1));
    let hits = settle(&mut mods);
    let cols = columns(&hits);
    let at = |name: &str| cols.iter().position(|c| c == name).unwrap();
    assert_eq!(at("pid"), at("server") + 1, "{cols:?}");
}

#[test]
fn open_filter_tracks_its_column_while_scrolling() {
    let size = (500.0, 300.0);
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame_at(&mut mods, copy, size);
    let (x, y) = center(&hit(&hits, "row-a"));
    mods.pointer(copy, PointerEvent::Wheel { x, y, dx: 160.0, dy: 0.0, gesture: None });
    let hits = frame_at(&mut mods, copy, size);
    let button = center(&hit(&hits, "filter-server"));
    press(&mut mods, copy, button, button);
    let hits = frame_at(&mut mods, copy, size);
    let before = hit(&hits, "menu-server").rect.x;
    mods.pointer(copy, PointerEvent::Wheel { x, y, dx: 120.0, dy: 0.0, gesture: None });
    let hits = frame_at(&mut mods, copy, size);
    let after = hit(&hits, "menu-server").rect.x;
    assert!(after < before);
    assert_eq!(after, hit(&hits, "col-server").rect.x);
    let (x, y) = center(&hit(&hits, "menu-server"));
    mods.pointer(copy, PointerEvent::Wheel { x, y, dx: -240.0, dy: 0.0, gesture: None });
    let hits = frame_at(&mut mods, copy, size);
    let menu = hit(&hits, "menu-server").rect;
    assert!(menu.x > after && menu.w == 200.0 && menu.x + menu.w <= size.0, "menu stays fully visible");
}

#[test]
fn phased_sideways_gesture_stretches_and_springs_back_at_both_ends() {
    let size = (360.0, 300.0);
    let mut mods = host();
    publish(&mut mods);
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame_at(&mut mods, copy, size);
    let max = hit(&hits, "columns").scroll_x.unwrap().max_offset();
    assert!(max > 0.0);
    let (x, y) = center(&hit(&hits, "row-a"));
    for (column, delta, edge) in [("col-title", -24.0, 0.0), ("col-session", 24.0, max)] {
        mods.pointer(copy, PointerEvent::Wheel { x, y, dx: edge, dy: 0.0, gesture: None });
        let hits = frame_at(&mut mods, copy, size);
        let rest = hit(&hits, column).rect.x;
        for step in 0..8 {
            advance(&mut mods, 16.0);
            let time = Some(NOW.with(|n| n.get()) / 1000.0);
            let gesture = Some(ScrollGesture { began: step == 0, ended: false, momentum: false, time, hold_end: false });
            mods.pointer(copy, PointerEvent::Wheel { x, y, dx: delta, dy: 0.0, gesture });
        }
        let pulled = mods.frame(copy, size, &mut MonospaceMeasure).unwrap().hits;
        assert_eq!(hit(&pulled, "columns").scroll_x.unwrap().offset, edge);
        assert!((rest - hit(&pulled, column).rect.x) * delta.signum() > 5.0, "{column} stretches past its edge");
        let time = Some(NOW.with(|n| n.get()) / 1000.0);
        let gesture = Some(ScrollGesture { began: false, ended: true, momentum: false, time, hold_end: false });
        mods.pointer(copy, PointerEvent::Wheel { x, y, dx: 0.0, dy: 0.0, gesture });
        let settled = frame_at(&mut mods, copy, size);
        assert_eq!(hit(&settled, column).rect.x, rest, "{column} springs back");
        assert_eq!(hit(&settled, "columns").scroll_x.unwrap().offset, edge);
    }
}

#[test]
fn rows_scroll_vertically_under_the_header() {
    let mut mods = host();
    let rows: Vec<_> = (0..30).map(|i| row(&format!("r{i}"), &format!("%{i}"), "pane", Some(1.0), Some(1 << 20), Some(1), i)).collect();
    mods.publish("pane_resources", json!([{"server": "", "local": true, "session": "main", "rows": rows}]));
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame(&mut mods, copy);
    let scroller = hit(&hits, "rows");
    let info = scroller.scroll.clone().expect("the rows scroll");
    assert!(info.overflows(), "{info:?}");
    let first = hit(&hits, "row-r8").rect.y;
    let (x, y) = center(&hit(&hits, "row-r1"));
    let outcome = mods.pointer(copy, PointerEvent::Wheel { x, y, dx: 0.0, dy: 120.0, gesture: None });
    assert!(outcome.handled);
    let hits = frame(&mut mods, copy);
    assert!((hit(&hits, "row-r8").rect.y - (first - 120.0)).abs() < 0.5, "a wheel over the rows scrolls them");
    assert!(hit(&hits, "row-r0").rect.h == 0.0, "a row scrolled out is not hittable");
    assert!((hit(&hits, "header").rect.y - 0.0).abs() < 0.5 && hit(&hits, "totals").rect.y > hit(&hits, "rows").rect.y, "the header and totals stay");
}

/// A long list scrolls vertically, yet a sideways gesture over its rows still
/// slides the columns: the rows' vertical scroller must not swallow it.
#[test]
fn sideways_gestures_over_a_scrolling_list_move_the_columns() {
    const NARROW: (f32, f32) = (360.0, 300.0);
    let mut mods = host();
    let rows: Vec<_> = (0..30).map(|i| row(&format!("r{i}"), &format!("%{i}"), "pane", Some(1.0), Some(1 << 20), Some(1), i)).collect();
    mods.publish("pane_resources", json!([{"server": "", "local": true, "session": "main", "rows": rows}]));
    let copy = mods.load(&folder(), json!({})).unwrap();
    let hits = frame_at(&mut mods, copy, NARROW);
    assert!(hit(&hits, "rows").scroll.clone().is_some_and(|s| s.overflows()));
    let cpu = hit(&hits, "col-cpu").rect.x;
    let (x, y) = center(&hit(&hits, "row-r2"));
    let outcome = mods.pointer(copy, PointerEvent::Wheel { x, y, dx: 80.0, dy: 2.0, gesture: None });
    assert!(outcome.handled);
    let hits = frame_at(&mut mods, copy, NARROW);
    assert!((hit(&hits, "col-cpu").rect.x - (cpu - 80.0)).abs() < 1.0, "the columns slid sideways");
    assert_eq!(hit(&hits, "rows").scroll.unwrap().offset, 0.0, "the rows did not scroll down");
    // Vertical still scrolls the rows, not the columns.
    let cpu = hit(&hits, "col-cpu").rect.x;
    mods.pointer(copy, PointerEvent::Wheel { x, y, dx: 2.0, dy: 80.0, gesture: None });
    let hits = frame_at(&mut mods, copy, NARROW);
    assert_eq!(hit(&hits, "col-cpu").rect.x, cpu);
    assert!(hit(&hits, "rows").scroll.unwrap().offset > 70.0);
}
