//! Per-ConPTY Job Objects, assigned by the process-creation attribute list.
//! Handles, not PID attachments, define accounting membership.
use super::{ProcessSnapshot, Reading};
use std::collections::HashMap;
use std::mem::{size_of, zeroed};
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::ptr::{null, null_mut};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use windows_sys::Win32::Foundation::{ERROR_MORE_DATA, FILETIME, HANDLE};
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::ProcessStatus::{
    K32GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS_EX,
};
use windows_sys::Win32::System::Threading::*;

mod process;
pub use process::Process;

/// Fresh close-policy query using the PTY's existing process-creation boundary.
/// Unknown membership or executable identity remains an error, never permission
/// to silently close a workload.
pub fn has_running_program(pid: u32) -> Result<bool, String> {
    let backend = Backend::new(pid)?;
    let job = backend.job.as_raw_handle();
    let members = process_ids(job)?;
    if !members.contains(&pid) {
        return Err("Shell is no longer in its Job Object".into());
    }
    if members.iter().any(|member| *member != pid) {
        return Ok(true);
    }
    let root = process_row(job, pid);
    if root.name.is_empty() {
        return Err("Unable to identify the shell executable".into());
    }
    Ok(!matches!(root.name.to_ascii_lowercase().as_str(),
        "powershell.exe" | "pwsh.exe" | "cmd.exe" | "nu.exe" |
        "sh.exe" | "bash.exe" | "zsh.exe" | "fish.exe" | "dash.exe" | "ksh.exe"))
}

fn registry() -> &'static Mutex<HashMap<u32, Weak<OwnedHandle>>> {
    static JOBS: OnceLock<Mutex<HashMap<u32, Weak<OwnedHandle>>>> = OnceLock::new();
    JOBS.get_or_init(Mutex::default)
}

/// Owned by the PTY, independently of whether sampling is enabled. No kill-on-close
/// or breakaway flags: closing the monitor does not change workload lifetime.
pub struct Boundary {
    job: Arc<OwnedHandle>,
    pid: Option<u32>,
}
impl Boundary {
    pub fn prepare() -> Result<Self, String> {
        let raw = unsafe { CreateJobObjectW(null(), null()) };
        if raw.is_null() {
            return Err(os_error("CreateJobObjectW"));
        }
        Ok(Self {
            job: Arc::new(unsafe { OwnedHandle::from_raw_handle(raw) }),
            pid: None,
        })
    }
    /// Opens the job called `name` in this logon session, or creates it.
    ///
    /// A terminal holder creates the job for the programs it starts. The
    /// session server opens the same job to track them, also after a restart.
    ///
    /// The name only works while at least one handle to the job is open.
    pub fn named(name: &str) -> Result<Self, String> {
        let wide: Vec<u16> = format!("Local\\{name}").encode_utf16().chain(Some(0)).collect();
        let raw = unsafe { CreateJobObjectW(null(), wide.as_ptr()) };
        if raw.is_null() {
            return Err(os_error("CreateJobObjectW"));
        }
        Ok(Self {
            job: Arc::new(unsafe { OwnedHandle::from_raw_handle(raw) }),
            pid: None,
        })
    }
    pub fn handle(&self) -> Arc<OwnedHandle> {
        self.job.clone()
    }
    /// Fresh membership query for close confirmation; independent of sampling.
    pub fn has_children(&self) -> Result<bool, String> {
        let root = self.pid.ok_or("Shell has not been registered")?;
        Ok(process_ids(self.job.as_raw_handle())?
            .into_iter()
            .any(|pid| pid != root))
    }
    /// Publish only after a successful spawn that used `handle()` in JOB_LIST.
    /// This records the existing boundary; it does not assign a running process.
    pub fn register(&mut self, pid: u32) {
        registry()
            .lock()
            .unwrap()
            .insert(pid, Arc::downgrade(&self.job));
        self.pid = Some(pid);
    }
}
impl Drop for Boundary {
    fn drop(&mut self) {
        if let Some(pid) = self.pid {
            let mut jobs = registry().lock().unwrap();
            if jobs
                .get(&pid)
                .is_some_and(|job| job.ptr_eq(&Arc::downgrade(&self.job)))
            {
                jobs.remove(&pid);
            }
        }
    }
}

