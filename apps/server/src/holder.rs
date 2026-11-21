//! The holder: a small process that owns every PTY and is the parent of every
//! program in a terminal.
//!
//! - It spawns, resizes, signals and reaps programs, and always reads their
//!   output. It does no parsing and makes no decisions.
//! - It keeps the last ~1 MB of output per terminal, so a server that crashed
//!   can rebuild its screens.
//! - It restarts a crashed server itself.
//!
//! Adapted from herdr-core `crates/herdr-core/src/holder.rs`
//! (https://github.com/herdrdev/herdr-core, Apache-2.0; see
//! `licenses/herdr-core-Apache-2.0.txt`). Changed for Graffitty:
//!
//! - PTYs come from Graffitty's portable-pty fork (`pty` below), not herdr's
//!   platform layer.
//! - The server to restart is the command line it announced in `Hello`.
//! - No environment-token sweep. The server already ends a terminal's leftover
//!   jobs when it closes the pane (`session_jobs`).
//! - On Windows the server link is a Unix-domain socket, not a named pipe.

use crate::holder_proto::{self as proto, Exit, Goodbye, HeldTerminal};
use pty::{Process, Pty, Stream};
use std::collections::{HashMap, VecDeque};
use std::io::{self, Read, Write};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const TAIL_BYTES: usize = 1 << 20;
const EXIT_DRAIN: Duration = Duration::from_millis(200);
/// Output queued for a server that reads slowly before programs have to wait for it.
const BACKLOG_BYTES: usize = 8 << 20;

struct Term {
    pid: u32,
    pty: Arc<Pty>,
    /// Input goes through its own thread: a program that stops reading blocks only itself.
    input: std::sync::mpsc::Sender<Vec<u8>>,
    cols: u16,
    rows: u16,
    tail: VecDeque<u8>,
    exit: Option<Exit>,
    reader_done: bool,
    /// Since when its output could drain; None while its reader waits for a
    /// server that fell behind. An exit waits for its output from then on.
    drains_since: Option<Instant>,
}

/// The connected server. Frames go out through its own writer thread: a
/// server that stops reading must never block anyone holding the state lock.
struct Core {
    generation: u64,
    frames: std::sync::mpsc::Sender<Vec<u8>>,
    backlog: Arc<Backlog>,
    /// Shut down to free a writer stuck on a server that is gone.
    stream: Stream,
}

/// Bytes queued for one server; None once its writer stopped.
struct Backlog {
    bytes: Mutex<Option<usize>>,
    changed: Condvar,
}

impl Backlog {
    fn update(&self, f: impl FnOnce(&mut Option<usize>)) {
        f(&mut self.bytes.lock().unwrap_or_else(|p| p.into_inner()));
        self.changed.notify_all();
    }

    fn over(&self, limit: usize) -> bool {
        self.bytes.lock().unwrap_or_else(|p| p.into_inner()).is_some_and(|n| n > limit)
    }

    /// Waits (never under the state lock) until at most `limit` bytes are queued or the writer stopped.
    fn wait(&self, limit: usize, timeout: Duration) {
        let bytes = self.bytes.lock().unwrap_or_else(|p| p.into_inner());
        let _ = self.changed.wait_timeout_while(bytes, timeout, |b| b.is_some_and(|n| n > limit));
    }
}

struct State {
    terms: HashMap<u32, Term>,
    core: Option<Core>,
    generation: u64,
    previous: &'static str,
    core_left: Instant,
    restarts: Vec<Instant>,
    /// How the last server said to start it again (empty: never).
    restart: Vec<String>,
}

struct Holder {
    state: Mutex<State>,
    changed: Condvar,
    instance: String,
    grace: Duration,
    socket: std::path::PathBuf,
    /// Where a restarted server writes its output.
    log: std::path::PathBuf,
    /// A newer build took over: exit once the last terminal is gone.
    draining: std::sync::atomic::AtomicBool,
}

