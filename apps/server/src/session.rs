#[cfg(test)]
use crate::spawn::Prepare as _;
use graffitty_terminal_core::vt::{Terminal, terminal::SizeReportSize};
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize};
use std::{
    cell::Cell,
    collections::VecDeque,
    io::{Read, Write},
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{self, Receiver, SyncSender},
    },
    thread,
};

pub type Error = Box<dyn std::error::Error>;
/// The narrowest grid that still holds one wide (CJK or emoji) character.
pub const MIN_COLUMNS: u16 = 2;
pub struct Session {
    pub id: u64,
    pub tab: u64,
    pub workspace: String,
    /// Server-side startup directory, inherited by descendants even after cd.
    pub initial_directory: Option<std::path::PathBuf>,
    /// Effective child environment, used only to format local directory titles.
    home_directory: Option<std::path::PathBuf>,
    pub shell: String,
    pub token: String,
    /// Presentation pin; OSC title continues to update underneath.
    pub pinned_title: String,
    /// Application-provided source message; translated by each client.
    pub builtin_title: String,
    pub font_size: u16,
    pub cell: (u32, u32),
    pub logical_extent: (f64, f64),
    pub layout_extent: Option<(f64, f64)>,
    cell_geometry: Rc<Cell<(u32, u32)>>,
    pub columns: u16,
    pub rows: u16,
    pub revision: u64,
    pub exited: bool,
    pub rect: [f64; 4],
    pub presentation_chunks: VecDeque<(u64, Vec<u8>)>,
    presentation_bytes: usize,
    pub scene_generation: u64,
    projection: graffitty_terminal_core::presentation_stream::Filter,
    image_cursor: Option<(u16, u16, usize, bool)>,
    pub scene_assets: graffitty_terminal_core::scene::Publisher,
    #[cfg(target_os = "macos")]
    local_surfaces: std::collections::BTreeMap<graffitty_protocol::terminal_scene::AssetKey, graffitty_chromium_video::surface::Surface>,
    scene_graphics: Option<graffitty_protocol::terminal_scene::Graphics>,
    scene_checkpoint: Option<Arc<Vec<u8>>>,
    observer: crate::terminal_protocol::Observer,
    pub notifications: VecDeque<(u64, serde_json::Value)>,
    pub notification_sequence: u64,
    pub(crate) clipboard: crate::clipboard::Broker,
    checkpoint: Option<Arc<Vec<u8>>>,
    pub limits: crate::spawn::TerminalLimits,
    /// Set once at creation by `gft pane run` / `graph spawn`: the terminal that
    /// started this one. Children close with their parent unless they
    /// asked to outlive it.
    pub spawned_by: Option<u64>,
    pub dies_with_parent: bool,
    _shell_hooks: Option<crate::shell_hooks::Hooks>,
    #[cfg(windows)]
    initial_console_title: String,
    images: crate::images::State,
    vt: Terminal<'static, 'static>,
    query_theme: graffitty_terminal_core::theme::Queries,
    pty: Pty,
    /// Left running on drop: a planned restart hands the program to the next server.
    pub detached: bool,
    #[cfg(windows)]
    _resource_boundary: terminal_resource_monitor::windows::Boundary,
    #[cfg(target_os = "linux")]
    _resource_boundary: Option<terminal_resource_monitor::linux::Boundary>,
    input: SyncSender<Vec<u8>>,
    pub command_input: Option<crate::terminal_input::Input>,
    pub typing_guard: crate::typing_guard::Gate,
    pub input_sequence: u64,
    pub input_events: VecDeque<(u64, serde_json::Value)>,
    output: Receiver<Vec<u8>>,
    stop: Arc<AtomicBool>,
    discard: Arc<AtomicBool>,
    geometry: Rc<Cell<(u16, u16)>>,
    bell: Rc<Cell<bool>>,
    /// OSC 7501 facts, as the program reported them.
    pub program_status: graffitty_terminal_core::program_status::ProgramStatus,
    /// Set when the root record changed; the owner applies it to the graph.
    pub program_status_changed: bool,
    program_reports: Rc<std::cell::RefCell<Vec<graffitty_terminal_core::program_status::StatusReport>>>,
    /// OSC 4723 claim nonces this terminal printed; the owner matches them.
    pub claim_nonces: Rc<std::cell::RefCell<Vec<String>>>,
    /// OSC 4723 effect holds the pane's programs asked for; see `docs/developers/automation-and-extensions/effect-holds.md`.
    pub effect_holds: graffitty_terminal_core::effect_holds::EffectHolds,
    effect_messages: Rc<std::cell::RefCell<Vec<graffitty_protocol::osc::Effects>>>,
    /// Drop VT replies while replaying output a previous server already answered.
    muted: Rc<Cell<bool>>,
}

/// Where the session's PTY lives: in this process, or in the terminal holder
/// that keeps programs running across server restarts.
enum Pty {
    Local { master: Box<dyn MasterPty + Send>, child: Box<dyn Child + Send + Sync> },
    Held(crate::holder_link::Held),
}

/// The holders this server spawns terminals in.
pub type Holders = crate::holder_link::Holders;

/// Opens the Job Object that a holder started the terminal's programs in.
#[cfg(windows)]
fn held_boundary(held: &crate::holder_link::Held) -> Result<terminal_resource_monitor::windows::Boundary, Error> {
    let mut boundary = terminal_resource_monitor::windows::Boundary::named(&held.job)
        .map_err(std::io::Error::other)?;
    boundary.register(held.pid);
    Ok(boundary)
}

/// The VT and the callbacks every session installs, for new and adopted terminals.
struct Terminal_ {
    vt: Terminal<'static, 'static>,
    query_theme: graffitty_terminal_core::theme::Queries,
    geometry: Rc<Cell<(u16, u16)>>,
    cell_geometry: Rc<Cell<(u32, u32)>>,
    bell: Rc<Cell<bool>>,
    program_reports: Rc<std::cell::RefCell<Vec<graffitty_terminal_core::program_status::StatusReport>>>,
    claim_nonces: Rc<std::cell::RefCell<Vec<String>>>,
    effect_messages: Rc<std::cell::RefCell<Vec<graffitty_protocol::osc::Effects>>>,
    muted: Rc<Cell<bool>>,
}

/// What a new or adopted session is made of, before its VT exists.
struct Parts {
    id: u64,
    tab: u64,
    workspace: String,
    initial_directory: Option<std::path::PathBuf>,
    shell: String,
    token: String,
    home_directory: Option<std::path::PathBuf>,
    font_size: u16,
    cell: (u32, u32),
    columns: u16,
    rows: u16,
    rect: [f64; 4],
    limits: crate::spawn::TerminalLimits,
    shell_hooks: Option<crate::shell_hooks::Hooks>,
    #[cfg(windows)]
    initial_console_title: String,
    #[cfg(windows)]
    resource_boundary: terminal_resource_monitor::windows::Boundary,
    #[cfg(target_os = "linux")]
    resource_boundary: Option<terminal_resource_monitor::linux::Boundary>,
    pty: Pty,
    input: SyncSender<Vec<u8>>,
    output: Receiver<Vec<u8>>,
    stop: Arc<AtomicBool>,
    discard: Arc<AtomicBool>,
}

