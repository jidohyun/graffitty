//! Terminal RPC is resolved and authorized against owner state, never a view.
use crate::{Error, Server, api, terminal_input, workspace};
use graffitty_workspace_core::state::Snapshot;
use serde_json::{Value, json};

pub fn handles(method: &str) -> bool {
    matches!(
        method,
        "terminal.get_text" | "terminal.pid" | "terminal.type" | "terminal.press" | "terminal.put"
    )
}

pub fn dispatch(
    server: &mut Server,
    caller: u64,
    method: &str,
    params: &Value,
) -> Result<api::Reply, Error> {
    let allowed: &[&str] = match method {
        "terminal.put" => &["target", "upload"],
        "terminal.get_text" => &["target", "tab_id", "scrollback"],
        "terminal.pid" => &["target", "tab_id", "details"],
        "terminal.type" => &["target", "tab_id", "text", "interval_ms"],
        "terminal.press" => &["target", "tab_id", "key", "interval_ms", "effects"],
        _ => return Err(api::error("method_not_found", "Unknown terminal method")),
    };
    let object = params
        .as_object()
        .ok_or_else(|| api::error("invalid_params", "Expected object params"))?;
    if let Some(key) = object.keys().find(|key| !allowed.contains(&key.as_str())) {
        return Err(api::error(
            "invalid_params",
            &format!("Unsupported parameter: {key}"),
        ));
    }
    if params.get("tab_id").is_some_and(|id| {
        id.as_u64() != Some(caller) && id.as_str() != Some(caller.to_string().as_str())
    }) {
        return Err(api::error("forbidden", "Cross-workspace access denied"));
    }
    let name = server
        .sessions
        .get(&caller)
        .ok_or_else(|| api::error("workspace_closed", "Terminal no longer exists"))?
        .workspace
        .clone();
    workspace::sync(server, &name)?;
    let state = server.workspace_state.snapshot(&name);
    let target = params
        .get("target")
        .map(|v| {
            v.as_str()
                .ok_or_else(|| api::error("invalid_params", "target must be a string"))
        })
        .transpose()?;
    if method == "terminal.pid" {
        let details = boolean(params, "details")?;
        return Ok(api::Reply::Ready(
            json!({"result":pids(server, &name, &state, target, details)?}),
        ));
    }
    if let Some(target) = target {
        let key = resolve_in_workspace(&state, &name, target)
            .ok_or_else(|| unknown_target(target, "Unknown pane target"))?;
        if key != format!("%{caller}") {
            return Err(api::error(
                "forbidden",
                "Terminal access is scoped to the calling terminal",
            ));
        }
    }
    if method == "terminal.put" {
        if server.sessions[&caller].exited { return Err(api::error("workspace_closed", "Terminal has exited")); }
        let chunk = serde_json::from_value::<graffitty_protocol::file_transfer::Chunk>(params["upload"].clone())
            .map_err(|e| api::error("invalid_params", &e.to_string()))?;
        let (receipt, paste) = server.uploads.receive(&server.owner_runtime.join("files"), caller, chunk)?;
        if paste {
            server.sessions[&caller].paste(&crate::file_transfer::quoted_path(receipt.path.as_deref().unwrap()))?;
        }
        return Ok(api::Reply::Ready(json!({"result":receipt})));
    }
    let session = server.sessions.get_mut(&caller).unwrap();
    if method == "terminal.get_text" {
        let text = session
            .text(boolean(params, "scrollback")?)
            .map_err(|e| api::error("capture_failed", &e.to_string()))?;
        return Ok(api::Reply::Ready(json!({"result":{"text":text}})));
    }
    let (job, receiver) = terminal_input::Input::new(method, params)?;
    if session.command_input.is_some() {
        return Err(api::error(
            "busy",
            "Virtual input already running in this terminal",
        ));
    }
    if session.exited {
        return Err(api::error("workspace_closed", "Terminal has exited"));
    }
    session.command_input = Some(job);
    Ok(api::Reply::Pending(receiver))
}

