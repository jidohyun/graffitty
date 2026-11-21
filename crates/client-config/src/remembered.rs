//! Choices made in the UI (menus, panels, the Effects dialog), kept between
//! launches.
//!
//! The file is a client.toml layer below every user file, so a key the user
//! sets in client.toml always wins and the rest follow the last choice.
//! Graffitty never writes client.toml itself.
use crate::bindings::Platform;
use crate::config::{self, Resolved};
use std::path::{Path, PathBuf};

/// The only keys the UI remembers; anything else in the file is ignored.
/// `*` matches any one name. World tables are remembered per world: their
/// transitions, and settings chosen from `SetWorldSetting` menu entries.
/// A world's `terminal` override is the user's alone.
pub const KEYS: [&[&str]; 4] = [
    &["effects", "profile"],
    &["effects", "disabled"],
    &["terminal", "effects"],
    &["worlds", "*", "*"],
];

fn keep(table: &mut toml::Table, prefix: &mut Vec<String>) {
    table.retain(|key, value| {
        prefix.push(key.to_string());
        if prefix.len() == 3 && prefix[0] == "worlds" && prefix[2] == "terminal" {
            prefix.pop();
            return false;
        }
        let exact = KEYS.iter().any(|allowed| {
            prefix.len() >= allowed.len() && allowed.iter().zip(prefix.iter()).all(|(a, b)| *a == "*" || a == b)
        });
        let parent = KEYS.iter().any(|allowed| {
            prefix.len() < allowed.len() && allowed.iter().zip(prefix.iter()).all(|(a, b)| *a == "*" || a == b)
        });
        let kept = exact
            || (parent
                && match value {
                    toml::Value::Table(inner) => {
                        keep(inner, prefix);
                        !inner.is_empty()
                    }
                    _ => false,
                });
        prefix.pop();
        kept
    });
}

/// The remembered layer in `source`; unreadable text remembers nothing.
pub fn layer(source: &str) -> toml::Table {
    let mut table: toml::Table = source.parse().unwrap_or_default();
    keep(&mut table, &mut Vec::new());
    table
}

/// Resolve `paths` over the remembered layer. A remembered choice that no
/// longer validates (a profile removed from client.toml) is dropped, never
/// reported: only the user's own files can be a configuration error.
pub fn load(
    paths: &[PathBuf],
    remembered: Option<&Path>,
    platform: Platform,
    dirs: &config::Dirs,
) -> Result<Resolved, String> {
    let mut documents = Vec::new();
    for path in paths {
        let source = std::fs::read_to_string(path)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        documents.push(config::parse(&source, path, dirs)?);
    }
    let base = remembered
        .and_then(|path| std::fs::read_to_string(path).ok())
        .map(|source| layer(&source))
        .filter(|layer| !layer.is_empty());
    if let Some(base) = base {
        let mut layered = vec![base];
        layered.extend(documents.iter().cloned());
        if let Ok(resolved) = config::resolve_documents(layered, platform) {
            return Ok(resolved);
        }
    }
    config::resolve_documents(documents, platform)
}

