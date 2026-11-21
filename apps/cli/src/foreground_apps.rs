//! Cheap pane context, separate from transcript/daemon discovery and agent status.
use crate::sessions::Process;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

pub(crate) fn scan(roots: &Value) -> Value {
    let table = crate::sessions::processes();
    // A failed inventory is not an app exit. Preserve the last observation.
    if table.is_empty() {
        return json!({"error": {"message": "Cannot read process inventory"}});
    }
    let mut result = serde_json::Map::new();
    for root in roots.as_array().into_iter().flatten() {
        let (Some(node), Some(pid)) = (root["node"].as_str(), root["pid"].as_i64()) else {
            continue;
        };
        if !table.contains_key(&pid) {
            continue;
        }
        let app = identify(pid, &table, &root["agent"], cfg!(unix)).unwrap_or(json!({}));
        result.insert(node.into(), app);
    }
    Value::Object(result)
}

fn name(executable: &str) -> String {
    executable
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("")
        .to_lowercase()
        .trim_start_matches('-')
        .trim_end_matches(".exe")
        .into()
}

fn wrapper(app: &str) -> bool {
    matches!(
        app,
        "sh" | "bash"
            | "zsh"
            | "fish"
            | "dash"
            | "nu"
            | "cmd"
            | "powershell"
            | "pwsh"
            | "node"
            | "bun"
            | "npm"
            | "npx"
            | "env"
    )
}

fn descendants(pid: i64, table: &HashMap<i64, Process>, unix: bool) -> HashSet<i64> {
    let mut found = HashSet::from([pid]);
    loop {
        let before = found.len();
        for process in table.values() {
            // Toolhelp parent PIDs can outlive a parent and be recycled. Windows
            // creation times are numeric FILETIMEs, unlike Unix's ps timestamps.
            let current_parent = unix
                || table.get(&process.parent).is_some_and(|parent| {
                    parent
                        .started
                        .parse::<u64>()
                        .ok()
                        .zip(process.started.parse::<u64>().ok())
                        .is_some_and(|(parent, child)| parent <= child)
                });
            if found.contains(&process.parent) && current_parent {
                found.insert(process.pid);
            }
        }
        if found.len() == before {
            return found;
        }
    }
}

fn ancestor(pid: i64, child: i64, table: &HashMap<i64, Process>) -> bool {
    let mut cursor = child;
    let mut seen = HashSet::new();
    while seen.insert(cursor) {
        let Some(process) = table.get(&cursor) else {
            return false;
        };
        cursor = process.parent;
        if cursor == pid {
            return true;
        }
    }
    false
}

