//! Server-qualified control belongs to the authenticated viewer capability,
//! never a pane token. Resolve on the owner so GUI focus cannot redirect it.
use crate::{Error, Server, api, terminal_api, workspace};
use graffitty_protocol::controller::Request;
use serde_json::{Value, json};

pub fn dispatch(server: &mut Server, value: &Value) -> Result<api::Reply, Error> {
    let request: Request = serde_json::from_value(value.clone())
        .map_err(|e| api::error("invalid_request", &e.to_string()))?;
    request
        .validate()
        .map_err(|e| api::error("invalid_request", e))?;
    let target = request
        .params
        .get("target")
        .map(|v| {
            v.as_str()
                .ok_or_else(|| api::error("invalid_target", "target must be a string"))
        })
        .transpose()?;
    if request.method == "pane.list" {
        if request
            .params
            .as_object()
            .unwrap()
            .keys()
            .any(|key| key != "target")
        {
            return Err(api::error(
                "invalid_params",
                "pane.list accepts only target",
            ));
        }
        let selected = target
            .filter(|s| !s.is_empty())
            .map(|s| server.workspaces.resolve(s))
            .transpose()
            .map_err(|e| api::error("invalid_target", &e.to_string()))?;
        let keys: Vec<_> = server
            .workspaces
            .iter()
            .filter(|k| selected.as_ref().is_none_or(|s| s == *k))
            .cloned()
            .collect();
        let mut panes = Vec::new();
        for key in keys {
            workspace::sync(server, &key)?;
            let state = server.workspace_state.snapshot(&key);
            let session = server.workspaces.id(&key);
            for (tab_index, tab) in state.order.iter().enumerate() {
                for (pane_index, pane) in state.layout.tabs[tab].numbered_keys().iter().enumerate()
                {
                    let id = graffitty_workspace_core::pane_id::parse(pane);
                    let kind = if id.is_some_and(|id| server.sessions.contains_key(&id)) {
                        "terminal"
                    } else {
                        "chromium"
                    };
                    panes.push(json!({"id":pane,"pane":pane,"type":kind,"session":session,
                        "session_name":server.workspaces.info(&key).name,"tab":format!("@{tab}"),
                        "target":pane,"position_target":format!("{session}:{}.{}", tab_index+1, pane_index+1)}));
                }
            }
        }
        return Ok(api::Reply::Ready(json!({"result":{"panes":panes}})));
    }
    let target = target
        .filter(|s| !s.is_empty())
        .ok_or_else(|| api::error("invalid_target", "Specify %ID or session:tab.pane"))?;
    let id = if let Some(id) = graffitty_workspace_core::pane_id::parse(target) {
        id
    } else {
        let (name, position) = target
            .rsplit_once(':')
            .filter(|(name, position)| !name.is_empty() && !position.is_empty())
            .ok_or_else(|| {
                api::error(
                    "invalid_target",
                    "Remote targets require %ID or session:tab.pane",
                )
            })?;
        let key = server
            .workspaces
            .resolve(name)
            .map_err(|e| api::error("invalid_target", &e.to_string()))?;
        workspace::sync(server, &key)?;
        let pane = terminal_api::resolve(
            &server.workspace_state.snapshot(&key),
            &format!(":{position}"),
        )
        .ok_or_else(|| {
            api::error(
                "invalid_target",
                "Unknown pane target (pane numbers start at 1)",
            )
        })?;
        graffitty_workspace_core::pane_id::parse(&pane)
            .ok_or_else(|| api::error("invalid_target", "Invalid pane identity"))?
    };
    if !server.sessions.contains_key(&id) {
        return Err(api::error("invalid_target", "Unknown terminal pane"));
    }
    let mut params = request.params;
    params["target"] = json!(format!("%{id}"));
    // The viewer selected a terminal with its server capability; reuse all
    // input validation, pacing, mode encoding and completion handling.
    server.request(id, &request.method, &params)
}
