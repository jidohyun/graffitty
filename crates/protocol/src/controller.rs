//! Explicit server control over an already authenticated connection. Pane-token
//! RPC keeps its own scope; this capability is held by the attached client.
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const METHODS: &[&str] = &[
    "terminal.type",
    "terminal.press",
    "terminal.put",
    "terminal.get_text",
    "terminal.pid",
    "pane.list",
];

pub fn valid_alias(alias: &str) -> bool {
    !alias.is_empty()
        && alias.len() <= 64
        && alias.as_bytes()[0].is_ascii_alphanumeric()
        && alias
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
}

/// A slash always denotes an explicit server. Never fall back to a local pane
/// when the prefix is malformed or cannot be resolved.
pub fn split_target(target: &str) -> Result<Option<(&str, &str)>, &'static str> {
    let Some((alias, pane)) = target.split_once('/') else {
        return Ok(None);
    };
    if !valid_alias(alias) || pane.contains('/') {
        return Err("Use server-alias/%ID or server-alias/session:tab.pane");
    }
    Ok(Some((alias, pane)))
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    pub version: u64,
    pub method: String,
    pub params: Value,
}
impl Request {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.version != super::VERSION {
            return Err("Unsupported controller protocol");
        }
        if !METHODS.contains(&self.method.as_str()) {
            return Err("Method is not available through server control");
        }
        if !self.params.is_object() {
            return Err("Expected object params");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn remote_prefix_is_explicit_and_exact() {
        assert_eq!(split_target("%12"), Ok(None));
        assert_eq!(split_target("project:1.2"), Ok(None));
        assert_eq!(split_target("Build/%12"), Ok(Some(("Build", "%12"))));
        assert_eq!(
            split_target("build/project:1.2"),
            Ok(Some(("build", "project:1.2")))
        );
        assert_eq!(split_target("build/"), Ok(Some(("build", ""))));
        for target in [
            "/%12",
            "../%12",
            "host:7183/%12",
            "build/a/%12",
            "-build/%12",
        ] {
            assert!(split_target(target).is_err(), "{target}");
        }
    }
}
