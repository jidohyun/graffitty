//! A private local capability for an attached server. Only discovery metadata
//! lives on disk; commands use the ordinary version-1 JSON socket envelope.
//! The frontend pumps requests onto its existing authenticated connection.
use crate::ipc::local_json::{Listener, Stream};
use anyhow::{Context, Result, bail, ensure};
use graffitty_protocol::{
    VERSION,
    controller::{Request, valid_alias},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs,
    io::{BufRead, BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

const MAX_REQUEST: usize = 4 * 1024 * 1024;
const LIMIT: usize = 32;
const TIMEOUT: Duration = Duration::from_secs(35);

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Descriptor {
    pub version: u64,
    pub alias: String,
    pub identity: String,
    pub endpoint: String,
    pub token: String,
}

pub fn state_directory() -> Result<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .or_else(|| std::env::var_os("USERPROFILE"))
                .map(|home| PathBuf::from(home).join(".local/state"))
        })
        .context("Missing user state directory")?;
    Ok(base.join("graffitty"))
}

fn private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)]
    crate::ipc::local_json::restrict_directory(path)?;
    Ok(())
}

fn descriptor(path: &Path) -> Result<Descriptor> {
    let meta = path.symlink_metadata()?;
    ensure!(
        meta.is_file() && meta.len() <= 65536,
        "Invalid remote controller descriptor"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        ensure!(
            meta.uid() == unsafe { libc::geteuid() } && meta.permissions().mode() & 0o077 == 0,
            "Remote controller descriptor must be private and owned by this user"
        );
    }
    let value: Descriptor = serde_json::from_slice(&fs::read(path)?)?;
    ensure!(
        value.version == VERSION && valid_alias(&value.alias),
        "Invalid remote controller protocol or alias"
    );
    Ok(value)
}

fn read_message(stream: &mut Stream) -> Result<Value> {
    let mut bytes = Vec::new();
    BufReader::new(stream)
        .take((MAX_REQUEST + 1) as u64)
        .read_until(b'\n', &mut bytes)?;
    ensure!(
        bytes.len() <= MAX_REQUEST && bytes.last() == Some(&b'\n'),
        "Invalid or oversized controller message"
    );
    Ok(serde_json::from_slice(&bytes)?)
}

fn exchange(desc: &Descriptor, method: &str, params: Value, timeout: Duration) -> Result<Value> {
    let mut stream = Stream::connect(&desc.endpoint)?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;
    let id = uuid::Uuid::new_v4().to_string();
    let mut bytes = serde_json::to_vec(
        &json!({"version":VERSION,"id":id,"token":desc.token,"method":method,"params":params}),
    )?;
    bytes.push(b'\n');
    ensure!(
        bytes.len() <= MAX_REQUEST,
        "Controller request is too large"
    );
    stream.write_all(&bytes)?;
    let reply = read_message(&mut stream)?;
    ensure!(
        reply["id"] == id
            && reply.is_object()
            && reply.get("result").is_some() != reply.get("error").is_some(),
        "Invalid controller reply"
    );
    Ok(reply)
}

/// Probe only read-only discovery before selecting a live capability. Never
/// retry a mutation: a lost acknowledgment can mean input already arrived.
pub fn find(state: &Path, alias: &str) -> Result<Descriptor> {
    ensure!(valid_alias(alias), "Invalid server alias");
    let entries = match fs::read_dir(state.join("remote-controllers")) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            bail!("Unknown or disconnected server alias: {alias}")
        }
        Err(error) => return Err(error.into()),
    };
    let mut found: Option<Descriptor> = None;
    let prefix = format!("{alias}.");
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with(&prefix) || !name.ends_with(".json") {
            continue;
        }
        let candidate = descriptor(&entry.path())?;
        if candidate.alias != alias {
            continue;
        }
        let Ok(reply) = exchange(
            &candidate,
            "controller.describe",
            json!({}),
            Duration::from_millis(250),
        ) else {
            continue;
        };
        if reply["result"]["alias"] != alias || reply["result"]["identity"] != candidate.identity {
            continue;
        }
        if let Some(existing) = &found {
            ensure!(
                existing.identity == candidate.identity,
                "Ambiguous server alias: {alias}"
            );
        } else {
            found = Some(candidate);
        }
    }
    found.with_context(|| format!("Unknown or disconnected server alias: {alias}"))
}

