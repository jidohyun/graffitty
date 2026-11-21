//! Connected Neovim file trees. OSC metadata drives updates; no lsof subprocesses.
use crate::{Error, Server, api, workspace};
use graffitty_workspace_core::{
    state::Edit,
    tiling::{Axis, Kind, Node, TabLayout},
};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

fn command_error(error: Error, executable: &str) -> Error {
    let detail = error.to_string();
    if detail.starts_with("Shell is not an executable file:") || detail.starts_with("Cannot resolve shell:") {
        return format!(
            "Could not execute the filetree command '{executable}'. Edit [filetree] command in the session server's server.toml (normally ~/.config/graffitty/server.toml) to name Neovim on the server, or remove it to use the bundled filetree. Restart the server after changing this setting."
        ).into();
    }
    error
}

/// The read-only Neovim, plugins and config that ship beside gft.
#[derive(Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Runtime {
    root: PathBuf,
    nvim: PathBuf,
    vimruntime: PathBuf,
}
impl Runtime {
    fn open(root: PathBuf) -> Result<Self, Error> {
        let manifest: Value = serde_json::from_slice(&fs::read(root.join("manifest.json"))?)?;
        let relative = |key: &str| -> Result<PathBuf, Error> {
            let value = manifest[key].as_str().ok_or("Invalid filetree runtime manifest")?;
            let path = Path::new(value);
            if path.is_absolute() || path.components().any(|c| !matches!(c, std::path::Component::Normal(_))) {
                return Err("Invalid filetree runtime manifest".into());
            }
            Ok(root.join(path))
        };
        let runtime = Self { nvim: relative("nvim")?, vimruntime: relative("vimruntime")?, root };
        if !runtime.nvim.is_file() || !runtime.vimruntime.is_dir() || !runtime.root.join("init.lua").is_file() {
            return Err("Incomplete filetree runtime".into());
        }
        Ok(runtime)
    }
    /// Installed bundles beside the executable come first; the build checkout's
    /// dist/ is only a development fallback, as for the Chromium host.
    pub fn locate() -> Result<Self, Error> {
        let mut roots: Vec<PathBuf> = Vec::new();
        if let Ok(exe) = std::env::current_exe() {
            roots.extend(exe.ancestors().skip(1).take(5).map(Path::to_path_buf));
        }
        roots.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."));
        for root in roots {
            for directory in [root.clone(), root.join("dist"), root.join("Resources/graffitty")] {
                // Remote installs keep versioned runtimes and point at the current one.
                let candidate = match fs::read_to_string(directory.join("filetree-runtime-path.txt")) {
                    Ok(relative) => directory.join(relative.trim()),
                    Err(_) => directory.join("filetree"),
                };
                if candidate.join("manifest.json").is_file() {
                    return Self::open(candidate);
                }
            }
        }
        Err("The bundled filetree runtime is missing. Reinstall Graffitty (in a source checkout, run tools/build_filetree_runtime.py), or set [filetree] command in the session server's server.toml to use your own Neovim.".into())
    }
}

/// How this server starts filetree Neovim processes.
#[derive(Clone, PartialEq, serde::Serialize, serde::Deserialize)]
enum Launch {
    Bundled(Runtime),
    Custom { command: Vec<String>, environment: BTreeMap<String, String> },
}

/// RPC address for a filetree Neovim. Windows Neovim listens only on named pipes,
/// so the address uses the pipe namespace there; elsewhere it is a Unix socket.
fn rpc_address(directory: &Path, name: &str, windows: bool) -> PathBuf {
    if !windows {
        return directory.join(name);
    }
    let id = directory.file_name().map(|id| id.to_string_lossy().into_owned()).unwrap_or_default();
    PathBuf::from(format!(r"\\.\pipe\{id}-{name}"))
}

fn navigator_command(enabled: bool) -> String {
    format!("lua assert(loadstring({}))({enabled})", json!(include_str!("../filetree/integrations.lua")))
}

#[derive(Default)]
pub struct Filetrees {
    pub active: BTreeMap<u64, Filetree>,
    // A detached editor keeps its RPC socket until that pane itself is closed.
    detached_editors: BTreeMap<u64, PathBuf>,
    detached_chromiums: BTreeMap<u64, u64>,
    sizes: BTreeMap<String, [f32; 2]>,
    loaded: bool,
}
pub struct Filetree {
    pub owner: u64,
    directory: PathBuf,
    cwd: PathBuf,
    report: String,
    probe: Instant,
    layout_revision: u64,
    pub address: PathBuf,
    editor: Option<(u64, PathBuf)>,
    chromium: Option<u64>,
    launch: Launch,
    navigator: bool,
}

/// Live-process associations, not recovery-checkpoint relaunch instructions.
#[derive(Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct SavedFiletrees {
    active: BTreeMap<u64, SavedFiletree>,
    detached_editors: BTreeMap<u64, PathBuf>,
    detached_chromiums: BTreeMap<u64, u64>,
}

#[derive(Clone, PartialEq, serde::Serialize, serde::Deserialize)]
struct SavedFiletree {
    owner: u64,
    directory: PathBuf,
    cwd: PathBuf,
    address: PathBuf,
    editor: Option<(u64, PathBuf)>,
    chromium: Option<u64>,
    launch: Launch,
    navigator: bool,
}

