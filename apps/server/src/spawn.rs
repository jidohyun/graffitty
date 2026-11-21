//! Host preparation of protocol launch options.
pub use graffitty_protocol::spawn::{SpawnOptions, protected_environment};
pub use graffitty_protocol::limits::{TerminalLimits, MAX_SCROLLBACK_BYTES};
pub use graffitty_platform::spawn::Prepared;
use std::path::Path;
pub trait Prepare {
    fn prepare(&self, default_shell: &str, source_cwd: Option<&Path>) -> Result<Prepared, String>;
}
impl Prepare for SpawnOptions {
    fn prepare(&self, default_shell: &str, source_cwd: Option<&Path>) -> Result<Prepared, String> {
        graffitty_platform::spawn::prepare(self, default_shell, source_cwd)
    }
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrollback_uses_one_name_in_requests_and_snapshots() {
        for budget in [0, 64, 10000, MAX_SCROLLBACK_BYTES] {
            let options: SpawnOptions = serde_json::from_value(serde_json::json!({"scrollback_bytes":budget})).unwrap();
            options.validate().unwrap();
            assert_eq!(options.terminal_limits().scrollback_bytes, budget);
            assert_eq!(serde_json::to_value(options.terminal_limits()).unwrap()["scrollback_bytes"], budget);
        }
        assert!(serde_json::from_value::<SpawnOptions>(serde_json::json!({"scrollback_lines":64})).is_err());
    }

    #[test]
    fn limits_are_validated_before_host_preparation_and_legacy_defaults_stay_fixed() {
        assert_eq!(
            SpawnOptions::default().terminal_limits(),
            TerminalLimits::default()
        );
        for value in [
            serde_json::json!({"scrollback_bytes":MAX_SCROLLBACK_BYTES+1}),
            serde_json::json!({"kitty_image_storage_mb":2049}),
            serde_json::json!({"kitty_image_transmission_mib":0}),
            serde_json::json!({"kitty_image_transmission_mib":513}),
        ] {
            let config: SpawnOptions = serde_json::from_value(value).unwrap();
            assert!(config.validate().is_err());
            assert!(config.prepare("/bin/sh", None).is_err());
        }
        let config: SpawnOptions = serde_json::from_value(serde_json::json!({"scrollback_bytes":0,"kitty_image_storage_mb":0,"kitty_image_transmission_mib":65})).unwrap();
        assert!(config.validate().is_ok());
        assert_eq!(config.terminal_limits().storage_bytes(), 0);
        assert_eq!(
            config.terminal_limits().transmission_bytes(),
            65 * 1024 * 1024
        );
    }

    #[cfg(unix)]
    #[test]
    fn real_zsh_hooks_preserve_user_startup_and_can_be_disabled() {
        use std::time::{Duration, Instant};
        let zsh = ["/bin/zsh", "/usr/bin/zsh"]
            .into_iter()
            .find(|path| Path::new(path).is_file());
        let Some(zsh) = zsh else {
            return;
        };
        let private = crate::shell_hooks::Hooks::prepare().unwrap();
        // Use our private resource directory as a separate original ZDOTDIR.
        let original = private.directory.join("original");
        std::fs::create_dir(&original).unwrap();
        std::fs::write(
            original.join(".zshenv"),
            "export HOOK_ORIGINAL_STARTUP=loaded\n",
        )
        .unwrap();
        std::fs::write(original.join(".zshrc"), "PS1='PRIVATE_HOOK> '\n").unwrap();
        for enabled in [false, true] {
            let options = SpawnOptions {
                shell: Some(zsh.into()),
                login: Some(false),
                shell_integration: Some(enabled),
                scrollback_bytes: Some(32),
                env: [("ZDOTDIR".into(), original.to_string_lossy().into_owned())].into(),
                ..Default::default()
            }
            .prepare(zsh, None)
            .unwrap();
            let mut session = crate::session::Session::new(
                99,
                99,
                "hooks-test",
                zsh,
                "private",
                "capability",
                "graffitty",
                None,
                Some(&options),
            )
            .unwrap();
            session
                .input(b"printf '\\036%s\\037\\n' \"$HOOK_ORIGINAL_STARTUP\"\r".to_vec())
                .unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut bytes;
            loop {
                session.poll();
                bytes = session
                    .presentation_chunks
                    .iter()
                    .flat_map(|(_, data)| data.iter().copied())
                    .collect::<Vec<_>>();
                if bytes.windows(8).any(|p| p == b"\x1eloaded\x1f") {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "Private zsh did not read original startup"
                );
                std::thread::sleep(Duration::from_millis(10));
            }
            // A complete next prompt is already queued in the same normal PTY
            // path; poll briefly so an enabled pre-command hook has executed.
            let deadline = Instant::now() + Duration::from_millis(100);
            while Instant::now() < deadline {
                session.poll();
                std::thread::sleep(Duration::from_millis(5));
            }
            bytes = session
                .presentation_chunks
                .iter()
                .flat_map(|(_, data)| data.iter().copied())
                .collect();
            assert_eq!(bytes.windows(6).any(|p| p == b"\x1b]133;"), enabled);
            assert_eq!(bytes.windows(4).any(|p| p == b"\x1b]7;"), enabled);
            assert_eq!(session.limits.scrollback_bytes, 32);
        }
        assert_eq!(
            std::fs::read_to_string(original.join(".zshenv")).unwrap(),
            "export HOOK_ORIGINAL_STARTUP=loaded\n"
        );
    }