/// Merge `choice` (a client.toml fragment) into the remembered file. Tables
/// merge key by key; arrays and scalars replace.
pub fn remember(path: &Path, choice: toml::Table) -> Result<(), String> {
    let mut choice = choice;
    keep(&mut choice, &mut Vec::new());
    if choice.is_empty() {
        return Err("nothing to remember: not a remembered key".into());
    }
    let mut table = std::fs::read_to_string(path)
        .map(|source| layer(&source))
        .unwrap_or_default();
    config::merge(&mut table, choice);
    // World tables are opaque to the schema; a transition is always a name.
    let worlds = table.get("worlds").and_then(toml::Value::as_table);
    for world in worlds.into_iter().flat_map(toml::Table::values) {
        for group in world.as_table().into_iter().flat_map(toml::Table::values) {
            if !group.get("effect").is_none_or(toml::Value::is_str) {
                return Err("a world transition effect must be a name".into());
            }
        }
    }
    config::validate_document(&table)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temporary = path.with_extension("toml.tmp");
    std::fs::write(&temporary, toml::to_string(&table).map_err(|error| error.to_string())?)
        .and_then(|()| std::fs::rename(&temporary, path))
        .map_err(|error| format!("{}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(name: &str, source: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "graffitty-remembered-{}-{name}",
            std::process::id()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("file.toml");
        std::fs::write(&path, source).unwrap();
        path
    }

    fn table(source: &str) -> toml::Table {
        source.parse().unwrap()
    }

    #[test]
    fn explicit_client_keys_win_and_the_rest_follow_the_last_choice() {
        let remembered = file("layer", "");
        remember(&remembered, table("[effects]\nprofile = 'off'\ndisabled = ['camera.tilt']")).unwrap();
        remember(
            &remembered,
            table("[terminal.effects.cursor_trail]\nstyle = 'blaze'\ndelay_ms = 0"),
        )
        .unwrap();
        let load = |source: &str| {
            let client = file("client", source);
            load(&[client], Some(&remembered), Platform::Linux, &config::Dirs::default())
                .unwrap()
                .settings
        };
        let settings = load("");
        let effects = settings.effects.unwrap();
        assert_eq!(effects.profile.as_deref(), Some("off"));
        assert_eq!(effects.disabled.unwrap(), ["camera.tilt"]);
        let trail = settings.terminal.unwrap().effects.unwrap().cursor_trail.unwrap();
        assert_eq!(trail.delay_ms, Some(0));

        let settings = load(
            "[effects]\nprofile = 'mild'\n[terminal.effects.cursor_trail]\ndelay_ms = 5",
        );
        let effects = settings.effects.unwrap();
        assert_eq!(effects.profile.as_deref(), Some("mild"));
        assert_eq!(effects.disabled.unwrap(), ["camera.tilt"]);
        let trail = settings.terminal.unwrap().effects.unwrap().cursor_trail.unwrap();
        assert_eq!(trail.delay_ms, Some(5));
        assert_eq!(toml::Value::try_from(trail.style).unwrap().as_str(), Some("blaze"));
    }

    #[test]
    fn transitions_are_remembered_per_world_below_the_users_world_table() {
        let remembered = file("worlds", "");
        remember(&remembered, table("[worlds.flat-3d.tab_switch]\neffect = 'none'")).unwrap();
        remember(&remembered, table("[worlds.flat-3d.session_switch]\neffect = 'fly_away'")).unwrap();
        remember(&remembered, table("[worlds.bistro.session_switch]\neffect = 'none'")).unwrap();
        assert!(remember(&remembered, table("[worlds.flat-3d.tab_switch]\neffect = 1")).is_err());
        assert!(remember(&remembered, table("[worlds.flat-3d.terminal]\nfont_size = 30")).is_err());
        remember(&remembered, table("[worlds.my-world.weather]\nkind = 'none'")).unwrap();
        let client = file(
            "worlds-client",
            "[worlds.flat-3d.session_switch]\neffect = 'fly_away_and_in'\n[worlds.flat-3d.terminal_window]\nblur_radius = 4",
        );
        let worlds = load(&[client], Some(&remembered), Platform::Linux, &config::Dirs::default())
            .unwrap()
            .settings
            .worlds
            .unwrap();
        let flat = &worlds["flat-3d"];
        assert_eq!(flat["tab_switch"]["effect"].as_str(), Some("none"));
        assert_eq!(flat["session_switch"]["effect"].as_str(), Some("fly_away_and_in"));
        assert_eq!(flat["terminal_window"]["blur_radius"].as_integer(), Some(4));
        assert_eq!(worlds["bistro"]["session_switch"]["effect"].as_str(), Some("none"));
        assert_eq!(worlds["my-world"]["weather"]["kind"].as_str(), Some("none"));
    }

    #[test]
    fn a_later_choice_replaces_the_earlier_one() {
        let remembered = file("replace", "");
        remember(&remembered, table("[effects]\nprofile = 'off'\ndisabled = ['lighting']")).unwrap();
        remember(&remembered, table("[effects]\nprofile = 'world'\ndisabled = []")).unwrap();
        let effects = load(&[], Some(&remembered), Platform::Linux, &config::Dirs::default())
            .unwrap()
            .settings
            .effects
            .unwrap();
        assert_eq!(effects.profile.as_deref(), Some("world"));
        assert!(effects.disabled.unwrap().is_empty());
    }

    #[test]
    fn only_remembered_keys_are_read_or_written() {
        let remembered = file(
            "keys",
            "language = 'ja'\n[effects]\nprofile = 'mild'\n[effects.profiles.x.camera]\nzoom = 1.2\n[terminal]\nfont_size = 30",
        );
        let settings = load(&[], Some(&remembered), Platform::Linux, &config::Dirs::default())
            .unwrap()
            .settings;
        assert_eq!(settings.language, None);
        assert_eq!(settings.terminal, None);
        let effects = settings.effects.unwrap();
        assert_eq!(effects.profile.as_deref(), Some("mild"));
        assert_eq!(effects.profiles, None);
        assert!(remember(&remembered, table("language = 'ja'")).is_err());
        assert!(remember(&remembered, table("[effects]\nprofile = 3")).is_err());
        assert!(remember(&remembered, table("[terminal.effects.cursor_trail]\nstyle = 'nope'")).is_err());
    }

    #[test]
    fn a_stale_or_broken_choice_is_dropped_without_an_error() {
        // "calm" was a user profile when it was chosen; client.toml no longer defines it.
        let remembered = file("stale", "[effects]\nprofile = 'calm'\n");
        let client = file("stale-client", "[terminal]\nfont_size = 14\n");
        let settings = load(&[client], Some(&remembered), Platform::Linux, &config::Dirs::default())
            .unwrap()
            .settings;
        assert_eq!(settings.effects, None);
        assert_eq!(settings.terminal.unwrap().font_size, Some(14));
        let broken = file("broken", "not toml [");
        assert!(load(&[], Some(&broken), Platform::Linux, &config::Dirs::default()).is_ok());
        let missing = broken.with_file_name("missing.toml");
        assert!(load(&[], Some(&missing), Platform::Linux, &config::Dirs::default()).is_ok());
        // The user's own error is still reported.
        let invalid = file("invalid-client", "[effects]\nprofile = 'nope'\n");
        assert!(load(&[invalid], Some(&remembered), Platform::Linux, &config::Dirs::default()).is_err());
    }
}