impl Session {
    pub fn cwd_report(&self) -> String { self.pwd_report().into() }
    pub fn home_directory(&self) -> Option<&std::path::Path> { self.home_directory.as_deref() }
    /// libghostty keeps OSC 2/7 payloads as bytes; non-UTF-8 reports read as unset.
    fn pwd_report(&self) -> &str { self.vt.pwd().ok().and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("") }
    /// Prefer the live shell directory (or OSC 7), startup directory, then home.
    pub fn cwd(&self) -> Option<std::path::PathBuf> {
        let reported = Some(self.pwd_report())
            .and_then(crate::filetree::directory_from_report)
            .filter(|path| path.is_dir());
        // PowerShell's provider location does not update the process's native
        // current directory. Its validated OSC 7 report is the live location.
        #[cfg(windows)]
        if reported.is_some() {
            return reported;
        }
        if let Some(path) = self
            .pid()
            .and_then(crate::process_cwd::for_pid)
            .filter(|path| path.is_dir())
        {
            // The process directory is resolved. A report naming the same directory
            // keeps the shell's symlinked path, such as /var instead of /private/var.
            if let Some(logical) = reported
                .as_ref()
                .filter(|logical| logical.canonicalize().ok() == path.canonicalize().ok())
            {
                return Some(logical.clone());
            }
            return Some(path);
        }
        reported.or_else(|| {
            self.initial_directory.clone().filter(|path| path.is_dir())
        }).or_else(|| {
            std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))
                .map(std::path::PathBuf::from)
                .filter(|path| path.is_absolute() && path.is_dir())
        })
    }

    pub fn new(
        id: u64,
        tab: u64,
        workspace: &str,
        shell: &str,
        endpoint: &str,
        token: &str,
        cli: &str,
        cwd: Option<&std::path::Path>,
        options: Option<&crate::spawn::Prepared>,
    ) -> Result<Self, Error> {
        Self::new_with_font(id, tab, workspace, shell, endpoint, token, cli, cwd, options, None, &[], None)
    }
    pub fn new_with_font(
        id: u64,
        tab: u64,
        workspace: &str,
        shell: &str,
        endpoint: &str,
        token: &str,
        cli: &str,
        cwd: Option<&std::path::Path>,
        options: Option<&crate::spawn::Prepared>,
        font: Option<(u16, crate::fonts::Metrics, [f64; 4])>,
        managed_environment: &[(&str, String)],
        holders: Option<&mut Holders>,
    ) -> Result<Self, Error> {
        let (font_size, cell) = font.map(|(size, m, _)| (size, (m.width, m.height))).unwrap_or((18, crate::images::CELL));
        let insets = font.map(|(_, _, insets)| insets).unwrap_or([4., 34., 4., 4.]);
        let columns = (960 / cell.0).clamp(u32::from(MIN_COLUMNS), 500) as u16;
        let rows = (552 / cell.1).clamp(5, 300) as u16;
        let limits = options.map(|v| v.limits).unwrap_or_default();
        limits.validate().map_err(std::io::Error::other)?;
        let shell_hooks = options
            .filter(|v| v.shell_integration)
            .map(|_| crate::shell_hooks::Hooks::prepare())
            .transpose()?;
        let mut cmd = CommandBuilder::new(
            options
                .map(|v| v.shell.as_os_str())
                .unwrap_or_else(|| shell.as_ref()),
        );
        let initial_directory = options.and_then(|v| v.cwd.as_deref()).or(cwd)
            .map(std::path::Path::to_owned).or_else(|| std::env::current_dir().ok());
        // Match the startup title exactly. Elevated ConPTY adds a localized
        // Administrator prefix even when the startup title is empty.
        // Treat that decorated startup value as our own.
        #[cfg(windows)]
        let initial_console_title = format!("graffitty-startup-{}", uuid::Uuid::new_v4());
        #[cfg(windows)]
        cmd.set_initial_title(&initial_console_title);
        if let Some(cwd) = initial_directory.as_deref() {
            cmd.cwd(cwd);
        }
        if options.map(|v| v.login).unwrap_or(cfg!(unix)) {
            cmd.arg("-l");
        }
        if let Some(options) = options { cmd.args(&options.args); }
        cmd.env("TERM", "xterm-ghostty");
        cmd.env("COLORTERM", "truecolor");
        // The owner's launcher may disable color for its captured build logs.
        // A new interactive PTY has its own color policy; explicit terminal
        // environment overrides below can still opt out with NO_COLOR.
        cmd.env_remove("NO_COLOR");
        #[cfg(target_os = "linux")]
        for (key, value) in
            graffitty_platform::process_env::shell_loader_values(|key| std::env::var_os(key))
        {
            cmd.env(key, value);
        }
        // This PTY is outside any tmux client that launched the server.
        cmd.env_remove("TMUX");
        cmd.env_remove("TMUX_PANE");
        if let Some(options) = options {
            for (key, value) in &options.env {
                cmd.env(key, value);
            }
        }
        // A planted server must not inherit a local GUI's capability/socket.
        for name in std::env::vars_os().map(|(name, _)| name).chain(
            options
                .into_iter()
                .flat_map(|v| v.env.keys().map(std::ffi::OsString::from)),
        ) {
            let key = name.to_string_lossy();
            // Existing process configuration (for example CODEX_HOME) remains
            // inherited. Only capability/session identities are scrubbed;
            // explicit overrides already reject every reserved CODEX_* key.
            if key.starts_with("GRAFFITTY_")
                || key == "GODOT_AGENT_SOCKET"
                || key == "CODEX_THREAD_ID"
                || key == "CODEX_SESSION_ID"
            {
                cmd.env_remove(&name);
            }
        }
        cmd.env_remove("CODEX_THREAD_ID");
        cmd.env_remove("CODEX_SESSION_ID");
        cmd.env("GRAFFITTY_SOCKET", endpoint);
        cmd.env("GRAFFITTY_TOKEN", token);
        cmd.env("GRAFFITTY_TAB_ID", id.to_string());
        cmd.env("GRAFFITTY_SURFACE_ID", format!("%{id}"));
        cmd.env("GRAFFITTY_PANE", format!("%{id}"));
        cmd.env("GRAFFITTY_BIN", cli);
        for (key, value) in managed_environment { cmd.env(key, value); }
        cmd.env("TERM_PROGRAM", "graffitty");
        cmd.env("TERM_PROGRAM_VERSION", env!("GRAFFITTY_VERSION"));
        if let (Some(hooks), Some(options)) = (&shell_hooks, options) {
            hooks.configure(&mut cmd, &options.shell.to_string_lossy(), &options.env);
        }
        crate::terminfo::configure(&mut cmd)?;
        // A holder puts the program in its own job. That job is opened below.
        #[cfg(windows)]
        let mut resource_boundary = if holders.is_some() {
            None
        } else {
            let boundary = terminal_resource_monitor::windows::Boundary::prepare()
                .map_err(std::io::Error::other)?;
            cmd.set_job(boundary.handle());
            Some(boundary)
        };
        // Linux accounting needs the shell in its own cgroup before user code
        // runs. Without a delegated parent the terminal still starts; its
        // monitor reports unavailable.
        #[cfg(target_os = "linux")]
        let resource_boundary = match terminal_resource_monitor::linux::Boundary::prepare() {
            Ok(boundary) => {
                let original = cmd.get_argv().clone();
                // The bootstrap shell joins before exec of the user shell.
                // Positional arguments prevent path/command injection; no PGID changes.
                let argv = cmd.get_argv_mut();
                argv.clear();
                argv.extend([
                    "/bin/sh".into(),
                    "-c".into(),
                    "if ! printf '%s' \"$$\" > \"$1/cgroup.procs\"; then printf '%s\\n' 'Resource monitor: cgroup assignment failed' >&2; fi; shift; exec \"$@\"".into(),
                    "terminal-resource-bootstrap".into(),
                    boundary.path().as_os_str().to_owned(),
                ]);
                argv.extend(original);
                Some(boundary)
            }
            Err(error) => {
                eprintln!("Terminal {id} resource monitoring unavailable: {error}");
                None
            }
        };
        let home_directory = cmd.get_env("HOME").or_else(|| cmd.get_env("USERPROFILE"))
            .map(std::path::PathBuf::from).filter(|path| path.is_absolute());
        let pixel_size = |columns: u16, rows: u16| (
            (u32::from(columns)*cell.0).min(u16::MAX as u32) as u16,
            (u32::from(rows)*cell.1).min(u16::MAX as u32) as u16,
        );
        let (input, rx) = mpsc::sync_channel::<Vec<u8>>(64);
        let stop = Arc::new(AtomicBool::new(false));
        let discard = Arc::new(AtomicBool::new(false));
        let (pty, output) = match holders {
            Some(holders) => {
                let (pixel_width, pixel_height) = pixel_size(columns, rows);
                let spec = crate::holder_proto::Spawn {
                    argv: cmd.get_argv().iter().map(|arg| arg.to_string_lossy().into_owned()).collect(),
                    // Non-UTF-8 variables cannot cross the JSON spawn request.
                    env: cmd.iter_full_env_as_str().map(|(k, v)| (k.to_owned(), v.to_owned())).collect(),
                    cwd: cmd.get_cwd().map(|cwd| cwd.to_string_lossy().into_owned()).unwrap_or_default(),
                    cols: columns,
                    rows,
                    pixel_width,
                    pixel_height,
                    #[cfg(windows)]
                    title: initial_console_title.clone(),
                    #[cfg(not(windows))]
                    title: String::new(),
                };
                let id32 = u32::try_from(id).map_err(|_| "Terminal id exceeds the holder's range")?;
                let (held, output) = holders.spawn(id32, &spec)?;
                #[cfg(target_os = "linux")]
                if let Some(boundary) = &resource_boundary {
                    if let Err(error) = boundary.join(held.pid) {
                        eprintln!("Terminal {id} resource monitoring unavailable: {error}");
                    }
                }
                #[cfg(windows)]
                {
                    resource_boundary = Some(held_boundary(&held)?);
                }
                held.forward_input(rx);
                (Pty::Held(held), output)
            }
            None => {
                let (pixel_width, pixel_height) = pixel_size(columns, rows);
                let pair = portable_pty::native_pty_system()
                    .openpty(PtySize { rows, cols: columns, pixel_width, pixel_height })?;
                let child = pair.slave.spawn_command(cmd)?;
                // The monitor inspects the shell as soon as the session registers;
                // the bootstrap alone may not have run yet.
                #[cfg(target_os = "linux")]
                if let (Some(boundary), Some(pid)) = (&resource_boundary, child.process_id()) {
                    if let Err(error) = boundary.join(pid) {
                        eprintln!("Terminal {id} resource monitoring unavailable: {error}");
                    }
                }
                #[cfg(windows)]
                if let Some(boundary) = resource_boundary.as_mut() {
                    boundary.register(child.process_id().ok_or_else(||
                        std::io::Error::other("New terminal has no process ID"))?);
                }
                drop(pair.slave);
                let mut reader = pair.master.try_clone_reader()?;
                let mut writer = pair.master.take_writer()?;
                let (tx, output) = mpsc::sync_channel(64);
                let stopping = stop.clone();
                let discarding = discard.clone();
                #[cfg(unix)]
                let fd = pair.master.as_raw_fd().unwrap();
                thread::spawn(move || {
                    let mut buffer = [0; 16384];
                    while !stopping.load(Ordering::Relaxed) {
                        #[cfg(unix)]
                        {
                            let mut poll = libc::pollfd {
                                fd,
                                events: libc::POLLIN,
                                revents: 0,
                            };
                            if unsafe { libc::poll(&mut poll, 1, 100) } <= 0 {
                                continue;
                            }
                        }
                        match reader.read(&mut buffer) {
                            Ok(0) => break,
                            Ok(n) => {
                                if !discarding.load(Ordering::Relaxed)
                                    && tx.send(buffer[..n].to_vec()).is_err()
                                {
                                    break;
                                }
                                crate::wake::notify();
                            }
                            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                            Err(_) => break,
                        }
                    }
                });
                thread::spawn(move || {
                    for bytes in rx {
                        if writer
                            .write_all(&bytes)
                            .and_then(|_| writer.flush())
                            .is_err()
                        {
                            break;
                        }
                    }
                });
                (Pty::Local { master: pair.master, child }, output)
            }
        };
        Self::assemble(Parts {
            id,
            tab,
            workspace: workspace.into(),
            initial_directory,
            shell: options.map(|v| v.shell.to_string_lossy().into_owned()).unwrap_or_else(|| shell.to_owned()),
            token: token.into(),
            home_directory,
            font_size,
            cell,
            columns,
            rows,
            rect: [24., 60., 960. + insets[0] + insets[2], 552. + insets[1] + insets[3]],
            limits,
            shell_hooks,
            #[cfg(windows)]
            initial_console_title,
            #[cfg(windows)]
            resource_boundary: resource_boundary.ok_or("Terminal has no Job Object")?,
            #[cfg(target_os = "linux")]
            resource_boundary,
            pty,
            input,
            output,
            stop,
            discard,
        })
    }
    fn assemble(parts: Parts) -> Result<Self, Error> {
        let Parts {
            id, tab, workspace, initial_directory, shell, token, home_directory, font_size, cell,
            columns, rows, rect, limits, shell_hooks,
            #[cfg(windows)]
            initial_console_title,
            #[cfg(any(windows, target_os = "linux"))]
            resource_boundary,
            pty, input, output, stop, discard,
        } = parts;
        let Terminal_ { vt, query_theme, geometry, cell_geometry, bell, program_reports, claim_nonces, effect_messages, muted } =
            Self::terminal(columns, rows, cell, limits, input.clone())?;
        Ok(Self {
            id,
            tab,
            workspace,
            initial_directory,
            shell,
            token,
            pinned_title: String::new(),
            builtin_title: String::new(),
            home_directory,
            font_size,
            cell,
            cell_geometry,
            logical_extent: (960., 552.),
            layout_extent: None,
            columns,
            rows,
            revision: 1,
            exited: false,
            rect,
            presentation_chunks: VecDeque::new(),
            presentation_bytes: 0,
            scene_generation: 1,
            projection: Default::default(),
            image_cursor: None,
            scene_assets: Default::default(),
            #[cfg(target_os = "macos")]
            local_surfaces: Default::default(),
            scene_graphics: None,
            scene_checkpoint: None,
            observer: Default::default(),
            notifications: VecDeque::new(),
            notification_sequence: 0,
            clipboard: Default::default(),
            checkpoint: None,
            limits,
            spawned_by: None,
            dies_with_parent: false,
            _shell_hooks: shell_hooks,
            #[cfg(windows)]
            initial_console_title,
            images: crate::images::State::with_limits(limits),
            vt,
            query_theme,
            pty,
            detached: false,
            #[cfg(any(windows, target_os = "linux"))]
            _resource_boundary: resource_boundary,
            input,
            command_input: None,
            typing_guard: Default::default(),
            input_sequence: 0,
            input_events: VecDeque::new(),
            output,
            stop,
            discard,
            geometry,
            bell,
            program_status: Default::default(),
            program_status_changed: false,
            program_reports,
            claim_nonces,
            effect_holds: Default::default(),
            effect_messages,
            muted,
        })
    }
    /// Takes over a terminal its holder kept running across a server restart.
    /// `screen` is the exact screen a planned restart saved; without it the
    /// screen is rebuilt from the holder's recent output.
    pub fn adopt(
        saved: &crate::owner_state::SavedSession,
        adopted: crate::holder_link::Adopted,
        metrics: crate::fonts::Metrics,
        screen: Option<Vec<u8>>,
    ) -> Result<Self, Error> {
        let crate::holder_link::Adopted { held, output, terminal, tail, .. } = adopted;
        let cell = (metrics.width, metrics.height);
        let (input, queued) = mpsc::sync_channel::<Vec<u8>>(64);
        held.forward_input(queued);
        let ended = terminal.exit.is_some();
        #[cfg(windows)]
        let resource_boundary = held_boundary(&held)?;
        let pixel = |n: u16, size: u32| (u32::from(n) * size).min(u16::MAX as u32) as u16;
        let (pixel_width, pixel_height) = (pixel(terminal.cols, cell.0), pixel(terminal.rows, cell.1));
        if !ended && screen.is_none() {
            held.nudge(terminal.cols, terminal.rows, pixel_width, pixel_height);
        }
        let mut session = Self::assemble(Parts {
            id: saved.id,
            tab: saved.tab,
            workspace: saved.workspace.clone(),
            initial_directory: saved.initial_directory.clone(),
            shell: saved.shell.clone(),
            token: saved.token.clone(),
            home_directory: saved.home_directory.clone(),
            font_size: saved.font_size,
            cell,
            columns: terminal.cols,
            rows: terminal.rows,
            rect: saved.rect,
            limits: saved.limits,
            // The previous server's hook files stay where the shell found them.
            shell_hooks: None,
            #[cfg(windows)]
            initial_console_title: saved.console_title.clone(),
            #[cfg(windows)]
            resource_boundary,
            #[cfg(target_os = "linux")]
            resource_boundary: None,
            pty: Pty::Held(held),
            input,
            output,
            stop: Arc::new(AtomicBool::new(false)),
            discard: Arc::new(AtomicBool::new(false)),
        })?;
        session.pinned_title.clone_from(&saved.pinned_title);
        session.builtin_title.clone_from(&saved.builtin_title);
        session.logical_extent = saved.logical_extent;
        session.layout_extent = saved.layout_extent;
        session.program_status = saved.program_status.clone();
        session.spawned_by = saved.spawned_by;
        session.dies_with_parent = saved.dies_with_parent;
        // A saved screen is synthetic: nothing it asks may reach the program.
        //
        // After a planned restart the tail is new output nobody answered yet;
        // after a crash it was answered long ago and replies would be typed
        // as garbage.
        let exact = screen.is_some();
        if let Some(screen) = screen {
            session.muted.set(true);
            session.feed(&screen);
        }
        session.muted.set(!exact);
        session.feed(&tail);
        session.muted.set(false);
        session.program_status_changed = true;
        Ok(session)
    }
    /// What the next server needs to adopt this session.
    pub fn saved(&self) -> crate::owner_state::SavedSession {
        crate::owner_state::SavedSession {
            id: self.id,
            tab: self.tab,
            workspace: self.workspace.clone(),
            shell: self.shell.clone(),
            token: self.token.clone(),
            pinned_title: self.pinned_title.clone(),
            builtin_title: self.builtin_title.clone(),
            font_size: self.font_size,
            rect: self.rect,
            logical_extent: self.logical_extent,
            layout_extent: self.layout_extent,
            limits: self.limits,
            initial_directory: self.initial_directory.clone(),
            home_directory: self.home_directory.clone(),
            program_status: self.program_status.clone(),
            spawned_by: self.spawned_by,
            dies_with_parent: self.dies_with_parent,
            #[cfg(windows)]
            console_title: self.initial_console_title.clone(),
            #[cfg(not(windows))]
            console_title: String::new(),
        }
    }
    /// Whether a planned restart can hand this terminal to the next server.
    pub fn is_held(&self) -> bool {
        matches!(self.pty, Pty::Held(_))
    }
    /// The screen exactly (palette, modes, scrollback, images), as VT for the
    /// next server, after applying whatever output already arrived.
    pub fn handover_screen(&mut self) -> Result<Vec<u8>, Error> {
        while let Ok(bytes) = self.output.try_recv() {
            self.feed(&bytes);
        }
        let terminal = crate::checkpoint::capture(&self.vt)?;
        self.images.capture(&self.vt, terminal).map_err(Into::into)
    }
    fn terminal(
        columns: u16,
        rows: u16,
        cell: (u32, u32),
        limits: crate::spawn::TerminalLimits,
        input: SyncSender<Vec<u8>>,
    ) -> Result<Terminal_, Error> {
        let mut vt = graffitty_terminal_core::new_vt(columns, rows, limits.scrollback_bytes as usize)?;
        let query_theme = graffitty_terminal_core::theme::Queries::new(&mut vt)?;
        crate::images::configure_with_limits(&mut vt, limits)?;
        let replies = input;
        let muted = Rc::new(Cell::new(false));
        let silent = muted.clone();
        vt.on_pty_write(move |_, bytes| {
            if !silent.get() {
                let _ = replies.try_send(bytes.to_vec());
            }
        })?;
        vt.resize(columns, rows, cell.0, cell.1)?;
        let geometry = Rc::new(Cell::new((columns, rows)));
        let dimensions = geometry.clone();
        let cell_geometry = Rc::new(Cell::new(cell));
        let cell_dimensions = cell_geometry.clone();
        vt.on_size(move |_| {
            let (columns, rows) = dimensions.get();
            Some(SizeReportSize {
                columns,
                rows,
                cell_width: cell_dimensions.get().0,
                cell_height: cell_dimensions.get().1,
            })
        })?;
        let bell = Rc::new(Cell::new(false));
        let bell_event = bell.clone();
        vt.on_bell(move |_| bell_event.set(true))?;
        vt.on_xtversion(|_| Some("graffitty-server"))?;
        // Setting this also makes the VT answer `OSC 7501 ; ?` support queries.
        let program_reports = Rc::new(std::cell::RefCell::new(Vec::new()));
        let reports = program_reports.clone();
        vt.on_program_status(move |_, report| {
            reports.borrow_mut().extend(graffitty_terminal_core::program_status::StatusReport::from_vt(report));
        })?;
        // OSC 4723: pane claims and effect holds. Replayed output never claims
        // or holds: it belongs to a previous server and the program did not
        // just print it.
        let claim_nonces = Rc::new(std::cell::RefCell::new(Vec::new()));
        let effect_messages = Rc::new(std::cell::RefCell::new(Vec::new()));
        let (claims, effects, replaying) = (claim_nonces.clone(), effect_messages.clone(), muted.clone());
        vt.on_unknown_sequence(move |_, sequence| {
            use graffitty_protocol::osc::Message;
            use graffitty_terminal_core::vt::terminal::UnknownSequence;
            let UnknownSequence::Osc { content, truncated: false, .. } = sequence else { return };
            if replaying.get() { return }
            match graffitty_protocol::osc::parse(content) {
                Some(Message::Claim(nonce)) => claims.borrow_mut().push(nonce),
                Some(Message::Effects(message)) => effects.borrow_mut().push(message),
                None => {}
            }
        })?;
        vt.set_unknown_max_bytes(graffitty_protocol::osc::MAX_SEQUENCE_BYTES)?;
        vt.on_device_attributes(|_| {
            use graffitty_terminal_core::vt::terminal::*;
            Some(DeviceAttributes {
                primary: PrimaryDeviceAttributes::new(
                    ConformanceLevel::VT220,
                    &[DeviceAttributeFeature::ANSI_COLOR],
                ),
                secondary: SecondaryDeviceAttributes {
                    device_type: DeviceType::VT220,
                    firmware_version: 1,
                    rom_cartridge: 0,
                },
                tertiary: Default::default(),
            })
        })?;
        Ok(Terminal_ { vt, query_theme, geometry, cell_geometry, bell, program_reports, claim_nonces, effect_messages, muted })
    }
    pub fn terminal_theme(&self) -> &graffitty_protocol::terminal_theme::Theme {
        self.query_theme.theme()
    }
    pub fn set_terminal_theme(&mut self, theme: graffitty_protocol::terminal_theme::Theme) -> Result<(), Error> {
        if let Some(report) = self.query_theme.update(&mut self.vt, theme)? {
            self.input(report.to_vec())?;
        }
        Ok(())
    }
    pub fn scene_ready(&self) -> bool { self.projection.at_boundary() }
    pub fn poll(&mut self) {
        // Fairness: noisy terminals cannot starve other workspaces or input.
        let mut drained = false;
        for _ in 0..64 {
            let Ok(bytes) = self.output.try_recv() else {
                drained = true;
                break;
            };
            self.feed(&bytes);
        }
        let ended = match &mut self.pty {
            Pty::Local { child, .. } => child.try_wait().ok().flatten().is_some(),
            // The holder reports an exit after forwarding the last output.
            Pty::Held(held) => {
                // Windows consoles have no foreground process group.
                #[cfg(unix)]
                held.refresh_foreground();
                drained && held.exit().is_some()
            }
        };
        if !self.exited && ended {
            self.clipboard.reset();
            self.exited = true;
            self.revision += 1;
        }
        if let Some(job) = self.command_input.as_mut() {
            let finished = job.poll(&self.vt, &self.input, self.exited);
            for event in job.take_activity() {
                self.input_sequence += 1;
                self.input_events.push_back((self.input_sequence, event));
                if self.input_events.len() > 256 { self.input_events.pop_front(); }
            }
            if finished { self.command_input = None; }
        }
    }
    /// Apply one chunk of program output.
    fn feed(&mut self, bytes: &[u8]) {
        {
            let bytes = bytes;
            self.images.feed(&bytes);
            let (presentation, boundaries) = self.projection.feed(&bytes);
            let mut offset = 0;
            let mut events: Vec<_> = boundaries.into_iter().map(|(end, boundary)| (end, 1, None, Some(boundary))).collect();
            self.observer.feed_each(&bytes, |end, event| events.push((end, 0, Some(event), None)));
            events.sort_by_key(|(end, priority, ..)| (*end, *priority));
            for (end, _, event, boundary) in events {
                self.vt.vt_write(&bytes[offset..end]);
                offset = end;
                if let Some(boundary) = boundary {
                    use graffitty_terminal_core::presentation_stream::Boundary;
                    let cursor = (self.vt.cursor_x().unwrap_or(0), self.vt.cursor_y().unwrap_or(0), self.vt.total_rows().unwrap_or(0), self.vt.is_cursor_pending_wrap().unwrap_or(false));
                    match boundary {
                        Boundary::Begin => self.image_cursor = Some(cursor),
                        Boundary::End { graphics } => {
                            // Most graphics operations only change placements.
                            // A legacy implicit cursor/scroll side effect requires
                            // a text-only checkpoint; pixels remain independent.
                            if graphics && self.image_cursor.is_some_and(|before| before != cursor) { self.scene_generation += 1; }
                            self.image_cursor = None;
                        }
                    }
                    continue;
                }
                use crate::terminal_protocol::Event;
                let value = match event.unwrap() {
                    Event::Notification(title, body) => {
                        Some(serde_json::json!({"title":title,"body":body}))
                    }
                    Event::Notify99(packet) => {
                        if let Some(reply) = crate::terminal_protocol::notification_query(&packet) {
                            // Queue the capability response before later DA1
                            // bytes reach the VT, once per owning terminal.
                            let _ = self.input(reply.into_bytes());
                            None
                        } else {
                            Some(serde_json::json!({"packet":packet}))
                        }
                    }
                    Event::Clipboard5522(packet) => {
                        self.clipboard.push(graffitty_protocol::clipboard::Operation::Rich { packet });
                        None
                    }
                    Event::ClipboardRead(selector, bel) => {
                        self.clipboard.push(graffitty_protocol::clipboard::Operation::ReadText { selector, bel });
                        None
                    }
                    Event::ClipboardWrite(selector, encoded) => {
                        self.clipboard.push(graffitty_protocol::clipboard::Operation::WriteText { selector, encoded });
                        None
                    }
                    Event::KittyHeader(header) => {
                        self.images.header(&header, &self.vt);
                        None
                    }
                    Event::Sixel(data) => {
                        self.images.external_upload = true;
                        if let Some((png, w, h)) = crate::inline_images::sixel(&data) {
                            crate::inline_images::place(
                                &mut self.vt,
                                &png,
                                w,
                                h,
                                self.cell,
                            );
                        }
                        None
                    }
                    Event::Erase { command, count } => {
                        crate::inline_images::erase(&mut self.vt, command, count);
                        None
                    }
                    Event::ItermImage(packet) => {
                        self.images.external_upload = true;
                        self.images.inline.iterm(
                            &packet,
                            &mut self.vt,
                            self.cell,
                            crate::images::inline_decode,
                        );
                        None
                    }
                    Event::Reset => {
                        self.clipboard.reset();
                        self.scene_assets.clear();
                        self.images.reset();
                        self.effect_holds.reset();
                        crate::images::apply_policy(&mut self.vt, self.limits, true)
                            .expect("Validated image policy must survive terminal reset");
                        None
                    }
                    _ => None,
                };
                if let Some(value) = value {
                    self.notification_sequence += 1;
                    self.notifications
                        .push_back((self.notification_sequence, value));
                    if self.notifications.len() > 256 {
                        self.notifications.pop_front();
                    }
                }
            }
            self.vt.vt_write(&bytes[offset..]);
            for report in self.program_reports.take() {
                if self.program_status.apply(&report).root_report || report.state == "clear" {
                    self.program_status_changed = true;
                }
            }
            let messages = self.effect_messages.take();
            if !messages.is_empty() {
                // A `process` hold belongs to whoever is in the foreground as it prints.
                let pgid = self.foreground();
                for message in &messages { self.effect_holds.apply(message, pgid); }
            }
            if self.bell.replace(false) {
                self.notification_sequence += 1;
                self.notifications
                    .push_back((self.notification_sequence, serde_json::json!({"bell":true})));
                if self.notifications.len() > 256 {
                    self.notifications.pop_front();
                }
            }
            self.images.prune(&mut self.vt);
            self.presentation_bytes += presentation.len();
            self.presentation_chunks.push_back((self.revision + 1, presentation));
            while self.presentation_bytes > 2 * 1024 * 1024 || self.presentation_chunks.len() > 4096 {
                if let Some((_, old)) = self.presentation_chunks.pop_front() { self.presentation_bytes -= old.len(); }
            }
            self.checkpoint = None;
            self.scene_checkpoint = None;
            self.scene_graphics = None;
            self.revision += 1;
        }
    }
    pub fn input(&self, bytes: Vec<u8>) -> Result<(), Error> {
        if self.exited {
            return Err("Terminal has exited".into());
        }
        self.input
            .try_send(bytes)
            .map_err(|_| "Terminal input queue is full".into())
    }
    pub fn paste(&self, text: &str) -> Result<(), Error> {
        self.send_paste(text, false)
    }
    pub fn send_paste(&self, text: &str, enter: bool) -> Result<(), Error> {
        let text = text.replace('\x1b', "");
        let mut bytes = if self
            .vt
            .mode(graffitty_terminal_core::vt::terminal::Mode::new(
                2004,
                graffitty_terminal_core::vt::terminal::ModeKind::Dec,
            ))
            .unwrap_or(false)
        {
            format!("\x1b[200~{text}\x1b[201~").into_bytes()
        } else {
            text.replace('\n', "\r").into_bytes()
        };
        if enter { bytes.extend(graffitty_terminal_core::command_input::Stroke::parse("Enter").unwrap().encode(&self.vt)?); }
        self.input(bytes)
    }
    pub fn configure_font(&mut self, size: u16, metrics: crate::fonts::Metrics) -> Result<(), Error> {
        self.font_size = size;
        self.cell = (metrics.width, metrics.height);
        self.cell_geometry.set(self.cell);
        let (width, height) = self.logical_extent;
        self.resize((width / self.cell.0 as f64).floor().clamp(f64::from(MIN_COLUMNS), 500.) as u16,
            (height / self.cell.1 as f64).floor().clamp(1., 300.) as u16)?;
        self.logical_extent = (width, height);
        Ok(())
    }
    pub fn resize_pixels(&mut self, width: f64, height: f64) -> Result<(), Error> {
        // A phone pane between docks can be narrower than a typical grid. The grid
        // must fit the pane, as rows do, or its right columns are clipped.
        let cols = (width / self.cell.0 as f64).floor().clamp(f64::from(MIN_COLUMNS), 500.) as u16;
        // A landscape soft keyboard can leave only one or two terminal rows.
        // The grid must fit the actual pane instead of extending under the IME.
        let rows = (height / self.cell.1 as f64).floor().clamp(1., 300.) as u16;
        // Preserve sub-cell space across font changes, rather than accumulating rounding.
        if (cols, rows) != (self.columns, self.rows) {
            self.resize(cols, rows)?;
        }
        self.logical_extent = (width, height);
        Ok(())
    }
    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), Error> {
        if !(MIN_COLUMNS..=500).contains(&cols) || !(1..=300).contains(&rows) {
            return Err("Invalid grid size".into());
        }
        let pixel_width = (u32::from(cols)*self.cell.0).min(u16::MAX as u32) as u16;
        let pixel_height = (u32::from(rows)*self.cell.1).min(u16::MAX as u32) as u16;
        match &self.pty {
            Pty::Local { master, .. } => master.resize(PtySize { cols, rows, pixel_width, pixel_height })?,
            Pty::Held(held) => held.resize(cols, rows, pixel_width, pixel_height),
        }
        self.vt
            .resize(cols, rows, self.cell.0, self.cell.1)?;
        self.columns = cols;
        self.rows = rows;
        self.geometry.set((cols, rows));
        self.scene_generation += 1;
        self.scene_checkpoint = None;
        self.scene_graphics = None;
        self.checkpoint = None;
        self.logical_extent = (cols as f64 * self.cell.0 as f64, rows as f64 * self.cell.1 as f64);
        self.rect[2] = self.logical_extent.0 + 8.;
        self.rect[3] = self.logical_extent.1 + 38.;
        self.revision += 1;
        Ok(())
    }
    pub fn checkpoint(&mut self) -> Result<Arc<Vec<u8>>, Error> {
        if self.checkpoint.is_none() {
            let terminal = crate::checkpoint::capture_frontend(&mut self.vt)?;
            self.checkpoint = Some(Arc::new(self.images.capture(&self.vt, terminal)?));
        }
        Ok(self.checkpoint.as_ref().unwrap().clone())
    }
    pub fn scene_checkpoint(&mut self) -> Result<Arc<Vec<u8>>, Error> {
        if self.scene_checkpoint.is_none() {
            self.scene_checkpoint = Some(Arc::new(crate::checkpoint::capture_frontend(&mut self.vt)?));
        }
        Ok(self.scene_checkpoint.as_ref().unwrap().clone())
    }
    pub fn scene_graphics(&mut self) -> Result<graffitty_protocol::terminal_scene::Graphics, Error> {
        if self.scene_graphics.is_none() {
            self.scene_graphics = Some(self.scene_assets.capture(&self.vt, &self.images)?);
        }
        Ok(self.scene_graphics.as_ref().unwrap().clone())
    }
    #[cfg(target_os = "macos")]
    pub fn shared_image(&mut self, asset: &graffitty_terminal_core::scene::Asset) -> Result<graffitty_chromium_video::surface::Surface, String> {
        self.local_surfaces.retain(|key, _| self.scene_assets.assets.contains_key(key));
        if !self.local_surfaces.contains_key(&asset.key) {
            self.local_surfaces.insert(asset.key.clone(), graffitty_chromium_video::surface::Surface::from_rgba(asset.width, asset.height, &asset.rgba)?);
        }
        Ok(self.local_surfaces[&asset.key].clone())
    }
    pub fn title(&self) -> String {
        if !self.pinned_title.is_empty() {
            return self.pinned_title.clone();
        }
        let title = self.automatic_title();
        if title.is_empty() { format!("%{}", self.id) } else { title }
    }
    pub fn reported_title(&self) -> &str {
        let title = self.vt.title().ok().and_then(|b| std::str::from_utf8(b).ok()).unwrap_or("");
        // Normalize the external console's startup decoration at the title
        // boundary. Never inject VT into a parser that may hold a partial OSC.
        #[cfg(windows)]
        if title.ends_with(&self.initial_console_title) { return ""; }
        title
    }
    pub fn automatic_title(&self) -> String {
        if !self.builtin_title.is_empty() {
            return self.builtin_title.clone();
        }
        let title = self.reported_title();
        if title.is_empty() {
            let report = self.pwd_report();
            let reported = crate::titles::reported_directory(report);
            if !reported.is_empty() {
                // Remote OSC 7 authorities must not be interpreted relative to
                // this shell's home, even if their path happens to match it.
                if crate::filetree::directory_from_report(report).is_some() {
                    crate::titles::directory_title(std::path::Path::new(&reported), self.home_directory.as_deref())
                } else {
                    reported
                }
            } else {
                self.initial_directory.as_deref()
                    .map(|path| crate::titles::directory_title(path, self.home_directory.as_deref()))
                    .unwrap_or_default()
            }
        } else {
            title.into()
        }
    }
    pub fn history(&self) -> Result<String, Error> {
        crate::terminal_text::capture(&self.vt, self.columns, true).map_err(Into::into)
    }
    pub fn text(&self, scrollback: bool) -> Result<String, Error> {
        crate::terminal_text::capture(&self.vt, self.columns, scrollback).map_err(Into::into)
    }
    pub fn foreground(&self) -> Option<i32> {
        match &self.pty {
            #[cfg(unix)]
            Pty::Local { master, .. } => { let pid = unsafe { libc::tcgetpgrp(master.as_raw_fd()?) }; (pid > 0).then_some(pid) }
            #[cfg(unix)]
            Pty::Held(held) => held.foreground(),
            #[cfg(not(unix))]
            _ => None,
        }
    }
    pub fn tty_name(&self) -> String {
        match &self.pty {
            #[cfg(unix)]
            Pty::Local { master, .. } => master.tty_name().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default(),
            #[cfg(not(unix))]
            Pty::Local { .. } => String::new(),
            Pty::Held(held) => held.tty.clone(),
        }
    }
    pub fn pid(&self) -> Option<u32> {
        match &self.pty {
            Pty::Local { child, .. } => child.process_id(),
            Pty::Held(held) => Some(held.pid),
        }
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.discard.store(true, Ordering::Relaxed);
        while self.output.try_recv().is_ok() {}
        let (master, child) = match &mut self.pty {
            Pty::Local { master, child } => (master, child),
            // A planned restart leaves it to the holder for the next server,
            // including the hook files its shell may still read.
            Pty::Held(_) if self.detached => {
                std::mem::forget(self._shell_hooks.take());
                return;
            }
            // The holder ends the program. Releasing the terminal then closes its
            // pseudoconsole, and that ends every other attached program.
            #[cfg(windows)]
            Pty::Held(held) => {
                held.signal(crate::holder_proto::KILL);
                held.release();
                return;
            }
            #[cfg(unix)]
            Pty::Held(held) => {
                let jobs = crate::session_jobs::Jobs::capture(Some(held.pid));
                jobs.signal(libc::SIGHUP);
                // The holder hangs up the shell's group and the foreground job.
                held.signal(libc::SIGHUP);
                let deadline = std::time::Instant::now() + std::time::Duration::from_millis(100);
                while held.exit().is_none() && std::time::Instant::now() < deadline {
                    while self.output.try_recv().is_ok() {}
                    thread::sleep(std::time::Duration::from_millis(5));
                }
                if held.exit().is_none() {
                    held.signal(libc::SIGKILL);
                }
                jobs.signal(libc::SIGKILL);
                held.release();
                return;
            }
        };
        #[cfg(unix)]
        let jobs=crate::session_jobs::Jobs::capture(child.process_id());
        #[cfg(unix)]
        jobs.signal(libc::SIGHUP);
        #[cfg(unix)]
        unsafe {
            // Closing a pane closes its foreground job as well as its shell.
            if let Some(pid) = master.process_group_leader() {
                libc::kill(-pid, libc::SIGHUP);
            }
            if let Some(pid) = child.process_id() {
                libc::kill(-(pid as i32), libc::SIGHUP);
            }
        }
        let _ = child.kill();
        // portable-pty's Unix kill is SIGHUP. A shell flushing a full PTY can
        // remain blocked in its HUP handler, so never wait without escalation.
        #[cfg(unix)]
        {
            let deadline = std::time::Instant::now() + std::time::Duration::from_millis(100);
            while child.try_wait().ok().flatten().is_none()
                && std::time::Instant::now() < deadline
            {
                while self.output.try_recv().is_ok() {}
                thread::sleep(std::time::Duration::from_millis(5));
            }
            if child.try_wait().ok().flatten().is_none() {
                unsafe {
                    if let Some(group) = master.process_group_leader() {
                        libc::kill(-group, libc::SIGKILL);
                    }
                    if let Some(pid) = child.process_id() {
                        libc::kill(pid as i32, libc::SIGKILL);
                    }
                }
            }
            // A shell can exit before a background job that ignores HUP.
            // Its recorded start identity prevents signalling a reused PID.
            jobs.signal(libc::SIGKILL);
        }
        let _ = child.wait();
        self.stop.store(true, Ordering::Relaxed);
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;
    #[test]
    fn windows_pty_wait_handles_exit_259_and_successful_kill() {
        for route in ["exit", "kill", "cloned-kill"] {
            let pair = portable_pty::native_pty_system().openpty(PtySize::default()).unwrap();
            let mut command = CommandBuilder::new("cmd.exe");
            command.args(["/d", "/c", if route == "exit" { "exit 259" }
                else { "for /L %i in (1,0,2) do @rem waiting" }]);
            let mut child = pair.slave.spawn_command(command).unwrap();
            if route == "kill" { child.kill().unwrap(); }
            if route == "cloned-kill" { child.clone_killer().kill().unwrap(); }
            let code = if route == "exit" { 259 } else { 1 };
            assert_eq!(child.wait().unwrap().exit_code(), code);
            assert_eq!(child.try_wait().unwrap().unwrap().exit_code(), code);
        }
    }

    #[test]
    fn shell_osc_directory_overrides_windows_process_directory() {
        let directory = std::env::temp_dir().join(format!("graffitty cwd 한글 {}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let options = crate::spawn::SpawnOptions {
            shell: Some("cmd.exe".into()), args: vec!["/d".into(), "/q".into()],
            login: Some(false), ..Default::default()
        }.prepare("cmd.exe", None).unwrap();
        let mut session = Session::new(1, 1, "cwd-test", "cmd.exe", "private",
            "capability", "graffitty", None, Some(&options)).unwrap();
        let initial = session.cwd().unwrap();
        let report = format!("\x1b]7;file://localhost/{}\x07",
            directory.to_string_lossy().replace('\\', "/").replace(' ', "%20"));
        session.vt.vt_write(report.as_bytes());
        assert_eq!(session.cwd().unwrap(), directory);
        std::fs::remove_dir(&directory).unwrap();
        assert_eq!(session.cwd().unwrap(), initial, "Deleted reported directories fall back to the live process");
    }

    #[test]
    fn console_startup_title_leaves_cwd_visible_until_an_application_sets_title() {
        let options = crate::spawn::SpawnOptions {
            shell: Some("cmd.exe".into()),
            args: vec!["/d".into(), "/q".into(), "/k".into(), "echo TITLE_READY".into()],
            login: Some(false),
            ..Default::default()
        }.prepare("cmd.exe", None).unwrap();
        let mut session = Session::new(1, 1, "titles-test", "cmd.exe", "private",
            "capability", "graffitty", None, Some(&options)).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !session.text(false).unwrap().contains("TITLE_READY") {
            session.poll();
            assert!(std::time::Instant::now() < deadline, "Native console did not start");
            thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(session.reported_title(), "");
        assert_eq!(session.title(), session.initial_directory.as_ref().unwrap().to_string_lossy());
        session.vt.vt_write(b"\x1b]2;Editor");
        assert_eq!(session.reported_title(), "", "A partial title must not expose the startup decoration");
        session.vt.vt_write(b" title\x07");
        assert_eq!(session.title(), "Editor title");
        session.vt.vt_write("\x1b]2;관리자: actual application title\x07".as_bytes());
        assert_eq!(session.title(), "관리자: actual application title", "Do not strip legitimate application title prefixes");
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn keyboard_sized_panes_and_font_changes_retain_a_fitting_grid() {
        let mut session=Session::new(1,1,"keyboard-grid","/bin/sh","private","capability",
            "graffitty",None,None).unwrap();
        let pid=session.pid();
        for rows in [1,2,4,16] {
            let height=session.cell.1 as f64*(rows as f64+0.25);
            session.resize_pixels(session.cell.0 as f64*80.,height).unwrap();
            assert_eq!((session.columns,session.rows),(80,rows));
            assert!(session.rows as f64*session.cell.1 as f64<=height);
            let metrics=crate::fonts::Metrics {width:session.cell.0,height:session.cell.1,baseline:0.,underline:0.,thickness:1.};
            session.configure_font(session.font_size,metrics).unwrap();
            assert_eq!(session.rows,rows);
            assert_eq!(session.pid(),pid);
        }
        // A phone pane between docks: the grid fits it instead of being clipped.
        for columns in [MIN_COLUMNS,3,9,19] {
            let width=session.cell.0 as f64*(columns as f64+0.5);
            session.resize_pixels(width,session.cell.1 as f64*4.).unwrap();
            assert_eq!(session.columns,columns);
        }
        session.resize_pixels(1.,session.cell.1 as f64*4.).unwrap();
        assert_eq!(session.columns,MIN_COLUMNS);
        assert!(session.resize(MIN_COLUMNS-1,4).is_err());
        assert_eq!(session.pid(),pid);
    }

    #[test]
    fn title_follows_osc_then_reported_directory_under_pane_and_builtin_pins() {
        let options = crate::spawn::SpawnOptions { shell: Some("/bin/sh".into()),
            login: Some(false), ..Default::default() }.prepare("/bin/sh", None).unwrap();
        let mut session = Session::new(1, 1, "titles-test", "/bin/sh", "private", "capability",
            "graffitty", None, Some(&options)).unwrap();
        session.initial_directory = None;
        assert_eq!(session.title(), "%1");
        assert_eq!(session.automatic_title(), "");
        session.initial_directory = Some("/tmp/start directory".into());
        assert_eq!(session.title(), "/tmp/start directory");
        session.vt.vt_write(b"\x1b]7;file://remote.invalid/tmp/title%20path\x07");
        assert_eq!(session.title(), "/tmp/title path");
        session.vt.vt_write(b"\x1b]2;editor\x07");
        assert_eq!(session.title(), "editor");
        session.pinned_title = "Pinned pane".into();
        session.vt.vt_write(b"\x1b]0;\x07");
        assert_eq!(session.title(), "Pinned pane");
        assert_eq!(session.automatic_title(), "/tmp/title path");
        session.pinned_title.clear();
        assert_eq!(session.title(), "/tmp/title path");
        session.builtin_title = "File tree".into();
        assert_eq!(session.title(), "File tree");
    }

    #[cfg(unix)]
    #[test]
    fn osc_7501_reports_reach_program_status() {
        let options = crate::spawn::SpawnOptions { shell: Some("/bin/sh".into()),
            login: Some(false), ..Default::default() }.prepare("/bin/sh", None).unwrap();
        let mut session = Session::new(1, 1, "status-test", "/bin/sh", "private", "capability",
            "graffitty", None, Some(&options)).unwrap();
        session.input(b"printf '\\033]7501;state=working:app=cargo\\033\\\\'\n".to_vec()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while session.program_status.word() != Some("working") && std::time::Instant::now() < deadline {
            session.poll();
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(std::mem::take(&mut session.program_status_changed));
        assert_eq!(session.program_status.status.as_ref().unwrap().app, "cargo");
    }

    #[cfg(unix)]
    #[test]
    fn osc_4723_claims_are_reported_and_replayed_claims_are_not() {
        let options = crate::spawn::SpawnOptions { shell: Some("/bin/sh".into()),
            login: Some(false), ..Default::default() }.prepare("/bin/sh", None).unwrap();
        let mut session = Session::new(1, 1, "claim-test", "/bin/sh", "private", "capability",
            "graffitty", None, Some(&options)).unwrap();
        let nonce = "0123456789abcdef0123456789abcdef";
        session.muted.set(true);
        session.feed(&graffitty_protocol::osc::encode_claim(nonce, false));
        session.feed(b"\x1b]4723;effects;hold=replayed;off=sparks\x07");
        session.muted.set(false);
        assert!(session.claim_nonces.take().is_empty());
        assert!(session.effect_messages.take().is_empty(), "replayed output never holds effects");
        session.input(format!("printf '\\033]4723;claim={nonce}\\007'\n").into_bytes()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut seen = vec![];
        while seen.is_empty() && std::time::Instant::now() < deadline {
            session.poll();
            seen = session.claim_nonces.take();
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(seen, [nonce]);
    }

    #[cfg(unix)]
    #[test]
    fn osc_4723_effect_holds_follow_the_printing_process_group() {
        let options = crate::spawn::SpawnOptions { shell: Some("/bin/sh".into()),
            login: Some(false), ..Default::default() }.prepare("/bin/sh", None).unwrap();
        let mut session = Session::new(1, 1, "hold-test", "/bin/sh", "private", "capability",
            "graffitty", None, Some(&options)).unwrap();
        session.input(b"printf '\\033]4723;effects;hold=sh;off=sparks,camera\\007'; printf '\\033]4723;effects;hold=kept;off=tab_switch;until=pane\\007'\n".to_vec()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while session.effect_holds.snapshot().len() < 2 && std::time::Instant::now() < deadline {
            session.poll();
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let ids: Vec<_> = session.effect_holds.snapshot().iter().map(|r| r.hold.id.clone()).collect();
        assert_eq!(ids, ["sh", "kept"]);
        let shell = session.effect_holds.snapshot()[0].pgid;
        assert_eq!(shell, session.foreground(), "a process hold records the group that printed it");
        assert!(!session.effect_holds.foreground_changed(shell), "the same group keeps its hold");
        assert!(session.effect_holds.foreground_changed(shell.map(|p| p + 1)));
        assert_eq!(session.effect_holds.snapshot()[0].hold.id, "kept");
        session.input(b"printf '\\033]4723;effects;release\\007'\n".to_vec()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !session.effect_holds.is_empty() && std::time::Instant::now() < deadline {
            session.poll();
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(session.effect_holds.is_empty());
    }

    #[test]
    fn new_home_tab_is_shortened_before_the_shell_reports_any_title() {
        let temporary = crate::shell_hooks::Hooks::prepare().unwrap();
        let home = temporary.directory.canonicalize().unwrap();
        let options = crate::spawn::SpawnOptions { shell: Some("/bin/sh".into()),
            login: Some(false), cwd: Some(home.to_string_lossy().into_owned()),
            env: [("HOME".into(), home.to_string_lossy().into_owned())].into(),
            ..Default::default() }.prepare("/bin/sh", None).unwrap();
        let mut session = Session::new(1, 1, "home-title-test", "/bin/sh", "private", "capability",
            "graffitty", None, Some(&options)).unwrap();
        // No poll: this is the first title published before shell initialization.
        assert_eq!(session.reported_title(), "");
        assert_eq!(session.title(), "~");
        assert_eq!(session.initial_directory.as_deref(), Some(home.as_path()));
        assert_eq!(session.cwd().as_deref(), Some(home.as_path()));
        let report = format!("\x1b]7;file://localhost{}\x07", home.display());
        session.vt.vt_write(report.as_bytes());
        assert_eq!(session.title(), "~", "A local OSC 7 report must not reintroduce the long title");
        session.vt.vt_write(b"\x1b]2;~\x07");
        assert_eq!(session.title(), "~", "The shell's home title does not change the displayed label");
        let literal = home.to_string_lossy().into_owned();
        session.vt.vt_write(format!("\x1b]2;{literal}\x07").as_bytes());
        assert_eq!(session.title(), literal, "Explicit application titles remain verbatim");
        session.pinned_title = literal.clone();
        session.vt.vt_write(b"\x1b]2;\x07");
        assert_eq!(session.title(), literal, "User pins remain verbatim");
        session.pinned_title.clear();
        session.vt.vt_write(format!("\x1b]7;file://remote.invalid{}\x07", home.display()).as_bytes());
        assert_eq!(session.title(), literal, "A remote directory must not use the local home");
        session.vt.vt_write(b"\x1b]7;\x07");
        session.initial_directory = Some(home.join("project"));
        assert_eq!(session.title(), "~/project");
    }

    #[test]
    #[cfg(any(target_os="macos",target_os="linux"))]
    fn closing_pty_kills_hup_ignoring_background_jobs_and_preserves_other_sessions() {
        let root=std::env::temp_dir().join(format!("graffitty-jobs-{}",uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let options=crate::spawn::SpawnOptions {shell:Some("/bin/sh".into()),login:Some(false),..Default::default()}
            .prepare("/bin/sh",None).unwrap();
        let mut closed=Session::new(1,1,"jobs-test","/bin/sh","private","capability","graffitty",None,Some(&options)).unwrap();
        let survivor=Session::new(2,2,"jobs-test","/bin/sh","private","capability","graffitty",None,Some(&options)).unwrap();
        let path=root.join("background.pid");
        let quoted=path.to_string_lossy().replace('\'',"'\\''");
        closed.input(format!("set -m; sh -c 'trap \"\" HUP; echo $$ > \"$1\"; exec sleep 30' sh '{quoted}' &\n").into_bytes()).unwrap();
        let deadline=std::time::Instant::now()+std::time::Duration::from_secs(5);
        let pid=loop {
            closed.poll();
            if let Some(pid)=std::fs::read_to_string(&path).ok().and_then(|v|v.trim().parse::<i32>().ok()) {break pid;}
            assert!(std::time::Instant::now()<deadline,"Background job did not start");
            thread::sleep(std::time::Duration::from_millis(10));
        };
        assert_ne!(unsafe {libc::getpgid(pid)},unsafe {libc::getpgid(closed.pid().unwrap() as i32)});
        let survivor_pid=survivor.pid().unwrap() as i32;
        drop(closed);
        let deadline=std::time::Instant::now()+std::time::Duration::from_secs(5);
        while unsafe {libc::kill(pid,0)}==0 && std::time::Instant::now()<deadline {
            thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(unsafe {libc::kill(pid,0)},-1,"Background job survived PTY close");
        assert_eq!(unsafe {libc::kill(survivor_pid,0)},0,"Another PTY was terminated");
        drop(survivor);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    #[cfg(any(target_os="macos",target_os="linux"))]
    fn closing_pty_kills_descendants_that_left_its_session() {
        // Neovim's TUI starts its `--embed` server in a new session.
        let root=std::env::temp_dir().join(format!("graffitty-jobs-{}",uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let options=crate::spawn::SpawnOptions {shell:Some("/bin/sh".into()),login:Some(false),..Default::default()}
            .prepare("/bin/sh",None).unwrap();
        let mut closed=Session::new(1,1,"jobs-test","/bin/sh","private","capability","graffitty",None,Some(&options)).unwrap();
        let path=root.join("detached.pid");
        let quoted=path.to_string_lossy().replace('\'',"'\\''");
        closed.input(format!("perl -MPOSIX -e 'if (my $c=fork) {{waitpid $c,0; exit}} POSIX::setsid()>0 or die; $SIG{{HUP}}=q(IGNORE); open my $f, q(>), $ARGV[0] or die; print $f $$; close $f; exec q(sleep), 30' '{quoted}' &\n").into_bytes()).unwrap();
        let deadline=std::time::Instant::now()+std::time::Duration::from_secs(5);
        let pid=loop {
            closed.poll();
            if let Some(pid)=std::fs::read_to_string(&path).ok().and_then(|v|v.trim().parse::<i32>().ok()) {break pid;}
            assert!(std::time::Instant::now()<deadline,"Detached job did not start");
            thread::sleep(std::time::Duration::from_millis(10));
        };
        assert_ne!(unsafe {libc::getsid(pid)},unsafe {libc::getsid(closed.pid().unwrap() as i32)});
        drop(closed);
        let deadline=std::time::Instant::now()+std::time::Duration::from_secs(5);
        while unsafe {libc::kill(pid,0)}==0 && std::time::Instant::now()<deadline {
            thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(unsafe {libc::kill(pid,0)},-1,"Detached descendant survived PTY close");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn preview_cleanup_survives_owner_poll_and_client_reconnect() {
        let options = crate::spawn::SpawnOptions {
            shell: Some("/bin/sh".into()), login: Some(false), ..Default::default()
        }.prepare("/bin/sh", None).unwrap();
        let mut session = Session::new(1, 1, "preview-test", "/bin/sh", "private", "capability",
            "graffitty", None, Some(&options)).unwrap();
        let (sender, receiver) = mpsc::sync_channel(4);
        let _pty_output = std::mem::replace(&mut session.output, receiver);
        sender.send(b"\x1b[3;4H\x1bP0;1q\"1;1;2;6#1;2;100;0;0!2~\x1b\\".to_vec()).unwrap();
        session.poll();
        let cell = (session.cell.0 as f32, session.cell.1 as f32);
        assert_eq!(graffitty_terminal_core::image_render::placements(&session.vt, cell).unwrap().len(), 1);
        let bytes = session.checkpoint().unwrap();
        let mut mirror = graffitty_terminal_core::new_vt(session.vt.cols().unwrap(), session.vt.rows().unwrap(), 100).unwrap();
        crate::images::configure(&mut mirror).unwrap();
        mirror.vt_write(&bytes);
        assert_eq!(graffitty_terminal_core::image_render::placements(&mirror, cell).unwrap().len(), 1);
        // One output packet can contain more than 64 effects before cleanup.
        let mut erase = b"\x1b[22;0t".repeat(80);
        erase.extend_from_slice(b"\x1b[3;1H\x1b[2K");
        sender.send(erase).unwrap();
        session.poll();
        assert!(graffitty_terminal_core::image_render::placements(&session.vt, cell).unwrap().is_empty());
        let bytes = session.checkpoint().unwrap();
        mirror.vt_write(&bytes);
        assert!(graffitty_terminal_core::image_render::placements(&mirror, cell).unwrap().is_empty());
    }

    #[test]
    fn new_pane_directory_uses_live_then_startup_then_home() {
        let root = std::env::temp_dir().join(format!("graffitty-cwd-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let changed = root.join("changed");
        std::fs::create_dir(&changed).unwrap();
        let options = crate::spawn::SpawnOptions {
            shell: Some("/bin/sh".into()), login: Some(false),
            cwd: Some(root.to_string_lossy().into()), ..Default::default()
        }.prepare("/bin/sh", None).unwrap();
        let session = Session::new(1, 1, "cwd-test", "/bin/sh", "private", "capability",
            "graffitty", None, Some(&options)).unwrap();
        session.input(format!("cd '{}'\n", changed.display()).into_bytes()).unwrap();
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while session.cwd().as_deref() != Some(changed.as_path()) && std::time::Instant::now() < deadline {
            thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(session.cwd().as_deref(), Some(changed.as_path()));
        std::fs::remove_dir(&changed).unwrap();
        assert_eq!(session.cwd().as_deref(), Some(root.as_path()));
        std::fs::remove_dir(&root).unwrap();
        let home = std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE"))
            .map(std::path::PathBuf::from).unwrap();
        assert!(home.is_dir());
        assert_eq!(session.cwd().as_deref(), Some(home.as_path()));
        drop(session);
    }

    #[test]
    fn scene_separates_multipart_png_assets_from_text() {
        let mut session = Session::new(
            1,
            1,
            "pixel-test",
            "/bin/sh",
            "private",
            "capability",
            "graffitty",
            None,
            None,
        )
        .unwrap();
        let (sender, receiver) = mpsc::sync_channel(4);
        let _pty_output = std::mem::replace(&mut session.output, receiver);
        let bytes = b"\x1b_Ga=T,f=100,i=9001,p=1,c=2,r=2,q=2,m=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB\x1b\\\x1b_Gm=0,q=2;CAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\";
        for split in 0..=bytes.len() {
            sender.send(b"\x1bc".to_vec()).unwrap();
            session.poll();
            sender.send(bytes[..split].to_vec()).unwrap();
            session.poll();
            if session.scene_ready() {
                let text = session.scene_checkpoint().unwrap();
                assert!(!String::from_utf8_lossy(&text).contains("\x1b_G"),
                    "Image escapes at byte {split} must not leak into scene text");
            }
            sender.send(bytes[split..].to_vec()).unwrap();
            session.poll();
            assert!(session.scene_ready());
            let text = session.scene_checkpoint().unwrap();
            assert!(!String::from_utf8_lossy(&text).contains("\x1b_G"));
            assert!(session.scene_graphics().unwrap().images.iter().any(|image| image.id == 9001));
            assert!(session.vt.kitty_graphics().unwrap().unwrap().image(9001).is_some());
            assert!(String::from_utf8_lossy(&session.checkpoint().unwrap()).contains("f=100"));
        }
    }

    #[test]
    fn owning_session_reapplies_image_policy_at_live_reset_stream_boundaries() {
        let bytes = b"\x1bc\x1b_Ga=T,f=24,s=1,v=1,c=2,r=1,i=7,q=2;/wAA\x1b\\\rRESET_READY";
        for storage in [0, 1] {
            let options = crate::spawn::SpawnOptions {
                shell: Some("/bin/sh".into()),
                login: Some(false),
                kitty_image_storage_mb: Some(storage),
                ..Default::default()
            }
            .prepare("/bin/sh", None)
            .unwrap();
            let mut session = Session::new(
                1,
                1,
                "reset-test",
                "/bin/sh",
                "private",
                "capability",
                "graffitty",
                None,
                Some(&options),
            )
            .unwrap();
            // Exercise the real owning actor's poll/parser, with deterministic
            // output packet boundaries instead of OS-dependent PTY coalescing.
            let (sender, receiver) = mpsc::sync_channel(4);
            let _pty_output = std::mem::replace(&mut session.output, receiver);
            for split in [0, 1, 2, 3, bytes.len() - 1, bytes.len()] {
                sender.send(bytes[..split].to_vec()).unwrap();
                session.poll();
                sender.send(bytes[split..].to_vec()).unwrap();
                session.poll();
                let graphics = session.vt.kitty_graphics().unwrap();
                assert_eq!(
                    graphics.as_ref().is_some_and(|graphics| graphics.image(7).is_some()),
                    storage > 0,
                    "storage {storage}, split {split}"
                );
                let mut iterator =
                    graffitty_terminal_core::vt::kitty::graphics::PlacementIterator::new().unwrap();
                let has_placement = graphics.as_ref().is_some_and(|graphics| iterator.update(graphics).unwrap().next().is_some());
                assert_eq!(has_placement, storage > 0);
                assert_eq!(
                    session.vt.kitty_image_storage_limit().unwrap().unwrap_or(0),
                    options.limits.storage_bytes()
                );
                assert_eq!(session.vt.is_kitty_image_from_file_allowed().unwrap(), Some(true));
                assert!(session.history().unwrap().contains("RESET_READY"));
            }
        }
    }
}
