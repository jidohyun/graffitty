//! Watch only the direct frontend child during startup. Once frames are healthy
//! the supervisor no longer puts a deadline on the application.
use super::{Cause, Failure, timestamp};
use std::fs;
use std::io;
use std::path::Path;
use std::process::{Child, ExitStatus};
use std::time::{Duration, Instant};

pub(super) const BASE_TIMEOUT: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_millis(100);

pub(super) enum Outcome {
    Healthy,
    Closed(ExitStatus),
    Failed(Failure),
}

struct Deadline {
    previous: Instant,
    idle: Duration,
    progress: String,
}

impl Deadline {
    fn update(&mut self, now: Instant, progress: &str, limit: Duration) -> bool {
        let delta = now.duration_since(self.previous);
        self.previous = now;
        // A watchdog that wasn't scheduled cannot attribute the gap to its
        // child. Give it a fresh interval after sleep, resume or starvation.
        if delta > Duration::from_secs(2) || self.progress != progress {
            self.progress = progress.to_owned();
            self.idle = Duration::ZERO;
        } else {
            self.idle += delta;
        }
        self.idle >= limit
    }
}

fn progress(dir: &Path) -> String {
    if dir.join("closed").is_file() {
        return "closing".into();
    }
    fs::read_to_string(dir.join("progress")).unwrap_or_else(|_| "engine".into())
}

/// A device-loss HRESULT can itself be the exit code before autoload runs.
pub(super) fn device_lost(status: ExitStatus, dir: &Path) -> bool {
    #[cfg(windows)]
    if matches!(
        status.code().map(|code| code as u32),
        Some(0x887A0005..=0x887A0007)
    ) {
        return true;
    }
    let _ = status;
    // A recovered device loss hours earlier cannot explain an unrelated exit.
    fs::metadata(dir.join("device-lost"))
        .and_then(|m| m.modified())
        .ok()
        .and_then(|when| when.elapsed().ok())
        .is_some_and(|age| age <= BASE_TIMEOUT)
}

pub(super) fn observe(child: &mut Child, dir: &Path, timeout: Duration) -> io::Result<Outcome> {
    let mut deadline = Deadline {
        previous: Instant::now(),
        idle: Duration::ZERO,
        progress: progress(dir),
    };
    let mut reason = None;
    loop {
        let exit = child.try_wait()?;
        if dir.join("healthy").is_file() {
            return Ok(Outcome::Healthy);
        }
        let current = progress(dir);
        if let Some(status) = exit {
            if (status.success() || reason == Some(Cause::Timeout)) && current == "closing" {
                return Ok(Outcome::Closed(status));
            }
            let cause = reason.unwrap_or_else(|| {
                if device_lost(status, dir) {
                    Cause::DeviceLost
                } else {
                    Cause::EarlyExit
                }
            });
            return Ok(Outcome::Failed(Failure {
                at: timestamp(),
                phase: current.split_whitespace().next().unwrap_or("engine").into(),
                cause,
                status: status.code(),
            }));
        }
        let expired = deadline.update(Instant::now(), &current, timeout);
        let dialog = init_dialog(child.id());
        if expired || dialog {
            // Recheck progress, acknowledgement and exit immediately before
            // termination. A completed shutdown is collected on the next poll.
            if child.try_wait()?.is_none()
                && !dir.join("healthy").exists()
                && progress(dir) == current
                && (!dialog || init_dialog(child.id()))
            {
                match child.kill() {
                    Ok(()) => {
                        reason = Some(if dialog {
                            Cause::InitDialog
                        } else {
                            Cause::Timeout
                        })
                    }
                    Err(error) if child.try_wait()?.is_none() => return Err(error),
                    Err(_) => {}
                }
            }
        }
        std::thread::sleep(POLL);
    }
}

#[cfg(not(windows))]
fn init_dialog(_: u32) -> bool {
    false
}

#[cfg(windows)]
fn init_dialog(pid: u32) -> bool {
    use windows_sys::Win32::{
        Foundation::{HWND, LPARAM},
        UI::WindowsAndMessaging::*,
    };
    struct Search {
        pid: u32,
        found: bool,
    }
    unsafe extern "system" fn inspect(window: HWND, param: LPARAM) -> i32 {
        let data = unsafe { &mut *(param as *mut Search) };
        let mut owner = 0;
        unsafe { GetWindowThreadProcessId(window, &mut owner) };
        if owner != data.pid {
            return 1;
        }
        let mut buf = [0; 96];
        let size = unsafe { GetClassNameW(window, buf.as_mut_ptr(), buf.len() as i32) } as usize;
        if !buf[..size].iter().copied().eq("#32770".encode_utf16()) {
            return 1;
        }
        let size = unsafe { GetWindowTextW(window, buf.as_mut_ptr(), buf.len() as i32) } as usize;
        // Exact title used by Godot DisplayServerWindows::create_func when
        // graphics initialization fails. Leave other native UI alone.
        data.found = buf[..size]
            .iter()
            .copied()
            .eq("Unable to initialize video driver".encode_utf16());
        i32::from(!data.found)
    }
    let mut data = Search { pid, found: false };
    unsafe { EnumWindows(Some(inspect), (&mut data as *mut Search) as LPARAM) };
    data.found
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sleep_and_new_progress_restart_the_watchdog() {
        let start = Instant::now();
        let mut timer = Deadline {
            previous: start,
            idle: Duration::ZERO,
            progress: "engine".into(),
        };
        let limit = Duration::from_secs(2);
        for (seconds, phase, expired) in [
            (1, "engine", false),
            (60, "engine", false),
            (61, "engine", false),
            (62, "frame", false),
            (63, "frame", false),
            (64, "frame", true),
        ] {
            assert_eq!(
                timer.update(start + Duration::from_secs(seconds), phase, limit),
                expired
            );
        }
    }
}
