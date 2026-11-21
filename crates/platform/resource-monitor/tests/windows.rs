#![cfg(windows)]
use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use terminal_resource_monitor::{Service, Snapshot, windows::Boundary};

#[test]
#[ignore = "subprocess fixture"]
fn detached_leaf() {
    std::thread::sleep(Duration::from_secs(4));
}

#[test]
#[ignore = "subprocess fixture"]
fn detached_workload() {
    assert!(std::env::args().any(|arg| arg == "한글 path\\\"quoted\"\\"));
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "detached_leaf", "--ignored"])
        .spawn().unwrap();
    assert!(child.wait().unwrap().success());
}

#[test]
fn detached_process_accounts_for_descendants_and_quotes_arguments() {
    use std::ffi::OsStr;
    use terminal_resource_monitor::windows::Process;
    let executable = std::env::current_exe().unwrap();
    let mut child = Process::spawn_detached(executable.as_os_str(), [
        "--exact", "detached_workload", "--ignored", "--skip", "한글 path\\\"quoted\"\\",
    ].map(OsStr::new)).unwrap();
    let service = Service::new().unwrap();
    service.register(77, child.id(), Duration::from_millis(100), true);
    snapshot(&service, 77, |s| s.processes.len() >= 2 && s.memory_current > 0);
    assert!(child.wait().unwrap().success());
    assert!(child.try_wait().unwrap().unwrap().success());
    child.kill().unwrap(); // Reaping an already exited process is harmless.
}

struct Terminal {
    child: Box<dyn Child + Send + Sync>,
    master: Option<Box<dyn MasterPty>>,
    reader: Option<std::thread::JoinHandle<()>>,
    _boundary: Boundary,
}
impl Terminal {
    fn spawn(dir: &Path, mode: &str) -> Self {
        let mut boundary = Boundary::prepare().unwrap();
        let pair = native_pty_system().openpty(PtySize::default()).unwrap();
        let mut cmd = CommandBuilder::new(std::env::current_exe().unwrap());
        cmd.args(["--exact", "workload", "--ignored", "--nocapture"]);
        cmd.env("RESOURCE_TEST_DIR", dir);
        cmd.env("RESOURCE_TEST_MODE", mode);
        cmd.set_job(boundary.handle());
        let child = pair.slave.spawn_command(cmd).unwrap();
        boundary.register(child.process_id().unwrap());
        drop(pair.slave);
        let mut writer = pair.master.take_writer().unwrap();
        let mut reader = pair.master.try_clone_reader().unwrap();
        let reader = std::thread::spawn(move || {
            let mut bytes = [0; 4096];
            let mut tail = Vec::new();
            while let Ok(n) = reader.read(&mut bytes) {
                if n == 0 {
                    break;
                }
                tail.extend_from_slice(&bytes[..n]);
                if tail.windows(4).any(|b| b == b"\x1b[6n") {
                    writer.write_all(b"\x1b[1;1R").unwrap();
                    tail.clear();
                }
                if tail.len() > 3 {
                    tail.drain(..tail.len() - 3);
                }
            }
        });
        Self {
            child,
            master: Some(pair.master),
            reader: Some(reader),
            _boundary: boundary,
        }
    }
    fn pid(&self) -> u32 {
        self.child.process_id().unwrap()
    }
}
impl Drop for Terminal {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        drop(self.master.take());
        let _ = self.reader.take().unwrap().join();
    }
}
#[track_caller]
fn wait(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out");
        std::thread::sleep(Duration::from_millis(30));
    }
}
#[track_caller]
fn snapshot(service: &Service, id: u64, predicate: impl Fn(&Snapshot) -> bool) -> Snapshot {
    let mut last = None;
    wait(|| {
        last = service.snapshot(id);
        if let Some(s) = &last {
            assert_ne!(s.status, "unavailable", "{}", s.error);
            predicate(s)
        } else {
            false
        }
    });
    last.unwrap()
}
fn mark(dir: &Path, name: &str) {
    std::fs::write(dir.join(name), b"ready").unwrap();
}

