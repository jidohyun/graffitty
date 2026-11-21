//! macOS sampler-only benchmark; excludes Godot/rendering and child CPU.
//! cargo run --release --example overhead -- 20 5 20
#[cfg(target_os = "macos")]
fn main() {
    use std::{
        process::{Command, Stdio},
        thread,
        time::{Duration, Instant},
    };
    use terminal_resource_monitor::Service;
    unsafe extern "C" {
        fn clock() -> std::ffi::c_ulong;
    }
    let args: Vec<_> = std::env::args().collect();
    let count: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(20);
    let interval: f64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5.0);
    let seconds: f64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(20.0);
    let service = Service::new().unwrap();
    let mut children = Vec::new();
    for id in 0..count {
        let child = Command::new("/bin/sleep")
            .arg("120")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        service.register(
            id,
            child.id(),
            Duration::from_secs_f64(interval.max(0.1)),
            interval > 0.0,
        );
        children.push(child);
    }
    thread::sleep(Duration::from_millis(500));
    let before: Vec<_> = (0..count)
        .map(|id| service.snapshot(id).unwrap().revision)
        .collect();
    let cpu_start = unsafe { clock() };
    let start = Instant::now();
    thread::sleep(Duration::from_secs_f64(seconds));
    let elapsed = start.elapsed().as_secs_f64();
    let cpu_seconds = unsafe { clock() }.saturating_sub(cpu_start) as f64 / 1_000_000.0;
    let mut samples = 0;
    let mut last_sample_ms = 0.0;
    for id in 0..count {
        let snapshot = service.snapshot(id).unwrap();
        samples += snapshot.revision - before[id as usize];
        last_sample_ms += snapshot.sample_ms;
    }
    println!(
        "terminals={count} interval={interval}s elapsed={elapsed:.2}s samples={samples} own_cpu={cpu_seconds:.6}s one_core_percent={:.4}% last_sweep_ms={last_sample_ms:.3}",
        cpu_seconds / elapsed * 100.0
    );
    if interval <= 0.0 {
        assert_eq!(samples, 0, "disabled collector must not sample");
    }
    drop(service);
    for mut child in children {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(not(target_os = "macos"))]
fn main() {
    eprintln!("This CPU-clock benchmark currently targets macOS.");
}
