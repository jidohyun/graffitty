//! Server-driven recovery checkpoints. The helper performs slow agent discovery
//! and atomic history writes without blocking PTY or client processing.
//!
//! The server saves when its own state changes and settles, when an agent
//! session starts or ends, on the interval, and once more as it ends on a
//! signal.
//!
//! Saves are rolling: the helper skips one that changed nothing and keeps
//! history entries an interval apart, as herdr-core keeps one current
//! `session.json` beside spaced snapshots.
use crate::{Error, Server, workspace};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

/// Native lifecycle changes come from process-bound discovery, not hook status:
/// SessionEnd runs while the old process can still be saved as resumable.
#[derive(Default)]
pub struct Lifecycle {
    agents: HashMap<u64, Value>,
    pending: bool,
}
impl Lifecycle {
    pub fn observe(&mut self, id: u64, state: &Value) {
        if state["status"] == "offline" {
            self.closed(id);
            return;
        }
        let provider = state["provider"].as_str().unwrap_or("");
        if !["codex", "claude", "opencode", "pi"].contains(&provider)
            && !graffitty_workspace_core::graph::is_custom_node(state) {
            return;
        }
        let mut identity = json!({"kind":state["kind"],"provider":provider,"pid":state["pid"],
            "started":state["started"],"session_id":state["session_id"]});
        if let Some(previous) = self.agents.get(&id) {
            if previous["provider"] == identity["provider"]
                && previous["kind"] == identity["kind"]
                && previous["pid"] == identity["pid"]
                && (identity["started"].is_null()
                    || previous["started"].is_null()
                    || previous["started"] == identity["started"])
            {
                // A transient discovery miss is not a new session. Learning a
                // process start time later also must not duplicate a hook save.
                for field in ["started", "session_id"] {
                    if identity[field].as_str().is_none_or(str::is_empty) {
                        identity[field] = previous[field].clone();
                    }
                }
                let same_session = previous["session_id"] == identity["session_id"];
                self.agents.insert(id, identity.clone());
                if same_session {
                    return;
                }
            } else {
                self.closed(id);
            }
        }
        // Wait until a native conversation can actually be restored. This also
        // handles daemon agents whose hooks cannot be routed to their frontend.
        if ["codex", "claude", "opencode", "pi"].contains(&provider)
            && state["transport"] != "inbox"
            && identity["session_id"].as_str().is_none_or(str::is_empty)
        {
            return;
        }
        self.agents.insert(id, identity);
        self.pending = true;
    }
    pub fn hook(&mut self, id: u64, event: &Value, node: &Value) {
        if node["transport"] == "inbox"
            || graffitty_workspace_core::graph::is_custom_node(node)
        {
            if event == "SessionStart" || event == "SessionEnd" {
                self.observe(id, node);
            }
        }
    }
    pub fn closed(&mut self, id: u64) {
        self.pending |= self.agents.remove(&id).is_some();
    }
}

struct Schedule {
    next: Instant,
    retry_at: Instant,
}
impl Schedule {
    fn new(now: Instant, interval: Duration) -> Self {
        Self {
            next: now + interval,
            retry_at: now,
        }
    }
    fn due(&self, now: Instant, pending: bool) -> bool {
        now >= self.retry_at && (pending || now >= self.next)
    }
    fn attempted(&mut self, now: Instant, interval: Duration) {
        self.retry_at = now + interval.min(Duration::from_secs(60));
    }
    fn saved(&mut self, now: Instant, interval: Duration) {
        self.next = now + interval;
        self.retry_at = now;
    }
}

