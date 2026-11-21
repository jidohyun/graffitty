//! `gft internal update prepare` and `gft internal update finish`: the two steps an installer
//! runs so that terminals keep running during an upgrade.
//!
//! macOS and Linux can replace the files of a running program, so an installer
//! only runs `finish`:
//!
//! 1. The server restarts as the new build.
//! 2. Its holders give the terminals to the new server.
//!
//! Windows locks the files of a running program, so an installer runs
//! `prepare` before it copies anything:
//!
//! 1. The server exits. Its holders keep the terminals.
//! 2. Graffitty's windows close.
//! 3. Files that a holder still runs from are renamed out of the way.
//!
//! Then `finish` starts the new server and reopens the windows.
use crate::live_sessions::{call, context, descriptor, restart_server, spawn_server, wait_for_server};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// How long to wait for the windows to close. After that, the upgrade is cancelled.
const FRONTEND_EXIT: Duration = Duration::from_secs(30);
/// Added to the name of a file that was renamed because a process still uses it.
const ASIDE: &str = ".old-";

fn record_path() -> Result<PathBuf> {
    Ok(descriptor()?.with_extension("update.json"))
}

fn save_checkpoint() {
    let saved = std::env::current_exe().and_then(|exe| {
        std::process::Command::new(exe)
            .args(["checkpoint", "save"])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .status()
    });
    if !saved.is_ok_and(|status| status.success()) {
        eprintln!("gft internal update: could not save a checkpoint; continuing, terminals keep running");
    }
}

