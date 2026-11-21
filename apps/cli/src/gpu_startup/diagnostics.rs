use super::{Cause, Failure, replace};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

const HEADER: &str = "Graphics startup failed";
const LOG: &str = "Diagnostic log";
const TIMEOUT: &str = "No startup progress";
const DIALOG: &str = "Graphics driver initialization failed";
const LOST: &str = "Graphics device lost";
const EXIT: &str = "Early exit (cause unknown)";

#[cfg(windows)]
fn system_language() -> String {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetUserDefaultLocaleName(name: *mut u16, len: i32) -> i32;
    }
    let mut name = [0; 85];
    let len = unsafe { GetUserDefaultLocaleName(name.as_mut_ptr(), name.len() as i32) };
    String::from_utf16_lossy(&name[..len.saturating_sub(1).max(0) as usize])
}

#[cfg(not(windows))]
fn system_language() -> String {
    ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .find_map(|key| std::env::var(key).ok().filter(|s| !s.is_empty()))
        .unwrap_or_default()
}

fn language() -> String {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .or_else(|| std::env::var_os("USERPROFILE"))
                .map(|home| PathBuf::from(home).join(".config"))
        });
    let config = base.map(|base| base.join("graffitty"));
    let saved = config
        .as_ref()
        .and_then(|dir| fs::read_to_string(dir.join("language.conf")).ok())
        .and_then(|content| {
            content
                .lines()
                .filter_map(|line| line.split_once('='))
                .find(|(k, _)| k.trim() == "language")
                .map(|(_, v)| v.trim().trim_matches('"').to_owned())
        });
    let configured = || {
        config
            .and_then(|dir| fs::read_to_string(dir.join("client.toml")).ok())
            .and_then(|s| s.parse::<toml_edit::DocumentMut>().ok())
            .and_then(|doc| doc.get("language")?.as_str().map(str::to_owned))
    };
    saved
        .or_else(configured)
        .filter(|s| s != "auto")
        .unwrap_or_else(system_language)
}

pub(super) fn exhaustion(
    state: &Path,
    failures: &[(String, Failure)],
    rules: &[u32],
) -> io::Result<String> {
    let mut log = state.join("last-failure.json");
    if let Err(error) = replace(
        &log,
        &serde_json::to_vec_pretty(
            &serde_json::json!({"version":1,"attempts":failures,"matched_rule_ids":rules}),
        )?,
    ) {
        eprintln!("GPU startup diagnostic: {error}");
        log = state.join("history.json");
    }
    let catalog: serde_json::Value = serde_json::from_str(include_str!(
        "../../../../frontends/godot/project/config/localization.json"
    ))?;
    let locale = language();
    let base = locale.split(['-', '_', '.']).next().unwrap_or("");
    let base = match base {
        "no" => "nb",
        "jp" => "ja",
        other => other,
    };
    let supported = catalog["locales"].as_object().and_then(|langs| {
        langs.keys().find(|key| {
            key.split('-')
                .next()
                .unwrap_or("")
                .eq_ignore_ascii_case(base)
        })
    });
    let tr = |key: &'static str| {
        supported
            .and_then(|lang| catalog["messages"][key][lang].as_str())
            .unwrap_or(key)
    };
    let mut lines = vec![tr(HEADER).to_owned()];
    for (mode, failure) in failures {
        let reason = tr(match failure.cause {
            Cause::Timeout => TIMEOUT,
            Cause::InitDialog => DIALOG,
            Cause::DeviceLost => LOST,
            Cause::EarlyExit => EXIT,
        });
        let status = failure
            .status
            .map(|s| format!(" (0x{:08X})", s as u32))
            .unwrap_or_default();
        let name = match mode.as_str() {
            "d3d12" => "Direct3D 12",
            "vulkan" => "Vulkan",
            "opengl3" => "OpenGL",
            "software" => "Mesa (OpenGL)",
            other => other,
        };
        lines.push(format!("{name} — {reason}{status}"));
    }
    lines.push(format!("{}\n{}", tr(LOG), log.display()));
    Ok(lines.join("\n"))
}

#[cfg(windows)]
pub(super) fn show(message: &str) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};
    let message: Vec<_> = message.encode_utf16().chain([0]).collect();
    unsafe {
        MessageBoxW(
            std::ptr::null_mut(),
            message.as_ptr(),
            windows_sys::core::w!("Graffitty"),
            MB_OK | MB_ICONERROR,
        );
    }
}

#[cfg(target_os = "linux")]
pub(super) fn show(message: &str) {
    use std::process::Command;
    // Zenity's label and desktop notification bodies can interpret markup.
    let escaped = message
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    for (tool, args) in [
        (
            "zenity",
            vec![
                "--error",
                "--title=Graffitty",
                "--no-markup",
                "--text",
                message,
            ],
        ),
        ("kdialog", vec!["--title", "Graffitty", "--error", &escaped]),
    ] {
        if Command::new(tool)
            .args(args)
            .status()
            .is_ok_and(|s| s.success())
        {
            return;
        }
    }
    eprintln!("{message}");
    let _ = notify_rust::Notification::new()
        .summary("Graffitty")
        .body(&escaped)
        .show();
}
