//! Provider discovery and blocking I/O, run off the Godot main thread.
#[cfg(unix)]
use std::os::unix::{fs::{FileTypeExt, MetadataExt}, net::UnixStream};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::Duration,
};
pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

// Godot parses JSON numbers as doubles and writes PIDs/offsets as `123.0`.
// Accept exact whole numbers, rejecting fractions and unsafe float integers.
fn integer(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        let n = value.as_f64()?;
        (n.is_finite() && n.fract() == 0.0 && n.abs() <= 9_007_199_254_740_991.0)
            .then_some(n as i64)
    })
}

fn home() -> PathBuf {
    std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default()
}
pub(crate) fn provider_home(provider: &str) -> PathBuf {
    let (variable, default) = if provider == "claude" {
        ("CLAUDE_CONFIG_DIR", ".claude")
    } else {
        ("CODEX_HOME", ".codex")
    };
    let path = std::env::var_os(variable)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(default));
    if path.is_absolute() {
        path
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    }
}
fn claude_directory(root: &Value, pid: i64) -> PathBuf {
    // A hook's home belongs to that process, never to the whole workspace.
    if integer(&root["agent_pid"]) == Some(pid) {
        if let Some(path) = root["provider_home"].as_str() {
            return PathBuf::from(path);
        }
    }
    // Also discover unwrapped processes when their transcript is open.
    for path in crate::sessions::open_paths(pid) {
        for ancestor in path.ancestors() {
            if ancestor.file_name().is_some_and(|name| name == "projects") {
                if let Some(dir) = ancestor.parent() {
                    if dir.join(format!("sessions/{pid}.json")).is_file() {
                        return dir.to_path_buf();
                    }
                }
            }
        }
    }
    provider_home("claude")
}
fn read_json(path: &Path) -> Option<Value> {
    read_json_up_to(path, 1024 * 1024)
}
fn read_json_up_to(path: &Path, limit: u64) -> Option<Value> {
    if fs::metadata(path).ok()?.len() > limit {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}
fn find_transcript(dir: &Path, name: &str, depth: u8) -> Option<PathBuf> {
    if depth == 0 {
        return None;
    }
    for entry in fs::read_dir(dir).ok()?.take(5000).flatten() {
        let p = entry.path();
        if entry.file_type().ok()?.is_dir() {
            if let Some(p) = find_transcript(&p, name, depth - 1) {
                return Some(p);
            }
        } else if p.file_name().is_some_and(|s| s == name) {
            return Some(p);
        }
    }
    None
}
/// Bind only files open in this process. A shared daemon's files identify
/// the daemon, so they cannot establish which frontend owns a thread.
fn codex_files(paths: &[PathBuf]) -> Value {
    let mut threads = std::collections::BTreeMap::<String, (PathBuf, Option<PathBuf>)>::new();
    let mut subagents = std::collections::HashSet::new();
    for path in paths {
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        let lock = path.parent().filter(|p| p.file_name().is_some_and(|n| n == "thread-writer-locks"));
        let (id, home, transcript) = if let Some(dir) = lock {
            let Some(id) = name.strip_suffix(".lock").filter(|id| uuid::Uuid::parse_str(id).is_ok()) else { continue };
            (id.to_owned(), dir.parent().unwrap_or(Path::new("/")).to_path_buf(), None)
        } else if name.starts_with("rollout-") && name.ends_with(".jsonl") {
            use std::io::BufRead;
            let record = fs::File::open(path).ok().and_then(|f| {
                std::io::BufReader::new(f.take(65536)).lines().next()?.ok()
            }).and_then(|line| serde_json::from_str::<Value>(&line).ok());
            let Some(id) = record.as_ref().filter(|v| v["type"] == "session_meta")
                .and_then(|v| v["payload"]["id"].as_str())
                .filter(|id| uuid::Uuid::parse_str(id).is_ok() && name.ends_with(&format!("-{id}.jsonl"))) else { continue };
            // Like tmux's agent-sid.sh, exclude subagent rollouts. Inspect the
            // metadata field, not arbitrary text that might contain "subagent".
            let payload = &record.as_ref().unwrap()["payload"];
            if payload["source"].get("subagent").is_some()
                || payload["source"] == "subagent"
                || payload["parent_thread_id"].is_string()
            {
                subagents.insert(id.to_owned());
                continue;
            }
            let Some(home) = path.ancestors().find(|p| p.file_name().is_some_and(|n| n == "sessions")).and_then(Path::parent) else { continue };
            (id.to_owned(), home.to_path_buf(), Some(path.clone()))
        } else { continue };
        let entry = threads.entry(id).or_insert((home, None));
        if transcript.is_some() { entry.1 = transcript; }
    }
    // A subagent lock may occur before or after its rollout in the fd listing.
    threads.retain(|id, _| !subagents.contains(id));
    if threads.len() != 1 {
        return json!({"discovery_note":if threads.is_empty() {
            "Codex PID detected; no process-bound thread evidence yet. No matching daemon thread has been verified."
        } else { "Multiple threads open in this process; refusing to guess the active thread." }});
    }
    let (id, (home, path)) = threads.into_iter().next().unwrap();
    let mut result = json!({"session_id":id,"provider_home":home,
        "queue_error":"This Codex process owns its session locally and has no external queue endpoint (local mode, e.g. --no-daemon or incompatible command-line config overrides). Detection and transcript reading work; native message delivery is unavailable."});
    if let Some(path) = path {
        result["transcript_path"] = json!(path);
        if let Ok(t) = transcript(&path, None) {
            result["status"] = t["status"].clone();
        }
    }
    result
}

pub fn scan(roots: &Value) -> Value {
    let table = crate::sessions::processes();
    let mut result = serde_json::Map::new();
    let mut daemon_inventories = std::collections::HashMap::<PathBuf, std::result::Result<Vec<Value>, String>>::new();
    for root in roots.as_array().into_iter().flatten() {
        let Some(p) = crate::sessions::foreground(integer(&root["pid"]).unwrap_or(-1), &table)
        else {
            // Godot's process-running API only tracks its own children. Agents
            // are grandchildren launched by the PTY shell; use the OS snapshot.
            if let (Some(key), Some(pid)) = (root["node"].as_str(), integer(&root["agent_pid"])) {
                let alive = table.get(&pid).is_some_and(|p| {
                    root["started"].as_str().is_none_or(|started| started == p.started)
                });
                if !alive {
                    result.insert(key.into(), json!({"status":"offline"}));
                }
            }
            continue;
        };
        let kind = crate::sessions::agent_name(&p.executable).unwrap_or_default();
        let mut state = json!({"provider":kind,"pid":p.pid,"started":p.started,"status":"unknown"});
        if kind == "claude" {
            let dir = claude_directory(root, p.pid);
            if let Some(r) = read_json(&dir.join(format!("sessions/{}.json", p.pid))) {
                // Registry records are PID-bound; reject recycled process records.
                let normalize = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
                if r["pid"].as_i64().is_some_and(|id| id != p.pid)
                    || r["procStart"]
                        .as_str()
                        .is_some_and(|s| normalize(s) != normalize(&p.started))
                {
                    continue;
                }
                state["session_id"] = r["sessionId"].clone();
                state["socket_path"] = r["messagingSocketPath"].clone();
                state["registry_dir"] = json!(dir.join("sessions"));
                state["status"] = json!(match r["status"].as_str().unwrap_or("unknown") {
                    "idle" => "idle",
                    "busy" | "working" => "busy",
                    "waiting" | "blocked" => "waiting",
                    _ => "unknown",
                });
                if let Some(id) = r["sessionId"]
                    .as_str()
                    .filter(|id| uuid::Uuid::parse_str(id).is_ok())
                {
                    if let Some(path) =
                        find_transcript(&dir.join("projects"), &format!("{id}.jsonl"), 3)
                    {
                        state["transcript_path"] = json!(path);
                    }
                }
            }
        } else if kind == "codex" {
            let open_paths = crate::sessions::open_paths(p.pid);
            let mut discovered = codex_files(&open_paths);
            if discovered.get("session_id").is_none() {
                let ports = crate::codex_discovery::listener_ports(p.pid);
                if !ports.is_empty() {
                    let home = if integer(&root["agent_pid"]) == Some(p.pid) && root["started"].as_str() == Some(&p.started) {
                        root["provider_home"].as_str().map(PathBuf::from).unwrap_or_else(|| provider_home("codex"))
                    } else { provider_home("codex") };
                    // SQLite handles also reveal custom CODEX_HOME locations without
                    // reading process environments or assuming the GUI's home.
                    let homes: std::collections::HashSet<_> = open_paths.iter().filter_map(|path| {
                        let name = path.file_name()?.to_str()?;
                        if !(name.starts_with("logs_") || name.starts_with("state_")) || !name.contains(".sqlite") { return None; }
                        let dir = path.parent()?;
                        dir.join("app-server-control/app-server-control.sock").exists().then(|| dir.to_path_buf())
                    }).collect();
                    let home = if homes.len() == 1 { homes.into_iter().next().unwrap() } else { home };
                    let inventory = daemon_inventories.entry(home.clone()).or_insert_with(|| {
                        crate::codex_discovery::Rpc::connect(&home).and_then(|mut rpc| crate::codex_discovery::inventory(&mut rpc)).map_err(|e| e.to_string())
                    });
                    match inventory {
                        Ok(records) => match crate::codex_discovery::select(records, &ports, &home) {
                            Ok(found) => discovered = found,
                            Err(e) => discovered["discovery_note"] = json!(e.to_string()),
                        },
                        Err(e) => discovered["discovery_note"] = json!(format!("Codex listener found; daemon discovery failed: {e}")),
                    }
                }
            }
            state.as_object_mut().unwrap().extend(discovered.as_object().unwrap().clone());
        }

        // A short daemon turn can start and finish between discovery polls.
        // Carry a completed-record checkpoint, not just instantaneous status.
        // Reading stays in this worker and is bounded to the transcript tail.
        if kind == "codex" && state["status"] == "idle" {
            if let Some(path) = state["transcript_path"].as_str() {
                if let Ok(tail) = transcript(Path::new(path), None) {
                    if tail["status"] != "busy" {
                        if let Some(checkpoint) = completed_checkpoint(&tail) {
                            state["completion_checkpoint"] = json!(checkpoint);
                        }
                    }
                }
            }
        }
        if let Some(key) = root["node"].as_str() {
            result.insert(key.into(), state);
        }
    }
    Value::Object(result)
}

/// Stable completion identity, including an observed pre-turn baseline.
fn completed_checkpoint(tail: &Value) -> Option<u64> {
    tail["completion_checkpoint"].as_u64().or_else(|| {
        // Establish a baseline before the first turn. An incomplete tail of
        // an older transcript cannot establish that there were no completions.
        (tail["status"] == "unknown" && tail["offset"] == 0).then_some(0)
    })
}

/// Bounded raw JSONL plus normalized assistant text. Never parse a partial last record.
pub fn transcript(path: &Path, offset: Option<u64>) -> Result<Value> {
    let mut f = fs::File::open(path)?;
    let len = f.metadata()?.len();
    let start = offset.unwrap_or(len.saturating_sub(128 * 1024)).min(len);
    f.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    (&mut f).take(128 * 1024).read_to_end(&mut bytes)?;
    // A large JSONL record must not leave readers retrying the same offset forever.
    while !bytes.contains(&b'\n') && start + (bytes.len() as u64) < len {
        if bytes.len() >= 1024 * 1024 {
            return Err("Transcript record exceeds the 1 MiB read limit".into());
        }
        (&mut f).take(128 * 1024).read_to_end(&mut bytes)?;
    }
    let end = bytes
        .iter()
        .rposition(|b| *b == b'\n')
        .map(|i| i + 1)
        .unwrap_or(0);
    bytes.truncate(end);
    let raw = String::from_utf8_lossy(&bytes).into_owned();
    let mut last = String::new();
    let mut status = "unknown";
    let mut completion_checkpoint = None;
    let mut position = start;
    for line in bytes.split_inclusive(|byte| *byte == b'\n') {
        position += line.len() as u64;
        let Ok(v) = serde_json::from_slice::<Value>(line) else {
            continue;
        };
        if v["type"] == "event_msg" {
            match v["payload"]["type"].as_str().unwrap_or("") {
                "task_started" | "turn_started" | "user_message" => status = "busy",
                "task_complete" | "turn_complete" => {
                    status = "idle";
                    completion_checkpoint = Some(position);
                    if let Some(s) = v["payload"]["last_agent_message"].as_str() {
                        last = s.into();
                    }
                }
                "turn_aborted" => status = "idle",
                _ => {}
            }
        }
        // OpenCode v2 exports retain native message records in append-only JSONL.
        if v["type"] == "idle" { status = "idle"; completion_checkpoint = Some(position); }
        if v["type"] == "user" { status = "busy"; }
        if v["type"] == "assistant" {
            last = v["content"].as_array().into_iter().flatten().filter(|p| p["type"] == "text")
                .filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("\n");
        }
        let msg = if v["type"] == "response_item" {
            &v["payload"]
        } else {
            &v["message"]
        };
        if msg["role"] == "assistant" {
            let text = msg["content"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|p| p["text"].as_str())
                .collect::<Vec<_>>()
                .join("\n");
            if !text.is_empty() {
                last = text;
            }
        }
    }
    Ok(
        json!({"text":raw,"last_message":last,"offset":start,"next_offset":start+end as u64,"size":len,"status":status,"completion_checkpoint":completion_checkpoint}),
    )
}

pub fn send_claude(target: &Value, text: &str, event_id: &str) -> Result<Value> {
    let pid = integer(&target["pid"]).ok_or("Claude PID missing")?;
    let table = crate::sessions::processes();
    let p = table.get(&pid).ok_or("Claude exited")?;
    if target["started"].as_str() != Some(&p.started) {
        return Err("Claude process changed".into());
    }
    let path = target["socket_path"]
        .as_str()
        .ok_or("Claude has no messaging socket")?;
    #[cfg(unix)]
    let meta = fs::symlink_metadata(path)?;
    #[cfg(unix)]
    if !meta.file_type().is_socket() || meta.uid() != unsafe { libc::geteuid() } {
        return Err("Invalid Claude socket owner/type".into());
    }
    // Claude hashes path.resolve(), not realpath(): /tmp and /private/tmp differ.
    if !Path::new(path).is_absolute()
        || Path::new(path)
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err("Claude socket path is not absolute and normalized".into());
    }
    #[cfg(windows)]
    if !path.starts_with(r"\\.\pipe\") {
        return Err("Claude messaging endpoint must be a local named pipe".into());
    }
    let hash = claude_endpoint_hash(path)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    let dir = Path::new(
        target["registry_dir"]
            .as_str()
            .ok_or("Claude registry unavailable")?,
    );
    let key_path = dir.join(format!("{pid}.{hash}.key"));
    let key_meta = fs::symlink_metadata(&key_path)?;
    if !key_meta.is_file() { return Err("Invalid Claude key file".into()); }
    #[cfg(unix)]
    if key_meta.uid() != meta.uid() || key_meta.mode() & 0o077 != 0 {
        return Err("Invalid Claude key file".into());
    }
    let key = read_json(&key_path).ok_or("Claude key unavailable")?;
    let token = key["peerToken"]
        .as_str()
        .ok_or("Claude peer token unavailable")?;
    let (auth, message) = claude_frames(token, event_id, text)?;
    #[cfg(unix)]
    let mut stream = UnixStream::connect(path)?;
    #[cfg(windows)]
    let mut stream = {
        let pipe = graffitty_session_transport::BlockingStream::connect(&format!("ipc://{path}"))?;
        if i64::from(pipe.server_process_id()?) != pid {
            return Err("Claude pipe process mismatch".into());
        }
        pipe
    };
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    #[cfg(unix)]
    crate::grow_send_buffer(&stream, auth.len() + message.len() + 2);
    #[cfg(target_os = "macos")]
    unsafe {
        use std::os::fd::AsRawFd;
        let mut peer: libc::pid_t = 0;
        let mut size = std::mem::size_of_val(&peer) as libc::socklen_t;
        if libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut peer as *mut libc::pid_t).cast(),
            &mut size,
        ) != 0
            || i64::from(peer) != pid
        {
            return Err("Claude socket process mismatch".into());
        }
    }
    writeln!(stream, "{auth}")?;
    writeln!(stream, "{message}")?;
    #[cfg(unix)]
    stream.shutdown(std::net::Shutdown::Write)?;
    // This protocol acknowledges asynchronously; don't claim model execution.
    Ok(json!({"status":"submitted","transport":"claude_socket"}))
}
fn claude_endpoint_hash(path: &str) -> [u8; 32] {
    // Claude's Windows registry hashes the case-insensitive pipe identity.
    #[cfg(windows)]
    let path = path.to_lowercase();
    Sha256::digest(path.as_bytes()).into()
}
/// Claude's inbox drops a connection once its buffered input exceeds 1,048,576
/// UTF-16 units, auth line included, after our write has already succeeded.
fn claude_frames(token: &str, event_id: &str, text: &str) -> Result<(String, String)> {
    let auth = json!({"type":"auth","token":token}).to_string();
    let message = json!({"type":"user","msg_id":event_id,"message":{"role":"user","content":text},"priority":"next"}).to_string();
    if auth.encode_utf16().count() + message.encode_utf16().count() + 2 > 1_048_576 {
        return Err("Message exceeds Claude's 1 MiB inbox limit; save long content to a file and send its path".into());
    }
    Ok((auth, message))
}
pub fn worker(request: &str) -> Result<Value> {
    // Delivery requests carry whole messages, bounded by the workspace socket.
    let v = read_json_up_to(Path::new(request), crate::MAX_MESSAGE).ok_or("Invalid worker request")?;
    match v["op"].as_str().unwrap_or("") {
        "scan" => Ok(scan(&v["roots"])),
        "foreground_apps" => Ok(crate::foreground_apps::scan(&v["roots"])),
        "codex_queue_status" => crate::codex_transport::queued_ids(&v["target"]),
        "codex_cancel" => crate::codex_transport::cancel_queue(
            &v["target"], v["submission_id"].as_str().ok_or("Missing submission ID")?,
        ),
        "codex_queue" => crate::codex_transport::queue(
            &v["target"], v["text"].as_str().ok_or("Missing text")?,
            v["event_id"].as_str().ok_or("Missing event ID")?,
        ),
        "read" => transcript(
            Path::new(v["path"].as_str().ok_or("Missing transcript path")?),
            integer(&v["offset"]).and_then(|n| u64::try_from(n).ok()),
        ),
        "claude_send" => send_claude(
            &v["target"],
            v["text"].as_str().ok_or("Missing text")?,
            v["event_id"].as_str().ok_or("Missing event ID")?,
        ),
        _ => Err("Unknown worker operation".into()),
    }
}

