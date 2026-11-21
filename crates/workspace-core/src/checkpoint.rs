//! Shared version-1 checkpoint document validation, independent of any frontend.
use serde_json::Value;
use std::collections::HashSet;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
fn canonical_id(v: &Value) -> Option<String> {
    let s = v.as_str()?;
    let id = uuid::Uuid::parse_str(s).ok()?.hyphenated().to_string();
    (id == s).then_some(id)
}
/// Claude and Codex conversations, found by process discovery, have UUIDs.
/// Integrations that speak the graph protocol declare their own relaunch.
pub fn agent_id(value: &Value) -> Option<String> {
    canonical_id(value)
}
/// The variables that choose where a discovered agent keeps its account and
/// conversations. A checkpoint records the ones the agent process had and
/// resumes with exactly those, removing the rest.
pub fn agent_locations(kind: &str) -> &'static [&'static str] {
    match kind {
        "claude" => &["CLAUDE_CONFIG_DIR"],
        "codex" => &["CODEX_HOME", "CODEX_SQLITE_HOME"],
        _ => &[],
    }
}
/// Largest JSON state a node may ask a checkpoint to keep for its relaunch.
pub const NODE_STATE_BYTES: usize = 64 * 1024;
/// How a checkpoint relaunches an opted-in node: its command line, and
/// optionally its directory and environment, where null removes a variable.
///
/// These never hold secret values: a node saves a reference, such as a
/// credential name in secrets.toml, and resolves it again.
pub fn node_restore(value: &Value) -> std::result::Result<(), String> {
    let restore = value.as_object().ok_or("restore must be an object")?;
    if let Some(field) = restore.keys().find(|key| !["command", "cwd", "env"].contains(&key.as_str())) {
        return Err(format!("Unknown restore field: {field}"));
    }
    fn text(v: &Value) -> Option<&str> {
        v.as_str().filter(|s| s.len() <= 4096 && !s.contains('\0'))
    }
    let command = restore.get("command").and_then(Value::as_array)
        .filter(|command| !command.is_empty() && command.len() <= 64)
        .ok_or("restore.command must list 1–64 arguments")?;
    if !command.iter().all(|arg| text(arg).is_some()) || text(&command[0]).is_none_or(str::is_empty) {
        return Err("restore.command arguments must be strings of at most 4096 bytes, starting with a program".into());
    }
    if let Some(cwd) = restore.get("cwd").filter(|v| !v.is_null()) {
        if !text(cwd).is_some_and(|cwd| std::path::Path::new(cwd).is_absolute()) {
            return Err("restore.cwd must be an absolute directory".into());
        }
    }
    if let Some(env) = restore.get("env").filter(|v| !v.is_null()) {
        let env = env.as_object().filter(|env| env.len() <= 32).ok_or("restore.env must map at most 32 variables")?;
        for (name, value) in env {
            if !restored_variable(name) {
                return Err(format!("restore.env cannot set {name}"));
            }
            if !value.is_null() && text(value).is_none() {
                return Err("restore.env values must be null or strings of at most 4096 bytes".into());
            }
        }
    }
    Ok(())
}
/// Loader variables could inject code, and restore supplies the pane's own
/// Graffitty capability and state file; a node's settings file may be kept.
fn restored_variable(name: &str) -> bool {
    let bytes = name.as_bytes();
    !bytes.is_empty() && bytes.len() <= 64
        && (bytes[0].is_ascii_alphabetic() || bytes[0] == b'_')
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_')
        && !name.starts_with("LD_") && !name.starts_with("DYLD_")
        && (!name.starts_with("GRAFFITTY_") || matches!(name, "GRAFFITTY_NODE_CONFIG" | "GRAFFITTY_SECRETS_CONFIG"))
}
/// The latest state a node reported for its relaunch: any JSON, kept small.
pub fn node_state(value: &Value) -> std::result::Result<(), String> {
    if serde_json::to_vec(value).map_err(|e| e.to_string())?.len() > NODE_STATE_BYTES {
        return Err(format!("Checkpoint state exceeds {} KiB", NODE_STATE_BYTES / 1024));
    }
    Ok(())
}
/// Pages a chromium reopens: what `chromium.create` and `tab-new` accept.
pub fn chromium_page(url: &str) -> bool {
    url == "about:blank" || ((url.starts_with("http://") || url.starts_with("https://")) && url.len() <= 8192)
}
fn numbers(value: &Value, count: usize) -> bool {
    value.as_array().is_some_and(|a| {
        a.len() == count
            && a.iter()
                .all(|v| v.as_f64().is_some_and(|n| n.is_finite() && n.abs() < 1e7))
    })
}
fn layout_types(value: &Value, depth: usize) -> bool {
    if depth > 64 {
        return false;
    }
    match value {
        Value::Object(map) => map.iter().all(|(key, v)| match key.as_str() {
            "rect2" => {
                numbers(v, 4) && v[2].as_f64().unwrap() > 0.0 && v[3].as_f64().unwrap() > 0.0
            }
            "pane" | "axis" | "split" => v.is_string(),
            "shown" | "stashed" | "tiling" => v.is_boolean(),
            "windows" | "children" => v.is_array() && layout_types(v, depth + 1),
            "tiles" | "rect" => v.is_object() && layout_types(v, depth + 1),
            _ => layout_types(v, depth + 1),
        }),
        Value::Array(a) => a.iter().all(|v| layout_types(v, depth + 1)),
        _ => true,
    }
}

