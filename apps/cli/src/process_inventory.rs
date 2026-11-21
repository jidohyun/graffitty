//! Native process inventory. Never spawn `ps` for recurring discovery.
use crate::sessions::Process;
use std::collections::HashMap;

// Keep the UTC process-identity representation used at the agent boundary.
fn started(seconds: i64) -> String {
    let time = jiff::Timestamp::from_second(seconds)
        .unwrap_or(jiff::Timestamp::UNIX_EPOCH)
        .to_zoned(jiff::tz::TimeZone::UTC);
    time.strftime("%a %b %e %H:%M:%S %Y")
        .to_string()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(target_os = "macos")]
pub(crate) fn processes() -> HashMap<i64, Process> {
    use std::mem::size_of;
    // libproc reports a count, not bytes. Leave room for births during enumeration.
    let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    if count <= 0 {
        return HashMap::new();
    }
    let mut pids = vec![0i32; count as usize + 128];
    let count = unsafe {
        libc::proc_listallpids(
            pids.as_mut_ptr().cast(),
            (pids.len() * size_of::<i32>()) as i32,
        )
    };
    let mut result = HashMap::new();
    for pid in pids
        .into_iter()
        .take(count.max(0) as usize)
        .filter(|p| *p > 0)
    {
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = size_of::<libc::proc_bsdinfo>() as i32;
        if unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size)
        } != size
        {
            continue;
        }
        let mut path = [0u8; 4096];
        let length =
            unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
        let executable = if length > 0 {
            String::from_utf8_lossy(
                &path[..path.iter().position(|b| *b == 0).unwrap_or(path.len())],
            )
            .into_owned()
        } else {
            // Kernel strings need not occupy the entire buffer.
            let bytes: Vec<_> = info
                .pbi_comm
                .iter()
                .take_while(|b| **b != 0)
                .map(|b| *b as u8)
                .collect();
            String::from_utf8_lossy(&bytes).into_owned()
        };
        result.insert(
            pid as i64,
            Process {
                pid: pid as i64,
                parent: info.pbi_ppid as i64,
                group: info.pbi_pgid as i64,
                foreground: info.e_tpgid as i32 as i64,
                tty: if info.e_tdev == u32::MAX {
                    "?".into()
                } else {
                    info.e_tdev.to_string()
                },
                state: match info.pbi_status {
                    5 => "Z",
                    4 => "T",
                    _ => "S",
                }
                .into(),
                started: started(info.pbi_start_tvsec as i64),
                executable,
            },
        );
    }
    result
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn processes() -> HashMap<i64, Process> {
    let boot = std::fs::read_to_string("/proc/stat").ok().and_then(|s| {
        s.lines()
            .find_map(|l| l.strip_prefix("btime ").and_then(|n| n.parse::<i64>().ok()))
    });
    let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as i64;
    let Some(boot) = boot.filter(|_| ticks > 0) else {
        return HashMap::new();
    };
    let mut result = HashMap::new();
    for entry in std::fs::read_dir("/proc").into_iter().flatten().flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<i64>().ok())
        else {
            continue;
        };
        let Ok(stat) = std::fs::read_to_string(entry.path().join("stat")) else {
            continue;
        };
        let Some((_, tail)) = stat.rsplit_once(") ") else {
            continue;
        };
        let fields: Vec<_> = tail.split_whitespace().collect();
        if fields.len() < 20 {
            continue;
        }
        let number = |i: usize| fields[i].parse::<i64>().ok();
        let (Some(parent), Some(group), Some(tty), Some(foreground), Some(start)) =
            (number(1), number(2), number(4), number(5), number(19))
        else {
            continue;
        };
        let executable = std::fs::read_link(entry.path().join("exe"))
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| {
                stat.split_once('(')
                    .map(|(_, s)| s.rsplit_once(") ").unwrap().0.to_owned())
                    .unwrap_or_default()
            });
        result.insert(
            pid,
            Process {
                pid,
                parent,
                group,
                foreground,
                tty: if tty == 0 {
                    "?".into()
                } else {
                    tty.to_string()
                },
                state: fields[0].into(),
                started: started(boot + start / ticks),
                executable,
            },
        );
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn utc_identity() {
        assert_eq!(started(0), "Thu Jan 1 00:00:00 1970");
    }
    #[test]
    fn identity_matches_external_utc_process_identity() {
        // Test oracle only: production inventory never launches a subprocess.
        let pid = std::process::id();
        let output = std::process::Command::new("ps")
            .args(["-p", &pid.to_string(), "-o", "lstart="])
            .env("TZ", "UTC")
            .env("LC_ALL", "C")
            .output()
            .unwrap();
        assert!(output.status.success());
        let expected = String::from_utf8(output.stdout)
            .unwrap()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(processes()[&(pid as i64)].started, expected);
    }
    #[test]
    fn native_tty_and_foreground_match_a_real_job() {
        use std::{
            fs::File,
            os::fd::FromRawFd,
            os::unix::process::CommandExt,
            process::{Command, Stdio},
        };
        let (mut master, mut slave) = (-1, -1);
        assert_eq!(
            unsafe {
                libc::openpty(
                    &raw mut master,
                    &raw mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            },
            0
        );
        let _master = unsafe { File::from_raw_fd(master) };
        let slave = unsafe { File::from_raw_fd(slave) };
        let mut command = Command::new("/bin/sleep");
        command
            .arg("10")
            .stdin(slave)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0
                    || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0
                    || libc::tcsetpgrp(0, libc::getpid()) < 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        struct Child(std::process::Child);
        impl Drop for Child {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let child = Child(command.spawn().unwrap());
        let table = processes();
        let job = &table[&(child.0.id() as i64)];
        assert_eq!(job.group, job.pid);
        assert_eq!(job.foreground, job.pid);
        assert_ne!(job.tty, "?");
        assert!(!job.state.contains('Z'));
    }
    #[test]
    fn inventories_self_and_parent() {
        let table = processes();
        let own = &table[&(std::process::id() as i64)];
        assert_eq!(own.group, unsafe { libc::getpgrp() } as i64);
        assert_eq!(own.parent, unsafe { libc::getppid() } as i64);
        assert!(!own.executable.is_empty());
        assert!(!own.started.is_empty());
        assert!(table.contains_key(&own.parent));
    }
}
