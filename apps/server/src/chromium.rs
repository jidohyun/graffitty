//! A CEF host process belongs to the server, including its profile and page
//! state. The host pushes GPU frames; terminals remain VT data.
use crate::chromium_video::Source;
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
use tungstenite::Message;
#[cfg(not(windows))]
use std::process::{Child as ChromiumProcess, Stdio};
#[cfg(windows)]
use terminal_resource_monitor::windows::Process as ChromiumProcess;

#[path = "chromium_playwright.rs"]
mod playwright;
#[cfg(target_os = "macos")]
#[path = "chromium_runtime.rs"]
mod runtime;
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// Waits, when dropped, for dropped chromiums to stop their processes and
/// delete temporary sessions before the server process exits.
pub struct RuntimeCleanup;
impl Drop for RuntimeCleanup {
    fn drop(&mut self) {
        #[cfg(target_os = "macos")]
        runtime::finish_all(Duration::from_secs(5));
    }
}

/// Where a chromium keeps its browser storage.
#[derive(Clone)]
pub enum Profile {
    /// Generated inside the session directory.
    Temporary,
    /// A caller's directory, used in place and never deleted.
    Persistent(PathBuf),
    /// A temporary copy of a caller's profile; the template is never modified.
    Template(PathBuf),
}
impl Profile {
    /// An explicit request overrides the server default; an empty `profile`
    /// requests temporary storage.
    pub fn select(params: &Value, settings: &crate::settings::Chromium) -> Result<Self> {
        let path = |value: &str| (!value.is_empty()).then(|| PathBuf::from(value));
        Ok(match (params["profile"].as_str(), params["profile_template"].as_str()) {
            (Some(_), Some(_)) => return Err("Use either profile or profile_template, not both".into()),
            (Some(profile), None) => path(profile).map_or(Self::Temporary, Self::Persistent),
            (None, Some(template)) => Self::Template(path(template).ok_or("profile_template must name a directory")?),
            (None, None) => Self::configured(settings),
        })
    }
    /// The server default for chromiums created without an explicit profile.
    pub fn configured(settings: &crate::settings::Chromium) -> Self {
        let path = |value: &str| (!value.is_empty()).then(|| PathBuf::from(value));
        match (path(&settings.profile), path(&settings.profile_template)) {
            (Some(profile), _) => Self::Persistent(profile),
            (None, Some(template)) => Self::Template(template),
            (None, None) => Self::Temporary,
        }
    }
}

const PROFILE_LOCK: &str = ".graffitty-server.lock";
/// Process locks, endpoints and regenerable caches stay out of a template copy.
const TEMPLATE_SKIPPED: &[&str] = &[
    "SingletonLock", "SingletonCookie", "SingletonSocket", "lockfile", "DevToolsActivePort", PROFILE_LOCK,
    "Cache", "Code Cache", "GPUCache", "GrShaderCache", "GraphiteDawnCache", "ShaderCache",
    "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "Crashpad",
];

/// Copy a template while holding its server lock so no chromium writes it meanwhile.
fn copy_template(template: &Path, target: &Path) -> Result<()> {
    if !template.is_absolute() || !template.is_dir() {
        return Err("Chromium profile template must be an existing absolute directory".into());
    }
    if fs::symlink_metadata(template.join("SingletonLock")).is_ok() {
        return Err("Chromium profile template is in use; close it before cloning".into());
    }
    let lock = fs::OpenOptions::new().read(true).write(true).create(true).truncate(false)
        .open(template.join(PROFILE_LOCK))?;
    fs2::FileExt::try_lock_exclusive(&lock)
        .map_err(|_| "Chromium profile template is in use; close it before cloning")?;
    fn copy(source: &Path, target: &Path) -> std::io::Result<()> {
        fs::create_dir_all(target)?;
        for entry in fs::read_dir(source)? {
            let entry = entry?;
            if entry.file_name().to_str().is_some_and(|name| TEMPLATE_SKIPPED.contains(&name)) {
                continue;
            }
            // Symlinks are skipped so a template cannot pull outside files into the copy.
            let kind = entry.file_type()?;
            if kind.is_dir() {
                copy(&entry.path(), &target.join(entry.file_name()))?;
            } else if kind.is_file() {
                fs::copy(entry.path(), target.join(entry.file_name()))?;
            }
        }
        Ok(())
    }
    copy(template, target).map_err(|error| format!("Cannot copy Chromium profile template: {error}").into())
}