#[test]
#[ignore = "subprocess fixture"]
fn workload() {
    let dir = PathBuf::from(std::env::var_os("RESOURCE_TEST_DIR").unwrap());
    let mode = std::env::var("RESOURCE_TEST_MODE").unwrap();
    if mode == "nested" {
        let inner_dir = dir.join("inner");
        std::fs::create_dir_all(&inner_dir).unwrap();
        let mut inner = Terminal::spawn(&inner_dir, "busy");
        let service = Service::new().unwrap();
        service.register(1, inner.pid(), Duration::from_millis(100), true);
        snapshot(&service, 1, |s| s.memory_current > 60 * 1024 * 1024);
        mark(&dir, "nested-ready");
        wait(|| inner.child.try_wait().unwrap().is_some());
        snapshot(&service, 1, |s| s.status == "exited");
        mark(&dir, "nested-reaped");
        wait(|| dir.join("exit").exists());
        return;
    }
    if mode == "busy" {
        let mut memory = vec![0u8; 64 * 1024 * 1024];
        for page in memory.chunks_mut(4096) {
            page[0] = 42;
        }
        mark(&dir, "allocated");
        let start = Instant::now();
        while start.elapsed() < Duration::from_millis(650) {
            std::hint::black_box(13u64.wrapping_mul(17));
        }
        wait(|| dir.join("release").exists());
        drop(memory);
        mark(&dir, "released");
        wait(|| dir.join("finish").exists());
        return;
    }
    mark(&dir, "ready");
    wait(|| dir.join("spawn").exists());
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "workload", "--ignored", "--nocapture"])
        .env("RESOURCE_TEST_MODE", "busy")
        .spawn()
        .unwrap();
    if mode == "orphan" {
        return;
    }
    child.wait().unwrap();
    mark(&dir, "reaped");
    wait(|| dir.join("exit").exists());
}

