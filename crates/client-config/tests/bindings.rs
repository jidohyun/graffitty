use graffitty_client_config::bindings::*;
use std::collections::BTreeMap;

fn config(text: &str) -> InputConfig {
    toml::from_str(text).unwrap()
}
fn key(text: &str, os: Platform) -> Shortcut {
    Shortcut::parse(text, os).unwrap()
}

#[test]
fn ios_has_its_own_map_and_command_shortcuts() {
    assert_eq!(Platform::from_name("ios"), Some(Platform::Ios));
    let input = config("[bindings]\nCopy = { ios = 'Cmd+K', android = 'Ctrl+Shift+C' }");
    input.validate().unwrap();
    let resolved = input.resolve(Platform::Ios, &BTreeMap::new()).unwrap();
    assert_eq!(resolved.action_for(&key("Cmd+K", Platform::Ios)), Some(Action::Copy));
    assert_eq!(key("CmdOrCtrl+V", Platform::Ios), key("Cmd+V", Platform::Ios));
    assert_eq!(default_bindings(Platform::Ios)[&Action::Paste], vec![key("Cmd+V", Platform::Ios)]);
}

#[test]
fn tab_menu_has_one_explicit_command_name() {
    assert_eq!(Action::from_name("ShowAllTabs"), Some(Action::ShowAllTabs));
    assert_eq!(Action::from_name("ShowTabs"), None);
}

#[test]
fn close_tab_keeps_the_default_shortcut_and_close_session_can_be_bound_separately() {
    let os = Platform::Macos;
    let input = config("[bindings]\nCloseSession = 'Cmd+Alt+Shift+W'");
    let resolved = input.resolve(os, &default_bindings(os)).unwrap();
    assert_eq!(resolved.action_for(&key("Cmd+Alt+W", os)), Some(Action::CloseTab));
    assert_eq!(
        resolved.action_for(&key("Cmd+Alt+Shift+W", os)),
        Some(Action::CloseSession)
    );
}

#[test]
fn default_prefix_is_ctrl_a_on_all_platforms() {
    for os in Platform::ALL {
        let bindings = InputConfig::default()
            .resolve(os, &BTreeMap::new())
            .unwrap();
        assert_eq!(bindings.prefix, key("Ctrl+A", os).chord, "{os:?}");
        assert_ne!(bindings.prefix, key("Cmd+A", os).chord, "{os:?}");
    }
}

#[test]
fn omitted_platform_prefix_uses_ctrl_a_and_explicit_override_is_preserved() {
    let input = config("[prefix]\nkey = { macos = 'Cmd+A' }");
    input.validate().unwrap();
    for os in Platform::ALL {
        let expected = if os == Platform::Macos { "Cmd+A" } else { "Ctrl+A" };
        assert_eq!(input.resolve(os, &BTreeMap::new()).unwrap().prefix, key(expected, os).chord);
    }
}

#[test]
fn direct_and_sequence_bindings_share_action_identity_and_hints() {
    let input = config(
        r#"
        [prefix]
        key = "CmdOrCtrl+A"
        [bindings]
        NewTab = ["CmdOrCtrl+T", "Prefix+C"]
        FocusLeft = "Prefix+H"
        NewPaneRight = "Prefix+Backslash"
    "#,
    );
    input.validate().unwrap();
    for os in Platform::ALL {
        let resolved = input.resolve(os, &BTreeMap::new()).unwrap();
        for shortcut in resolved.shortcuts_for(Action::NewTab) {
            assert_eq!(resolved.action_for(shortcut), Some(Action::NewTab));
        }
        assert_eq!(
            resolved.action_for(&key("Prefix+H", os)),
            Some(Action::FocusLeft)
        );
        assert_eq!(resolved.action_for(&key("H", os)), None);
    }
}

