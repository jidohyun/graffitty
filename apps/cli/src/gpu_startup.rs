//! Supervise the exported engine from before driver initialization until the
//! first healthy frames. Keep the child exit status for callers which wait.
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::process::{Command, ExitStatus};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const WINDOWS: &[&str] = &["d3d12", "vulkan", "opengl3"];
const LINUX: &[&str] = &["vulkan", "opengl3", "software"];
const FORGIVE_SECONDS: u64 = 300;
const CRASH_LIMIT: u64 = 3;

mod diagnostics;
mod driver_rules;
mod inventory;
mod watchdog;

#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
enum Cause {
    Timeout,
    InitDialog,
    DeviceLost,
    EarlyExit,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Failure {
    at: u64,
    phase: String,
    cause: Cause,
    status: Option<i32>,
}

#[derive(Default, Serialize, Deserialize)]
struct CrashBudget {
    mode: String,
    last: u64,
    count: u64,
}

impl CrashBudget {
    fn remaining(&self, now: u64) -> u64 {
        if now < self.last {
            return 0;
        }
        self.count
            .saturating_sub((now - self.last) / FORGIVE_SECONDS)
    }
}

fn retry_mode(driver: &str) -> &str {
    if driver == "opengl3_angle" {
        "opengl3"
    } else {
        driver
    }
}

#[derive(Serialize, Deserialize)]
struct AdapterIdentity {
    renderer: String,
    adapter: String,
    api: String,
}

#[derive(Serialize, Deserialize)]
struct Presentation {
    display_server: String,
    transparency_at_startup: bool,
    godot_transparency_after_draw: Option<bool>,
    transparency_after_draw: Option<bool>,
}

#[derive(Serialize, Deserialize)]
struct Adapter {
    #[serde(flatten)]
    identity: AdapterIdentity,
    presentation: Presentation,
}

#[derive(Default, Serialize, Deserialize)]
struct History {
    version: u8,
    fingerprint: String,
    selected: String,
    failures: BTreeMap<String, Failure>,
    budget: CrashBudget,
    adapters: BTreeMap<String, Adapter>,
    rules: Vec<u32>,
    reprobe: u64,
}

impl History {
    fn reset(fingerprint: &str, rules: &[u32]) -> Self {
        Self {
            version: 1,
            fingerprint: fingerprint.into(),
            rules: rules.into(),
            ..Self::default()
        }
    }

    fn record(&mut self, mode: &str, failure: Failure) {
        if failure.cause != Cause::EarlyExit {
            let previous = if self.budget.mode == mode {
                self.budget.remaining(failure.at)
            } else {
                0
            };
            self.budget = CrashBudget {
                mode: mode.into(),
                last: failure.at,
                count: previous.saturating_add(1),
            };
        }
        self.failures.insert(mode.into(), failure);
    }

    fn order<'a>(&self, chain: &[&'a str], disabled: &[&str], now: u64) -> Vec<&'a str> {
        let mut modes: Vec<_> = chain
            .iter()
            .copied()
            .filter(|mode| {
                !disabled.contains(mode)
                    && !(self.budget.mode == *mode && self.budget.remaining(now) >= CRASH_LIMIT)
            })
            .collect();
        if self.reprobe > now && self.reprobe - now <= FORGIVE_SECONDS {
            if let Some(index) = modes.iter().position(|&mode| mode == self.selected) {
                modes.rotate_left(index);
            }
        }
        modes
    }
}

struct Policy<'a> {
    chain: &'a [&'a str],
    fingerprint: &'a str,
    disabled: &'a [&'a str],
    rules: &'a [u32],
}

fn timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn replace(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut temp = tempfile::NamedTempFile::new_in(path.parent().unwrap())?;
    temp.write_all(bytes)?;
    temp.persist(path)?;
    Ok(())
}

const BEGIN: &str = "; BEGIN Graffitty automatic renderer\n";
const END: &str = "; END Graffitty automatic renderer\n";