#[test]
fn conpty_job_accounting() {
    let dir = std::env::temp_dir().join(format!("terminal-job-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let other_dir = dir.join("other");
    std::fs::create_dir_all(&other_dir).unwrap();
    let terminal = Terminal::spawn(&dir, "root");
    let other = Terminal::spawn(&other_dir, "root");
    let service = Service::new().unwrap();
    service.register(1, terminal.pid(), Duration::from_millis(100), true);
    service.register(2, other.pid(), Duration::from_millis(100), true);
    wait(|| dir.join("ready").exists());
    assert!(!terminal._boundary.has_children().unwrap());
    let initial = snapshot(&service, 1, |s| s.cpu_valid);
    assert_eq!(initial.backend, "windows-job-object");
    assert!(initial.memory_current > 0);
    mark(&dir, "spawn");
    wait(|| dir.join("allocated").exists());
    assert!(terminal._boundary.has_children().unwrap());
    let allocated = snapshot(&service, 1, |s| {
        s.memory_current > initial.memory_current + 50 * 1024 * 1024
    });
    assert!(allocated.processes.len() >= 2);
    let isolated = snapshot(&service, 2, |s| s.cpu_valid);
    assert!(isolated.memory_current < allocated.memory_current / 2);
    assert!(
        !isolated
            .processes
            .iter()
            .any(|p| allocated.processes.iter().any(|q| p.pid == q.pid))
    );
    let busy = snapshot(&service, 1, |s| {
        s.cpu_user_seconds + s.cpu_system_seconds > 0.3
    });
    mark(&dir, "release");
    wait(|| dir.join("released").exists());
    let released = snapshot(&service, 1, |s| {
        s.memory_current + 40 * 1024 * 1024 < allocated.memory_current
    });
    assert!(released.memory_peak_kernel.unwrap() >= allocated.memory_current);
    mark(&dir, "finish");
    wait(|| dir.join("reaped").exists());
    assert!(!terminal._boundary.has_children().unwrap());
    let reaped = snapshot(&service, 1, |s| s.processes.len() == 1);
    assert!(
        reaped.cpu_user_seconds + reaped.cpu_system_seconds
            >= busy.cpu_user_seconds + busy.cpu_system_seconds
    );
    assert!(!reaped.coverage_gap);
    service.pause(1);
    let paused = snapshot(&service, 1, |s| s.status == "paused");
    std::thread::sleep(Duration::from_millis(250));
    assert_eq!(service.snapshot(1).unwrap().revision, paused.revision);
    service.resume(1);
    snapshot(&service, 1, |s| s.epoch > paused.epoch && s.cpu_valid);
    service.reset(1);
    let reset = snapshot(&service, 1, |s| {
        s.epoch > paused.epoch + 1 && s.status == "running"
    });
    assert_eq!(reset.cpu_user_seconds, 0.0);
    assert!(reset.memory_peak_kernel.unwrap() >= allocated.memory_current);
    mark(&dir, "exit");
    let exited = snapshot(&service, 1, |s| s.status == "exited");
    // Windows may retain a small job commit charge after the last process exits.
    // Preserve the kernel reading instead of fabricating zero.
    assert!(exited.memory_current < initial.memory_current);
    service.remove(1);
    wait(|| service.snapshot(1).is_none());
    drop(service);
    drop(terminal);
    drop(other);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn job_retains_descendant_after_root_exits() {
    let dir = std::env::temp_dir().join(format!("terminal-job-orphan-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let mut terminal = Terminal::spawn(&dir, "orphan");
    // Root may exit before monitor registration. The retained job still owns
    // descendant accounting; discovery never depends on reopening the root PID.
    mark(&dir, "spawn");
    wait(|| terminal.child.try_wait().unwrap().is_some());
    wait(|| dir.join("allocated").exists());
    assert!(terminal._boundary.has_children().unwrap());
    let service = Service::new().unwrap();
    service.register(1, terminal.pid(), Duration::from_millis(100), true);
    let s = snapshot(&service, 1, |s| s.status == "running");
    assert!(s.memory_current > 60 * 1024 * 1024);
    assert!(!s.processes.iter().any(|p| p.pid == terminal.pid()));
    mark(&dir, "release");
    mark(&dir, "finish");
    snapshot(&service, 1, |s| s.status == "exited");
    drop(service);
    drop(terminal);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn nested_job_inherits_outer_accounting() {
    let dir = std::env::temp_dir().join(format!("terminal-job-nested-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let terminal = Terminal::spawn(&dir, "nested");
    let service = Service::new().unwrap();
    service.register(1, terminal.pid(), Duration::from_millis(100), true);
    wait(|| dir.join("nested-ready").exists());
    let allocated = snapshot(&service, 1, |s| s.memory_current > 60 * 1024 * 1024);
    assert!(allocated.processes.len() >= 2);
    mark(&dir.join("inner"), "release");
    mark(&dir.join("inner"), "finish");
    wait(|| dir.join("nested-reaped").exists());
    let released = snapshot(&service, 1, |s| {
        s.memory_current + 40 * 1024 * 1024 < allocated.memory_current
    });
    assert!(released.memory_peak_kernel.unwrap() >= allocated.memory_current);
    // Removing a monitor closes only its reference; the root is still alive.
    service.remove(1);
    wait(|| service.snapshot(1).is_none());
    drop(service);
    let mut terminal = terminal;
    assert!(terminal.child.try_wait().unwrap().is_none());
    mark(&dir, "exit");
    wait(|| terminal.child.try_wait().unwrap().is_some());
    drop(terminal);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn arbitrary_pid_is_not_attached_after_spawn() {
    let service = Service::new().unwrap();
    service.register(1, std::process::id(), Duration::from_millis(100), true);
    wait(|| {
        service
            .snapshot(1)
            .is_some_and(|s| s.status == "unavailable")
    });
    assert!(
        service
            .snapshot(1)
            .unwrap()
            .error
            .contains("process creation")
    );
}
