//! `terminal.run` and `pane.place`: a terminal starts programs and agents in
//! new panes of its own tab and arranges panes there.
//!
//! The new pane records who started it (`spawned_by`), the way herdr-core
//! records a terminal's parent (crates/herdr-core/src/api/run.rs,
//! Apache-2.0): children end with their parent unless they asked to outlive
//! it.
//!
//! Placement is authoritative layout, so every frontend shows the same
//! arrangement.
use crate::{Error, Server, api, terminal_api, workspace};
use graffitty_workspace_core::{state::Edit, tiling::{Side, TabLayout}};
use serde_json::{Value, json};

pub const PROVIDERS: [&str; 4] = ["claude", "codex", "opencode", "pi"];

const RUN_KEYS: &[&str] = &[
    "command", "agent", "model", "agent_args", "name", "cwd", "outlive_parent", "wire",
    "side", "of", "x", "y", "width", "height",
];
const PLACE_KEYS: &[&str] = &["target", "side", "of", "x", "y", "width", "height"];

/// Where a pane goes: beside another pane, at a workspace position, with a size.
pub struct Placement {
    pub side: Option<Side>,
    pub of: Option<String>,
    pub position: Option<[f32; 2]>,
    pub size: Option<[f32; 2]>,
}
impl Placement {
    pub fn parse(params: &Value) -> Result<Self, Error> {
        let side = match params.get("side") {
            None | Some(Value::Null) => None,
            Some(value) => Some(
                value.as_str().and_then(Side::parse)
                    .ok_or_else(|| api::error("invalid_params", "side must be left, right, above or below"))?,
            ),
        };
        let of = optional_string(params, "of")?;
        if of.is_some() && side.is_none() {
            return Err(api::error("invalid_params", "of requires a side"));
        }
        let number = |key: &str| -> Result<Option<f32>, Error> {
            match params.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(value) => value.as_f64().filter(|v| v.is_finite()).map(|v| Some(v as f32))
                    .ok_or_else(|| api::error("invalid_params", &format!("{key} must be a finite number"))),
            }
        };
        let position = match (number("x")?, number("y")?) {
            (None, None) => None,
            (Some(x), Some(y)) => Some([x, y]),
            _ => return Err(api::error("invalid_params", "x and y go together")),
        };
        let size = match (number("width")?, number("height")?) {
            (None, None) => None,
            (Some(w), Some(h)) => Some([w, h]),
            _ => return Err(api::error("invalid_params", "width and height go together")),
        };
        if side.is_some() && position.is_some() {
            return Err(api::error("invalid_params", "choose a side or an x/y position, not both"));
        }
        Ok(Self { side, of, position, size })
    }
    fn is_empty(&self) -> bool {
        self.side.is_none() && self.position.is_none() && self.size.is_none()
    }
}

fn optional_string(params: &Value, key: &str) -> Result<Option<String>, Error> {
    match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.is_empty() => Ok(Some(s.clone())),
        Some(Value::String(_)) => Ok(None),
        Some(_) => Err(api::error("invalid_params", &format!("{key} must be a string"))),
    }
}

fn reject_unknown(params: &Value, allowed: &[&str]) -> Result<(), Error> {
    let object = params.as_object().ok_or_else(|| api::error("invalid_params", "Expected object params"))?;
    if let Some(key) = object.keys().find(|key| !allowed.contains(&key.as_str())) {
        return Err(api::error("invalid_params", &format!("Unsupported parameter: {key}")));
    }
    Ok(())
}

/// POSIX single quoting; the command line is typed into the pane's shell.
pub fn shell_quote(word: &str) -> String {
    format!("'{}'", word.replace('\'', "'\\''"))
}

/// The interactive launch line for an integrated agent, as `graph spawn`
/// has always typed it: the integration check first, then the agent.
pub fn agent_command(cli: &str, provider: &str, model: Option<&str>, extra: &[String]) -> Result<String, Error> {
    if !PROVIDERS.contains(&provider) {
        return Err(api::error("invalid_params", "agent must be claude, codex, opencode or pi"));
    }
    let mut words = vec![provider.to_owned()];
    if let Some(model) = model.filter(|m| !m.is_empty()) {
        // Every supported provider has a model flag; Codex spells it -m.
        words.push(if provider == "codex" { "-m" } else { "--model" }.into());
        words.push(model.into());
    }
    words.extend(extra.iter().cloned());
    let launch: Vec<_> = words.iter().map(|w| shell_quote(w)).collect();
    Ok(format!("{} integrate agent {provider} --status && {}", shell_quote(cli), launch.join(" ")))
}