fn save_override(root: &Path, mode: &str, windows: bool) -> io::Result<()> {
    let path = root.join("override.cfg");
    if path.is_symlink() {
        // The user's linked configuration has a separate owner. The launcher
        // still applies its remembered mode through explicit engine arguments.
        return Ok(());
    }
    let old = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e),
    };
    let mut text = old.clone();
    let mut offset = 0;
    let mut block_start = None;
    let mut block_end = None;
    for line in old.split_inclusive('\n') {
        if line.trim_end() == BEGIN.trim_end() {
            block_start = Some(offset);
        }
        offset += line.len();
        if block_start.is_some() && line.trim_end() == END.trim_end() {
            block_end = Some(offset);
            break;
        }
    }
    if let Some(start) = block_start {
        let end = block_end.ok_or_else(|| io::Error::other("Incomplete renderer override"))?;
        text.replace_range(start..end, "");
    }
    if mode != (if windows { WINDOWS[0] } else { LINUX[0] }) {
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str(BEGIN);
        text.push_str("[rendering]\n");
        if mode == "vulkan" {
            text.push_str("renderer/rendering_method=\"forward_plus\"\nrendering_device/driver.windows=\"vulkan\"\n");
        } else {
            text.push_str("renderer/rendering_method=\"gl_compatibility\"\n");
        }
        text.push_str(END);
    }
    if text != old {
        replace(&path, text.as_bytes())?;
    }
    Ok(())
}

#[cfg(any(windows, target_os = "linux"))]
pub fn launch(root: &Path, args: &[OsString]) -> io::Result<ExitStatus> {
    let windows = cfg!(windows);
    let runtime = root.join(if windows {
        "GraffittyRuntime.exe"
    } else {
        "GraffittyRuntime"
    });
    let mut base = Command::new(&runtime);
    if !windows {
        graffitty_platform::process_env::sanitize_gui_loader(&mut base);
    }
    // Explicit engine controls (including offline tools) own their exit codes.
    let flags = &args[..args
        .iter()
        .position(|arg| arg == "--" || arg == "++")
        .unwrap_or(args.len())];
    let headless_display = flags
        .windows(2)
        .any(|pair| pair[0] == "--display-driver" && pair[1] == "headless");
    if headless_display
        || flags.iter().any(|arg| {
            matches!(
                arg.to_str(),
                Some(
                    "--rendering-driver"
                        | "--rendering-method"
                        | "--headless"
                        | "--quit"
                        | "--check-only"
                        | "-h"
                        | "-s"
                        | "--help"
                        | "--version"
                        | "--editor"
                        | "--script"
                )
            )
        })
    {
        return base.args(args).status();
    }
    let state = graffitty_transport::controller::state_directory()
        .map_err(io::Error::other)?
        .join("gpu");
    fs::create_dir_all(&state)?;
    let gpu_index = flags
        .windows(2)
        .filter(|pair| pair[0] == "--gpu-index")
        .last()
        .and_then(|pair| pair[1].to_str()?.parse().ok());
    let inventory = inventory::collect(&runtime, gpu_index);
    let fingerprint = format!("{}\n{}", env!("GRAFFITTY_VERSION"), inventory.fingerprint());
    let policy = Policy {
        chain: if windows { WINDOWS } else { LINUX },
        fingerprint: &fingerprint,
        disabled: &driver_rules::disabled_modes(&inventory),
        rules: &driver_rules::matched_rule_ids(&inventory),
    };
    supervise(
        &runtime,
        root,
        &state,
        args,
        &policy,
        watchdog::BASE_TIMEOUT,
    )
}

