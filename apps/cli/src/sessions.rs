//! Native checkpoint storage and conservative PID-to-conversation discovery.
//! Ported from tmux-restore-agents' foreground ownership / exact-ID approach.
use crate::platform::OpenOptionsExt;
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use crate::options::CheckpointCommand;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs,
    io::{BufRead, BufReader, Read, Write},

    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn running_contexts() -> Result<Vec<(String, String)>> {
    use crate::transport::Stream;
    let mut contexts = Vec::new();
    #[cfg(unix)]
    let uid = fs::metadata(home())?.uid();
    // AgentAPI uses /tmp on Unix, which differs from macOS TMPDIR.
    let root = if cfg!(unix) { PathBuf::from("/tmp") } else { std::env::temp_dir() };
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with("graffitty-")
        {
            continue;
        }
        let meta = entry.path().symlink_metadata()?;
        if !meta.is_dir() { continue; }
        #[cfg(unix)]
        if meta.uid() != uid || meta.permissions().mode() & 0o777 != 0o700 {
            continue;
        }
        let path = entry.path().join("session.json");
        let Ok(meta) = path.symlink_metadata() else {
            continue;
        };
        if !meta.is_file()

            || meta.len() > 4096
        {
            continue;
        }
        #[cfg(unix)]
        if meta.uid() != uid || meta.permissions().mode() & 0o077 != 0 { continue; }
        let Ok(bytes) = fs::read(&path) else {
            continue;
        };
        let Ok(v) = serde_json::from_slice::<Value>(&bytes) else {
            continue;
        };
        if let (Some(socket), Some(token)) = (v["socket"].as_str(), v["token"].as_str()) {
            if (socket.starts_with("tcp://127.0.0.1:") || Path::new(socket) == entry.path().join("api.sock"))
                && Stream::connect(socket).is_ok()
            {
                contexts.push((socket.to_owned(), token.to_owned()));
            }
        }
    }
    Ok(contexts)
}

pub fn discover_agent_context(thread_id: &str) -> Result<(String, String)> {
    uuid::Uuid::parse_str(thread_id)?;
    let (endpoint, token) = crate::live_sessions::context()?;
    let response = crate::call_context("agent.context", json!({"thread_id":thread_id}),
        Duration::from_secs(30), Some((endpoint.clone(), token)));
    let result = graffitty_graph_protocol::response("agent.context", response)?;
    let token = result["token"].as_str().filter(|s| !s.is_empty())
        .ok_or("Session server returned no pane capability")?;
    Ok((endpoint, token.to_owned()))
}

pub fn discover_context() -> Result<(String, String)> {
    let mut contexts = running_contexts()?;
    if contexts.len() != 1 {
        return Err(format!(
            "Found {} running Graffitty instances; run save inside the intended window",
            contexts.len()
        )
        .into());
    }
    Ok(contexts.remove(0))
}

fn home() -> PathBuf {
    std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default()
}
fn root() -> PathBuf {
    std::env::var_os("GRAFFITTY_CHECKPOINT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("XDG_STATE_HOME")
                .map(PathBuf::from)
                .filter(|p| p.is_absolute())
                .unwrap_or_else(|| home().join(".local/state"))
                .join("graffitty/checkpoints")
        })
}
fn directory(tag: &str) -> Result<PathBuf> {
    if tag.is_empty() || tag.len() > 100 || tag.chars().any(char::is_control) {
        return Err("tag must contain 1–100 printable bytes".into());
    }
    // Hex is injective even on case-insensitive filesystems; never interpret tag as a path.
    Ok(root().join(
        tag.as_bytes()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>(),
    ))
}
fn private_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    #[cfg(windows)]
    graffitty_session_transport::local_json::restrict_directory(path)?;
    Ok(())
}
// One lock per tag coordinates CLI writers, auto-save workers and readers.
// Atomic rename prevents partial documents; it does not serialize retention.
fn lock_history(dir: &Path) -> Result<fs::File> {
    private_dir(dir)?;
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(dir.join("history.lock"))?;
    lock.lock()?;
    Ok(lock)
}
fn atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .open(&temp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(temp);
    }
    result
}
fn history(dir: &Path) -> Result<Vec<PathBuf>> {
    if !dir.exists() {
        return Ok(vec![]);
    }
    let mut paths = fs::read_dir(dir)?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .starts_with("checkpoint-")
                && p.extension().is_some_and(|e| e == "json")
        })
        .collect::<Vec<_>>();
    paths.sort();
    paths.reverse();
    Ok(paths)
}
fn read(path: &Path) -> Result<Value> {
    let bytes = fs::read(path)?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err("checkpoint exceeds 4 MiB".into());
    }
    let value: Value = serde_json::from_slice(&bytes)?;
    validate(&value)?;
    Ok(value)
}
pub use crate::checkpoint::validate;
fn output(program: &str, args: &[&str]) -> Option<String> {
    output_with(program, args, &[])
}
/// Runs a provider command in an agent's own locations: a value sets a
/// variable, and None removes one the agent did not have.
fn output_with(program: &str, args: &[&str], env: &[(&str, Option<&str>)]) -> Option<String> {
    // Files, not pipes: a verbose provider cannot deadlock before the timeout.
    let path = std::env::temp_dir().join(format!("graffitty-discovery-{}", uuid::Uuid::new_v4()));
    let file = fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&path)
        .ok()?;
    let result = (|| {
        let mut command = Command::new(program);
        for (name, value) in env {
            match value {
                Some(value) => command.env(name, value),
                None => command.env_remove(name),
            };
        }
        let mut child = command
            .args(args)
            .env("LC_ALL", "C")
            .env("TZ", "UTC")
            .stdout(file)
            .stderr(Stdio::null())
            .stdin(Stdio::null())
            .spawn()
            .ok()?;
        let start = std::time::Instant::now();
        loop {
            if let Some(status) = child.try_wait().ok()? {
                if !status.success() {
                    return None;
                }
                break;
            }
            if start.elapsed() > Duration::from_secs(8) {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        if fs::metadata(&path).ok()?.len() > 4 * 1024 * 1024 {
            return None;
        }
        fs::read_to_string(&path).ok()
    })();
    let _ = fs::remove_file(path);
    result
}
#[derive(Clone)]
pub(crate) struct Process {
    pub(crate) pid: i64,
    pub(crate) parent: i64,
    pub(crate) group: i64,
    pub(crate) foreground: i64,
    pub(crate) tty: String,
    pub(crate) state: String,
    pub(crate) started: String,
    pub(crate) executable: String,
}
#[cfg(windows)]
pub(crate) fn processes() -> HashMap<i64, Process> {
    crate::platform::processes().into_iter().map(|(pid, parent, started, executable)|
        (pid, Process { pid, parent, started, executable, group: 0, foreground: 0, tty: String::new(), state: String::new() })).collect()
}
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "android"))]
pub(crate) fn processes() -> HashMap<i64, Process> {
    crate::process_inventory::processes()
}
#[cfg(all(unix, not(any(target_os = "macos", target_os = "linux", target_os = "android"))))]
pub(crate) fn processes() -> HashMap<i64, Process> {
    process_list(&output("ps", &["-ax", "-o", PROCESS_LIST_FORMAT]).unwrap_or_default())
}

