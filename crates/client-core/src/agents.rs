//! Agent list and attention sounds, adapted from herdr-app's model.rs and
//! defaults/mods/agents/main.js at e77f112 (Apache-2.0).
//! Changes: Graffitty status/provider adapter, no spaces, client-local pins,
//! stable server/epoch/terminal identities and a frontend-neutral snapshot.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};

#[derive(Clone, Debug, Deserialize)]
pub struct Input {
    pub id: String,
    pub key: String,
    pub title: String,
    pub provider: String,
    pub status: String,
    /// Optional OSC 7501 root report. Presentation only; never grants a graph identity.
    pub program: Option<graffitty_terminal_core::program_status::Status>,
    pub looking: bool,
    pub focused: bool,
}
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Stamp { pub state: String, pub at: u64 }
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Saved {
    pub version: u32,
    pub pins: HashSet<String>,
    pub changed: BTreeMap<String, Stamp>,
}
impl Default for Saved {
    fn default() -> Self { Self { version: 1, pins: HashSet::new(), changed: BTreeMap::new() } }
}
#[derive(Clone, Debug, Serialize)]
pub struct Row {
    pub id: String, pub key: String, pub title: String, pub provider: String,
    pub status: String, pub section: String, pub at: u64,
    pub focused: bool, pub pinned: bool,
}
#[derive(Default)]
struct Agent { word: String, seen: bool, seq: u64 }
#[derive(Default)]
pub struct Agents {
    saved: Saved,
    agents: HashMap<String, Agent>,
    held: Option<(String, u8)>,
    seq: u64,
}
fn word(s: &str) -> &str {
    match s { "busy" => "working", "waiting" | "error" => "blocked", _ => "idle" }
}
fn rank(s: &str) -> u8 {
    match s { "blocked" => 4, "done" => 3, "working" => 2, _ => 1 }
}
fn section(r: u8) -> &'static str {
    match r { 4 => "Needs you", 3 => "Done", 2 => "Working", _ => "Idle" }
}
fn app_name(provider: &str) -> &str {
    match provider { "pi" => "Pi", "claude" => "Claude Code", "codex" => "Codex", "opencode" => "OpenCode", other => other }
}
/// Herdr: blocked always alerts; finishing only while not looking.
pub fn alert(previous: Option<&str>, next: &str, looking: bool) -> Option<&'static str> {
    let busy = |s| matches!(s, "working" | "blocked");
    if next == "blocked" && previous != Some("blocked") { Some("blocked") }
    else if previous.is_some_and(busy) && !busy(next) && !looking { Some("done") }
    else { None }
}
impl Agents {
    pub fn restore(&mut self, json: &str) -> Result<(), String> {
        let saved: Saved = serde_json::from_str(json).map_err(|e| e.to_string())?;
        if saved.version != 1 { return Err("unsupported agents state version".into()); }
        self.saved = saved;
        Ok(())
    }
    pub fn save(&self) -> String { serde_json::to_string(&self.saved).unwrap() }
    pub fn pin(&mut self, id: String, pinned: bool) {
        if pinned { self.saved.pins.insert(id); } else { self.saved.pins.remove(&id); }
    }
    /// Missing agents (including reconnect gaps) keep their seen state. Only
    /// current live pane-backed providers are returned or allowed to alert.
    pub fn observe(&mut self, input: Vec<Input>, now: u64) -> (Vec<Row>, Vec<String>) {
        let mut rows = Vec::new();
        let mut alerts = Vec::new();
        for mut item in input {
            let supported = |app: &str| ["pi", "claude", "codex", "opencode"].contains(&app);
            // A shell/SSH/tmux pane can report an agent through OSC without
            // registering provider hooks. Use its explicit app for this list,
            // without changing the server's graph provider or permissions.
            if !supported(&item.provider) {
                let Some(program) = item.program.as_ref().filter(|p| supported(&p.app)) else { continue; };
                item.provider = program.app.clone();
                item.status = match program.state.as_str() {
                    "working" => "busy", "blocked" | "error" => "waiting",
                    "idle" | "done" => "idle", _ => continue,
                }.into();
                if !program.title.is_empty() { item.title = program.title.clone(); }
            }
            if !["busy", "waiting", "idle", "error"].contains(&item.status.as_str()) { continue; }
            // Herdr: a row is never blank; without a title it reads as its program.
            if item.title.trim().is_empty() { item.title = app_name(&item.provider).into(); }
            let next = word(&item.status);
            let old = self.agents.get(&item.id);
            if old.is_none_or(|a| a.word != next) {
                if let Some(sound) = alert(old.map(|a| a.word.as_str()), next, item.looking) {
                    alerts.push(sound.to_owned());
                }
                let was_busy = old.is_some_and(|a| matches!(a.word.as_str(), "working" | "blocked"));
                let seen = if matches!(next, "working" | "blocked") { true }
                    else if was_busy { item.looking } else { old.is_none_or(|a| a.seen) };
                self.seq += 1;
                self.agents.insert(item.id.clone(), Agent { word: next.into(), seen, seq: self.seq });
            }
            let a = self.agents.get_mut(&item.id).unwrap();
            let before_seen = if next == "idle" && !a.seen { "done" } else { next };
            // Preserve Done's group while focused, even after marking it seen.
            if item.focused && (self.held.as_ref().is_none_or(|h| h.0 != item.id) || before_seen != "idle") {
                self.held = Some((item.id.clone(), rank(before_seen)));
            }
            if item.looking { a.seen = true; }
            let status = if next == "idle" && !a.seen { "done" } else { next };
            let shown_rank = if status == "idle" && item.focused && self.held.as_ref().is_some_and(|h| h.0 == item.id && h.1 == 3) { 3 } else { rank(status) };
            // Looking isn't work: Done and Idle share one duration.
            let stamp = self.saved.changed.entry(item.id.clone()).or_default();
            if stamp.state != next { *stamp = Stamp { state: next.into(), at: now }; }
            let pinned = self.saved.pins.contains(&item.id);
            rows.push(Row { id: item.id, key: item.key, title: item.title, provider: item.provider,
                status: status.into(), section: if pinned { "Pinned" } else { section(shown_rank) }.into(),
                at: stamp.at, focused: item.focused, pinned });
        }
        if !rows.iter().any(|r| r.focused) { self.held = None; }
        let group_rank = |r: &Row| match r.section.as_str() { "Pinned" => 5, "Needs you" => 4, "Done" => 3, "Working" => 2, _ => 1 };
        rows.sort_by(|a,b| group_rank(b).cmp(&group_rank(a))
            .then_with(|| if a.pinned && b.pinned { rank(&b.status).cmp(&rank(&a.status)) } else { std::cmp::Ordering::Equal })
            .then(b.at.cmp(&a.at))
            .then(self.agents[&b.id].seq.cmp(&self.agents[&a.id].seq)));
        let listed: HashSet<_> = rows.iter().map(|r| r.id.clone()).collect();
        self.saved.changed.retain(|id, stamp| listed.contains(id) || now.saturating_sub(stamp.at) <= 30 * 86400);
        (rows, alerts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn input(status: &str, looking: bool, focused: bool) -> Vec<Input> {
        vec![Input { id: "server/epoch/1".into(), key: "%1".into(), title: "task".into(), provider: "pi".into(), status: status.into(), program: None, looking, focused }]
    }
    #[test] fn attention_rules() {
        assert_eq!(alert(Some("working"), "blocked", true), Some("blocked"));
        assert_eq!(alert(Some("blocked"), "blocked", false), None);
        assert_eq!(alert(Some("working"), "idle", false), Some("done"));
        assert_eq!(alert(Some("working"), "idle", true), None);
        assert_eq!(alert(None, "idle", false), None);
    }
    #[test] fn done_holds_until_leaving_without_resetting_duration() {
        let mut a = Agents::default();
        a.observe(input("busy", false, false), 1);
        let (rows, alerts) = a.observe(input("idle", false, false), 2);
        assert_eq!(rows[0].section, "Done"); assert_eq!(alerts, ["done"]);
        let (rows, alerts) = a.observe(input("idle", true, true), 3);
        assert!(alerts.is_empty()); assert_eq!(rows[0].section, "Done"); assert_eq!(rows[0].status, "idle"); assert_eq!(rows[0].at, 2);
        let (rows, _) = a.observe(input("idle", false, false), 4);
        assert_eq!(rows[0].section, "Idle");
    }
    #[test] fn osc_only_agent_is_listed_and_alerts_without_inventing_graph_identity() {
        let mut model = Agents::default();
        let mut snapshot = input("busy", false, false);
        snapshot[0].provider = "shell".into();
        snapshot[0].program = Some(serde_json::from_value(serde_json::json!({
            "state":"working", "app":"pi", "title":"OSC task"
        })).unwrap());
        let (rows, sounds) = model.observe(snapshot.clone(), 10);
        assert_eq!(rows[0].provider, "pi");
        assert_eq!(rows[0].title, "OSC task");
        assert_eq!(rows[0].status, "working");
        assert!(sounds.is_empty());
        snapshot[0].program.as_mut().unwrap().state = "blocked".into();
        let (rows, sounds) = model.observe(snapshot.clone(), 11);
        assert_eq!(rows[0].section, "Needs you");
        assert_eq!(sounds, ["blocked"]);
        assert_eq!(snapshot[0].provider, "shell");
        snapshot[0].program = None;
        assert!(model.observe(snapshot, 12).0.is_empty());
    }

    #[test] fn sorting_pins_recent_changes_and_provider_filtering() {
        let mut a = Agents::default();
        let mut idle = input("idle", false, false).remove(0);
        idle.id = "idle".into();
        let mut working = input("busy", false, false).remove(0);
        working.id = "working".into();
        let mut waiting = input("waiting", false, false).remove(0);
        waiting.id = "waiting".into();
        let mut shell = input("waiting", false, false).remove(0);
        shell.provider = "shell".into();
        a.pin(idle.id.clone(), true);
        let (rows, sounds) = a.observe(vec![working, idle, waiting, shell], 20);
        assert_eq!(rows.iter().map(|r| r.section.as_str()).collect::<Vec<_>>(), ["Pinned", "Needs you", "Working"]);
        assert_eq!(sounds, ["blocked"]);
    }
    #[test] fn reconnect_does_not_repeat_wait_and_visible_completion_is_idle() {
        let mut a = Agents::default();
        assert_eq!(a.observe(input("waiting", true, true), 1).1, ["blocked"]);
        a.observe(Vec::new(), 2);
        assert!(a.observe(input("waiting", true, true), 3).1.is_empty());
        let (rows, sounds) = a.observe(input("idle", true, true), 4);
        assert_eq!(rows[0].section, "Idle"); assert!(sounds.is_empty());
    }
    #[test] fn pin_and_clock_survive_restart_and_schemas_are_strict() {
        let mut a = Agents::default(); a.observe(input("busy", false, false), 20);
        a.pin("server/epoch/1".into(), true);
        let mut b = Agents::default(); b.restore(&a.save()).unwrap();
        let (rows, _) = b.observe(input("busy", false, false), 99);
        assert_eq!(rows[0].section, "Pinned"); assert_eq!(rows[0].at, 20);
        assert!(b.restore(r#"{"version":0,"pins":[],"changed":{}}"#).is_err());
    }
    #[test] fn untitled_rows_read_as_their_program() {
        let mut a = Agents::default();
        let mut items = input("idle", false, false);
        items[0].title = " ".into();
        let (rows, _) = a.observe(items, 1);
        assert_eq!(rows[0].title, "Pi");
    }
}