impl Filetrees {
    pub fn saved(&self) -> SavedFiletrees {
        SavedFiletrees {
            active: self.active.iter().map(|(&id, tree)| (id, SavedFiletree {
                owner: tree.owner, directory: tree.directory.clone(), cwd: tree.cwd.clone(),
                address: tree.address.clone(), editor: tree.editor.clone(), chromium: tree.chromium,
                launch: tree.launch.clone(), navigator: tree.navigator,
            })).collect(),
            detached_editors: self.detached_editors.clone(),
            detached_chromiums: self.detached_chromiums.clone(),
        }
    }
}

/// Rebind only panes actually adopted by the new owner. Timers and layout
/// observations start fresh; the running Neovim keeps its original RPC socket.
pub fn adopt(server: &mut Server, saved: SavedFiletrees) {
    for (id, tree) in saved.active {
        let Some(pane) = server.sessions.get(&id) else { continue };
        if !server.sessions.get(&tree.owner).is_some_and(|owner| owner.workspace == pane.workspace) { continue; }
        let editor = tree.editor.filter(|(editor, _)| server.sessions.get(editor).is_some_and(|editor| editor.workspace == pane.workspace));
        let chromium = tree.chromium.filter(|id| server.chromiums.contains_key(id));
        server.filetrees.active.insert(id, Filetree {
            owner: tree.owner, directory: tree.directory, cwd: tree.cwd,
            report: String::new(), probe: Instant::now(), layout_revision: u64::MAX,
            address: tree.address, editor, chromium, launch: tree.launch, navigator: tree.navigator,
        });
        hold_effects(server, tree.owner, id);
    }
    server.filetrees.detached_editors = saved.detached_editors.into_iter()
        .filter(|(id, _)| server.sessions.contains_key(id)).collect();
    server.filetrees.detached_chromiums = saved.detached_chromiums.into_iter()
        .filter(|(id, chromium)| server.sessions.contains_key(id) && server.chromiums.contains_key(chromium)).collect();
}

/// The effect hold an open filetree places on its connected pane and itself.
const HOLD_ID: &str = "filetree";

/// `[filetree] hold_effects` names effects that stay off while a tree is
/// open, in the connected pane and in the tree.
///
/// The server owns this hold: it survives process changes in the connected
/// pane and ends when the tree closes.
fn hold_effects(server: &mut Server, owner: u64, tree: u64) {
    use graffitty_protocol::osc::{Effects, Hold, Scope};
    let off = server.settings.filetree.hold_effects.clone();
    if off.is_empty() {
        return;
    }
    let hold = Effects::Hold(Hold { id: HOLD_ID.into(), off, on: Vec::new(), until: Scope::Clear });
    for id in [owner, tree] {
        if let Some(session) = server.sessions.get_mut(&id) {
            let pgid = session.foreground();
            session.effect_holds.apply(&hold, pgid);
        }
    }
}

/// Writable stdpaths and log of a bundled filetree, deleted with the pane.
fn sandbox(directory: &Path) -> PathBuf {
    directory.join("nvim")
}

/// Only the association and visible root are part of a recovery checkpoint.
pub fn checkpoint(server: &Server, pane: u64) -> Option<Value> {
    let tree = server.filetrees.active.get(&pane)?;
    let session = server.sessions.get(&pane)?;
    // The injected title hook reports Fyler's displayed root even after U/visit;
    // the Neovim process cwd can still point at the owner's previous directory.
    let displayed = PathBuf::from(session.reported_title());
    let root = if displayed.is_absolute() && displayed.is_dir() { displayed }
        else { session.cwd().unwrap_or_else(|| tree.cwd.clone()) };
    Some(json!({"owner":tree.owner,"root":root}))
}

fn publish(tree: &Filetree) -> Result<(), Error> {
    let path = tree.directory.join("cwd.json");
    let temporary = tree.directory.join("cwd.tmp");
    fs::write(&temporary, serde_json::to_vec(&json!({"cwd":tree.cwd}))?)?;
    fs::rename(temporary, path)?;
    Ok(())
}

pub fn owner(server: &Server, pane: u64) -> u64 {
    let tree = server.filetrees.active.iter().find(|(id, t)| {
        **id == pane
            || t.chromium == Some(pane)
            || t.editor.as_ref().is_some_and(|(id, _)| *id == pane)
    });
    tree.map(|(_, t)| t.owner)
        .or_else(|| {
            server
                .filetrees
                .detached_chromiums
                .iter()
                .find_map(|(source, chromium)| (*chromium == pane).then_some(*source))
        })
        .unwrap_or(pane)
}

/// Immediate ownership, also used to draw tree → viewer connection lines.
pub fn connection_owner(server: &Server, pane: u64) -> Option<u64> {
    server
        .filetrees
        .active
        .get(&pane)
        .map(|t| t.owner)
        .or_else(|| {
            server.filetrees.active.iter().find_map(|(id, t)| {
                t.editor
                    .as_ref()
                    .filter(|(editor, _)| *editor == pane)
                    .map(|_| *id)
            })
        })
}


fn mode(layout: &TabLayout, key: &str) -> &'static str {
    match layout.window(key) {
        Some(w) if w.stashed => "outside",
        Some(w) if layout.enabled && !w.graph_floating => "tiled",
        _ => "floating",
    }
}
fn size_key(cwd: &Path, mode: &str) -> String {
    format!("{mode}:{}", cwd.display())
}

