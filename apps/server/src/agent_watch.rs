//! Capability-scoped change notifications. Payloads are fetched through the
//! ordinary graph API, so revocation and recipient redaction have one path.
use crate::{ApiRequest, Server, api};
use serde_json::{Value, json};
use std::{
    sync::mpsc::{SyncSender, TrySendError},
    time::{Duration, Instant},
};

pub(crate) struct Watch {
    pane: u64,
    token: String,
    workspace: String,
    revision: ((u64, u64), bool),
    sent: Instant,
    reply: SyncSender<Value>,
}

pub(crate) fn subscribe(server: &mut Server, watches: &mut Vec<Watch>, request: ApiRequest) {
    let mut probe = request.value.clone();
    probe["method"] = json!("graph.adjacent");
    let api::Reply::Ready(mut response) = server.api(probe) else {
        return;
    };
    if response.get("error").is_none() {
        let token = request.value["token"].as_str().unwrap_or("");
        if let Some(session) = server.sessions.values().find(|s| s.token == token)
            && let Some(graph) = server.graphs.get(&session.workspace)
            && watches.len() < 64
        {
            watches.push(Watch {
                pane: session.id,
                token: token.into(),
                workspace: session.workspace.clone(),
                revision: (graph.notification_revision(), session.typing_guard.blocked()),
                sent: Instant::now(),
                reply: request.reply.clone(),
            });
            response = json!({"result":{"watching":true}});
        } else {
            response =
                json!({"error":{"code":"unavailable","message":"Agent subscription unavailable"}});
        }
    }
    response["id"] = request.value["id"].clone();
    response["version"] = json!(1);
    let _ = request.reply.try_send(response);
}

pub(crate) fn flush(server: &Server, watches: &mut Vec<Watch>) {
    watches.retain_mut(|watch| {
        let Some(session) = server.sessions.get(&watch.pane)
            .filter(|s| s.token == watch.token && s.workspace == watch.workspace) else { return false; };
        let Some(graph) = server.graphs.get(&session.workspace) else { return false; };
        let revision = (graph.notification_revision(), session.typing_guard.blocked());
        let changed = revision != watch.revision;
        if !changed && watch.sent.elapsed() < Duration::from_secs(5) { return true; }
        let event = json!({"version":1,"method":if changed {"graph.changed"} else {"graph.keepalive"},"params":{}});
        match watch.reply.try_send(event) {
            Ok(()) => { watch.revision = revision; watch.sent = Instant::now(); true }
            // A slow consumer must reconnect/resynchronize, not retain an
            // unbounded queue or silently lose a permission change.
            Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => false,
        }
    });
}
