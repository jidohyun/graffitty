use graffitty_client_config::bindings::{Action, Platform, Shortcut};
use graffitty_client_config::config::*;
use std::path::{Path, PathBuf};

fn doc(source: &str) -> toml::Table {
    parse(
        source,
        Path::new("/cfg/client.toml"),
        &Dirs::home("/home/u"),
    )
    .unwrap()
}
fn error(source: &str) -> String {
    parse(source, Path::new("/cfg/client.toml"), &Dirs::default()).unwrap_err()
}

#[test]
fn desktop_ui_scale_accepts_auto_or_a_fixed_factor() {
    for (value, expected) in [("'auto'", UiScale::Auto), ("2", UiScale::Fixed(2.0)), ("1.25", UiScale::Fixed(1.25))] {
        let document = doc(&format!("[window]\nui_scale = {value}"));
        let resolved = resolve_documents(vec![document], Platform::Windows).unwrap();
        assert_eq!(resolved.settings.window.unwrap().ui_scale, Some(expected));
    }
    for value in ["0", "-1", "nan", "inf", "1e100", "1e-100", "'1.5'", "'automatic'", "true"] {
        error(&format!("[window]\nui_scale = {value}"));
    }
}

#[test]
fn linux_window_decorations() {
    for (value, expected) in [("client", WindowDecorations::Client), ("system", WindowDecorations::System)] {
        let resolved = resolve_documents(vec![doc(&format!("[window]\ndecorations = '{value}'"))], Platform::Linux).unwrap();
        assert_eq!(resolved.settings.window.unwrap().decorations, Some(expected));
    }
    error("[window]\ndecorations = 'auto'");
    error("[window]\ndecorations = 'borderless'");
}