pub fn call(state: &Path, alias: &str, method: &str, params: Value) -> Result<Value> {
    Request {
        version: VERSION,
        method: method.into(),
        params: params.clone(),
    }
    .validate()
    .map_err(anyhow::Error::msg)?;
    let desc = find(state, alias)?;
    let mut reply = exchange(&desc, method, params, TIMEOUT + Duration::from_secs(2))
        .context("Remote control disconnected or timed out; delivery may have started (request was not retried)")?;
    if method == "pane.list"
        && let Some(panes) = reply["result"]["panes"].as_array_mut()
    {
        for pane in panes {
            if let Some(id) = pane["id"].as_str() {
                pane["target"] = json!(format!("{alias}/{id}"));
            }
            if let Some(position) = pane["position_target"].as_str() {
                pane["position_target"] = json!(format!("{alias}/{position}"));
            }
            pane["server"] = json!(alias);
        }
    }
    Ok(reply)
}

struct Queued {
    request: Request,
    deadline: Instant,
    reply: mpsc::SyncSender<Value>,
}
struct Pending {
    deadline: Instant,
    reply: mpsc::SyncSender<Value>,
}

/// Drop on every disconnect, including transient network loss. A new login
/// gets a fresh capability and cannot inherit an old input queue.
pub struct Bridge {
    incoming: mpsc::Receiver<Queued>,
    pending: BTreeMap<u64, Pending>,
    sequence: u64,
    active: Arc<AtomicBool>,
    wakeup: Option<Arc<AtomicBool>>,
    path: PathBuf,
    _directory: tempfile::TempDir,
}
impl Bridge {
    pub fn new(state: &Path, alias: &str, identity: &str) -> Result<Self> {
        Self::with_wakeup(state, alias, identity, None)
    }
    pub fn with_wakeup(
        state: &Path,
        alias: &str,
        identity: &str,
        wakeup: Option<Arc<AtomicBool>>,
    ) -> Result<Self> {
        ensure!(
            valid_alias(alias),
            "Server alias must be 1–64 letters, numbers, dots, underscores or hyphens, starting with a letter or number"
        );
        ensure!(!identity.is_empty(), "Missing server identity");
        let directory = tempfile::Builder::new()
            .prefix("gft-control-")
            .tempdir_in(std::env::temp_dir())?;
        private_directory(directory.path())?;
        let listener = Listener::bind(directory.path())?;
        listener.set_nonblocking(true)?;
        let desc = Descriptor {
            version: VERSION,
            alias: alias.into(),
            identity: identity.into(),
            endpoint: listener.endpoint(directory.path())?,
            token: uuid::Uuid::new_v4().to_string(),
        };
        let root = state.join("remote-controllers");
        private_directory(&root)?;
        let path = root.join(format!("{alias}.{}.json", uuid::Uuid::new_v4()));
        let mut file = tempfile::NamedTempFile::new_in(&root)?;
        serde_json::to_writer(&mut file, &desc)?;
        file.persist(&path).map_err(|e| e.error)?;
        let (queue, incoming) = mpsc::sync_channel(LIMIT);
        let active = Arc::new(AtomicBool::new(true));
        let alive = active.clone();
        let count = Arc::new(AtomicUsize::new(0));
        let signal = wakeup.clone();
        std::thread::Builder::new()
            .name("remote-controller".into())
            .spawn(move || {
                while alive.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok(mut stream) => {
                            if count.load(Ordering::Relaxed) >= LIMIT {
                                continue;
                            }
                            count.fetch_add(1, Ordering::Relaxed);
                            let count = count.clone();
                            let queue = queue.clone();
                            let desc = desc.clone();
                            let alive = alive.clone();
                            let wakeup = wakeup.clone();
                            std::thread::spawn(move || {
                                let _ =
                                    serve(&mut stream, &desc, &queue, &alive, wakeup.as_deref());
                                count.fetch_sub(1, Ordering::Relaxed);
                            });
                        }
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(Duration::from_millis(5))
                        }
                        Err(_) => break,
                    }
                }
            })?;
        Ok(Self {
            incoming,
            pending: BTreeMap::new(),
            sequence: 0,
            active,
            wakeup: signal,
            path,
            _directory: directory,
        })
    }

    /// IDs are negative on the wire, disjoint from frontend request counters.
    pub fn poll(&mut self) -> Vec<Value> {
        if let Some(wakeup) = &self.wakeup {
            wakeup.store(false, Ordering::Release);
        }
        self.pending.retain(|_, pending| {
            if Instant::now() < pending.deadline {
                return true;
            }
            let _ = pending.reply.try_send(error(
                "remote_timeout",
                "Remote request timed out; delivery may have started",
            ));
            false
        });
        let mut requests = Vec::new();
        for _ in 0..LIMIT {
            let Ok(queued) = self.incoming.try_recv() else {
                break;
            };
            if Instant::now() >= queued.deadline {
                continue;
            }
            if self.pending.len() >= LIMIT {
                let _ = queued
                    .reply
                    .try_send(error("busy", "Too many pending remote requests"));
                continue;
            }
            self.sequence += 1;
            let id = self.sequence;
            requests.push(
                json!({"type":"controller_rpc","request":-(id as i64),"call":queued.request}),
            );
            self.pending.insert(
                id,
                Pending {
                    deadline: queued.deadline,
                    reply: queued.reply,
                },
            );
        }
        requests
    }

    pub fn complete(&mut self, message: &Value) -> bool {
        let Some(id) = message["request"]
            .as_i64()
            .filter(|n| *n < 0)
            .and_then(i64::checked_neg)
            .map(|n| n as u64)
        else {
            return false;
        };
        let Some(pending) = self.pending.remove(&id) else {
            return false;
        };
        let value = if let Some(error) = message.get("error") {
            json!({"error":error})
        } else if let Some(result) = message.get("result") {
            json!({"result":result})
        } else {
            error(
                "remote_error",
                message["message"]
                    .as_str()
                    .unwrap_or("Invalid remote reply"),
            )
        };
        let _ = pending.reply.try_send(value);
        true
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        self.active.store(false, Ordering::Release);
        if let Some(wakeup) = &self.wakeup {
            wakeup.store(false, Ordering::Release);
        }
        let _ = fs::remove_file(&self.path);
        for (_, pending) in std::mem::take(&mut self.pending) {
            let _ = pending.reply.try_send(error(
                "remote_disconnected",
                "Server disconnected; request was not retried",
            ));
        }
    }
}

