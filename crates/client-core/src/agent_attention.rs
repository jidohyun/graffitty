//! Unseen agent outcomes for tab markers.
//!
//! The workspace server timestamps every agent status change in
//! `status_history`.
//!
//! That history is the evidence: a completion is a busy or waiting entry
//! followed by idle, a wait is an entry entering `waiting`.
//!
//! Live status transitions between observations are a second source when
//! history is missing or its clock moved backwards.
//!
//! Server timestamps are only compared with server timestamps, so client
//! clock skew cannot create or hide markers.
//!
//! Each pane holds at most one unseen completion and one unseen wait. Seeing
//! the pane clears both; a tab marker clears only when every pane in it was
//! seen.
//!
//! The current status always wins over remembered events: a pane that runs
//! again is no longer completed, and one that stopped waiting no longer needs
//! input.
//!
//! This keeps a missed lifecycle event from leaving a marker stuck.
use chrono::{DateTime, FixedOffset};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

const PROVIDERS: [&str; 4] = ["claude", "codex", "opencode", "pi"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Marker {
    Completed,
    Waiting,
}

#[derive(Default, Debug)]
struct Pane {
    /// Latest history time already applied, and how many entries at exactly
    /// that time were applied (several can share one millisecond).
    cursor: Option<(DateTime<FixedOffset>, usize)>,
    status: String,
    completed: bool,
    waiting: bool,
}

#[derive(Default, Debug)]
pub struct AgentAttention {
    panes: HashMap<String, Pane>,
}

fn history(node: &Value) -> Vec<(DateTime<FixedOffset>, &str)> {
    // Malformed entries are not evidence; skip them rather than guess.
    node["status_history"].as_array().into_iter().flatten().filter_map(|entry| {
        let at = DateTime::parse_from_rfc3339(entry["at"].as_str()?).ok()?;
        Some((at, entry["status"].as_str()?))
    }).collect()
}

fn agent_status(node: &Value) -> &str {
    if PROVIDERS.contains(&node["provider"].as_str().unwrap_or("")) {
        node["status"].as_str().unwrap_or("unknown")
    } else {
        // A shell or custom node is not an agent awaiting input or completing.
        "none"
    }
}

impl Pane {
    fn apply(&mut self, previous: &str, next: &str) {
        match next {
            "idle" if matches!(previous, "busy" | "waiting") => { self.completed = true; self.waiting = false; }
            "busy" => { self.completed = false; self.waiting = false; }
            "waiting" if previous != "waiting" => { self.waiting = true; self.completed = false; }
            _ => {}
        }
    }

    fn observe(&mut self, node: &Value, first: bool) {
        let entries = history(node);
        let status = agent_status(node).to_owned();
        if first {
            // Outcomes before this client first saw the pane are not unseen
            // here. A current wait is still evidence that input is needed now.
            self.waiting = status == "waiting";
        } else {
            let mut at_cursor = 0;
            for (index, (at, entry)) in entries.iter().enumerate() {
                let new = match self.cursor {
                    None => true,
                    Some((cursor, applied)) if *at == cursor => { at_cursor += 1; at_cursor > applied }
                    Some((cursor, _)) => *at > cursor,
                };
                if new {
                    // The first retained entry follows the last status this pane saw.
                    let before = if index == 0 { self.status.clone() } else { entries[index - 1].1.to_owned() };
                    self.apply(&before, entry);
                }
            }
            // Live transition: covers absent history and a server clock that
            // moved backwards. Repeating an already applied change is harmless.
            let before = self.status.clone();
            self.apply(&before, &status);
        }
        // Current status is authoritative over remembered events.
        if status == "busy" { self.completed = false; }
        if status != "waiting" { self.waiting = false; }
        // Never move the cursor back: entries the server re-stamps earlier are
        // covered by the live transition instead of being replayed.
        if let Some(latest) = entries.iter().map(|(at, _)| *at).max()
            && self.cursor.is_none_or(|(cursor, _)| latest >= cursor)
        {
            self.cursor = Some((latest, entries.iter().filter(|(at, _)| *at == latest).count()));
        }
        self.status = status;
    }
}

impl AgentAttention {
    /// Apply one graph view. `nodes` maps pane keys to public graph nodes;
    /// `visible` panes are currently in front of the user; `live` lists every
    /// pane that still exists in any window.
    ///
    /// Returns whether a marker changed.
    pub fn observe(&mut self, nodes: &Value, visible: &HashSet<String>, live: &HashSet<String>) -> bool {
        let before = self.snapshot();
        self.panes.retain(|key, _| live.contains(key));
        for key in live {
            // A node briefly absent during a reconnect keeps what it knew.
            let Some(node) = nodes.get(key).filter(|node| node.is_object()) else {
                if visible.contains(key) {
                    if let Some(pane) = self.panes.get_mut(key) { pane.completed = false; pane.waiting = false; }
                }
                continue;
            };
            let first = !self.panes.contains_key(key);
            let pane = self.panes.entry(key.clone()).or_default();
            pane.observe(node, first);
            if visible.contains(key) {
                pane.completed = false;
                pane.waiting = false;
            }
        }
        self.snapshot() != before
    }

    fn snapshot(&self) -> Vec<(String, bool, bool)> {
        let mut state: Vec<_> = self.panes.iter()
            .filter(|(_, pane)| pane.completed || pane.waiting)
            .map(|(key, pane)| (key.clone(), pane.completed, pane.waiting)).collect();
        state.sort();
        state
    }

    pub fn pane(&self, key: &str) -> Option<Marker> {
        let pane = self.panes.get(key)?;
        if pane.waiting { Some(Marker::Waiting) } else if pane.completed { Some(Marker::Completed) } else { None }
    }

    /// A tab shows one marker: waiting wins over completed, and the count is
    /// how many of its panes are in that state.
    pub fn marker<'a>(&self, keys: impl IntoIterator<Item = &'a str>) -> Value {
        let (mut waiting, mut completed) = (0, 0);
        for key in keys {
            match self.pane(key) {
                Some(Marker::Waiting) => waiting += 1,
                Some(Marker::Completed) => completed += 1,
                None => {}
            }
        }
        if waiting > 0 { json!({"state":"waiting","count":waiting}) }
        else if completed > 0 { json!({"state":"completed","count":completed}) }
        else { json!({"state":"","count":0}) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(keys: &[&str]) -> HashSet<String> { keys.iter().map(|k| k.to_string()).collect() }
    fn node(status: &str, history: &[(&str, &str)]) -> Value {
        json!({"provider":"claude","status":status,"status_history":history.iter()
            .map(|(at, status)| json!({"at":format!("2030-01-01T00:00:{at}.000+00:00"),"status":status})).collect::<Vec<_>>()})
    }
    fn view(panes: &[(&str, Value)]) -> Value {
        Value::Object(panes.iter().map(|(k, v)| (k.to_string(), v.clone())).collect())
    }

    #[test]
    fn hidden_completion_marks_until_seen() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        a.observe(&view(&[("%1", node("busy", &[("00", "idle"), ("01", "busy")]))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), None);
        assert!(a.observe(&view(&[("%1", node("idle", &[("00", "idle"), ("01", "busy"), ("02", "idle")]))]), &set(&[]), &live));
        assert_eq!(a.marker(["%1"]), json!({"state":"completed","count":1}));
        // Repeated identical snapshots do not re-arm or clear it.
        assert!(!a.observe(&view(&[("%1", node("idle", &[("00", "idle"), ("01", "busy"), ("02", "idle")]))]), &set(&[]), &live));
        assert!(a.observe(&view(&[("%1", node("idle", &[("00", "idle"), ("01", "busy"), ("02", "idle")]))]), &live, &live));
        assert_eq!(a.pane("%1"), None);
        // Seen history is never replayed after the user looks away.
        a.observe(&view(&[("%1", node("idle", &[("00", "idle"), ("01", "busy"), ("02", "idle")]))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), None);
    }

    #[test]
    fn completion_while_visible_never_marks() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        a.observe(&view(&[("%1", node("busy", &[("01", "busy")]))]), &live, &live);
        a.observe(&view(&[("%1", node("idle", &[("01", "busy"), ("02", "idle")]))]), &live, &live);
        assert_eq!(a.pane("%1"), None);
    }

    #[test]
    fn missed_snapshots_are_repaired_from_history() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        a.observe(&view(&[("%1", node("idle", &[("00", "idle")]))]), &set(&[]), &live);
        // The frontend never saw busy: idle -> idle, but history proves a turn ran.
        a.observe(&view(&[("%1", node("idle", &[("00", "idle"), ("01", "busy"), ("02", "idle")]))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), Some(Marker::Completed));
    }

    #[test]
    fn entries_sharing_a_millisecond_are_each_applied_once() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        a.observe(&view(&[("%1", node("busy", &[("01", "busy")]))]), &set(&[]), &live);
        a.observe(&view(&[("%1", node("idle", &[("01", "busy"), ("01", "idle")]))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), Some(Marker::Completed));
    }

    #[test]
    fn without_history_live_transitions_are_evidence() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        a.observe(&view(&[("%1", json!({"provider":"codex","status":"busy"}))]), &set(&[]), &live);
        a.observe(&view(&[("%1", json!({"provider":"codex","status":"idle"}))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), Some(Marker::Completed));
    }

    #[test]
    fn server_clock_moving_back_still_counts_live_change() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        a.observe(&view(&[("%1", node("busy", &[("09", "busy")]))]), &set(&[]), &live);
        a.observe(&view(&[("%1", node("idle", &[("09", "busy"), ("03", "idle")]))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), Some(Marker::Completed));
    }

    #[test]
    fn old_history_and_startup_idle_are_not_unseen() {
        let mut a = AgentAttention::default();
        let live = set(&["%1", "%2"]);
        a.observe(&view(&[("%1", node("idle", &[("00", "busy"), ("01", "idle")])),
            ("%2", node("waiting", &[("00", "busy"), ("01", "waiting")]))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), None);
        assert_eq!(a.pane("%2"), Some(Marker::Waiting), "a current wait still needs input");
        let ready = json!({"provider":"opencode","status":"idle","status_history":[]});
        let mut b = AgentAttention::default();
        b.observe(&view(&[("%1", json!({"provider":"opencode","status":"unknown"}))]), &set(&[]), &set(&["%1"]));
        b.observe(&view(&[("%1", ready)]), &set(&[]), &set(&["%1"]));
        assert_eq!(b.pane("%1"), None, "starting up idle is not a completed turn");
    }

    #[test]
    fn waiting_wins_and_counts_require_seeing_every_pane() {
        let mut a = AgentAttention::default();
        let live = set(&["%1", "%2", "%3"]);
        let busy = node("busy", &[("01", "busy")]);
        a.observe(&view(&[("%1", busy.clone()), ("%2", busy.clone()), ("%3", busy)]), &set(&[]), &live);
        let done = node("idle", &[("01", "busy"), ("02", "idle")]);
        let ask = node("waiting", &[("01", "busy"), ("02", "waiting")]);
        let nodes = view(&[("%1", done.clone()), ("%2", done), ("%3", ask)]);
        a.observe(&nodes, &set(&[]), &live);
        let tab = ["%1", "%2", "%3"];
        assert_eq!(a.marker(tab), json!({"state":"waiting","count":1}));
        a.observe(&nodes, &set(&["%3"]), &live);
        assert_eq!(a.marker(tab), json!({"state":"completed","count":2}));
        a.observe(&nodes, &set(&["%1"]), &live);
        assert_eq!(a.marker(tab), json!({"state":"completed","count":1}));
        a.observe(&nodes, &set(&["%2"]), &live);
        assert_eq!(a.marker(tab), json!({"state":"","count":0}));
    }

    #[test]
    fn current_status_clears_stale_events() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        let hidden = set(&[]);
        a.observe(&view(&[("%1", node("busy", &[("01", "busy")]))]), &hidden, &live);
        a.observe(&view(&[("%1", node("idle", &[("01", "busy"), ("02", "idle")]))]), &hidden, &live);
        // Running again supersedes the unseen result; finishing re-arms it.
        a.observe(&view(&[("%1", node("busy", &[("01", "busy"), ("02", "idle"), ("03", "busy")]))]), &hidden, &live);
        assert_eq!(a.pane("%1"), None);
        a.observe(&view(&[("%1", node("waiting", &[("03", "busy"), ("04", "waiting")]))]), &hidden, &live);
        assert_eq!(a.pane("%1"), Some(Marker::Waiting));
        // The agent exited while asking (scan reports offline): nothing to answer.
        a.observe(&view(&[("%1", node("offline", &[("04", "waiting"), ("05", "offline")]))]), &hidden, &live);
        assert_eq!(a.pane("%1"), None);
        // Answered elsewhere and resumed: no stuck yellow.
        a.observe(&view(&[("%1", node("waiting", &[("06", "waiting")]))]), &hidden, &live);
        a.observe(&view(&[("%1", node("busy", &[("06", "waiting"), ("07", "busy")]))]), &hidden, &live);
        assert_eq!(a.pane("%1"), None);
        // An agent replaced by a shell is not awaiting input.
        a.observe(&view(&[("%1", node("waiting", &[("08", "waiting")]))]), &hidden, &live);
        a.observe(&view(&[("%1", json!({"provider":"shell","status":"waiting"}))]), &hidden, &live);
        assert_eq!(a.pane("%1"), None);
    }

    #[test]
    fn completion_survives_exit_and_reconnect_but_not_closing_the_pane() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        a.observe(&view(&[("%1", node("busy", &[("01", "busy")]))]), &set(&[]), &live);
        a.observe(&view(&[("%1", node("offline", &[("01", "busy"), ("02", "idle"), ("03", "offline")]))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), Some(Marker::Completed), "the result is still unseen after the agent exits");
        a.observe(&view(&[]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), Some(Marker::Completed), "a reconnect gap is not evidence");
        assert!(a.observe(&view(&[]), &set(&[]), &set(&[])));
        assert_eq!(a.pane("%1"), None);
    }

    #[test]
    fn malformed_history_is_ignored() {
        let mut a = AgentAttention::default();
        let live = set(&["%1"]);
        let bad = |status: &str| json!({"provider":"claude","status":status,"status_history":[{"at":"yesterday","status":"busy"},{"status":"idle"},7]});
        a.observe(&view(&[("%1", bad("idle"))]), &set(&[]), &live);
        a.observe(&view(&[("%1", bad("idle"))]), &set(&[]), &live);
        assert_eq!(a.pane("%1"), None);
    }
}
