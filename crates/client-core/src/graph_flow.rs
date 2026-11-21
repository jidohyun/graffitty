//! Presentation of authoritative graph journal transitions. A receipt is a
//! transport event, never evidence that a model finished processing a message.
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Serialize)]
pub struct Pulse {
    pub event_id: String,
    pub edge: String,
    pub failed: bool,
    pub age: f32,
}
impl Pulse {
    pub fn distance(&self, length: f32) -> f32 {
        let duration = (length / 220.).max(1.2);
        if self.age <= duration {
            length * self.age / duration
        } else {
            length + 24. * (self.age - duration) / 0.12
        }
    }
    pub fn finished(&self, length: f32) -> bool {
        self.age >= (length / 220.).max(1.2) + 0.12
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Waiting {
    pub edge: String,
    pub received: bool,
    pub failed: bool,
    pub ids: BTreeSet<String>,
}

#[derive(Default, Serialize)]
pub struct Flow {
    pub pulses: Vec<Pulse>,
    pub waiting: Vec<Waiting>,
    pub blink: f32,
    #[serde(skip)]
    initialized: bool,
    #[serde(skip)]
    known: BTreeMap<String, String>,
}

fn text<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}
fn endpoint(node: &str, port: &str) -> String {
    if port.is_empty() {
        node.into()
    } else {
        format!("{node}/{port}")
    }
}
pub fn edge_key(edge: &Value) -> String {
    format!(
        "{}>{}",
        endpoint(text(edge, "from"), text(edge, "from_port")),
        endpoint(text(edge, "to"), text(edge, "to_port"))
    )
}
fn event_edge(event: &Value) -> String {
    if let Some(edge) = event["edge"].as_str() {
        return edge.into();
    }
    format!(
        "{}>{}",
        endpoint(text(event, "source"), text(event, "source_port")),
        endpoint(text(event, "target"), text(event, "target_port"))
    )
}

impl Flow {
    pub fn active(&self) -> bool {
        !self.pulses.is_empty() || !self.waiting.is_empty()
    }