/// Waits until the old server has exited. It holds a lock on the descriptor until then.
fn wait_for_exit(deadline: Instant) -> Result<()> {
    let lock = descriptor()?.with_extension("lock");
    loop {
        let free = fs::OpenOptions::new().read(true).write(true).open(&lock).is_ok_and(|file| {
            let free = fs2::FileExt::try_lock_exclusive(&file).is_ok();
            let _ = fs2::FileExt::unlock(&file);
            free
        });
        if free {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("The session server did not leave in time".into());
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

pub fn prepare() -> Result<()> {
    if context().is_err() {
        println!("No session server is running");
        return Ok(());
    }
    save_checkpoint();
    let record = record_path()?;
    let _ = fs::remove_file(&record);
    let result = call("server.restart", json!({"park": true}))?;
    wait_for_exit(Instant::now() + Duration::from_secs(30))?;
    let mut parked: Value = serde_json::from_slice(&fs::read(&record)?)?;
    let frontends: Vec<u32> = serde_json::from_value(parked["frontends"].clone()).unwrap_or_default();
    // Record each window's executable now, while the window still runs.
    // `finish` reopens the windows from this list.
    let mut executables: Vec<String> = frontends.iter().filter_map(|pid| process::executable(*pid)).collect();
    executables.sort();
    executables.dedup();
    parked["executables"] = json!(executables);
    fs::write(&record, serde_json::to_vec(&parked)?)?;
    let cleared = (|| -> Result<()> {
        let deadline = Instant::now() + FRONTEND_EXIT;
        for pid in &frontends {
            if !process::wait_exit(*pid, deadline) {
                return Err(format!("A Graffitty window (process {pid}) did not close").into());
            }
        }
        let root = installation()?;
        move_aside(&root)
    })();
    if let Err(error) = cleared {
        // The upgrade is cancelled. The old files are still in place, so start the
        // old server and its windows again.
        eprintln!("gft internal update: {error}; restoring the session server");
        finish()?;
        return Err(error);
    }
    println!("Parked; {} terminal(s) kept", result["terminals"].as_u64().unwrap_or(0));
    Ok(())
}

pub fn finish() -> Result<()> {
    let record = record_path()?;
    let Ok(bytes) = fs::read(&record) else {
        if context().is_err() {
            println!("No session server is running");
            return Ok(());
        }
        if call("server.status", json!({}))?["build"] == graffitty_server::build_id() {
            println!("The session server already runs this version");
            return Ok(());
        }
        save_checkpoint();
        // The server is still running the old build. Restart it and reopen the windows.
        return restart_server(true);
    };
    let parked: Value = serde_json::from_slice(&bytes)?;
    if context().is_err() || call("session.list", json!({})).is_err() {
        let mut command: Vec<String> = serde_json::from_value(parked["command"].clone())
            .map_err(|_| "The parked server left no command to start it again")?;
        // Start the server from this installation, not from the path the old one recorded.
        *command.first_mut().ok_or("The parked server left an empty command")? =
            graffitty_platform::install::stable_path(&std::env::current_exe()?).to_string_lossy().into_owned();
        spawn_server(&command)?;
        wait_for_server(Instant::now() + Duration::from_secs(30))?;
    }
    fs::remove_file(&record)?;
    for executable in parked["executables"].as_array().into_iter().flatten().filter_map(Value::as_str) {
        let path = Path::new(executable);
        let launcher = if cfg!(windows) && path.file_name().is_some_and(|name| name.eq_ignore_ascii_case("GraffittyRuntime.exe")) {
            path.with_file_name("Graffitty.exe")
        } else { path.to_owned() };
        if let Err(error) = process::open(&launcher) {
            eprintln!("gft internal update: cannot reopen {executable}: {error}");
        }
    }
    if let Ok(root) = installation() {
        remove_aside(&root);
    }
    println!("Resumed; {} terminal(s) kept", parked["terminals"].as_u64().unwrap_or(0));
    Ok(())
}

/// The folder Graffitty is installed in. This executable is `<folder>/tools/gft`.
fn installation() -> Result<PathBuf> {
    let exe = std::env::current_exe()?;
    Ok(exe.parent().and_then(Path::parent).ok_or("This executable is not part of an installation")?.to_path_buf())
}

fn files(root: &Path, found: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(root).into_iter().flatten().flatten() {
        let path = entry.path();
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => files(&path, found),
            Ok(kind) if kind.is_file() => found.push(path),
            _ => {}
        }
    }
}

fn is_aside(path: &Path) -> bool {
    path.file_name().is_some_and(|name| name.to_string_lossy().contains(ASIDE))
}

/// Deletes files that an earlier upgrade renamed and that no process uses any more.
fn remove_aside(root: &Path) {
    let mut found = Vec::new();
    files(root, &mut found);
    for path in found.into_iter().filter(|path| is_aside(path)) {
        let _ = fs::remove_file(path);
    }
}

/// Renames every file that a running process still uses, so the installer can
/// write the new file under the old name. Only Windows needs this.
///
/// A terminal holder keeps running from the renamed file until its last
/// terminal ends.
fn move_aside(root: &Path) -> Result<()> {
    remove_aside(root);
    if !cfg!(windows) {
        return Ok(());
    }
    let mut found = Vec::new();
    files(root, &mut found);
    for path in found.into_iter().filter(|path| !is_aside(path) && process::in_use(path)) {
        let mut name = path.file_name().unwrap_or_default().to_os_string();
        name.push(format!("{ASIDE}{}-{}", std::process::id(), uuid::Uuid::new_v4().simple()));
        let aside = path.with_file_name(name);
        fs::rename(&path, &aside)
            .map_err(|error| format!("{} is in use and cannot be moved aside: {error}", path.display()))?;
        // Put a copy back under the old name. If the upgrade stops here, Graffitty
        // still starts.
        fs::copy(&aside, &path)?;
    }
    Ok(())
}

#[cfg(unix)]
mod process {
    use std::path::Path;
    use std::time::{Duration, Instant};

    /// Not needed on Unix: the installer never closes a window. The server tells
    /// each window to reopen itself.
    pub fn executable(_pid: u32) -> Option<String> {
        None
    }

    pub fn wait_exit(pid: u32, deadline: Instant) -> bool {
        while unsafe { libc::kill(pid as i32, 0) } == 0 {
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        true
    }

    pub fn in_use(_path: &Path) -> bool {
        false
    }

    pub fn open(executable: &Path) -> std::io::Result<()> {
        use std::process::Stdio;
        std::process::Command::new(executable)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map(drop)
    }
}

#[cfg(windows)]
mod process {
    use std::os::windows::{fs::OpenOptionsExt, process::CommandExt};
    use std::path::Path;
    use std::time::Instant;
    use windows_sys::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE, QueryFullProcessImageNameW,
        WaitForSingleObject,
    };

    pub fn executable(pid: u32) -> Option<String> {
        unsafe {
            let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if process.is_null() {
                return None;
            }
            let mut path = [0u16; 32768];
            let mut length = path.len() as u32;
            let found = QueryFullProcessImageNameW(process, 0, path.as_mut_ptr(), &mut length) != 0;
            CloseHandle(process);
            found.then(|| String::from_utf16_lossy(&path[..length as usize]))
        }
    }

    pub fn wait_exit(pid: u32, deadline: Instant) -> bool {
        unsafe {
            let process = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
            if process.is_null() {
                // The process has already exited.
                return true;
            }
            let left = deadline.saturating_duration_since(Instant::now()).as_millis() as u32;
            let ended = WaitForSingleObject(process, left) == WAIT_OBJECT_0;
            CloseHandle(process);
            ended
        }
    }

    /// True if a process has the file open or is running from it.
    pub fn in_use(path: &Path) -> bool {
        std::fs::OpenOptions::new().read(true).write(true).share_mode(0).open(path).is_err()
    }

    pub fn open(executable: &Path) -> std::io::Result<()> {
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
        let mut command = std::process::Command::new(executable);
        // Do not pass the installer's output handles to the window. The installer
        // would wait for them until the window closed.
        crate::live_sessions::keep_output_private();
        command.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        if let Some(home) = std::env::var_os("USERPROFILE") {
            command.current_dir(home);
        }
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB);
        match command.spawn() {
            // The installer's job object forbids leaving it. Start the window inside the job.
            Err(error) if error.raw_os_error() == Some(5) => {
                command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
                command.spawn().map(drop)
            }
            started => started.map(drop),
        }
    }
}
