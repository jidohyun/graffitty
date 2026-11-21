//! One Chromium process and private CDP connection, shared by window panes.
use super::*;
use std::collections::BTreeMap;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::net::UnixListener;

const DIAGNOSTIC_TAIL_BYTES: u64 = 64 * 1024;

/// Runtime threads stop Chromium and remove its temporary session directory.
static CLEANUP: Mutex<Vec<thread::JoinHandle<()>>> = Mutex::new(Vec::new());

/// Server exit must not cut that cleanup short: a detached thread dies with
/// the process and leaves the whole temporary profile behind.
pub fn finish_all(timeout: Duration) {
    let deadline = Instant::now() + timeout;
    for cleanup in std::mem::take(&mut *CLEANUP.lock().unwrap()) {
        while !cleanup.is_finished() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        if cleanup.is_finished() {
            let _ = cleanup.join();
        }
    }
}

/// The host's own last fatal message, e.g. "GPU process isn't usable.
/// Goodbye.". Helper processes log FATAL lines too, without ending the host.
fn host_fatal(tail: &str, pid: u32) -> Option<String> {
    let prefix = format!("[{pid}:");
    tail.lines()
        .rev()
        .find(|line| line.starts_with(&prefix) && line.contains(":FATAL:"))
        .and_then(|line| line.split_once("] "))
        .map(|(_, message)| message.trim().to_owned())
        .filter(|message| !message.is_empty())
}

