use graffitty_client_config::{
    bindings::Platform,
    config::{Dirs, parse, resolve_documents},
    mods::{Host, Side},
};
use std::path::Path;

fn document(text: &str, path: &str) -> toml::Table {
    parse(text, Path::new(path), &Dirs::home("/home/demo")).unwrap()
}

#[test]
fn overrides_inherit_defaults_and_resolve_entries_per_document() {
    let result = resolve_documents(vec![
        document("[mods.agents]\nentry = './personal/list.js'\nprops.limit = 4\n[mods.builds]\nentry = '~/builds.js'\nhost = 'panel'\nplace = 'left'\nafter = 'agents'\nopen = true", "/config/client.toml"),
        document("[mods.agents]\ntitle = 'Tasks'\nprops.color = 'blue'", "/elsewhere/overlay.toml"),
    ], Platform::Android).unwrap();
    let agents = &result.mods["agents"];
    assert_eq!(agents.entry.as_deref(), Some("/config/./personal/list.js"));
    assert_eq!(agents.title.as_deref(), Some("Tasks"));
    assert_eq!(agents.host, Some(Host::Panel));
    assert_eq!(agents.place, Some(Side::Left));
    assert_eq!(agents.background_opacity, Some(0.8));
    assert_eq!(agents.props["limit"].as_integer(), Some(4));
    assert_eq!(agents.props["color"].as_str(), Some("blue"));
    assert_eq!(
        result.mods["builds"].entry.as_deref(),
        Some("/home/demo/builds.js")
    );
    assert!(
        result.mod_order.iter().position(|id| id == "agents")
            < result.mod_order.iter().position(|id| id == "builds")
    );
}

#[test]
fn rejects_invalid_registration_and_placement() {
    for text in [
        "[mods.new]\nhost = 'panel'",
        "[mods.new]\nentry = 'new.js'",
        "[mods.new]\nentry = 'new.js'\nhost = 'embedded'",
        "[mods.agents]\nhost = 'pane'",
        "[mods.agents]\nplace = 'bottom'",
        "[mods.agents]\nafter = 'missing'",
        "[mods.agents]\nafter = 'status-line'",
        "[mods.agents]\nafter = 'sessions'\n[mods.sessions]\nafter = 'agents'",
        "[mods.pane-strip]\nopen = true",
        "[mods.status-line]\nhost = 'panel'",
        "[mods.status-line]\nplace = 'none'",
        "[mods.status-line]\nplace = 'left'\nsides = ['left', 'top', 'bottom']",
    ] {
        let result =
            resolve_documents(vec![document(text, "/config/client.toml")], Platform::Linux);
        assert!(result.is_err(), "accepted {text}");
    }
    for text in [
        "[mods.'../escape']\nentry = 'new.js'",
        "[mods.agents]\nsize = nan",
        "[mods.agents]\nbackground_opacity = 2",
        "[mods.agents]\nsides = ['none']",
        "[mods.agents]\nsides = ['left', 'left']",
        "[mods.agents]\nscript = 'obsolete.js'",
    ] {
        assert!(
            parse(text, Path::new("client.toml"), &Dirs::default()).is_err(),
            "accepted {text}"
        );
    }
}

#[test]
fn bars_keep_their_host_and_accept_only_top_bottom_placement() {
    let result = resolve_documents(vec![document(
        "[mods.status-line]\nplace = 'top'\nsize = 120\n[mods.activity]\nentry = 'activity.js'\nhost = 'bar'",
        "/config/client.toml",
    )], Platform::Macos).unwrap();
    assert_eq!(result.mods["status-line"].host, Some(Host::Bar));
    assert_eq!(result.mods["status-line"].place, Some(Side::Top));
    assert_eq!(result.mods["status-line"].size, Some(120.0));
    assert_eq!(result.mods["activity"].place, Some(Side::Bottom));
    assert_eq!(result.mods["activity"].sides, Some(vec![Side::Top, Side::Bottom]));
}

#[test]
fn extra_pane_presenters_and_disabled_builtins_resolve() {
    let result = resolve_documents(
        vec![document(
            "[mods.pane-strip]\nenabled = false\n[mods.badge]\nentry = 'badge.js'\nhost = 'pane'",
            "/config/client.toml",
        )],
        Platform::Macos,
    )
    .unwrap();
    assert_eq!(result.mods["pane-strip"].enabled, Some(false));
    assert_eq!(result.mods["badge"].host, Some(Host::Pane));
}