fn supervise(
    runtime: &Path,
    root: &Path,
    state: &Path,
    args: &[OsString],
    policy: &Policy,
    timeout: Duration,
) -> io::Result<ExitStatus> {
    let Policy {
        chain,
        fingerprint,
        disabled,
        rules,
    } = *policy;
    // Only hold the lock for a state transition. A minimized window or a
    // blocked driver must never prevent another window from launching.
    let lock = fs::File::options()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(state.join("startup.lock"))?;
    FileExt::lock_exclusive(&lock)?;
    let path = state.join("history.json");
    let load = || -> History {
        fs::read(&path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    };
    let save = |history: &History| replace(&path, &serde_json::to_vec(history)?);
    let mut history = load();
    if history.version != 1 || history.fingerprint != fingerprint || history.rules != rules {
        history = History::reset(fingerprint, rules);
    }
    save(&history)?;
    let mut modes = history.order(chain, disabled, timestamp()).into_iter();
    let mut retested = false;
    let mut failures = Vec::new();
    let mut last_exit = None;
    while let Some(mode) = modes.next() {
        let attempt = tempfile::Builder::new()
            .prefix("attempt-")
            .tempdir_in(state)?;
        let mut cmd = Command::new(runtime);
        if chain == LINUX {
            graffitty_platform::process_env::sanitize_gui_loader(&mut cmd);
        }
        let driver = if mode == "software" { "opengl3" } else { mode };
        if mode == "software" {
            cmd.env("LIBGL_ALWAYS_SOFTWARE", "1");
            if let Some(value) = std::env::var_os("LIBGL_ALWAYS_SOFTWARE") {
                cmd.env("GRAFFITTY_GPU_ORIGINAL_SOFTWARE", value);
            } else {
                cmd.env_remove("GRAFFITTY_GPU_ORIGINAL_SOFTWARE");
            }
        }
        cmd.args([
            "--rendering-method",
            if driver == "opengl3" {
                "gl_compatibility"
            } else {
                "forward_plus"
            },
            "--rendering-driver",
            driver,
        ]);
        cmd.args(args)
            .env("GRAFFITTY_GPU_ATTEMPT", attempt.path())
            .env("GRAFFITTY_GPU_MODE", mode)
            .env(
                "GRAFFITTY_GPU_EXPECTED",
                history
                    .adapters
                    .get(mode)
                    .map(|adapter| serde_json::to_string(&adapter.identity))
                    .transpose()?
                    .unwrap_or_default(),
            );
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        let mut child = cmd.spawn()?;
        FileExt::unlock(&lock)?;
        let result = watchdog::observe(
            &mut child,
            attempt.path(),
            if mode == "software" {
                timeout * 2
            } else {
                timeout
            },
        )?;
        FileExt::lock_exclusive(&lock)?;
        history = load();
        if history.fingerprint != fingerprint {
            drop(lock);
            return child.wait();
        }
        let observed: Option<Adapter> = fs::read(attempt.path().join("adapter"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        match result {
            watchdog::Outcome::Healthy => {
                let backend = observed
                    .as_ref()
                    .map(|gpu| gpu.identity.renderer.as_str())
                    .unwrap_or(mode);
                let actual = if mode == "software" {
                    mode
                } else {
                    retry_mode(backend)
                };
                let actual = chain
                    .iter()
                    .copied()
                    .find(|&item| item == actual)
                    .unwrap_or(mode);
                let changed = history.selected != actual
                    || history
                        .adapters
                        .get(actual)
                        .is_some_and(|old| old.identity.renderer != backend);
                // Grant exactly one process the notice for this committed transition.
                let notify = changed && (actual != chain[0] || backend != mode);
                if actual != chain[0] && (changed || history.reprobe <= timestamp()) {
                    history.reprobe = timestamp() + FORGIVE_SECONDS;
                }
                history.selected = actual.into();
                if let Some(adapter) = observed {
                    history.adapters.insert(actual.into(), adapter);
                }
                save(&history)?;
                if let Err(error) = save_override(root, actual, chain == WINDOWS) {
                    eprintln!("renderer override: {error}");
                }
                replace(
                    &attempt.path().join("accepted"),
                    if notify { b"1" } else { b"0" },
                )?;
                FileExt::unlock(&lock)?;
                let status = child.wait()?;
                if !status.success() && watchdog::device_lost(status, attempt.path()) {
                    FileExt::lock_exclusive(&lock)?;
                    history = load();
                    if history.fingerprint == fingerprint {
                        history.record(
                            actual,
                            Failure {
                                at: timestamp(),
                                phase: "running".into(),
                                cause: Cause::DeviceLost,
                                status: status.code(),
                            },
                        );
                        save(&history)?;
                    }
                }
                return Ok(status);
            }
            watchdog::Outcome::Closed(status) => return Ok(status),
            watchdog::Outcome::Failed(failure) => {
                if !retested && attempt.path().join("changed").is_file() {
                    history = History::reset(fingerprint, rules);
                    save(&history)?;
                    modes = history.order(chain, disabled, timestamp()).into_iter();
                    retested = true;
                    continue;
                }
                last_exit = Some(child.wait()?);
                history.record(mode, failure.clone());
                failures.push((mode.to_owned(), failure));
                save(&history)?;
                // Another launcher may have exhausted a mode while this child ran.
                modes = modes
                    .filter(|next| {
                        history.budget.mode != *next
                            || history.budget.remaining(timestamp()) < CRASH_LIMIT
                    })
                    .collect::<Vec<_>>()
                    .into_iter();
            }
        }
    }
    if failures.is_empty() {
        failures.extend(history.failures);
    }
    drop(lock);
    let report = diagnostics::exhaustion(state, &failures, rules)?;
    #[cfg(any(windows, target_os = "linux"))]
    if !cfg!(test) {
        diagnostics::show(&report);
    }
    last_exit
        .filter(|exit| !exit.success())
        .ok_or_else(|| io::Error::other(report))
}

#[cfg(test)]
mod tests;