fn boolean(params: &Value, key: &str) -> Result<bool, Error> {
    params.get(key).map_or(Ok(false), |v| {
        v.as_bool()
            .ok_or_else(|| api::error("invalid_params", &format!("{key} must be a boolean")))
    })
}
fn number(value: &str) -> Option<u64> {
    let id = value.parse::<u64>().ok()?;
    (id.to_string() == value).then_some(id)
}
fn tab(state: &Snapshot, value: &str) -> Option<u64> {
    if let Some(id) = value.strip_prefix('@').and_then(number) {
        return state.layout.tabs.contains_key(&id).then_some(id);
    }
    value
        .strip_prefix(':')
        .and_then(number)
        .and_then(|n| n.checked_sub(1))
        .and_then(|n| state.order.get(usize::try_from(n).ok()?).copied())
}
/// Session-qualified and positional addresses share one pane resolver.
pub(crate) fn resolve_in_workspace(
    state: &Snapshot,
    workspace: &str,
    value: &str,
) -> Option<String> {
    if !value.starts_with(['%', ':', '@']) {
        let (session, rest) = value.rsplit_once(':')?;
        if session != workspace {
            return None;
        }
        return resolve(state, &format!(":{rest}"));
    }
    resolve(state, value)
}

pub(crate) fn resolve(state: &Snapshot, value: &str) -> Option<String> {
    let key = if let Some(id) = value.strip_prefix('%').and_then(number) {
        state
            .layout
            .tabs
            .values()
            .flat_map(|tab| &tab.windows)
            .find(|w| w.key == format!("%{id}"))?
            .key
            .clone()
    } else if let Some((group, index)) = value.split_once('.') {
        let group = tab(state, group)?;
        // Pane numbers start at 1, like tmux with pane-base-index 1.
        let index = usize::try_from(number(index)?.checked_sub(1)?).ok()?;
        state
            .layout
            .tabs
            .get(&group)?
            .numbered_keys()
            .get(index)?
            .clone()
    } else {
        return None;
    };
    state
        .layout
        .tabs
        .values()
        .any(|tab| tab.window(&key).is_some())
        .then_some(key)
}
/// Explains the one positional form that can never match.
fn unknown_target(value: &str, message: &str) -> Error {
    if (value.starts_with(':') || value.starts_with('@')) && value.ends_with(".0") {
        api::error("invalid_target", &format!("{message} (pane numbers start at 1)"))
    } else {
        api::error("invalid_target", message)
    }
}