    /// New views import history silently. Subsequent authoritative status
    /// changes animate once. Queued work remains stationary until transferred.
    pub fn update(&mut self, graph: &Value, dt: f32, now_unix: f64) {
        if !graph.is_object() {
            return;
        }
        let dt = if dt.is_finite() { dt.max(0.) } else { 0. };
        self.blink = (self.blink + dt) % 1.2;
        for pulse in &mut self.pulses {
            pulse.age += dt;
        }
        let live: BTreeSet<_> = graph["edges"]
            .as_array()
            .into_iter()
            .flatten()
            .map(edge_key)
            .collect();
        let unpaused: BTreeSet<_> = graph["edges"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|edge| {
                let deadline = edge["stop_at"].as_f64().unwrap_or(0.);
                edge["muted"] != true && (deadline <= 0. || deadline > now_unix)
            })
            .map(edge_key)
            .collect();
        self.pulses
            .retain(|pulse| pulse.failed || live.contains(&pulse.edge));
        let mut known = BTreeMap::new();
        for row in graph["journal"]["events"].as_array().into_iter().flatten() {
            let id = text(row, "event_id");
            let status = text(row, "status");
            if id.is_empty() {
                continue;
            }
            if self.initialized
                && row["pending"] != true
                && self.known.get(id).map(String::as_str) != Some(status)
            {
                let failed = status.starts_with("failed") || status.starts_with("cancel");
                if failed || matches!(status, "sent to receiver" | "submitted" | "delivered") {
                    self.pulses.retain(|pulse| pulse.event_id != id);
                    let edge = event_edge(row);
                    if failed || live.contains(&edge) {
                        self.pulses.push(Pulse {
                            event_id: id.into(),
                            edge,
                            failed,
                            age: 0.,
                        });
                    }
                }
            }
            known.insert(id.into(), status.into());
        }
        self.known = known;
        self.initialized = true;
        if self.pulses.len() > 64 {
            self.pulses.drain(..self.pulses.len() - 64);
        }

        let mut groups: BTreeMap<(String, bool, bool), BTreeSet<String>> = BTreeMap::new();
        let mut add = |event: &Value| {
            let edge = event_edge(event);
            let id = text(event, "event_id");
            if !unpaused.contains(&edge) || id.is_empty() {
                return;
            }
            let status = text(&event["progress"], "status");
            let failed = status == "failed";
            let received = failed || status == "pending";
            groups
                .entry((edge, received, failed))
                .or_default()
                .insert(id.into());
        };
        for queue in graph["queues"]
            .as_object()
            .into_iter()
            .flat_map(|queues| queues.values())
        {
            for event in queue.as_array().into_iter().flatten() {
                add(event);
            }
        }
        for row in graph["journal"]["events"].as_array().into_iter().flatten() {
            if row["pending"] == true && row["status"] == "queued in Codex" {
                add(row);
            }
        }
        self.waiting = groups
            .into_iter()
            .map(|((edge, received, failed), ids)| Waiting {
                edge,
                received,
                failed,
                ids,
            })
            .collect();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn graph() -> Value {
        json!({"edges":[{"from":"%1","to":"%2","from_port":"answer","to_port":"prompt"}],"queues":{},"journal":{"events":[]}})
    }
    fn event(status: &str, pending: bool) -> Value {
        json!({"event_id":"e1","source":"%1","target":"%2","source_port":"answer","target_port":"prompt","edge":"%1/answer>%2/prompt","status":status,"pending":pending})
    }

    #[test]
    fn imported_history_is_quiet_and_each_transport_transition_runs_once() {
        let mut flow = Flow::default();
        let mut graph = graph();
        graph["journal"]["events"] = json!([event("delivered", false)]);
        flow.update(&graph, 0., 100.);
        assert!(!flow.active());
        graph["journal"]["events"][0]["status"] = json!("submitted");
        flow.update(&graph, 0., 100.);
        assert_eq!(flow.pulses.len(), 1);
        flow.update(&graph, 0.6, 100.);
        assert_eq!(flow.pulses.len(), 1);
        assert!((flow.pulses[0].distance(100.) - 50.).abs() < 0.001);
        assert!(!flow.pulses[0].finished(100.));
        flow.update(&graph, 0.72, 100.);
        assert!(flow.pulses[0].finished(100.));
    }
    #[test]
    fn queues_group_real_ids_and_pending_progress_moves_the_indicator() {
        let mut flow = Flow::default();
        let mut graph = graph();
        let first = event("queued", true);
        let mut second = first.clone();
        second["event_id"] = json!("e2");
        graph["queues"]["%2"] = json!([first, second]);
        flow.update(&graph, 0., 100.);
        assert_eq!(flow.waiting.len(), 1);
        assert_eq!(flow.waiting[0].ids.len(), 2);
        assert!(!flow.waiting[0].received);
        assert!(flow.pulses.is_empty());
        graph["queues"]["%2"][0]["progress"] = json!({"status":"pending"});
        flow.update(&graph, 0., 100.);
        assert_eq!(flow.waiting.len(), 2);
        assert_eq!(flow.waiting.iter().filter(|g| g.received).count(), 1);
        graph["queues"]["%2"][0]["progress"] = json!({"status":"failed"});
        flow.update(&graph, 0., 100.);
        assert!(flow.waiting.iter().any(|g| g.failed && g.received));
        graph["edges"][0]["muted"] = json!(true);
        flow.update(&graph, 0., 100.);
        assert!(flow.waiting.is_empty());
        graph["edges"][0]["muted"] = json!(false);
        graph["edges"][0]["stop_at"] = json!(99.);
        flow.update(&graph, 0., 100.);
        assert!(flow.waiting.is_empty());
    }
    #[test]
    fn codex_pending_rows_stay_queued_and_disconnect_failure_remains_visible() {
        let mut flow = Flow::default();
        let mut graph = graph();
        flow.update(&graph, 0., 100.);
        graph["journal"]["events"] = json!([event("queued in Codex", true)]);
        flow.update(&graph, 0., 100.);
        assert_eq!(flow.waiting.len(), 1);
        assert!(flow.pulses.is_empty());
        graph["edges"] = json!([]);
        graph["journal"]["events"] = json!([event("cancelled: connection changed", false)]);
        flow.update(&graph, 0., 100.);
        assert!(flow.waiting.is_empty());
        assert_eq!(flow.pulses.len(), 1);
        assert!(flow.pulses[0].failed);
        flow.update(&graph, 0.1, 100.);
        assert_eq!(flow.pulses.len(), 1);
    }
}