fn diagnostic_tail(path: &std::path::Path) -> std::io::Result<String> {
    let mut file = fs::File::open(path)?;
    let offset = file.metadata()?.len().saturating_sub(DIAGNOSTIC_TAIL_BYTES);
    file.seek(SeekFrom::Start(offset))?;
    let mut bytes = Vec::new();
    file.take(DIAGNOSTIC_TAIL_BYTES).read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

enum Request {
    Connect(u64, PeerSink),
    Send(u64, Value),
    Disconnect(u64),
}
struct PeerSink {
    tx: mpsc::SyncSender<Message>,
    failure: Arc<Mutex<Option<String>>>,
}
impl PeerSink {
    fn send(&self, message: Message) -> bool {
        match self.tx.try_send(message) {
            Ok(()) => true,
            Err(mpsc::TrySendError::Full(_)) => {
                *self.failure.lock().unwrap() = Some(
                    "Chromium control reply queue overflowed (1024 pending messages)".into(),
                );
                false
            }
            Err(mpsc::TrySendError::Disconnected(_)) => false,
        }
    }
}

pub struct Runtime {
    pub pid: u32,
    pub profile: PathBuf,
    pub directory: PathBuf,
    pub temporary: bool,
    pub closing: Mutex<std::collections::BTreeSet<i64>>,
    tx: mpsc::SyncSender<Request>,
    next: std::sync::atomic::AtomicU64,
    stopping: Arc<AtomicBool>,
    ready: Arc<AtomicBool>,
    failure: Arc<Mutex<Option<String>>>,
}
pub struct Peer {
    runtime: Arc<Runtime>,
    id: u64,
    rx: mpsc::Receiver<Message>,
    failure: Arc<Mutex<Option<String>>>,
}
impl Runtime {
    pub fn new(
        mut child: std::process::Child,
        listener: UnixListener,
        profile: PathBuf,
        temporary: bool,
        lock: fs::File,
        control_directory: PathBuf,
        session_directory: SessionDirectory,
    ) -> Arc<Self> {
        let (tx, rx) = mpsc::sync_channel(1024);
        let stopping = Arc::new(AtomicBool::new(false));
        let ready = Arc::new(AtomicBool::new(false));
        let failure = Arc::new(Mutex::new(None));
        let runtime = Arc::new(Self {
            pid: child.id(),
            profile: profile.clone(),
            directory: session_directory.path.clone(),
            temporary,
            closing: Mutex::default(),
            tx,
            next: std::sync::atomic::AtomicU64::new(1),
            stopping: stopping.clone(),
            ready: ready.clone(),
            failure: failure.clone(),
        });
        let cleanup = thread::spawn(move || {
            // Keep receivers alive until the termination reason is published.
            // Otherwise their read wakes first and reports an unexplained close.
            let mut peers = BTreeMap::<u64, PeerSink>::new();
            let mut run = || -> Result<()> {
                let deadline = Instant::now() + Duration::from_secs(60);
                let mut control = loop {
                    match listener.accept() {
                        Ok((socket, _)) => {
                            socket.set_nonblocking(true)?;
                            break crate::chromium_capture::Control::new(socket)?;
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                        Err(e) => return Err(e.into()),
                    }
                    if stopping.load(Ordering::Relaxed)
                        || child.try_wait()?.is_some()
                        || Instant::now() > deadline
                    {
                        return Err("Chromium did not connect".into());
                    }
                    thread::sleep(Duration::from_millis(2));
                };
                ready.store(true, Ordering::Release);
                let mut pending = HashMap::<u64, (u64, Value)>::new();
                let mut sessions = HashMap::<String, u64>::new();
                let mut sequence = 0u64;
                while !stopping.load(Ordering::Relaxed) {
                    for request in rx.try_iter().take(128) {
                        match request {
                            Request::Connect(id, sender) => {
                                peers.insert(id, sender);
                            }
                            Request::Disconnect(id) => {
                                peers.remove(&id);
                                pending.retain(|_, (peer, _)| *peer != id);
                                sessions.retain(|_, peer| *peer != id);
                            }
                            Request::Send(peer, mut value) => {
                                if pending.len() >= 8192 {
                                    return Err("Chromium request limit exceeded".into());
                                }
                                sequence += 1;
                                pending.insert(sequence, (peer, value["id"].clone()));
                                value["id"] = json!(sequence);
                                control.send(Message::Text(value.to_string().into()))?;
                            }
                        }
                    }
                    match control.read() {
                        Ok(Message::Text(text)) => {
                            let mut value: Value = serde_json::from_str(&text)?;
                            if let Some(id) = value["id"].as_u64() {
                                if let Some((peer, original)) = pending.remove(&id) {
                                    if let Some(session) = value["result"]["sessionId"].as_str() {
                                        sessions.insert(session.into(), peer);
                                    }
                                    value["id"] = original;
                                    if let Some(sender) = peers.get(&peer) {
                                        if !sender.send(Message::Text(value.to_string().into())) {
                                            peers.remove(&peer);
                                        }
                                    }
                                }
                            } else {
                                let owner = value["sessionId"]
                                    .as_str()
                                    .and_then(|s| sessions.get(s))
                                    .copied();
                                if let Some(peer) = owner {
                                    if let Some(child) = value["params"]["sessionId"].as_str() {
                                        sessions.insert(child.into(), peer);
                                    }
                                }
                                let message = Message::Text(value.to_string().into());
                                peers.retain(|peer, sender| {
                                    owner.is_some_and(|owner| owner != *peer)
                                        || sender.send(message.clone())
                                });
                            }
                        }
                        Ok(_) => {}
                        Err(tungstenite::Error::Io(e))
                            if matches!(
                                e.kind(),
                                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                            ) =>
                        {
                            thread::sleep(Duration::from_millis(1))
                        }
                        Err(e) => return Err(e.into()),
                    }
                }
                let _ = control.send(Message::Text(
                    json!({"id":sequence+1,"method":"Browser.close","params":{}})
                        .to_string()
                        .into(),
                ));
                Ok(())
            };
            if let Err(error) = run() {
                // An aborting host closes its control socket while it is still
                // writing its crash report; wait for the exit that explains it.
                let deadline = Instant::now() + Duration::from_secs(2);
                let mut exited = child.try_wait().ok().flatten();
                while exited.is_none() && Instant::now() < deadline {
                    thread::sleep(Duration::from_millis(20));
                    exited = child.try_wait().ok().flatten();
                }
                // Its control socket closing is a consequence of the exit, not detail.
                let detail = match exited {
                    Some(status) => {
                        let fatal = diagnostic_tail(&session_directory.path.join("cef.log"))
                            .ok()
                            .and_then(|tail| host_fatal(&tail, child.id()))
                            .map(|message| format!(": {message}"))
                            .unwrap_or_default();
                        format!("Chromium host exited ({status}){fatal}")
                    }
                    None => format!("Chromium control connection failed: {error}"),
                };
                eprintln!("Chromium session stopped: {detail}");
                *failure.lock().unwrap() = Some(detail);
            }
            peers.clear();
            stopping.store(true, Ordering::Release);
            finish_chromium(&mut child, Duration::from_secs(2));
            if failure.lock().unwrap().is_some() {
                // The disposable directory is deleted below. Retain Chromium's
                // fatal CHECK/GPU diagnostics in the owner's server log first.
                if let Ok(tail) = diagnostic_tail(&session_directory.path.join("cef.log")) {
                    if !tail.is_empty() {
                        eprintln!("Chromium host diagnostic tail:\n{tail}");
                    }
                }
            }
            drop(lock);
            let _ = fs::remove_dir_all(control_directory);
            drop(session_directory);
        });
        let mut threads = CLEANUP.lock().unwrap();
        threads.retain(|thread| !thread.is_finished());
        threads.push(cleanup);
        runtime
    }
    pub fn connect(self: &Arc<Self>) -> Result<Peer> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::sync_channel(1024);
        let failure = Arc::new(Mutex::new(None));
        self.tx.send(Request::Connect(
            id,
            PeerSink {
                tx,
                failure: failure.clone(),
            },
        ))?;
        Ok(Peer {
            runtime: self.clone(),
            id,
            rx,
            failure,
        })
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Relaxed);
    }
}
impl Peer {
    pub fn wait_ready(&self) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(65);
        while !self.runtime.ready.load(Ordering::Acquire) {
            if self.runtime.stopping.load(Ordering::Acquire) || Instant::now() >= deadline {
                return Err("Chromium failed to initialize its control connection".into());
            }
            thread::sleep(Duration::from_millis(5));
        }
        Ok(())
    }
    fn disconnected(&self) -> tungstenite::Error {
        let detail = self
            .failure
            .lock()
            .unwrap()
            .clone()
            .or_else(|| self.runtime.failure.lock().unwrap().clone())
            .unwrap_or_else(|| "Chromium control connection is no longer available".into());
        std::io::Error::new(std::io::ErrorKind::ConnectionAborted, detail).into()
    }
    pub fn send(&mut self, message: Message) -> std::result::Result<(), tungstenite::Error> {
        let Message::Text(text) = message else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Chromium control accepts only text messages",
            )
            .into());
        };
        let value = serde_json::from_str(&text)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error))?;
        match self.runtime.tx.try_send(Request::Send(self.id, value)) {
            Ok(()) => Ok(()),
            Err(mpsc::TrySendError::Full(_)) => Err(tungstenite::Error::WriteBufferFull(Box::new(
                Message::Text(text),
            ))),
            Err(mpsc::TrySendError::Disconnected(_)) => Err(self.disconnected()),
        }
    }
    pub fn read(&mut self) -> std::result::Result<Message, tungstenite::Error> {
        match self.rx.recv_timeout(Duration::from_millis(2)) {
            Ok(value) => Ok(value),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                Err(std::io::Error::from(std::io::ErrorKind::WouldBlock).into())
            }
            Err(_) => Err(self.disconnected()),
        }
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        let _ = self.runtime.tx.try_send(Request::Disconnect(self.id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer() -> (Peer, mpsc::Receiver<Request>, mpsc::SyncSender<Message>) {
        let (tx, requests) = mpsc::sync_channel(1);
        let (messages, rx) = mpsc::sync_channel(1);
        let runtime = Arc::new(Runtime {
            pid: 0,
            profile: PathBuf::new(),
            directory: PathBuf::new(),
            temporary: true,
            closing: Mutex::default(),
            tx,
            next: std::sync::atomic::AtomicU64::new(2),
            stopping: Arc::new(AtomicBool::new(false)),
            ready: Arc::new(AtomicBool::new(true)),
            failure: Arc::new(Mutex::new(None)),
        });
        (
            Peer {
                runtime,
                id: 1,
                rx,
                failure: Arc::new(Mutex::new(None)),
            },
            requests,
            messages,
        )
    }

    #[test]
    fn crash_log_tail_is_bounded_and_retains_the_last_fatal_message() {
        let path = std::env::temp_dir().join(format!("graffitty-cef-log-{}", uuid::Uuid::new_v4()));
        let mut contents = vec![b'x'; DIAGNOSTIC_TAIL_BYTES as usize * 2];
        contents.extend_from_slice(b"\nFATAL: GPU process is not usable\n");
        fs::write(&path, &contents).unwrap();
        let tail = diagnostic_tail(&path).unwrap();
        fs::remove_file(path).unwrap();
        assert_eq!(tail.len(), DIAGNOSTIC_TAIL_BYTES as usize);
        assert!(tail.ends_with("FATAL: GPU process is not usable\n"));
    }

    #[test]
    fn only_the_host_process_fatal_message_explains_its_exit() {
        let tail = "[85327:1:1025/015032.122619:FATAL:ui/gl/init/gl_factory_mac.cc:60] NOTREACHED hit.\n\
            [71989:2:1025/015032.272163:ERROR:content/browser/gpu/gpu_process_host.cc:1089] GPU process exited unexpectedly: exit_code=6\n\
            [71989:2:1025/015032.272212:FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:416] GPU process isn't usable. Goodbye.\n";
        assert_eq!(host_fatal(tail, 71989).as_deref(), Some("GPU process isn't usable. Goodbye."));
        assert_eq!(host_fatal(tail, 4242), None, "A recovered helper's fatal message is not the host's");
        assert_eq!(host_fatal("[71989:2:1025/015032.1:ERROR:x.cc:1] killed\n", 71989), None);
    }

    #[test]
    fn request_backpressure_is_not_reported_as_normal_connection_close() {
        let (mut peer, requests, _messages) = peer();
        let first = Message::Text(r#"{"id":1,"method":"Input.dispatchMouseEvent"}"#.into());
        let second = Message::Text(r#"{"id":2,"method":"Input.dispatchMouseEvent"}"#.into());
        peer.send(first).unwrap();
        let error = peer.send(second.clone()).unwrap_err();
        assert!(
            matches!(error, tungstenite::Error::WriteBufferFull(message) if *message == second)
        );
        assert!(matches!(requests.recv().unwrap(), Request::Send(1, value) if value["id"] == 1));
        peer.send(second).unwrap();
        assert!(matches!(requests.recv().unwrap(), Request::Send(1, value) if value["id"] == 2));
    }

    #[test]
    fn a_window_receives_the_runtime_failure_reason() {
        let (mut peer, _requests, messages) = peer();
        *peer.runtime.failure.lock().unwrap() =
            Some("Chromium host exited (signal: 6): private control EOF".into());
        drop(messages);
        let error = peer.read().unwrap_err();
        assert!(
            error
                .to_string()
                .contains("Chromium host exited (signal: 6)")
        );
        assert!(!matches!(error, tungstenite::Error::ConnectionClosed));
    }

    #[test]
    fn slow_window_reply_overflow_is_reported_only_to_that_window() {
        let (mut peer, _requests, messages) = peer();
        let sink = PeerSink {
            tx: messages,
            failure: peer.failure.clone(),
        };
        assert!(sink.send(Message::Text("first".into())));
        assert!(!sink.send(Message::Text("second".into())));
        drop(sink);
        assert_eq!(peer.read().unwrap(), Message::Text("first".into()));
        assert!(
            peer.read()
                .unwrap_err()
                .to_string()
                .contains("reply queue overflowed")
        );
        assert!(peer.runtime.failure.lock().unwrap().is_none());
    }
}