fn pair_weights(node: &mut Node, source: &str, tree: &str, share: f32) {
    if let Kind::Split { children, .. } = &mut node.kind {
        if children.len() == 2 && children[0].keys() == [tree] && children[1].keys() == [source] {
            children[0].weight = Some(share);
            children[1].weight = Some(1. - share);
        } else {
            for child in children {
                pair_weights(child, source, tree, share);
            }
        }
    }
}

fn place(
    layout: &mut TabLayout,
    area: [f32; 4],
    source: &str,
    tree: &str,
    size: [f32; 2],
    focus: bool,
) -> Result<(), Error> {
    let rectangles = layout.arrange(area);
    let source_rect = *rectangles.get(source).ok_or("Source pane is hidden")?;
    let tiles = layout.tiles.clone();
    layout.add_neighbor(source, tree, Axis::Horizontal, true, area)?;
    let tiled = mode(layout, tree) == "tiled";
    if tiled {
        // Wrap just the source so removing the tree restores every other split.
        layout.tiles = tiles.map(|node| node.join(source, tree, Axis::Horizontal, true));
        let available = (source_rect[2] - layout.gap.unwrap_or(8.)).max(1.);
        let share = (size[0] / available).clamp(0.1, 0.8);
        if let Some(node) = &mut layout.tiles {
            pair_weights(node, source, tree, share);
        }
    }
    let window = layout.windows.iter_mut().find(|w| w.key == tree).unwrap();
    // A small overlap lets the existing force animation separate floating panes.
    window.rect = [
        source_rect[0] - size[0] + 40.,
        source_rect[1],
        size[0],
        size[1],
    ];
    layout.focused = if focus { tree } else { source }.into();
    layout.physics_anchor = Some(source.into());
    Ok(())
}

