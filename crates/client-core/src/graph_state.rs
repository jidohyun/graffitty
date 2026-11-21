//! Apply typed graph updates for all frontends, independent of transport.
//! Reject an invalid packet before changing state.
//!
//! The workspace server handles delivery, permissions, retention, and revisions.
use graffitty_protocol::graph::{self, Edge, Journal, JournalRow, Snapshot};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Serialize)]
pub struct Transfer {
    pub source: String,
    pub target: String,
    pub event_id: String,
    pub status: String,
    pub failed: bool,
}
#[derive(Default, Debug, Serialize)]
pub struct Changes {
    pub changed: bool,
    pub journal_edges: BTreeSet<String>,
    pub transfers: Vec<Transfer>,
    pub runs: BTreeSet<String>,
    pub limits: bool,
}
#[derive(Default)]
pub struct JournalCache {
    pub snapshots: BTreeMap<u64, Journal>,
    pub entries: BTreeMap<String, JournalRow>,
}
impl JournalCache {
    pub fn receive(&mut self, owner: u64, snapshot: Option<Journal>) -> BTreeSet<String> {
        let old = self.snapshots.get(&owner).cloned().unwrap_or_default();
        if let Some(snapshot) = snapshot {
            self.snapshots.insert(owner, snapshot);
        } else {
            self.snapshots.remove(&owner);
        }
        let entries: BTreeMap<_, _> = self
            .snapshots
            .values()
            .flat_map(|s| s.events.iter())
            .map(|row| (row.delivery.event_id.clone(), row.clone()))
            .collect();
        let mut affected = BTreeSet::new();
        for id in self.entries.keys().chain(entries.keys()) {
            if self.entries.get(id) == entries.get(id) {
                continue;
            }
            for row in [self.entries.get(id), entries.get(id)]
                .into_iter()
                .flatten()
            {
                affected.insert(row.edge.clone());
            }
        }
        let empty = Journal::default();
        let current = self.snapshots.get(&owner).unwrap_or(&empty);
        for key in old.by_edge.keys().chain(current.by_edge.keys()) {
            if old.by_edge.get(key) != current.by_edge.get(key) {
                affected.insert(key.clone());
            }
        }
        self.entries = entries;
        affected
    }
    pub fn snapshot(&self, edge: &str) -> Journal {
        let mut result = Journal::default();
        result.events = self
            .entries
            .values()
            .filter(|row| edge.is_empty() || row.edge == edge)
            .cloned()
            .collect();
        result
            .events
            .sort_by(|a, b| b.queued_at.total_cmp(&a.queued_at));
        let mut total = 0u64;
        for value in self.snapshots.values() {
            result.history_limit = value.history_limit;
            result.transition_limit = value.transition_limit;
            if edge.is_empty() {
                result.pending = result.pending.saturating_add(value.pending);
                total = total
                    .saturating_add(value.events.len() as u64)
                    .saturating_add(value.omitted);
            } else if let Some(count) = value.by_edge.get(edge) {
                result.pending = result.pending.saturating_add(count.pending);
                total = total.saturating_add(count.total);
            }
        }
        result.omitted = total.saturating_sub(result.events.len() as u64);
        result
    }
}
#[derive(Default)]
pub struct GraphState {
    pub snapshots: BTreeMap<u64, Snapshot>,
    pub journal: JournalCache,
    previews: BTreeMap<u64, BTreeMap<String, Option<Edge>>>,
}
impl GraphState {
    pub fn receive(&mut self, owner: u64, value: Value) -> graph::Result<Changes> {
        let snapshot = if value.as_object().is_some_and(|v| v.is_empty()) {
            None
        } else {
            Some(Snapshot::decode(value)?)
        };
        Ok(self.replace(owner, snapshot))
    }
    pub fn replace(&mut self, owner: u64, snapshot: Option<Snapshot>) -> Changes {
        let mut changes = Changes::default();
        let before = self.snapshots.get(&owner);
        if before == snapshot.as_ref() {
            return changes;
        }
        changes.changed = true;
        self.previews.remove(&owner);
        let empty = Snapshot::default();
        let old = before.unwrap_or(&empty);
        let next = snapshot.as_ref().unwrap_or(&empty);
        // Attaching and reconnecting import history silently, not as new deliveries.
        if before.is_some() {
            let previous: BTreeMap<_, _> = old
                .journal
                .events
                .iter()
                .map(|row| (&row.delivery.event_id, &row.status))
                .collect();
            for row in &next.journal.events {
                if row.pending || previous.get(&row.delivery.event_id).copied() == Some(&row.status)
                {
                    continue;
                }
                let failed = row.status.starts_with("failed") || row.status.starts_with("cancel");
                if failed
                    || matches!(
                        row.status.as_str(),
                        "sent to receiver" | "submitted" | "delivered"
                    )
                {
                    changes.transfers.push(Transfer {
                        source: row.delivery.source.clone(),
                        target: row.delivery.target.clone(),
                        event_id: row.delivery.event_id.clone(),
                        status: row.status.clone(),
                        failed,
                    });
                }
            }
        }
        for key in old.runs.keys().chain(next.runs.keys()) {
            if old.runs.get(key) != next.runs.get(key) {
                changes.runs.insert(key.clone());
            }
        }
        changes.limits = old.limits != next.limits;
        changes.journal_edges = self
            .journal
            .receive(owner, snapshot.as_ref().map(|s| s.journal.clone()));
        if let Some(snapshot) = snapshot {
            self.snapshots.insert(owner, snapshot);
        } else {
            self.snapshots.remove(&owner);
        }
        changes
    }
    pub fn preview_connect(&mut self, owner: u64, params: &Value) -> graph::Result<Edge> {
        let state = self
            .snapshots
            .get(&owner)
            .ok_or("Graph server is not connected")?;
        let from = state
            .nodes
            .iter()
            .find(|n| params["from"] == n.node)
            .ok_or("Choose a node on the same server workspace")?;
        let to = state
            .nodes
            .iter()
            .find(|n| params["to"] == n.node)
            .ok_or("Choose a node on the same server workspace")?;
        let edge = graph::connection(params, from, to, |key| {
            state.edges.iter().find(|e| e.key() == key).cloned()
        })?;
        self.previews
            .entry(owner)
            .or_default()
            .insert(edge.key(), Some(edge.clone()));
        Ok(edge)
    }
    pub fn rollback(&mut self, owner: u64) {
        self.previews.remove(&owner);
    }
    pub fn preview_disconnect(
        &mut self,
        owner: u64,
        source: &str,
        target: &str,
        from_port: &str,
        to_port: &str,
    ) {
        let Some(snapshot) = self.snapshots.get(&owner) else {
            return;
        };
        let mut edges: BTreeMap<_, _> = snapshot
            .edges
            .iter()
            .map(|edge| (edge.key(), edge.clone()))
            .collect();
        let previews = self.previews.entry(owner).or_default();
        for (key, edge) in previews.iter() {
            if let Some(edge) = edge {
                edges.insert(key.clone(), edge.clone());
            } else {
                edges.remove(key);
            }
        }
        for (key, edge) in edges {
            if edge.from == source
                && edge.to == target
                && (from_port.is_empty() || edge.from_port == from_port)
                && (to_port.is_empty() || edge.to_port == to_port)
            {
                previews.insert(key, None);
            }
        }
    }
    /// Godot's dynamic rendering boundary. Rust frontends can access typed
    /// snapshots directly; converting to UI dictionaries never parses JSON again.
    pub fn view(&self) -> Value {
        let mut nodes = BTreeMap::new();
        let mut owners = BTreeMap::new();
        let mut edges = BTreeMap::new();
        let mut queues = BTreeMap::new();
        let mut receipts = Vec::new();
        for (owner, snapshot) in &self.snapshots {
            for node in &snapshot.nodes {
                nodes.insert(&node.node, node);
                owners.insert(&node.node, *owner);
            }
            for edge in &snapshot.edges {
                edges.insert(edge.key(), edge);
            }
            if let Some(previews) = self.previews.get(owner) {
                for (key, edge) in previews {
                    if let Some(edge) = edge {
                        edges.insert(key.clone(), edge);
                    } else {
                        edges.remove(key);
                    }
                }
            }
            queues.extend(snapshot.queues.iter());
            receipts.extend(&snapshot.receipts);
        }
        let event_edges: BTreeMap<_, _> = self
            .journal
            .entries
            .iter()
            .map(|(id, row)| (id, &row.edge))
            .collect();
        json!({"nodes":nodes,"owners":owners,"edges":edges,"queues":queues,"receipts":receipts,
            "event_edges":event_edges,"journal_entries":self.journal.entries})
    }
}

