use super::{ProcessSnapshot, Reading};
use std::collections::{HashMap, HashSet};

#[repr(C)]
#[derive(Clone, Copy)]
struct Usage {
    start: u64,
    user: u64,
    system: u64,
    memory: u64,
    peak: u64,
    parent: u32,
    zombie: u32,
    name: [u8; 64],
}
unsafe extern "C" {
    fn trm_usage(pid: i32, out: *mut Usage) -> i32;
    fn trm_children(pid: i32, out: *mut i32, bytes: i32) -> i32;
}
fn usage(pid: u32) -> Result<Usage, i32> {
    let mut out: Usage = unsafe { std::mem::zeroed() };
    let result = unsafe { trm_usage(pid as i32, &mut out) };
    if result == 0 { Ok(out) } else { Err(result) }
}
fn children(pid: u32) -> Result<Vec<u32>, String> {
    // Unlike proc_listpids, proc_listchildpids returns a PID COUNT, while
    // its buffer size argument is bytes. Start small; no whole-system sizing.
    let mut pids = vec![0i32; 64];
    // Spare room covers ordinary forks between count and read. Retry growth,
    // bounded to avoid a fork storm starving every other terminal's sampling.
    for _ in 0..3 {
        let capacity = (pids.len() * 4) as i32;
        let n = unsafe { trm_children(pid as i32, pids.as_mut_ptr(), capacity) };
        if n < 0 {
            return Err(format!("Cannot discover children of {pid}"));
        }
        if (n as usize) < pids.len() {
            return Ok(pids[..n as usize]
                .iter()
                .filter(|p| **p > 0)
                .map(|p| *p as u32)
                .collect());
        }
        pids.resize(pids.len() * 2, 0);
    }
    Err("Process discovery changed too quickly; sample deferred".into())
}

pub(super) struct Backend {
    // Only live/discoverable identities are stored; exited entries are pruned.
    known: HashMap<u32, u64>,
}
impl Backend {
    pub const NAME: &'static str = "darwin-rusage-v4";
    pub const MEMORY: &'static str = "Physical footprint";
    pub fn new(pid: u32) -> Result<Self, String> {
        if pid == 0 || pid > i32::MAX as u32 {
            return Err("Invalid PTY child PID".into());
        }
        let root = usage(pid).map_err(|e| format!("Cannot attach PID {pid}: OS error {e}"))?;
        Ok(Self {
            known: HashMap::from([(pid, root.start)]),
        })
    }
    pub fn sample(&mut self) -> Result<Reading, String> {
        let mut gap = false;
        // Traverse from every sticky member, including already detached parents.
        let mut todo: Vec<u32> = self.known.keys().copied().collect();
        let mut visited = HashSet::new();
        while let Some(pid) = todo.pop() {
            if !visited.insert(pid) {
                continue;
            }
            match usage(pid) {
                Ok(u) if self.known.get(&pid).is_some_and(|s| *s == u.start) => {
                    for child in children(pid)? {
                        if let Ok(c) = usage(child)
                            && c.parent == pid
                            && c.start >= u.start
                        {
                            self.known.insert(child, c.start);
                            todo.push(child);
                        }
                    }
                }
                Ok(_) => {
                    self.known.remove(&pid);
                    gap = true;
                }
                Err(3) => {
                    self.known.remove(&pid);
                } // ESRCH: reaped, not permission failure.
                Err(e) => return Err(format!("PID {pid}: rusage unavailable (OS error {e})")),
            }
        }
        // A reap during the sweep can move counters from child to parent.
        // Verify the frontier before accepting it; retry a bounded number of times.
        for _ in 0..3 {
            let mut readings = Vec::new();
            let mut disappeared = false;
            for (pid, start) in self.known.clone() {
                match usage(pid) {
                    Ok(u) if u.start == start => readings.push((pid, u)),
                    Ok(_) => {
                        self.known.remove(&pid);
                        disappeared = true;
                        gap = true;
                    }
                    Err(3) => {
                        self.known.remove(&pid);
                        disappeared = true;
                    }
                    Err(e) => return Err(format!("PID {pid}: rusage unavailable (OS error {e})")),
                }
            }
            for (pid, old) in &readings {
                match usage(*pid) {
                    Ok(u) if u.start == old.start => {}
                    Ok(_) | Err(3) => {
                        self.known.remove(pid);
                        disappeared = true;
                    }
                    Err(e) => {
                        return Err(format!("PID {pid}: validation unavailable (OS error {e})"));
                    }
                }
            }
            if disappeared {
                continue;
            }
            let mut result = Reading {
                gap,
                ..Reading::default()
            };
            for (pid, u) in readings {
                result.user = result.user.saturating_add(u.user);
                result.system = result.system.saturating_add(u.system);
                let memory = if u.zombie != 0 { 0 } else { u.memory };
                result.memory = result.memory.saturating_add(memory);
                let end = u.name.iter().position(|b| *b == 0).unwrap_or(64);
                result.processes.push(ProcessSnapshot {
                    pid,
                    parent: u.parent,
                    start: u.start,
                    memory,
                    name: String::from_utf8_lossy(&u.name[..end]).into_owned(),
                });
            }
            result.processes.sort_by_key(|p| p.pid);
            return Ok(result);
        }
        Err("Process frontier changed during sample; retry next interval".into())
    }
}