pub fn toggle(server: &mut Server, caller: u64, params: &Value) -> Result<Value, Error> {
    let source = owner(server, caller);
    if let Some(pane) = server
        .filetrees
        .active
        .iter()
        .find(|(_, t)| t.owner == source)
        .map(|(id, _)| *id)
    {
        server.close(pane);
        return Ok(json!({"closed":format!("%{pane}"),"focus":format!("%{source}")}));
    }
    let session = server
        .sessions
        .get(&source)
        .ok_or("Connected terminal closed")?;
    let name = session.workspace.clone();
    let tab = session.tab;
    let report = session.cwd_report();
    let cwd = directory_from_report(&report)
        .filter(|p| p.is_dir())
        .or_else(|| session.cwd())
        .ok_or("Cannot determine source directory")?;
    let root = params.get("root").map(|value| value.as_str()
        .filter(|s| Path::new(s).is_absolute() && Path::new(s).is_dir())
        .ok_or("Filetree root must be an existing absolute directory"))
        .transpose()?.unwrap_or("");
    // The command belongs to the server; client parameters cannot choose it.
    let settings = &server.settings.filetree;
    let launch = if settings.command.is_empty() {
        Launch::Bundled(Runtime::locate()?)
    } else {
        Launch::Custom { command: settings.command.clone(), environment: settings.environment.clone() }
    };
    workspace::sync(server, &name)?;
    let before = server.workspace_state.snapshot(&name);
    let mut layout = before.layout.tabs[&tab].clone();
    let source_key = format!("%{source}");
    if !server.filetrees.loaded {
        server.filetrees.sizes = fs::read(server.descriptor.with_extension("filetree-sizes.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default();
        server.filetrees.loaded = true;
    }
    let size = server
        .filetrees
        .sizes
        .get(&size_key(&cwd, mode(&layout, &source_key)))
        .copied()
        .filter(|s| {
            s.iter()
                .all(|v| v.is_finite() && (80. ..=10000.).contains(v))
        })
        .unwrap_or([320., layout.window(&source_key).map_or(600., |w| w.rect[3])]);
    // macOS has a short Unix socket path limit and a long system temp directory.
    let directory =
        std::env::temp_dir().join(format!("graffitty-{}", uuid::Uuid::new_v4().simple()));
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&directory)?;
    let tree = Filetree {
        owner: source,
        cwd: cwd.clone(),
        report,
        probe: Instant::now(),
        layout_revision: u64::MAX,
        address: rpc_address(&directory, "t", cfg!(windows)),
        directory,
        editor: None,
        chromium: None,
        launch,
        navigator: server.settings.navigator.enabled && server.settings.navigator.filetree,
    };
    let result = (|| -> Result<u64, Error> {
        publish(&tree)?;
        // Integration hooks run before any config, in both bundled and custom modes.
        let integration = vec![
            "--cmd".into(),
            format!("lua assert(loadstring({}))()", json!(include_str!("../filetree/title.lua"))),
            "--cmd".into(),
            navigator_command(tree.navigator),
            "--listen".into(),
            tree.address.to_string_lossy().into(),
        ];
        let (shell, args, env) = match &tree.launch {
            Launch::Bundled(runtime) => {
                // Hermetic: only the bundle is read; every stdpath Neovim or
                // a plugin writes is inside the pane's private directory.
                //
                // Config stays unread (-u), and XDG_CONFIG_HOME stays the
                // user's so child processes such as git keep their
                // configuration.
                let sandbox = sandbox(&tree.directory);
                fs::create_dir(&sandbox)?;
                let path = |name: &str| sandbox.join(name).to_string_lossy().into_owned();
                let mut args: Vec<String> = vec![
                    "-u".into(), runtime.root.join("init.lua").to_string_lossy().into(),
                    "-i".into(), "NONE".into(), "-n".into(),
                ];
                args.extend(integration);
                let env = [
                    ("NVIM_APPNAME", "graffitty-filetree".to_owned()),
                    ("VIMRUNTIME", runtime.vimruntime.to_string_lossy().into_owned()),
                    ("XDG_DATA_HOME", path("data")),
                    ("XDG_STATE_HOME", path("state")),
                    ("XDG_CACHE_HOME", path("cache")),
                    ("NVIM_LOG_FILE", path("nvim.log")),
                ].map(|(k, v)| (k.to_owned(), v)).into();
                (runtime.nvim.to_string_lossy().into_owned(), args, env)
            }
            Launch::Custom { command, environment } => {
                let mut args = integration;
                args.extend(command[1..].iter().cloned());
                (command[0].clone(), args, environment.clone())
            }
        };
        let executable = shell.clone();
        let pane = server.create_with_environment(
            &name,
            Some(tab),
            Some(source),
            Some(crate::spawn::SpawnOptions {
                shell: Some(shell),
                login: Some(false),
                shell_integration: Some(false),
                cwd: Some(cwd.to_string_lossy().into()),
                args,
                env,
                ..Default::default()
            }),
            &[
                ("GRAFFITTY_FILETREE_OWNER", source_key.clone()),
                ("GRAFFITTY_FILETREE_ROOT", root.to_owned()),
                (
                    "GRAFFITTY_FILETREE_STATE",
                    tree.directory.join("cwd.json").to_string_lossy().into(),
                ),
            ],
            // A restore reopens the filetree under its saved pane ID.
            crate::SavedIdentity { pane: params["pane_id"].as_u64(), ..Default::default() },
        ).map_err(|error| command_error(error, &executable))?;
        let placed = (|| -> Result<(), Error> {
            place(
                &mut layout,
                before.tabs[&tab].area,
                &source_key,
                &format!("%{pane}"),
                size,
                params["focus"] == true,
            )?;
            workspace::sync(server, &name)?;
            let state = server.workspace_state.snapshot(&name);
            server.workspace_state.edit(
                &name,
                state.revision,
                Edit::Tab {
                    tab,
                    layout,
                    settings: None,
                },
            )?;
            workspace::sync_terminal_geometry(server, &name)
        })();
        if let Err(error) = placed {
            server.close(pane);
            return Err(error);
        }
        Ok(pane)
    })();
    match result {
        Ok(pane) => {
            let address = tree.address.clone();
            server.filetrees.active.insert(pane, tree);
            hold_effects(server, source, pane);
            Ok(
                json!({"pane":format!("%{pane}"),"owner":source_key,"address":address,
                "focus":format!("%{}",if params["focus"] == true {pane} else {source})}),
            )
        }
        Err(error) => {
            let _ = fs::remove_dir_all(&tree.directory);
            Err(error)
        }
    }
}

pub fn closing(server: &mut Server, pane: u64) {
    server
        .filetrees
        .detached_chromiums
        .retain(|_, chromium| *chromium != pane);
    if let Some(directory) = server.filetrees.detached_editors.remove(&pane) {
        let _ = fs::remove_file(directory.join("v"));
        let _ = fs::remove_dir(directory);
    }
    for tree in server.filetrees.active.values_mut() {
        if tree.chromium == Some(pane) {
            tree.chromium = None;
        }
        if tree.editor.as_ref().is_some_and(|(id, _)| *id == pane) {
            if let Some((_, address)) = tree.editor.take() {
                let _ = fs::remove_file(address);
            }
        }
    }
    let children: Vec<_> = server
        .filetrees
        .active
        .iter()
        .filter(|(_, t)| t.owner == pane)
        .map(|(id, _)| *id)
        .collect();
    for child in children {
        server.close(child);
    }
    server.filetrees.detached_chromiums.remove(&pane);
    let Some(tree) = server.filetrees.active.remove(&pane) else {
        return;
    };
    if let Some(owner) = server.sessions.get_mut(&tree.owner) {
        owner.effect_holds.remove(HOLD_ID);
    }
    // The viewer becomes independent. Its RPC identity stays usable even if
    // both the filetree and original shell are gone.
    if let Some(chromium) = tree.chromium.and_then(|id| server.chromiums.get_mut(&id)) {
        chromium.owner = chromium.id;
        server
            .filetrees
            .detached_chromiums
            .insert(tree.owner, chromium.id);
    }
    if let Some(session) = server.sessions.get(&pane) {
        let name = session.workspace.clone();
        let tab = session.tab;
        let state = server.workspace_state.snapshot(&name);
        if let Some(mut layout) = state.layout.tabs.get(&tab).cloned() {
            let key = format!("%{pane}");
            if let Some(rect) = layout.arrange(state.tabs[&tab].area).get(&key) {
                server
                    .filetrees
                    .sizes
                    .insert(size_key(&tree.cwd, mode(&layout, &key)), [rect[2], rect[3]]);
                let path = server.descriptor.with_extension("filetree-sizes.json");
                if let Ok(bytes) = serde_json::to_vec(&server.filetrees.sizes) {
                    let _ = fs::write(path, bytes);
                }
            }
            layout.focused = format!("%{}", tree.owner);
            let _ = server.workspace_state.edit(
                &name,
                state.revision,
                Edit::Tab {
                    tab,
                    layout,
                    settings: None,
                },
            );
        }
    }
    let _ = fs::remove_file(tree.directory.join("cwd.json"));
    let _ = fs::remove_file(&tree.address);
    let _ = fs::remove_dir_all(sandbox(&tree.directory));
    if let Some((editor, _)) = tree.editor {
        server
            .filetrees
            .detached_editors
            .insert(editor, tree.directory);
    } else {
        let _ = fs::remove_dir(&tree.directory);
    }
}

pub fn poll(server: &mut Server) {
    for (id, tree) in &mut server.filetrees.active {
        let Some(session) = server.sessions.get(&tree.owner) else {
            continue;
        };
        // Capture each mode before a later mode change or close. Only arrange
        // on workspace edits; shell output does not trigger layout work.
        if tree.layout_revision != server.workspace_state.revision(&session.workspace) {
            let state = server.workspace_state.snapshot(&session.workspace);
            tree.layout_revision = state.revision;
            if let Some(tab) = server.sessions.get(id).map(|s| s.tab) {
                if let Some(mut layout) = state.layout.tabs.get(&tab).cloned() {
                    let key = format!("%{id}");
                    if let Some(rect) = layout.arrange(state.tabs[&tab].area).get(&key) {
                        server
                            .filetrees
                            .sizes
                            .insert(size_key(&tree.cwd, mode(&layout, &key)), [rect[2], rect[3]]);
                    }
                }
            }
        }
        let report = session.cwd_report();
        let next = if report != tree.report {
            tree.report = report.clone();
            directory_from_report(&report)
        } else if report.is_empty() && tree.probe.elapsed() >= Duration::from_secs(1) {
            tree.probe = Instant::now();
            session.cwd()
        } else {
            None
        };
        if let Some(cwd) = next.filter(|p| p.is_dir() && *p != tree.cwd) {
            tree.layout_revision = u64::MAX;
            let previous = std::mem::replace(&mut tree.cwd, cwd);
            if let Err(error) = publish(tree) {
                tree.cwd = previous;
                tree.report.clear();
                eprintln!("[filetree cwd] {error}");
            }
        }
    }
}

pub(crate) fn directory_from_report(report: &str) -> Option<PathBuf> {
    let path = if let Some(uri) = report.strip_prefix("file://") {
        let slash = uri.find('/')?;
        let host = &uri[..slash];
        if !host.is_empty()
            && host != "localhost"
            && std::env::var("HOSTNAME").ok().as_deref() != Some(host)
            && std::env::var("HOST").ok().as_deref() != Some(host)
        {
            return None;
        }
        let mut bytes = Vec::new();
        let mut input = uri[slash..].bytes();
        while let Some(byte) = input.next() {
            bytes.push(if byte == b'%' {
                let a = char::from(input.next()?).to_digit(16)?;
                let b = char::from(input.next()?).to_digit(16)?;
                (a * 16 + b) as u8
            } else {
                byte
            });
        }
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStringExt;
            PathBuf::from(std::ffi::OsString::from_vec(bytes))
        }
        #[cfg(not(unix))]
        {
            PathBuf::from(String::from_utf8(bytes).ok()?.trim_start_matches('/'))
        }
    } else {
        PathBuf::from(report)
    };
    path.is_absolute().then_some(path)
}

