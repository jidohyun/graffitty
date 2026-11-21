//! Rows for the Resource Monitor panel: every pane a window shows, grouped
//! under its server and session, with the measured CPU, memory, process count
//! and root PID.
//!
//! Unknown or stale samples stay `None`: a missing value is never shown or
//! sorted as a measured zero. Sorting and column layout are the panel's own
//! view state.
use crate::agents_tree::{icon, Node};
use serde::{Deserialize, Serialize};

/// One pane as a window sees it, with its resource monitor's snapshot.
#[derive(Clone, Debug, Deserialize)]
pub struct Input {
    /// Stable across windows: two views of one server pane share it.
    pub id: String,
    /// The window (host) that shows it, for focusing.
    pub host: u64,
    /// `%N` in that window.
    pub key: String,
    /// agent, terminal, chromium or filetree.
    pub kind: String,
    #[serde(default)]
    pub provider: String,
    /// Foreground program identifier for terminals.
    #[serde(default)]
    pub app: String,
    #[serde(default)]
    pub title: String,
    /// The server's display name; "" for this computer.
    #[serde(default)]
    pub server: String,
    #[serde(default)]
    pub local: bool,
    /// The session's label.
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub focused: bool,
    /// The monitor's `snapshot()`, or null without a monitor.
    #[serde(default)]
    pub sample: Option<Sample>,
    /// Stable resource IDs connected by graph, spawn, filetree or browser links.
    #[serde(default)]
    pub connected: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct Sample {
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub cpu_valid: bool,
    #[serde(default)]
    pub cpu_percent: Option<f64>,
    #[serde(default)]
    pub memory_current: Option<f64>,
    /// Absent means valid; backends set it false when memory is unknown.
    #[serde(default)]
    pub memory_valid: Option<bool>,
    #[serde(default)]
    pub process_count: Option<f64>,
    #[serde(default)]
    pub root_pid: Option<f64>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Row {
    pub id: String,
    pub host: u64,
    pub key: String,
    /// A provider name, `terminal`, `python`, `chromium` or `filetree`.
    pub icon: String,
    pub title: String,
    pub focused: bool,
    /// `running`, `starting`, `paused`, `disabled`, `exited` or `unavailable`.
    pub status: String,
    /// Percent, as the monitor scales it; `None` until a measured interval.
    pub cpu: Option<f64>,
    /// Bytes.
    pub memory: Option<u64>,
    pub processes: Option<u32>,
    pub pid: Option<i64>,
    /// Nonempty only for an unnamed connection summary, never an agent parent.
    pub members: Vec<Row>,
}

#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Group {
    pub server: String,
    pub local: bool,
    pub session: String,
    pub rows: Vec<Row>,
}

fn row(input: &Input) -> Row {
    let node = Node {
        key: input.key.clone(),
        kind: input.kind.clone(),
        provider: input.provider.clone(),
        title: input.title.clone(),
        app: input.app.clone(),
        status: String::new(),
        rect: [0.0; 4],
    };
    let sample = input.sample.clone().unwrap_or_else(|| Sample { status: "unavailable".into(), ..Sample::default() });
    let live = sample.status == "running";
    let finite = |v: Option<f64>| v.filter(|v| v.is_finite() && *v >= 0.0);
    Row {
        id: input.id.clone(),
        members: Vec::new(),
        host: input.host,
        key: input.key.clone(),
        icon: icon(&node),
        title: input.title.clone(),
        focused: input.focused,
        status: if sample.status.is_empty() { "starting".into() } else { sample.status.clone() },
        cpu: if live && sample.cpu_valid { finite(sample.cpu_percent) } else { None },
        memory: if live && sample.memory_valid != Some(false) { finite(sample.memory_current).map(|v| v as u64) } else { None },
        processes: if live { finite(sample.process_count).map(|v| v as u32) } else { None },
        pid: sample.root_pid.filter(|p| p.is_finite() && *p > 0.0).map(|p| p as i64),
    }
}

/// Groups in first-seen order, rows in input order. A pane two windows show
/// is listed once, from the window where it is focused if any.
pub fn groups(inputs: &[Input]) -> Vec<Group> {
    let mut chosen: Vec<&Input> = Vec::new();
    for input in inputs {
        match chosen.iter().position(|c| c.id == input.id) {
            Some(i) if input.focused && !chosen[i].focused => chosen[i] = input,
            Some(_) => {}
            None => chosen.push(input),
        }
    }
    let mut result: Vec<Group> = Vec::new();
    for input in chosen {
        let found = result.iter().position(|g| g.server == input.server && g.local == input.local && g.session == input.session);
        let index = found.unwrap_or_else(|| {
            result.push(Group { server: input.server.clone(), local: input.local, session: input.session.clone(), rows: Vec::new() });
            result.len() - 1
        });
        result[index].rows.push(row(input));
    }
    // Keep server/session boundaries: CPU percentages on different machines
    // cannot be added. Links from every view participate, even a deduped view.
    for group in &mut result {
        let mut remaining = std::mem::take(&mut group.rows);
        while !remaining.is_empty() {
            let mut members = vec![remaining.remove(0)];
            loop {
                let found = remaining.iter().position(|candidate| members.iter().any(|member| {
                    inputs.iter().any(|input|
                        (input.id == member.id && input.connected.contains(&candidate.id))
                        || (input.id == candidate.id && input.connected.contains(&member.id)))
                }));
                let Some(index) = found else { break };
                members.push(remaining.remove(index));
            }
            if members.len() == 1 {
                group.rows.push(members.remove(0));
                continue;
            }
            let mut ids: Vec<_> = members.iter().map(|r| r.id.as_str()).collect();
            ids.sort_unstable();
            let id = format!("connection:{}", serde_json::to_string(&ids).unwrap());
            let cpu = members.iter().map(|r| r.cpu).sum::<Option<f64>>().filter(|v| v.is_finite());
            let memory = members.iter().try_fold(0u64, |sum, r| sum.checked_add(r.memory?));
            let processes = members.iter().try_fold(0u32, |sum, r| sum.checked_add(r.processes?));
            group.rows.push(Row { id, host: 0, key: String::new(), icon: String::new(),
                title: String::new(), focused: false, status: String::new(),
                cpu, memory, processes, pid: None, members });
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn input(value: serde_json::Value) -> Input {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn unknown_samples_are_never_zero() {
        let starting = input(json!({"id": "a", "host": 1, "key": "%1", "kind": "terminal",
            "sample": {"status": "starting", "cpu_valid": false, "cpu_percent": 0.0, "memory_current": 0.0, "process_count": 0, "root_pid": 42}}));
        let warming = input(json!({"id": "b", "host": 1, "key": "%2", "kind": "terminal",
            "sample": {"status": "running", "cpu_valid": false, "cpu_percent": 0.0, "memory_current": 1048576.0, "memory_valid": false, "process_count": 3, "root_pid": 43}}));
        let none = input(json!({"id": "c", "host": 1, "key": "%3", "kind": "chromium", "sample": null}));
        let rows = &groups(&[starting, warming, none])[0].rows;
        assert_eq!((rows[0].cpu, rows[0].memory, rows[0].processes, rows[0].pid), (None, None, None, Some(42)));
        assert_eq!((rows[1].cpu, rows[1].memory, rows[1].processes), (None, None, Some(3)));
        assert_eq!((rows[2].status.as_str(), rows[2].pid, rows[2].icon.as_str()), ("unavailable", None, "chromium"));
    }

    #[test]
    fn connections_have_neutral_summaries_and_unique_members() {
        let pane = |id: &str, kind: &str, connected: Vec<&str>| input(json!({
            "id": id, "host": 1, "key": format!("%{id}"), "kind": kind, "connected": connected,
            "sample": {"status": "running", "cpu_valid": true, "cpu_percent": 10,
                "memory_current": 100, "process_count": 2, "root_pid": 42}}));
        let mut inputs = vec![pane("1", "agent", vec!["2", "2"]), pane("2", "filetree", vec!["3"]),
            pane("3", "chromium", vec!["1"]), pane("4", "terminal", vec![])];
        // A duplicate view adds a link and must not add its resource usage twice.
        let mut duplicate = inputs[2].clone();
        duplicate.host = 2;
        duplicate.connected.push("4".into());
        inputs.push(duplicate);
        let result = groups(&inputs);
        let summary = &result[0].rows[0];
        assert_eq!(result[0].rows.len(), 1);
        assert_eq!(summary.members.len(), 4);
        assert_eq!((summary.cpu, summary.memory, summary.processes), (Some(40.0), Some(400), Some(8)));
        assert!(summary.title.is_empty() && summary.key.is_empty() && summary.icon.is_empty());
        assert_eq!(summary.pid, None);
        let stable_id = summary.id.clone();
        inputs.reverse();
        assert_eq!(groups(&inputs)[0].rows[0].id, stable_id);
        inputs.iter_mut().find(|i| i.id == "1").unwrap().sample = None;
        let result = groups(&inputs);
        let summary = &result[0].rows[0];
        assert_eq!((summary.cpu, summary.memory, summary.processes), (None, None, None));
        // Connections across sessions must not combine unlike CPU totals.
        inputs.iter_mut().find(|i| i.id == "4").unwrap().session = "other".into();
        let result = groups(&inputs);
        assert_eq!(result.len(), 2);
        assert!(result.iter().find(|g| g.session == "other").unwrap().rows[0].members.is_empty());
    }

    #[test]
    fn measured_samples_and_icons() {
        let rows = groups(&[
            input(json!({"id": "a", "host": 1, "key": "%1", "kind": "agent", "provider": "claude", "title": "fix",
                "sample": {"status": "running", "cpu_valid": true, "cpu_percent": 12.5, "memory_current": 2097152.0, "process_count": 4, "root_pid": 7}})),
            input(json!({"id": "b", "host": 1, "key": "%2", "kind": "terminal", "app": "/usr/bin/python3.12"})),
        ]);
        let a = &rows[0].rows[0];
        assert_eq!((a.icon.as_str(), a.cpu, a.memory, a.processes, a.pid), ("claude", Some(12.5), Some(2097152), Some(4), Some(7)));
        assert_eq!(rows[0].rows[1].icon, "python");
    }

    #[test]
    fn groups_by_server_and_session_and_dedupes_views() {
        let pane = |id: &str, server: &str, session: &str, focused: bool, host: u64| input(json!({
            "id": id, "host": host, "key": "%1", "kind": "terminal", "server": server, "local": server.is_empty(),
            "session": session, "focused": focused}));
        let result = groups(&[
            pane("x", "", "main", false, 1),
            pane("y", "box", "main", false, 1),
            pane("z", "", "main", false, 1),
            pane("x", "", "main", true, 2),
        ]);
        assert_eq!(result.iter().map(|g| (g.server.as_str(), g.session.as_str(), g.rows.len())).collect::<Vec<_>>(),
            [("", "main", 2), ("box", "main", 1)]);
        assert_eq!((result[0].rows[0].host, result[0].rows[0].focused), (2, true));
    }
}
