//! Remote-client policies independent of a scene tree or transport API.
use std::collections::BTreeMap;

/// View restoration chooses only from the server's current inventory. An
/// empty server stays connected without creating or inventing a session.
pub fn restore_session(sessions: &serde_json::Value, preferred: &str) -> Option<String> {
    let entries = sessions.as_array()?;
    let ids: Vec<_> = entries.iter().filter_map(|entry| entry["id"].as_str()).collect();
    ids.iter().copied().find(|id| *id == preferred)
        .or_else(|| ids.first().copied()).map(str::to_owned)
}

/// The session `step` places from `current` in server order, wrapping at
/// both ends. None when there is no other session to step to.
pub fn adjacent_session(sessions: &serde_json::Value, current: &str, step: i64) -> Option<String> {
    let ids: Vec<_> = sessions.as_array()?.iter().filter_map(|entry| entry["id"].as_str()).collect();
    let Some(index) = ids.iter().position(|id| *id == current) else {
        return ids.first().map(|id| (*id).to_owned());
    };
    let target = ids[(index as i64 + step).rem_euclid(ids.len() as i64) as usize];
    (target != current).then(|| target.to_owned())
}

/// Number shortcuts count from one in server order. Nine selects the final entry.
pub fn numbered_session(sessions: &serde_json::Value, number: u8) -> Option<String> {
    let entries = sessions.as_array()?;
    let target = match number {
        1..=8 => entries.get(usize::from(number - 1)),
        9 => entries.last(),
        _ => None,
    }?;
    target["id"].as_str().map(str::to_owned)
}

/// The previously viewed session, while the server still lists it.
pub fn last_session(sessions: &serde_json::Value, last: &str, current: &str) -> Option<String> {
    let listed = sessions.as_array()?.iter().any(|entry| entry["id"].as_str() == Some(last));
    (listed && last != current).then(|| last.to_owned())
}

