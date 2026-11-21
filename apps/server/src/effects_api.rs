//! Effect holds over RPC: the same records OSC 4723 creates, for scripts that
//! hold a pane capability but do not sit on the pane's tty.
//!
//! Any pane in the caller's workspace may be targeted, so a stale hold can be
//! cleared from another pane. See
//! `docs/developers/automation-and-extensions/effect-holds.md`.
use crate::{Error, Server, api, terminal_api, workspace};
use graffitty_protocol::osc::{Effects, Hold, Scope};
use serde_json::{Value, json};

pub fn handles(method: &str) -> bool {
    matches!(method, "effects.hold" | "effects.release" | "effects.list")
}

pub fn dispatch(server: &mut Server, caller: u64, method: &str, params: &Value) -> Result<Value, Error> {
    let allowed: &[&str] = match method {
        "effects.hold" => &["target", "id", "off", "on", "until"],
        "effects.release" => &["target", "id"],
        "effects.list" => &["target"],
        _ => return Err(api::error("method_not_found", "Unknown effects method")),
    };
    let object = params.as_object().ok_or_else(|| api::error("invalid_params", "Expected object params"))?;
    if let Some(key) = object.keys().find(|key| !allowed.contains(&key.as_str())) {
        return Err(api::error("invalid_params", &format!("Unsupported parameter: {key}")));
    }
    let pane = target(server, caller, params)?;
    let message = match method {
        "effects.hold" => {
            let hold = Hold {
                id: string(params, "id")?.ok_or_else(|| api::error("invalid_params", "id must be a string"))?,
                off: names(params, "off")?,
                on: names(params, "on")?,
                until: match string(params, "until")? {
                    None => Scope::Process,
                    Some(value) => Scope::parse(&value)
                        .ok_or_else(|| api::error("invalid_params", "until must be process, pane or clear"))?,
                },
            };
            hold.validate().map_err(|e| api::error("invalid_params", &e))?;
            Some(Effects::Hold(hold))
        }
        "effects.release" => Some(Effects::Release(match string(params, "id")? {
            Some(id) if !graffitty_protocol::osc::valid_id(&id) => {
                return Err(api::error("invalid_params", "Invalid hold id"));
            }
            id => id,
        })),
        _ => None,
    };
    let session = server.sessions.get_mut(&pane).ok_or_else(|| api::error("no_terminal", "Unknown pane"))?;
    if let Some(message) = message {
        let pgid = session.foreground();
        session.effect_holds.apply(&message, pgid);
    }
    Ok(json!({"pane":format!("%{pane}"),"holds":session.effect_holds.snapshot()}))
}

/// The caller's pane, or another terminal pane in the same workspace.
fn target(server: &mut Server, caller: u64, params: &Value) -> Result<u64, Error> {
    let name = server.sessions.get(&caller)
        .ok_or_else(|| api::error("workspace_closed", "Terminal no longer exists"))?
        .workspace.clone();
    let Some(target) = string(params, "target")? else { return Ok(caller) };
    workspace::sync(server, &name)?;
    let state = server.workspace_state.snapshot(&name);
    let key = terminal_api::resolve_in_workspace(&state, &name, &target)
        .ok_or_else(|| api::error("invalid_target", "Unknown pane target"))?;
    let id = key.strip_prefix('%').and_then(|s| s.parse::<u64>().ok())
        .filter(|id| server.sessions.get(id).is_some_and(|s| s.workspace == name && !s.exited))
        .ok_or_else(|| api::error("no_terminal", "Effect holds require a terminal pane"))?;
    Ok(id)
}

fn string(params: &Value, key: &str) -> Result<Option<String>, Error> {
    params.get(key).map(|v| {
        v.as_str().map(str::to_owned)
            .ok_or_else(|| api::error("invalid_params", &format!("{key} must be a string")))
    }).transpose()
}

fn names(params: &Value, key: &str) -> Result<Vec<String>, Error> {
    let Some(value) = params.get(key) else { return Ok(Vec::new()) };
    let invalid = || api::error("invalid_params", &format!("{key} must be an array of effect names"));
    value.as_array().ok_or_else(invalid)?
        .iter().map(|v| v.as_str().map(str::to_owned).ok_or_else(invalid)).collect()
}