#[test]
fn os_maps_accept_strings_and_arrays() {
    let input = config(
        r#"
        [prefix]
        key = { macos = "Cmd+A", windows = "Ctrl+Shift+A", linux = "Ctrl+Shift+A", android = "Ctrl+A" }
        [bindings]
        NewTab = { macos = ["Cmd+T", "Prefix+C"], windows = "Ctrl+Shift+T", linux = "Ctrl+Shift+T", android = "Prefix+C" }
    "#,
    );
    input.validate().unwrap();
    let linux = input.resolve(Platform::Linux, &BTreeMap::new()).unwrap();
    assert_eq!(linux.prefix, key("Ctrl+Shift+A", Platform::Linux).chord);
    assert_eq!(
        linux.action_for(&key("Ctrl+Shift+T", Platform::Linux)),
        Some(Action::NewTab)
    );
}

#[test]
fn omissions_keep_defaults_and_empty_arrays_unbind() {
    let defaults = BTreeMap::from([(Action::NewTab, vec![key("Ctrl+T", Platform::Linux)])]);
    let input = config("[bindings]\nNewTab = { macos = [] }");
    assert!(
        input
            .resolve(Platform::Macos, &defaults)
            .unwrap()
            .shortcuts_for(Action::NewTab)
            .is_empty()
    );
    assert_eq!(
        input.resolve(Platform::Linux, &defaults).unwrap().actions,
        defaults
    );
    let input = config("[bindings]\nNewTab = []");
    assert!(
        input
            .resolve(Platform::Linux, &defaults)
            .unwrap()
            .shortcuts_for(Action::NewTab)
            .is_empty()
    );
}

#[test]
fn modifiers_are_order_independent_and_conflicts_are_resolved_per_os() {
    assert_eq!(
        key("Ctrl+Shift+T", Platform::Linux),
        key("Shift+Ctrl+T", Platform::Linux)
    );
    let input = config("[bindings]\nNewTab = 'CmdOrCtrl+T'\nFocusLeft = 'Ctrl+T'");
    assert!(input.resolve(Platform::Macos, &BTreeMap::new()).is_ok());
    assert!(input.validate().unwrap_err().contains("conflict"));
}

#[test]
fn defaults_participate_in_conflict_detection() {
    let defaults = BTreeMap::from([(Action::NewTab, vec![key("Ctrl+T", Platform::Linux)])]);
    let input = config("[bindings]\nFocusLeft = 'Ctrl+T'");
    assert!(
        input
            .resolve(Platform::Linux, &defaults)
            .unwrap_err()
            .contains("conflict")
    );
}

#[test]
fn rejects_obsolete_names_unknown_fields_and_unknown_platforms() {
    for source in [
        "[bindings]\nnew_tab = 'Ctrl+T'",
        "[bindings]\nnew-tab = 'Ctrl+T'",
        "[bindings]\nUnknownAction = 'Ctrl+T'",
        "[prefix.bindings]\nc = 'NewTab'",
        "[prefix]\nshortcut = 'Ctrl+A'",
        "[prefix]\nkey = { darwin = 'Cmd+A' }",
        "[bindings]\nNewTab = { windwos = 'Ctrl+T' }",
    ] {
        let parsed = toml::from_str::<InputConfig>(source);
        assert!(
            parsed.map_or(true, |input| input.validate().is_err()),
            "{source}"
        );
    }
}

#[test]
fn rejects_invalid_keys_and_modifiers() {
    for text in [
        "",
        "Ctrl+",
        "Primary+A",
        "CmdOrCtrl+Ctrl+A",
        "Ctrl+Ctrl+A",
        "Prefix+Prefix+C",
        "Ctrl+typo",
        "Ctrl+a",
        "F0",
        "F36",
        "F01",
        "Ctrl++",
        "Ctrl+ T",
    ] {
        assert!(Shortcut::parse(text, Platform::Linux).is_err(), "{text}");
    }
}