/// The columns of a process list: `ps -ax -o` with this format prints one.
pub(crate) const PROCESS_LIST_FORMAT: &str = "pid=,ppid=,pgid=,tpgid=,tty=,state=,lstart=,comm=";

/// The processes in a list of `PROCESS_LIST_FORMAT` lines.
pub(crate) fn process_list(text: &str) -> HashMap<i64, Process> {
    text.lines()
        .filter_map(|line| {
            let fields: Vec<_> = line.split_whitespace().collect();
            if fields.len() < 12 {
                return None;
            }
            let p = Process {
                pid: fields[0].parse().ok()?,
                parent: fields[1].parse().ok()?,
                group: fields[2].parse().ok()?,
                foreground: fields[3].parse().ok()?,
                tty: fields[4].into(),
                state: fields[5].into(),
                started: fields[6..11].join(" "),
                executable: fields[11..].join(" "),
            };
            Some((p.pid, p))
        })
        .collect()
}
/// The agent CLI an executable runs as. Claude's native installer runs
/// `…/claude/versions/<version>`, a file named after its version.
pub(crate) fn agent_name(executable: &str) -> Option<&'static str> {
    let path = Path::new(executable);
    let stem = path.file_stem()?.to_str()?;
    if let Some(name) = ["claude", "codex", "opencode", "pi"].into_iter().find(|name| *name == stem) {
        return Some(name);
    }
    let mut parents = path.ancestors().skip(1);
    (parents.next()?.file_name()? == "versions" && parents.next()?.file_name()? == "claude").then_some("claude")
}

/// Whether a hook runs in a session hosted by the provider's background
/// daemon instead of in a terminal, and the conversation it was forked from.
/// `commands` are the hook's ancestors' command lines, nearest first.
pub(crate) fn background_session(commands: &[String]) -> Option<Option<String>> {
    if !commands.iter().any(|c| c.split_whitespace().any(|a| a == "--bg-pty-host")) {
        return None;
    }
    // The session's own process comes before its pty host: `--resume <transcript> --fork-session`.
    let parent = commands.iter().find_map(|command| {
        let args: Vec<_> = command.split_whitespace().collect();
        if args.contains(&"--bg-pty-host") || !args.contains(&"--fork-session") {
            return None;
        }
        // The transcript path may contain spaces; a bare session id has none.
        let source = command.split_once("--resume ")?.1;
        let source = source.find(".jsonl").map_or_else(|| source.split_whitespace().next().unwrap_or(""), |end| &source[..end]);
        Path::new(source).file_name().and_then(|s| s.to_str()).filter(|s| !s.is_empty()).map(str::to_owned)
    });
    Some(parent)
}

/// Command lines of a process's ancestors, nearest first.
#[cfg(unix)]
pub(crate) fn ancestor_commands(pid: i64, table: &HashMap<i64, Process>) -> Vec<String> {
    let mut commands = Vec::new();
    let mut cursor = table.get(&pid).map_or(0, |p| p.parent);
    let mut seen = HashSet::new();
    while cursor > 1 && seen.insert(cursor) && commands.len() < 8 {
        let Some(process) = table.get(&cursor) else { break };
        if let Ok(output) = std::process::Command::new("ps").args(["-o", "args=", "-p", &cursor.to_string()]).output() {
            commands.push(String::from_utf8_lossy(&output.stdout).trim().to_owned());
        }
        cursor = process.parent;
    }
    commands
}

#[cfg(not(unix))]
pub(crate) fn ancestor_commands(_: i64, _: &HashMap<i64, Process>) -> Vec<String> {
    Vec::new()
}

pub(crate) fn hook_owner<'a>(
    pid: i64,
    provider: &str,
    table: &'a HashMap<i64, Process>,
) -> Option<&'a Process> {
    // Hook runners insert shells and may detach their own process group/TTY.
    // Walk actual ancestors, never trust an inherited PID or pick an unrelated process.
    //
    // The walk ends where it would leave the terminal the agent runs in. What
    // started that terminal is not the agent of this pane, even when it is the
    // same program: an agent that launches Graffitty, or runs its tests, is an
    // ancestor of every hook inside.
    let on_terminal = |process: &Process| !process.tty.is_empty() && !process.tty.starts_with('?');
    let mut terminal: Option<&str> = None;
    let mut cursor = pid;
    let mut seen = HashSet::new();
    while cursor > 1 && seen.insert(cursor) {
        let process = table.get(&cursor)?;
        // Runner shells without a terminal are passed through; another
        // terminal is where the walk stops.
        if on_terminal(process) {
            match terminal {
                Some(tty) if process.tty != tty => return None,
                _ => terminal = Some(&process.tty),
            }
        }
        if cursor != pid
            && !process.state.contains('Z')
            && agent_name(&process.executable) == Some(provider)
        {
            return Some(process);
        }
        cursor = process.parent;
    }
    None
}

