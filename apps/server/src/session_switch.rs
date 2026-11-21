//! Switch one presentation, leaving both sessions and every other client alive.
use crate::{Client, Error, Server, api, send};
use serde_json::{Value, json};

pub fn from_pane(server: &mut Server, clients: &mut [Client], request: &Value) -> Result<Value, Error> {
    let (pane, method, params) = api::request(request, |token| {
        server.sessions.values().find(|s| s.token == token).map(|s| s.id)
    })?;
    if method == "session.create" {
        let client = if params["detached"] == true { None } else { Some(client_for_pane(server, clients, pane)?) };
        let created = crate::session_management::dispatch(server, &json!({
            "version":1, "method":"session.new", "params":params
        }))?;
        if let Some(index) = client {
            apply(server, &mut clients[index], created["id"].as_str().unwrap())?;
        }
        return Ok(created);
    }
    let name = params["name"].as_str().ok_or_else(|| api::error("invalid_params", "Expected session name"))?;
    let index = client_for_pane(server, clients, pane)?;
    apply(server, &mut clients[index], name)
}

fn client_for_pane(server: &Server, clients: &[Client], pane: u64) -> Result<usize, Error> {
    let workspace = &server.sessions[&pane].workspace;
    // Choose a viewer in this session. Prefer the one that last sent input
    // to the pane, then a viewer currently displaying it.
    //
    // The PTY's environment is shared and cannot identify the viewer.
    clients.iter().enumerate()
        .filter(|(_, c)| c.authenticated && c.session_switch && !c.workspace_closed
            && &c.workspace == workspace
            && server.workspace_incarnations.get(workspace) == Some(&c.workspace_incarnation))
        .max_by_key(|(_, c)| (c.last_input.get(&pane).copied(), c.subscribed.contains(&pane), c.frontend_client))
        .map(|(index, _)| index)
        .ok_or_else(|| api::error("client_unavailable", "No attached client supports switching sessions"))
}

pub fn apply(server: &mut Server, client: &mut Client, target: &str) -> Result<Value, Error> {
    let key = server.workspaces.resolve(target)?;
    let name = key.as_str();
    let incarnation = *server.workspace_incarnations.get(name)
        .ok_or_else(|| api::error("session_not_found", &format!("Session not found: {name}")))?;
    if client.workspace == name { return Ok(crate::session_management::description(server, name)); }
    server.frontend.disconnect(client.frontend_client);
    server.size_claims.release(client.frontend_client);
    client.workspace = name.into();
    client.workspace_closed = false;
    client.workspace_incarnation = incarnation;
    client.subscribed.clear();
    client.revisions.clear();
    client.scenes.subscribe(&[]);
    client.video_cursors.clear();
    client.chromium_flow.clear();
    client.topology.clear();
    client.pane_updates.clear();
    client.notifications.clear();
    client.input_sequences.clear();
    client.last_input.clear();
    for pane in server.sessions.values().filter(|s| s.workspace == name) {
        client.notifications.insert(pane.id, pane.notification_sequence);
        client.input_sequences.insert(pane.id, pane.input_sequence);
    }
    send(client, json!({"type":"session_switched", "workspace":server.workspaces.id(name)}))?;
    // A frontend switching sessions is now showing this one.
    if client.session_switch { server.last_viewed = Some(name.into()); }
    Ok(crate::session_management::description(server, name))
}