/// Own only a fresh UUID directory; never remove a caller's persistent profile.
struct SessionDirectory {
    path: PathBuf,
    delete_on_close: bool,
    /// Held for the session's lifetime; an unlocked directory has no owner.
    lock: Option<fs::File>,
}
const SESSION_LOCK: &str = ".graffitty-session.lock";
/// A session this new may still be acquiring its lock.
const NEW_SESSION_AGE: Duration = Duration::from_secs(60);
/// Without any lock to test, only a day-old session is assumed abandoned.
const UNLOCKED_SESSION_AGE: Duration = Duration::from_secs(24 * 60 * 60);
impl SessionDirectory {
    fn new(settings: &crate::settings::Chromium) -> Result<Self> {
        let root = settings.sessions_path()?;
        fs::create_dir_all(&root)?;
        if settings.delete_session_on_close {
            sweep_orphaned_sessions(&root);
        }
        let path = root.join(uuid::Uuid::new_v4().simple().to_string());
        let builder = fs::DirBuilder::new();
        #[cfg(unix)]
        let mut builder = builder;
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(&path)?;
        let lock = fs::OpenOptions::new().write(true).create_new(true).open(path.join(SESSION_LOCK))?;
        fs2::FileExt::try_lock_exclusive(&lock)?;
        Ok(Self { path, delete_on_close: settings.delete_session_on_close, lock: Some(lock) })
    }
}
impl Drop for SessionDirectory {
    fn drop(&mut self) {
        // Windows cannot remove the directory while its lock file is open.
        self.lock.take();
        if self.delete_on_close {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
/// A killed or crashed server cannot delete its temporary sessions. Remove
/// those whose owner no longer holds the lock, so profiles cannot accumulate.
fn sweep_orphaned_sessions(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        if !name.to_str().is_some_and(|name| name.len() == 32 && name.bytes().all(|b| b.is_ascii_hexdigit())) {
            continue;
        }
        if !entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let path = entry.path();
        let age = entry.metadata().and_then(|metadata| metadata.modified()).ok()
            .and_then(|modified| modified.elapsed().ok()).unwrap_or_default();
        if age < NEW_SESSION_AGE {
            continue;
        }
        // A running Chrome also holds its profile's lock.
        let unowned = |lock: PathBuf| fs::OpenOptions::new().write(true).open(lock)
            .ok().map(|lock| fs2::FileExt::try_lock_exclusive(&lock).is_ok());
        let orphaned = unowned(path.join(SESSION_LOCK))
            .or_else(|| unowned(path.join("cef-profile").join(PROFILE_LOCK)))
            .unwrap_or(age > UNLOCKED_SESSION_AGE);
        if orphaned {
            let _ = fs::remove_dir_all(&path);
        }
    }
}

#[cfg(test)]
mod session_storage_tests {
    use super::*;

    #[test]
    fn chromium_sessions_cleanup_only_owned_directory_and_can_be_retained() {
        // Never sweep the real default sessions directory from a test.
        let root = std::env::temp_dir().join(format!("graffitty-sessions-{}", uuid::Uuid::new_v4().simple()));
        let defaults = crate::settings::Chromium {
            sessions_directory: root.to_string_lossy().into_owned(), ..Default::default()
        };
        let parent = SessionDirectory::new(&defaults).unwrap();
        let profile = parent.path.join("persistent-profile");
        fs::create_dir(&profile).unwrap();
        fs::write(profile.join("cookies"), "keep").unwrap();
        let settings = crate::settings::Chromium {
            profile: profile.to_string_lossy().into_owned(),
            sessions_directory: parent.path.to_string_lossy().into_owned(),
            ..defaults
        };
        let session = SessionDirectory::new(&settings).unwrap();
        let removed = session.path.clone();
        fs::create_dir(removed.join("cef-profile")).unwrap();
        fs::write(removed.join("cef-profile/cookies"), "temporary").unwrap();
        drop(session);
        assert!(!removed.exists());
        assert_eq!(fs::read_to_string(profile.join("cookies")).unwrap(), "keep");

        let retained = SessionDirectory::new(&crate::settings::Chromium {
            delete_session_on_close: false, ..settings
        }).unwrap();
        let saved = retained.path.clone();
        fs::write(saved.join("diagnostics"), "retain").unwrap();
        drop(retained);
        assert_eq!(fs::read_to_string(saved.join("diagnostics")).unwrap(), "retain");
        assert_ne!(saved, removed);
        drop(parent);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn orphaned_sessions_are_swept_but_live_and_unrelated_directories_remain() {
        let root = std::env::temp_dir().join(format!("graffitty-sweep-{}", uuid::Uuid::new_v4().simple()));
        let settings = crate::settings::Chromium {
            sessions_directory: root.to_string_lossy().into_owned(), ..Default::default()
        };
        let aged = |path: &Path| {
            let old = std::time::SystemTime::now() - NEW_SESSION_AGE * 2;
            fs::File::open(path).unwrap().set_modified(old).unwrap();
        };
        let live = SessionDirectory::new(&settings).unwrap();
        aged(&live.path);
        let orphan = root.join(uuid::Uuid::new_v4().simple().to_string());
        fs::create_dir_all(orphan.join("cef-profile")).unwrap();
        fs::write(orphan.join(SESSION_LOCK), "").unwrap();
        aged(&orphan);
        // A live session of a server that predates session locks.
        let older = root.join(uuid::Uuid::new_v4().simple().to_string());
        fs::create_dir_all(older.join("cef-profile")).unwrap();
        let profile = fs::OpenOptions::new().write(true).create(true).truncate(false)
            .open(older.join("cef-profile").join(PROFILE_LOCK)).unwrap();
        fs2::FileExt::try_lock_exclusive(&profile).unwrap();
        aged(&older);
        let starting = root.join(uuid::Uuid::new_v4().simple().to_string());
        fs::create_dir(&starting).unwrap();
        let unlocked = root.join(uuid::Uuid::new_v4().simple().to_string());
        fs::create_dir(&unlocked).unwrap();
        aged(&unlocked);
        let unrelated = root.join("persistent-profile");
        fs::create_dir(&unrelated).unwrap();
        aged(&unrelated);
        let next = SessionDirectory::new(&settings).unwrap();
        assert!(!orphan.exists(), "An unlocked session has no owner");
        assert!(live.path.exists() && next.path.exists(), "Live sessions keep their lock");
        assert!(older.exists(), "A locked temporary profile keeps an older server's session");
        assert!(starting.exists(), "A new directory may still be acquiring its lock");
        assert!(unlocked.exists(), "Without a lock to test, only day-old sessions are removed");
        assert!(unrelated.exists(), "Only session directories are swept");
        drop((live, next, profile));
        fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod profile_template_tests {
    use super::*;

    #[test]
    fn explicit_requests_override_the_configured_profile_or_template() {
        let template = crate::settings::Chromium { profile_template: "/profiles/work".into(), ..Default::default() };
        let select = |params: Value, settings| Profile::select(&params, settings).unwrap();
        assert!(matches!(select(json!({}), &template), Profile::Template(p) if p == Path::new("/profiles/work")));
        assert!(matches!(select(json!({"profile":""}), &template), Profile::Temporary));
        assert!(matches!(select(json!({"profile":"/profiles/own"}), &template), Profile::Persistent(_)));
        let persistent = crate::settings::Chromium { profile: "/profiles/own".into(), ..Default::default() };
        assert!(matches!(select(json!({"profile_template":"/profiles/work"}), &persistent), Profile::Template(_)));
        assert!(matches!(select(json!({}), &crate::settings::Chromium::default()), Profile::Temporary));
        assert!(Profile::select(&json!({"profile":"/a","profile_template":"/b"}), &template).is_err());
        assert!(Profile::select(&json!({"profile_template":""}), &template).is_err());
    }

    #[test]
    fn template_copy_keeps_storage_and_skips_locks_and_caches() {
        let root = std::env::temp_dir().join(format!("graffitty-template-{}", uuid::Uuid::new_v4().simple()));
        let template = root.join("template");
        fs::create_dir_all(template.join("Default/Cache")).unwrap();
        fs::create_dir_all(template.join("Default/Local Storage/leveldb")).unwrap();
        fs::write(template.join("Local State"), "{}").unwrap();
        fs::write(template.join("Default/Cookies"), "session").unwrap();
        fs::write(template.join("Default/Local Storage/leveldb/000003.log"), "storage").unwrap();
        fs::write(template.join("Default/Cache/data_0"), "cache").unwrap();
        fs::write(template.join("DevToolsActivePort"), "9222").unwrap();
        let copy = root.join("copy");
        copy_template(&template, &copy).unwrap();
        assert_eq!(fs::read_to_string(copy.join("Default/Cookies")).unwrap(), "session");
        assert_eq!(fs::read_to_string(copy.join("Default/Local Storage/leveldb/000003.log")).unwrap(), "storage");
        assert!(copy.join("Local State").is_file());
        for skipped in ["Default/Cache", "DevToolsActivePort", PROFILE_LOCK] {
            assert!(!copy.join(skipped).exists(), "{skipped}");
        }

        let held = fs::OpenOptions::new().write(true).open(template.join(PROFILE_LOCK)).unwrap();
        fs2::FileExt::try_lock_exclusive(&held).unwrap();
        assert!(copy_template(&template, &root.join("locked")).is_err());
        drop(held);
        assert!(copy_template(&root.join("missing"), &root.join("missing-copy")).is_err());
        assert!(copy_template(Path::new("relative"), &root.join("relative-copy")).is_err());
        fs::remove_dir_all(root).unwrap();
    }
}

/// Liveness probe interval, and how long an unanswered probe means a stuck
/// page. Pages legitimately block for seconds (parsing, WASM start-up);
/// Chrome itself waits 15 s before calling one unresponsive.
///
/// Eight seconds still catches a page that never yields without flagging
/// ordinary heavy work.
const PAGE_HEARTBEAT: Duration = Duration::from_secs(2);
const UNRESPONSIVE_PAGE: Duration = Duration::from_secs(8);
const MIN_RENDER_SCALE: f64 = 0.125;

/// Chromium renders at the largest client's displayed size while its CSS
/// layout stays width x height.
///
/// Rendering never exceeds CSS resolution: the browser window would then be
/// larger than its page, which window.outerWidth exposes and some sites treat
/// as an open developer-tools panel.
///
/// Near 1:1 stays exact for crisp text; the view keeps at least 64 pixels.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn render_scale(width: u32, height: u32, demand: Option<u32>) -> f64 {
    let Some(demand) = demand else { return 1.0 };
    let scale = f64::from(demand) / f64::from(height.max(1));
    if scale >= 0.85 {
        return 1.0;
    }
    let smallest = 64.0 / f64::from(width.min(height).max(1));
    let scale = scale.max(MIN_RENDER_SCALE).max(smallest).min(1.0);
    (scale * 1000.0).round() / 1000.0
}

#[cfg(test)]
mod render_scale_tests {
    use super::render_scale;

    #[test]
    fn displayed_height_sets_resolution_without_unknown_or_extreme_views() {
        assert_eq!(render_scale(1280, 800, None), 1.0, "Unknown displays keep CSS resolution");
        assert_eq!(render_scale(1280, 800, Some(720)), 1.0, "Nearby tiers stay exact");
        assert_eq!(render_scale(1280, 800, Some(360)), 0.45);
        assert_eq!(render_scale(1280, 800, Some(144)), 0.18);
        assert_eq!(render_scale(1280, 2000, Some(144)), 0.125, "Tiny panes keep a legible floor");
        assert_eq!(render_scale(1280, 800, Some(2160)), 1.0, "Magnified panes render at CSS resolution");
        assert_eq!(render_scale(64, 4096, Some(144)), 1.0, "Views keep at least 64 pixels");
    }
}

fn command_error(error: &Box<dyn std::error::Error>) -> Value {
    if let Some(error) = error.downcast_ref::<crate::DispatchError>() {
        return error.0.clone();
    }
    json!({"code":error.downcast_ref::<playwright::AttachError>().map_or("chromium_error", |e| e.0),
        "message":error.to_string()})
}

fn evaluated_value(value: Value) -> Result<Value> {
    if let Some(error) = value.get("error") {
        if error["code"].is_string() && error["message"].is_string() {
            return Err(Box::new(crate::DispatchError(error.clone())));
        }
        return Err(error.to_string().into());
    }
    Ok(value)
}
pub struct Chromium {
    pub video: crate::chromium_video::Pipeline,
    pub id: u64,
    // RPC controller; equals id for an independent, detached chromium.
    pub owner: u64,
    pub session_id: u64,
    pub main_window: bool,
    #[cfg(target_os = "macos")]
    runtime: Arc<runtime::Runtime>,
    pub workspace: String,
    pub tab: u64,
    pub state: Value,
    pub pinned_title: String,
    pub revision: u64,
    pub results: HashMap<u64, Value>,
    tx: mpsc::SyncSender<(u64, String, Value)>,
    rx: mpsc::Receiver<Update>,
    input: mpsc::SyncSender<Value>,
    latest_frame: Arc<Mutex<Option<Source>>>,
    capture: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
    /// Last displayed height delivered to the worker; None means unknown.
    render_demand: Option<Option<u32>>,
    /// How a main window was created; a stopped one is relaunched from it.
    restart_profile: Option<Profile>,
    /// Tab URLs of the last running state, selected tab first.
    last_urls: Vec<String>,
}
enum Update {
    State(Value),
    Result(u64, Value),
}
impl Chromium {
    pub fn new(
        id: u64,
        owner: u64,
        workspace: String,
        tab: u64,
        url: String,
        profile: Profile,
        settings: &crate::settings::Chromium,
        resources: Arc<terminal_resource_monitor::Service>,
    ) -> Result<Self> {
        let executable = crate::chromium_capture::executable()?;
        let session_directory = SessionDirectory::new(settings)?;
        let restart_profile = profile.clone();
        let (directory, template) = match profile {
            Profile::Persistent(path) => (path, None),
            Profile::Temporary => (session_directory.path.join("cef-profile"), None),
            Profile::Template(path) => (session_directory.path.join("cef-profile"), Some(path)),
        };
        let temporary = directory.starts_with(&session_directory.path);
        fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if temporary {
                fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
            }
        }
        if let Some(template) = template {
            copy_template(&template, &directory)?;
        }
        if fs::symlink_metadata(directory.join("SingletonLock")).is_ok() {
            return Err("Chromium profile is already in use".into());
        }
        let profile_lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join(PROFILE_LOCK))?;
        fs2::FileExt::try_lock_exclusive(&profile_lock)
            .map_err(|_| "Chromium profile is already owned by another server")?;
        let _ = fs::remove_file(directory.join("DevToolsActivePort"));
        let gpu_capture = crate::chromium_capture::Capture::new(&session_directory.path)?;
        let mut command = Command::new(executable);
        command
            .arg("--backend")
            .arg(settings.backend.name())
            .arg("--artifacts")
            .arg(&gpu_capture.artifacts)
            .arg("--profile")
            .arg(&directory)
            .arg("--server-control")
            .arg(&gpu_capture.control)
            .arg("--url")
            .arg(&url);
        command.arg("--gpu-endpoint").arg(&gpu_capture.endpoint);
        #[cfg(not(target_os = "macos"))]
        command.arg("--server-pid").arg(std::process::id().to_string());
        #[cfg(target_os = "linux")]
        let resource_boundary = match terminal_resource_monitor::linux::Boundary::prepare() {
            Ok(boundary) => {
                boundary.configure_command(&mut command)?;
                Some(boundary)
            }
            Err(error) => {
                eprintln!("Chromium {id} resource monitoring unavailable: {error}");
                None
            }
        };
        #[cfg(windows)]
        let child = ChromiumProcess::spawn_detached(command.get_program(), command.get_args())?;
        #[cfg(not(windows))]
        let child = command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        #[cfg(not(target_os = "macos"))]
        let mut child = child;
        #[cfg(not(target_os = "macos"))]
        let chromium_pid = child.id();
        #[cfg(target_os = "macos")]
        {
            let mut gpu_capture = gpu_capture;
            gpu_capture.keep_control_directory = true;
            let runtime = runtime::Runtime::new(child, gpu_capture.listener.try_clone()?, directory, temporary, profile_lock, gpu_capture.control_directory.clone(), session_directory);
            let mut chromium = Self::window(id, owner, workspace, tab, id, runtime, gpu_capture, None, resources)?;
            chromium.restart_profile = Some(restart_profile);
            return Ok(chromium);
        }
        #[cfg(not(target_os = "macos"))]
        {
        let resource_monitor = crate::resources::ChromiumMonitor::new(resources, id, chromium_pid);
        let (tx, commands) = mpsc::sync_channel::<(u64, String, Value)>(128);
        let (updates, rx) = mpsc::sync_channel(256);
        let (input, inputs) = mpsc::sync_channel(512);
        let latest_frame = Arc::new(Mutex::new(None));
        let frame_sink = latest_frame.clone();
        let capture = Arc::new(AtomicBool::new(false));
        let capturing = capture.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = stop.clone();
        // Creation replies have always exposed profile ownership immediately;
        // page discovery remains asynchronous and updates this same state later.
        let initial_state = json!({"tabs":[],"chromiumId":-1,"pid":chromium_pid,
            "profile":directory.to_string_lossy(),"temporaryProfile":temporary,"nativeVisible":false,
            "runtimeDirectory":session_directory.path.to_string_lossy()});
        let worker = thread::spawn(move || {
            let _profile_lock = profile_lock;
            let run = (|| -> Result<()> {
                let socket = Transport::Native(gpu_capture.accept(&mut child)?);
                let mut cdp = Cdp {
                    resources: resource_monitor,
                    playwright: playwright::Broker::default(),
                    trace_cdp: std::env::var("RUST_LOG").is_ok_and(|v| v.contains("graffitty_cdp")),
                    chromium_id: id,
                    window_id: None,
                    session_id: id,
                    chromium_pid,
                    profile: directory.to_string_lossy().into_owned(),
                    temporary_profile: temporary,
                    runtime_directory: session_directory.path.to_string_lossy().into_owned(),
                    socket,
                    sequence: 0,
                    targets: vec![],
                    selected: 0,
                    session: String::new(),
                    width: 1000,
                    height: 700,
                    render_demand: None,
                    render_scale: 1.0,
                    inputs,
                    latest_frame: frame_sink,
                    streaming: false,
                    #[cfg(any(windows, target_os = "linux"))]
                    screencast_size: None,
                    context_menu: Value::Null,
                    find_result: Value::Null,
                    finding: false,
                    context_dirty: false,
                    tab_ids: HashMap::new(),
                    next_tab_id: 1,
                    page_crashed: false,
                    heartbeat: None,
                    heartbeat_at: Instant::now(),
                    page_unresponsive: false,
                    capture: Some(gpu_capture),
                };
                let mut last_state = Value::Null;
                let mut last_state_check = Instant::now() - Duration::from_secs(1);
                while !stopping.load(Ordering::Relaxed) {
                    cdp.resources.expire_idle();
                    cdp.flush_input()?;
                    for _ in 0..4 {
                        match commands.try_recv() {
                            Ok((ticket, action, args)) => {
                                let result = match cdp.command(&action, &args) {
                                    Ok(value) => json!({"result":value}),
                                    Err(e) => {
                                        json!({"error":command_error(&e)})
                                    }
                                };
                                if ticket != 0
                                    && updates.send(Update::Result(ticket, result)).is_err()
                                {
                                    return Ok(());
                                }
                            }
                            Err(_) => break,
                        }
                    }
                    if cdp.context_dirty || last_state_check.elapsed() > Duration::from_millis(250)
                    {
                        let state = cdp.state()?;
                        if state != last_state {
                            last_state = state.clone();
                            if updates.send(Update::State(state)).is_err() {
                                return Ok(());
                            }
                        }
                        last_state_check = Instant::now();
                    }
                    cdp.heartbeat()?;
                    cdp.set_streaming(capturing.load(Ordering::Relaxed))?;
                    cdp.receive()?;
                }
                let _ = cdp.call("Browser.close", json!({}), false);
                Ok(())
            })();
            if let Err(error) = run {
                eprintln!("Chromium {id} worker stopped: {error}");
                let _ = updates.try_send(Update::State(
                    json!({"error":error.to_string(),"tabs":[],"chromiumId":-1}),
                ));
            }
            // The CDP/socket shutdown above asks Chromium to close. Give its
            // profile database and singleton lock time to shut down before
            // killing an unresponsive process.
            //
            // Immediate kill leaves saved profiles locked and can discard
            // their last storage writes.
            finish_chromium(&mut child, Duration::from_secs(2));
            #[cfg(target_os = "linux")]
            drop(resource_boundary);
            drop(_profile_lock);
            drop(session_directory);
        });
        Ok(Self {
            video: crate::chromium_video::Pipeline::new(),
            id,
            owner,
            session_id: id,
            main_window: true,
            workspace,
            tab,
            state: initial_state,
            pinned_title: String::new(),
            revision: 0,
            results: HashMap::new(),
            tx,
            rx,
            input,
            latest_frame,
            capture,
            stop,
            worker: Some(worker),
            render_demand: None,
            restart_profile: Some(restart_profile),
            // Until its first tab list, it has the page it opened with.
            last_urls: vec![url],
        })
    }
    }
    #[cfg(target_os = "macos")]
    pub fn sibling(&self, id: u64, window: i64, resources: Arc<terminal_resource_monitor::Service>) -> Result<Self> {
        let capture = crate::chromium_capture::Capture::new(&self.runtime.directory)?;
        Self::window(id, self.id, self.workspace.clone(), self.tab, self.session_id,
            self.runtime.clone(), capture, Some(window), resources)
    }
    #[cfg(target_os = "macos")]
    fn window(id:u64, owner:u64, workspace:String, tab:u64, session_id:u64,
        runtime:Arc<runtime::Runtime>, capture_receiver:crate::chromium_capture::Capture,
        window_id:Option<i64>, resources:Arc<terminal_resource_monitor::Service>) -> Result<Self> {
        let (tx, commands) = mpsc::sync_channel::<(u64,String,Value)>(128);
        let (updates,rx) = mpsc::sync_channel(256);
        let (input,inputs) = mpsc::sync_channel(512);
        let latest_frame = Arc::new(Mutex::new(None));
        let capture = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let mut cdp = Cdp {
            resources:crate::resources::ChromiumMonitor::new(resources,id,runtime.pid),
            playwright:playwright::Broker::default(),
            trace_cdp:std::env::var("RUST_LOG").is_ok_and(|v|v.contains("graffitty_cdp")),
            chromium_id:id, session_id, window_id, chromium_pid:runtime.pid,
            profile:runtime.profile.to_string_lossy().into_owned(), temporary_profile:runtime.temporary,
            runtime_directory:runtime.directory.to_string_lossy().into_owned(),
            socket:Transport::Shared(runtime.connect()?), sequence:0,targets:vec![],selected:0,
            session:String::new(),width:1000,height:700,render_demand:None,render_scale:1.0,inputs,latest_frame:latest_frame.clone(),
            streaming:false,context_menu:Value::Null,find_result:Value::Null,finding:false,context_dirty:false,tab_ids:HashMap::new(),next_tab_id:1,page_crashed:false,heartbeat:None,heartbeat_at:Instant::now(),page_unresponsive:false,capture:Some(capture_receiver),
        };
        let main_window=window_id.is_none();
        let state = json!({"tabs":[],"chromiumId":-1,"pid":runtime.pid,"sessionId":session_id,"mainWindow":main_window,
            "windowId":window_id,"profile":cdp.profile,"temporaryProfile":runtime.temporary,"nativeVisible":false});
        let stopping = stop.clone();
        let capturing = capture.clone();
        let worker = thread::spawn(move || {
            let mut run = || -> Result<()> {
                let Transport::Shared(peer) = &cdp.socket;
                peer.wait_ready()?;
                let ready_deadline = Instant::now() + Duration::from_secs(30);
                loop {
                    let state = cdp.state()?;
                    updates.send(Update::State(state.clone()))?;
                    if !cdp.targets.is_empty() || state["closed"] == true { break; }
                    if stopping.load(Ordering::Relaxed) { return Ok(()); }
                    if Instant::now() > ready_deadline { return Err("Chromium window did not become ready".into()); }
                    thread::sleep(Duration::from_millis(25));
                }
                let mut last_state = Value::Null;
                let mut checked = Instant::now() - Duration::from_secs(1);
                while !stopping.load(Ordering::Relaxed) {
                    cdp.resources.expire_idle();
                    cdp.flush_input()?;
                    for (ticket,action,args) in commands.try_iter().take(4) {
                        let result = match cdp.command(&action,&args) {
                            Ok(value)=>json!({"result":value}), Err(error)=>json!({"error":command_error(&error)}),
                        };
                        if ticket != 0 { updates.send(Update::Result(ticket,result))?; }
                    }
                    if cdp.context_dirty || checked.elapsed()>Duration::from_millis(250) {
                        let state=cdp.state()?;
                        if state!=last_state { last_state=state.clone();updates.send(Update::State(state))?; }
                        checked=Instant::now();
                    }
                    cdp.heartbeat()?;
                    cdp.sync_render_scale()?;
                    cdp.set_streaming(capturing.load(Ordering::Relaxed))?;
                    cdp.receive()?;
                }
                if cdp.window_id.is_some() { let _=cdp.call("Graffitty.closeWindow",json!({}),false); }
                Ok(())
            };
            if let Err(error)=run() {
                eprintln!("Chromium window {id} stopped: {error}");
                // Frontends show this to the user: drop the transport's "IO error:" wrapper.
                let reason = match error.downcast_ref::<tungstenite::Error>() {
                    Some(tungstenite::Error::Io(io)) => io.to_string(),
                    _ => error.to_string(),
                };
                let _=updates.try_send(Update::State(json!({"error":reason,"tabs":[],"chromiumId":-1,"sessionId":session_id,"windowId":cdp.window_id})));
            }
        });
        Ok(Self{video:crate::chromium_video::Pipeline::new(),id,owner,session_id,main_window,runtime,workspace,tab,state,
            pinned_title:String::new(),revision:0,results:HashMap::new(),tx,rx,input,latest_frame,capture,stop,worker:Some(worker),render_demand:None,restart_profile:None,last_urls:Vec::new()})
    }
    pub fn command(&self, ticket: u64, action: String, args: Value) -> Result<()> {
        self.tx
            .try_send((ticket, action, args))
            .map_err(|_| "Chromium command queue unavailable".into())
    }
    pub fn input(&self, value: Value) -> Result<()> {
        if !value["params"].is_object() || value.to_string().len() > 64 * 1024 {
            return Err("Invalid or oversized chromium input event".into());
        }
        let method = value["method"].as_str().ok_or("Missing input method")?;
        if !matches!(
            method,
            "Input.dispatchMouseEvent" | "Input.dispatchKeyEvent" | "Input.insertText"
        ) {
            return Err("Unsupported chromium input method".into());
        }
        self.input
            .try_send(value)
            .map_err(|_| "Chromium input queue full".into())
    }
    pub fn capture(&self, enabled: bool) {
        self.capture.store(enabled, Ordering::Relaxed);
    }
    /// Report the largest physical height at which clients display this
    /// pane. A full command queue retries on the next server tick.
    pub fn render_demand(&mut self, height: Option<u32>) {
        if self.render_demand != Some(height)
            && self.tx.try_send((0, "render-demand".into(), json!({"height": height}))).is_ok()
        {
            self.render_demand = Some(height);
        }
    }
    pub fn poll(&mut self) {
        if let Some(bytes) = self.latest_frame.lock().unwrap().take() {
            self.revision += 1;
            // Captured frames are the input to every rendition: a stalled page
            // and a stalled stream look identical to a client without this.
            if std::env::var("RUST_LOG").is_ok_and(|v| v.contains("graffitty_video")) {
                eprintln!("Chromium {} capture revision {}", self.id, self.revision);
            }
            self.video.source(self.revision, bytes);
        }
        while let Ok(update) = self.rx.try_recv() {
            match update {
                Update::State(mut state) => {
                    state["mainWindow"]=json!(self.main_window);
                    if state["error"].as_str().is_some_and(|error| !error.is_empty()) {
                        // The browser stopped unexpectedly: its frontends alert
                        // the user and can relaunch it with the pages it had open.
                        state["crashed"] = json!(true);
                        state["restartable"] = json!(self.restart_profile.is_some());
                        state["lastUrls"] = json!(self.last_urls);
                    } else if let Some(tabs) = state["tabs"].as_array().filter(|tabs| !tabs.is_empty()) {
                        let url = |tab: &Value| tab["url"].as_str().map(str::to_owned);
                        self.last_urls = tabs.iter().filter(|tab| tab["selected"] == true).filter_map(url)
                            .chain(tabs.iter().filter(|tab| tab["selected"] != true).filter_map(url))
                            .collect();
                    }
                    self.state = state;
                },
                Update::Result(id, value) => {
                    if id == 0 {
                        if value.get("error").is_some() { eprintln!("Chromium {}: {value}", self.id); }
                        continue;
                    }
                    if self.results.len() >= 256
                        && let Some(first) = self.results.keys().min().copied()
                    {
                        self.results.remove(&first);
                    }
                    self.results.insert(id, value);
                }
            }
        }
    }
    /// Save the data needed to reopen a browser session:
    ///
    /// - Reopenable pages, with the selected page first.
    /// - The pinned title.
    /// - Profile fields for `chromium.create`.
    ///
    /// Restored pages start fresh. A detached window uses a copy of the
    /// session profile because only one window can lock it.
    pub fn snapshot(&self) -> Value {
        let tabs = self.state["tabs"].as_array().filter(|tabs| !tabs.is_empty());
        let mut urls: Vec<String> = match tabs {
            Some(tabs) => {
                let url = |tab: &Value| tab["url"].as_str().map(str::to_owned);
                tabs.iter().filter(|tab| tab["selected"] == true).filter_map(url)
                    .chain(tabs.iter().filter(|tab| tab["selected"] != true).filter_map(url))
                    .collect()
            }
            None => self.last_urls.clone(),
        };
        urls.retain(|url| graffitty_workspace_core::checkpoint::chromium_page(url));
        urls.truncate(32);
        if urls.is_empty() {
            urls.push("about:blank".into());
        }
        let mut entry = json!({"id": self.id, "urls": urls, "title": self.pinned_title});
        match &self.restart_profile {
            Some(Profile::Persistent(path)) => entry["profile"] = json!(path),
            Some(Profile::Template(path)) => entry["profile_template"] = json!(path),
            Some(Profile::Temporary) => entry["profile"] = json!(""),
            None if self.state["temporaryProfile"] == false && self.state["profile"].as_str().is_some_and(|p| !p.is_empty()) => {
                entry["profile_template"] = self.state["profile"].clone();
            }
            None => entry["profile"] = json!(""),
        }
        entry
    }
    /// Relaunch a stopped main window in place from its profile and last pages.
    /// The replacement keeps this id, so frontends recover the same pane.
    pub fn restart(&self, settings: &crate::settings::Chromium,
        resources: Arc<terminal_resource_monitor::Service>) -> Result<Self> {
        if !self.state["error"].as_str().is_some_and(|error| !error.is_empty()) {
            // Typed: when two viewers press Restart, the second one finds the
            // browser already relaunched, which is not a failure to report.
            return Err(crate::api::error("chromium_running", "Chromium is running; only a stopped chromium can be restarted"));
        }
        let profile = self.restart_profile.clone()
            .ok_or("Restart the session's main Chromium window to reopen this window")?;
        let restorable = |url: &&String| url.starts_with("http://") || url.starts_with("https://") || url.as_str() == "about:blank";
        let mut urls = self.last_urls.iter().filter(restorable).take(32);
        let first = urls.next().cloned().unwrap_or_else(|| "about:blank".into());
        let chromium = Self::new(self.id, self.owner, self.workspace.clone(), self.tab, first, profile, settings, resources)?;
        // Queued until the replacement is ready. A new tab becomes the
        // selected one, so select the restored first page again afterwards.
        let mut reopened = false;
        for url in urls {
            chromium.command(0, "tab-new".into(), json!({"url": url}))?;
            reopened = true;
        }
        if reopened {
            chromium.command(0, "tab-select".into(), json!({"chromium_id": 1}))?;
        }
        Ok(chromium)
    }
    #[cfg(target_os = "macos")]
    pub fn window_is_closing(&self, window: i64) -> bool {
        self.runtime.closing.lock().unwrap().contains(&window)
    }
    pub fn stop(&self) {
        #[cfg(target_os = "macos")]
        if let Some(window)=self.state["windowId"].as_i64() {
            self.runtime.closing.lock().unwrap().insert(window);
        }
        self.stop.store(true, Ordering::Relaxed);
    }
    pub fn finished(&self) -> bool {
        self.worker.as_ref().is_none_or(|w| w.is_finished())
    }
    pub fn title(&self) -> String {
        if !self.pinned_title.is_empty() {
            return self.pinned_title.clone();
        }
        self.automatic_title()
    }
    pub fn automatic_title(&self) -> String {
        self.state["tabs"]
            .as_array()
            .and_then(|a| a.iter().find(|t| t["selected"] == true))
            .and_then(|t| t["title"].as_str())
            .unwrap_or("Chromium")
            .into()
    }
}
fn finish_chromium(child: &mut ChromiumProcess, grace: Duration) {
    let deadline = Instant::now() + grace;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(10));
            }
            _ => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(all(test, unix))]