#[test]
fn preserves_prefix_control_keys_and_numeric_selectors() {
    for text in [
        "Prefix+Escape",
        "Prefix+1",
        "Prefix+A",
        "Prefix+Ctrl+A",
        "Prefix+Colon",
        "Prefix+Shift+Semicolon",
        "Prefix+At",
    ] {
        let input = config(&format!("[bindings]\nNewTab = '{text}'"));
        assert!(
            input.resolve(Platform::Linux, &BTreeMap::new()).is_err(),
            "{text}"
        );
    }
    let input = config("[prefix]\nkey = 'Prefix+A'");
    assert!(input.validate().is_err());
    let input = config("[bindings]\nNewTab = 'Ctrl+A'");
    assert!(input.validate().is_err());
}

#[test]
fn validates_inactive_os_branches_and_duplicate_bindings() {
    let input = config("[bindings]\nNewTab = { android = 'Typo+C' }");
    assert!(input.resolve(Platform::Macos, &BTreeMap::new()).is_ok());
    assert!(input.validate().is_err());
    let input = config("[bindings]\nNewTab = ['Ctrl+T', 'Ctrl+T']");
    assert!(input.validate().unwrap_err().contains("duplicate"));
}

#[test]
fn send_text_entries_carry_text_and_share_conflict_checks() {
    let input = config(
        r#"
        [bindings]
        SendText = [
          { key = "Shift+Enter", text = "\u001b\r" },
          { key = "Cmd+Left", text = "\u0001" },
        ]
        Ignore = ["F7"]
    "#,
    );
    input.validate().unwrap();
    let mac = input
        .resolve(Platform::Macos, &default_bindings(Platform::Macos))
        .unwrap();
    let enter = key("Shift+Enter", Platform::Macos);
    assert_eq!(mac.action_for(&enter), Some(Action::SendText));
    assert_eq!(mac.texts[&enter], "\u{1b}\r");
    assert_eq!(mac.texts[&key("Cmd+Left", Platform::Macos)], "\u{1}");
    assert_eq!(
        mac.action_for(&key("F7", Platform::Macos)),
        Some(Action::Ignore)
    );
    let per_os = config("[bindings]\nSendText = { linux = { key = 'Alt+Enter', text = 'x' } }");
    let linux = per_os.resolve(Platform::Linux, &BTreeMap::new()).unwrap();
    assert_eq!(linux.texts[&key("Alt+Enter", Platform::Linux)], "x");
    assert!(
        per_os
            .resolve(Platform::Macos, &BTreeMap::new())
            .unwrap()
            .texts
            .is_empty()
    );
}

#[test]
fn send_text_rejects_malformed_entries_and_conflicts() {
    for source in [
        "[bindings]\nSendText = 'Shift+Enter'",
        "[bindings]\nSendText = [{ key = 'Shift+Enter', text = '' }]",
        "[bindings]\nSendText = [{ key = 'Prefix+X', text = 'x' }]",
        "[bindings]\nIgnore = 'Prefix+X'",
        "[bindings]\nNewTab = [{ key = 'Ctrl+T', text = 'x' }]",
        "[bindings]\nSendText = [{ key = 'Shift+Up', text = 'x' }]", // PreviousPrompt default
        "[bindings]\nSendText = [{ key = 'F8', text = 'x' }, { key = 'F8', text = 'y' }]",
    ] {
        let parsed = toml::from_str::<InputConfig>(source);
        assert!(
            parsed.map_or(true, |input| input.validate().is_err()),
            "{source}"
        );
    }
    let typo = toml::from_str::<InputConfig>("[bindings]\nSendText = [{ key = 'F8', txt = 'x' }]")
        .unwrap();
    assert!(typo.validate().unwrap_err().contains("text = "));
    let platform =
        toml::from_str::<InputConfig>("[bindings]\nNewTab = { windwos = 'Ctrl+T' }").unwrap();
    assert!(
        platform
            .validate()
            .unwrap_err()
            .contains("macos/windows/linux/android")
    );
}

#[test]
fn prompt_jumps_default_to_the_shell_prompt_only() {
    for os in Platform::ALL {
        let resolved = InputConfig::default()
            .resolve(os, &default_bindings(os))
            .unwrap();
        for (action, text) in [
            (Action::PreviousPrompt, "Shift+Up"),
            (Action::NextPrompt, "Shift+Down"),
        ] {
            let shortcut = key(text, os);
            assert_eq!(resolved.action_for(&shortcut), Some(action));
            assert_eq!(resolved.conditions[&shortcut], Condition::PROMPT);
        }
        assert_eq!(
            resolved.conditions.len(),
            2,
            "only prompt jumps are conditional"
        );
    }
}