pub fn open_file(server: &mut Server, caller: u64, params: &Value) -> Result<Value, Error> {
    let tree = server
        .filetrees
        .active
        .get(&caller)
        .ok_or("File open requires a connected filetree")?;
    let path = params["path"]
        .as_str()
        .filter(|p| Path::new(p).is_absolute() && Path::new(p).is_file())
        .ok_or("Expected an existing absolute file path")?;
    if chromium_file(Path::new(path)) {
        let profile = crate::chromium::Profile::configured(&server.settings.chromium);
        return open_in_chromium(server, caller, path, None, false, profile, false);
    }
    if let Some((id, address)) = &tree.editor {
        if server.sessions.contains_key(id) {
            crate::regroup::validate_association(server, caller, *id)?;
            let result = json!({"pane":format!("%{id}"),"kind":"terminal","address":address,"created":false});
            let session = &server.sessions[id];
            let name = session.workspace.clone();
            let tab = session.tab;
            let state = server.workspace_state.snapshot(&name);
            let mut layout = state.layout.tabs[&tab].clone();
            layout.focused = format!("%{id}");
            server.workspace_state.edit(
                &name,
                state.revision,
                Edit::Tab {
                    tab,
                    layout,
                    settings: None,
                },
            )?;
            return Ok(result);
        }
    }
    let source = tree.owner;
    let launch = tree.launch.clone();
    let navigator = tree.navigator;
    let address = rpc_address(&tree.directory, "v", cfg!(windows));
    let name = server.sessions[&source].workspace.clone();
    let tab = server.sessions[&source].tab;
    workspace::sync(server, &name)?;
    let before = server.workspace_state.snapshot(&name);
    let mut layout = before.layout.tabs[&tab].clone();
    // The viewer is the user's own editor: their Neovim and default config.
    let (shell, mut args, env) = editor(server, &launch);
    args.extend([
        "--cmd".into(),
        navigator_command(navigator),
        "--listen".into(),
        address.to_string_lossy().into(),
        "--".into(),
        path.into(),
    ]);
    let executable = shell.clone();
    let pane = server.create_with_spawn(
        &name,
        Some(tab),
        Some(source),
        Some(crate::spawn::SpawnOptions {
            shell: Some(shell),
            login: Some(false),
            shell_integration: Some(false),
            args,
            env,
            ..Default::default()
        }),
    ).map_err(|error| command_error(error, &executable))?;
    let placed = (|| -> Result<(), Error> {
        place_viewer(
            &mut layout,
            before.tabs[&tab].area,
            &format!("%{source}"),
            &format!("%{pane}"),
            false,
        )?;
        workspace::sync(server, &name)?;
        let state = server.workspace_state.snapshot(&name);
        server.workspace_state.edit(
            &name,
            state.revision,
            Edit::Tab {
                tab,
                layout,
                settings: None,
            },
        )?;
        workspace::sync_terminal_geometry(server, &name)
    })();
    if let Err(error) = placed {
        server.close(pane);
        return Err(error);
    }
    server.sessions.get_mut(&pane).unwrap().builtin_title = "File viewer".into();
    server.filetrees.active.get_mut(&caller).unwrap().editor = Some((pane, address.clone()));
    Ok(json!({"pane":format!("%{pane}"),"kind":"terminal","address":address,"created":true}))
}

