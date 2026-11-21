use graffitty_mods::engine::Button;
use graffitty_mods::{Draw, Mods, MonospaceMeasure, Options, PointerEvent, Request};
use serde_json::json;

fn host() -> Mods {
    Mods::new(Options {
        state_dir: None,
        log: Box::new(|level, message| panic!("{level}: {message}")),
        translate: Box::new(str::to_owned),
    })
    .unwrap()
}

fn folder() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../frontends/godot/project/mods/pane-header")
}

fn props(width: f32) -> serde_json::Value {
    json!({"part": "header", "width": width, "terminal": true, "hovered": true,
        "gap": 4, "icon_color": "#ffffff", "tooltips": {"close": "Close pane"}})
}

#[test]
fn compact_close_is_clickable_and_does_not_overlap_title() {
    let mut mods = host();
    for width in [100.0, 170.0, 400.0] {
        let mut p = props(width);
        p["compact"] = json!(true);
        p["compact_close"] = json!(true);
        let copy = mods.load(&folder(), p).unwrap();
        let frame = mods
            .frame(copy, (width, 30.0), &mut MonospaceMeasure)
            .unwrap();
        let close = frame.hits.iter().find(|h| h.key == "close").unwrap().rect;
        let title = frame.hits.iter().find(|h| h.key == "title").unwrap().rect;
        assert_eq!((close.w, close.h), (24.0, 24.0));
        assert!(close.x + close.w <= width);
        assert!(title.x + title.w <= close.x);
        assert!(!frame.hits.iter().any(|h| h.key == "filetree"));
        let (x, y) = (close.x + close.w / 2.0, close.y + close.h / 2.0);
        mods.pointer(copy, PointerEvent::Move { x, y });
        mods.pointer(
            copy,
            PointerEvent::Down {
                x,
                y,
                button: Button::Left,
            },
        );
        mods.pointer(
            copy,
            PointerEvent::Up {
                x,
                y,
                button: Button::Left,
            },
        );
        let requests = mods.take_requests();
        assert_eq!(requests.len(), 1);
        assert!(
            matches!(&requests[0], Request::Run { copy: owner, name, args }
            if *owner == copy && name == "PaneHeaderAction" && args["action"] == "close")
        );
    }
}

#[test]
fn toolbar_preserves_sizes_hover_and_touch_visibility() {
    let mut mods = host();
    for (hover, touch, terminal) in [
        (true, false, true),
        (false, false, true),
        (false, true, true),
        (true, false, false),
    ] {
        let mut p = props(400.0);
        p["hovered"] = json!(hover);
        p["touch"] = json!(touch);
        p["terminal"] = json!(terminal);
        let copy = mods.load(&folder(), p).unwrap();
        let frame = mods
            .frame(copy, (400.0, 30.0), &mut MonospaceMeasure)
            .unwrap();
        for (action, size) in [
            ("close", 24.0),
            ("filetree", 24.0),
            ("chromium", 24.0),
            ("split_right", 28.0),
            ("split_down", 28.0),
        ] {
            let hit = frame.hits.iter().find(|h| h.key == action);
            assert_eq!(
                hit.is_some(),
                (hover || touch) && (terminal || action == "close"),
                "{action}"
            );
            if let Some(hit) = hit {
                assert_eq!((hit.rect.w, hit.rect.h), (size, size));
            }
        }
    }
}

#[test]
fn projected_title_is_mod_text_without_click_handlers() {
    let mut mods = host();
    let copy = mods
        .load(
            &folder(),
            json!({"part": "title", "text": "Terminal title", "font_size": 20, "color": "#ffffff"}),
        )
        .unwrap();
    let frame = mods
        .frame(copy, (160.0, 30.0), &mut MonospaceMeasure)
        .unwrap();
    assert!(
        frame.draws.iter().any(
            |d| matches!(d, Draw::Text { text, truncate: true, .. } if text == "Terminal title")
        )
    );
    mods.pointer(
        copy,
        PointerEvent::Down {
            x: 10.0,
            y: 10.0,
            button: Button::Left,
        },
    );
    mods.pointer(
        copy,
        PointerEvent::Up {
            x: 10.0,
            y: 10.0,
            button: Button::Left,
        },
    );
    assert!(mods.take_requests().is_empty());
}

/// A touch long press cancels the left press before it right-clicks the
/// reverse split; the canceled release must not also run the tap split.
#[test]
fn canceled_press_does_not_click_and_next_tap_still_does() {
    let mut mods = host();
    let mut p = props(400.0);
    p["touch"] = json!(true);
    let copy = mods.load(&folder(), p).unwrap();
    let frame = mods.frame(copy, (400.0, 30.0), &mut MonospaceMeasure).unwrap();
    let split = frame.hits.iter().find(|h| h.key == "split_right").unwrap().rect;
    let (x, y) = (split.x + split.w / 2.0, split.y + split.h / 2.0);
    mods.pointer(copy, PointerEvent::Down { x, y, button: Button::Left });
    mods.pointer(copy, PointerEvent::Cancel { x, y });
    assert!(mods.take_requests().is_empty(), "canceled press must not split");
    mods.pointer(copy, PointerEvent::Up { x, y, button: Button::Left });
    assert!(mods.take_requests().is_empty(), "a stray release after cancel must not split");
    mods.pointer(copy, PointerEvent::Down { x, y, button: Button::Left });
    mods.pointer(copy, PointerEvent::Up { x, y, button: Button::Left });
    let requests = mods.take_requests();
    assert!(matches!(requests.as_slice(), [Request::Run { name, args, .. }]
        if name == "PaneHeaderAction" && args["action"] == "split_right"));
}
