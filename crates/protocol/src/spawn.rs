//! Typed options for future PTYs; values never pass through a command shell.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
pub use crate::limits::{TerminalLimits, MAX_SCROLLBACK_BYTES};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct SpawnOptions {
    pub shell: Option<String>,
    /// Literal executable arguments, never interpreted by a command shell.
    pub args: Vec<String>,
    pub login: Option<bool>,
    pub cwd: Option<String>,
    pub env: BTreeMap<String, String>,
    pub shell_integration: Option<bool>,
    /// Engine scrollback budget in bytes.
    pub scrollback_bytes: Option<u32>,
    pub kitty_image_storage_mb: Option<u32>,
    pub kitty_image_transmission_mib: Option<u32>,
}

pub fn protected_environment(key: &str) -> bool {
    key.starts_with("GRAFFITTY_") || key.starts_with("CODEX_") || key == "GODOT_AGENT_SOCKET"
}

impl SpawnOptions {
    pub fn terminal_limits(&self) -> TerminalLimits {
        let defaults = TerminalLimits::default();
        TerminalLimits {
            scrollback_bytes: self.scrollback_bytes.unwrap_or(defaults.scrollback_bytes),
            kitty_image_storage_mb: self
                .kitty_image_storage_mb
                .unwrap_or(defaults.kitty_image_storage_mb),
            kitty_image_transmission_mib: self
                .kitty_image_transmission_mib
                .unwrap_or(defaults.kitty_image_transmission_mib),
        }
    }
    /// Safe to use in a frontend: no filesystem access and no host assumptions.
    pub fn validate(&self) -> Result<(), String> {
        self.terminal_limits().validate()?;
        if self.args.len() > 128 || self.args.iter().any(|s| s.contains('\0'))
            || self.args.iter().map(String::len).sum::<usize>() > 256 * 1024 {
            return Err("Executable arguments must fit in 256 KiB without NUL (at most 128)".into());
        }
        for (name, value) in [("Shell", &self.shell), ("Directory", &self.cwd)] {
            if value
                .as_ref()
                .is_some_and(|v| v.is_empty() || v.len() > 4096 || v.contains('\0'))
            {
                return Err(format!("{name} must contain 1–4096 bytes without NUL"));
            }
        }
        if self.env.len() > 128 {
            return Err("At most 128 environment variables are allowed".into());
        }
        let mut bytes = 0;
        for (key, value) in &self.env {
            if key.is_empty()
                || key.len() > 128
                || !key.bytes().enumerate().all(|(index, c)| {
                    c == b'_' || c.is_ascii_alphabetic() || (index > 0 && c.is_ascii_digit())
                })
            {
                return Err(format!("Invalid environment variable name: {key}"));
            }
            if protected_environment(key) {
                return Err(format!("{key} is managed by the session server"));
            }
            if value.len() > 65536 || value.contains('\0') {
                return Err(format!(
                    "Environment value for {key} exceeds 64 KiB or contains NUL"
                ));
            }
            bytes += key.len() + value.len();
        }
        if bytes > 256 * 1024 {
            return Err("Environment overrides exceed 256 KiB".into());
        }
        Ok(())
    }

}
