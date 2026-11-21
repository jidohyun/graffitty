//! Sessions rows reorder within a server; a row drag never requests a merge.
use graffitty_mods::engine::Button;
use graffitty_mods::Request;
use graffitty_mods::{Hit, Mods, MonospaceMeasure, Options, PointerEvent};
use serde_json::json;

fn frame(mods: &mut Mods, copy: u64) -> Vec<Hit> {
    mods.frame(copy, (360.0, 500.0), &mut MonospaceMeasure)
        .unwrap()
        .hits
}
fn point(hits: &[Hit], key: &str) -> (f32, f32) {
    let h = hits.iter().find(|h| h.key == key).unwrap();
    (h.rect.x + h.rect.w / 2.0, h.rect.y + h.rect.h / 2.0)
}
fn order(hits: &[Hit]) -> Vec<String> {
    let mut rows: Vec<_> = hits
        .iter()
        .filter(|h| h.key.starts_with("session-") && !h.key.contains('/'))
        .collect();
    rows.sort_by(|a, b| a.rect.y.total_cmp(&b.rect.y));
    rows.into_iter().map(|h| h.key.clone()).collect()
}
fn drag(mods: &mut Mods, copy: u64, from: (f32, f32), to: (f32, f32)) {
    mods.pointer(
        copy,
        PointerEvent::Down {
            x: from.0,
            y: from.1,
            button: Button::Left,
        },
    );
    mods.pointer(copy, PointerEvent::Move { x: to.0, y: to.1 });
    mods.pointer(
        copy,
        PointerEvent::Up {
            x: to.0,
            y: to.1,
            button: Button::Left,
        },
    );
}

#[test]
fn right_click_opens_session_menu_without_renaming_or_switching() {
    let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../frontends/godot/project/mods/sessions");
    for compact in [false, true] {
        let mut mods = Mods::new(Options {
            state_dir: None,
            log: Box::new(|level, message| panic!("{level}: {message}")),
            translate: Box::new(str::to_owned),
        })
        .unwrap();
        mods.set_theme(
            json!({"foreground":"#ffffff", "dim":"#888888", "selected":"#333333",
            "hover":"#444444", "accent":"#aabbcc", "connected":"#00ff00", "raised":"#555555"}),
        );
        mods.publish("sessions", json!([
            {"id":"local", "local":true, "connected":true, "sessions":[{"id":"$1", "name":"Local"}]},
            {"id":"remote", "name":"Remote server", "connected":true, "sessions":[{"id":"$1", "name":"Remote"}]}
        ]));
        let copy = mods.load(&folder, json!({"compact":compact})).unwrap();
        let hits = frame(&mut mods, copy);
        let (x, y) = point(&hits, "session-remote-$1");
        assert_eq!(mods.tooltip(copy, x, y).as_deref(), compact.then_some("Remote"));
        if !compact {
            let narrow = mods.frame(copy, (95.0, 500.0), &mut MonospaceMeasure).unwrap();
            let (label_x, label_y) = point(&narrow.hits, "name-session-remote-$1");
            assert_eq!(mods.tooltip(copy, label_x, label_y).as_deref(), Some("Remote"));
            frame(&mut mods, copy);
        }
        mods.pointer(
            copy,
            PointerEvent::Down {
                x,
                y,
                button: Button::Right,
            },
        );
        mods.pointer(
            copy,
            PointerEvent::Up {
                x,
                y,
                button: Button::Right,
            },
        );
        let requests = mods.take_requests();
        assert!(
            matches!(requests.as_slice(), [Request::Run { name, args, .. }]
            if name == "SessionContextMenu" && *args == json!({"server":"remote", "session":"$1"})),
            "Right-click must target the clicked server/session without any other action"
        );
    }
}

#[test]
fn reorder_is_shared_by_panel_copies_and_never_merges_sessions() {
    let mut mods = Mods::new(Options {
        state_dir: None,
        log: Box::new(|level, message| panic!("{level}: {message}")),
        translate: Box::new(str::to_owned),
    })
    .unwrap();
    mods.set_theme(
        json!({"foreground":"#ffffff", "dim":"#888888", "selected":"#333333",
        "hover":"#444444", "accent":"#aabbcc", "connected":"#00ff00", "raised":"#555555"}),
    );
    mods.publish("sessions", json!([
        {"id":"local", "local":true, "connected":true, "sessions":[
            {"id":"$1", "name":"one"}, {"id":"$2", "name":"two"}, {"id":"$3", "name":"three"}]},
        {"id":"remote", "name":"Remote", "connected":true, "sessions":[{"id":"$1", "name":"other"}]}
    ]));
    let folder = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../frontends/godot/project/mods/sessions");
    let copy = mods.load(&folder, json!({})).unwrap();
    let compact = mods.load(&folder, json!({"compact":true})).unwrap();
    let hits = frame(&mut mods, copy);
    drag(
        &mut mods,
        copy,
        point(&hits, "session-local-$1"),
        point(&hits, "session-local-$3"),
    );
    let expected = vec![
        "session-local-$2",
        "session-local-$3",
        "session-local-$1",
        "session-remote-$1",
    ];
    assert_eq!(order(&frame(&mut mods, copy)), expected);
    assert_eq!(order(&frame(&mut mods, compact)), expected);
    assert!(
        mods.take_requests().is_empty(),
        "reorder must not switch or merge"
    );
    let hits = frame(&mut mods, copy);
    drag(
        &mut mods,
        copy,
        point(&hits, "session-local-$2"),
        point(&hits, "session-remote-$1"),
    );
    assert_eq!(order(&frame(&mut mods, copy)), expected);
    assert!(
        mods.take_requests().is_empty(),
        "cross-server row drop must do nothing"
    );
    let hits = frame(&mut mods, compact);
    drag(
        &mut mods,
        compact,
        point(&hits, "session-local-$1"),
        point(&hits, "session-local-$2"),
    );
    assert_eq!(
        order(&frame(&mut mods, copy)),
        vec![
            "session-local-$1",
            "session-local-$2",
            "session-local-$3",
            "session-remote-$1"
        ]
    );
}
