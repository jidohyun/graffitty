//! Workspace-owned graph state. Pane capabilities select the sender; payloads
//! cannot impersonate another node or cross workspace boundaries.
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};
#[path = "graph_checkpoint.rs"]
mod checkpoint;
type Result<T> = std::result::Result<T, String>;
const QUEUE_LIMIT: usize = 10_000;
const RUN_MESSAGE_LIMIT: usize = 10_000;
const STATUS_HISTORY_LIMIT: usize = 20;
const STOP_TIME_ERROR: &str = "Connection reached its stop time. No messages are queued; clear or change its stop time to resume.";
/// Undirected closure includes paused/expired links: saved topology stays together.
pub fn connected_component<'a>(start: &str, edges: impl IntoIterator<Item = &'a Value>) -> HashSet<String> {
    let edges: Vec<_> = edges.into_iter().collect();
    let mut keys = HashSet::from([start.to_owned()]);
    loop {
        let before = keys.len();
        for edge in &edges {
            if let (Some(from), Some(to)) = (edge["from"].as_str(), edge["to"].as_str()) {
                if keys.contains(from) || keys.contains(to) {
                    keys.insert(from.into());
                    keys.insert(to.into());
                }
            }
        }
        if keys.len() == before { return keys; }
    }
}

/// The same complete incoming message is presented to native and inbox agents.
/// Callers must pass a recipient-visible event (for example from graph.take).
pub fn message_prompt(event: &Value) -> String {
    format!(
        "[Graffitty message from {}; event {}; run {}]\n{}\nPayload (JSON): {}",
        string(event, "source"), string(event, "event_id"), string(event, "run_id"),
        string(event, "text"), event,
    )
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct NodeSettings {
    pub pending_per_node: usize,
    pub run_messages: usize,
    pub status_history: usize,
    pub receipts: usize,
    pub tracked_runs: usize,
    pub delivery_history: usize,
    pub delivery_transitions: usize,
}
impl Default for NodeSettings {
    fn default() -> Self {
        Self { pending_per_node: QUEUE_LIMIT, run_messages: RUN_MESSAGE_LIMIT,
            status_history: STATUS_HISTORY_LIMIT, receipts: 100, tracked_runs: 4096,
            delivery_history: 200, delivery_transitions: 20 }
    }
}
impl NodeSettings {
    pub fn validate(&self) -> Result<()> {
        for (name, value) in [("pending_per_node",self.pending_per_node), ("run_messages",self.run_messages),
            ("status_history",self.status_history), ("receipts",self.receipts), ("tracked_runs",self.tracked_runs),
            ("delivery_history",self.delivery_history), ("delivery_transitions",self.delivery_transitions)] {
            if value == 0 || value > i64::MAX as usize { return Err(format!("nodes.{name} must be a positive integer within i64 range")); }
        }
        Ok(())
    }
}
pub struct Graph {
    settings: NodeSettings,
    pub nodes: BTreeMap<String, Value>,
    pub edges: BTreeMap<String, Value>,
    pub queues: BTreeMap<String, Vec<Value>>,
    pub receipts: Vec<Value>,
    runs: HashMap<String, usize>,
    run_limits: HashMap<String, usize>,
    default_run_limit: usize,
    journal: crate::graph_journal::Journal,
    revision: u64,
    notification_revision: u64,
    seen: HashMap<String, String>,
    contexts: HashMap<String, Value>,
    next_stop_at: Option<f64>,
    expired_deadlines: HashMap<String, f64>,
    // Only heartbeat timeouts are reversible; SessionEnd is not.
    timed_out_status: HashMap<String, Value>,
}
pub(crate) fn now() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
fn stop_at(edge: &Value) -> f64 {
    edge["stop_at"].as_f64().unwrap_or(0.0)
}
fn expired(edge: &Value, now: f64) -> bool {
    let deadline = stop_at(edge);
    deadline > 0.0 && deadline <= now
}
fn string<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}
fn uuid() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}
/// Runtime capabilities belong to the node kind, not its optional integration
/// provider. Accept the old adapter identity at the protocol boundary only.
pub fn is_custom_node(node: &Value) -> bool {
    node["kind"] == "custom" || ["adapter", "telegram"].contains(&string(node, "provider"))
}
fn lifecycle_identity<'a>(params: &'a Value, previous: &'a Value) -> Result<(&'static str, Option<&'a str>)> {
    let starting = params["event"] == "SessionStart";
    let raw_provider = params.get("provider").or_else(|| if starting { None } else { previous.get("provider") });
    let provider = match raw_provider {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if !s.is_empty() && s.len() <= 64
            && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b)) => Some(s.as_str()),
        _ => return Err("Provider must be a nonempty identifier of at most 64 characters".into()),
    };
    let inferred = if provider.is_none() || matches!(provider, Some("adapter" | "telegram")) { "custom" } else { "agent" };
    let kind = params.get("kind").or_else(|| if starting || params.get("provider").is_some() { None } else { previous.get("kind") })
        .map(|v| v.as_str().ok_or("Node kind must be custom or agent"))
        .transpose()?.unwrap_or(inferred);
    match kind {
        "agent" if matches!(provider, Some("claude" | "codex" | "opencode" | "pi")) => Ok(("agent", provider)),
        "custom" if !matches!(provider, Some("claude" | "codex" | "opencode" | "pi" | "shell")) =>
            Ok(("custom", provider.filter(|p| *p != "adapter"))),
        _ => Err("Choose kind custom with an optional provider, or kind agent with Claude/Codex/OpenCode".into()),
    }
}
fn record_status(node: &mut Value, limit: usize) {
    let provider = node["provider"].clone();
    let status = node["status"].clone();
    if node.get("status_history").is_none() {
        node["status_history"] = json!([]);
    }
    let history = node["status_history"].as_array_mut().unwrap();
    if history.last().is_some_and(|entry| entry["provider"] == provider && entry["status"] == status) {
        return;
    }
    let mut entry = json!({"at":chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, false),"status":status});
    if !provider.is_null() { entry["provider"] = provider; }
    history.push(entry);
    if history.len() > limit { history.remove(0); }
}
fn edge_key(edge: &Value) -> String {
    format!(
        "{}/{}>{}/{}",
        string(edge, "from"),
        string(edge, "from_port"),
        string(edge, "to"),
        string(edge, "to_port")
    )
}
pub(crate) fn event_key(event: &Value) -> String {
    edge_key(
        &json!({"from":event["source"],"from_port":event["source_port"],"to":event["target"],"to_port":event["target_port"]}),
    )
}
fn ports(node: &Value, output: bool) -> Vec<Value> {
    if let Some(ports) = node["manifest"][if output { "outputs" } else { "inputs" }].as_array() {
        return ports.clone();
    }
    graffitty_protocol::graph::builtin_ports(string(node,"provider"), output).into_iter()
        .map(|port| serde_json::to_value(port).expect("port serialization")).collect()
}
fn port(node: &Value, output: bool, name: &str) -> Result<Value> {
    let ports = ports(node, output);
    if name.is_empty() && ports.len() == 1 {
        return Ok(ports[0].clone());
    }
    ports
        .into_iter()
        .find(|p| p["id"] == name)
        .ok_or_else(|| "Choose an advertised port".into())
}
use graffitty_protocol::graph::normalize_manifest as manifest;