/// Where a window goes when its own session `closed` ends: the session it
/// viewed before (`last`), else the first in server order.
///
/// Sessions in `shown` are already held by another window and are skipped.
/// None when nothing is left to show.
pub fn fallback_session(sessions: &serde_json::Value, closed: &str, last: &str, shown: &[String]) -> Option<String> {
    let ids: Vec<_> = sessions.as_array()?.iter().filter_map(|entry| entry["id"].as_str())
        .filter(|id| *id != closed && !shown.iter().any(|other| other == id)).collect();
    ids.iter().copied().find(|id| *id == last).or_else(|| ids.first().copied()).map(str::to_owned)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct WireId(pub i64);
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct LocalId(pub i64);
#[derive(Default)]
pub struct Namespace {
    forward: BTreeMap<WireId, LocalId>,
    reverse: BTreeMap<LocalId, WireId>,
}
impl Namespace {
    pub fn bind(&mut self, wire: WireId, local: LocalId) {
        if let Some(old) = self.forward.insert(wire, local) {
            self.reverse.remove(&old);
        }
        if let Some(old) = self.reverse.insert(local, wire) {
            if old != wire {
                self.forward.remove(&old);
            }
        }
    }
    pub fn local(&self, wire: WireId) -> Option<LocalId> {
        self.forward.get(&wire).copied()
    }
    pub fn wire(&self, local: LocalId) -> WireId {
        self.reverse.get(&local).copied().unwrap_or(WireId(local.0))
    }
    pub fn pairs(&self) -> impl Iterator<Item = (WireId, LocalId)> + '_ {
        self.forward.iter().map(|(a, b)| (*a, *b))
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Field {
    Literal,
    Pane,
    Target,
    Tab,
    Node,
    Edge,
    Queues,
    ByEdge,
}
impl Field {
    pub fn from_key(key: &str) -> Self {
        match key {
            "pane" => Self::Pane,
            "target" => Self::Target,
            "tab" => Self::Tab,
            "edge" => Self::Edge,
            "queues" => Self::Queues,
            "by_edge" => Self::ByEdge,
            "node" | "from" | "to" | "source" | "self" | "chromium" | "id" | "owner" | "focus"
            | "closed" => Self::Node,
            _ => Self::Literal,
        }
    }
    pub fn map(self, text: &str, mut id: impl FnMut(i64) -> i64) -> String {
        self.map_with(text, &mut id)
    }
    fn map_with(self, text: &str, id: &mut dyn FnMut(i64) -> i64) -> String {
        if self == Self::Edge {
            return text
                .split('>')
                .map(|end| Self::Node.map_with(end, id))
                .collect::<Vec<_>>()
                .join(">");
        }
        if matches!(self, Self::Literal | Self::Queues | Self::ByEdge) {
            return text.into();
        }
        if let Some(rest) = text.strip_prefix('%') {
            let (number, suffix) = rest
                .split_once('/')
                .map(|(n, s)| (n, format!("/{s}")))
                .unwrap_or((rest, String::new()));
            if !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()) {
                if let Ok(number) = number.parse::<i64>() {
                    return format!("%{}{suffix}", id(number));
                }
            }
        }
        if matches!(self, Self::Target | Self::Tab) {
            if let Some(rest) = text.strip_prefix('@') {
                let (number, suffix) = rest
                    .split_once('.')
                    .map(|(n, s)| (n, format!(".{s}")))
                    .unwrap_or((rest, String::new()));
                if !number.is_empty() && number.bytes().all(|b| b.is_ascii_digit()) {
                    if let Ok(number) = number.parse::<i64>() {
                        return format!("@{}{suffix}", id(number));
                    }
                }
            }
        }
        text.into()
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CloseAction {
    Retry,
    Authentication,
    Protocol,
}
pub fn close_action(code: i64, password_verified: bool) -> CloseAction {
    match code {
        1008 if !password_verified => CloseAction::Authentication,
        1008 => CloseAction::Protocol,
        1002 | 1003 | 1007 | 1009 | 1010 | 1011 => CloseAction::Protocol,
        _ => CloseAction::Retry,
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SocketState {
    Absent,
    Connecting,
    Open,
    Closing,
    Closed,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PollAction {
    Wait,
    Connect,
    Read,
    Closed,
    Timeout,
}
pub fn poll_action(
    enabled: bool,
    state: SocketState,
    buffered: bool,
    now: u64,
    deadline: u64,
    retry: u64,
) -> PollAction {
    if !enabled {
        return PollAction::Wait;
    }
    match state {
        SocketState::Absent => {
            if now >= retry {
                PollAction::Connect
            } else {
                PollAction::Wait
            }
        }
        SocketState::Closed if !buffered => PollAction::Closed,
        SocketState::Connecting if now >= deadline => PollAction::Timeout,
        SocketState::Open => PollAction::Read,
        _ if buffered => PollAction::Read,
        _ => PollAction::Wait,
    }
}
/// Field-aware graph/RPC namespace translation shared by native frontends.
/// Message text, paths, and node-defined payloads remain opaque.
pub fn map_value(value: &serde_json::Value, field: Field, id: &mut dyn FnMut(i64) -> i64) -> serde_json::Value {
    use serde_json::Value;
    match value {
        Value::String(text) => Value::String(field.map_with(text,id)),
        Value::Array(items) => Value::Array(items.iter().map(|value| map_value(value,field,id)).collect()),
        Value::Object(object) => Value::Object(object.iter().map(|(key,value)| {
            let mapped = match field {Field::Queues=>Field::Node,Field::ByEdge=>Field::Edge,_=>Field::Literal}.map_with(key,id);
            let value = if matches!(key.as_str(),"payload" | "content" | "renderings") {value.clone()}
                else {map_value(value,Field::from_key(key),id)};
            (mapped,value)
        }).collect()),
        _ => value.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn view_restore_uses_only_live_sessions_and_does_not_create_one() {
        let sessions = serde_json::json!([{"id":"$3"},{"id":"$8"}]);
        assert_eq!(restore_session(&sessions, "$8").as_deref(), Some("$8"));
        assert_eq!(restore_session(&sessions, "$0").as_deref(), Some("$3"));
        assert_eq!(restore_session(&serde_json::json!([]), "$8"), None);
    }

    #[test]
    fn session_stepping_wraps_and_last_session_must_still_be_listed() {
        let sessions = serde_json::json!([{"id":"$1"},{"id":"$2"},{"id":"$3"}]);
        assert_eq!(adjacent_session(&sessions, "$3", 1).as_deref(), Some("$1"));
        assert_eq!(adjacent_session(&sessions, "$1", -1).as_deref(), Some("$3"));
        assert_eq!(adjacent_session(&sessions, "$2", 1).as_deref(), Some("$3"));
        assert_eq!(adjacent_session(&sessions, "", 1).as_deref(), Some("$1"));
        assert_eq!(adjacent_session(&serde_json::json!([{"id":"$1"}]), "$1", 1), None);
        assert_eq!(adjacent_session(&serde_json::json!([]), "$1", 1), None);
        assert_eq!(numbered_session(&sessions, 2).as_deref(), Some("$2"));
        assert_eq!(numbered_session(&sessions, 9).as_deref(), Some("$3"));
        assert_eq!(numbered_session(&sessions, 4), None);
        let many = serde_json::json!((1..=12).map(|id| serde_json::json!({"id": id.to_string()})).collect::<Vec<_>>());
        assert_eq!(numbered_session(&many, 8).as_deref(), Some("8"));
        assert_eq!(numbered_session(&many, 9).as_deref(), Some("12"));
        assert_eq!(last_session(&sessions, "$2", "$3").as_deref(), Some("$2"));
        assert_eq!(last_session(&sessions, "$9", "$3"), None);
        assert_eq!(last_session(&sessions, "$3", "$3"), None);
        assert_eq!(last_session(&sessions, "", "$3"), None);
    }

    #[test]
    fn closed_session_falls_back_to_one_no_other_window_shows() {
        let sessions = serde_json::json!([{"id":"$1"},{"id":"$2"},{"id":"$3"}]);
        let none: &[String] = &[];
        assert_eq!(fallback_session(&sessions, "$1", "$3", none).as_deref(), Some("$3"));
        assert_eq!(fallback_session(&sessions, "$1", "", none).as_deref(), Some("$2"));
        // The closed session is never a target, even when still listed or last.
        assert_eq!(fallback_session(&sessions, "$2", "$2", none).as_deref(), Some("$1"));
        assert_eq!(fallback_session(&sessions, "$1", "$2", &["$2".into()]).as_deref(), Some("$3"));
        assert_eq!(fallback_session(&sessions, "$1", "", &["$2".into(), "$3".into()]), None);
        assert_eq!(fallback_session(&serde_json::json!([{"id":"$1"}]), "$1", "", none), None);
        assert_eq!(fallback_session(&serde_json::json!([]), "$1", "", none), None);
    }

    #[test]
    fn identities_roundtrip_without_remapping_titles_or_pids() {
        let mut ns = Namespace::default();
        ns.bind(WireId(0), LocalId(70));
        ns.bind(WireId(8), LocalId(80));
        let edge = Field::Edge.map("%0/out>%8/in", |n| ns.local(WireId(n)).unwrap().0);
        assert_eq!(edge, "%70/out>%80/in");
        assert_eq!(
            Field::Edge.map(&edge, |n| ns.wire(LocalId(n)).0),
            "%0/out>%8/in"
        );
        assert_eq!(Field::Literal.map("%0", |_| 999), "%0");
        assert_eq!(Field::Tab.map("@8.1", |_| 80), "@80.1");
        assert_eq!(Field::Node.map("%oops", |_| 999), "%oops");
    }
    #[test]
    fn final_packets_drain_and_only_transient_failures_retry() {
        assert_eq!(
            poll_action(true, SocketState::Closed, true, 20, 10, 0),
            PollAction::Read
        );
        assert_eq!(
            poll_action(true, SocketState::Closed, false, 20, 10, 0),
            PollAction::Closed
        );
        assert_eq!(
            poll_action(false, SocketState::Absent, false, 100, 0, 0),
            PollAction::Wait
        );
        assert_eq!(
            poll_action(true, SocketState::Absent, false, 99, 0, 100),
            PollAction::Wait
        );
        assert_eq!(
            poll_action(true, SocketState::Absent, false, 100, 0, 100),
            PollAction::Connect
        );
        assert_eq!(
            poll_action(true, SocketState::Connecting, false, 100, 100, 0),
            PollAction::Timeout
        );
        assert_eq!(close_action(1008, false), CloseAction::Authentication);
        assert_eq!(close_action(1008, true), CloseAction::Protocol);
        assert_eq!(close_action(1011, true), CloseAction::Protocol);
        assert_eq!(close_action(1006, true), CloseAction::Retry);
    }
}