#[cfg(test)]
mod claude_send_tests {
    use super::*;
    #[cfg(windows)]
    #[test]
    fn windows_claude_uses_authenticated_named_pipe_and_case_normalized_key() {
        let directory = tempfile::tempdir().unwrap();
        let path = format!(r"\\.\pipe\LOCAL\cc-msg-test-{}", uuid::Uuid::new_v4());
        let listener = graffitty_session_transport::bind(Path::new(&path)).unwrap();
        let peer = std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + Duration::from_secs(5);
            let mut stream = loop {
                match graffitty_session_transport::accept(&listener) {
                    Ok(stream) => break stream,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && std::time::Instant::now() < deadline =>
                        std::thread::sleep(Duration::from_millis(1)),
                    Err(e) => panic!("{e}"),
                }
            };
            let mut bytes = Vec::new();
            while bytes.iter().filter(|b| **b == b'\n').count() < 2 {
                assert!(std::time::Instant::now() < deadline, "Claude pipe message timed out");
                let mut buffer = [0; 4096];
                match stream.read(&mut buffer) {
                    Ok(count) if count > 0 => bytes.extend_from_slice(&buffer[..count]),
                    Ok(_) => std::thread::sleep(Duration::from_millis(1)),
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock =>
                        std::thread::sleep(Duration::from_millis(1)),
                    Err(e) => panic!("{e}"),
                }
            }
            String::from_utf8(bytes).unwrap()
        });
        let pid = i64::from(std::process::id());
        let table = crate::sessions::processes();
        let hash = Sha256::digest(path.to_lowercase().as_bytes()).iter().map(|b| format!("{b:02x}")).collect::<String>();
        fs::write(directory.path().join(format!("{pid}.{hash}.key")), r#"{"peerToken":"fixture-only-token"}"#).unwrap();
        let target = json!({"pid":pid,"started":table[&pid].started,"socket_path":path,"registry_dir":directory.path()});
        let result = send_claude(&target, "Windows pipe message", "11111111-1111-4111-8111-111111111111").unwrap();
        assert_eq!(result["status"], "submitted");
        let wire = peer.join().unwrap();
        let lines: Vec<Value> = wire.lines().map(|s| serde_json::from_str(s).unwrap()).collect();
        assert_eq!(lines[0], json!({"type":"auth","token":"fixture-only-token"}));
        assert_eq!(lines[1]["message"]["content"], "Windows pipe message");
    }
    #[test]
    fn frames_stop_at_the_claude_inbox_line_limit() {
        let (token, id) = ("0".repeat(32), "11111111-1111-4111-8111-111111111111");
        let (auth, message) = claude_frames(&token, id, "").unwrap();
        let room = 1_048_576 - (auth.len() + message.len() + 2);
        assert!(claude_frames(&token, id, &"x".repeat(room)).is_ok());
        assert!(claude_frames(&token, id, &"x".repeat(room + 1)).is_err());
        // Claude counts JavaScript string length: an emoji is two units.
        assert!(claude_frames(&token, id, &"😀".repeat(room / 2)).is_ok());
        assert!(claude_frames(&token, id, &"😀".repeat(room / 2 + 1)).is_err());
    }
}