/// Runs a holder on `socket` (each holder has its own; the server picks the path).
pub fn run(socket: std::path::PathBuf) -> io::Result<()> {
    pty::raise_nofile_limit();
    pty::accept_interrupts();
    // A taken path means another holder lives there; a stale file is removed by the server.
    let listener = pty::listen(&socket)?;
    let log = socket.with_extension("server.log");
    let grace = std::env::var("GRAFFITTY_HOLDER_GRACE_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .map_or(Duration::from_secs(3), Duration::from_millis);
    let holder = Arc::new(Holder {
        state: Mutex::new(State {
            terms: HashMap::new(),
            core: None,
            generation: 0,
            previous: "none",
            core_left: Instant::now(),
            restarts: Vec::new(),
            restart: Vec::new(),
        }),
        changed: Condvar::new(),
        instance: uuid::Uuid::new_v4().simple().to_string(),
        grace,
        socket,
        log,
        draining: Default::default(),
    });
    let supervisor = holder.clone();
    std::thread::spawn(move || supervisor.supervise());
    for stream in listener.incoming() {
        let holder = holder.clone();
        let stream = stream?;
        std::thread::spawn(move || {
            if let Err(e) = holder.serve(stream) {
                eprintln!("holder: server connection: {e}");
            }
        });
    }
    Ok(())
}

impl Holder {
    fn exit(&self) -> ! {
        let _ = std::fs::remove_file(&self.socket);
        std::process::exit(0);
    }

    fn exit_if_drained(&self) {
        if self.draining.load(std::sync::atomic::Ordering::SeqCst) && self.lock().terms.is_empty() {
            self.exit();
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Queues a frame for the current server.
    fn to_core(&self, st: &mut State, frame: &[u8]) {
        if let Some(core) = &st.core {
            core.backlog.update(|b| *b = b.map(|n| n + frame.len()));
            let _ = core.frames.send(frame.to_vec());
        }
    }

    /// A handover lets the writer deliver what is queued (BYE last) but no longer
    /// holds programs back for it; any other end cuts it off.
    fn core_gone(&self, st: &mut State, how: &'static str) {
        if let Some(core) = st.core.take() {
            match how {
                "handover" => core.backlog.update(|b| *b = None),
                _ => drop(core.stream.shutdown(std::net::Shutdown::Both)),
            }
        }
        st.previous = how;
        st.core_left = Instant::now();
    }

    /// Writes one server's frames in order; a failed write means that server is gone.
    fn write_to_core(&self, generation: u64, mut stream: Stream, frames: Receiver<Vec<u8>>, backlog: Arc<Backlog>) {
        for frame in frames {
            if stream.write_all(&frame).is_err() {
                break;
            }
            backlog.update(|b| *b = b.map(|n| n.saturating_sub(frame.len())));
        }
        backlog.update(|b| *b = None);
        let mut st = self.lock();
        if st.core.as_ref().is_some_and(|c| c.generation == generation) {
            self.core_gone(&mut st, "crash");
        }
    }

    fn serve(self: &Arc<Self>, mut stream: Stream) -> io::Result<()> {
        let hello = match proto::read(&mut stream)? {
            Some((proto::HELLO, _, payload)) => proto::parse::<proto::Hello>(&payload)?,
            _ => return Ok(()),
        };
        let generation = {
            let mut st = self.lock();
            if st.core.is_some() {
                self.core_gone(&mut st, "crash");
            }
            st.restart = hello.restart;
            st.generation += 1;
            let mut ids: Vec<u32> = st.terms.keys().copied().collect();
            ids.sort();
            let welcome = proto::Welcome {
                version: proto::VERSION,
                instance: self.instance.clone(),
                pid: std::process::id(),
                build: crate::holder_link::build_id(),
                previous: st.previous.into(),
                terminals: ids
                    .iter()
                    .map(|id| {
                        let t = &st.terms[id];
                        HeldTerminal { id: *id, pid: t.pid, tty: t.pty.tty.clone(), job: t.pty.job.clone(), cols: t.cols, rows: t.rows, exit: t.exit }
                    })
                    .collect(),
            };
            let mut out = proto::json_frame(proto::WELCOME, 0, &welcome);
            for id in &ids {
                let (a, b) = st.terms[id].tail.as_slices();
                out.extend(proto::frame(proto::TAIL, *id, &[a, b].concat()));
            }
            let (frames, queued) = std::sync::mpsc::channel();
            let backlog = Arc::new(Backlog { bytes: Mutex::new(Some(0)), changed: Condvar::new() });
            let (writer, kept) = (stream.try_clone()?, stream.try_clone()?);
            let (holder, written, generation) = (self.clone(), backlog.clone(), st.generation);
            std::thread::spawn(move || holder.write_to_core(generation, writer, queued, written));
            st.core = Some(Core { generation, frames, backlog, stream: kept });
            self.to_core(&mut st, &out);
            generation
        };

        let result = self.commands(&mut stream, generation);
        let mut st = self.lock();
        if st.core.as_ref().is_some_and(|c| c.generation == generation) {
            self.core_gone(&mut st, "crash");
        }
        result
    }

    fn commands(self: &Arc<Self>, stream: &mut Stream, generation: u64) -> io::Result<()> {
        while let Some((kind, id, payload)) = proto::read(stream)? {
            match kind {
                proto::SPAWN => self.spawn(id, proto::parse(&payload)?),
                proto::INPUT => {
                    if let Some(t) = self.lock().terms.get(&id) {
                        let _ = t.input.send(payload);
                    }
                }
                proto::RESIZE => {
                    let size: proto::Size = proto::parse(&payload)?;
                    let mut st = self.lock();
                    if let Some(t) = st.terms.get_mut(&id) {
                        t.cols = size.cols;
                        t.rows = size.rows;
                        t.pty.resize(size.cols, size.rows, size.pixel_width, size.pixel_height);
                    }
                }
                proto::SIGNAL => {
                    let sig: proto::Signal = proto::parse(&payload)?;
                    let st = self.lock();
                    // Never signal after reaping: the pid may belong to someone else now.
                    if let Some(t) = st.terms.get(&id).filter(|t| t.exit.is_none()) {
                        t.pty.signal(t.pid, sig.signal);
                    }
                }
                proto::FOREGROUND => {
                    let mut st = self.lock();
                    let pgid = st.terms.get(&id).filter(|t| t.exit.is_none()).map_or(-1, |t| t.pty.foreground());
                    self.to_core(&mut st, &proto::json_frame(proto::FOREGROUND_IS, id, &proto::Foreground { pgid }));
                }
                proto::RELEASE => {
                    if let Some(t) = self.lock().terms.remove(&id)
                        && !t.reader_done
                    {
                        // Leftover background jobs still hold the PTY: hang them up.
                        t.pty.hang_up(t.pid);
                    }
                    self.exit_if_drained();
                }
                proto::DRAIN => {
                    self.draining.store(true, std::sync::atomic::Ordering::SeqCst);
                    self.exit_if_drained();
                }
                proto::GOODBYE => {
                    let mode: Goodbye = proto::parse(&payload)?;
                    let mut st = self.lock();
                    // Read late, after a newer core said hello: that one stays.
                    if st.core.as_ref().is_none_or(|c| c.generation != generation) {
                        return Ok(());
                    }
                    if mode != Goodbye::Shutdown {
                        // The server saved screens up to here; the next one replays only what follows.
                        st.terms.values_mut().for_each(|t| t.tail.clear());
                    }
                    if mode == Goodbye::Park {
                        // An installer is replacing the server and will start the new one. Do not restart it here.
                        st.restart.clear();
                    }
                    if mode == Goodbye::Shutdown {
                        // Whatever the server's stop missed (started since, or hiding)
                        // is hung up here, before the goodbye.
                        for t in st.terms.values().filter(|t| t.exit.is_none()) {
                            t.pty.hang_up(t.pid);
                        }
                        self.to_core(&mut st, &proto::frame(proto::BYE, 0, &[]));
                        let backlog = st.core.as_ref().map(|c| c.backlog.clone());
                        drop(st);
                        if let Some(backlog) = backlog {
                            backlog.wait(0, Duration::from_secs(5));
                        }
                        self.exit();
                    }
                    self.to_core(&mut st, &proto::frame(proto::BYE, 0, &[]));
                    self.core_gone(&mut st, "handover");
                    return Ok(());
                }
                _ => {}
            }
        }
        Ok(())
    }

    fn spawn(self: &Arc<Self>, id: u32, spec: proto::Spawn) {
        let mut st = self.lock();
        if let Some(t) = st.terms.get(&id) {
            let frame = proto::json_frame(proto::SPAWNED, id, &proto::Spawned { pid: t.pid, tty: t.pty.tty.clone(), job: t.pty.job.clone() });
            return self.to_core(&mut st, &frame);
        }
        let name = format!("graffitty-terminal-{}-{id}", self.instance);
        let started = pty::spawn(&name, &spec).and_then(|(pty, child)| Ok((pty.reader()?, pty.writer()?, pty, child)));
        let frame = match started {
            Err(e) => {
                let error = format!("cannot start {:?}: {e}", spec.argv.first().map_or("", |s| s.as_str()));
                eprintln!("holder: %{id}: {error}");
                proto::json_frame(proto::SPAWN_FAILED, id, &proto::SpawnFailed { error })
            }
            Ok((reader, mut writer, pty, child)) => {
                let pid = child.process_id().unwrap_or_default();
                let (tty, job) = (pty.tty.clone(), pty.job.clone());
                let (input, queued) = std::sync::mpsc::channel::<Vec<u8>>();
                std::thread::spawn(move || {
                    for bytes in queued {
                        if writer.write_all(&bytes).is_err() {
                            break;
                        }
                    }
                });
                st.terms.insert(
                    id,
                    Term {
                        pid,
                        input,
                        pty: Arc::new(pty),
                        cols: spec.cols,
                        rows: spec.rows,
                        tail: VecDeque::new(),
                        exit: None,
                        reader_done: false,
                        drains_since: Some(Instant::now()),
                    },
                );
                let (holder, waiter) = (self.clone(), self.clone());
                std::thread::spawn(move || holder.pump(id, reader));
                std::thread::spawn(move || waiter.reap(id, child));
                proto::json_frame(proto::SPAWNED, id, &proto::Spawned { pid, tty, job })
            }
        };
        self.to_core(&mut st, &frame);
    }

    /// Always reads, server or not, so programs never stall on a full PTY.
    fn pump(&self, id: u32, mut reader: impl Read) {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break, // EIO: every slave side closed
            };
            let mut st = self.lock();
            let Some(t) = st.terms.get_mut(&id) else { break };
            t.tail.extend(&buf[..n]);
            let excess = t.tail.len().saturating_sub(TAIL_BYTES);
            t.tail.drain(..excess);
            self.to_core(&mut st, &proto::frame(proto::OUTPUT, id, &buf[..n]));
            // A server that falls behind slows its programs, as a PTY nobody reads would.
            let Some(backlog) = st.core.as_ref().map(|c| c.backlog.clone()).filter(|b| b.over(BACKLOG_BYTES)) else {
                continue;
            };
            st.terms.get_mut(&id).expect("just found").drains_since = None;
            drop(st);
            backlog.wait(BACKLOG_BYTES, Duration::MAX);
            if let Some(t) = self.lock().terms.get_mut(&id) {
                t.drains_since = Some(Instant::now());
            }
            self.changed.notify_all();
        }
        if let Some(t) = self.lock().terms.get_mut(&id) {
            t.reader_done = true;
        }
        self.changed.notify_all();
    }

    /// The exit code comes from here, after the last output has been forwarded.
    fn reap(self: &Arc<Self>, id: u32, mut child: Process) {
        let (code, signal) = match pty::wait(&mut child) {
            Ok(ended) => ended,
            Err(e) => {
                eprintln!("holder: wait %{id}: {e}");
                return;
            }
        };
        let exit = Exit { code, signal };
        let exited = Instant::now();
        let mut st = self.lock();
        while let Some(t) = st.terms.get(&id).filter(|t| !t.reader_done) {
            // Its output goes first: time a slow server holds the reader back doesn't count.
            let Some(since) = t.drains_since else {
                st = self.changed.wait(st).unwrap_or_else(|p| p.into_inner());
                continue;
            };
            let deadline = since.max(exited) + EXIT_DRAIN;
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            st = self.changed.wait_timeout(st, left).unwrap_or_else(|p| p.into_inner()).0;
        }
        if let Some(t) = st.terms.get_mut(&id) {
            t.exit = Some(exit);
            self.to_core(&mut st, &proto::json_frame(proto::EXITED, id, &exit));
        }
    }

    /// Starts a server when the last one crashed and none came back in time.
    fn supervise(&self) {
        loop {
            std::thread::sleep(self.grace.min(Duration::from_millis(100)));
            let mut st = self.lock();
            if st.core.is_some() || st.core_left.elapsed() < self.grace {
                continue;
            }
            if st.terms.is_empty() {
                self.exit();
            }
            let now = Instant::now();
            st.restarts.retain(|t| now.duration_since(*t) < Duration::from_secs(300));
            let backoff = self.grace * 2u32.pow(st.restarts.len().min(6) as u32);
            if st.restarts.last().is_some_and(|t| now.duration_since(*t) < backoff.min(Duration::from_secs(60))) {
                continue;
            }
            if st.restart.is_empty() {
                continue;
            }
            st.restarts.push(now);
            st.core_left = now;
            let restart = st.restart.clone();
            drop(st);
            if let Err(e) = pty::spawn_detached(&restart, &self.log) {
                eprintln!("holder: cannot start server: {e}");
            }
        }
    }
}

/// herdr's platform PTY calls, served by Graffitty's portable-pty fork so held
/// programs start exactly like in-process ones (signal dispositions reset,
/// inherited descriptors closed, controlling terminal set).
#[cfg(unix)]
mod pty {
    use crate::holder_proto as proto;
    use portable_pty::{CommandBuilder, MasterPty, PtySize};
    use std::io::{self, Read, Write};
    use std::sync::Mutex;

    pub type Stream = std::os::unix::net::UnixStream;
    pub type Process = Box<dyn portable_pty::Child + Send + Sync>;

    pub struct Pty {
        master: Mutex<Box<dyn MasterPty + Send>>,
        fd: i32,
        pub tty: String,
        /// Windows only: the Job Object its programs run in.
        pub job: String,
    }

    pub fn listen(path: &std::path::Path) -> io::Result<std::os::unix::net::UnixListener> {
        use std::os::unix::fs::PermissionsExt;
        let listener = std::os::unix::net::UnixListener::bind(path)?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        Ok(listener)
    }

    /// Only Windows turns interrupts off for a process started apart.
    pub fn accept_interrupts() {}

    pub fn raise_nofile_limit() {
        let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
            return;
        }
        // Below Darwin's OPEN_MAX; requesting an unlimited soft limit fails there.
        let target = limit.rlim_cur.max(limit.rlim_max.min(8192));
        if target != limit.rlim_cur {
            limit.rlim_cur = target;
            if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &limit) } != 0 {
                eprintln!("cannot raise open file limit; using inherited limit: {}", io::Error::last_os_error());
            }
        }
    }

    pub fn spawn(_name: &str, spec: &proto::Spawn) -> io::Result<(Pty, Process)> {
        if spec.argv.is_empty() {
            return Err(io::Error::other("empty argv"));
        }
        let pair = portable_pty::native_pty_system()
            .openpty(PtySize {
                rows: spec.rows,
                cols: spec.cols,
                pixel_width: spec.pixel_width,
                pixel_height: spec.pixel_height,
            })
            .map_err(io::Error::other)?;
        let mut cmd = CommandBuilder::from_argv(spec.argv.iter().map(Into::into).collect());
        cmd.env_clear();
        for (key, value) in &spec.env {
            cmd.env(key, value);
        }
        if !spec.cwd.is_empty() {
            cmd.cwd(&spec.cwd);
        }
        let child = pair.slave.spawn_command(cmd).map_err(io::Error::other)?;
        drop(pair.slave);
        let fd = pair.master.as_raw_fd().ok_or_else(|| io::Error::other("pty has no descriptor"))?;
        let tty = pair.master.tty_name().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        Ok((Pty { master: Mutex::new(pair.master), fd, tty, job: String::new() }, child))
    }

    impl Pty {
        fn master(&self) -> std::sync::MutexGuard<'_, Box<dyn MasterPty + Send>> {
            self.master.lock().unwrap_or_else(|p| p.into_inner())
        }

        /// Its output, read until every program on it has gone.
        pub fn reader(&self) -> io::Result<Box<dyn Read + Send>> {
            self.master().try_clone_reader().map_err(io::Error::other)
        }

        pub fn writer(&self) -> io::Result<Box<dyn Write + Send>> {
            self.master().take_writer().map_err(io::Error::other)
        }

        pub fn resize(&self, cols: u16, rows: u16, pixel_width: u16, pixel_height: u16) {
            let _ = self.master().resize(PtySize { rows, cols, pixel_width, pixel_height });
        }

        /// The process group in the foreground (a shell's job), or -1.
        pub fn foreground(&self) -> i32 {
            unsafe { libc::tcgetpgrp(self.fd) }
        }

        /// The program's group, plus whatever group is in the foreground.
        pub fn signal(&self, pid: u32, signal: i32) {
            unsafe {
                libc::killpg(pid as i32, signal);
                let fg = libc::tcgetpgrp(self.fd);
                if fg > 0 && fg != pid as i32 {
                    libc::killpg(fg, signal);
                }
            }
        }

        /// Its program is gone: hang up what still holds the terminal.
        pub fn hang_up(&self, pid: u32) {
            unsafe { libc::killpg(pid as i32, libc::SIGHUP) };
        }
    }

    /// Waits for it to end: (exit code, signal). portable-pty reports signals by
    /// name only, so the holder reaps the pid itself.
    pub fn wait(child: &mut Process) -> io::Result<(Option<i32>, Option<i32>)> {
        let pid = child.process_id().ok_or_else(|| io::Error::other("child has no pid"))? as libc::pid_t;
        loop {
            let mut status = 0;
            if unsafe { libc::waitpid(pid, &mut status, 0) } < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if libc::WIFEXITED(status) {
                return Ok((Some(libc::WEXITSTATUS(status)), None));
            }
            if libc::WIFSIGNALED(status) {
                return Ok((None, Some(libc::WTERMSIG(status))));
            }
        }
    }

    /// Starts the server again on its own, logging to `log`.
    pub fn spawn_detached(argv: &[String], log: &std::path::Path) -> io::Result<()> {
        let (program, args) = argv.split_first().ok_or_else(|| io::Error::other("empty restart command"))?;
        let output = std::fs::OpenOptions::new().create(true).append(true).open(log)?;
        let mut cmd = std::process::Command::new(program);
        cmd.args(args).stdin(std::process::Stdio::null()).stdout(output.try_clone()?).stderr(output);
        crate::holder_link::spawn_apart(&mut cmd).map(drop)
    }
}

