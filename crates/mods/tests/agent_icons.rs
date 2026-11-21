use graffitty_mods::{Draw, Mods, MonospaceMeasure, Options};
use serde_json::{Value, json};

fn host() -> Mods {
    let mut mods = Mods::new(Options {
        state_dir: None,
        log: Box::new(|level, message| panic!("{level}: {message}")),
        translate: Box::new(str::to_owned),
    })
    .unwrap();
    mods.set_theme(
        json!({"foreground":"#e4e4e7", "dim":"#8b93a1", "idle":"#8b93a1", "working":"#8ab4f8",
        "hover":"#ffffff0f", "input":"#28282f", "blocked":"#ffd078", "done":"#89ddbd"}),
    );
    mods
}

fn folder(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../frontends/godot/project/mods")
        .join(name)
}

fn agent(provider: &str, status: &str) -> Value {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    json!({"provider":provider, "status":status, "name":provider, "label":status,
        "logo":if provider == "codex" { "codex.png" } else { "pi.svg" }, "symbol":"",
        "since":now - 125, "icon":"circle-x.svg", "tint":"#a0a0a0", "spinning":false,
        "tooltip":"Agent status", "session":"", "queued":0, "queued_label":"Queued", "detail":""})
}

fn assert_logo(frame: &graffitty_mods::Frame, provider: &str, offline: bool) {
    let filename = if provider == "codex" {
        "codex.png"
    } else {
        "pi.svg"
    };
    let (gray, alpha) = frame
        .draws
        .iter()
        .find_map(|draw| match draw {
            Draw::Image {
                path,
                grayscale,
                opacity,
                ..
            } if path == filename => Some((*grayscale, *opacity)),
            _ => None,
        })
        .expect("Codex and Pi use original-colour artwork, independent of text tint");
    assert_eq!(gray, offline);
    assert!((alpha - if offline { 0.55 } else { 1.0 }).abs() < 0.001);
}

#[test]
fn retained_badges_desaturate_offline_icons_without_losing_the_elapsed_time() {
    let mut mods = host();
    for provider in ["codex", "pi"] {
        for props in [
            json!({}),
            json!({"compact":true, "row":true}),
            json!({"compact":true, "row":false}),
        ] {
            let copy = mods.load(&folder("pane-status"), props).unwrap();
            for status in ["busy", "offline", "idle"] {
                mods.publish("resources", json!({"pane":"%1", "kind":"terminal", "label":"Pane", "status":"running",
                    "status_label":"Running", "cpu":"0%", "memory":"1M", "metrics":[], "tooltip":"Pane",
                    "agent":agent(provider, status)}));
                let frame = mods
                    .frame(copy, (600.0, 300.0), &mut MonospaceMeasure)
                    .unwrap();
                assert_logo(&frame, provider, status == "offline");
                assert!(
                    mods.texts(copy).iter().any(|text| text == "2m"),
                    "Duration remains visible while offline"
                );
            }
            mods.unload(copy);
        }
        let strip = mods
            .load(&folder("pane-strip"), json!({"pane":"%1"}))
            .unwrap();
        for status in ["busy", "offline", "idle"] {
            mods.publish(
                "pane/%1",
                json!({"label":"Pane", "cpu":"0%", "memory":"1M", "agent":agent(provider, status)}),
            );
            assert_logo(
                &mods
                    .frame(strip, (300.0, 200.0), &mut MonospaceMeasure)
                    .unwrap(),
                provider,
                status == "offline",
            );
        }
        let menu = mods
            .load(
                &folder("tab-menu"),
                json!({"item":{"title":"Tab", "ordinal":1}, "font_size":16,
            "foreground":"#ffffff", "background":"#202126", "badges":[agent(provider, "offline")]}),
            )
            .unwrap();
        assert_logo(
            &mods
                .frame(menu, (600.0, 100.0), &mut MonospaceMeasure)
                .unwrap(),
            provider,
            true,
        );
    }
}

#[test]
fn agents_keep_pi_coloured_and_desaturate_offline_children() {
    let mut mods = host();
    mods.publish("agents", json!([{"id":"parent", "key":"%1", "provider":"pi", "status":"working", "section":"Working",
        "title":"Live Pi", "at":0, "focused":false, "pinned":false, "subs":[
            {"key":"%2", "host_id":1, "kind":"agent", "icon":"codex", "status":"offline", "title":"Offline Codex", "lines":["└"]}
        ]}]));
    let copy = mods.load(&folder("agents"), json!({})).unwrap();
    let frame = mods
        .frame(copy, (300.0, 300.0), &mut MonospaceMeasure)
        .unwrap();
    assert_logo(&frame, "pi", false);
    assert_logo(&frame, "codex", true);
}