/// A custom filetree's Neovim also edits files. With the bundled filetree the
/// viewer is `nvim` from the server PATH, or the bundled binary with `--clean`
/// when the server has no Neovim of its own.
fn editor(server: &Server, launch: &Launch) -> (String, Vec<String>, BTreeMap<String, String>) {
    use crate::spawn::Prepare;
    let user = BTreeMap::from([("NVIM_APPNAME".to_owned(), "nvim".to_owned())]);
    match launch {
        Launch::Custom { command, .. } => (command[0].clone(), Vec::new(), user),
        Launch::Bundled(runtime) => {
            let installed = crate::spawn::SpawnOptions { shell: Some("nvim".into()), ..Default::default() };
            if server.settings.spawn_options(Some(&installed)).prepare(&server.shell, None).is_ok() {
                return ("nvim".into(), Vec::new(), user);
            }
            let env = [("VIMRUNTIME".to_owned(), runtime.vimruntime.to_string_lossy().into_owned())].into();
            (runtime.nvim.to_string_lossy().into_owned(), vec!["--clean".into()], env)
        }
    }
}

fn chromium_file(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str(),
        "pdf"
            | "html"
            | "htm"
            | "xhtml"
            | "xht"
            | "xhtm"
            | "svg"
            | "svgz"
            | "png"
            | "apng"
            | "jpg"
            | "jpeg"
            | "jpe"
            | "jfif"
            | "pjpeg"
            | "pjp"
            | "gif"
            | "webp"
            | "avif"
            | "jxl"
            | "bmp"
            | "ico"
            | "webm"
            | "mov"
            | "qt"
            | "mkv"
            | "mp4"
            | "m4v"
            | "ogv"
            | "ogm"
            | "mp3"
            | "m4a"
            | "aac"
            | "ogg"
            | "oga"
            | "weba"
            | "mka"
            | "opus"
            | "wav"
            | "flac"
    )
}

/// `chromium open` from a terminal. A pane it creates opens beside the caller,
/// like `chromium new`; filetree previews split above their owner instead.
pub fn open_chromium_file(
    server: &mut Server,
    caller: u64,
    path: &str,
    target: Option<u64>,
    force_new: bool,
    profile: crate::chromium::Profile,
) -> Result<Value, Error> {
    open_in_chromium(server, caller, path, target, force_new, profile, true)
}