impl Default for Graph {
    fn default() -> Self { Self::with_settings(NodeSettings::default()) }
}
impl Graph {
    pub fn with_settings(settings: NodeSettings) -> Self {
        Self {
            nodes: BTreeMap::new(), edges: BTreeMap::new(), queues: BTreeMap::new(),
            receipts: Vec::new(), runs: HashMap::new(), run_limits: HashMap::new(),
            default_run_limit: settings.run_messages, journal: crate::graph_journal::Journal::with_limits(settings.delivery_history, settings.delivery_transitions),
            settings,
            revision: 0, notification_revision: 0, seen: HashMap::new(), contexts: HashMap::new(),
            next_stop_at: None, expired_deadlines: HashMap::new(),
            timed_out_status: HashMap::new(),
        }
    }
}
impl Graph {
    fn run_limit(&self, run: &str) -> usize {
        self.run_limits.get(run).copied().unwrap_or(self.default_run_limit)
    }
    fn budgets(&self) -> Value {
        let runs: BTreeMap<_, _> = self.runs.iter().map(|(id,count)|
            (id, json!({"run_id":id,"count":count,"limit":self.run_limit(id),"available":true}))).collect();
        json!({"limits":{"pending_per_node":self.settings.pending_per_node,"run_messages":self.default_run_limit},"runs":runs})
    }
    pub fn native_pending(&self, id: &str) -> bool { self.journal.native_pending(id) }
    pub fn record_delivery(&mut self, event: &Value, status: &str, pending: bool) {
        self.journal.record(event, status, pending);
        self.receipts.retain(|receipt| receipt["event_id"] != event["event_id"]);
        self.receipts.push(json!({"event_id":event["event_id"],"source":event["source"],"target":event["target"],"edge":event_key(event),"status":status}));
        if self.receipts.len() > self.settings.receipts { self.receipts.remove(0); }
    }
    pub fn delivery_prompt(&self, event: &Value) -> String {
        message_prompt(&self.exposed_event(event))
    }
    fn exposed_event(&self, event: &Value) -> Value {
        let mut exposed = event.clone();
        if event.get("caused_by").is_none() && event["shared_sessions"] != true
            && !self.can_read(string(event,"source"), string(event,"target")) {
            if let Some(sessions) = exposed["sessions"].as_array_mut() {
                for session in sessions {
                    if let Some(session) = session.as_object_mut() { session.remove("path"); }
                }
            }
        }
        exposed
    }
    fn clear_queue(&mut self, key: &str) {
        let removed = self.queues.remove(key).unwrap_or_default();
        if !removed.is_empty() { self.notification_revision = self.notification_revision.wrapping_add(1); }
        for event in removed {
            self.journal.record(&event, "cancelled: receiver session changed or closed", false);
        }
    }

    /// A native discovery worker can finish reading a completed turn after a
    /// newer turn has started. Route its output without changing live status.
    pub fn discovered_completion(&mut self, id: u64, text: &str, checkpoint: &str, run_id: &str) -> Result<()> {
        let key = format!("%{id}");
        let node = self.nodes.get(&key).ok_or("Unknown agent")?;
        let run_id = if self.runs.contains_key(run_id) { run_id } else { "" };
        let params = json!({"text":text,"session_id":node["session_id"],"run_id":run_id});
        let signature = format!("{}:{checkpoint}:{text}", node["session_id"]);
        self.expire();
        self.enqueue_completion(&key, &params, signature)
    }

    fn enqueue_completion(&mut self, key: &str, params: &Value, signature: String) -> Result<()> {
        if self.seen.get(key) == Some(&signature) {
            return Ok(());
        }
        self.seen.insert(key.into(), signature);
        let edges: Vec<_> = self.edges.values().filter(|edge| {
            edge["from"] == key && edge["turn_completed"] == true
                && edge["muted"] != true && !expired(edge, now())
        }).cloned().collect();
        for edge in edges {
            if let Err(error) = self.enqueue(&edge, params, None, true) {
                let event = json!({"event_id":uuid(),"source":edge["from"],"target":edge["to"],"source_port":edge["from_port"],"target_port":edge["to_port"],"run_id":params["run_id"],"type":"turn.completed"});
                let status = format!("failed: {error}");
                self.journal.record(&event, &status, false);
                self.receipts.push(json!({"event_id":event["event_id"],"source":event["source"],"target":event["target"],"edge":event_key(&event),"status":status}));
                if self.receipts.len() > self.settings.receipts { self.receipts.remove(0); }
                return Err(error);
            }
        }
        Ok(())
    }

    /// Lifecycle outputs use ordinary message delivery, without granting Read.
    /// Their trigger is owner-observed state, not an agent's graph.send call.
    fn enqueue_lifecycle(&mut self, key: &str, output: &str, fields: &Value) -> Result<()> {
        if is_custom_node(&self.nodes[key]) { return Ok(()); }
        let mut params = fields.clone();
        params["kind"] = json!(format!("agent.{output}"));
        params["run_id"] = self.nodes[key]["run_id"].clone();
        if params["payload"].is_null() {
            params["payload"] = json!({"provider":self.nodes[key]["provider"],
                "session_id":self.nodes[key]["session_id"],"error":fields["error"]});
        }
        if params["text"].as_str().is_none_or(str::is_empty) {
            params["text"] = json!(if output == "waiting" { "Agent is awaiting input" } else { "Agent failed" });
        }
        let edges: Vec<_> = self.edges.values().filter(|edge| {
            edge["from"] == key && edge["from_port"] == output && edge["send"] == true
                && edge["muted"] != true && !expired(edge, now())
        }).cloned().collect();
        for edge in edges {
            if let Err(error) = self.enqueue(&edge, &params, None, false) {
                let event = json!({"event_id":uuid(),"source":key,"target":edge["to"],
                    "source_port":output,"target_port":edge["to_port"],"run_id":params["run_id"],"type":"message"});
                self.journal.record(&event, &format!("failed: {error}"), false);
            }
        }
        Ok(())
    }

