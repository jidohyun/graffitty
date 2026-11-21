//! Connect the server to its terminal holders.
//!
//! - Start holders or take over holders left by a previous server.
//!   Their terminal programs keep running during takeover.
//! - Route each terminal's frames to its session.
//! - Send goodbye on shutdown or planned restart.
//!
//! Adapted from herdr-core's `crates/herdr-core/src/runtime.rs`
//! (`start_holder`, `attach_all`, `take_over`, `read_holder`, `holder_frames`,
//! `goodbye`, and `nudge`) and `client.rs` (`build_id`, `wait_for_socket`).
//! See https://github.com/herdrdev/herdr-core and
//! `licenses/herdr-core-Apache-2.0.txt`.
//!
//! Graffitty's link thread forwards frames through per-session channels.
//! The server polls those channels in its main loop. `owner_state` holds
//! the terminal registry and screen snapshots. If the link reader fails,
//! its terminals end and the server skips takeover.

use crate::holder_proto::{self as proto, Exit, Goodbye, HeldTerminal};
use std::collections::HashMap;
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
#[cfg(windows)]
use uds_windows::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

/// Output chunks a session may have queued before its holder link waits.
const ROUTE_CHUNKS: usize = 256;
/// How long a spawn may take before the session reports failure.
const SPAWN_WAIT: Duration = Duration::from_secs(10);
/// How often a session refreshes its foreground process group.
const FOREGROUND_EVERY: Duration = Duration::from_millis(250);

/// Which binary this is: a server of another build lets that build's holder
/// drain and starts its own for new terminals.
pub fn build_id() -> String {
    static BUILD: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    BUILD
        .get_or_init(|| {
            let file = std::env::current_exe().and_then(std::fs::metadata);
            #[cfg(unix)]
            let identity = file.map(|m| {
                use std::os::unix::fs::MetadataExt;
                format!("{}:{}:{}", m.dev(), m.ino(), m.mtime())
            });
            // An upgrade writes a new file here. Its size and write time identify the build.
            #[cfg(windows)]
            let identity = file.map(|m| {
                use std::os::windows::fs::MetadataExt;
                format!("{}:{}", m.file_size(), m.last_write_time())
            });
            identity
                .map(|identity| format!("{}:{identity}", env!("GRAFFITTY_VERSION")))
                .unwrap_or_else(|_| env!("GRAFFITTY_VERSION").into())
        })
        .clone()
}

/// Starts `cmd` as an independent process. It keeps running when the process
/// that started it ends, for example when that terminal closes or its job ends.
pub(crate) fn spawn_apart(cmd: &mut std::process::Command) -> io::Result<std::process::Child> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
        cmd.spawn()
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        const ACCESS_DENIED: i32 = 5;
        cmd.creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB);
        match cmd.spawn() {
            // The caller's job object forbids leaving it. Start the process inside the job.
            Err(error) if error.raw_os_error() == Some(ACCESS_DENIED) => {
                cmd.creation_flags(CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP);
                cmd.spawn()
            }
            started => started,
        }
    }
}