pub(super) struct Backend {
    job: Arc<OwnedHandle>,
}
impl Backend {
    pub const NAME: &'static str = "windows-job-object";
    pub const MEMORY: &'static str = "Job committed memory";
    pub fn new(pid: u32) -> Result<Self, String> {
        let job = registry()
            .lock()
            .unwrap()
            .get(&pid)
            .and_then(Weak::upgrade)
            .ok_or("Terminal has no Job Object established at process creation")?;
        Ok(Self { job })
    }
    pub fn sample(&mut self) -> Result<Reading, String> {
        let job = self.job.as_raw_handle();
        let mut cpu: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION = unsafe { zeroed() };
        query(job, JobObjectBasicAccountingInformation, &mut cpu)?;
        // Microsoft hcsshim uses this current-job memory query (class 28).
        // https://github.com/microsoft/hcsshim/blob/main/internal/winapi/jobobject.go
        // It is absent from windows-sys metadata. Probe on every sample and fail
        // explicitly when unsupported; violation notifications are NOT current usage.
        #[repr(C)]
        #[derive(Default)]
        struct MemoryUsage {
            current: u64,
            peak: u64,
        }
        let mut memory = MemoryUsage::default();
        query(job, 28, &mut memory)?;
        let processes = process_ids(job)?
            .into_iter()
            .map(|pid| process_row(job, pid))
            .collect();
        Ok(Reading {
            user: (cpu.TotalUserTime.max(0) as u64).saturating_mul(100),
            system: (cpu.TotalKernelTime.max(0) as u64).saturating_mul(100),
            memory: memory.current,
            kernel_peak: Some(memory.peak),
            processes,
            ..Reading::default()
        })
    }
}
fn os_error(operation: &str) -> String {
    format!("{operation}: {}", std::io::Error::last_os_error())
}
fn query<T>(job: HANDLE, class: JOBOBJECTINFOCLASS, value: &mut T) -> Result<(), String> {
    if unsafe {
        QueryInformationJobObject(
            job,
            class,
            value as *mut T as _,
            size_of::<T>() as u32,
            null_mut(),
        )
    } == 0
    {
        Err(os_error(&format!("QueryInformationJobObject({class})")))
    } else {
        Ok(())
    }
}
fn process_ids(job: HANDLE) -> Result<Vec<u32>, String> {
    // Pointer-sized, aligned storage for the two DWORD header fields and PID array.
    // Retry if processes were born during enumeration, with a bounded allocation.
    let mut capacity = 64;
    for _ in 0..12 {
        let bytes = 8 + capacity * size_of::<usize>();
        let mut buffer = vec![0usize; bytes.div_ceil(size_of::<usize>())];
        let ok = unsafe {
            QueryInformationJobObject(
                job,
                JobObjectBasicProcessIdList,
                buffer.as_mut_ptr() as _,
                bytes as u32,
                null_mut(),
            )
        };
        if ok != 0 {
            let header = buffer.as_ptr() as *const u32;
            let count = unsafe { *header.add(1) } as usize;
            if count > capacity {
                return Err("Invalid job PID list length".into());
            }
            let pids = unsafe {
                std::slice::from_raw_parts(
                    (buffer.as_ptr() as *const u8).add(8) as *const usize,
                    count,
                )
            };
            return Ok(pids.iter().map(|pid| *pid as u32).collect());
        }
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(ERROR_MORE_DATA as i32) {
            return Err(format!("Job process inventory: {error}"));
        }
        capacity *= 2;
    }
    Err("Job process inventory kept growing during enumeration".into())
}
fn process_row(job: HANDLE, pid: u32) -> ProcessSnapshot {
    let mut row = ProcessSnapshot {
        pid,
        ..ProcessSnapshot::default()
    };
    let raw = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, 0, pid) };
    if raw.is_null() {
        return row;
    }
    let process = unsafe { OwnedHandle::from_raw_handle(raw) };
    let raw = process.as_raw_handle();
    let mut member = 0;
    // A PID can exit and be reused between inventory and OpenProcess. Never
    // decorate the row with another workload's process data.
    if unsafe { IsProcessInJob(raw, job, &mut member) } == 0 || member == 0 {
        return row;
    }
    let mut start: FILETIME = unsafe { zeroed() };
    let mut exit: FILETIME = unsafe { zeroed() };
    let mut kernel: FILETIME = unsafe { zeroed() };
    let mut user: FILETIME = unsafe { zeroed() };
    if unsafe { GetProcessTimes(raw, &mut start, &mut exit, &mut kernel, &mut user) } != 0 {
        row.start = ((start.dwHighDateTime as u64) << 32) | start.dwLowDateTime as u64;
    }
    let mut name = vec![0u16; 32768];
    let mut length = name.len() as u32;
    if unsafe { QueryFullProcessImageNameW(raw, 0, name.as_mut_ptr(), &mut length) } != 0 {
        let path = String::from_utf16_lossy(&name[..length as usize]);
        row.name = path.rsplit('\\').next().unwrap_or(&path).into();
    }
    let mut memory: PROCESS_MEMORY_COUNTERS_EX = unsafe { zeroed() };
    memory.cb = size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32;
    if unsafe { K32GetProcessMemoryInfo(raw, &mut memory as *mut _ as _, memory.cb) } != 0 {
        row.memory = memory.PrivateUsage as u64;
    }
    row
}