fn open_in_chromium(
    server: &mut Server,
    caller: u64,
    path: &str,
    target: Option<u64>,
    force_new: bool,
    // Used only when a new chromium pane is created.
    profile: crate::chromium::Profile,
    beside: bool,
) -> Result<Value, Error> {
    if force_new && target.is_some() {
        return Err("--new cannot be combined with --target".into());
    }
    let path = Path::new(path);
    if !path.is_absolute() || !path.is_file() {
        return Err("Expected an existing absolute file path".into());
    }
    let url = url::Url::from_file_path(path)
        .map_err(|_| "Cannot convert path to file URL")?
        .to_string();
    let source = owner(server, caller);
    let name = server
        .sessions
        .get(&source)
        .ok_or("File open requires a terminal pane")?
        .workspace
        .clone();
    let tree_id = server
        .filetrees
        .active
        .iter()
        .find_map(|(id, tree)| (tree.owner == source).then_some(*id));
    let associated = tree_id
        .and_then(|id| server.filetrees.active[&id].chromium)
        .or_else(|| server.filetrees.detached_chromiums.get(&source).copied());
    let reusable = |id: &u64| {
        server
            .chromiums
            .get(id)
            .is_some_and(|b| b.workspace == name && owner(server, b.owner) == source)
    };
    let existing = if let Some(id) = target {
        let chromium = server
            .chromiums
            .get(&id)
            .ok_or_else(|| api::error("invalid_target", "Target must be a Chromium pane"))?;
        api::chromium_owner(
            source,
            owner(server, chromium.owner),
            chromium.workspace == name,
        )?;
        Some(id)
    } else if force_new {
        None
    } else {
        associated
            .filter(reusable)
            .or_else(|| server.chromiums.keys().copied().find(reusable))
    };
    let controller = tree_id.unwrap_or(source);
    if let Some(id) = existing {
        crate::regroup::validate_association(server, controller, id)?;
    }
    let (name, tab) = existing
        .map(|id| {
            let chromium = &server.chromiums[&id];
            (chromium.workspace.clone(), chromium.tab)
        })
        .unwrap_or_else(|| {
            let session = &server.sessions[&source];
            (session.workspace.clone(), session.tab)
        });
    workspace::sync(server, &name)?;
    let before = server.workspace_state.snapshot(&name);
    let mut layout = before.layout.tabs[&tab].clone();
    let pane = if let Some(id) = existing {
        // Ticket zero is reserved for internal commands with no RPC waiter.
        server.chromiums[&id].command(0, "tab-new".into(), json!({"url":url}))?;
        layout.focused = format!("%{id}");
        id
    } else {
        if server.chromiums.len() >= 32 {
            return Err("Server chromium limit reached".into());
        }
        let id = server.next;
        // Validate placement before starting a new process.
        place_viewer(
            &mut layout,
            before.tabs[&tab].area,
            &format!("%{source}"),
            &format!("%{id}"),
            beside,
        )?;
        let chromium = crate::chromium::Chromium::new(
            id,
            controller,
            name.clone(),
            tab,
            url,
            profile,
            &server.settings.chromium,
            std::sync::Arc::clone(&server.resources),
        )?;
        server.next += 1;
        server.chromiums.insert(id, chromium);
        id
    };
    let placed = (|| -> Result<(), Error> {
        workspace::sync(server, &name)?;
        let state = server.workspace_state.snapshot(&name);
        server.workspace_state.edit(
            &name,
            state.revision,
            Edit::Tab {
                tab,
                layout,
                settings: None,
            },
        )?;
        workspace::sync_terminal_geometry(server, &name)
    })();
    if let Err(error) = placed {
        if existing.is_none() {
            server.retire_chromium(pane);
        }
        return Err(error);
    }
    if let Some(tree) = tree_id {
        server.filetrees.active.get_mut(&tree).unwrap().chromium = Some(pane);
        server.filetrees.detached_chromiums.remove(&source);
    } else {
        server.filetrees.detached_chromiums.insert(source, pane);
    }
    server.chromiums.get_mut(&pane).unwrap().owner = controller;
    Ok(
        json!({"pane":format!("%{pane}"),"chromium":format!("%{pane}"),"kind":"chromium","created":existing.is_none()}),
    )
}

/// Split a viewer above its source, or beside it (to the right) when `beside`.
fn place_viewer(
    layout: &mut TabLayout,
    area: [f32; 4],
    source: &str,
    viewer: &str,
    beside: bool,
) -> Result<(), Error> {
    let rects = layout.arrange(area);
    let rect = *rects.get(source).ok_or("Source pane is hidden")?;
    let tiles = layout.tiles.clone();
    let (axis, before) = if beside { (Axis::Horizontal, false) } else { (Axis::Vertical, true) };
    layout.add_neighbor(source, viewer, axis, before, area)?;
    if mode(layout, viewer) == "tiled" {
        layout.tiles = tiles.map(|node| node.join(source, viewer, axis, before));
    }
    layout
        .windows
        .iter_mut()
        .find(|w| w.key == viewer)
        .unwrap()
        .rect = if beside {
        [rect[0] + rect[2] - 40., rect[1], rect[2], rect[3]]
    } else {
        [rect[0], rect[1] - rect[3] + 40., rect[2], rect[3]]
    };
    layout.focused = viewer.into();
    layout.physics_anchor = Some(source.into());
    Ok(())
}

pub fn send(server: &mut Server, caller: u64, params: &Value) -> Result<Value, Error> {
    let source = server
        .sessions
        .get(&caller)
        .ok_or("Calling terminal closed")?;
    let name = source.workspace.clone();
    let tab = source.tab;
    workspace::sync(server, &name)?;
    let state = server.workspace_state.snapshot(&name);
    let target = params["target"].as_str().unwrap_or("connected");
    let target = if target == "connected" {
        format!(
            "%{}",
            server
                .filetrees
                .active
                .get(&caller)
                .ok_or("Choose a target pane first")?
                .owner
        )
    } else if target.starts_with('.') {
        format!("@{tab}{target}")
    } else {
        target.into()
    };
    let key = crate::terminal_api::resolve(&state, &target).ok_or("Unknown target pane")?;
    let pane = graffitty_workspace_core::pane_id::parse(&key).ok_or("Invalid target pane")?;
    let text = params["text"]
        .as_str()
        .filter(|s| s.len() <= 1024 * 1024 && !s.contains('\0'))
        .ok_or("Text must fit in 1 MiB without NUL")?;
    let enter = params
        .get("enter")
        .map_or(Ok(false), |v| v.as_bool().ok_or("enter must be a boolean"))?;
    let session = server
        .sessions
        .get(&pane)
        .filter(|s| s.workspace == name)
        .ok_or("Target is not a terminal in this session")?;
    session.send_paste(text, enter)?;
    Ok(json!({"pane":key,"bytes":text.len(),"enter":enter}))
}