pub fn validate(v: &Value) -> Result<()> {
    if v["version"] != 1 {
        return Err("unsupported checkpoint version".into());
    }
    let windows = v["windows"]
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 100)
        .ok_or("empty or invalid windows")?;
    let mut ids = HashSet::new();
    for w in windows {
        if !numbers(&w["position"], 2)
            || !numbers(&w["size"], 2)
            || w["size"][0].as_f64().unwrap() < 1.0
            || w["size"][1].as_f64().unwrap() < 1.0
        {
            return Err("invalid window geometry".into());
        }
        if w.get("mode")
            .is_some_and(|m| m.as_i64().is_none_or(|n| !(0..=4).contains(&n)))
        {
            return Err("invalid window mode".into());
        }
        let panes = w["panes"]
            .as_array()
            .filter(|a| !a.is_empty() && a.len() <= 1000)
            .ok_or("invalid panes")?;
        let mut keys = HashSet::new();
        let mut filetree_owners = HashSet::new();
        for p in panes {
            let id = p["id"]
                .as_i64()
                .filter(|id| *id >= 0)
                .ok_or("invalid pane ID")?;
            if !ids.insert(id) {
                return Err("duplicate pane ID".into());
            }
            keys.insert(format!("%{id}"));
            if !p["cwd"].is_string() {
                return Err("invalid cwd".into());
            }
            if let Some(parent) = p.get("spawned_by").filter(|v| !v.is_null()) {
                let parent = parent.as_i64().ok_or("invalid spawned_by")?;
                if parent == id || !panes.iter().any(|p| p["id"] == parent) {
                    return Err("spawned_by must reference another pane in its window".into());
                }
            }
            if let Some(tree) = p.get("filetree") {
                let owner = tree["owner"].as_i64().ok_or("invalid filetree owner")?;
                if owner == id || !filetree_owners.insert(owner)
                    || !panes.iter().any(|p| p["id"] == owner && p.get("filetree").is_none()) {
                    return Err("filetree must reference an ordinary owner pane in its window".into());
                }
                if tree["root"].as_str().is_none_or(|s| !std::path::Path::new(s).is_absolute() || s.contains('\0')) {
                    return Err("invalid filetree root".into());
                }
            }
            if let Some(agent) = p.get("agent").filter(|a| !a.is_null()) {
                let kind = agent["kind"].as_str().unwrap_or("");
                if !["codex", "claude"].contains(&kind) {
                    return Err("unsupported agent".into());
                }
                let fields = agent.as_object().ok_or("invalid agent")?;
                if let Some(field) = fields.keys()
                    .find(|key| !["kind", "session_id", "executable", "env", "pid", "started"].contains(&key.as_str())) {
                    return Err(format!("Unknown agent field: {field}").into());
                }
                if !agent["session_id"].is_null() && agent_id(&agent["session_id"]).is_none() {
                    return Err("invalid conversation ID".into());
                }
                let env = agent["env"].as_object().ok_or("agent.env must be an object")?;
                for (name, value) in env {
                    if !agent_locations(kind).contains(&name.as_str()) {
                        return Err(format!("agent.env cannot set {name} for {kind}").into());
                    }
                    if value.as_str().is_none_or(|s| s.len() > 4096 || s.contains('\0')) {
                        return Err("agent.env values must be strings of at most 4096 bytes".into());
                    }
                }
            }
            // An opted-in node relaunches from its declared command and state.
            if let Some(node) = p.get("node").filter(|n| !n.is_null()) {
                if p.get("filetree").is_some() || p.get("agent").is_some_and(|a| !a.is_null()) {
                    return Err("a node pane cannot also be a filetree or an agent".into());
                }
                let mut restore = node.as_object().cloned().ok_or("invalid node")?;
                let state = restore.remove("state");
                if restore.remove("pid").is_some_and(|pid| pid.as_i64().is_none_or(|pid| pid <= 0)) {
                    return Err("invalid node pid".into());
                }
                node_restore(&Value::Object(restore))?;
                if let Some(state) = state {
                    node_state(&state)?;
                }
            }
        }
        // Chromium panes reopen from their pages and profile; page state is
        // not saved. Their keys share the pane namespace and layout.
        let chromiums = w["chromiums"]
            .as_array()
            .filter(|a| a.len() <= 100)
            .ok_or("invalid chromiums")?;
        for c in chromiums {
            let id = c["id"].as_i64().filter(|id| *id >= 0).ok_or("invalid chromium ID")?;
            if !ids.insert(id) {
                return Err("duplicate pane ID".into());
            }
            keys.insert(format!("%{id}"));
            let urls = c["urls"]
                .as_array()
                .filter(|a| !a.is_empty() && a.len() <= 32)
                .ok_or("invalid chromium pages")?;
            if !urls.iter().all(|url| url.as_str().is_some_and(chromium_page)) {
                return Err("chromium pages must be http, https or about:blank".into());
            }
            // A chromium shares its owner's session, so its window. Restore
            // opens one without an owner through its window's first terminal.
            if c.get("owner").is_some_and(|owner| !owner.is_null())
                && !panes.iter().any(|p| p["id"] == c["owner"] && p.get("filetree").is_none()) {
                return Err("chromium owner must be an ordinary pane in its window".into());
            }
            let path = |field: &str| c.get(field).filter(|v| !v.is_null());
            if path("profile").is_some() && path("profile_template").is_some() {
                return Err("chromium has both a profile and a profile template".into());
            }
            for field in ["profile", "profile_template"] {
                if let Some(value) = path(field) {
                    // An empty profile is a temporary one; a path must be absolute.
                    let text = value.as_str().ok_or("invalid chromium profile")?;
                    if (field == "profile_template" || !text.is_empty())
                        && (!std::path::Path::new(text).is_absolute() || text.contains('\0')) {
                        return Err("invalid chromium profile".into());
                    }
                }
            }
        }
        let tabs = w["tabs"]
            .as_array()
            .filter(|a| !a.is_empty())
            .ok_or("invalid tabs")?;
        let mut placed = HashSet::new();
        let mut tab_ids = HashSet::new();
        for tab in tabs {
            let id = tab["id"]
                .as_i64()
                .filter(|id| *id >= 0)
                .ok_or("invalid tab ID")?;
            if !tab_ids.insert(id) {
                return Err("duplicate tab ID".into());
            }
            let tree = &tab["tree"];
            if !layout_types(tree, 0) {
                return Err("invalid layout field types".into());
            }
            let mut tab_keys = HashSet::new();
            let leaves = if tree.get("pane").is_some() {
                vec![tree]
            } else {
                tree["windows"]
                    .as_array()
                    .ok_or("invalid layout")?
                    .iter()
                    .collect()
            };
            for leaf in leaves {
                let key = leaf["pane"].as_str().ok_or("invalid pane reference")?;
                tab_keys.insert(key.to_owned());
                if !keys.contains(key) || !placed.insert(key.to_owned()) {
                    return Err("missing or duplicate pane reference".into());
                }
            }
            if !tab_keys.contains(tab["focused"].as_str().unwrap_or("")) {
                return Err("invalid focused pane".into());
            }
            for pane in panes.iter().filter(|p| p.get("filetree").is_some()) {
                if tab_keys.contains(&format!("%{}", pane["id"]))
                    && !tab_keys.contains(&format!("%{}", pane["filetree"]["owner"])) {
                    return Err("filetree and owner must be in the same tab".into());
                }
            }
        }
        if placed != keys || !tab_ids.contains(&w["active"].as_i64().unwrap_or(-1)) {
            return Err("incomplete layout".into());
        }
    }
    let mapping: std::collections::HashMap<_, _> = ids.iter().map(|id| {
        let key = format!("%{id}");
        (key.clone(), key)
    }).collect();
    for window in windows {
        if let Some(saved) = window.get("graph") {
            let mut graph = crate::graph::Graph::default();
            for id in &ids { graph.add(*id as u64, String::new()); }
            graph.restore_checkpoint(saved, &mapping)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate;
    use serde_json::{Value, json};

    /// A terminal and its chromium side by side, and a window whose
    /// chromium has a tab of its own and no owner.
    fn fixture() -> Value {
        json!({"version":1,"windows":[
            {"active":1,"position":[0,0],"size":[900,700],
             "tabs":[{"id":1,"focused":"%1","tree":{"windows":[{"pane":"%1"},{"pane":"%2"}]}}],
             "panes":[{"id":1,"pid":-1,"cwd":"/tmp"}],
             "chromiums":[{"id":2,"owner":1,"urls":["https://example.com/a","about:blank"],"profile":""}]},
            {"active":4,"position":[40,40],"size":[900,700],
             "tabs":[{"id":4,"focused":"%4","tree":{"pane":"%4"}},{"id":5,"focused":"%3","tree":{"windows":[{"pane":"%3"}]}}],
             "panes":[{"id":4,"pid":-1,"cwd":"/tmp"}],
             "chromiums":[{"id":3,"owner":null,"urls":["http://127.0.0.1:8000/"],"profile_template":"/tmp/template"}]}]})
    }
    fn rejected(change: impl FnOnce(&mut Value)) -> String {
        let mut v = fixture();
        change(&mut v);
        validate(&v).expect_err("checkpoint should be rejected").to_string()
    }

    #[test]
    fn chromiums_are_part_of_every_window() {
        validate(&fixture()).unwrap();
        let mut v = fixture();
        v["windows"][0]["chromiums"][0]["owner"] = Value::Null;
        v["windows"][1]["chromiums"][0]["owner"] = json!(4);
        v["windows"][1]["chromiums"][0]["profile_template"] = Value::Null;
        validate(&v).unwrap();
        rejected(|v| { v["windows"][0].as_object_mut().unwrap().remove("chromiums"); });
        // Every chromium must be placed, and every placed key must exist.
        rejected(|v| v["windows"][0]["tabs"][0]["tree"]["windows"].as_array_mut().unwrap().truncate(1));
        rejected(|v| v["windows"][1]["chromiums"] = json!([]));
        rejected(|v| v["windows"][1]["chromiums"][0]["id"] = json!(4));
    }

    #[test]
    fn chromium_pages_are_web_pages() {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "chrome://settings", ""] {
            rejected(|v| v["windows"][0]["chromiums"][0]["urls"][0] = json!(url));
        }
        rejected(|v| v["windows"][0]["chromiums"][0]["urls"] = json!([]));
        rejected(|v| v["windows"][0]["chromiums"][0]["urls"] = json!(vec!["about:blank"; 33]));
        rejected(|v| v["windows"][0]["chromiums"][0]["urls"][0] = json!(format!("https://{}", "a".repeat(8192))));
    }

    #[test]
    fn chromium_profiles_and_owners_are_checked() {
        rejected(|v| v["windows"][0]["chromiums"][0]["profile"] = json!("relative/profile"));
        rejected(|v| v["windows"][1]["chromiums"][0]["profile_template"] = json!(""));
        rejected(|v| v["windows"][0]["chromiums"][0]["profile_template"] = json!("/tmp/template"));
        rejected(|v| v["windows"][0]["chromiums"][0]["owner"] = json!(9));
        rejected(|v| v["windows"][0]["chromiums"][0]["owner"] = json!("1"));
        // Ownership cannot cross sessions, so it cannot cross windows.
        rejected(|v| v["windows"][1]["chromiums"][0]["owner"] = json!(1));
        // A filetree is not an owner: closing it must not close the browser.
        let message = rejected(|v| {
            v["windows"][0]["panes"].as_array_mut().unwrap().push(json!({"id":4,"pid":-1,"cwd":"/tmp","filetree":{"owner":1,"root":"/tmp"}}));
            v["windows"][0]["tabs"][0]["tree"]["windows"].as_array_mut().unwrap().push(json!({"pane":"%4"}));
            v["windows"][0]["chromiums"][0]["owner"] = json!(4);
        });
        assert_eq!(message, "chromium owner must be an ordinary pane in its window");
    }

    #[test]
    fn opted_in_nodes_carry_a_relaunch_and_state_but_not_alongside_an_agent() {
        let node = json!({"command":["gft","node","payload-inspector"],"cwd":"/work","env":{"GRAFFITTY_NODE_CONFIG":"/work/n.json","GRAFFITTY_SECRETS_CONFIG":"/config/secrets.toml"},
                          "state":{"seen":3},"pid":42});
        let mut v = fixture();
        v["windows"][0]["panes"][0]["node"] = node.clone();
        validate(&v).unwrap();
        rejected(|v| { v["windows"][0]["panes"][0]["node"] = node.clone(); v["windows"][0]["panes"][0]["agent"] = json!({"kind":"codex"}); });
        rejected(|v| v["windows"][0]["panes"][0]["node"] = json!({"command":["gft"],"env":{"LD_PRELOAD":"/tmp/x.so"}}));
        // Null removes a variable the node did not have from the restoring shell.
        v["windows"][0]["panes"][0]["node"] = json!({"command":["opencode"],"env":{"XDG_DATA_HOME":"/data","OPENCODE_DB":null}});
        validate(&v).unwrap();
        rejected(|v| v["windows"][0]["panes"][0]["node"] = json!({"command":["gft"],"env":{"MODE":1}}));
        rejected(|v| v["windows"][0]["panes"][0]["node"] = json!({"command":["gft"],"pid":0}));
        rejected(|v| v["windows"][0]["panes"][0]["node"] = json!({"command":["gft"],"state":"x".repeat(64 * 1024)}));
        // Only process discovery's agents remain: integrations declare relaunches.
        rejected(|v| v["windows"][0]["panes"][0]["agent"] = json!({"kind":"pi","session_id":"abc"}));
    }

    #[test]
    fn discovered_agents_keep_only_their_own_provider_locations() {
        let mut v = fixture();
        v["windows"][0]["panes"][0]["agent"] = json!({"kind":"claude","session_id":"22222222-2222-4222-8222-222222222222",
            "executable":"/bin/claude","env":{"CLAUDE_CONFIG_DIR":"/accounts/work"},"pid":7,"started":"Mon Sep 21 10:01:00 2026"});
        validate(&v).unwrap();
        v["windows"][0]["panes"][0]["agent"] = json!({"kind":"codex","session_id":null,"env":{"CODEX_HOME":"/c","CODEX_SQLITE_HOME":"/s"}});
        validate(&v).unwrap();
        let agent = |agent: Value| rejected(move |v| v["windows"][0]["panes"][0]["agent"] = agent);
        // Each provider keeps its own locations; credentials are never among them.
        assert_eq!(agent(json!({"kind":"claude","env":{"CODEX_HOME":"/c"}})), "agent.env cannot set CODEX_HOME for claude");
        agent(json!({"kind":"codex","env":{"CODEX_API_KEY":"secret"}}));
        agent(json!({"kind":"codex","env":{"CODEX_HOME":null}}));
        // Discovery always records the environment, so a resume knows what to remove.
        assert_eq!(agent(json!({"kind":"codex","session_id":null})), "agent.env must be an object");
        assert_eq!(agent(json!({"kind":"codex","env":{},"home":"/c"})), "Unknown agent field: home");
    }

    #[test]
    fn a_window_opens_its_chromiums_through_its_own_terminal() {
        let message = rejected(|v| {
            v["windows"][1]["panes"] = json!([]);
            v["windows"][1]["tabs"].as_array_mut().unwrap().remove(0);
            v["windows"][1]["active"] = json!(5);
        });
        assert_eq!(message, "invalid panes");
    }
}
