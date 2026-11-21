//! Shared translations using the client preference or its system locale.
use serde::Deserialize;
use std::{borrow::Cow, collections::BTreeMap, sync::OnceLock};

#[derive(Deserialize)]
pub struct Catalog {
    pub locales: BTreeMap<String, String>,
    messages: BTreeMap<String, BTreeMap<String, String>>,
}

pub fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| serde_json::from_str(include_str!(
        "../../../frontends/godot/project/config/localization.json"
    )).expect("Invalid shared translation catalog"))
}

pub fn supported(language: &str) -> bool {
    language == "auto" || catalog().locales.contains_key(language)
}

pub fn resolve(language: &str, system: &str) -> &'static str {
    let requested = if language == "auto" { system } else { language };
    let normalized = requested.split('.').next().unwrap_or(requested).replace('_', "-").to_lowercase();
    let normalized = match normalized.as_str() {
        "jp" | "jp-jp" => "ja",
        value if value == "no" || value.starts_with("no-") => "nb",
        value => value,
    };
    let locales = &catalog().locales;
    locales.keys().find(|key| key.to_lowercase() == normalized)
        .or_else(|| locales.keys().find(|key| key.split('-').next().unwrap().eq_ignore_ascii_case(normalized.split('-').next().unwrap())))
        .map_or("en-US", String::as_str)
}

pub fn effective(_server: Option<&str>, local: &str) -> &'static str {
    static SYSTEM: OnceLock<String> = OnceLock::new();
    let system = SYSTEM.get_or_init(|| sys_locale::get_locale().unwrap_or_else(|| "en-US".into()));
    resolve(local, system)
}

pub fn text<'a>(language: &str, source: &'a str) -> Cow<'a, str> {
    // Equivalent native chrome labels use the reference catalog without
    // duplicating translations or translating terminal titles/user input.
    let key = match source {
        "File" => "Shell",
        "Rendering" => "Settings",
        "New Terminal Tab" | "New Shell" => "New Terminal",
        "Split Right" | "Split ↔" => "New Pane Right",
        "Split Below" | "Split ↕" => "New Pane Below",
        "Connect to Host…" | "Connect to host" | "Remote connections" => "Connect to Graffitty",
        "Server URL" | "ws:// or wss:// server address" => "Server address",
        "Workspace" => "Session name",
        "Back to local" => "Back to workspace",
        "Telegram code" | "Telegram 2FA code" => "Enter the Telegram code",
        "Host remote access" | "Access settings" => "Remote Access",
        "Close all workspaces in this window? Running programs and unsaved chromium state will be lost." =>
            "Close all workspaces in this window? Running processes and unsaved chromium state will be lost.",
        _ => source,
    };
    if language == "en-US" { return Cow::Borrowed(source); }
    catalog().messages.get(key).and_then(|message| message.get(language))
        .filter(|translated| !translated.is_empty())
        .map_or(Cow::Borrowed(source), |translated| Cow::Borrowed(translated.as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_locales_and_aliases_match_the_reference_client() {
        for (system, expected) in [("ko_KR.UTF-8", "ko"), ("en_GB", "en-US"),
            ("pt_PT", "pt-BR"), ("jp-JP", "ja"), ("no_NO", "nb"), ("zz_ZZ", "en-US")] {
            assert_eq!(resolve("auto", system), expected);
        }
    }

    #[test]
    fn server_language_never_overrides_local_choice() {
        assert_eq!(effective(Some("ja"), "ko"), "ko");
        assert_eq!(effective(Some("future-locale"), "ko"), "ko");
        assert_eq!(effective(Some("auto"), "ko"), "ko");
        assert_eq!(effective(None, "pt-BR"), "pt-BR");
    }

    #[test]
    fn list_windows_and_docks_have_every_supported_translation() {
        let catalog = catalog();
        for source in [
            "Agents", "Sessions", "Pinned", "Needs you", "Working", "Idle", "Done",
            "No agent status yet. Agents show up here when they report their status.",
            "Unpin", "Pin to the top", "This Computer", "Servers…", "New Session",
            "New session on %s", "Connected", "Not connected",
            "Connect to a server…", "Opening %s…",
            "Could not switch session", "Could not create session", "Could not rename session",
            "Rename", "Rename Session", "Rename Session…", "Automatic name", "Server is not connected",
            "All Sessions…", "Switch Session", "Agent sounds", "Close",
            "The session owner did not respond.", "Drag to move or undock", "Resize sidebar",
            "Resize stacked panels", "Drag to resize width and height", "Collapse sidebar", "Expand sidebar",
        ] {
            let messages = catalog.messages.get(source).unwrap_or_else(|| panic!("Missing UI message: {source}"));
            for locale in catalog.locales.keys() {
                let text = messages.get(locale).unwrap_or_else(|| panic!("Missing {locale}: {source}"));
                assert!(!text.trim().is_empty(), "Empty {locale}: {source}");
                assert_eq!(text.matches("%s").count(), source.matches("%s").count(), "Placeholder mismatch {locale}: {source}");
            }
        }
    }

    #[test]
    fn catalog_translates_messages_without_changing_user_content() {
        assert_eq!(text("ko", "Connect"), "연결");
        let path = "/tmp/Connect/사용자";
        assert_eq!(text("ko", path), path);
        assert_eq!(text("unknown", "Connect"), "Connect");
        assert!(catalog().locales.len() >= 11);
    }
}