pub fn capture(server: &mut Server, names: &[String]) -> Result<Value, Error> {
    let mut windows = vec![];
    for name in names {
        workspace::sync(server, name)?;
        let state = server.workspace_state.snapshot(name);
        let panes: Vec<_> = server
            .sessions
            .values()
            .filter(|s| &s.workspace == name)
            .map(|s| {
                let mut pane = json!({"id":s.id,"pid":s.pid(),"cwd":s.cwd().unwrap_or_default(),
                "title":s.pinned_title,"font_size":s.font_size});
                if let Some(tree) = crate::filetree::checkpoint(server, s.id) {
                    pane["filetree"] = tree;
                }
                if let Some(parent) = s.spawned_by.filter(|p| server.sessions.get(p).is_some_and(|p| &p.workspace == name)) {
                    pane["spawned_by"] = json!(parent);
                    pane["dies_with_parent"] = json!(s.dies_with_parent);
                }
                // A running node that opted in relaunches from its own declaration,
                // with the latest state it reported. Claude and Codex are found
                // by the CLI's process discovery instead.
                if let Some(node) = server.graphs.get(name).and_then(|g| g.nodes.get(&format!("%{}",s.id))) {
                    if let Some(restore) = node.get("restore").filter(|_| node["status"] != "offline" && pane.get("filetree").is_none()) {
                        let mut entry = restore.clone();
                        if node["pid"].as_i64().is_some_and(|pid| pid > 0) {
                            entry["pid"] = node["pid"].clone();
                        }
                        if let Some(state) = node.get("checkpoint_state") {
                            entry["state"] = state.clone();
                        }
                        pane["node"] = entry;
                    }
                }
                pane
            })
            .collect();
        // Only self-owned chromiums can outlive every terminal; restore
        // has no terminal of this window to reopen them through.
        if panes.is_empty() {
            continue;
        }
        // Chromiums placed in this workspace's layout reopen through their
        // owner terminal. Detached windows and viewers whose filetree closed
        // have none; restore opens those through the window's first terminal.
        let placed: std::collections::HashSet<String> = state.order.iter()
            .flat_map(|id| state.layout.tabs[id].windows.iter().map(|w| w.key.clone()))
            .collect();
        let terminals: std::collections::HashSet<u64> = panes.iter()
            .filter(|pane| pane.get("filetree").is_none())
            .filter_map(|pane| pane["id"].as_u64())
            .collect();
        let mut chromiums: Vec<_> = server.chromiums.values()
            .filter(|b| &b.workspace == name && placed.contains(&format!("%{}", b.id)))
            .map(|b| {
                let mut entry = b.snapshot();
                entry["owner"] = if b.owner != b.id && terminals.contains(&b.owner) { json!(b.owner) } else { Value::Null };
                entry
            })
            .collect();
        chromiums.sort_by_key(|entry| entry["id"].as_u64());
        let tabs: Vec<_> = state.order.iter().map(|id| {
            let layout = &state.layout.tabs[id];
            let windows: Vec<_> = layout.windows.iter().map(|w| json!({"pane":w.key,"shown":w.shown,
                "stashed":w.stashed,"graph_floating":w.graph_floating,"rect":{"rect2":w.rect}})).collect();
            let mut visual = serde_json::to_value(&layout.graph_visual).unwrap();
            for point in visual["reroutes"].as_object_mut().unwrap().values_mut() {
                point["position"] = json!({"vec2":point["position"]});
            }
            json!({"id":id,"title":server.tab_titles.get(id).cloned().unwrap_or_default(),
                "focused":layout.focused,"area":state.tabs[id].area,"graph_visual":visual,
                "tree":{"windows":windows,"tiling":layout.enabled,"physics":layout.physics,
                    "physics_anchor":layout.physics_anchor,"tiling_axis":layout.axis,"tiling_gap":layout.gap,
                    "tiles":layout.tiles.as_ref().map(|v|serde_json::to_value(v).unwrap()).unwrap_or(json!({}))}})
        }).collect();
        let area = state
            .active
            .and_then(|id| state.tabs.get(&id))
            .map(|s| s.area)
            .unwrap_or([0., 34., 1280., 766.]);
        windows.push(json!({"workspace":server.workspaces.id(name),"active":state.active,"tabs":tabs,"panes":panes,"chromiums":chromiums,
            "position":[0,0],"size":[area[2],area[1]+area[3]],"mode":0,"plugin":"",
            "graph":server.graphs.get(name).map(|g|g.checkpoint()).unwrap_or(json!({"nodes":[],"edges":[]}))}));
    }
    let document = json!({"version":1,"windows":windows});
    graffitty_workspace_core::checkpoint::validate(&document)?;
    Ok(document)
}