fn identify(pid: i64, table: &HashMap<i64, Process>, agent: &Value, unix: bool) -> Option<Value> {
    let shell = table.get(&pid)?;
    if unix && (shell.foreground <= 0 || ["?", "??", "-"].contains(&shell.tty.as_str())) {
        return None;
    }
    let descendants = descendants(pid, table, unix);
    let candidates: Vec<_> = table
        .values()
        .filter(|p| {
            descendants.contains(&p.pid)
                && !p.state.contains(['Z', 'T'])
                && (!unix || (p.group == shell.foreground && p.tty == shell.tty))
        })
        .collect();
    let roots: Vec<_> = candidates
        .iter()
        .copied()
        .filter(|p| {
            !candidates
                .iter()
                .any(|other| other.pid != p.pid && ancestor(other.pid, p.pid, table))
        })
        .collect();
    // Pipelines/multiple unrelated branches have no single foreground app.
    if roots.len() != 1 {
        return None;
    }
    let mut current = roots[0];
    loop {
        let mut app = name(&current.executable);
        // Native integrations identify runtime wrappers (e.g. Pi in node).
        // Their registered PID must still belong to this pane's foreground job.
        let provider = agent["provider"].as_str().unwrap_or("");
        if agent["pid"].as_i64() == Some(current.pid)
            && ["claude", "codex", "pi", "opencode"].contains(&provider)
            && (app == provider || matches!(app.as_str(), "node" | "bun"))
            && agent["started"]
                .as_str()
                .map_or(agent["integrated"] == true, |s| s == current.started)
        {
            app = provider.into();
        }
        if !wrapper(&app) {
            return Some(json!({"id": app, "pid": current.pid, "started": current.started}));
        }
        let children: Vec<_> = candidates
            .iter()
            .copied()
            .filter(|p| p.parent == current.pid)
            .collect();
        match children.as_slice() {
            [child] => current = child,
            [] => return Some(json!({"id": app, "pid": current.pid, "started": current.started})),
            _ => return None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn process(pid: i64, parent: i64, group: i64, executable: &str) -> Process {
        Process {
            pid,
            parent,
            group,
            foreground: 20,
            tty: "tty1".into(),
            state: "S".into(),
            started: pid.to_string(),
            executable: executable.into(),
        }
    }
    fn table() -> HashMap<i64, Process> {
        HashMap::from([
            (10, process(10, 0, 10, "/bin/zsh")),
            (20, process(20, 10, 20, "/bin/nvim")),
        ])
    }
    #[test]
    fn observes_entry_suspend_resume_and_exit() {
        let mut table = table();
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "nvim"
        );
        table.get_mut(&10).unwrap().foreground = 10;
        table.get_mut(&20).unwrap().state = "T".into();
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "zsh"
        );
        table.get_mut(&10).unwrap().foreground = 20;
        table.get_mut(&20).unwrap().state = "S".into();
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "nvim"
        );
        table.remove(&20);
        table.get_mut(&10).unwrap().foreground = 10;
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "zsh"
        );
    }
    #[test]
    fn integrations_name_wrappers_but_do_not_override_foreground_ownership() {
        let mut table = table();
        table.get_mut(&20).unwrap().executable = "/bin/node".into();
        let hint = json!({"pid":20,"provider":"pi","integrated":true});
        assert_eq!(identify(10, &table, &hint, true).unwrap()["id"], "pi");
        let mut expired = hint.clone();
        expired["status"] = json!("offline");
        assert_eq!(
            identify(10, &table, &expired, true).unwrap()["id"],
            "pi",
            "Agent heartbeat/turn status does not change a live foreground process identity"
        );
        table.get_mut(&10).unwrap().foreground = 10;
        assert_eq!(identify(10, &table, &hint, true).unwrap()["id"], "zsh");
        table.get_mut(&10).unwrap().foreground = 20;
        let stale = json!({"pid":20,"provider":"pi","started":"old"});
        assert_eq!(identify(10, &table, &stale, true).unwrap()["id"], "node");
    }
    #[test]
    fn tool_children_do_not_replace_the_frontend_but_a_new_foreground_job_does() {
        let mut table = table();
        table.get_mut(&20).unwrap().executable = "/bin/codex".into();
        table.insert(21, process(21, 20, 20, "/bin/rg"));
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "codex"
        );
        table.insert(22, process(22, 20, 22, "/bin/nvim"));
        table.get_mut(&10).unwrap().foreground = 22;
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "nvim"
        );
    }
    #[test]
    fn skips_launchers_and_rejects_other_ttys_ambiguous_jobs_and_cycles() {
        let mut table = table();
        table.get_mut(&20).unwrap().executable = "/bin/node".into();
        table.insert(21, process(21, 20, 20, "/bin/codex"));
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "codex"
        );
        table.get_mut(&21).unwrap().tty = "other".into();
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "node"
        );
        table.insert(22, process(22, 10, 20, "/bin/nvim"));
        assert!(identify(10, &table, &Value::Null, true).is_none());
        table.get_mut(&20).unwrap().parent = 21;
        table.get_mut(&21).unwrap().tty = "tty1".into();
        assert_eq!(
            identify(10, &table, &Value::Null, true).unwrap()["id"],
            "nvim"
        );
    }
    #[test]
    fn windows_uses_only_an_unambiguous_process_chain() {
        let mut table = table();
        table.get_mut(&10).unwrap().executable = r"C:\Windows\pwsh.exe".into();
        table.get_mut(&20).unwrap().executable = r"C:\Tools\nvim.exe".into();
        assert_eq!(
            identify(10, &table, &Value::Null, false).unwrap()["id"],
            "nvim"
        );
        table.insert(30, process(30, 10, 30, "codex.exe"));
        assert!(identify(10, &table, &Value::Null, false).is_none());
        table.get_mut(&30).unwrap().started = "1".into();
        assert_eq!(
            identify(10, &table, &Value::Null, false).unwrap()["id"],
            "nvim",
            "An old child's recycled parent PID cannot claim this pane"
        );
    }
}