    #[test]
    fn rejects_capability_overrides_and_malformed_or_unbounded_options() {
        for key in [
            "GRAFFITTY_TOKEN",
            "GRAFFITTY_SURFACE_ID",
            "CODEX_THREAD_ID",
            "CODEX_HOME",
            "GODOT_AGENT_SOCKET",
            "A=B",
            "BAD KEY",
            "1NAME",
            "",
        ] {
            assert!(
                SpawnOptions {
                    env: [(key.into(), "x".into())].into(),
                    ..Default::default()
                }
                .validate()
                .is_err(),
                "{key}"
            );
        }
        assert!(
            SpawnOptions {
                env: [("OK".into(), "\0".into())].into(),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            SpawnOptions {
                env: [("OK".into(), "x".repeat(65537))].into(),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            SpawnOptions {
                env: (0..129).map(|i| (format!("V{i}"), String::new())).collect(),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            serde_json::from_value::<SpawnOptions>(serde_json::json!({"command":"echo nope"}))
                .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn host_validation_preserves_literal_values_and_cwd_precedence() {
        let source = std::env::temp_dir().canonicalize().unwrap();
        let config = SpawnOptions {
            shell: Some("/bin/sh".into()),
            login: Some(false),
            env: [("LITERAL".into(), "$(exit 7);`id`".into())].into(),
            ..Default::default()
        };
        let prepared = config.prepare("/missing/default", Some(&source)).unwrap();
        assert!(!prepared.login);
        assert_eq!(prepared.cwd.as_deref(), Some(source.as_path()));
        assert_eq!(prepared.env["LITERAL"], "$(exit 7);`id`");
        let explicit = SpawnOptions {
            cwd: Some("/".into()),
            ..config.clone()
        }
        .prepare("/bin/sh", Some(&source))
        .unwrap();
        assert_eq!(explicit.cwd.as_deref(), Some(Path::new("/")));
        assert!(
            SpawnOptions {
                shell: Some("/no/such/shell".into()),
                ..Default::default()
            }
            .prepare("/bin/sh", None)
            .is_err()
        );
        assert!(
            SpawnOptions {
                cwd: Some("/no/such/directory".into()),
                ..Default::default()
            }
            .prepare("/bin/sh", None)
            .is_err()
        );
        assert!(
            SpawnOptions {
                cwd: Some("relative".into()),
                ..Default::default()
            }
            .prepare("/bin/sh", None)
            .is_err()
        );
    }

    #[cfg(unix)]
    #[test]
    fn real_pty_receives_literal_environment_directory_and_server_capabilities() {
        use std::time::{Duration, Instant};
        let cwd = std::env::temp_dir().canonicalize().unwrap();
        let options = SpawnOptions {
            shell: Some("/bin/sh".into()),
            login: Some(false),
            cwd: Some(cwd.to_string_lossy().into()),
            env: [("GRAFFITTY_SPAWN_LITERAL_TEST".into(), "rejected".into())].into(),
            ..Default::default()
        };
        assert!(options.prepare("/bin/sh", None).is_err());
        let mut options = SpawnOptions {
            env: [("SPAWN_LITERAL_TEST".into(), "$(exit 7);`id`".into())].into(),
            ..options
        }
        .prepare("/bin/sh", None)
        .unwrap();
        // Defense in depth: a prepared value cannot replace the owner's
        // capability even if an internal caller bypasses structural validation.
        options
            .env
            .insert("GRAFFITTY_TOKEN".into(), "forged".into());
        let mut session = crate::session::Session::new(
            91,
            91,
            "spawn-test",
            "/bin/sh",
            "private-endpoint",
            "actual-capability",
            "graffitty",
            None,
            Some(&options),
        )
        .unwrap();
        session.input(b"printf '\\036%s|%s|%s|%s\\037\\n' \"$SPAWN_LITERAL_TEST\" \"$PWD\" \"$GRAFFITTY_SURFACE_ID\" \"$GRAFFITTY_TOKEN\"\r".to_vec()).unwrap();
        let expected = format!(
            "\x1e$(exit 7);`id`|{}|%91|actual-capability\x1f",
            cwd.display()
        );
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            session.poll();
            let bytes: Vec<_> = session
                .presentation_chunks
                .iter()
                .flat_map(|(_, bytes)| bytes.iter().copied())
                .collect();
            if bytes
                .windows(expected.len())
                .any(|w| w == expected.as_bytes())
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "PTY did not receive requested options: {}",
                String::from_utf8_lossy(&bytes)
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[cfg(unix)]
    #[test]
    fn pty_color_policy_is_independent_of_captured_launcher_output() {
        use std::time::{Duration, Instant};
        for override_value in [None, Some("1")] {
            let options = SpawnOptions {
                shell: Some("/bin/sh".into()),
                login: Some(false),
                env: override_value
                    .map(|value| ("NO_COLOR".into(), value.into()))
                    .into_iter()
                    .collect(),
                ..Default::default()
            }
            .prepare("/bin/sh", None)
            .unwrap();
            let mut session = crate::session::Session::new(
                92,
                92,
                "color-test",
                "/bin/sh",
                "private-endpoint",
                "capability",
                "graffitty",
                None,
                Some(&options),
            )
            .unwrap();
            session.input(b"printf '\\036%s|%s|%s\\037\\n' \"${NO_COLOR-unset}\" \"$TERM\" \"$COLORTERM\"\r".to_vec()).unwrap();
            let expected = format!(
                "\x1e{}|xterm-ghostty|truecolor\x1f",
                override_value.unwrap_or("unset")
            );
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                session.poll();
                let bytes: Vec<_> = session
                    .presentation_chunks
                    .iter()
                    .flat_map(|(_, bytes)| bytes.iter().copied())
                    .collect();
                if bytes
                    .windows(expected.len())
                    .any(|part| part == expected.as_bytes())
                {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "PTY color policy mismatch: {}",
                    String::from_utf8_lossy(&bytes)
                );
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn bell_callback_distinguishes_audible_bell_from_osc_terminator() {
        use std::time::{Duration, Instant};
        let options = SpawnOptions {
            shell: Some("/bin/sh".into()),
            login: Some(false),
            ..Default::default()
        }
        .prepare("/bin/sh", None)
        .unwrap();
        let mut session = crate::session::Session::new(
            92,
            92,
            "bell-test",
            "/bin/sh",
            "private",
            "capability",
            "graffitty",
            None,
            Some(&options),
        )
        .unwrap();
        session
            .input(b"printf '\\033]9;OSC_TERMINATOR_ONLY\\a\\n'\r".to_vec())
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while !session
            .notifications
            .iter()
            .any(|(_, v)| v["body"] == "OSC_TERMINATOR_ONLY")
        {
            session.poll();
            assert!(Instant::now() < deadline, "Missing OSC notification");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(!session.notifications.iter().any(|(_, v)| v["bell"] == true));
        session.input(b"printf '\\a'\r".to_vec()).unwrap();
        while !session.notifications.iter().any(|(_, v)| v["bell"] == true) {
            session.poll();
            assert!(Instant::now() < deadline, "Missing actual VT bell");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            session
                .notifications
                .iter()
                .filter(|(_, v)| v["bell"] == true)
                .count(),
            1
        );
    }

    #[cfg(unix)]
    #[test]
    fn notification_query_precedes_da1_once_at_the_owning_pty() {
        use std::time::{Duration, Instant};
        let options = SpawnOptions {
            shell: Some("/bin/sh".into()),
            login: Some(false),
            ..Default::default()
        }
        .prepare("/bin/sh", None)
        .unwrap();
        let mut session = crate::session::Session::new(
            93,
            93,
            "notification-query-test",
            "/bin/sh",
            "private",
            "capability",
            "graffitty",
            None,
            Some(&options),
        )
        .unwrap();
        let script = r#"import os,termios,tty
old=termios.tcgetattr(0)
try:
 tty.setraw(0)
 os.write(1,b'\x1b]99;i=probe:p=?;\x1b\\\x1b[c')
 data=b''
 while not (b'\x1b\\' in data and data.endswith(b'c')): data+=os.read(0,1)
 os.write(1,b'\r\nQUERY_ORDER_'+data.hex().encode()+b'\r\n')
finally: termios.tcsetattr(0,termios.TCSANOW,old)
"#;
        session
            .input(format!("python3 -c '{}'\r", script.replace('\'', "'\\''")).into_bytes())
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(8);
        let response = loop {
            session.poll();
            let bytes: Vec<_> = session
                .presentation_chunks
                .iter()
                .flat_map(|(_, v)| v.iter().copied())
                .collect();
            let output = String::from_utf8_lossy(&bytes);
            if let Some(line) = output.lines().find(|s| s.starts_with("QUERY_ORDER_")) {
                break line.trim_start_matches("QUERY_ORDER_").trim().to_owned();
            }
            assert!(
                Instant::now() < deadline,
                "No query response from PTY: {output}"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        let expected = crate::terminal_protocol::notification_query("i=probe:p=?;").unwrap();
        let prefix: String = expected.bytes().map(|b| format!("{b:02x}")).collect();
        assert!(
            response.starts_with(&format!("{prefix}1b5b")),
            "Notification must precede CSI DA1: {response}"
        );
        assert_eq!(
            response.matches("1b5d39393b").count(),
            1,
            "Only the owning server answers"
        );
        assert!(
            !session
                .notifications
                .iter()
                .any(|(_, v)| v["packet"] == "i=probe:p=?;"),
            "Do not forward capability queries to presentation frontends"
        );
    }
}