pub fn restore_graph(server: &mut Server, workspace: &str, value: &Value) -> Result<Value, Error> {
    let ids: std::collections::HashMap<String, String> =
        serde_json::from_value(value["ids"].clone())?;
    let saved = &value["graph"];
    if saved.is_null() {
        return restore_spawned(server, workspace, value, &ids);
    }
    for edge in saved["edges"]
        .as_array()
        .ok_or("Invalid saved connections")?
    {
        let mut mapped = edge.clone();
        for field in ["from", "to"] {
            mapped[field] = json!(
                ids.get(edge[field].as_str().ok_or("Invalid connection endpoint")?)
                    .ok_or("Missing restored connection endpoint")?
            );
        }
        crate::regroup::validate_connection(server, workspace, &mapped)?;
    }
    server
        .graphs
        .get_mut(workspace)
        .ok_or("Unknown workspace")?
        .restore_checkpoint(saved, &ids)?;
    restore_spawned(server, workspace, value, &ids)
}

/// Parent links are restored with the graph: both are connections between
/// the same recreated panes, and both wait until every pane exists.
fn restore_spawned(server: &mut Server, workspace: &str, value: &Value, ids: &std::collections::HashMap<String, String>) -> Result<Value, Error> {
    if let Some(spawned) = value.get("spawned").filter(|v| !v.is_null()) {
        let links: Vec<Value> = serde_json::from_value(spawned.clone())?;
        for link in links {
            let pane = |field: &str| -> Result<u64, Error> {
                let saved = link[field].as_i64().ok_or("Invalid spawned link")?;
                let mapped = ids.get(&format!("%{saved}")).ok_or("Missing restored spawned pane")?;
                mapped.strip_prefix('%').and_then(|id| id.parse().ok()).ok_or_else(|| "Invalid restored pane".into())
            };
            let (child, parent) = (pane("pane")?, pane("spawned_by")?);
            if child == parent { return Err("A pane cannot spawn itself".into()); }
            let same = server.sessions.get(&child).zip(server.sessions.get(&parent))
                .is_some_and(|(c, p)| c.workspace == workspace && p.workspace == workspace && c.tab == p.tab);
            if !same { return Err("Spawned panes must share their parent's tab".into()); }
            let child = server.sessions.get_mut(&child).unwrap();
            child.spawned_by = Some(parent);
            child.dies_with_parent = link["dies_with_parent"].as_bool().unwrap_or(false);
        }
    }
    Ok(json!({"ok":true}))
}

struct Job {
    child: Child,
    input: PathBuf,
    errors: PathBuf,
    started: Instant,
}
impl Drop for Job {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        let _ = fs::remove_file(&self.input);
        let _ = fs::remove_file(&self.errors);
    }
}

/// How long a changed state must stay the same before it is saved: a drag,
/// a resize or a burst of new panes is one change.
const SETTLE: Duration = Duration::from_secs(10);
/// The least time between two saves that only a state change asked for.
const CHANGE_SPACING: Duration = Duration::from_secs(60);
/// How long an ending server waits for its last save.
const FINISH: Duration = Duration::from_secs(5);

/// Notices a state that differs from the saved one and has stopped changing.
#[derive(Default)]
struct Changes {
    saved: Option<u64>,
    seen: Option<u64>,
    settled: bool,
}
impl Changes {
    fn look(&mut self, state: Option<u64>) {
        self.settled = state.is_some() && state != self.saved && state == self.seen;
        self.seen = state;
    }
    fn saved(&mut self, state: u64) {
        self.saved = Some(state);
        self.settled = false;
    }
}

/// Every session's state as the helper receives it.
fn document(server: &mut Server) -> Result<Vec<u8>, Error> {
    let mut names: Vec<_> = server.workspaces.iter().cloned().collect();
    names.sort();
    let bytes = serde_json::to_vec(&capture(server, &names)?)?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err("checkpoint exceeds 4 MiB".into());
    }
    Ok(bytes)
}
fn fingerprint(bytes: &[u8]) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

