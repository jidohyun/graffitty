//! Native workload accounting. No Godot calls or UI work on the sampler thread.
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, mpsc};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos::Backend;
// Its tests also run on macOS. Windows has no `pre_exec`, which the module uses.
#[cfg(any(target_os = "linux", all(test, unix)))]
pub mod linux;
#[cfg(target_os = "linux")]
use linux::Backend;
#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
mod platform;
#[cfg(not(any(target_os = "macos", target_os = "linux", windows)))]
use platform::Backend;

#[cfg(windows)]
pub mod windows;
#[cfg(windows)]
use windows::Backend;

#[derive(Clone, Debug, Default)]
pub struct ProcessSnapshot {
    pub pid: u32,
    pub parent: u32,
    pub start: u64,
    pub name: String,
    pub memory: u64,
}

#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub revision: u64,
    pub root_pid: u32,
    pub status: String,
    pub backend: String,
    pub memory_label: String,
    pub error: String,
    pub cpu_percent: f64,
    pub cpu_valid: bool,
    pub cpu_user_seconds: f64,
    pub cpu_system_seconds: f64,
    pub memory_current: u64,
    pub memory_peak_observed: u64,
    pub memory_peak_kernel: Option<u64>,
    pub epoch: u64,
    pub coverage_gap: bool,
    pub sample_ms: f64,
    pub sampled_at: Option<Instant>,
    pub monitoring_since: Option<Instant>,
    pub processes: Vec<ProcessSnapshot>,
}

#[derive(Default)]
pub(crate) struct Reading {
    user: u64,
    system: u64,
    memory: u64,
    kernel_peak: Option<u64>,
    processes: Vec<ProcessSnapshot>,
    gap: bool,
}

enum Command {
    Add(u64, u32, Duration, bool),
    Remove(u64),
    Pause(u64, bool),
    Reset(u64),
    Interval(u64, Duration),
    Stop,
}

/// What 100% means in `Snapshot::cpu_percent`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CpuScale {
    /// Every logical CPU this process may use, as in Windows Task Manager.
    #[default]
    AllCores,
    /// One fully busy logical CPU, as in top and Activity Monitor: a process
    /// tree keeping four of them busy reads 400%.
    OneCore,
}

/// One service per terminal host, one sleeping worker shared by all terminals.
pub struct Service {
    tx: mpsc::Sender<Command>,
    snapshots: Arc<Mutex<HashMap<u64, Snapshot>>>,
    worker: Option<JoinHandle<()>>,
    all_cores_scale: AtomicBool,
}
impl Service {
    pub fn new() -> std::io::Result<Self> {
        let (tx, rx) = mpsc::channel();
        let snapshots = Arc::new(Mutex::new(HashMap::new()));
        let shared = snapshots.clone();
        let worker = std::thread::Builder::new()
            .name("terminal-resources".into())
            .spawn(move || run(rx, shared))?;
        Ok(Self {
            tx,
            snapshots,
            worker: Some(worker),
            all_cores_scale: AtomicBool::new(true),
        })
    }
    /// Applies to every snapshot read afterwards, including earlier samples.
    pub fn set_cpu_scale(&self, scale: CpuScale) {
        self.all_cores_scale
            .store(scale == CpuScale::AllCores, Ordering::Relaxed);
    }
    pub fn register(&self, id: u64, pid: u32, interval: Duration, enabled: bool) {
        let _ = self
            .tx
            .send(Command::Add(id, pid, sane_interval(interval), enabled));
    }
    pub fn remove(&self, id: u64) {
        let _ = self.tx.send(Command::Remove(id));
    }
    pub fn pause(&self, id: u64) {
        let _ = self.tx.send(Command::Pause(id, true));
    }
    pub fn resume(&self, id: u64) {
        let _ = self.tx.send(Command::Pause(id, false));
    }
    pub fn reset(&self, id: u64) {
        let _ = self.tx.send(Command::Reset(id));
    }
    pub fn interval(&self, id: u64, value: Duration) {
        let _ = self.tx.send(Command::Interval(id, sane_interval(value)));
    }
    pub fn snapshot(&self, id: u64) -> Option<Snapshot> {
        let mut snapshot = self.snapshots.lock().ok()?.get(&id).cloned()?;
        if self.all_cores_scale.load(Ordering::Relaxed) {
            snapshot.cpu_percent /= logical_cpus();
        }
        Some(snapshot)
    }
}
/// Logical CPUs this process may run on; affinity and cgroup quotas count.
fn logical_cpus() -> f64 {
    static CPUS: OnceLock<f64> = OnceLock::new();
    *CPUS.get_or_init(|| std::thread::available_parallelism().map_or(1, |cpus| cpus.get()) as f64)
}
impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.tx.send(Command::Stop);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
fn sane_interval(value: Duration) -> Duration {
    value.clamp(Duration::from_millis(100), Duration::from_secs(3600))
}