fn wait_for_socket(path: &Path) -> io::Result<UnixStream> {
    let start = Instant::now();
    loop {
        if let Ok(stream) = UnixStream::connect(path) {
            return Ok(stream);
        }
        if start.elapsed() > Duration::from_secs(5) {
            return Err(io::Error::other("the terminal holder did not start within 5 s"));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Where one held terminal's frames go.
struct Route {
    output: mpsc::SyncSender<Vec<u8>>,
    state: Arc<RouteState>,
}

#[derive(Default)]
struct RouteState {
    exit: Mutex<Option<Exit>>,
    foreground: AtomicI32,
}

/// One holder process and our connection to it.
pub struct Link {
    writer: Mutex<mpsc::Sender<Vec<u8>>>,
    pub instance: String,
    pub pid: u32,
    /// Of our build: it takes new terminals. Others only drain.
    current: bool,
    routes: Mutex<HashMap<u32, Route>>,
    pending: Mutex<HashMap<u32, mpsc::SyncSender<Result<proto::Spawned, String>>>>,
    bye: Mutex<Option<mpsc::Receiver<()>>>,
    alive: AtomicBool,
}

impl Link {
    fn send(&self, frame: Vec<u8>) {
        let _ = self.writer.lock().unwrap_or_else(|p| p.into_inner()).send(frame);
    }

    fn route(&self, id: u32) -> (mpsc::Receiver<Vec<u8>>, Arc<RouteState>) {
        let (output, received) = mpsc::sync_channel(ROUTE_CHUNKS);
        let state = Arc::new(RouteState { foreground: AtomicI32::new(-1), ..Default::default() });
        let mut routes = self.routes.lock().unwrap_or_else(|p| p.into_inner());
        routes.insert(id, Route { output, state: state.clone() });
        (received, state)
    }

    /// The holder is gone (or we stopped reading it): every program it ran
    /// ended with it, as far as this server can tell.
    fn lost(&self) {
        eprintln!("[holder] lost terminal holder {} (pid {}); its terminals ended", self.instance, self.pid);
        self.alive.store(false, Ordering::SeqCst);
        for route in self.routes.lock().unwrap_or_else(|p| p.into_inner()).values() {
            let mut exit = route.state.exit.lock().unwrap_or_else(|p| p.into_inner());
            exit.get_or_insert(Exit { code: None, signal: None });
        }
        for (_, waiting) in self.pending.lock().unwrap_or_else(|p| p.into_inner()).drain() {
            let _ = waiting.try_send(Err("the terminal holder exited".into()));
        }
        crate::wake::notify();
    }

    /// Handles the holder's frames until it says goodbye (true) or the link ends (false).
    fn frames(&self, stream: &mut UnixStream) -> io::Result<bool> {
        while let Some((kind, id, payload)) = proto::read(stream)? {
            match kind {
                proto::OUTPUT => {
                    let output = self.routes.lock().unwrap_or_else(|p| p.into_inner()).get(&id).map(|r| r.output.clone());
                    if let Some(output) = output {
                        // A session that stopped reading (closing) must not stall the others.
                        let _ = output.send(payload);
                        crate::wake::notify();
                    }
                }
                proto::SPAWNED | proto::SPAWN_FAILED => {
                    let result = if kind == proto::SPAWNED {
                        proto::parse::<proto::Spawned>(&payload).map_err(|e| e.to_string())
                    } else {
                        Err(proto::parse::<proto::SpawnFailed>(&payload).map_or_else(|e| e.to_string(), |f| f.error))
                    };
                    if let Some(waiting) = self.pending.lock().unwrap_or_else(|p| p.into_inner()).remove(&id) {
                        let _ = waiting.try_send(result);
                    }
                }
                proto::EXITED => {
                    if let Ok(exit) = proto::parse::<Exit>(&payload)
                        && let Some(route) = self.routes.lock().unwrap_or_else(|p| p.into_inner()).get(&id)
                    {
                        *route.state.exit.lock().unwrap_or_else(|p| p.into_inner()) = Some(exit);
                        crate::wake::notify();
                    }
                }
                proto::FOREGROUND_IS => {
                    let pgid = proto::parse::<proto::Foreground>(&payload).map_or(-1, |f| f.pgid);
                    if let Some(route) = self.routes.lock().unwrap_or_else(|p| p.into_inner()).get(&id) {
                        route.state.foreground.store(pgid, Ordering::Relaxed);
                    }
                }
                proto::BYE => return Ok(true),
                _ => {}
            }
        }
        Ok(false)
    }
}

/// A session's handle on its held terminal.
pub struct Held {
    link: Arc<Link>,
    id: u32,
    pub pid: u32,
    pub tty: String,
    /// Windows: the name of the Job Object its programs run in.
    pub job: String,
    state: Arc<RouteState>,
    asked: std::cell::Cell<Instant>,
}

impl Held {
    /// Sends what the session queues as input, in order, until it drops the queue.
    pub fn forward_input(&self, queued: mpsc::Receiver<Vec<u8>>) {
        let (link, id) = (self.link.clone(), self.id);
        std::thread::spawn(move || {
            for bytes in queued {
                link.send(proto::frame(proto::INPUT, id, &bytes));
            }
        });
    }

    pub fn resize(&self, cols: u16, rows: u16, pixel_width: u16, pixel_height: u16) {
        let size = proto::Size { cols, rows, pixel_width, pixel_height };
        self.link.send(proto::json_frame(proto::RESIZE, self.id, &size));
    }

    /// Signals the program's group and the foreground group (the holder
    /// refuses once it reaped the program, so a reused pid is never hit).
    pub fn signal(&self, signal: i32) {
        self.link.send(proto::json_frame(proto::SIGNAL, self.id, &proto::Signal { signal }));
    }

    pub fn exit(&self) -> Option<Exit> {
        *self.state.exit.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// The foreground process group, as last reported. Asking is asynchronous;
    /// until the first answer the shell itself is in front.
    pub fn foreground(&self) -> Option<i32> {
        let pgid = self.state.foreground.load(Ordering::Relaxed);
        Some(if pgid > 0 { pgid } else { self.pid as i32 }).filter(|_| self.exit().is_none())
    }

    pub fn refresh_foreground(&self) {
        if self.asked.get().elapsed() >= FOREGROUND_EVERY && self.exit().is_none() {
            self.asked.set(Instant::now());
            self.link.send(proto::frame(proto::FOREGROUND, self.id, &[]));
        }
    }

    /// The holder forgets the terminal (hanging up leftovers that hold it).
    pub fn release(&self) {
        self.link.routes.lock().unwrap_or_else(|p| p.into_inner()).remove(&self.id);
        self.link.send(proto::frame(proto::RELEASE, self.id, &[]));
    }

    /// Resize down and back so a full-screen program repaints a screen that
    /// was rebuilt from its recent output.
    pub fn nudge(&self, cols: u16, rows: u16, pixel_width: u16, pixel_height: u16) {
        self.resize(cols, rows.saturating_sub(1).max(1), pixel_width, pixel_height);
        let (link, id) = (self.link.clone(), self.id);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            link.send(proto::json_frame(proto::RESIZE, id, &proto::Size { cols, rows, pixel_width, pixel_height }));
        });
    }
}

/// A terminal a holder was already running when we took it over.
pub struct Adopted {
    pub held: Held,
    pub output: mpsc::Receiver<Vec<u8>>,
    pub terminal: HeldTerminal,
    /// Output since the previous server saved its screens (handover), or the
    /// last ~1 MB (crash).
    pub tail: Vec<u8>,
    /// How the previous server left: "none", "handover" or "crash".
    pub previous: String,
}

/// The longest Unix socket path in bytes: `sun_path` less its terminator.
#[cfg(any(target_os = "macos", target_os = "ios"))]
const SOCKET_PATH_LIMIT: usize = 103;
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
const SOCKET_PATH_LIMIT: usize = 107;

pub struct Holders {
    /// Holder sockets are `<prefix><id>.sock`, beside the server descriptor,
    /// as in herdr-core.
    ///
    /// A Unix socket path is limited to `SOCKET_PATH_LIMIT` bytes. We keep the
    /// sockets here anyway: an installed state directory leaves about 40
    /// bytes to spare, one directory holds everything a server owns, and a
    /// temporary directory would only move the limit to another path the user
    /// controls. A state directory that is too deep is reported, not worked
    /// around; tests with deep folders run their server from a short one.
    prefix: String,
    restart: Vec<String>,
    links: Vec<Arc<Link>>,
}

impl Holders {
    /// `descriptor` names the server; `restart` is how a holder starts it again.
    pub fn new(descriptor: &Path, restart: Vec<String>) -> Self {
        let base = descriptor.with_extension("").display().to_string();
        Self { prefix: format!("{base}.holder."), restart, links: Vec::new() }
    }

    /// The command line a holder uses to start this server again.
    pub fn restart_command(&self) -> &[String] {
        &self.restart
    }

    /// At startup: take over every holder still running. Returns what they run.
    pub fn attach_all(&mut self) -> Vec<Adopted> {
        let prefix = PathBuf::from(&self.prefix);
        let (Some(dir), Some(stem)) = (prefix.parent(), prefix.file_name().map(|n| n.to_string_lossy().into_owned()))
        else {
            return Vec::new();
        };
        let mut sockets: Vec<PathBuf> = std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.file_name().is_some_and(|n| {
                let n = n.to_string_lossy();
                n.starts_with(&stem) && n.ends_with(".sock")
            }))
            .collect();
        sockets.sort();
        let mut adopted = Vec::new();
        for socket in sockets {
            match UnixStream::connect(&socket) {
                Ok(stream) => match self.take_over(stream, false) {
                    Ok(terminals) => adopted.extend(terminals),
                    Err(e) => eprintln!("[holder] cannot take over {}: {e}", socket.display()),
                },
                // Its holder is gone.
                Err(_) => drop(std::fs::remove_file(&socket)),
            }
        }
        adopted
    }

    /// The holder new terminals go to, started if there is none.
    fn current(&mut self) -> io::Result<Arc<Link>> {
        self.links.retain(|l| l.alive.load(Ordering::SeqCst));
        if let Some(link) = self.links.iter().find(|l| l.current) {
            return Ok(link.clone());
        }
        // 8 hex: unique enough among one server's holders, and short.
        let socket = format!("{}{}.sock", self.prefix, &uuid::Uuid::new_v4().simple().to_string()[..8]);
        if socket.len() > SOCKET_PATH_LIMIT {
            return Err(io::Error::other(format!(
                "the terminal holder's socket path is {} bytes and the system allows {SOCKET_PATH_LIMIT}; \
                 use a shorter state directory: {socket}",
                socket.len()
            )));
        }
        let log = Path::new(&socket).with_extension("log");
        let output = std::fs::OpenOptions::new().create(true).append(true).open(&log)?;
        let mut cmd = std::process::Command::new(std::env::current_exe()?);
        cmd.args(["internal", "holder", "--socket", &socket])
            .stdin(std::process::Stdio::null())
            .stdout(output.try_clone()?)
            .stderr(output);
        // The server gets its own session. Closing the terminal that started it must not end it.
        spawn_apart(&mut cmd)?;
        let stream = wait_for_socket(Path::new(&socket))?;
        let adopted = self.take_over(stream, true)?;
        // A brand-new holder runs nothing yet.
        debug_assert!(adopted.is_empty());
        self.links.iter().find(|l| l.current).cloned().ok_or_else(|| io::Error::other("holder is not current"))
    }

    /// Takes over one holder and adopts what it runs.
    fn take_over(&mut self, mut stream: UnixStream, require_current: bool) -> io::Result<Vec<Adopted>> {
        let hello = proto::Hello { version: proto::VERSION, restart: self.restart.clone() };
        stream.write_all(&proto::json_frame(proto::HELLO, 0, &hello))?;
        let welcome: proto::Welcome = match proto::read(&mut stream)? {
            Some((proto::WELCOME, _, payload)) => proto::parse(&payload)?,
            _ => return Err(io::Error::other("holder sent no welcome")),
        };
        if welcome.version != proto::VERSION {
            return Err(io::Error::other(format!(
                "holder protocol {} differs from server protocol {}",
                welcome.version,
                proto::VERSION
            )));
        }
        let mut tails = HashMap::new();
        for _ in &welcome.terminals {
            match proto::read(&mut stream)? {
                Some((proto::TAIL, id, bytes)) => tails.insert(id, bytes),
                _ => return Err(io::Error::other("holder sent no tail")),
            };
        }
        let current = welcome.build == build_id();
        if require_current && !current {
            stream.write_all(&proto::frame(proto::DRAIN, 0, &[]))?;
            return Err(io::Error::other(format!("holder build {} differs from server build {}", welcome.build, build_id())));
        }
        let (writer, frames) = mpsc::channel::<Vec<u8>>();
        let mut socket = stream.try_clone()?;
        std::thread::spawn(move || {
            for frame in frames {
                if socket.write_all(&frame).is_err() {
                    break;
                }
            }
        });
        let (bye_tx, bye_rx) = mpsc::channel();
        let link = Arc::new(Link {
            writer: Mutex::new(writer),
            instance: welcome.instance.clone(),
            pid: welcome.pid,
            current,
            routes: Default::default(),
            pending: Default::default(),
            bye: Mutex::new(Some(bye_rx)),
            alive: AtomicBool::new(true),
        });
        if !current {
            // Another build: it keeps what it runs, takes nothing new, exits when empty.
            link.send(proto::frame(proto::DRAIN, 0, &[]));
        }
        // Routes exist before the reader starts, so no output is dropped.
        let adopted: Vec<Adopted> = welcome
            .terminals
            .into_iter()
            .map(|terminal| {
                let (output, state) = link.route(terminal.id);
                if let Some(exit) = terminal.exit {
                    *state.exit.lock().unwrap_or_else(|p| p.into_inner()) = Some(exit);
                }
                Adopted {
                    held: Held {
                        link: link.clone(),
                        id: terminal.id,
                        pid: terminal.pid,
                        tty: terminal.tty.clone(),
                        job: terminal.job.clone(),
                        state,
                        asked: Instant::now().into(),
                    },
                    output,
                    tail: tails.remove(&terminal.id).unwrap_or_default(),
                    terminal,
                    previous: welcome.previous.clone(),
                }
            })
            .collect();
        let reader = link.clone();
        std::thread::spawn(move || {
            let mut stream = stream;
            let ended = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| reader.frames(&mut stream)));
            if !matches!(ended, Ok(Ok(true))) {
                // Never leave the link open with nobody reading: the holder would wait on us.
                let _ = stream.shutdown(std::net::Shutdown::Both);
                reader.lost();
            }
            drop(bye_tx);
        });
        self.links.push(link);
        Ok(adopted)
    }

    /// Starts `spec` in the current holder as terminal `id`.
    pub fn spawn(&mut self, id: u32, spec: &proto::Spawn) -> io::Result<(Held, mpsc::Receiver<Vec<u8>>)> {
        let link = self.current()?;
        let (output, state) = link.route(id);
        let (done, result) = mpsc::sync_channel(1);
        link.pending.lock().unwrap_or_else(|p| p.into_inner()).insert(id, done);
        link.send(proto::json_frame(proto::SPAWN, id, spec));
        let spawned = match result.recv_timeout(SPAWN_WAIT) {
            Ok(result) => result.map_err(io::Error::other),
            Err(_) => Err(io::Error::other("the terminal holder did not start the program in time")),
        };
        match spawned {
            Ok(spawned) => {
                Ok((
                    Held {
                        link,
                        id,
                        pid: spawned.pid,
                        tty: spawned.tty,
                        job: spawned.job,
                        state,
                        asked: Instant::now().into(),
                    },
                    output,
                ))
            }
            Err(error) => {
                link.pending.lock().unwrap_or_else(|p| p.into_inner()).remove(&id);
                link.routes.lock().unwrap_or_else(|p| p.into_inner()).remove(&id);
                // A late start must not leave a program nobody can address.
                link.send(proto::json_frame(proto::SIGNAL, id, &proto::Signal { signal: proto::KILL }));
                link.send(proto::frame(proto::RELEASE, id, &[]));
                Err(error)
            }
        }
    }

    /// A held terminal no saved session claims: nobody can address it, so it must not live.
    pub fn discard(adopted: Adopted) {
        adopted.held.signal(proto::KILL);
        adopted.held.release();
    }

    /// Ends every link on purpose and waits until each holder confirms.
    pub fn goodbye(&mut self, mode: Goodbye) {
        let byes: Vec<mpsc::Receiver<()>> = self
            .links
            .iter()
            .filter_map(|link| {
                link.send(proto::json_frame(proto::GOODBYE, 0, &mode));
                link.bye.lock().unwrap_or_else(|p| p.into_inner()).take()
            })
            .collect();
        for rx in byes {
            let _ = rx.recv_timeout(Duration::from_secs(6));
        }
        self.links.clear();
    }

    /// Holders of another build that still run terminals, and how many
    /// terminals they run. Each exits on its own once its last one ends.
    pub fn draining(&self) -> (usize, usize) {
        let mut holders = 0;
        let mut terminals = 0;
        for link in self.links.iter().filter(|l| !l.current && l.alive.load(Ordering::SeqCst)) {
            let routes = link.routes.lock().unwrap_or_else(|p| p.into_inner());
            let running = routes
                .values()
                .filter(|r| r.state.exit.lock().unwrap_or_else(|p| p.into_inner()).is_none())
                .count();
            if running > 0 {
                holders += 1;
                terminals += running;
            }
        }
        (holders, terminals)
    }

    /// Holders whose programs this server would lose by stopping.
    pub fn is_empty(&self) -> bool {
        self.links.is_empty()
    }
}
