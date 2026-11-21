//! Move a live tab between local sessions without replacing any PTY.
use crate::{Error, Server, session_management, workspace};
use serde_json::{Value, json};
use std::collections::HashSet;

pub fn apply(server: &mut Server, source: &str, request: &Value) -> Result<Value, Error> {
    let tab = request["tab"].as_u64().ok_or("Expected source tab ID")?;
    let target = match request.get("destination") {
        None | Some(Value::Null) => {
            if server.workspaces.len() >= 64 { return Err("Session limit reached".into()); }
            session_management::fresh_key()
        }
        Some(Value::String(name)) => server.workspaces.resolve(name)?,
        _ => return Err("Destination session not found".into()),
    };
    if source == target { return Err("Source and destination sessions are identical".into()); }
    let next = server.next.checked_add(1).ok_or("Server identity exhausted")?;
    // A tab identity also guards against a target name being killed and reused
    // while the user was dragging to its old window.
    if let Some(witness) = request["destination_tab"].as_u64() {
        if !server.sessions.values().any(|s| s.workspace == target && s.tab == witness)
            && !server.chromiums.values().any(|b| b.workspace == target && b.tab == witness) {
            return Err("Destination tab is no longer in that session".into());
        }
    }
    let terminals: HashSet<_> = server.sessions.values()
        .filter(|s| s.workspace == source && s.tab == tab).map(|s| s.id).collect();
    let chromiums: Vec<_> = server.chromiums.values()
        .filter(|b| b.workspace == source && b.tab == tab).map(|b| b.id).collect();
    if terminals.is_empty() && chromiums.is_empty() { return Err("Tab is not in this session".into()); }
    // Chromium lifetime follows its owning terminal. Keep a split ownership
    // group intact rather than silently leaving a foreign-session dependency.
    if server.chromiums.values().any(|b| b.workspace == source && b.owner != b.id
        && ((b.tab == tab) != terminals.contains(&b.owner))) {
        return Err("Move owned chromiums into their terminal's tab before transferring the tab".into());
    }
    workspace::sync(server, source)?;
    if server.workspaces.contains(&target) { workspace::sync(server, &target)?; }
    server.workspace_state.transfer_tab(source, &target, tab)?;
    // All validation and disk writes succeeded. The remaining changes cannot
    // fail, and the event loop publishes only the complete new membership.
    for id in &terminals { server.sessions.get_mut(id).unwrap().workspace.clone_from(&target); }
    for id in &chromiums { server.chromiums.get_mut(id).unwrap().workspace.clone_from(&target); }
    if server.workspaces.insert(target.clone()) {
        server.workspace_incarnations.insert(target.clone(), server.workspaces.info(&target).id.0);
        server.next = next;
    }
    let mut from_graph = server.graphs.remove(source).unwrap_or_else(|| crate::graph::Graph::with_settings(server.settings.nodes.clone()));
    from_graph.transfer_nodes_to(&terminals, server.graphs.entry(target.clone()).or_insert_with(|| crate::graph::Graph::with_settings(server.settings.nodes.clone())));
    let empty = !server.sessions.values().any(|s| s.workspace == source)
        && !server.chromiums.values().any(|b| b.workspace == source);
    if empty {
        server.workspaces.remove(source);
        server.workspace_incarnations.remove(source);
    } else { server.graphs.insert(source.into(), from_graph); }
    Ok(json!({"workspace":server.workspaces.id(&target),"tab":tab,"source_empty":empty}))
}
