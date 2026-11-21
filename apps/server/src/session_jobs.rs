//! Close background job-control groups as well as the PTY foreground group.
//! Remember start identities before the shell exits and reparents its jobs.
//!
//! Descendants that left the session (Neovim's `--embed` server calls setsid)
//! are found through their parents while the shell's tree is still intact.
#[derive(Clone, Copy, PartialEq, Eq)]
struct Identity {
    pid: i32,
    session: i32,
    started: (u64, u64),
}

pub struct Jobs(Vec<Identity>);
impl Jobs {
    pub fn capture(shell: Option<u32>) -> Self {
        let Some(shell)=shell.and_then(|pid|identity(pid as i32)) else {return Self(Vec::new())};
        // portable-pty creates a session leader. Never signal the server's or
        // invoking terminal's session if that contract is not satisfied.
        if shell.session!=shell.pid || unsafe {libc::getsid(0)}==shell.session {
            return Self(Vec::new());
        }
        let all:Vec<_>=pids().into_iter().filter_map(process).collect();
        let mut jobs:Vec<_>=all.iter().map(|(job,_)|*job).filter(|job|job.session==shell.session).collect();
        loop {
            let found=jobs.len();
            for (job,parent) in &all {
                if !jobs.contains(job) && jobs.iter().any(|known|known.pid==*parent) {jobs.push(*job);}
            }
            if jobs.len()==found {break Self(jobs);}
        }
    }
    pub fn signal(&self, signal:i32) {
        for job in &self.0 {
            if identity(job.pid)==Some(*job) {
                unsafe {libc::kill(job.pid,signal);}
            }
        }
    }
}

#[cfg(target_os="macos")]
fn pids() -> Vec<i32> {
    const PROC_ALL_PIDS:u32=1; // libproc.h; not exported by the libc crate.
    let bytes=unsafe {libc::proc_listpids(PROC_ALL_PIDS,0,std::ptr::null_mut(),0)};
    if bytes<=0 {return Vec::new();}
    let mut pids=vec![0;bytes as usize/4+256];
    let copied=unsafe {libc::proc_listpids(PROC_ALL_PIDS,0,pids.as_mut_ptr().cast(),(pids.len()*4) as i32)};
    pids.truncate(copied.max(0) as usize/4);
    pids.into_iter().filter(|pid|*pid>0).collect()
}
fn identity(pid:i32) -> Option<Identity> {process(pid).map(|(job,_)|job)}
/// The parent stays out of the identity: a reparented job is still the same job.
#[cfg(target_os="macos")]
fn process(pid:i32) -> Option<(Identity,i32)> {
    let mut info:libc::proc_bsdinfo=unsafe {std::mem::zeroed()};
    let size=std::mem::size_of_val(&info) as i32;
    let copied=unsafe {libc::proc_pidinfo(pid,libc::PROC_PIDTBSDINFO,0,(&mut info as *mut libc::proc_bsdinfo).cast(),size)};
    let session=unsafe {libc::getsid(pid)};
    (copied==size && session>0).then_some((Identity {pid,session,started:(info.pbi_start_tvsec,info.pbi_start_tvusec)},info.pbi_ppid as i32))
}
#[cfg(target_os="linux")]
fn pids() -> Vec<i32> {
    std::fs::read_dir("/proc").into_iter().flatten().filter_map(|entry|entry.ok()?
        .file_name().to_str()?.parse().ok()).collect()
}
#[cfg(target_os="linux")]
fn process(pid:i32) -> Option<(Identity,i32)> {
    let stat=std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let fields:Vec<_>=stat.rsplit_once(')')?.1.split_whitespace().collect();
    Some((Identity {pid,session:fields.get(3)?.parse().ok()?,started:(fields.get(19)?.parse().ok()?,0)},fields.get(1)?.parse().ok()?))
}
#[cfg(not(any(target_os="macos",target_os="linux")))]
fn pids() -> Vec<i32> {Vec::new()}
#[cfg(not(any(target_os="macos",target_os="linux")))]
fn process(_:i32) -> Option<(Identity,i32)> {None}