mod shutdown_tests {
    use super::*;

    #[test]
    fn chromium_shutdown_allows_cleanup_and_reaps_unresponsive_children() {
        let mut graceful = Command::new("/bin/sh")
            .args(["-c", "sleep 0.05; exit 23"])
            .spawn()
            .unwrap();
        finish_chromium(&mut graceful, Duration::from_secs(2));
        assert_eq!(graceful.wait().unwrap().code(), Some(23));

        let mut unresponsive = Command::new("/bin/sh")
            .args(["-c", "exec sleep 60"])
            .spawn()
            .unwrap();
        finish_chromium(&mut unresponsive, Duration::from_millis(20));
        assert!(!unresponsive.wait().unwrap().success());
    }
}
impl Drop for Chromium {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            while !worker.is_finished() {
                while self.rx.try_recv().is_ok() {}
                thread::sleep(Duration::from_millis(8));
            }
            let _ = worker.join();
        }
    }
}
enum Transport {
    #[cfg(target_os = "macos")]
    Shared(runtime::Peer),
    #[cfg(not(target_os = "macos"))]
    Native(crate::chromium_capture::Control),
}
impl Transport {
    fn send(&mut self, message: Message) -> std::result::Result<(), tungstenite::Error> {
        match self {
            #[cfg(target_os = "macos")]
            Self::Shared(s) => s.send(message),
            #[cfg(not(target_os = "macos"))]
            Self::Native(s) => s.send(message),
        }
    }
    fn read(&mut self) -> std::result::Result<Message, tungstenite::Error> {
        match self {
            #[cfg(target_os = "macos")]
            Self::Shared(s) => s.read(),
            #[cfg(not(target_os = "macos"))]
            Self::Native(s) => s.read(),
        }
    }
}
struct Cdp {
    playwright: playwright::Broker,
    trace_cdp: bool,
    chromium_id: u64,
    window_id: Option<i64>,
    session_id: u64,
    chromium_pid: u32,
    profile: String,
    temporary_profile: bool,
    runtime_directory: String,
    resources: crate::resources::ChromiumMonitor,
    socket: Transport,
    capture: Option<crate::chromium_capture::Capture>,
    sequence: u64,
    targets: Vec<String>,
    selected: usize,
    session: String,
    width: u32,
    height: u32,
    /// Largest physical height at which clients display this page.
    render_demand: Option<u32>,
    /// Applied render scale; CSS layout stays width x height.
    render_scale: f64,
    inputs: mpsc::Receiver<Value>,
    latest_frame: Arc<Mutex<Option<Source>>>,
    streaming: bool,
    #[cfg(any(windows, target_os = "linux"))]
    screencast_size: Option<(u32, u32)>,
    context_menu: Value,
    /// Latest find-in-page result for the selected page; cleared when the
    /// selection changes, because Chromium's find state is per page.
    find_result: Value,
    finding: bool,
    context_dirty: bool,
    /// Stable ids for this window's pages. A position changes when a tab
    /// moves, so frontends could not follow a dragged tab or the primary page.
    tab_ids: HashMap<String, u64>,
    next_tab_id: u64,
    /// The attached page's renderer died; its last frame stays until a reload.
    page_crashed: bool,
    /// Outstanding liveness probe, and whether the page stopped answering it.
    heartbeat: Option<(u64, Instant)>,
    heartbeat_at: Instant,
    page_unresponsive: bool,
}
impl Cdp {
    fn send(&mut self, method: &str, mut params: Value, session: Option<String>) -> Result<u64> {
        #[cfg(target_os = "macos")]
        if method.starts_with("Graffitty.") || method.starts_with("Input.") {
            params["windowId"] = json!(self.window_id);
        }
        self.sequence += 1;
        let id = self.sequence;
        let mut message = json!({"id":id,"method":method,"params":params});
        if let Some(session) = session {
            message["sessionId"] = json!(session);
        }
        if self.trace_cdp {
            eprintln!(
                "CDP owner send {} {} session={}",
                id, method, message["sessionId"]
            );
        }
        self.socket
            .send(Message::Text(message.to_string().into()))?;
        Ok(id)
    }
    // Input never waits for an automation command or a frame acknowledgement.
    fn flush_input(&mut self) -> Result<()> {
        if self.session.is_empty() {
            return Ok(());
        }
        for _ in 0..128 {
            let Ok(input) = self.inputs.try_recv() else {
                break;
            };
            self.send(
                input["method"].as_str().unwrap(),
                input["params"].clone(),
                Some(self.session.clone()),
            )?;
        }
        Ok(())
    }
    fn service_playwright(&mut self) -> Result<()> {
        for command in self.playwright.poll() {
            self.sequence += 1;
            let id = self.sequence;
            if command.borrowed {
                self.playwright.sent(id, &command.message);
            }
            let mut message = command.message;
            message["id"] = json!(id);
            if self.trace_cdp {
                eprintln!(
                    "CDP borrowed={} send {} {} session={}",
                    command.borrowed, id, message["method"], message["sessionId"]
                );
                if message["method"] == "Page.captureScreenshot" {
                    eprintln!("CDP screenshot options {}", message["params"]);
                }
            }
            self.socket
                .send(Message::Text(message.to_string().into()))?;
        }
        Ok(())
    }
    fn receive(&mut self) -> Result<Option<Value>> {
        self.service_playwright()?;
        self.flush_input()?;
        if let Some(capture) = &mut self.capture {
            if let Some(surface) = capture.receiver.receive() {
                if self.streaming {
                    *self.latest_frame.lock().unwrap() = Some(Source::Surface(Arc::new(surface)));
                }
            }
        }
        let message = match self.socket.read() {
            Ok(message) => message,
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return Ok(None);
            }
            Err(error) => return Err(error.into()),
        };
        if let Message::Text(text) = message {
            let value: Value = serde_json::from_str(&text)?;
            if self.trace_cdp {
                eprintln!(
                    "CDP receive id={} method={} session={} error={}",
                    value["id"], value["method"], value["sessionId"], value["error"]
                );
            }
            if self.playwright.receive(&value) {
                return Ok(None);
            }
            if self.heartbeat.is_some_and(|(id, _)| value["id"] == id) {
                self.heartbeat = None;
                // A teardown error answers the probe without the page running
                // again; only a real answer means it is back.
                if self.page_unresponsive && value.get("error").is_none() {
                    self.page_unresponsive = false;
                    self.context_dirty = true;
                }
            }
            if value["method"] == "Graffitty.stateChanged" {
                self.context_dirty = true;
            }
            // A renderer crash leaves the capture on the page's last frame;
            // only a reload replaces the renderer.
            if value["sessionId"].as_str() == Some(self.session.as_str()) {
                match value["method"].as_str() {
                    // A crashed page is reported as crashed, not as a page
                    // that never answered the probe it can no longer answer.
                    Some("Inspector.targetCrashed") => {
                        (self.page_crashed, self.context_dirty) = (true, true);
                        (self.heartbeat, self.page_unresponsive) = (None, false);
                    }
                    Some("Inspector.targetReloadedAfterCrash") => {
                        (self.page_crashed, self.context_dirty) = (false, true);
                        (self.heartbeat, self.page_unresponsive) = (None, false);
                    }
                    _ => {}
                }
            }
            if value["method"] == "Graffitty.contextMenu" && value["params"]["windowId"]==json!(self.window_id) {
                self.context_menu = value["params"].clone();
                self.context_dirty = true;
            }
            // Chromium can still report a stopped search; it is not shown again.
            if value["method"] == "Graffitty.findResult" && self.finding && value["params"]["windowId"]==json!(self.window_id) {
                let params = &value["params"];
                self.find_result = json!({"identifier":params["identifier"],"count":params["count"],"active":params["active"],"final":params["final"]});
                self.context_dirty = true;
            }
            if value["method"] == "Page.screencastFrame" {
                let session = value["sessionId"].as_str().unwrap_or("").to_owned();
                #[cfg(any(windows, target_os = "linux"))]
                let accepting = self.screencast_size.is_some();
                #[cfg(not(any(windows, target_os = "linux")))]
                let accepting = true;
                if accepting && session == self.session && self.streaming {
                    if let Some(data) = value["params"]["data"].as_str() {
                        if data.len() <= 6 * 1024 * 1024 {
                            let bytes = STANDARD.decode(data)?;
                            // Keep only the newest frame if the client/network is slower.
                            *self.latest_frame.lock().unwrap() =
                                Some(Source::Image(Arc::new(bytes)));
                        }
                    }
                }
                self.send(
                    "Page.screencastFrameAck",
                    json!({"sessionId":value["params"]["sessionId"]}),
                    Some(session),
                )?;
            }
            return Ok(Some(value));
        }
        Ok(None)
    }
    fn call(&mut self, method: &str, params: Value, page: bool) -> Result<Value> {
        let id = self.send(method, params, page.then(|| self.session.clone()))?;
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            if let Some(value) = self.receive()? {
                if value["id"] == id {
                    if value.get("error").is_some() {
                        return Err(value["error"].to_string().into());
                    }
                    return Ok(value["result"].clone());
                }
            }
            if Instant::now() >= deadline {
                return Err(format!("Chromium command timed out: {method}").into());
            }
        }
    }
    /// A page stuck in script keeps its renderer, paints nothing and answers
    /// nothing, which is indistinguishable from a still page until something
    /// asks it a question.
    ///
    /// Ask a trivial one; Chromium's own hang monitor watches native input
    /// this hidden window never receives.
    fn heartbeat(&mut self) -> Result<()> {
        if self.session.is_empty() || self.page_crashed || self.playwright.is_active() {
            self.heartbeat = None;
            self.page_unresponsive = false;
            return Ok(());
        }
        match self.heartbeat {
            Some((_, sent)) => {
                if sent.elapsed() > UNRESPONSIVE_PAGE && !self.page_unresponsive {
                    self.page_unresponsive = true;
                    self.context_dirty = true;
                }
            }
            None if self.heartbeat_at.elapsed() > PAGE_HEARTBEAT => {
                let id = self.send("Runtime.evaluate", json!({"expression":"0","returnByValue":true}),
                    Some(self.session.clone()))?;
                self.heartbeat = Some((id, Instant::now()));
                self.heartbeat_at = Instant::now();
            }
            None => {}
        }
        Ok(())
    }
    /// Leased automation keeps exact CSS-pixel screenshots and coordinates.
    #[cfg(target_os = "macos")]
    fn render_target(&self) -> f64 {
        if self.playwright.is_active() { 1.0 } else { render_scale(self.width, self.height, self.render_demand) }
    }
    fn resize_params(&self) -> Value {
        json!({"width":self.width,"height":self.height,"scale":self.render_scale})
    }
    fn sync_render_scale(&mut self) -> Result<()> {
        #[cfg(target_os = "macos")]
        {
            let scale = self.render_target();
            if scale != self.render_scale {
                self.render_scale = scale;
                self.call("Graffitty.resize", self.resize_params(), false)?;
            }
        }
        Ok(())
    }
    fn set_streaming(&mut self, enabled: bool) -> Result<()> {
        // Keep the compositor live while CDP borrows a page in a hidden tab.
        // Screenshots need a frame even when the frontend has stopped subscribing.
        //
        // Release the lease to return to frontend subscription demand.
        let enabled = enabled || self.playwright.is_active();
        if self.session.is_empty() || enabled == self.streaming {
            return Ok(());
        }
        let _capture = self.call("Graffitty.capture", json!({"enabled":enabled}), false)?;
        self.streaming = enabled;
        #[cfg(any(windows, target_os = "linux"))]
        self.sync_screencast(_capture["softwareScreencast"] == true && _capture["nativeVisible"] != true)?;
        Ok(())
    }
    #[cfg(any(windows, target_os = "linux"))]
    fn sync_screencast(&mut self, embedded_software: bool) -> Result<()> {
        // Bound even high-entropy PNGs to the control channel's frame budget.
        // Every repaint matters: sampling every Nth update can miss a static page.
        if self.session.is_empty() {
            // Chromium already destroyed the old target and its screencast.
            self.screencast_size = None;
            return Ok(());
        }
        let wanted = (self.streaming && embedded_software)
            .then_some((self.width.min(1280), self.height.min(900)));
        if wanted == self.screencast_size { return Ok(()); }
        if self.screencast_size.is_some() {
            self.page("Page.stopScreencast", json!({}))?;
            self.screencast_size = None;
        }
        if let Some((width, height)) = wanted {
            // receive() may see the first static frame while waiting for the reply.
            self.screencast_size = wanted;
            if let Err(error) = self.page("Page.startScreencast", json!({"format":"png",
                "maxWidth":width,"maxHeight":height,"everyNthFrame":1})) {
                self.screencast_size = None;
                return Err(error);
            }
        }
        Ok(())
    }
    fn tab_id(&mut self, target: &str) -> u64 {
        if let Some(&id) = self.tab_ids.get(target) {
            return id;
        }
        let id = self.next_tab_id;
        self.next_tab_id += 1;
        self.tab_ids.insert(target.to_owned(), id);
        id
    }
    fn tab_index(&self, args: &Value) -> Result<usize> {
        let id = args["chromium_id"].as_u64().ok_or("Expected chromium_id")?;
        self.targets.iter().position(|target| self.tab_ids.get(target) == Some(&id))
            .ok_or_else(|| "Unknown page".into())
    }
    fn page(&mut self, method: &str, params: Value) -> Result<Value> {
        self.call(method, params, true)
    }
    fn attach(&mut self, index: usize) -> Result<()> {
        let target = self
            .targets
            .get(index)
            .ok_or("Unknown chromium tab")?
            .clone();
        let streaming = self.streaming;
        (self.find_result, self.finding) = (Value::Null, false);
        self.set_streaming(false)?;
        #[cfg(any(windows, target_os = "linux"))]
        self.sync_screencast(false)?;
        if !self.session.is_empty() {
            self.call(
                "Target.detachFromTarget",
                json!({"sessionId":self.session}),
                false,
            )?;
        }
        // The CEF target mapping appears asynchronously after tab creation.
        let deadline = Instant::now() + Duration::from_secs(5);
        while self
            .call("Graffitty.select", json!({"targetId":target}), false)
            .is_err()
        {
            if Instant::now() > deadline {
                return Err("Capture tab mapping timed out".into());
            }
            thread::sleep(Duration::from_millis(20));
        }
        self.selected = index;
        self.session = self.call(
            "Target.attachToTarget",
            json!({"targetId":target,"flatten":true}),
            false,
        )?["sessionId"]
            .as_str()
            .ok_or("Missing page session")?
            .into();
        // Reports this page's renderer crashes and reloads.
        self.page_crashed = false;
        self.heartbeat = None;
        self.page_unresponsive = false;
        self.page("Inspector.enable", json!({}))?;
        #[cfg(not(target_os = "macos"))]
        self.page(
            "Emulation.setDeviceMetricsOverride",
            json!({"width":self.width,"height":self.height,"deviceScaleFactor":1,"mobile":false}),
        )?;
        self.call("Graffitty.resize", self.resize_params(), false)?;
        self.set_streaming(streaming)?;
        Ok(())
    }
    fn state(&mut self) -> Result<Value> {
        self.context_dirty = false;
        let inventory = self.call("Target.getTargets", json!({}), false)?;
        let mut pages: Vec<_> = inventory["targetInfos"]
            .as_array()
            .ok_or("Missing chromium tabs")?
            .iter()
            .filter(|t| t["type"] == "page")
            .cloned()
            .collect();
        #[cfg(target_os = "macos")]
        let diagnostics = {
            let diagnostics = self.call("Graffitty.diagnostics", json!({}), false)?;
            if let Some(error) = diagnostics["error"].as_str().filter(|error| !error.is_empty()) {
                return Err(error.to_owned().into());
            }
            let windows = diagnostics["windows"].as_array().ok_or("Missing Chromium windows")?;
            if self.window_id.is_none() {
                self.window_id = windows.first().and_then(|window|window["id"].as_i64());
            }
            let Some(window_id) = self.window_id else {
                return Ok(json!({"tabs":[],"chromiumId":-1,"sessionId":self.session_id,"windows":[]}));
            };
            let Some(window) = windows.iter().find(|window|window["id"]==window_id) else {
                return Ok(json!({"tabs":[],"chromiumId":-1,"sessionId":self.session_id,"windowId":window_id,"closed":true,"windows":windows}));
            };
            let tabs=window["tabs"].as_array().ok_or("Missing window tabs")?;
            pages.retain(|page|tabs.iter().any(|tab|tab["target"]==page["targetId"]));
            pages.sort_by_key(|page|tabs.iter().position(|tab|tab["target"]==page["targetId"]).unwrap_or(usize::MAX));
            let endpoint=self.capture.as_ref().unwrap().endpoint.clone();
            self.call("Graffitty.registerWindow", json!({"endpoint":endpoint}),false)?;
            diagnostics
        };
        #[cfg(not(target_os = "macos"))]
        let diagnostics = {
            let diagnostics = self.call("Graffitty.diagnostics", json!({}), false)?;
            if let Some(error) = diagnostics["error"].as_str().filter(|error| !error.is_empty()) {
                return Err(error.to_owned().into());
            }
            let targets = diagnostics["pageTargets"].as_array().ok_or("Missing CEF page inventory")?;
            pages.retain(|page| targets.contains(&page["targetId"]));
            pages.sort_by_key(|page| targets.iter().position(|target| target == &page["targetId"]).unwrap());
            diagnostics
        };
        let selected_target = self.targets.get(self.selected).cloned();
        self.targets = pages.iter().filter_map(|p|p["targetId"].as_str().map(str::to_owned)).collect();
        let mut selection = selected_target.as_ref().and_then(|target|self.targets.iter().position(|id|id==target)).unwrap_or(0);
        #[cfg(target_os = "macos")]
        if let Some(tab) = diagnostics["windows"].as_array().and_then(|windows|windows.iter().find(|w|w["id"].as_i64()==self.window_id))
            .and_then(|w|w["tabs"].as_array()).and_then(|tabs|tabs.iter().find(|t|t["selected"]==true))
            && let Some(index) = self.targets.iter().position(|id|tab["target"]==*id) { selection=index; }
        #[cfg(not(target_os = "macos"))]
        if let Some(index) = self.targets.iter().position(|id| diagnostics["nativeSelectedTargetId"] == *id) {
            selection = index;
        }
        let selection_changed = self.targets.get(selection) != selected_target.as_ref();
        if selected_target.as_ref().is_some_and(|target|!inventory["targetInfos"].as_array().unwrap().iter().any(|p|p["targetId"]==*target)) {
            // Chromium automatically destroys the flattened session with a
            // closed target. A moved target still exists and must be detached.
            self.session.clear();
        }
        if self.targets.is_empty() {
            // The native host creates the first hidden window itself. A CDP
            // createTarget during startup would create/show another window.
            return Ok(json!({"tabs":[],"chromiumId":-1}));
        }
        if self.session.is_empty() || selection_changed {
            // A detached target can still exist in another window; explicitly
            // detach this pane's CDP session before choosing its survivor.
            self.attach(selection)?;
        } else { self.selected=selection; }
        #[cfg(any(windows, target_os = "linux"))]
        self.sync_screencast(diagnostics["captureTransport"] == "cdp-screencast" &&
            diagnostics["nativeVisible"] != true)?;
        let targets = self.targets.clone();
        self.tab_ids.retain(|target, _| targets.contains(target));
        let ids: Vec<u64> = targets.iter().map(|target| self.tab_id(target)).collect();
        let tabs: Vec<_> = targets.iter().enumerate().map(|(index, id)| {
            let page = pages.iter().find(|page| page["targetId"] == *id).unwrap();
            let mut tab = json!({"id":ids[index], "title":page["title"], "url":page["url"],
                "selected":index == self.selected, "loading":false});
            if let Some(details) = diagnostics["pageDetails"][id].as_object() {
                tab.as_object_mut().unwrap().extend(details.clone());
            }
            tab
        }).collect();
        let selected_id = ids[self.selected];
        let mut state = json!({"tabs":tabs,"chromiumId":selected_id,"capturedPageId":selected_id,"nativeVisible":false,"contextMenu":self.context_menu,"findResult":self.find_result,"captureTransport":if cfg!(target_os="macos"){"iosurface"}else if cfg!(windows){"d3d-shared-texture"}else{"vulkan-opaque-fd"}, "pid":self.chromium_pid, "profile":self.profile, "temporaryProfile":self.temporary_profile, "primaryTargetId":self.targets[self.selected], "runtimeDirectory":self.runtime_directory(),"sessionId":self.session_id,"windowId":self.window_id});
        // Chromium chrome Back/Forward availability for the attached page
        // (Godot ChromiumChrome reads can_go_back/can_go_forward). History is
        // chromium-side state; a page between sessions simply reports neither.
        if self.page_crashed && let Some(tab) = state["tabs"].get_mut(self.selected) {
            tab["crashed"] = json!(true);
        }
        if self.page_unresponsive && let Some(tab) = state["tabs"].get_mut(self.selected) {
            tab["notResponding"] = json!(true);
        }
        // Native close/quit controls can also hide the window. Query the
        // host instead of caching the last requested mode in the owner.
        state.as_object_mut().unwrap().extend(
            diagnostics.as_object().ok_or("Invalid chromium diagnostics")?.clone());
        Ok(state)
    }
    fn runtime_directory(&self) -> String {
        self.runtime_directory.clone()
    }
    fn evaluate(&mut self, expression: String) -> Result<Value> {
        // A crashed or stuck renderer cannot answer; fail now rather than
        // holding this pane's command channel until the timeout.
        if self.page_crashed {
            return Err("The page crashed; reload it to continue".into());
        }
        if self.page_unresponsive {
            return Err("The page is not responding; reload it to continue".into());
        }
        let value=self.page("Runtime.evaluate",json!({"expression":expression,"returnByValue":true,"awaitPromise":true,"timeout":10000}))?;
        if value.get("exceptionDetails").is_some() {
            return Err(value["exceptionDetails"].to_string().into());
        }
        evaluated_value(value["result"]["value"].clone())
    }
    fn dom(&mut self, action: &str, args: &Value) -> Result<Value> {
        let mut params = args.clone();
        if action == "snapshot" {
            params["generation"] = json!(uuid::Uuid::new_v4().simple().to_string());
        }
        self.evaluate(format!(
            "({})({})",
            // The shared asset is a complete function-expression statement.
            // Its trailing separator cannot appear inside this call expression.
            include_str!("../chromium/automation.js").trim().trim_end_matches(';'),
            json!({"action":action,"params":params})
        ))
    }
    fn command(&mut self, action: &str, args: &Value) -> Result<Value> {
        match action {
            "chromium.attach" => {
                self.service_playwright()?;
                if self.session.is_empty() {
                    self.state()?;
                }
                let target = self
                    .targets
                    .get(self.selected)
                    .ok_or("Chromium page is not ready")?;
                self.playwright.open(self.chromium_id, target)
            }
            "chromium.detach" => {
                let token = args["lease"].as_str().ok_or("Expected attachment lease")?;
                self.playwright.release(Some(token));
                self.service_playwright()?;
                Ok(json!({"detached":true}))
            }
            "resources" => self.resources.request(args).map_err(Into::into),
            "chromium.eval" => self.evaluate(
                args["expression"]
                    .as_str()
                    .ok_or("Expected expression")?
                    .into(),
            ),
            "chromium.snapshot" => self.dom("snapshot", args),
            "chromium.fill" => self.dom("fill", args),
            "chromium.scroll" => self.dom("scroll", args),
            "chromium.navigate" => self.page("Page.navigate", json!({"url":args["url"]})),
            "chromium.click" => {
                let point = self.dom("locate", args)?;
                for kind in ["mousePressed", "mouseReleased"] {
                    self.page("Input.dispatchMouseEvent",json!({"type":kind,"x":point["x"],"y":point["y"],"button":"left","clickCount":1}))?;
                }
                Ok(json!({"clicked":true}))
            }
            "chromium.press" => {
                let key = args["key"].as_str().ok_or("Expected key")?;
                let code = match key {
                    "Enter" => 13,
                    "Tab" => 9,
                    "Escape" => 27,
                    "Backspace" => 8,
                    "Delete" => 46,
                    "ArrowLeft" => 37,
                    "ArrowUp" => 38,
                    "ArrowRight" => 39,
                    "ArrowDown" => 40,
                    "Space" => 32,
                    _ => return Err("Unsupported key".into()),
                };
                for kind in ["keyDown", "keyUp"] {
                    let mut params = json!({"type":kind,"key":if key=="Space"{" "}else{key},"windowsVirtualKeyCode":code});
                    if kind == "keyDown" && ["Enter", "Space"].contains(&key) {
                        params["text"] = json!(if key == "Enter" { "\r" } else { " " });
                    }
                    self.page("Input.dispatchKeyEvent", params)?;
                }
                Ok(json!({"pressed":key}))
            }
            "chromium.wait" => {
                let deadline = Instant::now()
                    + Duration::from_millis(
                        args["timeout_ms"].as_u64().unwrap_or(10000).clamp(1, 30000),
                    );
                loop {
                    let value = self.dom("wait", args)?;
                    if value["ready"] == true {
                        return Ok(value);
                    }
                    if Instant::now() >= deadline {
                        return Err("Page condition not reached".into());
                    }
                    let next = Instant::now() + Duration::from_millis(25);
                    while Instant::now() < next {
                        self.receive()?;
                    }
                }
            }
            "context-menu-select" => self.call("Graffitty.contextMenuSelect", args.clone(), false),
            // Chromium's find-in-page engine on the selected page. A new query
            // restarts the count; `find_next` steps through the current one.
            "find" => {
                let text = args["text"].as_str().filter(|text| !text.is_empty() && text.len() <= 4096)
                    .ok_or("Find text is empty or too long")?;
                let find_next = args["find_next"] == true;
                let params = |find_next: bool| json!({"text":text,"backward":args["backward"] == true,
                    "matchCase":args["match_case"] == true,"findNext":find_next});
                self.finding = true;
                if find_next {
                    return self.page("Graffitty.find", params(true));
                }
                // A new CEF find session only highlights its matches. Like
                // Chrome, also make the first (or, backward, the last)
                // active.
                //
                // The previous query's active match must not be the starting
                // point: stepping on from it drifts one match per keystroke,
                // and Chromium then reports the wrong ordinal.
                self.find_result = Value::Null;
                self.page("Graffitty.stopFinding", json!({"clearSelection":true}))?;
                self.page("Graffitty.find", params(false))?;
                self.page("Graffitty.find", params(true))
            }
            "find-stop" => {
                self.finding = false;
                self.find_result = Value::Null;
                self.context_dirty = true;
                self.page("Graffitty.stopFinding", json!({"clearSelection":args["clear_selection"] == true}))
            }
            "render-demand" => {
                self.render_demand = args["height"].as_u64().map(|height| height.clamp(1, 8192) as u32);
                self.sync_render_scale()?;
                Ok(json!({}))
            }
            "chrome-state" => self.state(),
            "cdp" => self.page(
                args["method"].as_str().ok_or("Missing CDP method")?,
                args.get("params").cloned().unwrap_or(json!({})),
            ),
            "resize" => {
                self.width = args["width"].as_u64().unwrap_or(1000).clamp(64, 4096) as u32;
                self.height = args["height"].as_u64().unwrap_or(700).clamp(64, 4096) as u32;
                #[cfg(target_os = "macos")]
                { self.render_scale = self.render_target(); }
                self.call("Graffitty.resize", self.resize_params(), false)?;
                #[cfg(not(target_os = "macos"))]
                return self.page("Emulation.setDeviceMetricsOverride",json!({"width":self.width,"height":self.height,"deviceScaleFactor":1,"mobile":false}));
                #[cfg(target_os = "macos")]
                Ok(json!({}))
            }
            "tab-select" => {
                let index = self.tab_index(args)?;
                self.attach(index)?;
                self.state()
            }
            "tab-move" => {
                // Chromium chrome drag-reorder. Page ids are stable, so the
                // selected page keeps its id; only positions change.
                let from = self.tab_index(args)?;
                let index = args["index"].as_u64().ok_or("Expected tab index")? as usize;
                if from >= self.targets.len() || index >= self.targets.len() {
                    return Err("Invalid tab index".into());
                }
                self.call("Graffitty.moveTab", json!({"targetId":self.targets[from],"index":index}),false)?;
                let selected = self.targets.get(self.selected).cloned();
                let target = self.targets.remove(from);
                self.targets.insert(index, target);
                if let Some(selected) = selected {
                    self.selected = self.targets.iter().position(|id| *id == selected).unwrap_or(0);
                }
                self.state()
            }
            "tab-new" => {
                let value = self.call(
                    "Graffitty.createTab",
                    // On macOS create inside the existing hidden window via
                    // the tab bridge. CDP createTarget shows the native window
                    // even when background is true in the Chrome runtime.
                    json!({"url":args.get("url").cloned().unwrap_or(json!("about:blank")),"background":true}),
                    false,
                )?;
                self.state()?;
                let id = value["targetId"].as_str().unwrap_or("");
                if let Some(index) = self.targets.iter().position(|t| t == id) {
                    self.attach(index)?;
                }
                self.state()
            }
            "tab-close" => {
                let index = self.tab_index(args)?;
                let id = self.targets.get(index).ok_or("Unknown page")?.clone();
                // Select the surviving neighbor before destroying the active page.
                // If the active page closes first, Chromium can select the first page
                // and briefly show its pixels under the neighbor's tab.
                if index == self.selected && self.targets.len() > 1 {
                    let neighbour = if index + 1 < self.targets.len() { index + 1 } else { index - 1 };
                    self.attach(neighbour)?;
                }
                let selected = self.targets.get(self.selected).cloned();
                self.call("Target.closeTarget", json!({"targetId":id}), false)?;
                // Target removal is asynchronous. Wait briefly so the closed
                // page is neither kept nor appended again by state().
                let deadline = Instant::now() + Duration::from_secs(2);
                while Instant::now() < deadline
                    && self.call("Target.getTargets", json!({}), false)?["targetInfos"]
                        .as_array()
                        .is_some_and(|targets| targets.iter().any(|t| t["targetId"] == id.as_str()))
                {
                    let next = Instant::now() + Duration::from_millis(20);
                    while Instant::now() < next {
                        self.receive()?;
                    }
                }
                self.targets.retain(|target| *target != id);
                if selected.as_ref() == Some(&id) {
                    // Like Chrome, closing the selected page selects its
                    // neighbour; its session ended with the page.
                    self.session.clear();
                    self.streaming = false;
                    if !self.targets.is_empty() {
                        self.attach(index.min(self.targets.len() - 1))?;
                    }
                } else if let Some(selected) = selected {
                    // Closing another page keeps the selected page and session.
                    self.selected = self.targets.iter().position(|target| *target == selected).unwrap_or(0);
                }
                self.state()
            }
            "tab-navigate" => {
                // Typed address-bar text: Chrome's omnibox picks the URL or a
                // search with the profile's default engine, as a real window would.
                let text = args["text"].as_str().map(str::trim).filter(|t| !t.is_empty())
                    .ok_or("Enter a chromium address")?;
                let resolved = self.call("Graffitty.classify", json!({"text":text}), false).map_err(|error| {
                    let error = error.to_string();
                    serde_json::from_str::<Value>(&error).ok()
                        .and_then(|e| e["message"].as_str().map(str::to_owned)).unwrap_or(error)
                })?;
                let url = resolved["url"].as_str().ok_or("Chrome did not resolve the address")?;
                // Clients may be remote: never let them open host files or browser internals.
                let blank = url == "about:blank" || url.starts_with("about:blank#") || url.starts_with("about:blank?");
                if !(url.starts_with("https://") || url.starts_with("http://") || blank) {
                    return Err("Use an http:// or https:// URL".into());
                }
                self.page("Page.navigate", json!({"url":url}))
            }
            "history-query" => {
                // Address-bar suggestions ranked by Chrome's omnibox from the
                // profile's local history; typing never reaches a search service.
                let text = args["text"].as_str().ok_or("Expected history text")?;
                if text.len() > 2048 {
                    return Err("History text is limited to 2048 bytes".into());
                }
                let limit = args.get("limit").map_or(Some(8), Value::as_u64).filter(|l| (1..=20).contains(l))
                    .ok_or("History limit must be 1-20")?;
                if text.trim().is_empty() {
                    return Ok(json!({"matches":[]}));
                }
                history_matches(&self.call("Graffitty.historyQuery", json!({"text":text,"limit":limit}), false)?)
            }
            "tab-reload" if self.page_unresponsive => {
                // A stuck renderer never runs Page.reload, and a same-site
                // load would reuse it.
                //
                // A different document commits in a new renderer and Chromium
                // ends the stuck one, which leaves no crash report
                // (Page.crash would, and macOS shows each as a "quit
                // unexpectedly" dialog).
                //
                // It then replaces itself with the page, so history gains no
                // extra entry.
                let history = self.page("Page.getNavigationHistory", json!({}))?;
                let url = history["entries"].get(history["currentIndex"].as_u64().unwrap_or(0) as usize)
                    .and_then(|entry| entry["url"].as_str()).unwrap_or("about:blank").to_owned();
                let script = format!("<script>location.replace({})</script>", serde_json::to_string(&url)?);
                self.page("Page.navigate", json!({"url": format!("data:text/html;base64,{}", STANDARD.encode(script))}))
            }
            "tab-reload" => self.page("Page.reload", json!({})),
            "tab-stop" => self.page("Page.stopLoading", json!({})),
            "tab-back" | "tab-forward" => {
                let h = self.page("Page.getNavigationHistory", json!({}))?;
                let index = h["currentIndex"].as_i64().unwrap_or(0)
                    + if action == "tab-back" { -1 } else { 1 };
                let entry = h["entries"]
                    .as_array()
                    .and_then(|a| usize::try_from(index).ok().and_then(|i| a.get(i)))
                    .ok_or("No history entry")?;
                self.page(
                    "Page.navigateToHistoryEntry",
                    json!({"entryId":entry["id"]}),
                )
            }
            "chrome-native" | "chrome-world" => {
                self.context_dirty = true;
                self.call("Graffitty.present", json!({"mode":if action == "chrome-native" {"native"} else {"embedded"}}), false)
            }
            "capture-enabled" => Ok(json!({"ok":true})),
            _ => Err(format!("Unsupported chromium action: {action}").into()),
        }
    }
}