#[test]
fn when_entries_override_and_plain_entries_drop_the_default_condition() {
    let input = config(
        r#"
        [bindings]
        PreviousPrompt = "Shift+Up"
        NextPrompt = [{ key = "Alt+Down", when = "!alt_screen" }]
        ScrollTop = { key = "Shift+Home", when = "prompt" }
        SendText = { key = "Shift+Enter", text = "x", when = "alt_screen" }
    "#,
    );
    input.validate().unwrap();
    let os = Platform::Linux;
    let resolved = input.resolve(os, &default_bindings(os)).unwrap();
    assert!(!resolved.conditions.contains_key(&key("Shift+Up", os)));
    assert!(!resolved.conditions.contains_key(&key("Shift+Down", os)));
    assert_eq!(
        resolved.conditions[&key("Alt+Down", os)],
        Condition {
            state: TerminalState::AltScreen,
            negated: true
        }
    );
    assert_eq!(
        resolved.conditions[&key("Shift+Home", os)],
        Condition::PROMPT
    );
    assert_eq!(resolved.texts[&key("Shift+Enter", os)], "x");
    assert_eq!(
        resolved.conditions[&key("Shift+Enter", os)].name(),
        "alt_screen"
    );
    // Unbinding an action also drops its default condition.
    let unbound = config("[bindings]\nPreviousPrompt = []")
        .resolve(os, &default_bindings(os))
        .unwrap();
    assert!(!unbound.conditions.contains_key(&key("Shift+Up", os)));
}

#[test]
fn when_rejects_unknown_states_app_actions_prefixes_and_extra_fields() {
    for (text, error) in [
        (
            r#"PreviousPrompt = { key = "Shift+Up", when = "shell" }"#,
            "unknown when",
        ),
        (
            r#"NewTab = { key = "Ctrl+T", when = "prompt" }"#,
            "only to terminal actions",
        ),
        (
            r#"Find = { key = "Prefix+F", when = "prompt" }"#,
            "not Prefix+",
        ),
        (
            r#"PreviousPrompt = { key = "Shift+Up", if = "prompt" }"#,
            "expected a shortcut",
        ),
        (
            r#"PreviousPrompt = { key = "Shift+Up", text = "x" }"#,
            "only SendText has text",
        ),
        (
            r#"SendText = { key = "Shift+Enter", when = "prompt" }"#,
            "SendText entries",
        ),
    ] {
        let message = config(&format!("[bindings]\n{text}"))
            .validate()
            .unwrap_err();
        assert!(message.contains(error), "{text}: {message}");
    }
}

#[test]
fn app_modifier_expands_and_composes_on_every_platform() {
    for os in Platform::ALL {
        let app = if os.is_apple() { "Cmd" } else { "Ctrl+Shift" };
        assert_eq!(key("CmdOrCtrlShift+T", os), key(&format!("{app}+T"), os));
        assert_eq!(key("Alt+CmdOrCtrlShift+Enter", os), key(&format!("{app}+Alt+Enter"), os));
        assert_eq!(key("Prefix+CmdOrCtrlShift+T", os), key(&format!("Prefix+{app}+T"), os));
        let input = config("[bindings]\nCopy = 'CmdOrCtrlShift+C'\nFitToPane = 'CmdOrCtrlShift+Enter'");
        input.validate().unwrap();
        let resolved = input.resolve(os, &default_bindings(os)).unwrap();
        assert_eq!(resolved.action_for(&key(&format!("{app}+C"), os)), Some(Action::Copy));
        assert_eq!(resolved.action_for(&key(&format!("{app}+Enter"), os)), Some(Action::FitToPane));
    }
}

