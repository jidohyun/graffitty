#![cfg(target_os = "macos")]
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use terminal_resource_monitor::{Service, Snapshot};

struct Fixture {
    child: Child,
    output: BufReader<std::process::ChildStdout>,
}
impl Fixture {
    fn new() -> Self {
        let mut child = Command::new("python3")
            .args(["-u", "-c", include_str!("workload.py")])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        let mut f = Self { child, output };
        assert_eq!(f.line(), "ready");
        f
    }
    fn line(&mut self) -> String {
        let mut line = String::new();
        self.output.read_line(&mut line).unwrap();
        line.trim().into()
    }
    fn command(&mut self, command: &str) -> String {
        writeln!(self.child.stdin.as_mut().unwrap(), "{command}").unwrap();
        self.line()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = writeln!(self.child.stdin.as_mut().unwrap(), "quit");
        let _ = self.child.wait();
    }
}
fn wait(service: &Service, predicate: impl Fn(&Snapshot) -> bool) -> Snapshot {
    let deadline = Instant::now() + Duration::from_secs(8);
    loop {
        if let Some(s) = service.snapshot(1) {
            if predicate(&s) {
                return s;
            }
            assert!(Instant::now() < deadline, "snapshot timeout: {s:?}");
        } else {
            assert!(Instant::now() < deadline);
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[test]
fn darwin_cpu_memory_pause_reset_and_sticky_membership() {
    let mut f = Fixture::new();
    let service = Service::new().unwrap();
    service.register(1, f.child.id(), Duration::from_millis(100), true);
    let initial = wait(&service, |s| s.cpu_valid);
    assert!(initial.memory_current > 0);
    f.command("burn");
    let self_cpu = wait(&service, |s| {
        s.cpu_user_seconds + s.cpu_system_seconds >= 0.27
    });
    // A 0.3s process_time burn validates Mach tick conversion on Apple Silicon.
    assert!(
        self_cpu.cpu_user_seconds + self_cpu.cpu_system_seconds < 1.2,
        "{self_cpu:?}"
    );

    // Slow discovery intentionally misses nested children entirely. Their
    // reaped CPU must still reach the tracked root's ri_child counters.
    service.interval(1, Duration::from_secs(2));
    let before = self_cpu.cpu_user_seconds + self_cpu.cpu_system_seconds;
    f.command("nested");
    let nested = wait(&service, |s| {
        s.cpu_user_seconds + s.cpu_system_seconds > before + 0.27
    });
    let before = nested.cpu_user_seconds + nested.cpu_system_seconds;
    f.command("parallel");
    wait(&service, |s| {
        s.cpu_user_seconds + s.cpu_system_seconds > before + 0.8
    });

    service.interval(1, Duration::from_millis(100));
    let before = service.snapshot(1).unwrap();
    f.command("frontier");
    let after = wait(&service, |s| s.revision > before.revision + 9);
    let delta = after.cpu_user_seconds + after.cpu_system_seconds
        - before.cpu_user_seconds
        - before.cpu_system_seconds;
    assert!(
        (0.27..0.8).contains(&delta),
        "CPU must transfer without duplication: {delta}, {after:?}"
    );
    f.command("memory");
    let memory = wait(&service, |s| {
        s.memory_current > initial.memory_current + 24 * 1024 * 1024
    });
    let detached: u32 = f.command("detach").parse().unwrap();
    wait(&service, |s| s.processes.iter().any(|p| p.pid == detached));
    let orphan: u32 = f.command("orphan").parse().unwrap();
    wait(&service, |s| {
        s.processes.iter().any(|p| p.pid == orphan && p.parent != 1)
    });
    wait(&service, |s| {
        s.processes.iter().any(|p| p.pid == orphan && p.parent == 1)
    });

    service.pause(1);
    let paused = wait(&service, |s| s.status == "paused");
    std::thread::sleep(Duration::from_millis(350));
    assert_eq!(service.snapshot(1).unwrap().revision, paused.revision);
    f.command("burn");
    service.resume(1);
    let resumed = wait(&service, |s| s.epoch > paused.epoch && s.cpu_valid);
    assert!(resumed.coverage_gap);
    assert!(resumed.memory_peak_observed >= memory.memory_current);
    service.reset(1);
    let reset = wait(&service, |s| s.epoch > resumed.epoch && s.cpu_valid);
    assert!(reset.cpu_user_seconds + reset.cpu_system_seconds < 0.2);
    service.remove(1);
    let deadline = Instant::now() + Duration::from_secs(1);
    while service.snapshot(1).is_some() {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
}
