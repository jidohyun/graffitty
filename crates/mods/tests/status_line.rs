use graffitty_mods::{Draw, Mods, MonospaceMeasure, Options};
use serde_json::json;

/// The theme's `working` yellow, #ffd078.
fn yellow(color: &graffitty_mods::value::Color) -> bool {
    let near = |value: f32, byte: f32| (value * 255.0 - byte).abs() < 1.0;
    near(color.r, 255.0) && near(color.g, 208.0) && near(color.b, 120.0)
}

fn host() -> Mods {
    let mut mods = Mods::new(Options {
        state_dir: None,
        log: Box::new(|level, message| panic!("{level}: {message}")),
        translate: Box::new(str::to_owned),
    })
    .unwrap();
    mods.set_theme(json!({"foreground": "#e4e4e7", "muted": "#a2a4ae", "dim": "#8b93a1",
        "chrome": "#202126", "hover": "#303238", "accent": "#c6a0f6", "working": "#ffd078",
        "blocked": "#ff8080"}));
    mods.publish("agents", json!([]));
    mods.publish("effects", json!({"disabled": []}));
    mods
}

fn session(video: serde_json::Value) -> serde_json::Value {
    json!({"id": "$1", "name": "work", "server": "ws://192.0.2.1:7183", "local": false,
        "connected": true, "video": video})
}

fn folder() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../frontends/godot/project/mods/status-line")
}

#[test]
fn websocket_video_warns_in_yellow_with_its_reason_in_the_tooltip() {
    let mut mods = host();
    mods.publish("session", session(json!({"streaming": true, "transport": "websocket",
        "reason": "no_reply", "address": "192.0.2.1:7183"})));
    let copy = mods.load(&folder(), json!({"width": 1400})).unwrap();
    let frame = mods.frame(copy, (1400.0, 28.0), &mut MonospaceMeasure).unwrap();
    let warning = frame.hits.iter().find(|h| h.key == "video-transport").expect("a warning");
    assert!(frame.draws.iter().any(|d| matches!(d, Draw::Text { text, color, .. }
        if text == "WebSocket video" && yellow(color))), "{:?}", frame.draws);
    assert!(frame.draws.iter().any(|d| matches!(d, Draw::Svg { path, color, .. }
        if path == "triangle-alert.svg" && yellow(color))));
    let r = warning.rect;
    let tooltip = mods.tooltip(copy, r.x + r.w / 2.0, r.y + r.h / 2.0).unwrap();
    assert!(tooltip.contains("a lost packet delays the whole connection"), "{tooltip}");
    assert!(tooltip.contains("No UDP reply from 192.0.2.1:7183."), "{tooltip}");

    // Narrow lines keep only the mark; its tooltip still explains.
    let narrow = mods.load(&folder(), json!({"width": 240})).unwrap();
    let frame = mods.frame(narrow, (240.0, 28.0), &mut MonospaceMeasure).unwrap();
    assert!(frame.draws.iter().any(|d| matches!(d, Draw::Svg { path, color, .. }
        if path == "triangle-alert.svg" && yellow(color))));
    assert!(!frame.draws.iter().any(|d| matches!(d, Draw::Text { text, .. } if text == "WebSocket video")));
}

#[test]
fn datagram_video_idle_sessions_and_local_sessions_show_no_warning() {
    for video in [
        json!({"streaming": true, "transport": "datagram", "address": "192.0.2.1:7183"}),
        json!({"streaming": false, "transport": "websocket", "reason": "unoffered"}),
        json!({}),
    ] {
        let mut mods = host();
        mods.publish("session", session(video.clone()));
        let copy = mods.load(&folder(), json!({"width": 1400})).unwrap();
        let frame = mods.frame(copy, (1400.0, 28.0), &mut MonospaceMeasure).unwrap();
        assert!(!frame.hits.iter().any(|h| h.key == "video-transport"), "{video}");
    }
}

#[test]
fn only_switches_are_interactive_so_a_compact_band_drags_from_the_rest() {
    let mut mods = host();
    mods.publish("session", session(json!({})));
    let copy = mods.load(&folder(), json!({"width": 1400})).unwrap();
    let frame = mods.frame(copy, (1400.0, 28.0), &mut MonospaceMeasure).unwrap();
    let switch = frame.hits.iter().find(|h| h.handlers.iter().any(|h| h.0 == "on_click")).expect("a switch");
    let r = switch.rect;
    assert!(mods.interactive_at(copy, r.x + r.w / 2.0, r.y + r.h / 2.0), "{}", switch.key);
    let session = frame.hits.iter().find(|h| h.key == "session").expect("the session label");
    let r = session.rect;
    assert!(!mods.interactive_at(copy, r.x + r.w / 2.0, r.y + r.h / 2.0), "a label is a drag area");
    assert!(!mods.interactive_at(copy, 2.0, 2.0), "the line's padding is a drag area");
}