#[test]
fn documented_example_resolves() {
    let resolved = resolve_documents(
        vec![doc(r##"
        language = "ko"
        [world]
        path = "~/worlds/bistro.pck"
        [window]
        max_fps = 120
        macos.blur_radius = 30
        windows.blur_material = "mica"
        [tiling]
        enabled = false
        gap = 4
        [terminal]
        font_size = 18
        font_regular_path = "fonts/Mono.ttf"
        foreground = "#eeeeee"
        selection_foreground = "none"
        palette_overrides = { "17" = "#123456" }
        symbol_maps = [{ first = 0xE000, last = 0xF8FF, family = "Symbols Nerd Font" }]
        [terminal.background]
        alpha = 0.9
        [terminal.effects.cursor_trail]
        style = "smear"
        decay = [0.1, 0.5]
        [prefix]
        key = { macos = "Cmd+A", linux = "Ctrl+Shift+A" }
        [bindings]
        NewTab = ["CmdOrCtrl+T", "Prefix+C"]
        [[menu.items]]
        label = "View::World::Bistro"
        action = "SwitchWorld"
        path = "~/worlds/bistro.pck"
        os = ["macos"]
        [[menu.items]]
        label = "Shell::Work Browser"
        action = "NewChromium"
        profile = "work"
        [[rules]]
        event = "app_changed"
        app = ["nvim"]
        action = "SettleEffects"
        include = ["typing"]
    "##)],
        Platform::Linux,
    )
    .unwrap();
    let terminal = resolved.settings.terminal.as_ref().unwrap();
    assert_eq!(
        terminal.font_regular_path.as_deref(),
        Some("/cfg/fonts/Mono.ttf")
    );
    assert_eq!(
        resolved.settings.world.unwrap().path.as_deref(),
        Some("/home/u/worlds/bistro.pck")
    );
    assert_eq!(
        resolved.menu.as_ref().unwrap().len(),
        1,
        "macOS-only entries are filtered out"
    );
    assert_eq!(resolved.rules.unwrap().len(), 1);
    assert_eq!(
        resolved.bindings.prefix,
        Shortcut::parse("Ctrl+Shift+A", Platform::Linux)
            .unwrap()
            .chord
    );
    assert_eq!(
        resolved
            .bindings
            .action_for(&Shortcut::parse("Ctrl+T", Platform::Linux).unwrap()),
        Some(Action::NewTab)
    );
    let mac = resolve_documents(vec![doc("[[menu.items]]\nlabel='View::World::Bistro'\naction='SwitchWorld'\npath='~/c.pck'\nos=['macos']")], Platform::Macos).unwrap();
    assert_eq!(mac.menu.unwrap()[0].path.as_deref(), Some("/home/u/c.pck"));
}

#[test]
fn stdpath_placeholders_expand_in_path_fields() {
    let dirs = Dirs {
        home: Some("/home/u".into()),
        config: Some("/xdg/config/graffitty".into()),
        data: Some("/xdg/data/graffitty".into()),
        cache: Some("/xdg/cache/graffitty".into()),
        state: Some("/xdg/state/graffitty".into()),
    };
    let table = parse(
        "[world]\npath = '%(data)/worlds/bistro/bistro.pck'\n\
         [power]\nbattery_world = 'bistro'\nexternal_world = '%(cache)/w.pck'\n\
         [sounds]\ndone = '%(config)/done.ogg'\nblocked = '%(state)'\n\
         [terminal]\nfont_regular_path = '%(data)/fonts/Mono.ttf'\n\
         [[menu.items]]\nlabel = 'View::World::Bistro'\naction = 'SwitchWorld'\npath = '%(data)/worlds/bistro/bistro.pck'",
        Path::new("/cfg/client.toml"),
        &dirs,
    )
    .unwrap();
    assert_eq!(table["world"]["path"].as_str(), Some("/xdg/data/graffitty/worlds/bistro/bistro.pck"));
    assert_eq!(table["power"]["battery_world"].as_str(), Some("bistro"), "a world id is not a path");
    assert_eq!(table["power"]["external_world"].as_str(), Some("/xdg/cache/graffitty/w.pck"));
    assert_eq!(table["sounds"]["done"].as_str(), Some("/xdg/config/graffitty/done.ogg"));
    assert_eq!(table["sounds"]["blocked"].as_str(), Some("/xdg/state/graffitty"));
    assert_eq!(table["terminal"]["font_regular_path"].as_str(), Some("/xdg/data/graffitty/fonts/Mono.ttf"));
    assert_eq!(table["menu"]["items"][0]["path"].as_str(), Some("/xdg/data/graffitty/worlds/bistro/bistro.pck"));
    for (path, message) in [
        ("%(temp)/w.pck", "unknown placeholder %(temp)"),
        ("%(data", "unterminated"),
        ("%(data)worlds", "followed by /"),
        ("%(data)/", "followed by /"),
    ] {
        let error = parse(&format!("[world]\npath = '{path}'"), Path::new("/cfg/client.toml"), &dirs).unwrap_err();
        assert!(error.contains(message), "{path}: {error}");
    }
    let error = parse("[world]\npath = '%(data)/w.pck'", Path::new("/cfg/client.toml"), &Dirs::home("/home/u")).unwrap_err();
    assert!(error.contains("data directory is unknown"), "{error}");
    assert_eq!(
        Dirs::home("/home/u").expand("~user/w.pck").unwrap(),
        "~user/w.pck",
        "only ~ and ~/ name the home directory"
    );
    assert_eq!(
        Dirs::home("C:/Users/u").expand("~/worlds/w.pck").unwrap(),
        "C:/Users/u/worlds/w.pck",
        "the path keeps its / on Windows too"
    );
}

#[test]
fn rejects_unknown_keys_types_colors_and_enumerations() {
    for source in [
        "unknown = 1",
        "[terminal]\nfont_size = '18'",
        "[terminal]\nfont_sise = 18",
        "[terminal]\nforeground = 'white'",
        "[terminal]\nforeground = '#12345'",
        "[terminal]\ncursor_shape = 'triangle'",
        "[terminal]\npalette = ['#000000']",
        "[terminal]\npalette_overrides = { '256' = '#000000' }",
        "[terminal]\nkey_bindings = []",
        "[window]\nwindows.blur_material = 'glass'",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'new_tab'",
        "[[menu.items]]\nlabel = 'Shell'\naction = 'NewTab'",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'SwitchWorld'",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'NewTab'\npath = 'x'",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'NewTab'\nshortcut = 'Ctrl+T'",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'NewTab'\nos = ['darwin']",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'NewTab'\nos = []",
        "[[menu.items]]\nlabel='A::B'\naction='NewTab'\n[[menu.items]]\nlabel='A::B::C'\naction='NewTab'",
        "[[rules]]\nevent = 'app_changed'\naction = 'DisableEffects'",
        "[[rules]]\nevent = 'active'\naction = 'SettleEffects'",
        "[[rules]]\nevent = 'app_changed'\naction = 'settle'",
        "[bindings]\nNewTab = 'Primary+T'",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'SendText'",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'NewTab'\ntext = 'x'",
        "[[menu.items]]\nlabel = 'Shell::X'\naction = 'Ignore'",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'SetWorldSetting'\nsetting = 'weather.kind'\nvalue = 'none'",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'SetWorldSetting'\nworld = 'my-world'\nvalue = 'none'",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'SetWorldSetting'\nworld = 'my-world'\nsetting = 'weather.kind'",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'SetWorldSetting'\nworld = 'my-world'\nsetting = 'Weather.Kind'\nvalue = 'none'",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'SetWorldSetting'\nworld = 'my-world'\nsetting = 'weather..kind'\nvalue = 'none'",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'SetWorldSetting'\nworld = 'my-world'\nsetting = 'terminal.font_size'\nvalue = 20",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'SetWorldSetting'\nworld = 'my-world'\nsetting = 'weather'\nvalue = { kind = 'none' }",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'NewTab'\nsetting = 'weather.kind'",
        "[[menu.items]]\nlabel = 'View::Snow'\naction = 'NewTab'\nworld = ' '",
        "[[menu.items]]\nlabel='View::Snow'\naction='NewTab'\nworld='my-world'\n[[menu.items]]\nlabel='View::Snow'\naction='NewTab'",
    ] {
        let message = error(source);
        assert!(
            message.starts_with("/cfg/client.toml: "),
            "{source}: {message}"
        );
    }
}

#[test]
fn platform_scoped_duplicate_labels_are_allowed() {
    doc(
        "[[menu.items]]\nlabel='A::B'\naction='NewTab'\nos=['macos']\n[[menu.items]]\nlabel='A::B'\naction='NewWindow'\nos=['linux','windows']",
    );
}

#[test]
fn overlays_merge_tables_and_replace_bindings_per_action() {
    let first = doc(
        "[terminal]\nfont_size = 18\nligatures = false\n[bindings]\nNewTab = { macos = 'Cmd+T', linux = 'Ctrl+T' }\nFocusLeft = 'Alt+H'",
    );
    let second = doc("[terminal]\nfont_size = 20\n[bindings]\nNewTab = { macos = 'Cmd+Y' }");
    let linux = resolve_documents(vec![first.clone(), second.clone()], Platform::Linux).unwrap();
    let terminal = linux.settings.terminal.unwrap();
    assert_eq!(
        (terminal.font_size, terminal.ligatures),
        (Some(20), Some(false))
    );
    let key = |text| Shortcut::parse(text, Platform::Linux).unwrap();
    assert_eq!(
        linux.bindings.action_for(&key("Ctrl+T")),
        None,
        "the later NewTab value replaced the earlier OS map"
    );
    assert_eq!(
        linux.bindings.action_for(&key("Ctrl+Shift+T")),
        Some(Action::NewTab),
        "Linux falls back to defaults"
    );
    assert_eq!(
        linux.bindings.action_for(&key("Alt+H")),
        Some(Action::FocusLeft)
    );
}

#[test]
fn missing_and_unreadable_files_report_their_path() {
    let missing = PathBuf::from("/nonexistent/graffitty/client.toml");
    assert!(
        load(&[missing], Platform::Linux, &Dirs::default())
            .unwrap_err()
            .contains("/nonexistent/graffitty/client.toml")
    );
}

#[test]
fn defaults_resolve_without_conflicts_on_every_platform() {
    for platform in Platform::ALL {
        let resolved = resolve_documents(vec![], platform).unwrap();
        assert!(resolved.menu.is_none() && resolved.rules.is_none());
        assert!(!resolved.bindings.shortcuts_for(Action::NewTab).is_empty());
    }
}

#[test]
fn world_tables_are_opaque_and_layer() {
    let first = doc(
        "[worlds.flat-3d.terminal_window]\nblur_radius = 8\npadding = [1, 2, 3, 4]\n[worlds.some-plugin]\nanything = { nested = true }\nlevels = 3",
    );
    let second = doc("[worlds.flat-3d.terminal_window]\nblur_radius = 4");
    let resolved = resolve_documents(vec![first, second], Platform::Linux).unwrap();
    let worlds = resolved.settings.worlds.unwrap();
    let window = &worlds["flat-3d"]["terminal_window"];
    assert_eq!(window["blur_radius"].as_integer(), Some(4));
    assert_eq!(
        window["padding"].as_array().unwrap().len(),
        4,
        "later files merge key by key"
    );
    assert_eq!(
        worlds["some-plugin"]["levels"].as_integer(),
        Some(3),
        "unknown worlds' tables pass through"
    );
    for source in ["[worlds]\nflat = 1", "[worlds.'../x']\na = 1"] {
        parse(source, Path::new("/c.toml"), &Dirs::default()).unwrap();
    }
    assert!(parse("worlds = 1", Path::new("/c.toml"), &Dirs::default()).is_err());
}

#[test]
fn send_text_menu_entries_keep_their_text() {
    let resolved = resolve_documents(
        vec![doc(
            "[[menu.items]]\nlabel = 'Edit::Home'\naction = 'SendText'\ntext = \"\\u0001\"",
        )],
        Platform::Linux,
    )
    .unwrap();
    assert_eq!(resolved.menu.unwrap()[0].text.as_deref(), Some("\u{1}"));
}

#[test]
fn effect_profiles_use_inline_settings_and_validate_names() {
    let resolved = resolve_documents(
        vec![
            doc("[effects]\nprofile = 'calm'"),
            doc("[effects.profiles.calm.camera]\ndrift_px = 7.0\n[effects.profiles.home.camera]\nzoom = 1.2"),
        ],
        Platform::Macos,
    )
    .unwrap();
    let effects = resolved.settings.effects.unwrap();
    assert_eq!(effects.profile.as_deref(), Some("calm"));
    let profiles = effects.profiles.unwrap();
    assert_eq!(profiles["calm"].camera.as_ref().unwrap().drift_px, Some(7.0));
    assert_eq!(profiles["home"].camera.as_ref().unwrap().zoom, Some(1.2));
    for builtin in BUILTIN_EFFECT_PROFILES {
        let source = format!("[effects]\nprofile = '{builtin}'");
        resolve_documents(vec![doc(&source)], Platform::Linux).unwrap();
    }
    for source in [
        "[effects.profiles.mild.camera]\nzoom = 1.2",
        "[effects.profiles.My.camera]\nzoom = 1.2",
        "[effects.profiles]\ncalm = ''",
        "[effects]\nprofiles = { calm = 1 }",
        "[effects]\nunknown = 1",
    ] {
        assert!(error(source).starts_with("/cfg/client.toml: "), "{source}");
    }
    let missing = resolve_documents(vec![doc("[effects]\nprofile = 'nope'")], Platform::Linux);
    assert!(missing.unwrap_err().contains("effects.profile"));
}

#[test]
fn touch_defaults_keep_the_shipped_strip_and_buttons() {
    let touch = resolve_documents(vec![], Platform::Android).unwrap().settings.touch;
    assert_eq!(touch.keys.unwrap(), DEFAULT_TOUCH_KEYS.map(TouchKey::Key).to_vec());
    assert_eq!(touch.buttons.unwrap(), DEFAULT_TOUCH_BUTTONS.to_vec());
}

#[test]
fn touch_lists_choose_order_and_action_keys() {
    let touch = resolve_documents(
        vec![doc(r#"
[touch]
keys = ["ctrl", "escape", { label = "⌃A", action = "TogglePrefix" }, { label = "|", action = "SendText", text = "|" }]
buttons = ["microphone"]
"#)],
        Platform::Android,
    )
    .unwrap()
    .settings
    .touch;
    let keys = touch.keys.unwrap();
    assert_eq!(keys[0], TouchKey::Key(TouchKeyName::Ctrl));
    assert_eq!(keys[1], TouchKey::Key(TouchKeyName::Escape));
    assert!(matches!(&keys[2], TouchKey::Action(a) if a.action == Action::TogglePrefix && a.label == "⌃A" && a.text.is_none()));
    assert!(matches!(&keys[3], TouchKey::Action(a) if a.action == Action::SendText && a.text.as_deref() == Some("|")));
    assert_eq!(touch.buttons.unwrap(), vec![TouchButton::Microphone]);
    // One list omitted keeps that list's defaults; an empty list removes everything.
    let touch = resolve_documents(vec![doc("[touch]\nbuttons = []\n")], Platform::Android).unwrap().settings.touch;
    assert_eq!(touch.keys.unwrap().len(), DEFAULT_TOUCH_KEYS.len());
    assert!(touch.buttons.unwrap().is_empty());
}

#[test]
fn touch_rejects_unknown_duplicate_and_unsupported_entries() {
    // Schema errors surface while parsing a document; list rules while resolving.
    let reject = |source: &str| match parse(source, Path::new("/cfg/client.toml"), &Dirs::default()) {
        Err(error) => error,
        Ok(table) => resolve_documents(vec![table], Platform::Android).unwrap_err(),
    };
    assert!(reject("[touch]\nkeys = [\"meta\"]\n").contains("unknown touch key \"meta\""), "{}", reject("[touch]\nkeys = [\"meta\"]\n"));
    assert!(reject("[touch]\nkeys = [\"ctrl\", \"ctrl\"]\n").contains("touch.keys lists ctrl twice"));
    assert!(reject("[touch]\nbuttons = [\"keyboard\", \"keyboard\"]\n").contains("touch.buttons lists keyboard twice"));
    assert!(reject("[touch]\nbuttons = [\"monitor\"]\n").contains("monitor"));
    assert!(reject("[touch]\nkeys = [{ label = \"x\", action = \"SendText\" }]\n").contains("SendText requires a nonempty text"));
    assert!(reject("[touch]\nkeys = [{ label = \"x\", action = \"Agents\", text = \"a\" }]\n").contains("only SendText has one"));
    assert!(reject("[touch]\nkeys = [{ label = \" \", action = \"Agents\" }]\n").contains("nonempty label"));
    assert!(reject("[touch]\nkeys = [{ label = \"x\", action = \"OpenPanel\" }]\n").contains("cannot be a touch key"));
    assert!(reject("[touch]\nkeys = [{ label = \"x\", action = \"Nope\" }]\n").contains("touch key"));
    assert!(reject("[touch]\nhold = true\n").contains("hold"));
}

#[test]
fn effect_tuning_normalizes_and_rejects_invalid_settings() {
    let source = "[effects.camera]\nzoom = 1.8\nzoom_mode = 'typing'\n[effects.sheet]\nripple = 1.5\n[effects.splash]\nscale = 2.5";
    let resolved = resolve_documents(vec![doc(source)], Platform::Linux).unwrap();
    let effects = resolved.settings.effects.unwrap();
    let options = effects.tuning().options();
    assert!(options.iter().any(|(section, key, value)| section == "state.typing" && key == "camera.zoom" && value == &serde_json::json!(1.8)));
    assert!(options.iter().any(|(section, key, value)| section == "scene.typing" && key == "splash_scale" && value == &serde_json::json!(2.5)));
    for source in [
        "[effects.weather]\nkind = 'snow'",
        "[effects.camera]\nzoom = -1.0",
        "[effects.camera]\nzoom_mode = 'wrong'",
        "[effects.camera.adaptive_group]\nmain_view = 0.5",
        "[effects.camera.adaptive_group]\nfiletree = 2.0",
        "[effects.profiles.calm.camera]\ndrift_px = -3.0",
        "[effects.profiles]\ncalm = 'calm.conf'",
    ] { assert!(!error(source).is_empty(), "{source}"); }
    for options in effects.profile_options().values() { assert!(!options.is_empty()); }
}

#[test]
fn world_setting_entries_are_scoped_to_their_world() {
    let resolved = resolve_documents(
        vec![doc(r#"
        [[menu.items]]
        label = "View::Weather::Off"
        action = "SetWorldSetting"
        world = "my-world"
        setting = "weather.kind"
        value = "none"

        [[menu.items]]
        label = "View::Weather::Off"
        action = "SetWorldSetting"
        world = "other-world"
        setting = "rain.enabled"
        value = false

        [[menu.items]]
        label = "View::Weather::Heavy"
        action = "SetWorldSetting"
        world = "my-world"
        setting = "weather.intensity"
        value = 3.5
        "#)],
        Platform::Macos,
    )
    .unwrap();
    let menu = resolved.menu.unwrap();
    assert_eq!(menu.len(), 3);
    assert_eq!(menu[0].world.as_deref(), Some("my-world"));
    assert_eq!(menu[0].setting.as_deref(), Some("weather.kind"));
    assert_eq!(menu[0].value, Some(toml::Value::String("none".into())));
    assert_eq!(menu[1].value, Some(toml::Value::Boolean(false)));
    assert_eq!(menu[2].value, Some(toml::Value::Float(3.5)));
    let item = serde_json::to_value(&menu[0]).unwrap();
    assert_eq!(item["action"], "SetWorldSetting");
    assert_eq!(item["world"], "my-world");
    assert_eq!(item["value"], "none");
}