#[cfg(test)]
mod tests {
    use super::*;
    use graffitty_workspace_core::tiling::Window;
    #[test]
    fn chromium_file_routes_media_and_keeps_editable_files_in_neovim() {
        for name in ["clip.MOV", "clip.qt", "clip.mkv", "clip.ogm", "song.weba", "song.mka",
                     "image.apng", "image.jfif", "image.svgz", "page.xhtml"] {
            assert!(chromium_file(Path::new(name)), "{name}");
        }
        for name in ["clip.mov.rs", "notes.md", "config.toml", "README"] {
            assert!(!chromium_file(Path::new(name)), "{name}");
        }
    }
    #[test]
    fn windows_neovim_listens_on_a_named_pipe() {
        let directory = Path::new("C:/Temp/graffitty-0123abcd");
        assert_eq!(rpc_address(directory, "t", true), PathBuf::from(r"\\.\pipe\graffitty-0123abcd-t"));
        assert_eq!(rpc_address(directory, "v", false), directory.join("v"));
    }
    #[test]
    fn missing_custom_command_explains_the_setting_and_bundled_default() {
        for executable in ["nvim", "/missing/custom/nvim"] {
            let error = command_error(format!("Shell is not an executable file: {executable}").into(), executable).to_string();
            for expected in [executable, "server.toml", "[filetree] command", "bundled filetree"] {
                assert!(error.contains(expected), "{expected}: {error}");
            }
        }
        assert_eq!(command_error("Working directory does not exist: /gone".into(), "nvim").to_string(), "Working directory does not exist: /gone");
    }
    #[test]
    fn runtime_manifest_paths_stay_inside_the_bundle() {
        let root = std::env::temp_dir().join(format!("graffitty-runtime-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(root.join("nvim/bin")).unwrap();
        fs::create_dir_all(root.join("nvim/share/nvim/runtime")).unwrap();
        fs::write(root.join("nvim/bin/nvim"), "").unwrap();
        fs::write(root.join("init.lua"), "").unwrap();
        let write = |nvim: &str| fs::write(root.join("manifest.json"),
            json!({"nvim": nvim, "vimruntime": "nvim/share/nvim/runtime"}).to_string()).unwrap();
        write("nvim/bin/nvim");
        let runtime = Runtime::open(root.clone()).unwrap();
        assert_eq!(runtime.nvim, root.join("nvim/bin/nvim"));
        for escape in ["../nvim", "/usr/bin/nvim", "nvim/../../nvim"] {
            write(escape);
            assert!(Runtime::open(root.clone()).is_err(), "{escape}");
        }
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn encoded_paths_and_foreign_hosts() {
        assert_eq!(
            directory_from_report("file://localhost/tmp/a%20%25%CE%A9"),
            Some(PathBuf::from("/tmp/a %Ω"))
        );
        assert!(directory_from_report("file://foreign-host.invalid/tmp").is_none());
        assert!(directory_from_report("relative").is_none());
    }
    #[test]
    fn tree_split_preserves_other_panes_and_float_flags() {
        let mut layout = TabLayout {
            enabled: true,
            windows: vec![
                Window::new("%1", [0., 0., 800., 600.]),
                Window::new("%2", [0., 0., 800., 600.]),
            ],
            ..Default::default()
        };
        let area = [0., 0., 1600., 800.];
        let before = layout.arrange(area);
        place(&mut layout, area, "%1", "%3", [250., 600.], false).unwrap();
        let after = layout.arrange(area);
        assert_eq!(before["%2"], after["%2"]);
        assert!((after["%3"][2] - 250.).abs() < 1.);
        assert_eq!(layout.focused, "%1");
        layout.remove("%3");
        assert_eq!(layout.arrange(area), before);
        layout.windows[0].stashed = true;
        place(&mut layout, area, "%1", "%4", [280., 450.], true).unwrap();
        assert!(layout.window("%4").unwrap().stashed);
        assert_eq!(&layout.window("%4").unwrap().rect[2..], &[280., 450.]);
    }
    #[test]
    fn viewer_splits_above_or_beside_owner_without_changing_filetree() {
        let area = [0., 0., 1200., 800.];
        for beside in [false, true] {
            let mut layout = TabLayout {
                enabled: true,
                windows: vec![Window::new("%1", area)],
                ..Default::default()
            };
            place(&mut layout, area, "%1", "%2", [300., 800.], false).unwrap();
            let before = layout.arrange(area);
            place_viewer(&mut layout, area, "%1", "%3", beside).unwrap();
            let after = layout.arrange(area);
            assert_eq!(after["%2"], before["%2"]);
            if beside {
                assert_eq!(after["%3"][1], after["%1"][1]);
                assert!(after["%1"][0] + after["%1"][2] <= after["%3"][0]);
            } else {
                assert_eq!(after["%3"][0], after["%1"][0]);
                assert!(after["%3"][1] + after["%3"][3] <= after["%1"][1]);
            }
            layout.remove("%3");
            assert_eq!(layout.arrange(area), before);
        }
    }
}