/// Decode text packets in Rust for all transports (including the Godot remote
/// adapter). Integer IDs/checkpoints never make a JSON -> floating-point detour.
pub fn decode_message(bytes: &[u8]) -> graph::Result<Value> {
    if bytes.len() > 8 * 1024 * 1024 {
        return Err("Server message exceeds the size limit".into());
    }
    let message: Value =
        serde_json::from_slice(bytes).map_err(|e| format!("Invalid server message: {e}"))?;
    if !message.is_object() {
        return Err("Invalid server message".into());
    }
    if message["type"] == "topology" {
        if let Some(graph) = message.get("graph") {
            Snapshot::decode(graph.clone())?;
        }
    }
    Ok(message)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot() -> Value {
        json!({"nodes":[{"node":"%1","provider":"claude"},{"node":"%2","kind":"custom"}],
        "edges":[],"queues":{},"journal":{"events":[]},"limits":{"run_messages":100}})
    }
    fn row(status: &str, pending: bool) -> Value {
        json!({"event_id":"e","source":"%1","target":"%2","edge":"%1/send>%2/in", "pending":pending,
        "status":status,"queued_at":1.,"updated_at":2.})
    }
    #[test]
    fn atomic_receive_rejects_malformed_packets_and_keeps_exact_integers() {
        let mut state = GraphState::default();
        let valid = snapshot();
        state.receive(1, valid.clone()).unwrap();
        let before = state.view();
        for invalid in [
            json!({"nodes":[{"node":"%1","provider":7}]}),
            json!({"edges":[{"from":"%1","to":"%2","send":"yes"}]}),
            json!({"journal":{"events":[row("delivered",false),{"event_id":"missing fields"}]}}),
        ] {
            assert!(state.receive(1, invalid).is_err());
            assert_eq!(state.view(), before);
        }
        let message=decode_message(br#"{"type":"ack","request":9007199254740993,"result":{"checkpoint":{"byte_offset":9007199254740995}}}"#).unwrap();
        assert_eq!(message["request"].as_u64(), Some(9007199254740993));
        assert_eq!(
            message["result"]["checkpoint"]["byte_offset"].as_u64(),
            Some(9007199254740995)
        );
        assert!(decode_message(br#"{"type":"topology","graph":{"queues":[]}}"#).is_err());
    }
    #[test]
    fn previews_stay_visual_and_other_workspaces_survive_rejection() {
        let mut state = GraphState::default();
        let first =
            json!({"nodes":[{"node":"%1","provider":"claude"},{"node":"%2","provider":"codex"}]});
        let second =
            json!({"nodes":[{"node":"%3","provider":"claude"},{"node":"%4","provider":"codex"}]});
        state.receive(1, first.clone()).unwrap();
        state.receive(2, second).unwrap();
        let first_edge = state
            .preview_connect(1, &json!({"from":"%1","to":"%2","send":true}))
            .unwrap();
        let second_edge = state
            .preview_connect(2, &json!({"from":"%3","to":"%4","send":true}))
            .unwrap();
        assert_eq!(state.view()["edges"].as_object().unwrap().len(), 2);
        assert!(state.snapshots[&1].edges.is_empty());
        assert!(state.snapshots[&1].queues.is_empty());
        state.rollback(1);
        assert!(state.view()["edges"].get(first_edge.key()).is_none());
        assert!(state.view()["edges"].get(second_edge.key()).is_some());
        state.preview_disconnect(2, "%3", "%4", "send", "in");
        assert!(state.view()["edges"].as_object().unwrap().is_empty());
        state.rollback(2);
        let mut accepted = first;
        accepted["edges"] = json!([first_edge]);
        state.receive(1, accepted).unwrap();
        assert_eq!(state.view()["edges"].as_object().unwrap().len(), 1);
    }
    #[test]
    fn imports_are_quiet_live_transitions_once_and_owners_stay_isolated() {
        let mut state = GraphState::default();
        let mut first = snapshot();
        first["journal"]["events"] = json!([row("delivered", false)]);
        assert!(
            state
                .receive(1, first.clone())
                .unwrap()
                .transfers
                .is_empty()
        );
        assert!(!state.receive(1, first.clone()).unwrap().changed);
        first["journal"]["events"] = json!([row("cancelled: removed", false)]);
        let changes = state.receive(1, first.clone()).unwrap();
        assert_eq!(changes.transfers.len(), 1);
        assert!(changes.transfers[0].failed);
        let mut second = snapshot();
        second["nodes"] = json!([{"node":"%3","kind":"custom"}]);
        state.receive(2, second).unwrap();
        state.receive(1, json!({})).unwrap();
        assert_eq!(state.view()["owners"]["%3"], 2);
        assert!(state.view()["nodes"].get("%1").is_none());
        assert!(state.journal.entries.is_empty());
        assert!(state.receive(1, first).unwrap().transfers.is_empty());
    }
}