struct Workload {
    backend: Result<Backend, String>,
    snapshot: Snapshot,
    interval: Duration,
    due: Instant,
    paused: bool,
    previous: Option<(u64, u64, Instant)>,
}
impl Workload {
    fn new(pid: u32, interval: Duration, enabled: bool) -> Self {
        Self {
            backend: Backend::new(pid),
            snapshot: Snapshot {
                root_pid: pid,
                backend: Backend::NAME.into(),
                memory_label: Backend::MEMORY.into(),
                epoch: 1,
                status: if enabled { "starting" } else { "paused" }.into(),
                monitoring_since: Some(Instant::now()),
                ..Snapshot::default()
            },
            interval,
            due: Instant::now(),
            paused: !enabled,
            previous: None,
        }
    }
    fn sample(&mut self) {
        let started = Instant::now();
        let reading = match &mut self.backend {
            Ok(b) => b.sample(),
            Err(e) => Err(e.clone()),
        };
        let now = Instant::now();
        self.snapshot.revision += 1;
        self.snapshot.sample_ms = started.elapsed().as_secs_f64() * 1000.0;
        self.snapshot.cpu_valid = false;
        match reading {
            Ok(r) => {
                self.snapshot.error.clear();
                self.snapshot.status = if r.processes.is_empty() {
                    "exited"
                } else {
                    "running"
                }
                .into();
                self.snapshot.coverage_gap |= r.gap;
                if let Some((user, system, at)) = self.previous {
                    if r.user >= user && r.system >= system && !r.gap {
                        let du = (r.user - user) as f64 / 1e9;
                        let ds = (r.system - system) as f64 / 1e9;
                        self.snapshot.cpu_user_seconds += du;
                        self.snapshot.cpu_system_seconds += ds;
                        self.snapshot.cpu_percent =
                            (du + ds) / now.duration_since(at).as_secs_f64() * 100.0;
                        self.snapshot.cpu_valid = true;
                    } else {
                        // Loss of an orphan's counters is not negative CPU. Rebaseline
                        // and surface a gap instead of silently manufacturing totals.
                        self.snapshot.coverage_gap = true;
                    }
                }
                self.previous = Some((r.user, r.system, now));
                self.snapshot.memory_current = r.memory;
                self.snapshot.memory_peak_kernel = r.kernel_peak;
                self.snapshot.memory_peak_observed =
                    self.snapshot.memory_peak_observed.max(r.memory);
                self.snapshot.processes = r.processes;
                self.snapshot.sampled_at = Some(now);
            }
            Err(e) => {
                self.snapshot.status = "unavailable".into();
                self.snapshot.error = e;
                self.snapshot.coverage_gap = true;
                self.previous = None;
            }
        }
        self.due = now + self.interval;
    }
}
fn run(rx: mpsc::Receiver<Command>, shared: Arc<Mutex<HashMap<u64, Snapshot>>>) {
    let mut workloads: HashMap<u64, Workload> = HashMap::new();
    loop {
        let now = Instant::now();
        for (id, w) in &mut workloads {
            if !w.paused && w.due <= now {
                w.sample();
                if let Ok(mut out) = shared.lock() {
                    out.insert(*id, w.snapshot.clone());
                }
            }
        }
        let wait = workloads
            .values()
            .filter(|w| !w.paused)
            .map(|w| w.due.saturating_duration_since(Instant::now()))
            .min();
        let command = match wait {
            Some(t) => match rx.recv_timeout(t) {
                Ok(c) => c,
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(_) => break,
            },
            None => match rx.recv() {
                Ok(c) => c,
                Err(_) => break,
            },
        };
        match command {
            Command::Stop => break,
            Command::Add(id, pid, interval, enabled) => {
                let w = Workload::new(pid, interval, enabled);
                if let Ok(mut out) = shared.lock() {
                    out.insert(id, w.snapshot.clone());
                }
                workloads.insert(id, w);
            }
            Command::Remove(id) => {
                workloads.remove(&id);
                if let Ok(mut out) = shared.lock() {
                    out.remove(&id);
                }
            }
            Command::Pause(id, pause) => {
                if let Some(w) = workloads.get_mut(&id)
                    && w.paused != pause
                {
                    w.paused = pause;
                    w.previous = None;
                    w.snapshot.cpu_valid = false;
                    w.snapshot.coverage_gap = true;
                    w.snapshot.status = if pause { "paused" } else { "starting" }.into();
                    if !pause {
                        w.snapshot.epoch += 1;
                        w.due = Instant::now();
                    }
                    w.snapshot.revision += 1;
                    if let Ok(mut out) = shared.lock() {
                        out.insert(id, w.snapshot.clone());
                    }
                }
            }
            Command::Reset(id) => {
                if let Some(w) = workloads.get_mut(&id) {
                    let epoch = w.snapshot.epoch + 1;
                    // Keep sticky identity; reset history, not workload membership.
                    w.snapshot = Snapshot {
                        root_pid: w.snapshot.root_pid,
                        backend: Backend::NAME.into(),
                        memory_label: Backend::MEMORY.into(),
                        epoch,
                        revision: w.snapshot.revision + 1,
                        monitoring_since: Some(Instant::now()),
                        status: if w.paused { "paused" } else { "starting" }.into(),
                        ..Snapshot::default()
                    };
                    w.previous = None;
                    w.due = Instant::now();
                    if let Ok(mut out) = shared.lock() {
                        out.insert(id, w.snapshot.clone());
                    }
                }
            }
            Command::Interval(id, interval) => {
                if let Some(w) = workloads.get_mut(&id) {
                    w.interval = interval;
                    w.due = Instant::now() + interval;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn interval_is_bounded() {
        assert_eq!(sane_interval(Duration::ZERO), Duration::from_millis(100));
        assert_eq!(
            sane_interval(Duration::from_secs(5)),
            Duration::from_secs(5)
        );
    }
    #[test]
    fn worker_can_stop_without_any_workload() {
        drop(Service::new().unwrap());
    }
    #[test]
    fn all_cores_scale_divides_cpu_by_the_available_logical_cpus() {
        let service = Service::new().unwrap();
        service.snapshots.lock().unwrap().insert(
            7,
            Snapshot {
                cpu_percent: 400.0,
                ..Snapshot::default()
            },
        );
        let cpus = std::thread::available_parallelism().unwrap().get() as f64;
        assert_eq!(service.snapshot(7).unwrap().cpu_percent, 400.0 / cpus);
        service.set_cpu_scale(CpuScale::OneCore);
        assert_eq!(service.snapshot(7).unwrap().cpu_percent, 400.0);
        service.set_cpu_scale(CpuScale::AllCores);
        assert_eq!(service.snapshot(7).unwrap().cpu_percent, 400.0 / cpus);
    }
}
