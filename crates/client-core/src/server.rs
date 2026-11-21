//! Common private-server discovery and attachment. Only isolated, explicitly
//! owned test servers are stopped when their connection is dropped.
use crate::{
    client::{Client, Event},
    transport::ClientTransport,
};
use anyhow::{Context, Result, bail, ensure};
use graffitty_transport::ipc::{self as ipc, Packet};
use serde_json::{Value, json};
use std::{
    fs,
    io::Read,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};

#[derive(Clone, Debug)]
pub struct Paths {
    pub directory: PathBuf,
    pub descriptor: PathBuf,
}
impl Paths {
    /// Both shipping frontends discover the same owner. Tests can use
    /// in_directory or pass an explicit descriptor to every connection API.
    pub fn discover() -> Result<Self> {
        Self::in_directory(graffitty_protocol::server_state_directory().context("Missing user state directory")?)
    }
    pub fn in_directory(directory: PathBuf) -> Result<Self> {
        private_directory(&directory)?;
        Ok(Self {
            descriptor: directory.join("server.json"),
            directory,
        })
    }
}

pub fn private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    ensure!(
        fs::symlink_metadata(path)?.is_dir(),
        "State directory is not a directory"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

#[derive(Clone)]
pub struct AttachOptions {
    pub workspace: String,
    /// Existing protocol feature/spawn options. Identity fields below always
    /// come from the private descriptor and cannot be overridden by this map.
    pub capabilities: serde_json::Map<String, Value>,
}
impl Default for AttachOptions {
    fn default() -> Self {
        Self {
            workspace: "main".into(),
            capabilities: json!({
                "features":["bell"], "chromium_image_format":"png"
            })
            .as_object()
            .unwrap()
            .clone(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Launch {
    pub binary: PathBuf,
    /// Explicit default shell for a newly started server. `None` leaves the choice
    /// to the server's `[terminal] shell`, `SHELL` and platform default.
    pub shell: Option<String>,
    /// Optional explicit launch directory, principally for isolated fixtures.
    pub working_directory: Option<PathBuf>,
}

pub struct Connection {
    pub client: Client,
    pub descriptor: PathBuf,
    pub server_pid: Option<u32>,
    /// True only when this connection actually started the owner process.
    pub newly_started: bool,
    owned: Option<OwnedServer>,
    _directory: Option<tempfile::TempDir>,
}

impl Connection {
    pub fn attach(path: &Path, options: &AttachOptions) -> Result<Self> {
        let descriptor = read_descriptor(path)?;
        let local = &descriptor["local"];
        let mut peer = ipc::Peer::new(ipc::connect(
            local["url"].as_str().context("Missing IPC URL")?,
        )?);
        let mut auth = Value::Object(options.capabilities.clone());
        auth["type"] = json!("auth_local");
        auth["version"] = json!(graffitty_protocol::VERSION);
        auth["token"] = local["token"].clone();
        ensure!(auth["token"].as_str().is_some(), "Missing local capability");
        auth["workspace"] = json!(options.workspace);
        peer.send(Packet::Text(serde_json::to_vec(&auth)?))?;
        let mut client = Client::new(ClientTransport::Local(peer));
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut queued = Vec::new();
        loop {
            let events = client.poll()?;
            let mut ready = false;
            for event in events {
                match &event {
                    Event::Ready(value) => {
                        ensure!(
                            value["version"] == graffitty_protocol::VERSION,
                            "Unsupported session protocol"
                        );
                        ready = true;
                    }
                    Event::Message(value) if value["type"] == "error" => {
                        bail!(
                            "{}",
                            value["message"]
                                .as_str()
                                .unwrap_or("Session authentication failed")
                        );
                    }
                    _ => {}
                }
                queued.push(event);
                ensure!(
                    queued.len() <= 256,
                    "Too many messages before session authentication"
                );
            }
            if ready {
                break;
            }
            ensure!(
                Instant::now() < deadline,
                "Session authentication timed out"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
        client.queue(queued);
        Ok(Self {
            client,
            descriptor: path.to_owned(),
            server_pid: descriptor_pid(&descriptor),
            newly_started: false,
            owned: None,
            _directory: None,
        })
    }

    /// The server's descriptor lock arbitrates simultaneous frontend starts.
    /// Successfully attached persistent servers outlive every frontend window.
    pub fn connect_or_start(path: &Path, launch: &Launch, options: &AttachOptions) -> Result<Self> {
        match Self::attach(path, options) {
            Ok(connection) => return Ok(connection),
            // Reattachment cannot create a replacement owner after the last
            // session closed (or after an explicit attach to a missing name).
            Err(error) if options.capabilities.get("require_workspace") == Some(&json!(true)) => return Err(error),
            Err(_) => {}
        }
        private_directory(path.parent().context("Missing descriptor directory")?)?;
        let mut child = spawn(path, launch, true)?.map(|child| OwnedServer(Some(child)));
        let mut connection = Self::attach(path, options)?;
        if let Some(mut owner) = child.take() {
            connection.newly_started = true;
            let mut process = owner.0.take().unwrap();
            // Keep only a reaper; it never stops an independently owned server.
            std::thread::spawn(move || {
                let _ = process.wait();
            });
        }
        Ok(connection)
    }

    pub fn isolated(launch: &Launch, options: &AttachOptions) -> Result<Self> {
        let base = if cfg!(unix) {
            PathBuf::from("/tmp")
        } else {
            std::env::temp_dir()
        };
        let directory = tempfile::Builder::new()
            .prefix("gr-client-")
            .tempdir_in(base)?;
        let path = directory.path().join("server.json");
        let owned = OwnedServer(Some(
            spawn(&path, launch, false)?.context("Missing isolated server")?,
        ));
        let mut connection = Self::attach(&path, options)?;
        connection.newly_started = true;
        connection.owned = Some(owned);
        connection._directory = Some(directory);
        Ok(connection)
    }

    /// An attached or persistent owner is never stopped. This is idempotent
    /// and allows a frontend to release its isolated fixture before all UI
    /// callbacks holding the connection have themselves been dropped.
    pub fn stop_owned(&mut self) {
        self.owned.take();
    }

    /// True when dropping this connection stops its (isolated) server.
    pub fn owns_server(&self) -> bool {
        self.owned.is_some()
    }

    /// Hand an isolated owner's lifetime, with its private descriptor
    /// directory, to another client of the same server. A frontend whose
    /// first window retires keeps the sessions of its remaining windows.
    pub fn hand_off_owner(&mut self, to: &mut Connection) {
        if self.owned.is_some() && to.owned.is_none() && to.descriptor == self.descriptor {
            to.owned = self.owned.take();
            to._directory = self._directory.take();
        }
    }
}

fn read_descriptor(path: &Path) -> Result<Value> {
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 1024 * 1024,
        "Session descriptor is too large"
    );
    serde_json::from_slice(&bytes).context("Invalid session descriptor")
}
fn descriptor_pid(value: &Value) -> Option<u32> {
    u32::try_from(value["pid"].as_u64()?).ok()
}

fn spawn(path: &Path, launch: &Launch, persistent: bool) -> Result<Option<Child>> {
    let directory = path.parent().context("Missing descriptor directory")?;
    ensure!(
        launch.binary.is_file(),
        "Session server binary is missing: {}",
        launch.binary.display()
    );
    let log_path = directory.join("server.log");
    let mut options = fs::OpenOptions::new();
    options.create(true).append(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let log = options.open(&log_path)?;
    // The log is appended to across runs; a failure must quote this run only.
    let logged_before = log.metadata()?.len();
    // The server may start in another working directory; a relative binary
    // path would then name a different file.
    let binary = std::path::absolute(&launch.binary)?;
    let mut command = Command::new(&binary);
    command
        .arg("server")
        .arg("--connection")
        .arg(path)
        .arg("--auth-file")
        .arg(directory.join("auth.json"))
        .args(launch.shell.iter().flat_map(|shell| ["--shell", shell.as_str()]))
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    if let Some(cwd) = &launch.working_directory {
        command.current_dir(cwd);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        if persistent {
            command.process_group(0);
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let mut child = command.spawn().context("Start private session server")?;
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if read_descriptor(path).ok().and_then(|d| descriptor_pid(&d)) == Some(child.id()) {
            return Ok(Some(child));
        }
        if let Some(status) = child.try_wait()? {
            if persistent {
                // The lock winner may still be publishing its descriptor. The
                // subsequent authenticated attach proves ownership, not PID reuse.
                let race_deadline = Instant::now() + Duration::from_secs(2);
                while Instant::now() < race_deadline {
                    // A stale descriptor from the previous owner may still be
                    // present while the lock winner starts. Wait for a usable
                    // endpoint, not merely a parseable old JSON file.
                    if read_descriptor(path).ok().is_some_and(|value| {
                        let local = &value["local"];
                        local["url"]
                            .as_str()
                            .is_some_and(|url| ipc::connect(url).is_ok())
                    }) {
                        return Ok(None);
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
            bail!("Session server exited {status}: {}", written_since(&log_path, logged_before));
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("Session server start timed out");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// What a server wrote to its log after `offset`: its last few lines, which
/// hold the reason it stopped. Earlier runs' lines are someone else's story.
fn written_since(log: &Path, offset: u64) -> String {
    use std::io::{Read, Seek, SeekFrom};
    let mut text = String::new();
    if let Ok(mut file) = fs::File::open(log) {
        let mut bytes = Vec::new();
        if file.seek(SeekFrom::Start(offset)).is_ok() && file.read_to_end(&mut bytes).is_ok() {
            text = String::from_utf8_lossy(&bytes).into_owned();
        }
    }
    let lines: Vec<&str> = text.lines().map(str::trim).filter(|line| !line.is_empty()).collect();
    lines[lines.len().saturating_sub(3)..].join("; ")
}

struct OwnedServer(Option<Child>);
impl Drop for OwnedServer {
    fn drop(&mut self) {
        let Some(child) = self.0.as_mut() else {
            return;
        };
        #[cfg(unix)]
        if matches!(child.try_wait(), Ok(None)) {
            unsafe {
                libc::kill(child.id() as i32, libc::SIGTERM);
            }
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while child.try_wait().ok().flatten().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(test)]
mod report_tests {
    #[test]
    fn a_failed_start_quotes_only_what_that_run_wrote() {
        let directory = tempfile::tempdir().unwrap();
        let log = directory.path().join("server.log");
        let earlier = "gft server: Server already running for this connection file\n";
        std::fs::write(&log, format!("{earlier}one\ntwo\n\nthree\ngft server: 127.0.0.1:7183 is in use by nginx (pid 7)\n")).unwrap();
        assert_eq!(
            super::written_since(&log, earlier.len() as u64),
            "two; three; gft server: 127.0.0.1:7183 is in use by nginx (pid 7)"
        );
        assert_eq!(super::written_since(&log, 10_000), "");
    }
}