/// A tab-local pane target: the caller's pane when omitted.
fn resolve_pane(server: &Server, workspace: &str, tab: u64, caller: u64, target: Option<&str>) -> Result<String, Error> {
    let Some(target) = target else { return Ok(format!("%{caller}")) };
    let state = server.workspace_state.snapshot(workspace);
    let key = terminal_api::resolve_in_workspace(&state, workspace, target)
        .ok_or_else(|| api::error("invalid_target", "No matching pane in this workspace"))?;
    let in_tab = state.layout.tabs.get(&tab).is_some_and(|layout| layout.window(&key).is_some());
    if !in_tab {
        return Err(api::error("forbidden", "Placement stays within the calling terminal's tab"));
    }
    Ok(key)
}

fn apply_layout(server: &mut Server, workspace: &str, tab: u64, layout: TabLayout) -> Result<(), Error> {
    workspace::sync(server, workspace)?;
    let revision = server.workspace_state.snapshot(workspace).revision;
    server.workspace_state.edit(workspace, revision, Edit::Tab { tab, layout, settings: None })?;
    workspace::sync_terminal_geometry(server, workspace)
}

/// Start a program or agent in a new pane beside the caller.
pub fn run(server: &mut Server, caller: u64, params: &Value) -> Result<Value, Error> {
    reject_unknown(params, RUN_KEYS)?;
    let (workspace, tab) = {
        let session = server.sessions.get(&caller).ok_or_else(|| api::error("workspace_closed", "Terminal no longer exists"))?;
        (session.workspace.clone(), session.tab)
    };
    let command = optional_string(params, "command")?;
    let agent = optional_string(params, "agent")?;
    if command.is_some() && agent.is_some() {
        return Err(api::error("invalid_params", "choose a command or an agent"));
    }
    let model = optional_string(params, "model")?;
    let extra: Vec<String> = match params.get("agent_args") {
        None | Some(Value::Null) => vec![],
        Some(value) => serde_json::from_value(value.clone())
            .map_err(|_| api::error("invalid_params", "agent_args must be a list of strings"))?,
    };
    if agent.is_none() && (model.is_some() || !extra.is_empty()) {
        return Err(api::error("invalid_params", "model and agent_args apply to agents"));
    }
    let typed = match (&agent, &command) {
        (Some(provider), _) => Some(agent_command(&server.cli, provider, model.as_deref(), &extra)?),
        (None, Some(command)) => Some(command.clone()),
        (None, None) => None,
    };
    let name = optional_string(params, "name")?;
    if name.as_ref().is_some_and(|n| n.chars().count() > 64) {
        return Err(api::error("invalid_params", "name must be at most 64 characters"));
    }
    let outlive = match params.get("outlive_parent") {
        None | Some(Value::Null) => false,
        Some(value) => value.as_bool().ok_or_else(|| api::error("invalid_params", "outlive_parent must be a boolean"))?,
    };
    let wires = crate::graph_wiring::parse(params)?;
    if !wires.is_empty() {
        if agent.is_none() {
            return Err(api::error("invalid_params", "wire connects an agent; add --agent"));
        }
        // The lead must be able to hold the other end of every wire now; the
        // child's end exists once its SessionStart hook names its provider.
        let lead = server.graphs.get(&workspace).and_then(|graph| graph.nodes.get(&format!("%{caller}")));
        if !crate::graph_wiring::wirable(lead) {
            return Err(api::error("forbidden", "wire needs the caller to be an integrated agent with graph ports; this terminal is not one"));
        }
    }
    let placement = Placement::parse(params)?;
    let options = optional_string(params, "cwd")?.map(|cwd| {
        serde_json::from_value::<crate::spawn::SpawnOptions>(json!({"cwd": cwd}))
    }).transpose()?;
    workspace::sync(server, &workspace)?;
    let anchor = resolve_pane(server, &workspace, tab, caller, placement.of.as_deref())?;
    let state = server.workspace_state.snapshot(&workspace);
    let mut layout = state.layout.tabs.get(&tab).cloned().ok_or("Unknown workspace tab")?;
    let area = state.tabs[&tab].area;
    let key = format!("%{}", server.next);
    if let Some(side) = placement.side {
        layout.add_beside(&anchor, &key, side, area)?;
    }
    let created = server.create_with_spawn(&workspace, Some(tab), Some(caller), options)?;
    {
        let session = server.sessions.get_mut(&created).unwrap();
        session.spawned_by = Some(caller);
        session.dies_with_parent = !outlive;
        if let Some(name) = &name {
            session.pinned_title = name.clone();
        }
    }
    if !wires.is_empty() {
        server.pending_wires.insert(created, crate::graph_wiring::Pending { parent: caller, wires: wires.clone() });
    }
    let applied = (|| -> Result<(), Error> {
        if placement.side.is_none() {
            // A free pane joins the layout before absolute geometry can apply.
            workspace::sync(server, &workspace)?;
            layout = server.workspace_state.snapshot(&workspace).layout.tabs.get(&tab).cloned().ok_or("Unknown workspace tab")?;
        }
        if placement.position.is_some() || placement.size.is_some() {
            layout.set_rect(&key, placement.position, placement.size)?;
        }
        if let Some(rect) = layout.window(&key).map(|w| w.rect) {
            server.sessions.get_mut(&created).unwrap().rect = rect.map(f64::from);
        }
        if !placement.is_empty() {
            apply_layout(server, &workspace, tab, layout.clone())?;
        }
        Ok(())
    })();
    if let Err(error) = applied {
        server.close(created);
        return Err(error);
    }
    if let Some(line) = &typed {
        server.sessions[&created].input(format!("{line}\r").into_bytes())?;
    }
    Ok(json!({
        "pane": key,
        "node": key,
        "spawned_by": format!("%{caller}"),
        "tab": tab,
        "command": typed,
        "agent": agent,
        "dies_with_parent": !outlive,
        "wire": {"pending": wires},
    }))
}