/// Chrome's version 1 history reply, reduced to entries `tab-navigate` accepts.
fn history_matches(result: &Value) -> Result<Value> {
    if result["version"] != 1 {
        return Err("Unexpected Chrome history protocol version".into());
    }
    let matches = result["matches"].as_array().ok_or("Chrome history reply has no matches")?;
    let matches: Vec<Value> = matches
        .iter()
        .filter_map(|entry| {
            let url = entry["url"].as_str()?;
            (url.starts_with("https://") || url.starts_with("http://"))
                .then(|| json!({"url":url,"title":entry["title"].as_str().unwrap_or("")}))
        })
        .collect();
    Ok(json!({ "matches": matches }))
}

#[cfg(test)]
mod error_tests {
    use super::*;

    #[test]
    fn history_keeps_only_navigable_entries_of_the_current_version() {
        let reply = json!({"version":1,"matches":[
            {"url":"https://github.com/","title":"GitHub","type":"history-url"},
            {"url":"file:///etc/hosts","title":"hosts"},
            {"url":"http://example.com/"}]});
        assert_eq!(history_matches(&reply).unwrap(), json!({"matches":[
            {"url":"https://github.com/","title":"GitHub"},
            {"url":"http://example.com/","title":""}]}));
        assert!(history_matches(&json!({"version":2,"matches":[]})).is_err());
    }

    #[test]
    fn stale_dom_reference_survives_the_chromium_command_reply() {
        let value = json!({"error":{"code":"stale_ref","message":"Take a fresh snapshot and use its element reference"}});
        let error = evaluated_value(value.clone()).unwrap_err();
        assert_eq!(command_error(&error), value["error"]);
        assert_eq!(evaluated_value(json!({"clicked":true})).unwrap(), json!({"clicked":true}));
        let unexpected = evaluated_value(json!({"error":"page failed"})).unwrap_err();
        assert_eq!(command_error(&unexpected)["code"], "chromium_error");
    }
}