#[cfg(windows)]
pub(crate) fn foreground(pid: i64, table: &HashMap<i64, Process>) -> Option<&Process> {
    let root = table.get(&pid)?;
    let mut descendants = HashSet::from([pid]);
    loop {
        let before = descendants.len();
        for process in table.values() {
            if descendants.contains(&process.parent) && table.get(&process.parent).is_some_and(|parent| parent.started <= process.started) {
                descendants.insert(process.pid);
            }
        }
        if descendants.len() == before { break; }
    }
    let candidates: Vec<_> = table.values().filter(|p| descendants.contains(&p.pid) &&
        Path::new(&p.executable).file_stem().and_then(|s| s.to_str()).is_some_and(|s| ["claude", "codex", "opencode", "pi"].contains(&s))).collect();
    // A Codex TUI can own a same-named daemon child. Its listener is the
    // process-bound identity used by daemon inventory verification, so resolve
    // that identity before treating a same-named descendant as a package shim.
    let listeners: Vec<_> = candidates.iter().copied()
        .filter(|p| Path::new(&p.executable).file_stem().and_then(|s| s.to_str()) == Some("codex")
            && !crate::codex_discovery::listener_ports(p.pid).is_empty()).collect();
    if listeners.len() == 1 { return Some(listeners[0]); }
    if listeners.len() > 1 { return None; }
    // Package-manager shims can keep a same-named parent alive while the
    // actual native CLI runs below it. Keep the leaf of that provider chain;
    // unrelated sibling workers remain ambiguous.
    let candidates: Vec<_> = candidates.iter().copied().filter(|candidate| {
        !candidates.iter().any(|other| {
            if other.pid == candidate.pid
                || Path::new(&other.executable).file_stem() != Path::new(&candidate.executable).file_stem() {
                return false;
            }
            let mut cursor = other.parent;
            let mut seen = HashSet::new();
            while seen.insert(cursor) {
                if cursor == candidate.pid { return true; }
                let Some(parent) = table.get(&cursor) else { break };
                cursor = parent.parent;
            }
            false
        })
    }).collect();
    let _ = root;
    if candidates.len() == 1 { return Some(candidates[0]); }
    // Windows package-manager launchers and detached daemon children can also
    // be named codex.exe. The frontend's TCP listener identifies the process
    // to verify against the daemon inventory; never guess between listeners.
    let listeners: Vec<_> = candidates.iter().copied()
        .filter(|p| !crate::codex_discovery::listener_ports(p.pid).is_empty()).collect();
    if listeners.len() == 1 { Some(listeners[0]) } else { None }
}
#[cfg(unix)]
pub(crate) fn foreground(pid: i64, table: &HashMap<i64, Process>) -> Option<&Process> {
    let shell = table.get(&pid)?;
    if shell.foreground <= 0 || ["?", "??", "-"].contains(&shell.tty.as_str()) {
        return None;
    }
    let mut descendants = HashSet::from([pid]);
    loop {
        let before = descendants.len();
        for p in table.values() {
            if descendants.contains(&p.parent) {
                descendants.insert(p.pid);
            }
        }
        if descendants.len() == before {
            break;
        }
    }
    let candidates: Vec<_> = table
        .values()
        .filter(|p| {
            descendants.contains(&p.pid)
                && p.group == shell.foreground
                && p.tty == shell.tty
                && !p.state.contains('Z')
                && agent_name(&p.executable).is_some()
        })
        .collect();
    if candidates.len() == 1 {
        Some(candidates[0])
    } else {
        None
    }
}
fn canonical_id(v: &Value) -> Option<String> {
    let s = v.as_str()?;
    let id = uuid::Uuid::parse_str(s).ok()?.hyphenated().to_string();
    (id == s).then_some(id)
}
pub(crate) fn open_paths(pid: i64) -> Vec<PathBuf> {
    let proc = PathBuf::from(format!("/proc/{pid}/fd"));
    if let Ok(entries) = fs::read_dir(proc) {
        return entries
            .filter_map(|e| fs::read_link(e.ok()?.path()).ok())
            .collect();
    }
    output("lsof", &["-n", "-P", "-Fn", "-p", &pid.to_string()])
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.strip_prefix("n/").map(|p| PathBuf::from(format!("/{p}"))))
        .collect()
}
/// The provider locations an agent process was started with, read from its
/// own environment: a shell alias can give each agent its own account.
///
/// Where the OS withholds that, discovery searches this helper's locations
/// instead, so a resume still reuses the ones its conversation was found in.
fn locations(p: &Process, kind: &str) -> BTreeMap<String, String> {
    let names = graffitty_workspace_core::checkpoint::agent_locations(kind);
    u32::try_from(p.pid)
        .ok()
        .and_then(|pid| graffitty_platform::process_env::variables(pid, names))
        .unwrap_or_else(|| {
            names.iter().filter_map(|name| Some((name.to_string(), std::env::var(name).ok()?))).collect()
        })
}
fn agent(p: &Process, claude: &mut HashMap<BTreeMap<String, String>, Option<Value>>) -> Value {
    let kind = agent_name(&p.executable).unwrap_or_default();
    let mut env = locations(p, kind);
    let mut id = None;
    if kind == "claude" {
        // `claude agents` lists only the sessions of its own configuration.
        let records = claude.entry(env.clone()).or_insert_with(|| {
            let variables: Vec<_> = graffitty_workspace_core::checkpoint::agent_locations(kind)
                .iter()
                .map(|name| (*name, env.get(*name).map(String::as_str)))
                .collect();
            output_with("claude", &["agents", "--json"], &variables)
                .and_then(|s| serde_json::from_str(&s).ok())
        });
        let matches: Vec<_> = records
            .as_ref()
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|r| r["pid"] == p.pid && r["kind"] == "interactive")
            .collect();
        if matches.len() == 1 {
            id = canonical_id(&matches[0]["sessionId"]);
        } else if matches.is_empty() {
            let config = env
                .get("CLAUDE_CONFIG_DIR")
                .filter(|dir| !dir.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home().join(".claude"));
            let path = config.join(format!("sessions/{}.json", p.pid));
            if let Ok(bytes) = fs::read(path) {
                if bytes.len() <= 1024 * 1024 {
                    if let Ok(r) = serde_json::from_slice::<Value>(&bytes) {
                        if r["pid"] == p.pid
                            && r["kind"] == "interactive"
                            && r["entrypoint"] == "cli"
                            && r["procStart"]
                                .as_str()
                                .unwrap_or("")
                                .split_whitespace()
                                .collect::<Vec<_>>()
                                .join(" ")
                                == p.started
                        {
                            id = canonical_id(&r["sessionId"]);
                        }
                    }
                }
            }
        }
    } else if kind == "codex" {
        let mut ids = HashSet::new();
        let mut homes = HashSet::new();
        let mut invalid = false;
        for path in open_paths(p.pid) {
            let name = path.file_name().unwrap_or_default().to_string_lossy();
            if !name.starts_with("rollout-") || !name.ends_with(".jsonl") {
                continue;
            }
            let Some(root) = path
                .ancestors()
                .find(|p| p.file_name().is_some_and(|n| n == "sessions"))
                .and_then(Path::parent)
            else {
                continue;
            };
            let record = (|| -> Option<Value> {
                if path.symlink_metadata().ok()?.file_type().is_symlink() {
                    return None;
                }
                let mut line = String::new();
                BufReader::new(fs::File::open(&path).ok()?)
                    .take(1024 * 1024 + 1)
                    .read_line(&mut line)
                    .ok()?;
                if line.len() > 1024 * 1024 {
                    return None;
                }
                serde_json::from_str(&line).ok()
            })();
            if let Some(r) = record.filter(|r| r["type"] == "session_meta") {
                let thread = canonical_id(&r["payload"]["id"]);
                let session = canonical_id(&r["payload"]["session_id"]);
                if thread.is_some_and(|t| name.ends_with(&format!("-{t}.jsonl")))
                    && session.is_some()
                {
                    ids.insert(session.unwrap());
                    homes.insert(root.to_path_buf());
                } else {
                    invalid = true;
                }
            } else {
                invalid = true;
            }
        }
        if !invalid && ids.len() == 1 && homes.len() == 1 {
            id = ids.into_iter().next();
            // The rollout proves which home holds the conversation. Keep the
            // process's own spelling of it unless that points elsewhere.
            let proven = homes.into_iter().next().unwrap();
            let declared = env
                .get("CODEX_HOME")
                .filter(|dir| !dir.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| home().join(".codex"));
            if fs::canonicalize(declared).ok() != fs::canonicalize(&proven).ok() {
                env.insert("CODEX_HOME".into(), proven.to_string_lossy().into_owned());
            }
        }
    }
    json!({"kind":kind,"session_id":id,"executable":p.executable,"env":env,"pid":p.pid,"started":p.started})
}
fn enrich(v: &mut Value, table: HashMap<i64, Process>) -> Result<()> {
    let mut claude = HashMap::new();
    for window in v["windows"].as_array_mut().unwrap() {
        for pane in window["panes"].as_array_mut().unwrap() {
            let pid = pane["pid"].as_i64().unwrap_or(-1);
            if !table.contains_key(&pid) {
                return Err(format!(
                    "pane {} shell is no longer running; checkpoint not written",
                    pane["id"]
                )
                .into());
            }
            pane.as_object_mut().unwrap().remove("agent");
            // A node that exited since the server's capture cannot relaunch.
            if pane["node"]["pid"].as_i64().is_some_and(|pid| !table.contains_key(&pid)) {
                pane.as_object_mut().unwrap().remove("node");
            }
            if pane.get("filetree").is_some() { continue; }
            // Opted-in nodes, including Pi and OpenCode, declare their own
            // relaunch. Claude and Codex cannot, so discovery finds them.
            if pane.get("node").is_none() {
                if let Some(p) = foreground(pid, &table).filter(|p| {
                    matches!(agent_name(&p.executable), Some("claude" | "codex"))
                }) {
                    pane["agent"] = agent(p, &mut claude);
                }
            }
            // OSC 7 is optional; use the pane shell's OS cwd if available.
            if let Some(cwd)=u32::try_from(pid).ok().and_then(crate::process_cwd::for_pid) {
                pane["cwd"]=json!(cwd.to_str().ok_or("Shell working directory is not valid Unicode")?);
            } else if let Some(files)=output("lsof",&["-a","-p",&pid.to_string(),"-d","cwd","-Fn"]) {
                // Older platforms can still use lsof for simple paths. Never
                // overwrite a valid OSC directory with an escaped non-path.
                if let Some(cwd)=files.lines().find_map(|line|line.strip_prefix('n')).filter(|path|Path::new(path).is_dir()) {
                    pane["cwd"]=json!(cwd);
                }
            }
        }
    }
    Ok(())
}

fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
/// What a restored pane runs before it continues as the user's shell: a
/// resumed agent or a relaunched node, with its own directory and variables.
struct Relaunch {
    command: Vec<String>,
    cwd: Option<String>,
    /// A value to set, or None to remove a variable the program did not have.
    env: Vec<(String, Option<String>)>,
}
impl Relaunch {
    fn node(node: &Value, state_path: &Path) -> Result<Self> {
        let mut command: Vec<String> = node["command"].as_array().unwrap().iter()
            .map(|arg| arg.as_str().unwrap().to_owned()).collect();
        // A bare `gft` is this CLI, as built-in nodes declare themselves.
        if command[0] == "gft" {
            command[0] = std::env::current_exe()?.to_string_lossy().into_owned();
        }
        let mut env: Vec<_> = node["env"].as_object().into_iter().flatten()
            .map(|(name, value)| (name.clone(), value.as_str().map(str::to_owned))).collect();
        if let Some(state) = node.get("state") {
            atomic(state_path, &serde_json::to_vec(state)?, 0o600)?;
            env.push(("GRAFFITTY_NODE_STATE".into(), Some(state_path.to_string_lossy().into_owned())));
        }
        Ok(Self { command, cwd: node["cwd"].as_str().map(str::to_owned), env })
    }
    /// Resumes a discovered conversation in the provider locations its agent
    /// had, removing any the restoring environment adds.
    fn agent(kind: &str, executable: &str, id: String, agent: &Value) -> Self {
        let env = graffitty_workspace_core::checkpoint::agent_locations(kind).iter()
            .map(|name| (name.to_string(), agent["env"][name].as_str().map(str::to_owned))).collect();
        let resume = if kind == "codex" { "resume" } else { "--resume" };
        Self { command: vec![executable.into(), resume.into(), id], cwd: None, env }
    }
    /// The variables and directory belong to the relaunched program only;
    /// the shell that follows keeps the pane's own.
    fn sh(&self) -> String {
        let mut script = String::from("#!/bin/sh\n(\n");
        if let Some(cwd) = &self.cwd {
            script += &format!("cd -- {} 2>/dev/null\n", quote(cwd));
        }
        for (name, value) in &self.env {
            script += &match value {
                Some(value) => format!("export {name}={}\n", quote(value)),
                None => format!("unset {name}\n"),
            };
        }
        let command: Vec<_> = self.command.iter().map(|arg| quote(arg)).collect();
        script += &format!("exec {}\n)\nexec {} -l\n", command.join(" "),
            quote(&std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into())));
        script
    }
    /// PowerShell runs this with -NoExit and continues as the pane's shell,
    /// so it restores the directory and variables it changed.
    fn powershell(&self) -> String {
        let quote = |text: &str| format!("'{}'", text.replace('\'', "''"));
        let names: Vec<_> = self.env.iter().map(|(name, _)| quote(name)).collect();
        let mut script = format!("$saved = @{{}}\nforeach ($name in @({})) {{ $saved[$name] = [Environment]::GetEnvironmentVariable($name) }}\n", names.join(", "));
        for (name, value) in &self.env {
            let value = value.as_deref().map_or("$null".into(), quote);
            script += &format!("[Environment]::SetEnvironmentVariable({}, {value})\n", quote(name));
        }
        if let Some(cwd) = &self.cwd {
            script += &format!("Push-Location -LiteralPath {} -ErrorAction SilentlyContinue\n", quote(cwd));
        }
        let command: Vec<_> = self.command.iter().map(|arg| quote(arg)).collect();
        script += &format!("try {{ & {} }} catch {{ Write-Host $_ }} finally {{\n", command.join(" "));
        if self.cwd.is_some() {
            script += "    Pop-Location -ErrorAction SilentlyContinue\n";
        }
        script += "    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }\n}\n";
        script
    }
    /// Writes the script and returns the pane's program and arguments. Windows
    /// cannot run a script file as a pane's program, so PowerShell runs it.
    fn write(&self, run: &Path, pane: &Value, windows: bool) -> Result<(String, Vec<String>)> {
        if windows {
            let path = run.join(format!("pane-{pane}.ps1"));
            atomic(&path, self.powershell().as_bytes(), 0o600)?;
            let path_list = std::env::var_os("PATH").unwrap_or_default();
            let pwsh = std::env::split_paths(&path_list).any(|dir| dir.join("pwsh.exe").is_file());
            let program = if pwsh { "pwsh.exe" } else { "powershell.exe" };
            Ok((program.into(), ["-NoLogo", "-NoExit", "-ExecutionPolicy", "Bypass", "-File"].into_iter()
                .map(str::to_owned).chain([path.to_string_lossy().into_owned()]).collect()))
        } else {
            let path = run.join(format!("pane-{pane}.sh"));
            atomic(&path, self.sh().as_bytes(), 0o700)?;
            Ok((path.to_string_lossy().into_owned(), vec![]))
        }
    }
}
/// Only checkpoints from this history relaunch node commands or resume
/// agents: a file from elsewhere is data, so those panes come back as shells.
fn prepare(mut v: Value, dir: &Path, trusted: bool) -> Result<PathBuf> {
    let run = dir.join(format!("restore-{}", uuid::Uuid::new_v4()));
    private_dir(&run)?;
    for w in v["windows"].as_array_mut().unwrap() {
        for p in w["panes"].as_array_mut().unwrap() {
            // Ignore executable launch fields in checkpoints; regenerate only supported resumes.
            p.as_object_mut().unwrap().remove("restore_shell");
            p.as_object_mut().unwrap().remove("restore_args");
            let original = p["cwd"].as_str().unwrap();
            let mut cwd = PathBuf::from(original);
            while !cwd.is_dir() && cwd.pop() {}
            if !cwd.is_absolute() || cwd.parent().is_none() {
                cwd = home();
            }
            if cwd.to_string_lossy() != original {
                eprintln!("pane {}: {} → {}", p["id"], original, cwd.display());
            }
            p["cwd"] = json!(cwd);
            if let Some(tree) = p.get_mut("filetree") {
                let original = tree["root"].as_str().unwrap();
                let mut root = PathBuf::from(original);
                while !root.is_dir() && root.pop() {}
                if !root.is_absolute() { root = home(); }
                if root.to_string_lossy() != original {
                    eprintln!("filetree root: {} → {}", original, root.display());
                }
                tree["root"] = json!(root);
                p.as_object_mut().unwrap().remove("agent");
                continue;
            }
            if let Some(node) = p.get("node").filter(|node| !node.is_null()).cloned() {
                if trusted {
                    let relaunch = Relaunch::node(&node, &run.join(format!("pane-{}-state.json", p["id"])))?;
                    let (program, args) = relaunch.write(&run, &p["id"], cfg!(windows))?;
                    p["restore_shell"] = json!(program);
                    if !args.is_empty() {
                        p["restore_args"] = json!(args);
                    }
                } else {
                    let command: Vec<_> = node["command"].as_array().unwrap().iter().filter_map(Value::as_str).map(quote).collect();
                    eprintln!("pane {}: not relaunching {} from a checkpoint outside your checkpoint history", p["id"], command.join(" "));
                    p.as_object_mut().unwrap().remove("node");
                }
                continue;
            }
            let a = &p["agent"].clone();
            let id = graffitty_workspace_core::checkpoint::agent_id(&a["session_id"]);
            if let Some(id) = id.as_ref().filter(|_| !trusted) {
                // A resume runs the saved executable, so it follows the same rule.
                eprintln!("pane {}: not resuming {} conversation {id} from a checkpoint outside your checkpoint history",
                    p["id"], a["kind"].as_str().unwrap_or("agent"));
                p.as_object_mut().unwrap().remove("agent");
            } else if let Some(id) = id {
                let kind = a["kind"].as_str().unwrap();
                let executable = a["executable"]
                    .as_str()
                    .filter(|s| {
                        Path::new(s).is_absolute()
                            && Path::new(s).file_stem().is_some_and(|n| n == kind)
                    })
                    .unwrap_or(kind);
                let relaunch = Relaunch::agent(kind, executable, id, a);
                let (program, args) = relaunch.write(&run, &p["id"], cfg!(windows))?;
                p["restore_shell"] = json!(program);
                if !args.is_empty() {
                    p["restore_args"] = json!(args);
                }
            } else if !a.is_null() {
                eprintln!(
                    "pane {}: agent session unresolved; restoring a shell",
                    p["id"]
                );
            }
        }
    }
    // Panes of a checkpoint from this history ask for the IDs they had.
    v["keep_ids"] = json!(trusted);
    v["receipt"] = json!(run.join("ready.json"));
    let path = run.join("layout.json");
    atomic(&path, &serde_json::to_vec(&v)?, 0o600)?;
    Ok(path)
}
/// What a rolling save does about the newest entry of its history.
#[derive(Debug, PartialEq)]
enum Rolling {
    /// Nothing changed since the newest entry: no write.
    Unchanged,
    /// The newest entry is closer than the spacing to the one before it, so
    /// it is only the latest state and the new save takes its place.
    Replace,
    Append,
}
fn rolling(new: &Value, newest: Option<&Value>, previous: Option<&Value>, spacing: u64) -> Rolling {
    let state = |v: &Value| {
        let mut v = v.clone();
        for field in ["saved_at", "tag"] {
            v.as_object_mut().unwrap().remove(field);
        }
        v
    };
    let Some(newest) = newest else { return Rolling::Append };
    if state(newest) == state(new) {
        return Rolling::Unchanged;
    }
    let apart = newest["saved_at"].as_u64().zip(previous.and_then(|p| p["saved_at"].as_u64()))
        .map(|(newest, previous)| newest.saturating_sub(previous));
    if apart.is_some_and(|apart| apart < spacing) { Rolling::Replace } else { Rolling::Append }
}
pub fn run(command: CheckpointCommand) -> Result<Value> {
    match command {
        CheckpointCommand::Save(args) => {
            let dir = directory(&args.selection.tag)?;
            // Every session of the server, also from inside a pane: a save
            // scoped to the caller's session could not restore the others.
            let mut v = if let Some(path) = &args.input {
                read(Path::new(path))?
            } else {
                crate::live_sessions::capture_checkpoint()?
            };
            validate(&v)?;
            // A capture taken elsewhere comes with the process list taken with
            // it; a live one is matched against this computer's processes.
            let listed = |path: &Option<String>| -> Result<HashMap<i64, Process>> {
                match path {
                    Some(path) => Ok(process_list(&fs::read_to_string(path)?)),
                    None => Ok(processes()),
                }
            };
            if args.processes.is_some() && args.input.is_none() {
                return Err("--processes describes the capture given with --input".into());
            }
            enrich(&mut v, listed(&args.processes)?)?;
            validate(&v)?;
            // A process that exited or was replaced while metadata was read cannot be resumed safely.
            let after = listed(&args.processes)?;
            for w in v["windows"].as_array_mut().unwrap() {
                for p in w["panes"].as_array_mut().unwrap() {
                    if let Some(pid) = p["agent"]["pid"].as_i64() {
                        if foreground(p["pid"].as_i64().unwrap_or(-1), &after).is_none_or(|a| {
                            a.pid != pid
                                || p["agent"]["started"].as_str() != Some(a.started.as_str())
                        }) {
                            return Err(
                                "foreground agent changed during capture; checkpoint not written"
                                    .into(),
                            );
                        }
                    }
                }
            }
            v["saved_at"] = json!(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs());
            v["tag"] = json!(args.selection.tag);
            let _history_lock = lock_history(&dir)?;
            let mut replaced = None;
            if let Some(spacing) = args.rolling {
                // An unreadable entry counts as different and is never the one replaced.
                let entries = history(&dir)?;
                let stored = |index: usize| entries.get(index).and_then(|path| read(path).ok());
                match rolling(&v, stored(0).as_ref(), stored(1).as_ref(), spacing) {
                    Rolling::Unchanged => return Ok(json!({"path":entries[0],"unchanged":true})),
                    Rolling::Replace => replaced = Some(entries[0].clone()),
                    Rolling::Append => {}
                }
            }
            let path = dir.join(format!(
                "checkpoint-{:020}-{}.json",
                SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos(),
                uuid::Uuid::new_v4()
            ));
            let bytes = serde_json::to_vec_pretty(&v)?;
            if bytes.len() > 4 * 1024 * 1024 { return Err("checkpoint exceeds 4 MiB".into()); }
            atomic(&path, &bytes, 0o600)?;
            if let Some(replaced) = replaced {
                fs::remove_file(replaced)?;
            }
            let retain = std::env::var("GRAFFITTY_CHECKPOINT_HISTORY")
                .ok()
                .and_then(|s| s.parse::<usize>().ok())
                .filter(|n| *n > 0)
                .unwrap_or(20);
            for old in history(&dir)?.into_iter().skip(retain) {
                fs::remove_file(old)?;
            }
            Ok(json!({"path":path}))
        }
        CheckpointCommand::List(args) => {
            let dir = directory(&args.tag)?;
            let _history_lock = lock_history(&dir)?;
            let mut entries = vec![];
            for path in history(&dir)? {
                let v = read(&path)?;
                // One Graffitty window is one session; tabs and panes (terminals
                // and chromiums) are summed across them, as tmux-restore-agents lists.
                let windows = v["windows"].as_array().unwrap();
                let count = |key: &str| windows.iter().map(|w| w[key].as_array().map_or(0, Vec::len)).sum::<usize>();
                entries.push(json!({"path":path,"saved_at":v["saved_at"],"windows":windows.len(),
                    "tabs":count("tabs"),"panes":count("panes") + count("chromiums")}));
            }
            Ok(json!(entries))
        }
        CheckpointCommand::Restore(args) => {
            let dir = directory(&args.selection.tag)?;
            let (v, trusted, path) = if let Ok(index) = args.checkpoint.parse::<usize>() {
                let _history_lock = lock_history(&dir)?;
                let path = history(&dir)?.get(index).cloned().ok_or("checkpoint index not found")?;
                (read(&path)?, true, path)
            } else {
                let path = PathBuf::from(args.checkpoint);
                let trusted = fs::canonicalize(&path).ok().zip(fs::canonicalize(root()).ok())
                    .is_some_and(|(path, root)| path.starts_with(root));
                // An explicit history path can belong to a different tag.
                let _history_lock = if trusted {
                    Some(lock_history(path.parent().ok_or("checkpoint has no parent")?)?)
                } else { None };
                (read(&path)?, trusted, path)
            };
            let prepared = prepare(v, &dir, trusted)?;
            if args.prepare_only {
                return Ok(json!({"prepared":prepared}));
            }
            let mut gui = if let Some(frontend) = args.frontend {
                let path=PathBuf::from(frontend);
                if !path.is_absolute() || !path.is_file() {
                    return Err("Frontend must be an absolute executable file path".into());
                }
                Command::new(path)
            } else if cfg!(any(windows, target_os = "linux")) {
                // Use the packaged launcher on both desktop platforms.
                let mut launcher = Command::new(std::env::current_exe()?);
                launcher.arg("gui");
                launcher
            } else {
                Command::new(std::env::current_exe()?.with_file_name("gft-gui"))
            };
            let mut child = gui
                .args([
                    "--",
                    &format!("--restore-checkpoint={}", prepared.display()),
                ])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()?;
            let receipt = prepared.parent().unwrap().join("ready.json");
            let started = std::time::Instant::now();
            while !receipt.is_file() {
                if let Some(status) = child.try_wait()? {
                    return Err(
                        format!("restore application exited before restoring: {status}").into(),
                    );
                }
                if started.elapsed() > Duration::from_secs(60) {
                    return Err("restore did not report readiness within 60 seconds; inspect the application log".into());
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            let result: Value = serde_json::from_slice(&fs::read(receipt)?)?;
            if result["ok"] != true {
                return Err(format!("restore failed: {result}").into());
            }
            // A saved ID that a live pane already has was replaced by a new one.
            let renumbered: serde_json::Map<String, Value> = result["panes"].as_object().into_iter().flatten()
                .filter(|(saved, restored)| restored.as_u64().map(|id| id.to_string()).as_ref() != Some(*saved))
                .map(|(saved, restored)| (format!("%{saved}"), json!(format!("%{restored}")))).collect();
            Ok(json!({"pid":child.id(),"checkpoint":path,"renumbered":renumbered}))
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn agent_names_include_claudes_versioned_native_install() {
        for (path, name) in [
            ("/usr/local/bin/claude", Some("claude")),
            ("/Users/u/.local/share/claude/versions/2.1.326", Some("claude")),
            ("/opt/claude/versions/2", Some("claude")),
            ("/opt/homebrew/bin/codex", Some("codex")),
            ("pi", Some("pi")),
            ("/Users/u/.local/share/other/versions/2.1.326", None),
            ("/usr/bin/versions", None),
            ("/bin/zsh", None),
        ] {
            assert_eq!(super::agent_name(path), name, "{path}");
        }
    }


    use super::*;
    #[test]
    fn background_session_names_the_conversation_it_was_forked_from() {
        let session = "/opt/claude/versions/2 --session-id new-id --fork-session --resume /Users/Shared/my projects/gft/old-id.jsonl --reply-on-resume";
        let host = "/opt/claude/claude --bg-pty-host /tmp/pty.sock 67 16 -- /opt/claude/versions/2 --session-id new-id --fork-session --resume /tmp/other-id.jsonl";
        let commands = |list: &[&str]| list.iter().map(|c| c.to_string()).collect::<Vec<_>>();
        assert_eq!(background_session(&commands(&["/bin/sh -c hook", session, host, "claude daemon run"])), Some(Some("old-id".into())));
        assert_eq!(background_session(&commands(&["/opt/claude/versions/2 --session-id fresh", "claude --bg-pty-host /tmp/pty.sock 67 16 -- x"])), Some(None), "A new background session has no parent");
        assert_eq!(background_session(&commands(&["claude --resume old-id --fork-session", "/bin/zsh -li"])), None, "A fork typed in a pane runs in that pane");
    }
    fn fixture() -> Value {
        json!({"version":1,"windows":[{"active":3,"position":[10,20],"size":[900,700],"tabs":[{"id":3,"focused":"%3","tree":{"pane":"%3"}}],"panes":[{"id":3,"pid":-1,"cwd":"/tmp"}],"chromiums":[]}]})
    }
    #[cfg(windows)]
    #[test]
    fn windows_foreground_uses_unique_agent_descendant() {
        let row = |pid, parent, executable: &str| Process { pid, parent, started: "100".into(), executable: executable.into(), group: 0, foreground: 0, tty: String::new(), state: String::new() };
        let mut table = HashMap::from([(10, row(10, 1, "pwsh.exe")), (11, row(11, 10, "claude.exe")), (12, row(12, 2, "codex.exe"))]);
        assert_eq!(foreground(10, &table).unwrap().pid, 11);
        table.insert(13, row(13, 10, "codex.exe"));
        assert!(foreground(10, &table).is_none());
    }
    #[cfg(windows)]
    #[test]
    fn windows_foreground_resolves_provider_shim_but_not_sibling_workers() {
        let row = |pid, parent, executable: &str| Process { pid, parent, started: "100".into(), executable: executable.into(), group: 0, foreground: 0, tty: String::new(), state: String::new() };
        let mut table = HashMap::from([
            (10, row(10, 1, "pwsh.exe")),
            (11, row(11, 10, r"C:\shims\claude.exe")),
            (12, row(12, 11, r"C:\packages\claude.exe")),
        ]);
        assert_eq!(foreground(10, &table).unwrap().pid, 12);
        table.insert(13, row(13, 11, r"C:\other\claude.exe"));
        assert!(foreground(10, &table).is_none());
    }
    #[test]
    fn rolling_saves_skip_unchanged_state_and_space_out_history() {
        let at = |seconds: u64, cwd: &str| {
            let mut v = fixture();
            v["saved_at"] = json!(seconds);
            v["tag"] = json!("auto");
            v["windows"][0]["panes"][0]["cwd"] = json!(cwd);
            v
        };
        let new = at(4000, "/new");
        assert_eq!(rolling(&new, None, None, 1800), Rolling::Append);
        assert_eq!(rolling(&new, Some(&at(10, "/new")), None, 1800), Rolling::Unchanged);
        // The only entry anchors the history; the next save starts the rolling head.
        assert_eq!(rolling(&new, Some(&at(10, "/a")), None, 1800), Rolling::Append);
        assert_eq!(rolling(&new, Some(&at(70, "/b")), Some(&at(10, "/a")), 1800), Rolling::Replace);
        assert_eq!(rolling(&new, Some(&at(1810, "/b")), Some(&at(10, "/a")), 1800), Rolling::Append);
    }
    #[test]
    fn rejects_incomplete_or_ambiguous_layouts() {
        assert!(validate(&fixture()).is_ok());
        let mut v = fixture();
        v["windows"][0]["panes"][0]["id"] = json!(4);
        assert!(validate(&v).is_err());
        let mut v = fixture();
        let w = v["windows"][0].clone();
        v["windows"].as_array_mut().unwrap().push(w);
        assert!(validate(&v).is_err());
        let mut v = fixture();
        v["windows"][0]["active"] = json!(99);
        assert!(validate(&v).is_err());
        let mut v = fixture();
        v["windows"] = json!([]);
        assert!(validate(&v).is_err());
    }
    #[test]
    fn hook_owner_walks_shells_and_node_launcher_without_guessing() {
        let base = Process {
            pid: 10,
            parent: 1,
            group: 10,
            foreground: 10,
            tty: "ttys001".into(),
            state: "S".into(),
            started: "now".into(),
            executable: "/bin/node".into(),
        };
        let mut table = HashMap::from([
            (10, base.clone()),
            (
                11,
                Process {
                    pid: 11,
                    parent: 10,
                    executable: "/vendor/bin/codex".into(),
                    ..base.clone()
                },
            ),
            (
                12,
                Process {
                    pid: 12,
                    parent: 11,
                    executable: "/bin/sh".into(),
                    tty: "??".into(),
                    ..base.clone()
                },
            ),
            (
                13,
                Process {
                    pid: 13,
                    parent: 12,
                    executable: "/bin/gft".into(),
                    ..base.clone()
                },
            ),
            (
                99,
                Process {
                    pid: 99,
                    executable: "/bin/claude".into(),
                    ..base.clone()
                },
            ),
        ]);
        assert_eq!(hook_owner(13, "codex", &table).unwrap().pid, 11);
        assert!(hook_owner(13, "claude", &table).is_none());
        // The same agent program further up, on another terminal, started this
        // terminal (it launched the app, or runs its tests). It is not this pane's agent.
        table.get_mut(&10).unwrap().parent = 99;
        table.get_mut(&99).unwrap().tty = "ttys009".into();
        assert!(hook_owner(13, "claude", &table).is_none());
        table.get_mut(&99).unwrap().tty = "ttys001".into();
        assert_eq!(hook_owner(13, "claude", &table).unwrap().pid, 99);
        table.get_mut(&10).unwrap().parent = 1;
        table.get_mut(&11).unwrap().state = "Z".into();
        assert!(hook_owner(13, "codex", &table).is_none());
        table.get_mut(&12).unwrap().parent = 13;
        assert!(hook_owner(13, "codex", &table).is_none());
    }
    #[cfg(unix)]
    #[test]
    fn foreground_requires_unique_descendant_on_same_tty() {
        let shell = Process {
            pid: 1,
            parent: 0,
            group: 1,
            foreground: 2,
            tty: "ttys001".into(),
            state: "S".into(),
            started: "now".into(),
            executable: "/bin/zsh".into(),
        };
        let child = Process {
            pid: 2,
            parent: 1,
            group: 2,
            executable: "/bin/codex".into(),
            ..shell.clone()
        };
        let mut table = HashMap::from([(1, shell), (2, child.clone())]);
        assert_eq!(foreground(1, &table).unwrap().pid, 2);
        table.get_mut(&2).unwrap().tty = "ttys002".into();
        assert!(foreground(1, &table).is_none());
        table.insert(2, child.clone());
        table.insert(3, Process { pid: 3, ..child });
        assert!(foreground(1, &table).is_none());
        table.remove(&3);
        table.get_mut(&2).unwrap().parent = 99;
        assert!(foreground(1, &table).is_none());
    }
    #[test]
    fn tag_encoding_is_case_sensitive_and_cannot_escape() {
        assert_ne!(directory("Main").unwrap(), directory("main").unwrap());
        assert!(
            !directory("../../x")
                .unwrap()
                .file_name()
                .unwrap()
                .to_string_lossy()
                .contains('/')
        );
        assert!(directory("").is_err());
        assert!(directory("bad\n").is_err());
    }
    fn relaunch() -> Relaunch {
        Relaunch {
            command: vec!["C:/Tools/judge.exe".into(), "two words".into(), "it's".into()],
            cwd: Some("C:/Work Dir".into()),
            env: vec![("MODE".into(), Some("strict".into())), ("XDG_DATA_HOME".into(), None),
                      ("GRAFFITTY_NODE_STATE".into(), Some("C:/state.json".into()))],
        }
    }
    #[test]
    fn relaunch_scripts_keep_the_following_shell_clean() {
        unsafe { std::env::set_var("SHELL", "/bin/zsh") };
        assert_eq!(relaunch().sh(), "#!/bin/sh\n(\ncd -- 'C:/Work Dir' 2>/dev/null\nexport MODE='strict'\nunset XDG_DATA_HOME\n\
            export GRAFFITTY_NODE_STATE='C:/state.json'\nexec 'C:/Tools/judge.exe' 'two words' 'it'\\''s'\n)\nexec '/bin/zsh' -l\n");
        assert_eq!(relaunch().powershell(), "$saved = @{}\nforeach ($name in @('MODE', 'XDG_DATA_HOME', 'GRAFFITTY_NODE_STATE')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }\n\
            [Environment]::SetEnvironmentVariable('MODE', 'strict')\n[Environment]::SetEnvironmentVariable('XDG_DATA_HOME', $null)\n\
            [Environment]::SetEnvironmentVariable('GRAFFITTY_NODE_STATE', 'C:/state.json')\n\
            Push-Location -LiteralPath 'C:/Work Dir' -ErrorAction SilentlyContinue\n\
            try { & 'C:/Tools/judge.exe' 'two words' 'it''s' } catch { Write-Host $_ } finally {\n    Pop-Location -ErrorAction SilentlyContinue\n    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }\n}\n");
        let run = std::env::temp_dir().join(format!("graffitty-relaunch-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&run).unwrap();
        let (program, args) = relaunch().write(&run, &json!(3), true).unwrap();
        assert!(program == "pwsh.exe" || program == "powershell.exe");
        assert_eq!(args[..5], ["-NoLogo", "-NoExit", "-ExecutionPolicy", "Bypass", "-File"]);
        assert_eq!(fs::read_to_string(&args[5]).unwrap(), relaunch().powershell());
        let (script, args) = relaunch().write(&run, &json!(3), false).unwrap();
        assert!(args.is_empty() && script.ends_with("pane-3.sh"));
        fs::remove_dir_all(run).unwrap();
    }
    #[test]
    fn agents_resume_in_exactly_their_own_provider_locations() {
        let agent = json!({"kind":"codex","env":{"CODEX_HOME":"/accounts/work"}});
        let relaunch = Relaunch::agent("codex", "/bin/codex", "id".into(), &agent);
        assert_eq!(relaunch.command, ["/bin/codex", "resume", "id"]);
        // A location the agent did not have is removed, not inherited from the restoring shell.
        assert_eq!(relaunch.env, [("CODEX_HOME".into(), Some("/accounts/work".into())), ("CODEX_SQLITE_HOME".into(), None)]);
        let relaunch = Relaunch::agent("claude", "claude", "id".into(), &json!({"kind":"claude","env":{}}));
        assert_eq!((relaunch.command, relaunch.env), (vec!["claude".into(), "--resume".into(), "id".into()],
            vec![("CLAUDE_CONFIG_DIR".into(), None)]));
    }
    #[test]
    fn prepare_never_replays_unresolved_or_arbitrary_commands() {
        let dir = std::env::temp_dir().join(format!("graffitty-test-{}", uuid::Uuid::new_v4()));
        let mut v = fixture();
        v["windows"][0]["panes"][0]["restore_shell"] = json!("/tmp/untrusted");
        v["windows"][0]["panes"][0]["agent"] = json!({"kind":"codex","session_id":null,"env":{}});
        let path = prepare(v, &dir, true).unwrap();
        let saved = read(&path).unwrap();
        assert!(
            saved["windows"][0]["panes"][0]
                .get("restore_shell")
                .is_none()
        );
        #[cfg(unix)]
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(dir).unwrap();
        assert_eq!(quote("a'b; $(id)"), "'a'\\''b; $(id)'");
    }
}
