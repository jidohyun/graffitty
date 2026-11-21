//! Queue delivery to verified existing Codex sessions. Never launches or rewrites Codex.
use crate::agent_bridge::Result;
use serde_json::{Value, json};
use std::path::Path;

/// Submit through Codex's native queue; never read or modify the terminal composer.
pub fn queue(target: &Value, text: &str, event_id: &str) -> Result<Value> {
    queue_request(target, "thread/queue/add", json!({"input":[{"type":"text","text":text,"text_elements":[]}],"clientUserMessageId":uuid::Uuid::parse_str(event_id)?.to_string()}))
}

pub fn cancel_queue(target: &Value, submission_id: &str) -> Result<Value> {
    queue_request(target, "thread/queue/delete", json!({"queuedSubmissionId":submission_id}))
}

/// Return a complete queue snapshot; errors must never be treated as an empty queue.
pub fn queued_ids(target: &Value) -> Result<Value> {
    let mut ids = Vec::new();
    let mut cursor = Value::Null;
    let mut seen = std::collections::HashSet::new();
    for _ in 0..128 {
        let page = queue_request(target, "thread/queue/list", json!({"cursor":cursor,"limit":100}))?;
        for item in page["data"].as_array().ok_or("Invalid Codex queue response")? {
            ids.push(item["id"].as_str().ok_or("Missing queued submission ID")?.to_owned());
        }
        cursor = page["nextCursor"].clone();
        if cursor.is_null() { return Ok(json!({"queued_ids":ids})); }
        let next = cursor.as_str().ok_or("Invalid Codex queue cursor")?;
        if !seen.insert(next.to_owned()) { return Err("Repeated Codex queue cursor".into()); }
    }
    Err("Codex queue snapshot exceeded page limit".into())
}

fn queue_request(target: &Value, method: &str, mut params: Value) -> Result<Value> {
    #[cfg(unix)]
    use std::os::unix::net::UnixStream;
    #[cfg(windows)]
    use uds_windows::UnixStream;
    use tungstenite::Message;
    let thread = target["session_id"].as_str().ok_or("Codex thread not resolved from process evidence")?;
    uuid::Uuid::parse_str(thread)?;
    let table = crate::sessions::processes();
    let pid = target["pid"].as_f64().ok_or("Codex PID missing")?;
    let owner = table.get(&(pid as i64)).ok_or("Codex process exited")?;
    if pid != owner.pid as f64 || target["started"].as_str() != Some(&owner.started) {
        return Err("Codex process identity changed".into());
    }
    if target["discovery_transport"] == "codex_tui_listener" {
        let home = Path::new(target["provider_home"].as_str().ok_or("Codex home missing")?);
        let mut rpc = crate::codex_discovery::verify(target, home, owner.pid)?;
        params["threadId"] = json!(thread);
        return rpc.call(method, params);
    }
    let endpoint = {
        if let Some(reason) = target["queue_error"].as_str() { return Err(reason.into()); }
        if target["integrated"] != true {
            return Err("Codex thread has no verified queue binding; no message was sent".into());
        }
        let home = Path::new(target["provider_home"].as_str().ok_or("Codex home not discovered")?);
        let owned_lock = home.join("thread-writer-locks").join(format!("{thread}.lock"));
        if crate::sessions::open_paths(owner.pid).contains(&owned_lock) {
            return Err("Codex --no-daemon has no external queue endpoint; no message was sent".into());
        }
        home.join("app-server-control/app-server-control.sock")
    };
    // Connect only to an existing server. Never start/resume a second writer.
    let stream = UnixStream::connect(endpoint)?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(std::time::Duration::from_secs(5)))?;
    let (mut client, _) = tungstenite::client("ws://localhost/", stream)?;
    params["threadId"] = json!(thread);
    for request in [
        json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"graffitty","version":env!("GRAFFITTY_VERSION")},"capabilities":{"experimentalApi":true}}}),
        json!({"id":2,"method":method,"params":params}),
    ] {
        client.send(Message::Text(request.to_string().into()))?;
        loop {
            if let Message::Text(text) = client.read()? {
                let response: Value = serde_json::from_str(&text)?;
                if response["id"] == request["id"] {
                    if response.get("error").is_some() { return Err(response["error"].to_string().into()); }
                    if request["id"] == 2 { return Ok(response["result"].clone()); }
                    client.send(Message::Text(json!({"method":"initialized"}).to_string().into()))?;
                    break;
                }
            }
        }
    }
    Err("Codex queue did not respond".into())
}
