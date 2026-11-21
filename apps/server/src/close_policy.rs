//! Fresh close confirmation checks. Unknown process state always asks first.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn shell(name: &str) -> bool {
    matches!(name.trim_start_matches('-'), "sh" | "zsh" | "bash" | "fish" | "dash" | "ksh" | "nu")
}

pub fn has_running_program(pid: Option<u32>, exited: bool) -> bool {
    if exited { return false; }
    pid.and_then(|pid| inspect(pid).ok()).unwrap_or(true)
}

#[cfg(target_os = "macos")]
fn inspect(pid: u32) -> std::io::Result<bool> {
    fn info(pid: u32) -> std::io::Result<libc::proc_bsdinfo> {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of_val(&info) as i32;
        if unsafe { libc::proc_pidinfo(pid as i32, libc::PROC_PIDTBSDINFO, 0, (&mut info as *mut libc::proc_bsdinfo).cast(), size) } != size {
            return Err(std::io::Error::last_os_error());
        }
        Ok(info)
    }
    let root = info(pid)?;
    if root.pbi_status == 5 { return Ok(false); }
    let name: Vec<u8> = root.pbi_name.iter().map(|byte| *byte as u8).take_while(|byte| *byte != 0).collect();
    let name = String::from_utf8_lossy(&name);
    if !shell(&name) { return Ok(true); }
    let mut children = vec![0i32; 64];
    for _ in 0..8 {
        let count = unsafe { libc::proc_listchildpids(pid as i32, children.as_mut_ptr().cast(), (children.len()*4) as i32) };
        if count < 0 { return Err(std::io::Error::last_os_error()); }
        if count as usize >= children.len() { children.resize(children.len()*2, 0); continue; }
        for child in children.into_iter().take(count as usize).filter(|p| *p > 0) {
            match info(child as u32) {
                Ok(child) if child.pbi_ppid == pid && child.pbi_status != 5 => return Ok(true),
                Ok(_) => {},
                Err(error) if error.raw_os_error() == Some(libc::ESRCH) => {},
                Err(error) => return Err(error),
            }
        }
        return Ok(false);
    }
    Err(std::io::Error::other("Process tree changed during close check"))
}

#[cfg(target_os = "linux")]
fn inspect(pid: u32) -> std::io::Result<bool> {
    let executable = std::fs::read_link(format!("/proc/{pid}/exe"))?;
    if !executable.file_name().and_then(|n| n.to_str()).is_some_and(shell) { return Ok(true); }
    for entry in std::fs::read_dir("/proc")? {
        let entry = entry?;
        if entry.file_name().to_string_lossy().parse::<u32>().is_err() { continue; }
        let stat = match std::fs::read_to_string(entry.path().join("stat")) {
            Ok(stat) => stat,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        let Some((_, rest)) = stat.rsplit_once(')') else { return Err(std::io::Error::other("Invalid process status")); };
        let mut fields = rest.split_whitespace();
        let state = fields.next();
        if fields.next().and_then(|parent| parent.parse::<u32>().ok()) == Some(pid) && state != Some("Z") { return Ok(true); }
    }
    Ok(false)
}

#[cfg(windows)]
fn inspect(pid: u32) -> std::io::Result<bool> {
    terminal_resource_monitor::windows::has_running_program(pid).map_err(std::io::Error::other)
}

#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
fn inspect(_pid: u32) -> std::io::Result<bool> { Ok(true) }

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;
    use portable_pty::{CommandBuilder, PtySize};
    use std::time::{Duration, Instant};

    #[test]
    fn fresh_job_query_distinguishes_idle_shell_and_child() {
        for (script, expected) in [
            ("rem idle", false),
            ("powershell.exe -NoProfile -Command Start-Sleep -Seconds 3", true),
        ] {
            let pair = portable_pty::native_pty_system().openpty(PtySize::default()).unwrap();
            let mut boundary = terminal_resource_monitor::windows::Boundary::prepare().unwrap();
            let mut command = CommandBuilder::new("cmd.exe");
            command.args(["/d", "/k", script]);
            command.set_job(boundary.handle());
            let mut child = pair.slave.spawn_command(command).unwrap();
            let pid = child.process_id().unwrap();
            boundary.register(pid);
            let deadline = Instant::now() + Duration::from_secs(2);
            let mut observed = has_running_program(Some(pid), false);
            while observed != expected && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
                observed = has_running_program(Some(pid), false);
            }
            // Let the short-lived child finish before tearing down its parent.
            if expected { std::thread::sleep(Duration::from_secs(4)); }
            child.kill().unwrap();
            child.wait().unwrap();
            drop(pair);
            assert_eq!(observed, expected, "{script}");
        }
        assert!(has_running_program(None, false));
        assert!(has_running_program(Some(u32::MAX), false));
        assert!(!has_running_program(None, true));
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{os::unix::process::CommandExt, process::{Child, Command, Stdio}, time::{Duration, Instant}};
    struct Process(Child);
    impl Drop for Process { fn drop(&mut self) { unsafe {libc::kill(-(self.0.id() as i32), libc::SIGKILL);} let _ = self.0.wait(); } }
    fn spawn(script: &str) -> Process { Process(Command::new("/bin/sh").args(["-c",script]).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0).spawn().unwrap()) }
    fn wait(pid:u32, expected:bool) { let until=Instant::now()+Duration::from_secs(2);while has_running_program(Some(pid),false)!=expected {assert!(Instant::now()<until);std::thread::sleep(Duration::from_millis(10));} }
    #[test]
    fn fresh_checks_distinguish_idle_shell_background_job_and_exec_application() {
        let idle=spawn("read value"); wait(idle.0.id(),false);
        let background=spawn("sleep 30 & wait"); wait(background.0.id(),true);
        let exec=spawn("exec sleep 30"); wait(exec.0.id(),true);
        assert!(has_running_program(None,false));
        assert!(!has_running_program(None,true));
        assert!(has_running_program(Some(u32::MAX),false));
    }
}