#[cfg(test)]
mod codex_discovery_tests {
    use super::*;
    #[test]
    fn completed_record_checkpoint_ignores_later_metadata_and_partial_lines() {
        let path = std::env::temp_dir().join(format!("graffitty-completion-{}.jsonl", uuid::Uuid::new_v4()));
        fs::write(&path, "{\"type\":\"session_meta\"}\n").unwrap();
        assert_eq!(completed_checkpoint(&transcript(&path, None).unwrap()), Some(0));
        assert_eq!(completed_checkpoint(&json!({"status":"unknown","offset":100})), None);
        let completed = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"빠른 응답\"}}\n";
        fs::write(&path, completed).unwrap();
        let first = transcript(&path, None).unwrap();
        assert_eq!(first["completion_checkpoint"], completed.len() as u64);
        fs::write(&path, format!("{completed}{{\"type\":\"token_count\"}}\n{{\"partial\":" )).unwrap();
        let later = transcript(&path, None).unwrap();
        assert_eq!(later["completion_checkpoint"], first["completion_checkpoint"]);
        assert_eq!(later["last_message"], "빠른 응답");
        // A bounded tail may begin inside a multibyte character. Checkpoints
        // must still count file bytes, not replacement characters in raw text.
        fs::write(&path, format!("한글\n{completed}")).unwrap();
        let tail = transcript(&path, Some(1)).unwrap();
        assert_eq!(tail["completion_checkpoint"], ("한글\n".len() + completed.len()) as u64);
        fs::remove_file(path).unwrap();
    }
    #[test]
    fn lock_identifies_thread_before_transcript_exists() {
        let id = "11111111-1111-4111-8111-111111111111";
        let v = codex_files(&[PathBuf::from(format!("/custom/codex/thread-writer-locks/{id}.lock"))]);
        assert_eq!(v["session_id"], id);
        assert_eq!(v["provider_home"], "/custom/codex");
        assert!(v.get("transcript_path").is_none());
        assert!(v["queue_error"].as_str().unwrap().contains("no external queue endpoint"));
    }
    #[test]
    fn multiple_threads_and_missing_evidence_never_guess() {
        for paths in [vec![], vec![
            PathBuf::from("/x/thread-writer-locks/11111111-1111-4111-8111-111111111111.lock"),
            PathBuf::from("/x/thread-writer-locks/22222222-2222-4222-8222-222222222222.lock"),
        ], vec![PathBuf::from("/x/thread-writer-locks/not-a-thread.lock")]] {
            let v = codex_files(&paths);
            assert!(v.get("session_id").is_none());
            assert!(v["discovery_note"].is_string());
        }
    }
    #[test]
    fn subagent_rollouts_and_locks_do_not_hide_the_main_thread() {
        let dir = std::env::temp_dir().join(format!("graffitty-subagents-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(dir.join("sessions")).unwrap();
        let main = "11111111-1111-4111-8111-111111111111";
        let child = "22222222-2222-4222-8222-222222222222";
        let mut paths = vec![];
        for (id, source) in [(main, json!("cli")), (child, json!({"subagent":{"thread_spawn":{"parent_thread_id":main}}}))] {
            let path = dir.join(format!("sessions/rollout-test-{id}.jsonl"));
            fs::write(&path, format!("{}\n", json!({"type":"session_meta","payload":{"id":id,"source":source}}))).unwrap();
            paths.extend([dir.join(format!("thread-writer-locks/{id}.lock")), path]);
        }
        for _ in 0..2 {
            assert_eq!(codex_files(&paths)["session_id"], main);
            paths.reverse();
        }
        let child_paths: Vec<_> = paths.into_iter().filter(|p| p.to_string_lossy().contains(child)).collect();
        assert!(codex_files(&child_paths).get("session_id").is_none());
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn rollout_and_lock_agree_and_status_comes_from_events() {
        let dir = std::env::temp_dir().join(format!("graffitty-discovery-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(dir.join("sessions/2026/09/30")).unwrap();
        let id = "11111111-1111-4111-8111-111111111111";
        let path = dir.join(format!("sessions/2026/09/30/rollout-test-{id}.jsonl"));
        fs::write(&path, format!("{}\n{}\n{}\n", json!({"type":"session_meta","payload":{"id":id}}),
            json!({"type":"event_msg","payload":{"type":"task_started"}}),
            json!({"type":"event_msg","payload":{"type":"task_complete"}}))).unwrap();
        let v = codex_files(&[path.clone(), dir.join(format!("thread-writer-locks/{id}.lock"))]);
        assert_eq!(v["session_id"], id);
        assert_eq!(v["status"], "idle");
        assert_eq!(v["transcript_path"], json!(path));
        fs::remove_dir_all(dir).unwrap();
    }
}
