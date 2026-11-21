//! cgroup v2 accounting. No PGID changes, no root escalation, no RSS fallback.
use super::{ProcessSnapshot, Reading};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(0);

fn membership(pid: &str) -> Result<PathBuf, String> {
    let value = fs::read_to_string(format!("/proc/{pid}/cgroup")).map_err(|e| e.to_string())?;
    let relative = value
        .lines()
        .find_map(|line| line.strip_prefix("0::"))
        .ok_or("cgroup v2 unavailable")?;
    let path = Path::new("/sys/fs/cgroup").join(relative.trim_start_matches('/'));
    path.canonicalize().map_err(|e| e.to_string())
}

/// Retain through PTY teardown. Drop only removes an empty accounting group;
/// it never kills descendants or recursively deletes user-created subgroups.
pub struct Boundary {
    path: PathBuf,
}
impl Boundary {
    pub fn prepare() -> Result<Self, String> {
        let parent = match std::env::var_os("GODOT_RESOURCE_CGROUP_PARENT") {
            Some(path) => PathBuf::from(path)
                .canonicalize()
                .map_err(|e| e.to_string())?,
            None => membership("self")?,
        };
        if !parent.join("cgroup.controllers").is_file() {
            return Err("A delegated cgroup-v2 parent is required".into());
        }
        let path = parent.join(format!(
            "godot-terminal-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path)
            .map_err(|e| format!("Cannot create terminal cgroup (delegation required): {e}"))?;
        let boundary = Self { path };
        for file in ["cpu.stat", "memory.current", "memory.peak"] {
            if !boundary.path.join(file).is_file() {
                return Err(format!(
                    "Delegated cgroup lacks {file}; enable CPU/memory controllers in its parent"
                ));
            }
        }
        Ok(boundary)
    }
    pub fn path(&self) -> &Path {
        &self.path
    }
    /// Move a process into this group. A PTY bootstrap joins before user code
    /// runs; the spawner repeating it orders the move before the first sample.
    pub fn join(&self, pid: u32) -> Result<(), String> {
        fs::write(self.path.join("cgroup.procs"), pid.to_string()).map_err(|e| e.to_string())
    }
    /// Join before exec so even the first subprocess inherits the accounting
    /// boundary. Open in the parent; the post-fork hook only writes to this FD.
    pub fn configure_command(&self, command: &mut std::process::Command) -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::process::CommandExt;
        let mut membership = fs::OpenOptions::new()
            .write(true)
            .open(self.path.join("cgroup.procs"))?;
        // SAFETY: File::write_all uses write(2), without allocation or locks.
        // cgroup.procs interprets zero as the writing process's PID.
        unsafe {
            command.pre_exec(move || membership.write_all(b"0"));
        }
        Ok(())
    }
}
impl Drop for Boundary {
    fn drop(&mut self) {
        // Browser children may finish just after their owner has been reaped.
        // Only retry removal of this group; never kill or remove descendants.
        for attempt in 0..=20 {
            match fs::remove_dir(&self.path) {
                Ok(()) => return,
                Err(error)
                    if attempt < 20
                        && matches!(
                            error.kind(),
                            std::io::ErrorKind::DirectoryNotEmpty
                                | std::io::ErrorKind::ResourceBusy
                        ) =>
                {
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(_) => return,
            }
        }
    }
}

pub(super) struct Backend {
    path: PathBuf,
}
impl Backend {
    pub const NAME: &'static str = "linux-cgroup-v2";
    pub const MEMORY: &'static str = "Cgroup memory";
    pub fn new(pid: u32) -> Result<Self, String> {
        let path = membership(&pid.to_string())?;
        let prefix = format!("godot-terminal-{}-", std::process::id());
        if !path
            .file_name()
            .is_some_and(|n| n.to_string_lossy().starts_with(&prefix))
        {
            return Err("Terminal has no private cgroup-v2 boundary; a delegated parent is required at launch".into());
        }
        Ok(Self { path })
    }
    pub fn sample(&mut self) -> Result<Reading, String> {
        let stats = fs::read_to_string(self.path.join("cpu.stat")).map_err(|e| e.to_string())?;
        let (user, system) = parse_cpu(&stats)?;
        let memory = fs::read_to_string(self.path.join("memory.current"))
            .map_err(|e| e.to_string())?
            .trim()
            .parse::<u64>()
            .map_err(|e| e.to_string())?;
        let mut result = Reading {
            user,
            system,
            memory,
            ..Reading::default()
        };
        result.kernel_peak = Some(
            fs::read_to_string(self.path.join("memory.peak"))
                .map_err(|e| e.to_string())?
                .trim()
                .parse::<u64>()
                .map_err(|e| e.to_string())?,
        );
        inventory(&self.path, &mut result.processes, 0)?;
        result.processes.sort_by_key(|p| p.pid);
        result.processes.dedup_by_key(|p| p.pid);
        Ok(result)
    }
}
fn parse_cpu(stats: &str) -> Result<(u64, u64), String> {
    let counter = |key| -> Result<u64, String> {
        stats
            .lines()
            .find_map(|line| {
                let (name, number) = line.split_once(' ')?;
                (name == key).then_some(number)
            })
            .ok_or_else(|| format!("cpu.stat lacks {key}"))?
            .parse::<u64>()
            .map(|v| v.saturating_mul(1000))
            .map_err(|e| e.to_string())
    };
    Ok((counter("user_usec")?, counter("system_usec")?))
}
fn inventory(path: &Path, out: &mut Vec<ProcessSnapshot>, depth: usize) -> Result<(), String> {
    if depth > 32 {
        return Err("Cgroup nesting exceeds inventory limit".into());
    }
    let pids = fs::read_to_string(path.join("cgroup.procs")).map_err(|e| e.to_string())?;
    for pid in pids.lines().filter_map(|p| p.parse::<u32>().ok()) {
        let stat = fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
        let Some((head, tail)) = stat.rsplit_once(')') else {
            continue;
        };
        let fields: Vec<_> = tail.split_whitespace().collect();
        if fields.len() < 20 {
            continue;
        }
        out.push(ProcessSnapshot {
            pid,
            parent: fields[1].parse().unwrap_or(0),
            start: fields[19].parse().unwrap_or(0),
            name: head
                .split_once('(')
                .map(|(_, n)| n.to_owned())
                .unwrap_or_default(),
            // Not RSS: cgroup charge cannot be fairly decomposed per process.
            memory: 0,
        });
    }
    for entry in fs::read_dir(path).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        if entry.file_type().map_err(|e| e.to_string())?.is_dir() {
            inventory(&entry.path(), out, depth + 1)?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a writable delegated cgroup-v2 parent with CPU/memory controllers"]
    fn command_boundary_accounts_for_descendants_and_is_removed_after_exit() {
        use std::process::Command;
        use std::time::{Duration, Instant};
        let boundary = Boundary::prepare().unwrap();
        let path = boundary.path().to_owned();
        let mut command = Command::new("/bin/sh");
        command.args(["-c", "sleep 1 & wait"]);
        boundary.configure_command(&mut command).unwrap();
        let mut child = command.spawn().unwrap();
        assert_eq!(membership(&child.id().to_string()).unwrap(), path);
        assert_ne!(membership("self").unwrap(), path);
        let mut backend = Backend::new(child.id()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            let reading = backend.sample().unwrap();
            if reading.processes.len() >= 2 && reading.memory > 0 {
                assert!(reading.kernel_peak.unwrap() >= reading.memory);
                break;
            }
            assert!(
                Instant::now() < deadline,
                "descendant accounting unavailable"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(child.wait().unwrap().success());
        drop(boundary);
        assert!(!path.exists(), "empty accounting boundary leaked");
    }
    #[test]
    #[ignore = "requires a writable delegated cgroup-v2 parent with CPU/memory controllers"]
    fn boundary_cleanup_waits_for_exiting_processes() {
        let boundary = Boundary::prepare().unwrap();
        let path = boundary.path().to_owned();
        let mut command = std::process::Command::new("/bin/sleep");
        command.arg("0.2");
        boundary.configure_command(&mut command).unwrap();
        let mut child = command.spawn().unwrap();
        drop(boundary);
        assert!(child.wait().unwrap().success());
        assert!(!path.exists(), "cleanup raced with process exit");
    }
    #[test]
    fn cpu_units_and_missing_fields() {
        assert_eq!(
            parse_cpu("usage_usec 7\nuser_usec 5\nsystem_usec 2\n").unwrap(),
            (5000, 2000)
        );
        assert!(parse_cpu("usage_usec 7\n").is_err());
    }
}
