use std::{
    collections::BTreeMap,
    io::Read,
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};
#[cfg(unix)]
use std::{
    io,
    os::{fd::AsRawFd, unix::process::CommandExt},
    process::Child,
};
const MAX_OUTPUT_BYTES: usize = super::MAX_SECRET_BYTES + 2;
fn command(args: &[String], env: &BTreeMap<String, String>, cwd: &Path) -> Command {
    let mut command = Command::new(&args[0]);
    command.args(&args[1..]).envs(env).current_dir(cwd);
    command
}
pub(super) fn read(
    args: &[String],
    env: &BTreeMap<String, String>,
    cwd: &Path,
    timeout: Duration,
) -> super::Result<String> {
    read_secret(args, env, cwd, timeout).ok_or_else(|| "command failed, timed out, or returned invalid/oversized output; check the helper privately".into())
}
fn parse_output(bytes: &[u8]) -> Option<String> {
    let mut value = String::from_utf8(bytes.to_vec()).ok()?;
    if value.ends_with('\n') {
        value.pop();
        if value.ends_with('\r') {
            value.pop();
        }
    }
    super::valid_value(value).ok()
}
#[cfg(unix)]
struct Probe(Child);
#[cfg(unix)]
impl Drop for Probe {
    fn drop(&mut self) {
        // setsid below isolates the probe and provider subprocesses. A hung
        // provider must not survive the timeout or hold a pipe open forever.
        unsafe {
            libc::kill(-(self.0.id() as libc::pid_t), libc::SIGKILL);
        }
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[cfg(unix)]
fn read_secret(
    args: &[String],
    env: &BTreeMap<String, String>,
    cwd: &Path,
    timeout: Duration,
) -> Option<String> {
    let started = Instant::now();
    let mut command = command(args, env, cwd);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut probe = Probe(command.spawn().ok()?);
    let mut stdout = probe.0.stdout.take()?;
    let fd = stdout.as_raw_fd();
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags == -1 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) == -1 {
            return None;
        }
    }
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    let mut eof = false;
    loop {
        if started.elapsed() >= timeout {
            return None;
        }
        let mut chunk = [0; 8192];
        loop {
            match stdout.read(&mut chunk) {
                Ok(0) => {
                    eof = true;
                    break;
                }
                Ok(count) => {
                    if bytes.len() + count > MAX_OUTPUT_BYTES {
                        return None;
                    }
                    bytes.extend_from_slice(&chunk[..count]);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return None,
            }
        }
        if let Some(status) = probe.0.try_wait().ok()? {
            if !status.success() {
                return None;
            }
            if eof {
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    parse_output(&bytes)
}

#[cfg(windows)]
fn read_secret(
    args: &[String],
    env: &BTreeMap<String, String>,
    cwd: &Path,
    timeout: Duration,
) -> Option<String> {
    use std::os::windows::process::CommandExt;
    let mut child = command(args, env, cwd)
        .creation_flags(0x08000000)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut bytes = zeroize::Zeroizing::new(Vec::new());
        let result = stdout
            .take(MAX_OUTPUT_BYTES as u64 + 1)
            .read_to_end(&mut bytes);
        let _ = sender.send(result.map(|_| bytes));
    });
    let started = Instant::now();
    let result = (|| {
        let bytes = receiver.recv_timeout(timeout).ok()?.ok()?;
        if bytes.len() > MAX_OUTPUT_BYTES {
            return None;
        }
        loop {
            if let Some(status) = child.try_wait().ok()? {
                if !status.success() {
                    return None;
                }
                break;
            }
            if started.elapsed() >= timeout {
                return None;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        parse_output(&bytes)
    })();
    if result.is_none() {
        let _ = Command::new("taskkill.exe")
            .args(["/PID", &child.id().to_string(), "/T", "/F"])
            .creation_flags(0x08000000)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let _ = child.kill();
    }
    let _ = child.wait();
    result
}