/// The same calls on Windows:
///
/// - Terminals are ConPTY, through the portable-pty fork.
/// - The server link is a Unix-domain socket (Windows 10 1803 and later).
/// - Each terminal has a named Job Object. The server uses it to track the
///   terminal's programs, also after a restart.
#[cfg(windows)]
mod pty {
    use crate::holder_proto as proto;
    use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize};
    use std::io::{self, Read, Write};
    use std::sync::Mutex;
    use terminal_resource_monitor::windows::Boundary;

    pub type Stream = uds_windows::UnixStream;
    pub type Process = Box<dyn portable_pty::Child + Send + Sync>;

    pub struct Pty {
        master: Mutex<Box<dyn MasterPty + Send>>,
        killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
        /// Windows has no terminal device path.
        pub tty: String,
        pub job: String,
        /// Keeps the job open. Its name stops working when the last handle closes,
        /// and the next server finds the job by name.
        _boundary: Boundary,
    }

    pub fn listen(path: &std::path::Path) -> io::Result<uds_windows::UnixListener> {
        uds_windows::UnixListener::bind(path)
    }

    pub fn raise_nofile_limit() {}

    /// The server starts a holder in its own process group, where Windows
    /// turns Ctrl+C off, and every program in a terminal would inherit that:
    /// Ctrl+C could not interrupt `Start-Sleep` or `ping`. Turn it back on.
    pub fn accept_interrupts() {
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn SetConsoleCtrlHandler(handler: *const core::ffi::c_void, add: i32) -> i32;
        }
        // SAFETY: a null handler with FALSE only clears this process's ignore flag.
        unsafe { SetConsoleCtrlHandler(std::ptr::null(), 0) };
    }

    pub fn spawn(name: &str, spec: &proto::Spawn) -> io::Result<(Pty, Process)> {
        if spec.argv.is_empty() {
            return Err(io::Error::other("empty argv"));
        }
        let pair = portable_pty::native_pty_system()
            .openpty(PtySize {
                rows: spec.rows,
                cols: spec.cols,
                pixel_width: spec.pixel_width,
                pixel_height: spec.pixel_height,
            })
            .map_err(io::Error::other)?;
        let mut cmd = CommandBuilder::from_argv(spec.argv.iter().map(Into::into).collect());
        cmd.env_clear();
        for (key, value) in &spec.env {
            cmd.env(key, value);
        }
        if !spec.cwd.is_empty() {
            cmd.cwd(&spec.cwd);
        }
        if !spec.title.is_empty() {
            cmd.set_initial_title(&spec.title);
        }
        let boundary = Boundary::named(name).map_err(io::Error::other)?;
        cmd.set_job(boundary.handle());
        let child = pair.slave.spawn_command(cmd).map_err(io::Error::other)?;
        drop(pair.slave);
        let killer = child.clone_killer();
        Ok((
            Pty {
                master: Mutex::new(pair.master),
                killer: Mutex::new(killer),
                tty: String::new(),
                job: name.into(),
                _boundary: boundary,
            },
            child,
        ))
    }

    impl Pty {
        fn master(&self) -> std::sync::MutexGuard<'_, Box<dyn MasterPty + Send>> {
            self.master.lock().unwrap_or_else(|p| p.into_inner())
        }

        pub fn reader(&self) -> io::Result<Box<dyn Read + Send>> {
            self.master().try_clone_reader().map_err(io::Error::other)
        }

        pub fn writer(&self) -> io::Result<Box<dyn Write + Send>> {
            self.master().take_writer().map_err(io::Error::other)
        }

        pub fn resize(&self, cols: u16, rows: u16, pixel_width: u16, pixel_height: u16) {
            let _ = self.master().resize(PtySize { rows, cols, pixel_width, pixel_height });
        }

        /// Windows consoles have no foreground process group.
        pub fn foreground(&self) -> i32 {
            -1
        }

        /// Every signal ends the program. Ctrl+C is sent as input, not as a signal.
        pub fn signal(&self, _pid: u32, _signal: i32) {
            let _ = self.killer.lock().unwrap_or_else(|p| p.into_inner()).kill();
        }

        /// Nothing to do: releasing the terminal drops the pseudoconsole, and that
        /// ends every attached program.
        pub fn hang_up(&self, _pid: u32) {}
    }

    pub fn wait(child: &mut Process) -> io::Result<(Option<i32>, Option<i32>)> {
        child.wait().map(|status| (Some(status.exit_code() as i32), None))
    }

    /// Starts the server again as an independent process. Its output goes to `log`.
    pub fn spawn_detached(argv: &[String], log: &std::path::Path) -> io::Result<()> {
        let (program, args) = argv.split_first().ok_or_else(|| io::Error::other("empty restart command"))?;
        let output = std::fs::OpenOptions::new().create(true).append(true).open(log)?;
        let mut cmd = std::process::Command::new(program);
        cmd.args(args).stdin(std::process::Stdio::null()).stdout(output.try_clone()?).stderr(output);
        crate::holder_link::spawn_apart(&mut cmd).map(drop)
    }
}
