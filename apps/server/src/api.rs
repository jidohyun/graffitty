//! Stable CLI/MCP error codes at the session owner's capability boundary.
use crate::Error;
use serde_json::{Value, json};

/// Both CLI and persistent RPC adapters consume the same operation result.
pub enum Reply {
    Ready(Value),
    Pending(std::sync::mpsc::Receiver<Value>),
}

pub fn completed(receiver: &std::sync::mpsc::Receiver<Value>) -> Option<Value> {
    match receiver.try_recv() {
        Ok(value) => Some(value),
        Err(std::sync::mpsc::TryRecvError::Empty) => None,
        Err(std::sync::mpsc::TryRecvError::Disconnected) => Some(json!({"error":{"code":"workspace_closed","message":"Terminal closed during input"}})),
    }
}

pub fn rpc_response(request: Value, mut value: Value) -> Value {
    value["request"] = request;
    value["type"] = json!(if value.get("error").is_some() { "error" } else { "ack" });
    if value.get("error").is_some() { value["message"] = value["error"]["message"].clone(); }
    value
}

#[derive(Debug)]
pub struct DispatchError(pub Value);
impl std::fmt::Display for DispatchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0["message"].as_str().unwrap_or("Request failed"))
    }
}
impl std::error::Error for DispatchError {}

pub fn error(code: &str, message: &str) -> Error {
    Box::new(DispatchError(json!({"code":code,"message":message})))
}

pub fn error_details(error: &Error) -> Value {
    error.downcast_ref::<DispatchError>().map(|e| e.0.clone())
        .unwrap_or_else(|| json!({"code":"remote_error","message":error.to_string()}))
}

/// Require the current envelope and authenticate before parameter validation.
pub fn request(value: &Value, resolve: impl FnOnce(&str) -> Option<u64>) -> Result<(u64, &str, Value), Error> {
    if !value.is_object() {
        return Err(error("invalid_request", "Expected JSON object"));
    }
    if value["version"] != 1 {
        return Err(error("unsupported_version", "API version 1 required"));
    }
    let id = value["token"].as_str().and_then(resolve)
        .ok_or_else(|| error("unauthorized", "Valid pane capability required"))?;
    let params = value["params"].clone();
    if !params.is_object() {
        return Err(error("invalid_params", "Expected object params"));
    }
    let method = value["method"].as_str().filter(|method| !method.is_empty())
        .ok_or_else(|| error("invalid_request", "Expected method"))?;
    Ok((id, method, params))
}

pub fn chromium_owner(caller: u64, owner: u64, same_workspace: bool) -> Result<(), Error> {
    if caller != owner || !same_workspace {
        return Err(error("forbidden", "Chromium belongs to another terminal"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_and_request_failures_keep_the_public_error_codes() {
        let resolve = |token: &str| (token == "valid").then_some(7);
        for (value, code) in [
            (json!([]), "invalid_request"),
            (json!({"version":2}), "unsupported_version"),
            (json!({"token":"valid","method":"identify","params":{}}), "unsupported_version"),
            (json!({"version":1,"method":"identify","params":{}}), "unauthorized"),
            (json!({"version":1,"token":"wrong","method":"terminal.type","params":[]}), "unauthorized"),
            (json!({"version":1,"token":"valid","method":"terminal.type","params":[]}), "invalid_params"),
            (json!({"version":1,"token":"valid","method":"identify"}), "invalid_params"),
            (json!({"version":1,"token":"valid","params":{}}), "invalid_request"),
            (json!({"version":1,"token":"valid","method":"","params":{}}), "invalid_request"),
        ] {
            assert_eq!(error_details(&request(&value, resolve).unwrap_err())["code"], code);
        }
        let value = json!({"version":1,"token":"valid","method":"identify","params":{}});
        assert_eq!(request(&value, resolve).unwrap(), (7, "identify", json!({})));
    }

    #[test]
    fn chromium_ownership_is_scoped_to_both_pane_and_workspace() {
        assert!(chromium_owner(7, 7, true).is_ok());
        for (owner, same_workspace) in [(8, true), (7, false)] {
            assert_eq!(error_details(&chromium_owner(7, owner, same_workspace).unwrap_err())["code"], "forbidden");
        }
    }

    #[test]
    fn structured_dispatch_details_survive_without_reclassifying_io_failures() {
        let details = json!({"code":"read_denied","message":"Permission required","node":"%8"});
        let typed: Error = Box::new(DispatchError(details.clone()));
        assert_eq!(error_details(&typed), details);
        let io: Error = std::io::Error::other("Chromium belongs to another terminal").into();
        assert_eq!(error_details(&io)["code"], "remote_error");
    }
}
