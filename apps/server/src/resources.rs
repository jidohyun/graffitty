//! Wire representation of the shared native worker's cached process samples.
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use terminal_resource_monitor::Snapshot;

/// Chromium samples share the server's one native worker with terminal samples.
/// Surface IDs are allocated from the same server counter, so keys cannot alias.
pub struct ChromiumMonitor {
    service: Arc<terminal_resource_monitor::Service>,
    id: u64,
    pid: u32,
    last_request: Option<Instant>,
}
impl ChromiumMonitor {
    pub fn new(service: Arc<terminal_resource_monitor::Service>, id: u64, pid: u32) -> Self {
        Self {
            service,
            id,
            pid,
            last_request: None,
        }
    }
    pub fn request(&mut self, args: &Value) -> Result<Value, &'static str> {
        let enabled = match args.get("enabled") {
            None => true,
            Some(value) => value
                .as_bool()
                .ok_or("Chromium resource enabled must be a boolean")?,
        };
        if !enabled {
            self.disable();
            return Ok(snapshot(Snapshot {
                root_pid: self.pid,
                status: "paused".into(),
                ..Snapshot::default()
            }));
        }
        if self.last_request.is_none() {
            self.service
                .register(self.id, self.pid, Duration::from_secs(1), true);
        }
        self.last_request = Some(Instant::now());
        Ok(snapshot(self.service.snapshot(self.id).unwrap_or_else(
            || Snapshot {
                root_pid: self.pid,
                status: "starting".into(),
                ..Snapshot::default()
            },
        )))
    }
    pub fn expire_idle(&mut self) {
        self.expire_at(Instant::now());
    }
    fn expire_at(&mut self, now: Instant) {
        // A disconnected frontend cannot keep an otherwise unused chromium monitored.
        // Active Monitors request once per second; the lease allows slow clients.
        if self
            .last_request
            .is_some_and(|at| now.saturating_duration_since(at) > Duration::from_secs(10))
        {
            self.disable();
        }
    }
    fn disable(&mut self) {
        if self.last_request.take().is_some() {
            self.service.remove(self.id);
        }
    }
}
impl Drop for ChromiumMonitor {
    fn drop(&mut self) {
        self.disable();
    }
}

pub fn snapshot(s: Snapshot) -> Value {
    let processes: Vec<Value> = s
        .processes
        .iter()
        .map(|p| {
            json!({
                "pid": p.pid, "parent_pid": p.parent, "start_identity": p.start,
                "name": p.name, "memory_current": p.memory,
            })
        })
        .collect();
    json!({
        "revision": s.revision, "root_pid": s.root_pid, "status": s.status,
        "backend": s.backend, "memory_label": s.memory_label, "error": s.error,
        "cpu_percent": s.cpu_percent, "cpu_valid": s.cpu_valid,
        "cpu_time_user": s.cpu_user_seconds, "cpu_time_system": s.cpu_system_seconds,
        "cpu_time": s.cpu_user_seconds + s.cpu_system_seconds,
        "memory_current": s.memory_current, "memory_peak_observed": s.memory_peak_observed,
        "memory_peak_kernel": s.memory_peak_kernel, "memory_peak_upper_bound": null,
        "epoch": s.epoch, "coverage_gap": s.coverage_gap, "sample_ms": s.sample_ms,
        "sample_age_seconds": s.sampled_at.map(|t| t.elapsed().as_secs_f64()).unwrap_or(-1.0),
        "monitoring_seconds": s.monitoring_since.map(|t| t.elapsed().as_secs_f64()).unwrap_or(0.0),
        "process_count": processes.len(), "processes": processes,
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{
        os::unix::process::CommandExt,
        process::{Child, Command, Stdio},
        thread,
    };

    struct ProcessTree(Child);
    impl Drop for ProcessTree {
        fn drop(&mut self) {
            // The fixture owns this fresh process group, including its sleep child.
            unsafe {
                libc::kill(-(self.0.id() as i32), libc::SIGTERM);
            }
            let _ = self.0.wait();
        }
    }
    fn eventually(mut condition: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(8);
        while !condition() {
            assert!(
                Instant::now() < deadline,
                "Resource worker did not publish the expected sample"
            );
            thread::sleep(Duration::from_millis(25));
        }
    }

    #[test]
    #[cfg_attr(target_os = "linux", ignore = "requires a writable delegated cgroup-v2 parent with CPU/memory controllers")]
    fn chromium_monitor_samples_real_descendants_and_releases_shared_worker_entries() {
        #[cfg(target_os = "linux")]
        let boundary = terminal_resource_monitor::linux::Boundary::prepare().unwrap();
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 30 & wait"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0);
        // Match the browser launcher: Linux accounting requires a private
        // boundary inherited by the shell and every descendant before exec.
        #[cfg(target_os = "linux")]
        boundary.configure_command(&mut command).unwrap();
        let child = ProcessTree(command.spawn().unwrap());
        let service = Arc::new(terminal_resource_monitor::Service::new().unwrap());
        service.register(1, std::process::id(), Duration::from_secs(1), true);
        let mut chromium = ChromiumMonitor::new(Arc::clone(&service), 2, child.0.id());
        assert!(chromium.request(&json!({"enabled":"yes"})).is_err());
        assert!(chromium.last_request.is_none());
        assert_eq!(
            chromium.request(&json!({})).unwrap()["root_pid"],
            child.0.id()
        );
        eventually(|| {
            let value = chromium.request(&json!({})).unwrap();
            value["status"] == "running"
                && value["cpu_valid"] == true
                && value["process_count"].as_u64().unwrap_or(0) >= 2
                && value["memory_current"].as_u64().unwrap_or(0) > 0
        });
        let sample = chromium.request(&json!({})).unwrap();
        assert!(
            sample["processes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|p| p["pid"] == child.0.id())
        );
        assert!(
            sample["processes"]
                .as_array()
                .unwrap()
                .iter()
                .any(|p| p["parent_pid"] == child.0.id())
        );
        assert_eq!(
            service.snapshot(1).unwrap().root_pid,
            std::process::id(),
            "Chromium ID must not replace the terminal sample"
        );
        assert_eq!(
            chromium.request(&json!({"enabled":false})).unwrap()["status"],
            "paused"
        );
        eventually(|| service.snapshot(2).is_none());
        chromium.request(&json!({})).unwrap();
        eventually(|| service.snapshot(2).is_some());
        chromium.expire_at(Instant::now() + Duration::from_secs(11));
        eventually(|| service.snapshot(2).is_none());
        chromium.request(&json!({})).unwrap();
        eventually(|| service.snapshot(2).is_some());
        drop(chromium);
        eventually(|| service.snapshot(2).is_none());
        assert!(
            service.snapshot(1).is_some(),
            "Removing a chromium must retain terminal monitoring"
        );
    }
}