#[test]
fn app_modifier_rejects_overlapping_modifiers_in_either_order() {
    for os in Platform::ALL {
        let overlaps: &[&str] = if os.is_apple() {
            &["Cmd", "CmdOrCtrl", "CmdOrCtrlShift"]
        } else {
            &["Ctrl", "Shift", "CmdOrCtrl", "CmdOrCtrlShift"]
        };
        for modifier in overlaps {
            for shortcut in [format!("{modifier}+CmdOrCtrlShift+T"), format!("CmdOrCtrlShift+{modifier}+T")] {
                assert!(Shortcut::parse(&shortcut, os).is_err(), "{shortcut} on {os:?}");
            }
        }
    }
}

#[test]
fn app_modifier_conflicts_with_the_equivalent_explicit_chord() {
    for os in Platform::ALL {
        let explicit = if os.is_apple() { "Cmd+T" } else { "Ctrl+Shift+T" };
        let input = config(&format!("[bindings]\nNewTab = 'CmdOrCtrlShift+T'\nFocusLeft = '{explicit}'"));
        assert!(input.resolve(os, &BTreeMap::new()).is_err());
    }
}

#[test]
fn brackets_step_agents_and_with_alt_step_sessions() {
    for os in Platform::ALL {
        let resolved = InputConfig::default().resolve(os, &default_bindings(os)).unwrap();
        assert_eq!(resolved.action_for(&key("CmdOrCtrlShift+BracketRight", os)), Some(Action::NextAgent));
        assert_eq!(resolved.action_for(&key("CmdOrCtrlShift+BracketLeft", os)), Some(Action::PreviousAgent));
        for digit in 1..=9 {
            let action = Action::from_name(&format!("SelectSession{digit}")).unwrap();
            assert_eq!(resolved.action_for(&key(&format!("CmdOrCtrlShift+Alt+{digit}"), os)), Some(action));
        }
        assert_eq!(resolved.action_for(&key("CmdOrCtrlShift+Alt+BracketRight", os)), Some(Action::NextSession));
    }
}

#[test]
fn new_session_takes_prefix_shift_c_beside_new_tab() {
    for os in Platform::ALL {
        let resolved = InputConfig::default().resolve(os, &default_bindings(os)).unwrap();
        assert_eq!(resolved.action_for(&key("Prefix+Shift+C", os)), Some(Action::NewSession));
        assert_eq!(resolved.action_for(&key("Prefix+C", os)), Some(Action::NewTab));
    }
}

#[test]
fn side_panels_take_the_app_b_shortcut_without_binding_chromium() {
    for os in Platform::ALL {
        let resolved = InputConfig::default().resolve(os, &default_bindings(os)).unwrap();
        assert_eq!(resolved.action_for(&key("CmdOrCtrlShift+B", os)), Some(Action::ToggleSidePanels));
        assert!(resolved.shortcuts_for(Action::NewChromium).is_empty());
    }
}

#[test]
fn prefix_split_symbols_follow_layout_text_including_altgr() {
    for text in ["\\", "|", "-", "_"] {
        for modifiers in [Modifiers::default(), Modifiers { shift: true, ..Default::default() },
            Modifiers { alt: true, ..Default::default() },
            Modifiers { ctrl: true, alt: true, ..Default::default() }] {
            assert_eq!(prefix_punctuation(text, modifiers), text.chars().next());
        }
        assert_eq!(prefix_punctuation(text, Modifiers { ctrl: true, ..Default::default() }), None);
        assert_eq!(prefix_punctuation(text, Modifiers { meta: true, ..Default::default() }), None);
    }
    assert_eq!(prefix_punctuation("/", Modifiers { shift: true, ..Default::default() }), None);
    for os in [Platform::Macos, Platform::Windows, Platform::Linux, Platform::Android, Platform::Ios] {
        let defaults = default_bindings(os);
        assert_eq!(defaults[&Action::NewPaneLeft], vec![key("Prefix+Bar", os)]);
        assert_eq!(defaults[&Action::NewPaneAbove], vec![key("Prefix+Underscore", os)]);
    }
}
