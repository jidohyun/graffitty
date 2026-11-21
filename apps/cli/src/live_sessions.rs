//! tmux-style live sessions on the shared local owner, independent of a GUI.
use crate::{options::NewSession, transport};
use serde_json::{Value, json};
use std::{
    fs,
    path::PathBuf,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

pub(crate) fn descriptor() -> Result<PathBuf> {
    graffitty_graph_protocol::local_server_descriptor()
}

pub(crate) fn context() -> Result<(String, String)> {
    graffitty_graph_protocol::local_server()
}

pub(crate) fn call(method: &str, params: Value) -> Result<Value> {
    let (endpoint, token) = context()?;
    use graffitty_graph_protocol::Rpc;
    graffitty_graph_protocol::Client::new(endpoint, token)
        .with_timeout(Duration::from_secs(10)).call(method, params)
}

/// Restarts the server without closing terminals. The holders keep every
/// program and the new server adopts them. Returns when the new server
/// answers.
///
/// With `relaunch` (used after an upgrade), open windows reopen as the new
/// version.
pub fn restart_server(relaunch: bool) -> Result<()> {
    let before = context()?;
    let result = call("server.restart", json!({"relaunch": relaunch}))?;
    // Start the new server here, as soon as the old one has exited. A holder
    // would also start it, but only after a delay, and there is no holder when
    // there are no terminals.
    if let Ok(command) = serde_json::from_value::<Vec<String>>(result["command"].clone())
        && !command.is_empty()
    {
        let lock = descriptor()?.with_extension("lock");
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            let free = fs::OpenOptions::new().read(true).write(true).open(&lock).is_ok_and(|file| {
                let free = fs2::FileExt::try_lock_exclusive(&file).is_ok();
                let _ = fs2::FileExt::unlock(&file);
                free
            });
            if free {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        // An open window may already have started the server.
        if context().is_err() {
            spawn_server(&command)?;
        }
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        // The next owner keeps the endpoint but publishes a new local token.
        if context().is_ok_and(|now| now.1 != before.1) && call("session.list", json!({})).is_ok() {
            let kept = result["terminals"].as_u64().unwrap_or(0);
            // Kept terminals stay on the holder of the build that started
            // them; say so, so older processes left running are explained.
            let status = call("server.status", json!({}))?;
            let terminals = status["draining_terminals"].as_u64().unwrap_or(0);
            let holders = status["draining_holders"].as_u64().unwrap_or(0);
            if terminals > 0 {
                println!(
                    "Restarted; {kept} terminal(s) kept, {terminals} still on {holders} older-build holder(s) until they exit"
                );
            } else {
                println!("Restarted; {kept} terminal(s) kept");
            }
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("Timed out waiting for the restarted session server".into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Stops child processes from inheriting this command's output handles.
/// Windows passes every inheritable handle to a new process. A server holding
/// this command's output would make the caller wait until the server exits.
#[cfg(windows)]
pub(crate) fn keep_output_private() {
    use windows_sys::Win32::Foundation::{HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE, SetHandleInformation};
    use windows_sys::Win32::System::Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE};
    for which in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
        let handle = unsafe { GetStdHandle(which) };
        if !handle.is_null() && handle != INVALID_HANDLE_VALUE {
            unsafe { SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0) };
        }
    }
}

/// Starts a session server as an independent process. `command` is its full
/// command line.
pub(crate) fn spawn_server(command: &[String]) -> Result<()> {
    let (program, arguments) = command.split_first().ok_or("Empty server command")?;
    let path = descriptor()?;
    let parent = path.parent().ok_or("Missing descriptor directory")?;
    let log = fs::OpenOptions::new().create(true).append(true).open(parent.join("server.log"))?;
    let mut server = Command::new(program);
    server.args(arguments).stdin(Stdio::null()).stdout(log.try_clone()?).stderr(log);
    // A handover leaves the old server's environment: the new one keeps it,
    // whoever runs this command (an agent, a pane's shell). Read once.
    let inherited = graffitty_server::handover_environment_path(&path);
    if let Ok(bytes) = fs::read(&inherited) {
        let _ = fs::remove_file(&inherited);
        let environment: std::collections::BTreeMap<String, String> = serde_json::from_slice(&bytes)
            .map_err(|_| "The previous session server left an unreadable environment")?;
        server.env_clear().envs(environment);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        server.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        server.creation_flags(0x08000000);
        keep_output_private();
    }
    server.spawn()?;
    Ok(())
}

/// Waits until a session server answers.
pub(crate) fn wait_for_server(deadline: Instant) -> Result<()> {
    while call("session.list", json!({})).is_err() {
        if Instant::now() >= deadline {
            return Err("Timed out waiting for the session server".into());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Ok(())
}

pub fn capture_checkpoint() -> Result<Value> {
    call("session.checkpoint", json!({}))
}

fn start_server() -> Result<()> {
    let path = descriptor()?;
    // Do not replace or terminate an existing owner.
    if let Ok(bytes) = fs::read(&path) {
        if let Ok(data) = serde_json::from_slice::<Value>(&bytes) {
            let local = &data["local"];
            if local["url"]
                .as_str()
                .is_some_and(|url| transport::Stream::connect(url).is_ok())
            {
                return Ok(());
            }
        }
    }
    let parent = path.parent().ok_or("Missing descriptor directory")?;
    fs::create_dir_all(parent)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    }
    let binary = std::env::var_os("GRAFFITTY_SERVER")
        .map(PathBuf::from)
        .unwrap_or(std::env::current_exe()?);
    let log = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(parent.join("server.log"))?;
    let mut command = Command::new(binary);
    command
        .args(["server", "--connection"])
        .arg(&path)
        .arg("--auth-file")
        .arg(parent.join("auth.json"))
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
        keep_output_private();
    }
    let mut child = command.spawn()?;
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if call("session.list", json!({})).is_ok() {
            return Ok(());
        }
        if let Some(status) = child.try_wait()? {
            // Another launcher may have won the descriptor lock.
            if call("session.list", json!({})).is_ok() {
                return Ok(());
            }
            return Err(format!(
                "Session server exited {status}; see {}",
                parent.join("server.log").display()
            )
            .into());
        }
        if Instant::now() >= deadline {
            return Err("Timed out starting session server".into());
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

pub fn list(as_json: bool) -> Result<()> {
    let value = call("session.list", json!({}))?;
    if as_json {
        println!("{}", value["sessions"]);
    } else {
        for entry in value["sessions"].as_array().ok_or("Invalid session list")? {
            println!(
                "{}: {} windows, {} panes{}",
                entry["name"].as_str().or(entry["automatic_name"].as_str())
                    .map(|name| format!("{name} {}", entry["id"].as_str().unwrap_or("")))
                    .unwrap_or_else(|| entry["id"].as_str().unwrap_or("").to_owned()),
                entry["windows"],
                entry["panes"],
                if entry["attached"] == true {
                    " (attached)"
                } else {
                    ""
                }
            );
        }
    }
    Ok(())
}
pub fn rename(target: &str, name: &str) -> Result<()> {
    call("session.rename", json!({"name":target,"new_name":name}))?;
    Ok(())
}
pub fn target(method: &str, name: &str) -> Result<()> {
    call(method, json!({"name":name}))?;
    Ok(())
}
pub fn attach(name: &str) -> Result<()> {
    if let Some(result) = pane_call("session.attach", json!({"name":name})) {
        result?;
        return Ok(());
    }
    target("session.has", name)?;
    Err(crate::launch(
        vec![format!("--workspace={name}"), "--attach-session".into()],
        None,
    )
    .into())
}

// A server-owned shell deliberately receives only its pane capability, not
// the daemon's administrative descriptor. Route through that exact owner.
fn pane_call(method: &str, params: Value) -> Option<Result<Value>> {
    if let (Ok(socket), Ok(token)) = (std::env::var("GRAFFITTY_SOCKET"), std::env::var("GRAFFITTY_TOKEN")) {
        if !socket.is_empty() && !token.is_empty() {
            let response = crate::call_context(method, params, Duration::from_secs(10), Some((socket, token)));
            if let Some(error) = response.get("error") {
                return Some(Err(error["message"].as_str().unwrap_or("Session command failed").to_owned().into()));
            }
            return Some(Ok(response["result"].clone()));
        }
    }
    None
}
pub fn new(args: NewSession) -> Result<()> {
    let cwd = match args.cwd {
        Some(path) => fs::canonicalize(path)?,
        None => std::env::current_dir()?,
    };
    if !cwd.is_dir() {
        return Err("Starting directory is not a directory".into());
    }
    if let Some(result) = pane_call("session.create", json!({
        "name":args.session_name, "spawn":{"cwd":cwd}, "detached":args.detached
    })) {
        let value = result?;
        if args.detached {
            println!("{}", value["id"].as_str().ok_or("Missing session ID")?);
        }
        return Ok(());
    }
    start_server()?;
    let value = call(
        "session.new",
        json!({"name":args.session_name,"spawn":{"cwd":cwd}}),
    )?;
    let name = value["id"].as_str().ok_or("Missing session ID")?;
    if args.detached {
        println!("{name}");
        Ok(())
    } else {
        attach(name)
    }
}