    pub fn add(&mut self, id: u64, title: String) {
        let key = format!("%{id}");
        self.nodes
            .entry(key)
            .or_insert_with(|| json!({"provider":"shell","status":"unintegrated","title":title}));
    }
    /// Apply owner-side process discovery. Live integrated agents retain their
    /// hook status; discovery still records process exits and replacements.
    pub fn observe_agent(&mut self, id: u64, state: &Value) {
        let key = format!("%{id}");
        let Some(node) = self.nodes.get(&key) else { return; };
        if is_custom_node(node) { return; }
        let was_waiting = node["status"] == "waiting";
        let had_turn_baseline = node.get("observed_turn").is_some();
        let previous_turn = node["observed_turn"].clone();
        let same_session = node["session_id"] == state["session_id"] && node["pid"] == state["pid"];
        let inbox = node["transport"] == "inbox";
        if inbox {
            // A gft node is not a native-provider process. Ignore shell scans,
            // but allow a subsequently launched real provider to replace it.
            if !["codex", "claude", "opencode", "pi"].contains(&string(state, "provider"))
                || state["pid"].as_i64().is_none_or(|pid| Some(pid) == node["pid"].as_i64()) {
                return;
            }
            self.clear_queue(&key);
        }
        let node = self.nodes.get_mut(&key).unwrap();
        if inbox {
            self.timed_out_status.remove(&key);
            for field in ["transport", "heartbeat_at", "integrated", "session_id", "transcript_path"] {
                node.as_object_mut().unwrap().remove(field);
            }
        }
        let Some(found) = state.as_object() else { return; };
        let mut found = found.clone();
        if found.get("pid").is_some_and(|pid| !pid.is_null() && *pid != node["pid"]) {
            node.as_object_mut().unwrap().remove("integrated");
        }
        if node["integrated"] == true && found.get("status") != Some(&json!("offline")) {
            found.remove("status");
        }
        // Keep the status from lifecycle events or OSC 7501 when discovery only
        // knows "unknown" for the same process. This also applies after a server
        // restart loses the node's registration.
        //
        // Replace it when discovery sees a new process or a known status.
        if found.contains_key("status") {
            let same_process = node["pid"].is_null() || found.get("pid").is_none_or(|pid| pid.is_null() || *pid == node["pid"]);
            let informed = !matches!(node["status"].as_str(), None | Some("unintegrated" | "unknown" | "offline"));
            if found["status"] == "unknown" && same_process && informed {
                found.remove("status");
            } else {
                node.as_object_mut().unwrap().remove("status_source");
            }
        }
        node.as_object_mut().unwrap().extend(found);
        if ["codex", "claude", "opencode", "pi"].contains(&string(node, "provider")) { record_status(node, self.settings.status_history); }
        let waiting = node["status"] == "waiting";
        let turn = node["observed_turn"].clone();
        if !was_waiting && waiting {
            let _ = self.enqueue_lifecycle(&key, "waiting", &json!({}));
        }
        // Establish a baseline on attachment; do not replay a historical error.
        // Comparing status too catches a turn seen running before it failed.
        if same_session && had_turn_baseline
            && (turn["id"] != previous_turn["id"] || turn["status"] != previous_turn["status"])
            && turn["status"] == "failed" && turn["id"].is_string() {
            let _ = self.enqueue_lifecycle(&key, "error", &json!({
                "text":turn["error"]["message"], "outcome":"error", "payload":{"error":turn["error"],"turn_id":turn["id"]}
            }));
        }
    }
    /// Apply the terminal's OSC 7501 root record (`None` once cleared). Every
    /// node keeps the record as `program_status`. A node without lifecycle hooks
    /// or discovery also takes its status from it; hook status stays authoritative.
    pub fn observe_program_status(&mut self, id: u64, status: Option<&Value>) {
        let Some(node) = self.nodes.get_mut(&format!("%{id}")) else { return; };
        match status {
            Some(status) => node["program_status"] = status.clone(),
            None => { node.as_object_mut().unwrap().remove("program_status"); }
        }
        if !matches!(node["status"].as_str(), Some("unintegrated" | "unknown")) && node["status_source"] != "program" {
            return;
        }
        let word = status.and_then(|status| status["state"].as_str());
        node["status"] = json!(match word {
            Some("working") => "busy",
            // Both need a person: approve/answer, or read why it failed.
            Some("blocked" | "error") => "waiting",
            Some(_) => "idle",
            None => "unintegrated",
        });
        if word.is_some() {
            node["status_source"] = json!("program");
        } else {
            node.as_object_mut().unwrap().remove("status_source");
        }
        record_status(node, self.settings.status_history);
    }
    pub fn remove(&mut self, id: u64) {
        let key = format!("%{id}");
        self.nodes.remove(&key);
        self.timed_out_status.remove(&key);
        self.clear_queue(&key);
        self.contexts.remove(&key);
        self.edges.retain(|_, e| e["from"] != key && e["to"] != key);
        self.revoke();
    }
    /// Preserve the moved subgraph and its queued work. Edges crossing the new
    /// session boundary lose authority and queued cross-session delivery stops.
    pub fn transfer_nodes_to(&mut self, ids: &HashSet<u64>, target: &mut Graph) {
        let keys: HashSet<_> = ids.iter().map(|id| format!("%{id}")).collect();
        let internal: Vec<_> = self.edges.iter().filter(|(_, e)|
            keys.contains(string(e, "from")) && keys.contains(string(e, "to")))
            .map(|(id, edge)| (id.clone(), edge.clone())).collect();
        for key in &keys {
            if let Some(node) = self.nodes.remove(key) { target.nodes.insert(key.clone(), node); }
            if let Some(status) = self.timed_out_status.remove(key) { target.timed_out_status.insert(key.clone(), status); }
            if let Some(context) = self.contexts.remove(key) { target.contexts.insert(key.clone(), context); }
            if let Some(seen) = self.seen.remove(key) { target.seen.insert(key.clone(), seen); }
            if let Some(queue) = self.queues.remove(key) {
                target.queues.entry(key.clone()).or_default().extend(queue);
            }
        }
        for (id, edge) in internal { target.edges.insert(id, edge); }
        self.edges.retain(|_, e| !keys.contains(string(e, "from")) && !keys.contains(string(e, "to")));
        for (run, count) in &self.runs {
            let value = target.runs.entry(run.clone()).or_default();
            *value = (*value).max(*count);
            target.run_limits.entry(run.clone()).or_insert(self.run_limit(run));
        }
        self.revoke();
        target.revoke();
    }
    pub fn adjacent(&self, key: &str) -> Value {
        let expose = |edge: &Value| {
            let mut edge = edge.clone();
            for (node, field) in [("from","from_title"),("to","to_title")] {
                edge[field] = self.nodes.get(string(&edge,node)).and_then(|n|n.get("title")).cloned().unwrap_or(json!("Untitled terminal"));
            }
            edge
        };
        json!({"self":key,"revision":self.revision,
            "incoming":self.edges.values().filter(|e|e["to"]==key).map(expose).collect::<Vec<_>>(),
            "outgoing":self.edges.values().filter(|e|e["from"]==key).map(expose).collect::<Vec<_>>()})
    }
    pub fn read_denied(&self, source: &str, caller: &str) -> Value {
        json!({"code":"connection_changed",
            "message":format!("No current Read connection from {source} to {caller}. Earlier graph instructions may be stale. Stop this attempt; do not recreate the edge to bypass removal. Run `gft graph adjacent` for live permissions. Once reconnected with Read, retry the same command; no session restart is needed."),
            "adjacent":self.adjacent(caller)})
    }
    pub fn snapshot(&self) -> Value {
        let nodes: Vec<_> = self
            .nodes
            .iter()
            .map(|(key, value)| {
                let mut node = value.clone();
                for secret in [
                    "socket_path",
                    "registry_dir",
                    "transcript_path",
                    "session_file",
                    "provider_home",
                    "launch_context",
                    "heartbeat_at",
                    "restore",
                    "checkpoint_state",
                ] {
                    node.as_object_mut().unwrap().remove(secret);
                }
                node["node"] = json!(key);
                node["pane"] = json!(key);
                node["queued"] = json!(self.queues.get(key).map_or(0, Vec::len));
                if node.get("manifest").is_none() && !ports(value, true).is_empty() {
                    node["manifest"] =
                        json!({"inputs":ports(value,false),"outputs":ports(value,true)});
                    if value["transport"] == "inbox" {
                        node["manifest"]["name"] = value["title"].clone();
                    }
                }
                node
            })
            .collect();
        let queues: BTreeMap<_, _> = self
            .queues
            .iter()
            .map(|(key, queue)| {
                (
                    key,
                    queue
                        .iter()
                        .map(|event| {
                            let mut visible = serde_json::Map::new();
                            for field in [
                                "source",
                                "target",
                                "source_port",
                                "target_port",
                                "event_id",
                                "run_id",
                                "type",
                                "edge_revision",
                                "progress",
                            ] {
                                if let Some(value) = event.get(field) {
                                    visible.insert(field.into(), value.clone());
                                }
                            }
                            Value::Object(visible)
                        })
                        .collect::<Vec<_>>(),
                )
            })
            .collect();
        let mut snapshot = self.budgets();
        snapshot.as_object_mut().unwrap().extend(json!({"nodes":nodes,"edges":self.edges.values().collect::<Vec<_>>(),"receipts":self.receipts,"queues":queues,"revision":self.revision,"journal":self.journal.snapshot("")}).as_object().unwrap().clone());
        snapshot
    }
    pub fn allowed(&self, event: &Value) -> bool {
        self.allowed_at(event, now())
    }
    fn allowed_at(&self, event: &Value, now: f64) -> bool {
        self.edges.get(&event_key(event)).is_some_and(|e| {
            e["muted"] != true
                && !expired(e, now)
                && e["revision"] == event["edge_revision"]
                && e[if event["type"] == "turn.completed" {
                    "turn_completed"
                } else {
                    "send"
                }] == true
        })
    }
    fn revoke(&mut self) {
        self.revoke_at(now());
    }
    fn revoke_at(&mut self, now: f64) {
        let mut queues = std::mem::take(&mut self.queues);
        for queue in queues.values_mut() {
            queue.retain(|e| {
                if self.allowed_at(e, now) { true } else {
                    self.journal.record(e, "cancelled: connection changed", false);
                    false
                }
            });
        }
        self.queues = queues;
        self.revision += 1;
        self.schedule_expiry();
    }
    fn schedule_expiry(&mut self) {
        self.expired_deadlines.retain(|key, deadline| {
            self.edges
                .get(key)
                .is_some_and(|edge| stop_at(edge) == *deadline)
        });
        self.next_stop_at = self
            .edges
            .iter()
            .filter_map(|(key, edge)| {
                let deadline = stop_at(edge);
                (deadline > 0.0 && self.expired_deadlines.get(key) != Some(&deadline))
                    .then_some(deadline)
            })
            .min_by(f64::total_cmp);
    }
    /// The server actor already services workers and I/O. Check only its cached
    /// next deadline; scan/revoke once when due, with no separate polling task.
    pub fn expire(&mut self) {
        self.expire_at(now());
    }
    fn expire_at(&mut self, now: f64) {
        for (key, node) in &mut self.nodes {
            if node["transport"] == "inbox" && node["status"] != "offline"
                && node["heartbeat_at"].as_f64().is_some_and(|at| now - at > 15.0) {
                self.timed_out_status.insert(key.clone(), node["status"].clone());
                node["status"] = json!("offline");
                self.notification_revision = self.notification_revision.wrapping_add(1);
                record_status(node, self.settings.status_history);
            }
        }
        if self.next_stop_at.is_none_or(|deadline| now < deadline) {
            return;
        }
        for (key, edge) in &self.edges {
            if expired(edge, now) {
                self.expired_deadlines.insert(key.clone(), stop_at(edge));
            }
        }
        self.revoke_at(now);
    }
    fn reconcile_ports(&mut self) {
        self.edges.retain(|_, edge| {
            let output = port(
                &self.nodes[string(edge, "from")],
                true,
                string(edge, "from_port"),
            );
            let input = port(
                &self.nodes[string(edge, "to")],
                false,
                string(edge, "to_port"),
            );
            output.is_ok_and(|p| {
                let mode = string(&p, "mode");
                edge["send"] == (mode == "send")
                    && edge["turn_completed"] == (mode == "turn_completed")
            }) && input.is_ok()
        });
    }
    pub fn can_read(&self, source: &str, target: &str) -> bool {
        self.can_read_at(source, target, now())
    }
    fn can_read_at(&self, source: &str, target: &str, now: f64) -> bool {
        source == target
            || self.edges.values().any(|e| {
                e["from"] == source
                    && e["to"] == target
                    && e["read"] == true
                    && e["muted"] != true
                    && !expired(e, now)
            })
    }
    fn enqueue(
        &mut self,
        edge: &Value,
        params: &Value,
        content: Option<&Value>,
        turn: bool,
    ) -> Result<Value> {
        if expired(edge, now()) {
            return Err(STOP_TIME_ERROR.into());
        }
        let target = string(edge, "to");
        if self.queues.get(target).map_or(0, Vec::len) >= self.settings.pending_per_node {
            return Err("Recipient queue is full".into());
        }
        let run = if string(params, "run_id").is_empty() {
            uuid()
        } else {
            string(params, "run_id").into()
        };
        if self.runs.get(&run).copied().unwrap_or(0) >= self.run_limit(&run) {
            return Err("Graph run message limit reached".into());
        }
        let text = params.get("text").cloned().unwrap_or_else(|| {
            params["payload"].get("text").cloned().unwrap_or_else(|| {
                if params["payload"].is_string() {
                    params["payload"].clone()
                } else {
                    json!("")
                }
            })
        });
        if !string(edge, "contains").is_empty()
            && !text
                .as_str()
                .unwrap_or("")
                .contains(string(edge, "contains"))
            || !string(edge, "outcome").is_empty() && edge["outcome"] != params["outcome"]
        {
            return Ok(json!({"status":"filtered"}));
        }
        let mut event = json!({"type":if turn{"turn.completed"}else{"message"},"kind":params.get("kind").cloned().unwrap_or_else(|| json!(if turn { "turn.completed" } else { "message" })),"source":edge["from"],"target":edge["to"],"source_port":edge["from_port"],"target_port":edge["to_port"],"edge_revision":edge["revision"],"event_id":uuid(),"run_id":run,"text":text,"payload":params["payload"],"content":params.get("content").cloned().unwrap_or(json!([])),"renderings":params.get("renderings").cloned().unwrap_or(json!({})),"sessions":params.get("sessions").cloned().unwrap_or(json!([])),"outcome":params.get("outcome").cloned().unwrap_or(json!("")),"created":std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs_f64()});
        if params.get("sessions").is_some() { event["shared_sessions"] = json!(true); }
        if params.get("sessions").is_none() {
            if let Some(source) = self.nodes.get(string(edge, "from")) {
                let path = string(source,"transcript_path");
                // A process lifecycle is not a conversation. Providerless nodes
                // such as Manual Prompt have no session to attach to a message.
                if !path.is_empty() || (!is_custom_node(source) && !string(source,"session_id").is_empty()) {
                    let mut reference = json!({"id":source["session_id"]});
                    if let Some(provider) = source.get("provider").filter(|p| !p.is_null()) {
                        reference["provider"] = provider.clone();
                    }
                    if !path.is_empty() && self.can_read(string(edge,"from"),target) {
                        reference["path"] = json!(path);
                        if let Ok(metadata) = std::fs::metadata(path) { reference["checkpoint"] = json!({"byte_offset":metadata.len()}); }
                    }
                    event["sessions"] = json!([reference]);
                }
            }
        }
        if let Some(content) = content {
            for key in ["origin", "caused_by"] {
                event[key] = content[key].clone();
            }
        }
        self.run_limits.entry(run.clone()).or_insert(self.default_run_limit);
        *self.runs.entry(run.clone()).or_default() += 1;
        if self.runs.len() > self.settings.tracked_runs {
            let old = self.runs.keys().find(|k| **k != run).cloned();
            if let Some(old) = old {
                self.runs.remove(&old);
                self.run_limits.remove(&old);
            }
        }
        let result = json!({"status":"queued","event_id":event["event_id"],"run_id":run});
        self.journal.record(&event, "queued in Graffitty", true);
        self.queues.entry(target.into()).or_default().push(event);
        self.notification_revision = self.notification_revision.wrapping_add(1);
        Ok(result)
    }
    /// Cheap actor-side change detection for authenticated inbox subscriptions.
    pub fn notification_revision(&self) -> (u64, u64) {
        (self.revision, self.notification_revision)
    }
    pub fn dispatch(&mut self, id: u64, method: &str, p: &Value) -> Result<Value> {
        let result = self.dispatch_inner(id, method, p);
        if result.is_ok() && !matches!(method, "agent.heartbeat" | "graph.adjacent" | "graph.list" | "graph.read" | "graph.inbox" | "graph.take") {
            self.notification_revision = self.notification_revision.wrapping_add(1);
        }
        result
    }
    fn dispatch_inner(&mut self, id: u64, method: &str, p: &Value) -> Result<Value> {
        if serde_json::to_vec(p).map_err(|e| e.to_string())?.len() > 2 * 1024 * 1024 {
            return Err("Graph message exceeds 2 MiB".into());
        }
        let key = format!("%{id}");
        if !self.nodes.contains_key(&key) {
            return Err("Unknown pane".into());
        }
        self.expire();
        match method {
            "graph.list" => Ok(self.snapshot()),
            "graph.queue" => Ok(self.journal.snapshot(string(p, "edge"))),
            "graph.run.default" | "graph.run.limit" | "graph.run.reset" => {
                let run = string(p, "run_id");
                if method != "graph.run.default" && !self.runs.contains_key(run) {
                    return Err("Graph run is no longer available".into());
                }
                if method == "graph.run.reset" {
                    self.runs.insert(run.into(), 0);
                } else {
                    let limit = p["limit"].as_u64().filter(|v| *v > 0 && *v <= i64::MAX as u64)
                        .and_then(|v| usize::try_from(v).ok()).ok_or("Run message limit must be a positive integer")?;
                    if method == "graph.run.default" { self.default_run_limit = limit; }
                    else { self.run_limits.insert(run.into(), limit); }
                }
                Ok(self.budgets())
            }
            "agent.register" => {
                if !is_custom_node(&self.nodes[&key]) {
                    return Err("Only custom nodes may advertise ports".into());
                }
                let manifest = manifest(p)?;
                self.nodes.get_mut(&key).unwrap()["manifest"] = manifest;
                self.reconcile_ports();
                self.revoke();
                Ok(self.nodes[&key].clone())
            }
            // The latest state a restorable node wants back after a restore.
            "agent.checkpoint" => {
                if self.nodes[&key].get("restore").is_none() {
                    return Err("Declare restore at SessionStart before reporting checkpoint state".into());
                }
                let state = p.get("state").cloned().unwrap_or(Value::Null);
                crate::checkpoint::node_state(&state)?;
                let node = self.nodes.get_mut(&key).unwrap();
                if state.is_null() {
                    node.as_object_mut().unwrap().remove("checkpoint_state");
                } else {
                    node["checkpoint_state"] = state;
                }
                Ok(json!({"ok":true}))
            }
            "agent.heartbeat" => {
                if self.nodes[&key]["transport"] == "inbox" {
                    let node = self.nodes.get_mut(&key).unwrap();
                    node["heartbeat_at"] = json!(now());
                    if let Some(status) = self.timed_out_status.remove(&key) {
                        node["status"] = status;
                        record_status(node, self.settings.status_history);
                        self.notification_revision = self.notification_revision.wrapping_add(1);
                    }
                }
                // The transport tells an integration whether this server still
                // holds its SessionStart registration, or lost it in a restart.
                Ok(json!({"ok":true,"transport":self.nodes[&key]["transport"]}))
            }
            "agent.event" => {
                let (kind, provider) = lifecycle_identity(p, &self.nodes[&key])?;
                let provider = provider.map(str::to_owned);
                // A provider's background daemon keeps the environment of the
                // pane that first started it, so every session it hosts
                // reports through that pane.
                //
                // Only this pane's own conversation, or a fork of it, may
                // speak for it; another pane's would overwrite this agent's
                // status and conversation.
                if p["detached"] == true {
                    let bound = &self.nodes[&key]["session_id"];
                    if bound.as_str().is_some_and(|id| !id.is_empty())
                        && *bound != p["session_id"]
                        && *bound != p["parent_session_id"]
                    {
                        return Err("This background session belongs to another pane".into());
                    }
                }
                if p.get("transport").is_some() && (p["event"] != "SessionStart"
                    || !["inbox", "native"].contains(&string(p, "transport"))) {
                    return Err("Choose inbox or native transport at SessionStart".into());
                }
                if p.get("title").is_some_and(|v| v.as_str().is_none_or(|s| s.chars().count() > 200 || s.chars().any(char::is_control))) {
                    return Err("Invalid agent title".into());
                }
                // A node opts in to checkpoint recovery with how to relaunch it.
                if let Some(restore) = p.get("restore").filter(|v| !v.is_null()) {
                    if p["event"] != "SessionStart" {
                        return Err("Declare restore at SessionStart".into());
                    }
                    crate::checkpoint::node_restore(restore)?;
                }
                let node = &self.nodes[&key];
                if p["event"] == "SessionStart"
                    && (node["pid"] != p["pid"] || node["session_id"] != p["session_id"])
                    && !(kind == "custom"
                        && is_custom_node(node)
                        && p["resume_inbox"] == true)
                {
                    self.clear_queue(&key);
                }
                let node = self.nodes.get_mut(&key).unwrap();
                let was_waiting = node["status"] == "waiting";
                if p["event"] == "SessionStart" {
                    node["transport"] = json!(p["transport"].as_str().unwrap_or("native"));
                    node.as_object_mut().unwrap().remove("heartbeat_at");
                    // A newly launched node must not inherit the previous
                    // agent's conversation identity in the same terminal.
                    for field in ["session_id", "transcript_path", "session_file", "provider_home", "checkpoint_state", "observed_turn"] {
                        node.as_object_mut().unwrap().remove(field);
                    }
                    match p.get("restore").filter(|v| !v.is_null()) {
                        Some(restore) => node["restore"] = restore.clone(),
                        None => { node.as_object_mut().unwrap().remove("restore"); }
                    }
                }
                if node["transport"] == "inbox" {
                    node["heartbeat_at"] = json!(now());
                    if let Some(title) = p.get("title") { node["title"] = title.clone(); }
                }
                if kind != "custom" {
                    node.as_object_mut().unwrap().remove("manifest");
                }
                self.timed_out_status.remove(&key);
                node["kind"] = json!(kind);
                node.as_object_mut().unwrap().remove("status_source");
                if let Some(provider) = provider { node["provider"] = json!(provider); }
                else { node.as_object_mut().unwrap().remove("provider"); }
                node["status"] = json!(match string(p, "event") {
                    "SessionStart" | "Stop" | "Ready" | "Error" => "idle",
                    "SessionEnd" => "offline",
                    "PermissionRequest" | "AwaitingInput" => "waiting",
                    _ => "busy",
                });
                record_status(node, self.settings.status_history);
                // Another process: the start time kept for the previous one
                // would make this one look like an impostor of it.
                if p.get("pid").is_some_and(|pid| !pid.is_null() && *pid != node["pid"]) {
                    node.as_object_mut().unwrap().remove("started");
                }
                for field in [
                    "session_id",
                    "pid",
                    "transcript_path",
                    "session_file",
                    "integrated",
                    "provider_home",
                    "started",
                ] {
                    if let Some(value) = p.get(field) {
                        node[field] = value.clone();
                    }
                }
                if p["event"] == "UserPromptSubmit" || p["event"] == "SessionStart" {
                    node.as_object_mut().unwrap().remove("last_lifecycle_error");
                }
                if p["event"] == "UserPromptSubmit" {
                    if node["transport"] == "inbox" {
                        // Identical scripted replies in separate turns are distinct completions.
                        self.seen.remove(&key);
                    }
                    self.journal.started(&key, string(p, "prompt"));
                    let header = string(p, "prompt").lines().next().unwrap_or("");
                    let run = header.strip_prefix("[Graffitty ")
                        .and_then(|value| value.rsplit_once("; run "))
                        .and_then(|(_, value)| value.strip_suffix(']'))
                        .filter(|run| self.runs.contains_key(*run));
                    if let Some(run) = run {
                        node["run_id"] = json!(run);
                    } else {
                        node.as_object_mut().unwrap().remove("run_id");
                    }
                } else if p["event"] == "SessionStart" {
                    node.as_object_mut().unwrap().remove("run_id");
                }
                self.reconcile_ports();
                self.revoke();
                if !was_waiting && self.nodes[&key]["status"] == "waiting" {
                    self.enqueue_lifecycle(&key, "waiting", &json!({}))?;
                }
                if p["event"] == "Error" || (p["event"] == "Stop" && p["outcome"] == "error") {
                    let signature = json!([p["session_id"], p["completion_id"], p["text"]]);
                    if self.nodes[&key]["last_lifecycle_error"] != signature {
                        self.nodes.get_mut(&key).unwrap()["last_lifecycle_error"] = signature;
                        self.enqueue_lifecycle(&key, "error", p)?;
                    }
                } else if p["event"] == "Stop" && p["outcome"] != "interrupted" {
                    // A user interrupt only returns the node to idle: it is
                    // neither a completed turn nor an error.
                    let signature = format!("{}:{}:{}", p["session_id"], p["completion_id"], p["text"]);
                    let mut completion = p.clone();
                    completion["run_id"] = self.nodes[&key]["run_id"].clone();
                    self.enqueue_completion(&key, &completion, signature)?;
                }
                let adjacent = self.adjacent(&key);
                // Lifecycle/status updates advance the snapshot revision but
                // do not change a node's permissions. Only its adjacent edges
                // determine whether the next hook needs refreshed context.
                let context = json!({"incoming":adjacent["incoming"],"outgoing":adjacent["outgoing"]});
                let changed = self.contexts.get(&key) != Some(&context);
                let transport = self.nodes[&key]["transport"].clone();
                if ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse"].contains(&string(p, "event")) {
                    self.contexts.insert(key, context);
                }
                Ok(json!({"adjacent":adjacent,"graph_changed":changed,"transport":transport}))
            }
            "graph.connect" => {
                let source = string(p, "from");
                let target = string(p, "to");
                if source == target
                    || !self.nodes.contains_key(source)
                    || !self.nodes.contains_key(target)
                {
                    return Err("Choose two different live nodes in this workspace".into());
                }
                let source_node = serde_json::from_value(self.nodes[source].clone()).map_err(|e| format!("Invalid source: {e}"))?;
                let target_node = serde_json::from_value(self.nodes[target].clone()).map_err(|e| format!("Invalid target: {e}"))?;
                let canonical = graffitty_protocol::graph::connection(p, &source_node, &target_node,
                    |key| self.edges.get(key).and_then(|edge| serde_json::from_value(edge.clone()).ok()))?;
                let mut edge = serde_json::to_value(canonical).map_err(|e| e.to_string())?;
                let id = edge_key(&edge);
                let mut retained_revision = None;
                if let Some(existing) = self.edges.get(&id) {
                    let mut previous = existing.clone();
                    previous.as_object_mut().unwrap().remove("revision");
                    if previous == edge {
                        return Ok(existing.clone());
                    }
                    previous.as_object_mut().unwrap().remove("stop_at");
                    let mut permissions = edge.clone();
                    permissions.as_object_mut().unwrap().remove("stop_at");
                    if previous == permissions && !expired(existing, now()) {
                        retained_revision = Some(existing["revision"].clone());
                    }
                }
                self.revision += 1;
                edge["revision"] = retained_revision.unwrap_or_else(|| json!(self.revision));
                self.edges.insert(id, edge.clone());
                self.revoke();
                Ok(edge)
            }
            "graph.disconnect" => {
                let matches: Vec<_> = self
                    .edges
                    .iter()
                    .filter(|(_, e)| {
                        e["from"] == p["from"]
                            && e["to"] == p["to"]
                            && (string(p, "from_port").is_empty()
                                || e["from_port"] == p["from_port"])
                            && (string(p, "to_port").is_empty() || e["to_port"] == p["to_port"])
                    })
                    .map(|(k, _)| k.clone())
                    .collect();
                if matches.len() > 1 {
                    return Err("Specify the ports to disconnect".into());
                }
                for id in matches {
                    self.edges.remove(&id);
                }
                self.revoke();
                Ok(json!({"ok":true}))
            }
            "graph.adjacent" => Ok(self.adjacent(&key)),
            "graph.inbox" | "graph.take" => {
                let mut events = vec![];
                let mut budget = 3 * 1024 * 1024;
                for event in self.queues.get(&key).into_iter().flatten() {
                    if !self.allowed(event) {
                        continue;
                    }
                    let size = event.to_string().len();
                    if size > budget {
                        break;
                    }
                    budget -= size;
                    events.push(self.exposed_event(event));
                }
                Ok(json!({"events":events}))
            }
            "graph.ack" | "graph.progress" => {
                let queue = self.queues.entry(key.clone()).or_default();
                let index = queue
                    .iter()
                    .position(|e| e["event_id"] == p["event_id"])
                    .ok_or("Pending event not found")?;
                let event = queue[index].clone();
                let status = p.get("status").cloned().unwrap_or_else(|| json!(if method == "graph.progress" { "pending" } else { "delivered" }));
                if method == "graph.ack" {
                    queue.remove(index);
                } else {
                    if status != "pending" && status != "failed" {
                        return Err("Invalid progress status".into());
                    }
                    queue[index]["progress"] = p.clone();
                    queue[index]["progress"]["status"] = status.clone();
                }
                let status_text = status.as_str().unwrap_or("delivered");
                let pending = method == "graph.progress" || status_text == "queued in Codex";
                let journal_status = if method == "graph.progress" {
                    format!("{}: {}", status_text, string(p, "message"))
                } else if ["delivered", "submitted"].contains(&status_text) {
                    "sent to receiver".into()
                } else { status_text.into() };
                self.journal.record(&event, &journal_status, pending);
                self.receipts.retain(|e| e["event_id"] != event["event_id"]);
                self.receipts.push(json!({"event_id":event["event_id"],"source":event["source"],"target":key,"edge":event_key(&event),"status":status,"message":p["message"],"details":p["details"]}));
                if self.receipts.len() > self.settings.receipts {
                    self.receipts.remove(0);
                }
                Ok(json!({"ok":true}))
            }
            "graph.send" | "graph.emit" | "graph.forward" => {
                let mut params = p.clone();
                let mut content = None;
                if method == "graph.forward" {
                    let event = self
                        .queues
                        .get(&key)
                        .and_then(|q| q.iter().find(|e| e["event_id"] == p["event_id"]))
                        .filter(|event| self.allowed(event))
                        .ok_or("Pending event not found")?;
                    let event = self.exposed_event(event);
                    for field in [
                        "payload",
                        "text",
                        "content",
                        "renderings",
                        "sessions",
                        "kind",
                        "run_id",
                        "outcome",
                    ] {
                        params[field] = event[field].clone();
                    }
                    if let Some(patch) = p.get("content") {
                        let patch = patch.as_object().ok_or("content must be an object")?;
                        for (field, value) in patch {
                            if !["text", "payload", "content", "renderings"]
                                .contains(&field.as_str())
                            {
                                return Err("Invalid forward override".into());
                            }
                            params[field] = value.clone();
                        }
                    }
                    content = Some(
                        json!({"caused_by":event["event_id"],"origin":event.get("origin").cloned().unwrap_or(json!({"source":event["source"],"source_port":event["source_port"],"event_id":event["event_id"]}))}),
                    );
                }
                let output = if method == "graph.send" {
                    port(&self.nodes[&key], true, "send")
                        .or_else(|_| port(&self.nodes[&key], true, ""))?
                } else {
                    if !params.as_object().unwrap().contains_key("payload") {
                        return Err("payload is required".into());
                    }
                    let output = port(&self.nodes[&key], true, string(p, "output"))?;
                    if !is_custom_node(&self.nodes[&key]) && matches!(string(&output, "id"), "waiting" | "error") {
                        return Err("Lifecycle outputs are emitted by the agent integration".into());
                    }
                    output
                };
                let edges: Vec<_> = self
                    .edges
                    .values()
                    .filter(|e| {
                        e["from"] == key
                            && e["from_port"] == output["id"]
                            && e["send"] == true
                            && e["muted"] != true
                            && (method == "graph.send" || !expired(e, now()))
                            && (method != "graph.send" || e["to"] == p["to"])
                    })
                    .cloned()
                    .collect();
                if edges.is_empty() {
                    return Err("No matching Send connection".into());
                }
                if method == "graph.send" && expired(&edges[0], now()) {
                    return Err(STOP_TIME_ERROR.into());
                }
                let mut counts: HashMap<String, usize> = HashMap::new();
                for edge in &edges {
                    *counts.entry(string(edge, "to").into()).or_default() += 1;
                }
                for (target, count) in counts {
                    if self.queues.get(&target).map_or(0, Vec::len) + count > self.settings.pending_per_node {
                        return Err("Recipient queue is full".into());
                    }
                }
                if string(&params, "run_id").is_empty() {
                    params["run_id"] = json!(uuid());
                }
                if self
                    .runs
                    .get(string(&params, "run_id"))
                    .copied()
                    .unwrap_or(0)
                    + edges.len()
                    > self.run_limit(string(&params, "run_id"))
                {
                    return Err("Graph run message limit reached".into());
                }
                let mut events = vec![];
                for edge in edges {
                    events.push(self.enqueue(&edge, &params, content.as_ref(), false)?);
                }
                if method == "graph.send" {
                    Ok(events.remove(0))
                } else {
                    Ok(json!({"status":"queued","events":events,"run_id":params["run_id"]}))
                }
            }
            _ => Err("Unknown graph method".into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn connected_group_follows_both_directions_cycles_and_muted_links() {
        let edges = vec![json!({"from":"%3","to":"%2","muted":true}),
            json!({"from":"%1","to":"%2"}), json!({"from":"%3","to":"%1"}),
            json!({"from":"%8","to":"%9"})];
        for start in ["%1", "%2", "%3"] {
            assert_eq!(connected_component(start, &edges), HashSet::from(["%1".into(), "%2".into(), "%3".into()]));
        }
        assert_eq!(connected_component("%7", &edges), HashSet::from(["%7".into()]));
    }

    #[test]
    fn subscription_revision_wakes_for_delivery_and_revocation_not_reads_or_heartbeats() {
        let mut graph = Graph::default();
        for id in [1, 2] {
            graph.add(id, format!("Terminal {id}"));
            graph.dispatch(id, "agent.event", &json!({"provider":"pi", "event":"SessionStart",
                "session_id":format!("s{id}"), "transport":"inbox"})).unwrap();
        }
        let edge = json!({"from":"%1", "to":"%2", "send":true});
        graph.dispatch(1, "graph.connect", &edge).unwrap();
        let idle = graph.notification_revision();
        for method in ["graph.adjacent", "graph.list", "graph.take", "graph.inbox", "agent.heartbeat"] {
            graph.dispatch(2, method, &json!({})).unwrap();
            assert_eq!(graph.notification_revision(), idle, "{method} must not cause a notification loop");
        }
        graph.dispatch(1, "graph.send", &json!({"to":"%2", "text":"test"})).unwrap();
        let queued = graph.notification_revision();
        assert_ne!(queued, idle);
        assert_eq!(graph.dispatch(2, "graph.take", &json!({})).unwrap()["events"].as_array().unwrap().len(), 1);
        graph.dispatch(1, "graph.disconnect", &edge).unwrap();
        assert_ne!(graph.notification_revision(), queued);
        assert!(graph.dispatch(2, "graph.take", &json!({})).unwrap()["events"].as_array().unwrap().is_empty());
    }

    #[test]
    fn moving_nodes_preserves_internal_work_and_revokes_cross_session_delivery() {
        let mut source = Graph::default();
        let mut target = Graph::default();
        for id in 1..=3 { source.add(id, format!("Shell {id}")); }
        target.add(4, "Existing target".into());
        for receiver in [2, 3] {
            let edge = json!({"from":"%1","from_port":"out",
                "to":format!("%{receiver}"),"to_port":"in","send":true,"revision":1});
            source.edges.insert(edge_key(&edge), edge);
            source.queues.insert(format!("%{receiver}"), vec![json!({
                "source":"%1","source_port":"out","target":format!("%{receiver}"),
                "target_port":"in","type":"message","edge_revision":1,"event_id":format!("event-{receiver}")})]);
        }
        source.transfer_nodes_to(&HashSet::from([1, 2]), &mut target);
        assert_eq!(source.nodes.keys().cloned().collect::<Vec<_>>(), vec!["%3"]);
        assert_eq!(target.nodes.len(), 3);
        assert!(source.edges.is_empty());
        assert_eq!(target.edges.len(), 1);
        assert!(source.queues["%3"].is_empty());
        assert_eq!(target.queues["%2"].len(), 1);
        assert!(target.allowed(&target.queues["%2"][0]));
    }
    #[test]
    fn another_process_in_the_same_terminal_does_not_keep_the_previous_start_time() {
        let mut graph = Graph::default();
        graph.add(1, "Terminal 1".to_string());
        // Discovery learned the first agent's process and when it started.
        graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"SessionStart","pid":10,"started":"Mon Sep 21 10:00:00 2026"})).unwrap();
        assert_eq!(graph.nodes["%1"]["started"],"Mon Sep 21 10:00:00 2026");
        // The same process reporting again keeps it.
        graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"Stop","pid":10,"text":"done"})).unwrap();
        assert_eq!(graph.nodes["%1"]["started"],"Mon Sep 21 10:00:00 2026");
        // Another process, which does not say when it started, must not look
        // like the first one: a later check compares this time with the process.
        graph.dispatch(1,"agent.event",&json!({"provider":"pi","event":"SessionStart","pid":11,"integrated":true})).unwrap();
        assert_eq!(graph.nodes["%1"]["pid"],11);
        assert!(graph.nodes["%1"].get("started").is_none());
    }
    #[test]
    fn provider_prompt_restores_only_known_causal_runs_and_stop_preserves_them() {
        let mut graph = Graph::default();
        for id in [1,2,3] {
            graph.add(id, format!("Terminal {id}"));
            graph.dispatch(id,"agent.event",&json!({"provider":"claude","event":"SessionStart","pid":id,"session_id":format!("session-{id}")})).unwrap();
        }
        graph.dispatch(1,"graph.connect",&json!({"from":"%1","to":"%2","send":true})).unwrap();
        graph.dispatch(2,"graph.connect",&json!({"from":"%2","to":"%3","turn_completed":true})).unwrap();
        let event = graph.dispatch(1,"graph.send",&json!({"to":"%2","text":"request"})).unwrap();
        let run = event["run_id"].as_str().unwrap();
        let prompt = format!("[Graffitty message from %1; event accepted; run {run}]\nrequest");
        graph.dispatch(2,"agent.event",&json!({"provider":"claude","event":"UserPromptSubmit","prompt":prompt})).unwrap();
        assert_eq!(graph.nodes["%2"]["run_id"],run);
        graph.dispatch(2,"agent.event",&json!({"provider":"claude","event":"Stop","text":"completion"})).unwrap();
        assert_eq!(graph.queues["%3"][0]["run_id"],run);
        assert_eq!(graph.runs[run],2,"The forwarded completion consumes the original run budget");
        for prompt in ["ordinary user input", "[Graffitty message from %1; run unknown]\nrequest"] {
            graph.dispatch(2,"agent.event",&json!({"provider":"claude","event":"UserPromptSubmit","prompt":prompt})).unwrap();
            assert!(graph.nodes["%2"].get("run_id").is_none());
        }
        graph.dispatch(2,"agent.event",&json!({"provider":"claude","event":"Stop","text":"new user completion"})).unwrap();
        assert_ne!(graph.queues["%3"][1]["run_id"],run);
    }

    #[test]
    fn hooks_refresh_only_the_callers_changed_permissions() {
        let mut graph = setup();
        let hook = |graph: &mut Graph, id| graph.dispatch(id, "agent.event", &json!({"provider":"adapter","event":"PreToolUse"})).unwrap();
        hook(&mut graph, 2);
        assert_eq!(hook(&mut graph, 2)["graph_changed"], false);
        graph.dispatch(1, "graph.connect", &json!({"from":"%1","to":"%3","from_port":"out","to_port":"in","read":true})).unwrap();
        assert_eq!(hook(&mut graph, 2)["graph_changed"], false);
        graph.dispatch(1, "graph.connect", &json!({"from":"%1","to":"%2","from_port":"out","to_port":"in","read":true})).unwrap();
        assert_eq!(hook(&mut graph, 2)["graph_changed"], true);
        assert_eq!(hook(&mut graph, 2)["graph_changed"], false);
        graph.dispatch(1, "graph.disconnect", &json!({"from":"%1","to":"%2"})).unwrap();
        let denied = graph.read_denied("%1", "%2");
        assert_eq!(denied["code"], "connection_changed");
        assert_eq!(denied["adjacent"]["incoming"], json!([]));
        assert_eq!(hook(&mut graph, 2)["graph_changed"], true);
        assert_eq!(hook(&mut graph, 2)["graph_changed"], false);
    }

    fn setup() -> Graph {
        let mut g = Graph::default();
        for id in 1..=3 {
            g.add(id, format!("Node {id}"));
            g.dispatch(
                id,
                "agent.event",
                &json!({"provider":"adapter","event":"SessionStart","pid":id}),
            )
            .unwrap();
            g.dispatch(
                id,
                "agent.register",
                &json!({"name":"Test","inputs":[{"id":"in"}],"outputs":[{"id":"out"}]}),
            )
            .unwrap();
        }
        g
    }
    #[test]
    fn output_line_style_survives_registration_without_changing_delivery() {
        let mut g = setup();
        g.dispatch(1, "agent.register", &json!({"name":"Renamed composer","inputs":[],
            "outputs":[{"id":"out","line_style":"solid"}]})).unwrap();
        let snapshot = g.snapshot();
        let source = snapshot["nodes"].as_array().unwrap().iter().find(|n| n["node"] == "%1").unwrap();
        assert_eq!(source["manifest"]["outputs"][0]["line_style"], "solid");
        let edge = g.dispatch(1, "graph.connect", &send_edge()).unwrap();
        assert_eq!(edge["send"], true);
        assert_eq!(edge["turn_completed"], false);
        g.dispatch(1, "graph.emit", &json!({"output":"out","payload":"submitted"})).unwrap();
        assert_eq!(g.queues["%2"][0]["text"], "submitted");
        for style in [json!("dotted"), json!("unknown"), json!(7), Value::Null] {
            assert!(manifest(&json!({"inputs":[],"outputs":[{"id":"out","line_style":style}]})).is_err());
        }
        assert!(manifest(&json!({"inputs":[{"id":"in","line_style":"solid"}],"outputs":[]})).is_err());
    }
    #[test]
    fn connections_use_the_same_pane_ids_as_nodes_including_zero() {
        let mut graph = Graph::default();
        for id in [0, 2] {
            graph.add(id, format!("Pane {id}"));
            graph.dispatch(id, "agent.event", &json!({
                "provider":"adapter", "event":"SessionStart", "pid":id
            })).unwrap();
            graph.dispatch(id, "agent.register", &json!({
                "name":"Fixture", "inputs":[{"id":"in"}], "outputs":[{"id":"out"}]
            })).unwrap();
        }
        let connected = graph.dispatch(0, "graph.connect", &json!({
            "from":"%0", "to":"%2", "from_port":"out", "to_port":"in"
        })).unwrap();
        assert_eq!(connected["from"], "%0");
        assert_eq!(connected["to"], "%2");
        assert!(graph.edges.contains_key("%0/out>%2/in"));
        for node in graph.snapshot()["nodes"].as_array().unwrap() {
            assert_eq!(node["pane"], node["node"]);
            assert!(crate::pane_id::parse(node["node"].as_str().unwrap()).is_some());
        }
    }

    #[test]
    fn authority_forwarding_and_revocation() {
        let mut g = setup();
        assert!(
            g.dispatch(1, "graph.emit", &json!({"output":"out","payload":"hello"}))
                .is_err()
        );
        let edge = json!({"from":"%1","to":"%2","from_port":"out","to_port":"in"});
        g.dispatch(1, "graph.connect", &edge).unwrap();
        g.dispatch(
            2,
            "graph.connect",
            &json!({"from":"%2","to":"%3","from_port":"out","to_port":"in"}),
        )
        .unwrap();
        let result = g
            .dispatch(
                1,
                "graph.emit",
                &json!({"output":"out","payload":{"text":"한글"},"source":"%3"}),
            )
            .unwrap();
        let id = &result["events"][0]["event_id"];
        let event = &g.dispatch(2, "graph.take", &json!({})).unwrap()["events"][0];
        assert_eq!(event["source"], "%1");
        assert!(!g.can_read("%1", "%2"));
        g.dispatch(2, "graph.forward", &json!({"output":"out","event_id":id}))
            .unwrap();
        let forwarded = &g.dispatch(3, "graph.take", &json!({})).unwrap()["events"][0];
        assert_eq!(forwarded["origin"]["source"], "%1");
        assert_eq!(forwarded["text"], "한글");
        g.dispatch(1, "graph.disconnect", &edge).unwrap();
        assert!(
            g.dispatch(2, "graph.take", &json!({})).unwrap()["events"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(
            g.dispatch(2, "graph.forward", &json!({"output":"out","event_id":id}))
                .is_err()
        );
        assert!(
            g.dispatch(
                1,
                "graph.connect",
                &json!({"from":"%1","to":"%99"})
            )
            .is_err()
        );
    }
    #[test]
    fn bounded_fanout_is_atomic() {
        let mut g = setup();
        for id in 2..=3 {
            g.dispatch(1,"graph.connect",&json!({"from":"%1","to":format!("%{id}"),"from_port":"out","to_port":"in"})).unwrap();
        }
        for _ in 0..QUEUE_LIMIT {
            g.dispatch(1, "graph.emit", &json!({"output":"out","payload":"hello"}))
                .unwrap();
        }
        assert!(
            g.dispatch(
                1,
                "graph.emit",
                &json!({"output":"out","payload":"overflow"})
            )
            .is_err()
        );
        assert_eq!(g.queues["%2"].len(), QUEUE_LIMIT);
        assert_eq!(g.queues["%3"].len(), QUEUE_LIMIT);
        g.remove(1);
        assert!(g.queues["%2"].is_empty());
    }

    fn send_edge() -> Value {
        json!({"from":"%1","to":"%2","from_port":"out","to_port":"in"})
    }

    #[test]
    fn stop_time_defaults_preserves_and_validates() {
        let mut g = setup();
        let mut params = send_edge();
        let initial = g.dispatch(1, "graph.connect", &params).unwrap();
        assert!(initial.get("stop_at").is_none());
        assert_eq!(g.next_stop_at, None);
        let deadline = now() + 600.0;
        params["stop_at"] = json!(deadline);
        let scheduled = g.dispatch(1, "graph.connect", &params).unwrap();
        assert_eq!(scheduled["stop_at"], deadline);
        assert_eq!(g.next_stop_at, Some(deadline));
        params.as_object_mut().unwrap().remove("stop_at");
        params["contains"] = json!("keep");
        let edited = g.dispatch(1, "graph.connect", &params).unwrap();
        assert_eq!(
            edited["stop_at"], deadline,
            "Omitted update preserves deadline"
        );
        for invalid in [json!(-1), json!("tomorrow"), json!(true), Value::Null] {
            params["stop_at"] = invalid;
            assert!(
                g.dispatch(1, "graph.connect", &params)
                    .unwrap_err()
                    .contains("stop_at")
            );
            assert_eq!(g.edges[&edge_key(&params)]["stop_at"], deadline);
        }
        params["stop_at"] = json!(0);
        let cleared = g.dispatch(1, "graph.connect", &params).unwrap();
        assert!(cleared.get("stop_at").is_none());
        assert_eq!(g.next_stop_at, None);
    }

    #[test]
    fn active_deadline_edits_preserve_accepted_messages() {
        let mut g = setup();
        let mut params = send_edge();
        let original = g.dispatch(1, "graph.connect", &params).unwrap();
        g.dispatch(
            1,
            "graph.emit",
            &json!({"output":"out","payload":"accepted"}),
        )
        .unwrap();
        let event = g.queues["%2"][0].clone();
        for deadline in [now() + 600.0, now() + 60.0, 0.0] {
            params["stop_at"] = json!(deadline);
            let edge = g.dispatch(1, "graph.connect", &params).unwrap();
            assert_eq!(edge["revision"], original["revision"]);
            assert_eq!(g.queues["%2"], vec![event.clone()]);
            assert!(g.allowed(&event));
        }
        params["muted"] = json!(true);
        let edge = g.dispatch(1, "graph.connect", &params).unwrap();
        assert_ne!(edge["revision"], original["revision"]);
        assert!(!g.allowed(&event));
        assert!(g.queues["%2"].is_empty());
    }

    #[test]
    fn deadline_boundary_expires_once_and_keeps_edge_visible() {
        let mut g = setup();
        let deadline = now() + 600.0;
        let mut params = send_edge();
        params["stop_at"] = json!(deadline);
        let edge = g.dispatch(1, "graph.connect", &params).unwrap();
        g.dispatch(
            1,
            "graph.emit",
            &json!({"output":"out","payload":"accepted"}),
        )
        .unwrap();
        let event = g.queues["%2"][0].clone();
        assert!(g.allowed_at(&event, deadline - 0.001));
        assert!(!g.allowed_at(&event, deadline));
        let before = g.revision;
        g.expire_at(deadline - 0.001);
        assert_eq!(g.revision, before);
        g.expire_at(deadline);
        assert!(g.queues["%2"].is_empty());
        assert_eq!(g.edges[&edge_key(&edge)], edge);
        assert_eq!(g.revision, before + 1);
        assert_eq!(g.next_stop_at, None);
        g.expire_at(deadline + 100.0);
        assert_eq!(g.revision, before + 1, "Expiry is processed only once");
    }

    #[test]
    fn expired_connections_block_send_read_and_turn_fanout() {
        let mut g = setup();
        let mut params = send_edge();
        params["stop_at"] = json!(now() - 1.0);
        g.dispatch(1, "graph.connect", &params).unwrap();
        assert_eq!(
            g.dispatch(
                1,
                "graph.send",
                &json!({"to":"%2","text":"blocked"})
            )
            .unwrap_err(),
            STOP_TIME_ERROR
        );
        g.dispatch(1, "agent.register", &json!({"name":"Test","inputs":[{"id":"in"}],
            "outputs":[{"id":"out"},{"id":"read","mode":"read"},{"id":"turn","mode":"turn_completed"}]})).unwrap();
        for output in ["read", "turn"] {
            params["from_port"] = json!(output);
            g.dispatch(1, "graph.connect", &params).unwrap();
        }
        assert!(!g.can_read("%1", "%2"));
        assert!(g.can_read("%1", "%1"));
        g.dispatch(
            1,
            "agent.event",
            &json!({"provider":"adapter","event":"Stop","text":"no turn delivery"}),
        )
        .unwrap();
        assert!(g.queues.values().all(Vec::is_empty));
        params = send_edge();
        params["to"] = json!("%3");
        g.dispatch(1, "graph.connect", &params).unwrap();
        let emitted = g
            .dispatch(
                1,
                "graph.emit",
                &json!({"output":"out","payload":"live only"}),
            )
            .unwrap();
        assert_eq!(emitted["events"].as_array().unwrap().len(), 1);
        assert_eq!(g.queues["%3"].len(), 1);
        assert!(g.queues.get("%2").is_none_or(Vec::is_empty));
    }

    #[test]
    fn expired_reopen_revokes_old_pending_even_before_actor_expiry() {
        let mut g = setup();
        let params = send_edge();
        let edge = g.dispatch(1, "graph.connect", &params).unwrap();
        g.dispatch(1, "graph.emit", &json!({"output":"out","payload":"old"}))
            .unwrap();
        let old = g.queues["%2"][0].clone();
        // Move the clock boundary into the past without delivering actor expiry.
        g.edges.get_mut(&edge_key(&edge)).unwrap()["stop_at"] = json!(now() - 1.0);
        g.schedule_expiry();
        let mut clear = params.clone();
        clear["stop_at"] = json!(0);
        let reopened = g.dispatch(1, "graph.connect", &clear).unwrap();
        assert_ne!(reopened["revision"], edge["revision"]);
        assert!(!g.allowed(&old));
        assert!(g.queues["%2"].is_empty());
        g.dispatch(1, "graph.emit", &json!({"output":"out","payload":"new"}))
            .unwrap();
        assert_eq!(g.queues["%2"][0]["text"], "new");
    }
}

#[cfg(test)]
#[path = "graph_tests.rs"]
mod migration_tests;