/// Arrange a pane of the caller's tab: beside another pane, or at a position/size.
pub fn place(server: &mut Server, caller: u64, params: &Value) -> Result<Value, Error> {
    reject_unknown(params, PLACE_KEYS)?;
    let (workspace, tab) = {
        let session = server.sessions.get(&caller).ok_or_else(|| api::error("workspace_closed", "Terminal no longer exists"))?;
        (session.workspace.clone(), session.tab)
    };
    let placement = Placement::parse(params)?;
    if placement.is_empty() {
        return Err(api::error("invalid_params", "give a side (with of), an x/y position, or a width/height"));
    }
    workspace::sync(server, &workspace)?;
    let target = resolve_pane(server, &workspace, tab, caller, optional_string(params, "target")?.as_deref())?;
    let anchor = resolve_pane(server, &workspace, tab, caller, placement.of.as_deref())?;
    let state = server.workspace_state.snapshot(&workspace);
    let mut layout = state.layout.tabs.get(&tab).cloned().ok_or("Unknown workspace tab")?;
    let area = state.tabs[&tab].area;
    // Placing a pane asks for it somewhere visible. Chromium panes start
    // hidden; without this, placement would only move an invisible window.
    layout.window_mut(&target).ok_or("Unknown pane")?.shown = true;
    if let Some(side) = placement.side {
        if anchor == target {
            return Err(api::error("invalid_params", "of must name another pane"));
        }
        layout.move_beside(&target, &anchor, side, area)?;
    }
    if placement.position.is_some() || placement.size.is_some() {
        layout.set_rect(&target, placement.position, placement.size)?;
    }
    let rect = layout.window(&target).map(|w| w.rect).ok_or("Unknown pane")?;
    if let Some(id) = target.strip_prefix('%').and_then(|id| id.parse::<u64>().ok()) {
        if let Some(session) = server.sessions.get_mut(&id) {
            session.rect = rect.map(f64::from);
        }
    }
    apply_layout(server, &workspace, tab, layout)?;
    Ok(json!({"pane": target, "rect": rect}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_launch_lines_check_integration_then_start_the_agent() {
        assert_eq!(agent_command("/opt/g ft/gft", "pi", None, &[]).unwrap(), "'/opt/g ft/gft' integrate agent pi --status && 'pi'");
        assert_eq!(agent_command("gft", "codex", Some("gpt-6"), &["--no-daemon".into()]).unwrap(),
            "'gft' integrate agent codex --status && 'codex' '-m' 'gpt-6' '--no-daemon'");
        assert_eq!(agent_command("gft", "claude", Some("opus"), &[]).unwrap(), "'gft' integrate agent claude --status && 'claude' '--model' 'opus'");
        assert!(agent_command("gft", "bash", None, &[]).is_err());
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
    }

    #[test]
    fn placement_parsing_rejects_half_pairs_and_mixed_modes() {
        let ok = Placement::parse(&json!({"side":"right","of":"%3","width":400,"height":300})).unwrap();
        assert_eq!(ok.side, Some(Side::Right));
        assert_eq!(ok.size, Some([400., 300.]));
        assert!(Placement::parse(&json!({"side":"diagonal"})).is_err());
        assert!(Placement::parse(&json!({"of":"%3"})).is_err());
        assert!(Placement::parse(&json!({"x":1})).is_err());
        assert!(Placement::parse(&json!({"side":"left","x":1,"y":2})).is_err());
        assert!(Placement::parse(&json!({})).unwrap().is_empty());
    }
}
