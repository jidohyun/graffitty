//! Resolve Codex tool calls at the session owner, including detached panes.
use crate::{Error, Server, api};
use serde_json::{Value, json};

pub fn start(server: &mut Server, request: &Value) -> Result<api::Reply, Error> {
    let (_, _, params) = api::request(request, |token| (token == server.local_token).then_some(0))?;
    let thread = params["thread_id"]
        .as_str()
        .filter(|id| uuid::Uuid::parse_str(id).is_ok())
        .ok_or_else(|| api::error("invalid_thread", "Expected a Codex thread UUID"))?;
    let roots: Vec<_> = server
        .sessions
        .values()
        .filter(|s| !s.exited)
        .map(|s| {
            let key = format!("%{}", s.id);
            let node = &server.graphs[&s.workspace].nodes[&key];
            json!({"node":key,"pid":s.pid(),"foreground":s.foreground(),"agent_pid":node["pid"],
            "started":node["started"],"provider_home":node["provider_home"]})
        })
        .collect();
    let key = format!("context:{}", uuid::Uuid::new_v4());
    // Each request gets fresh process evidence, never a cached graph binding.
    if !server.workers.start(
        &server.cli,
        key.clone(),
        json!({"op":"scan","roots":roots}),
        json!({"thread":thread,"roots":roots}),
    ) {
        return Err(api::error("busy", "Agent discovery busy; retry shortly"));
    }
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    server.agent_contexts.insert(key, sender);
    Ok(api::Reply::Pending(receiver))
}

pub fn finish(server: &mut Server, key: &str, context: &Value, found: &Value) {
    let Some(reply) = server.agent_contexts.remove(key) else {
        return;
    };
    let result = resolve(context, found, |id, root| {
        server
            .sessions
            .get(&id)
            .filter(|s| {
                !s.exited
                    && json!(s.pid()) == root["pid"]
                    && json!(s.foreground()) == root["foreground"]
            })
            .map(|s| s.token.clone())
    });
    let value = match result {
        Ok(result) => json!({"result":result}),
        Err(error) => json!({"error":api::error_details(&error)}),
    };
    let _ = reply.try_send(value);
}

fn resolve(
    context: &Value,
    found: &Value,
    live_token: impl Fn(u64, &Value) -> Option<String>,
) -> Result<Value, Error> {
    if let Some(error) = found.get("error") {
        return Err(api::error(
            "discovery_error",
            error["message"]
                .as_str()
                .unwrap_or("Agent discovery failed"),
        ));
    }
    let states = found
        .as_object()
        .ok_or_else(|| api::error("discovery_error", "Invalid discovery response"))?;
    let mut matches = Vec::new();
    let mut notes = Vec::new();
    for root in context["roots"].as_array().into_iter().flatten() {
        let Some(key) = root["node"].as_str() else {
            continue;
        };
        let Some(id) = graffitty_workspace_core::pane_id::parse(key) else {
            continue;
        };
        let Some(token) = live_token(id, root) else {
            continue;
        };
        let Some(state) = states.get(key).filter(|s| s["provider"] == "codex") else {
            continue;
        };
        if state["session_id"] == context["thread"] {
            matches.push(json!({"pane":key,"token":token}));
        } else if let Some(note) = state["discovery_note"].as_str() {
            // Preserve the reason a running Codex could not be identified.
            if !notes.contains(&note) {
                notes.push(note);
            }
        }
    }
    if matches.len() == 1 {
        return Ok(matches.remove(0));
    }
    let mut message = format!(
        "Found {} live Graffitty panes for this Codex thread.",
        matches.len()
    );
    if !notes.is_empty() {
        message += &format!(" {}", notes.join(" "));
    }
    if matches.len() > 1 {
        message += " Close duplicate Codex clients for this thread before retrying.";
    } else {
        message += &format!(
            " Resume the thread in its Graffitty terminal; if Codex lost its binding after a daemon restart, exit and run `codex resume {}` there.",
            context["thread"].as_str().unwrap_or("<thread-id>")
        );
    }
    Err(api::error("unresolved_thread", &message))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_exact_thread_match_requires_a_live_unchanged_pane() {
        let context =
            json!({"thread":"thread-a","roots":[{"node":"%1","pid":10},{"node":"%2","pid":20}]});
        let found = json!({"%1":{"provider":"codex","session_id":"thread-b"},
            "%2":{"provider":"codex","session_id":"thread-a"}});
        let token =
            |id, root: &Value| (root["pid"] == json!(id * 10)).then(|| format!("token-{id}"));
        assert_eq!(
            resolve(&context, &found, token).unwrap(),
            json!({"pane":"%2","token":"token-2"})
        );
        assert!(resolve(&context, &found, |_, _| None).is_err());
        let mut switched = found.clone();
        switched["%2"]["session_id"] = json!("thread-c");
        assert!(resolve(&context, &switched, token).is_err());
        let mut ambiguous = found.clone();
        ambiguous["%1"]["session_id"] = json!("thread-a");
        assert!(resolve(&context, &ambiguous, token).is_err());
        let mut wrong_provider = found;
        wrong_provider["%2"]["provider"] = json!("claude");
        assert!(resolve(&context, &wrong_provider, token).is_err());
    }

    #[test]
    fn missing_provider_evidence_and_worker_errors_are_visible() {
        let context = json!({"thread":"thread-a","roots":[{"node":"%1","pid":10}]});
        let found = json!({"%1":{"provider":"codex","discovery_note":"Codex listener matches 0 main threads"}});
        let error = resolve(&context, &found, |_, _| Some("secret".into())).unwrap_err();
        let details = api::error_details(&error);
        assert_eq!(details["code"], "unresolved_thread");
        assert!(
            details["message"]
                .as_str()
                .unwrap()
                .contains("Codex listener matches 0")
        );
        assert!(!details.to_string().contains("secret"));
        let error = resolve(
            &context,
            &json!({"error":{"message":"worker timed out"}}),
            |_, _| None,
        )
        .unwrap_err();
        assert_eq!(
            api::error_details(&error),
            json!({"code":"discovery_error","message":"worker timed out"})
        );
    }
}
