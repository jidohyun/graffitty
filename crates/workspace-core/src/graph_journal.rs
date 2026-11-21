//! Server-owned, metadata-only delivery history. Payloads never enter snapshots.
use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};

const HISTORY_LIMIT: usize = 200;
const TRANSITION_LIMIT: usize = 20;

pub(crate) struct Journal {
    history_limit: usize,
    transition_limit: usize,
    entries: BTreeMap<String, Value>,
    finished: VecDeque<String>,
}

impl Default for Journal {
    fn default() -> Self { Self::with_limits(HISTORY_LIMIT, TRANSITION_LIMIT) }
}
impl Journal {
    pub fn with_limits(history_limit: usize, transition_limit: usize) -> Self {
        Self { history_limit, transition_limit, entries: BTreeMap::new(), finished: VecDeque::new() }
    }
    pub fn native_pending(&self, id: &str) -> bool {
        self.entries
            .get(id)
            .is_some_and(|row| row["pending"] == true && row["status"] == "queued in Codex")
    }
    pub fn started(&mut self, target: &str, prompt: &str) {
        let header = prompt.lines().next().unwrap_or("");
        if !header.starts_with("[Graffitty ") || !header.ends_with(']') {
            return;
        }
        let Some(id) = header
            .split_once("; event ")
            .and_then(|(_, tail)| tail.split_once("; run "))
            .map(|(id, _)| id)
        else {
            return;
        };
        if let Some(row) = self
            .entries
            .get(id)
            .filter(|row| row["target"] == target)
            .cloned()
        {
            self.record(&row, "sent to receiver", false);
        }
    }
    pub fn record(&mut self, event: &Value, status: &str, pending: bool) {
        let Some(id) = event["event_id"].as_str() else {
            return;
        };
        let now = super::graph::now();
        let entry = self.entries.entry(id.into()).or_insert_with(|| {
            json!({
                "event_id":id,"source":event["source"],"target":event["target"],
                "source_port":event["source_port"],"target_port":event["target_port"],
                "edge":super::graph::event_key(event),"run_id":event["run_id"],
                "kind":event.get("kind").unwrap_or(&event["type"]),
                "queued_at":event.get("created").cloned().unwrap_or(json!(now)),"transitions":[],
            })
        });
        // The prompt-start hook can arrive before the queue RPC finishes.
        if status == "queued in Codex" && entry["status"] == "sent to receiver" {
            return;
        }
        let status: String = status.chars().take(256).collect();
        if entry["status"] == status && entry["pending"] == pending {
            return;
        }
        entry["status"] = json!(status);
        entry["pending"] = json!(pending);
        entry["updated_at"] = json!(now);
        let transitions = entry["transitions"].as_array_mut().unwrap();
        transitions.push(json!({"at":now,"status":status}));
        if transitions.len() > self.transition_limit {
            transitions.remove(0);
        }
        self.finished.retain(|value| value != id);
        if !pending {
            self.finished.push_back(id.into());
        }
        while self.finished.len() > self.history_limit {
            self.entries.remove(&self.finished.pop_front().unwrap());
        }
    }

    pub fn snapshot(&self, edge: &str) -> Value {
        let mut rows: Vec<_> = self
            .entries
            .values()
            .filter(|row| edge.is_empty() || row["edge"] == edge)
            .cloned()
            .collect();
        let mut by_edge: BTreeMap<String, Value> = BTreeMap::new();
        for row in &rows {
            let count = by_edge
                .entry(row["edge"].as_str().unwrap_or("").into())
                .or_insert(json!({"total":0,"pending":0}));
            count["total"] = json!(count["total"].as_u64().unwrap() + 1);
            if row["pending"] == true {
                count["pending"] = json!(count["pending"].as_u64().unwrap() + 1);
            }
        }
        let pending = rows.iter().filter(|row| row["pending"] == true).count();
        let total = rows.len();
        rows.sort_by(|a, b| {
            b["pending"]
                .as_bool()
                .cmp(&a["pending"].as_bool())
                .then_with(|| {
                    b["queued_at"]
                        .as_f64()
                        .unwrap_or(0.0)
                        .total_cmp(&a["queued_at"].as_f64().unwrap_or(0.0))
                })
        });
        let mut budget = 3 * 1024 * 1024;
        let mut selected = Vec::new();
        for row in rows {
            let bytes = row.to_string().len();
            if selected.len() >= 1000 || bytes > budget {
                break;
            }
            budget -= bytes;
            selected.push(row);
        }
        selected.sort_by(|a, b| {
            b["queued_at"]
                .as_f64()
                .unwrap_or(0.0)
                .total_cmp(&a["queued_at"].as_f64().unwrap_or(0.0))
        });
        json!({"pending":pending,"omitted":total-selected.len(),"events":selected,
            "history_limit":self.history_limit,"transition_limit":self.transition_limit,"by_edge":by_edge})
    }
}