fn pids(
    server: &Server,
    name: &str,
    state: &Snapshot,
    target: Option<&str>,
    details: bool,
) -> Result<Value, Error> {
    let group = target.filter(|s| (s.starts_with('@') || s.starts_with(':')) && !s.contains('.'));
    let selected_tab = group
        .map(|s| tab(state, s).ok_or_else(|| api::error("no_tab", "Unknown tab target")))
        .transpose()?;
    let selected_pane = target
        .filter(|_| group.is_none())
        .map(|s| {
            resolve_in_workspace(state, name, s)
                .ok_or_else(|| unknown_target(s, "No matching pane in this workspace"))
        })
        .transpose()?;
    if selected_pane.as_ref().is_some_and(|key| {
        key.strip_prefix('%')
            .and_then(number)
            .is_none_or(|id| !server.sessions.contains_key(&id))
    }) {
        return Err(api::error(
            "no_terminal",
            "PID lookup requires a terminal pane",
        ));
    }
    let mut terminals = Vec::new();
    for (position, id) in state.order.iter().enumerate() {
        if selected_tab.is_some_and(|tab| tab != *id) {
            continue;
        }
        for (index, key) in state.layout.tabs[id].numbered_keys().iter().enumerate() {
            if selected_pane.as_ref().is_some_and(|selected| selected != key) {
                continue;
            }
            let Some(pane) = key.strip_prefix('%').and_then(number) else {
                continue;
            };
            let Some(session) = server.sessions.get(&pane).filter(|s| s.workspace == name) else {
                continue;
            };
            let mut row = json!({"pane":format!("%{pane}"),"id":key,"type":"terminal", "tab":format!("@{id}"),
                "target":format!(":{}.{}",position+1,index+1),"root_pid":session.pid()});
            if details {
                let snapshot = server
                    .resources
                    .snapshot(pane)
                    .map(crate::resources::snapshot);
                for field in ["status", "sample_age_seconds", "coverage_gap", "backend"] {
                    row[field] = snapshot.as_ref().map_or(Value::Null, |v| v[field].clone());
                }
                if snapshot.is_none() {
                    row["status"] = json!("unavailable");
                }
                row["processes"] = snapshot.map_or(json!([]), |v| v["processes"].clone());
            }
            terminals.push(row);
        }
    }
    Ok(json!({"terminals":terminals}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use graffitty_workspace_core::tiling::{TabLayout, Window};

    fn state() -> Snapshot {
        let pane = |key: &str| Window::new(key, [0.0, 0.0, 1.0, 1.0]);
        let mut state = Snapshot::default();
        state.layout.tabs.insert(
            7,
            TabLayout { windows: vec![pane("%3"), pane("%8")], ..Default::default() },
        );
        state.layout.tabs.insert(
            9,
            TabLayout { windows: vec![pane("%9")], ..Default::default() },
        );
        state.order = vec![7, 9];
        state
    }

    #[test]
    fn positional_panes_start_at_one() {
        let state = state();
        assert_eq!(resolve(&state, ":1.1").as_deref(), Some("%3"));
        assert_eq!(resolve(&state, ":1.2").as_deref(), Some("%8"));
        assert_eq!(resolve(&state, ":2.1").as_deref(), Some("%9"));
        assert_eq!(resolve(&state, "@7.2").as_deref(), Some("%8"));
        assert_eq!(resolve(&state, "%8").as_deref(), Some("%8"));
        assert_eq!(resolve(&state, ":1.0"), None);
        assert_eq!(resolve(&state, ":1.3"), None);
    }

    #[test]
    fn session_qualified_targets_use_the_same_order_and_stay_scoped() {
        let state = state();
        assert_eq!(
            resolve_in_workspace(&state, "main", "main:1.2"),
            resolve(&state, ":1.2")
        );
        assert_eq!(
            resolve_in_workspace(&state, "main", "main:2.1"),
            resolve(&state, ":2.1")
        );
        assert_eq!(resolve_in_workspace(&state, "main", "other:1.2"), None);
        assert_eq!(resolve_in_workspace(&state, "main", "main:1.0"), None);
        assert_eq!(
            resolve_in_workspace(&state, "main", "%8"),
            resolve(&state, "%8")
        );
    }

    #[test]
    fn pane_zero_explains_the_numbering() {
        let message = |value| {
            api::error_details(&unknown_target(value, "Unknown pane target"))["message"].clone()
        };
        assert_eq!(message(":1.0"), "Unknown pane target (pane numbers start at 1)");
        assert_eq!(message("@7.0"), "Unknown pane target (pane numbers start at 1)");
        assert_eq!(message(":1.5"), "Unknown pane target");
    }

    #[test]
    fn positional_targets_follow_main_before_stashes() {
        use graffitty_workspace_core::tiling::{Axis, Node};
        let mut state = state();
        let layout = state.layout.tabs.get_mut(&7).unwrap();
        layout.enabled = true;
        layout.windows.push(Window::new("%12", [0., 0., 100., 100.]));
        layout.windows[0].stashed = true;
        layout.tiles = Some(Node::branch(Axis::Horizontal, vec![Node::leaf("%12"), Node::leaf("%8")]));
        assert_eq!(resolve(&state, ":1.1").as_deref(), Some("%12"));
        assert_eq!(resolve(&state, "@7.2").as_deref(), Some("%8"));
        assert_eq!(resolve(&state, ":1.3").as_deref(), Some("%3"));
        assert_eq!(resolve(&state, "%3").as_deref(), Some("%3"));
        state.layout.tabs.get_mut(&7).unwrap().remove("%12");
        assert_eq!(resolve(&state, ":1.1").as_deref(), Some("%8"));
        assert_eq!(resolve(&state, ":1.2").as_deref(), Some("%3"));
    }
}