pub struct Automatic {
    schedule: Schedule,
    job: Option<Job>,
    changes: Changes,
    look_at: Instant,
    change_at: Instant,
}
impl Automatic {
    pub fn new(interval: u64) -> Self {
        let now = Instant::now();
        Self {
            schedule: Schedule::new(now, Duration::from_secs(interval)),
            job: None,
            changes: Changes::default(),
            look_at: now + SETTLE,
            change_at: now,
        }
    }
    /// The server is ending on a signal: save its last state, within a bound
    /// the system's shutdown allows. Programs the system has already ended
    /// make the helper refuse, which leaves the previous rolling save.
    pub fn finish(&mut self, server: &mut Server) {
        if !server.settings.checkpoints.enabled || server.sessions.is_empty() {
            return;
        }
        let deadline = Instant::now() + FINISH;
        for launch in [false, true] {
            if launch {
                if let Err(error) = self.launch(server) {
                    eprintln!("[checkpoints] {error}");
                }
            }
            if let Some(mut job) = self.job.take() {
                while job.child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
        }
    }
    fn launch(&mut self, server: &mut Server) -> Result<(), Error> {
        let bytes = document(server)?;
        let input = server
            .descriptor
            .parent()
            .unwrap_or(Path::new("."))
            .join(format!("checkpoint-{}.tmp", uuid::Uuid::new_v4()));
        let errors = input.with_extension("err");
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let launch = (|| -> Result<Child, Error> {
            options.open(&input)?.write_all(&bytes)?;
            Ok(Command::new(&server.cli)
                .args(["checkpoint", "save", "--tag", "auto", "--rolling"])
                .arg(server.settings.checkpoints.interval_seconds.to_string())
                .arg("--input")
                .arg(&input)
                .env(
                    "GRAFFITTY_CHECKPOINT_HISTORY",
                    server.settings.checkpoints.history.to_string(),
                )
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(options.open(&errors)?)
                .spawn()?)
        })();
        match launch {
            Ok(child) => {
                server.checkpoint_lifecycle.pending = false;
                self.changes.saved(fingerprint(&bytes));
                self.change_at = Instant::now() + CHANGE_SPACING;
                self.job = Some(Job {
                    child,
                    input,
                    errors,
                    started: Instant::now(),
                });
                Ok(())
            }
            Err(error) => {
                let _ = fs::remove_file(input);
                let _ = fs::remove_file(errors);
                Err(error)
            }
        }
    }
    pub fn poll(&mut self, server: &mut Server) {
        let interval = Duration::from_secs(server.settings.checkpoints.interval_seconds);
        if let Some(job) = &mut self.job {
            let status = job.child.try_wait();
            if matches!(status, Ok(Some(_)))
                || status.is_err()
                || job.started.elapsed() >= Duration::from_secs(60)
            {
                if matches!(status, Ok(Some(status)) if status.success()) {
                    // Count from a completed write, including lifecycle saves.
                    self.schedule.saved(Instant::now(), interval);
                } else {
                    server.checkpoint_lifecycle.pending = true;
                    self.schedule.attempted(Instant::now(), interval);
                    let mut detail = String::new();
                    if let Ok(file) = fs::File::open(&job.errors) {
                        let _ = file.take(4096).read_to_string(&mut detail);
                    }
                    eprintln!(
                        "[checkpoints] Automatic save failed or timed out: {}",
                        detail.trim()
                    );
                }
                self.job = None;
            }
        }
        if !server.settings.checkpoints.enabled || self.job.is_some() {
            return;
        }
        let now = Instant::now();
        if now >= self.look_at {
            self.look_at = now + SETTLE;
            let state = (!server.sessions.is_empty())
                .then(|| document(server).ok())
                .flatten()
                .map(|bytes| fingerprint(&bytes));
            self.changes.look(state);
        }
        let changed = self.changes.settled && now >= self.change_at;
        if !self
            .schedule
            .due(now, server.checkpoint_lifecycle.pending || changed)
        {
            return;
        }
        self.schedule.attempted(now, interval);
        if server.sessions.is_empty() {
            return;
        }
        if let Err(error) = self.launch(server) {
            eprintln!("[checkpoints] {error}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_successful_auto_save_restarts_the_full_interval() {
        let start = Instant::now();
        let interval = Duration::from_secs(1800);
        let mut schedule = Schedule::new(start, interval);
        assert!(!schedule.due(start + Duration::from_secs(1799), false));
        assert!(schedule.due(start + interval, false));
        // A session start saves at minute 20, and an end saves at minute 25.
        for elapsed in [1200, 1500] {
            let now = start + Duration::from_secs(elapsed);
            assert!(schedule.due(now, true));
            schedule.attempted(now, interval);
            schedule.saved(now + Duration::from_secs(2), interval);
        }
        assert!(!schedule.due(start + interval, false));
        assert!(!schedule.due(start + Duration::from_secs(3301), false));
        assert!(schedule.due(start + Duration::from_secs(3302), false));
        // Events arriving during a helper are still eligible after it succeeds.
        assert!(schedule.due(start + Duration::from_secs(1502), true));
    }

    #[test]
    fn a_changed_state_is_saved_once_it_settles() {
        let mut changes = Changes::default();
        changes.look(None); // No sessions yet.
        assert!(!changes.settled);
        changes.look(Some(1));
        assert!(!changes.settled, "A first look cannot tell that it settled");
        changes.look(Some(2)); // Still moving.
        assert!(!changes.settled);
        changes.look(Some(2));
        assert!(changes.settled);
        changes.saved(2);
        changes.look(Some(2));
        assert!(!changes.settled, "The saved state is not a change");
        changes.look(Some(3));
        changes.look(Some(3));
        assert!(changes.settled);
    }

    #[test]
    fn failed_attempts_delay_retries_without_postponing_the_timer() {
        let start = Instant::now();
        let interval = Duration::from_secs(1800);
        let mut schedule = Schedule::new(start, interval);
        schedule.attempted(start + Duration::from_secs(1200), interval);
        assert!(!schedule.due(start + Duration::from_secs(1259), true));
        assert!(schedule.due(start + Duration::from_secs(1260), true));
        assert!(schedule.due(start + interval, false));
    }

    #[test]
    fn native_sessions_wait_for_identity_and_actual_exit() {
        let mut lifecycle = Lifecycle::default();
        let mut node = json!({"provider":"codex","pid":42,"started":"today","status":"idle"});
        lifecycle.observe(1, &node);
        assert!(!lifecycle.pending);
        node["session_id"] = json!("first-session");
        lifecycle.observe(1, &node);
        assert!(std::mem::take(&mut lifecycle.pending));
        node["status"] = json!("busy");
        lifecycle.observe(1, &node);
        lifecycle.hook(1, &json!("SessionStart"), &node); // compaction
        lifecycle.hook(1, &json!("Stop"), &node);
        let mut ending = node.clone();
        ending["status"] = json!("offline");
        lifecycle.hook(1, &json!("SessionEnd"), &ending);
        lifecycle.observe(1, &node); // Still alive after its end hook.
        let mut missing = node.clone();
        missing.as_object_mut().unwrap().remove("session_id");
        lifecycle.observe(1, &missing);
        assert!(!lifecycle.pending);
        lifecycle.observe(1, &json!({"status":"offline"}));
        assert!(std::mem::take(&mut lifecycle.pending));
        lifecycle.observe(1, &json!({"status":"offline"}));
        assert!(!lifecycle.pending);
        node["pid"] = json!(43); // Resume the same conversation in a new process.
        lifecycle.observe(1, &node);
        assert!(std::mem::take(&mut lifecycle.pending));
        node["session_id"] = json!("new-session"); // /clear, same process.
        lifecycle.observe(1, &node);
        assert!(std::mem::take(&mut lifecycle.pending));
        lifecycle.observe(1, &node);
        assert!(!lifecycle.pending);
        lifecycle.closed(1);
        assert!(lifecycle.pending);
    }

    #[test]
    fn adapter_hooks_trigger_only_session_lifecycle_changes() {
        let mut lifecycle = Lifecycle::default();
        let mut node =
            json!({"provider":"adapter","pid":42,"session_id":"adapter-42","status":"idle"});
        lifecycle.hook(1, &json!("SessionStart"), &node);
        assert!(std::mem::take(&mut lifecycle.pending));
        lifecycle.hook(1, &json!("SessionStart"), &node);
        lifecycle.hook(1, &json!("Stop"), &node);
        assert!(!lifecycle.pending);
        node["status"] = json!("offline");
        lifecycle.hook(1, &json!("SessionEnd"), &node);
        assert!(std::mem::take(&mut lifecycle.pending));
        lifecycle.hook(1, &json!("SessionEnd"), &node);
        assert!(!lifecycle.pending);
    }

    #[test]
    fn providerless_node_lifecycle_still_triggers_checkpoints() {
        let mut lifecycle = Lifecycle::default();
        let mut node = json!({"kind":"custom","pid":42,"status":"idle"});
        lifecycle.hook(1, &json!("SessionStart"), &node);
        assert!(std::mem::take(&mut lifecycle.pending));
        lifecycle.hook(1, &json!("SessionStart"), &node);
        assert!(!lifecycle.pending);
        node["status"] = json!("offline");
        lifecycle.hook(1, &json!("SessionEnd"), &node);
        assert!(std::mem::take(&mut lifecycle.pending));
    }
}