fn error(code: &str, message: &str) -> Value {
    json!({"error":{"code":code,"message":message}})
}

/// A headless attachment uses exactly the same bridge as a GUI adapter. No
/// terminal subscriptions, input replay or reconnection are implicit here.
pub struct Attached {
    transport: crate::ClientTransport,
    bridge: Bridge,
}
impl Attached {
    pub fn new(
        transport: crate::ClientTransport,
        state: &Path,
        alias: &str,
        identity: &str,
    ) -> Result<Self> {
        Ok(Self {
            transport,
            bridge: Bridge::new(state, alias, identity)?,
        })
    }
    pub fn poll(&mut self) -> Result<()> {
        for request in self.bridge.poll() {
            self.transport
                .send(crate::ipc::Packet::Text(serde_json::to_vec(&request)?))?;
        }
        match self.transport.flush() {
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            result => result?,
        }
        for _ in 0..128 {
            match self.transport.read() {
                Ok(crate::ipc::Packet::Text(bytes)) => {
                    self.bridge
                        .complete(&serde_json::from_slice::<Value>(&bytes)?);
                }
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error.into()),
            }
        }
        Ok(())
    }
}

fn serve(
    stream: &mut Stream,
    desc: &Descriptor,
    queue: &mpsc::SyncSender<Queued>,
    active: &AtomicBool,
    wakeup: Option<&AtomicBool>,
) -> Result<()> {
    // On macOS an accepted socket inherits the listener's nonblocking flag.
    //
    // Large upload chunks can arrive in several reads; their worker must wait
    // for the rest of the bounded request rather than dropping a partial
    // line.
    stream.set_nonblocking(false)?;
    stream.set_read_timeout(Some(Duration::from_secs(3)))?;
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    let value = read_message(stream)?;
    let mut response = if value["token"] != desc.token {
        error("unauthorized", "Invalid controller capability")
    } else if value["version"] != VERSION || !value["params"].is_object() {
        error("invalid_request", "Expected version 1 and object params")
    } else if !active.load(Ordering::Acquire) {
        error("remote_disconnected", "Server disconnected")
    } else if value["method"] == "controller.describe" {
        json!({"result":{"alias":desc.alias,"identity":desc.identity}})
    } else {
        let request = Request {
            version: VERSION,
            method: value["method"].as_str().unwrap_or("").into(),
            params: value["params"].clone(),
        };
        match request.validate() {
            Err(message) => error("invalid_request", message),
            Ok(()) => {
                let (reply, receiver) = mpsc::sync_channel(1);
                let deadline = Instant::now() + TIMEOUT;
                if queue
                    .try_send(Queued {
                        request,
                        deadline,
                        reply,
                    })
                    .is_err()
                {
                    error("busy", "Remote control queue is full or closed")
                } else {
                    if let Some(wakeup) = wakeup {
                        wakeup.store(true, Ordering::Release);
                    }
                    loop {
                        match receiver.recv_timeout(Duration::from_millis(100)) {
                            Ok(reply) => break reply,
                            Err(mpsc::RecvTimeoutError::Disconnected) => {
                                break error("remote_disconnected", "Server disconnected");
                            }
                            Err(_) if !active.load(Ordering::Acquire) => {
                                break error(
                                    "remote_disconnected",
                                    "Server disconnected; request was not retried",
                                );
                            }
                            Err(_) if Instant::now() >= deadline => {
                                break error(
                                    "remote_timeout",
                                    "Remote request timed out; delivery may have started",
                                );
                            }
                            Err(_) => {}
                        }
                    }
                }
            }
        }
    };
    response["id"] = value["id"].clone();
    let mut bytes = serde_json::to_vec(&response)?;
    bytes.push(b'\n');
    stream.write_all(&bytes)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn next(bridge: &mut Bridge) -> Value {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if let Some(request) = bridge.poll().pop() {
                return request;
            }
            assert!(Instant::now() < deadline, "No request arrived");
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn fragmented_upload_request_waits_for_its_complete_json_line() {
        let state = tempfile::tempdir().unwrap();
        let mut bridge = Bridge::new(state.path(), "build", "fixture-a").unwrap();
        let desc = find(state.path(), "build").unwrap();
        let caller = std::thread::spawn(move || {
            let mut stream = Stream::connect(&desc.endpoint).unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            let mut bytes = serde_json::to_vec(&json!({"version":VERSION,"id":"fragmented","token":desc.token,
                "method":"terminal.put","params":{"upload":{"data":"A".repeat(32768)}}})).unwrap();
            bytes.push(b'\n');
            for part in bytes.chunks(1024) {
                stream.write_all(part).unwrap();
                std::thread::sleep(Duration::from_millis(2));
            }
            read_message(&mut stream).unwrap()
        });
        let request = next(&mut bridge);
        assert_eq!(request["call"]["params"]["upload"]["data"].as_str().unwrap().len(), 32768);
        assert!(bridge.complete(&json!({"request":request["request"],"result":{"received":24576}})));
        assert_eq!(caller.join().unwrap()["result"]["received"], 24576);
    }

    #[test]
    fn capabilities_bound_methods_and_correlate_exactly_once() {
        let state = tempfile::tempdir().unwrap();
        let mut bridge = Bridge::new(state.path(), "build", "fixture-a").unwrap();
        let desc = find(state.path(), "build").unwrap();
        let mut wrong = desc.clone();
        wrong.token = "wrong".into();
        assert_eq!(
            exchange(
                &wrong,
                "terminal.type",
                json!({"target":"%1","text":"wrong"}),
                TIMEOUT
            )
            .unwrap()["error"]["code"],
            "unauthorized"
        );
        assert_eq!(
            exchange(&desc, "server.restart", json!({}), TIMEOUT).unwrap()["error"]["code"],
            "invalid_request"
        );
        assert!(bridge.poll().is_empty());
        let path = state.path().to_owned();
        let caller = std::thread::spawn(move || {
            call(
                &path,
                "build",
                "terminal.type",
                json!({"target":"%12","text":"한🙂"}),
            )
            .unwrap()
        });
        let request = next(&mut bridge);
        assert_eq!(
            request["call"]["params"],
            json!({"target":"%12","text":"한🙂"})
        );
        assert_eq!(request["call"]["version"], 1);
        let response = json!({"request":request["request"],"result":{"keys_sent":2}});
        assert!(bridge.complete(&response));
        assert!(!bridge.complete(&response));
        assert_eq!(caller.join().unwrap()["result"]["keys_sent"], 2);
    }

    #[test]
    fn aliases_are_exact_and_conflicts_fail_closed() {
        let state = tempfile::tempdir().unwrap();
        let first = Bridge::new(state.path(), "build", "fixture-a").unwrap();
        let second = Bridge::new(state.path(), "build", "fixture-a").unwrap();
        assert!(find(state.path(), "build").is_ok());
        assert!(find(state.path(), "buil").is_err());
        assert!(find(state.path(), "Build").is_err());
        let conflict = Bridge::new(state.path(), "build", "fixture-b").unwrap();
        assert!(
            find(state.path(), "build")
                .err()
                .unwrap()
                .to_string()
                .contains("Ambiguous")
        );
        drop(conflict);
        drop(first);
        drop(second);
        assert!(find(state.path(), "build").is_err());
    }

    #[test]
    fn disconnect_revokes_inflight_work_without_replaying_on_a_new_connection() {
        let state = tempfile::tempdir().unwrap();
        let mut bridge = Bridge::new(state.path(), "build", "fixture-a").unwrap();
        let path = state.path().to_owned();
        let caller = std::thread::spawn(move || {
            call(
                &path,
                "build",
                "terminal.press",
                json!({"target":"%1","key":"Enter"}),
            )
            .unwrap()
        });
        next(&mut bridge);
        drop(bridge);
        assert_eq!(
            caller.join().unwrap()["error"]["code"],
            "remote_disconnected"
        );
        let mut reconnected = Bridge::new(state.path(), "build", "fixture-a").unwrap();
        assert!(reconnected.poll().is_empty());
    }

    #[test]
    fn pane_listing_returns_copyable_server_scoped_targets() {
        let state = tempfile::tempdir().unwrap();
        let mut bridge = Bridge::new(state.path(), "build", "fixture-a").unwrap();
        let path = state.path().to_owned();
        let caller = std::thread::spawn(move || {
            call(&path, "build", "pane.list", json!({"target":""})).unwrap()
        });
        let request = next(&mut bridge);
        bridge.complete(&json!({"request":request["request"],"result":{"panes":[{"id":"%1","position_target":"$0:1.1"}]}}));
        let reply = caller.join().unwrap();
        assert_eq!(reply["result"]["panes"][0]["target"], "build/%1");
        assert_eq!(
            reply["result"]["panes"][0]["position_target"],
            "build/$0:1.1"
        );
    }
}
