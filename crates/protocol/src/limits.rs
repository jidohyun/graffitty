//! Resource policy shared by authoritative terminals and their mirrors.
use serde::{Deserialize, Serialize};

/// Resolved, non-secret limits for one terminal. Omitted launch options preserve
/// the existing server defaults. Clients use this same policy on checkpoints.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct TerminalLimits {
    /// Engine scrollback budget in bytes.
    pub scrollback_bytes: u32,
    pub kitty_image_storage_mb: u32,
    pub kitty_image_transmission_mib: u32,
}
pub const MAX_SCROLLBACK_BYTES: u32 = 128 * 1024 * 1024;

impl Default for TerminalLimits {
    fn default() -> Self {
        Self {
            scrollback_bytes: 50_000_000,
            kitty_image_storage_mb: 320,
            kitty_image_transmission_mib: 32,
        }
    }
}
impl TerminalLimits {
    pub fn validate(&self) -> Result<(), String> {
        if self.scrollback_bytes > MAX_SCROLLBACK_BYTES {
            return Err("Scrollback budget must be between 0 and 134217728 bytes".into());
        }
        if self.kitty_image_storage_mb > 2048 {
            return Err("Kitty image storage must be between 0 and 2048 MB".into());
        }
        if !(1..=512).contains(&self.kitty_image_transmission_mib) {
            return Err("Kitty image transmission must be between 1 and 512 MiB".into());
        }
        Ok(())
    }
    pub fn storage_bytes(self) -> u64 {
        u64::from(self.kitty_image_storage_mb) * 1000 * 1000
    }
    pub fn transmission_bytes(self) -> usize {
        self.kitty_image_transmission_mib as usize * 1024 * 1024
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_uses_byte_units_and_rejects_old_names() {
        let named: TerminalLimits = serde_json::from_str(r#"{"scrollback_bytes":4096}"#).unwrap();
        assert_eq!(named.scrollback_bytes, 4096);
        assert_eq!(named.storage_bytes(), 320_000_000);
        assert_eq!(named.transmission_bytes(), 32 * 1024 * 1024);
        assert_eq!(serde_json::to_value(named).unwrap()["scrollback_bytes"],4096);
        assert!(serde_json::from_str::<TerminalLimits>(r#"{"scrollback_lines":4096}"#).is_err());
    }

    #[test]
    fn zero_storage_disables_images_but_transmissions_require_a_budget() {
        let mut limits = TerminalLimits {
            scrollback_bytes: 0,
            kitty_image_storage_mb: 0,
            kitty_image_transmission_mib: 1,
        };
        assert!(limits.validate().is_ok());
        assert_eq!(limits.storage_bytes(), 0);
        limits.kitty_image_transmission_mib = 0;
        assert!(limits.validate().is_err());
        limits.kitty_image_transmission_mib = 513;
        assert!(limits.validate().is_err());
        limits.kitty_image_transmission_mib = 512;
        limits.scrollback_bytes = MAX_SCROLLBACK_BYTES;
        limits.kitty_image_storage_mb = 2048;
        assert!(limits.validate().is_ok());
        limits.scrollback_bytes += 1;
        assert!(limits.validate().is_err());
        limits.scrollback_bytes = 1;
        limits.kitty_image_storage_mb += 1;
        assert!(limits.validate().is_err());
    }
}
