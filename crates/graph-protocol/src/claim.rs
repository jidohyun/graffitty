//! Pane context resolution for processes whose inherited pane variables may
//! belong to another pane.
//!
//! Inside tmux, panes inherit the tmux server's environment, so
//! `GRAFFITTY_TOKEN` is the capability of whichever Graffitty pane first
//! started that server.
//!
//! Such processes instead claim the pane that actually displays them with OSC
//! 4723 (see `docs/developers/automation-and-extensions/pane-claim.md`).
use crate::{Client, Result, Rpc};
use serde_json::{Value, json};
use std::{fs, path::PathBuf, sync::OnceLock, time::Duration};

/// The local server's endpoint and server-wide capability, from the private
/// descriptor the session server publishes for this user.
pub fn local_server() -> Result<(String, String)> {
    let path = local_server_descriptor()?;
    let meta = path
        .symlink_metadata()
        .map_err(|e| format!("No session server at {}: {e}", path.display()))?;
    if !meta.is_file() || meta.len() > 65536 {
        return Err("Invalid local server descriptor".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        // SAFETY: geteuid has no preconditions and cannot fail.
        if meta.uid() != unsafe { libc::geteuid() } || meta.permissions().mode() & 0o077 != 0 {
            return Err("Local server descriptor must be private and owned by this user".into());
        }
    }
    let data: Value = serde_json::from_slice(
        &fs::read(&path).map_err(|e| format!("No session server at {}: {e}", path.display()))?,
    )?;
    let local = &data["local"];
    if local["protocol"] != graffitty_protocol::VERSION {
        return Err("Unsupported local server protocol".into());
    }
    Ok((
        local["url"].as_str().filter(|s| !s.is_empty()).ok_or("Missing local server URL")?.into(),
        local["token"].as_str().filter(|s| !s.is_empty()).ok_or("Missing local server token")?.into(),
    ))
}

/// Where the session server publishes its private local descriptor.
pub fn local_server_descriptor() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("GRAFFITTY_SERVER_DESCRIPTOR") {
        return Ok(path.into());
    }
    Ok(graffitty_protocol::default_server_descriptor().ok_or("Missing user state directory")?)
}

/// The claimed `(endpoint, pane token)` for a process inside tmux whose tmux
/// server descends from a Graffitty pane; `None` everywhere else. Claimed once
/// per process: a long-running node keeps the pane it started in.
pub fn tmux_context() -> Result<Option<(String, String)>> {
    static CLAIMED: OnceLock<std::result::Result<Option<(String, String)>, String>> = OnceLock::new();
    CLAIMED
        .get_or_init(|| resolve_tmux().map_err(|e| e.to_string()))
        .clone()
        .map_err(Into::into)
}

fn resolve_tmux() -> Result<Option<(String, String)>> {
    let set = |name| std::env::var(name).ok().filter(|v| !v.is_empty());
    let (Some(_), Some(endpoint)) = (set("TMUX"), set("GRAFFITTY_SOCKET")) else {
        return Ok(None);
    };
    claim_through_tmux(&endpoint, set("GRAFFITTY_TOKEN"), set("TMUX_PANE")).map(Some)
}

#[cfg(not(unix))]
fn claim_through_tmux(_: &str, _: Option<String>, _: Option<String>) -> Result<(String, String)> {
    Err("Graffitty pane claims inside tmux require a Unix terminal".into())
}

/// Start a claim with the inherited pane capability. When the pane that started
/// this tmux server has closed, fall back to the local server capability.
fn begin(endpoint: &str, inherited: Option<String>) -> Result<(String, Value)> {
    if let Some(token) = inherited {
        let reply = Client::new(endpoint, token.clone()).exchange("pane.claim.begin", json!({}))
            .map_err(|e| format!("The Graffitty server that started this tmux server is unreachable ({e}); restart tmux inside the current one"))?;
        if reply["error"]["code"] != "unauthorized" {
            return Ok((token, crate::response("pane.claim.begin", reply)?));
        }
    }
    let (local_endpoint, token) = local_server()
        .map_err(|e| format!("The pane that started this tmux server closed, and {e}; restart tmux"))?;
    if local_endpoint != endpoint {
        return Err("This tmux server was started by a different Graffitty server; restart tmux inside the current one".into());
    }
    let started = Client::new(endpoint, token.clone()).call("pane.claim.begin", json!({}))?;
    Ok((token, started))
}

#[cfg(unix)]
fn claim_through_tmux(endpoint: &str, inherited: Option<String>, pane: Option<String>) -> Result<(String, String)> {
    use std::io::Write;
    let mut query = std::process::Command::new("tmux");
    query.arg("display-message").arg("-p");
    if let Some(pane) = &pane {
        query.arg("-t").arg(pane);
    }
    let output = query.arg("#{allow-passthrough}").output()
        .map_err(|e| format!("Cannot ask tmux for this pane: {e}"))?;
    let passthrough = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !output.status.success() || !matches!(passthrough.as_str(), "on" | "all") {
        return Err("tmux blocks the Graffitty pane claim; add `set -g allow-passthrough all` to tmux.conf".into());
    }
    let (credential, started) = begin(endpoint, inherited)?;
    let (Some(nonce), Some(ticket)) = (started["nonce"].as_str(), started["ticket"].as_str()) else {
        return Err("Session server returned an invalid pane claim".into());
    };
    if !graffitty_protocol::osc::valid_nonce(nonce) {
        return Err("Session server returned an invalid pane claim".into());
    }
    let mut tty = fs::OpenOptions::new().write(true).open("/dev/tty")
        .map_err(|e| format!("No terminal to claim a Graffitty pane from: {e}"))?;
    tty.write_all(&graffitty_protocol::osc::encode_claim(nonce, true))?;
    tty.flush()?;
    let wait = Duration::from_millis(started["timeout_ms"].as_u64().unwrap_or(2000)) + Duration::from_secs(3);
    let claimed = Client::new(endpoint, credential).with_timeout(wait)
        .call("pane.claim.finish", json!({"ticket":ticket}))?;
    let token = claimed["token"].as_str().filter(|t| !t.is_empty())
        .ok_or("Session server returned no pane capability")?;
    Ok((endpoint.to_owned(), token.to_owned()))
}
