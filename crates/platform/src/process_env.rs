//! Read the arguments and variables a process was started with, from its own
//! argument and environment blocks.
use std::collections::BTreeMap;

/// The arguments process `pid` currently presents, `argv[0]` first. A process
/// may rewrite them after starting (Node's `process.title` does). `None` when
/// this platform or the process's owner does not expose them.
pub fn arguments(pid: u32) -> Option<Vec<String>> {
    let (arguments, _) = blocks(pid)?;
    Some(arguments.iter().map(|a| String::from_utf8_lossy(a).into_owned()).collect())
}

/// The values `names` had in process `pid` when it started. Only those are
/// returned, never the rest of an environment that can hold credentials.
///
/// `None` when this platform or the process's owner does not expose it.
pub fn variables(pid: u32, names: &[&str]) -> Option<BTreeMap<String, String>> {
    let mut found = BTreeMap::new();
    let (_, environment) = blocks(pid)?;
    // macOS withholds the environment of Apple platform binaries; an empty
    // block is unknown, not proof that nothing was set.
    if environment.is_empty() {
        return None;
    }
    for entry in environment {
        let Some(split) = entry.iter().position(|b| *b == b'=') else { continue };
        let Ok(name) = std::str::from_utf8(&entry[..split]) else { continue };
        if names.contains(&name) && !found.contains_key(name) {
            if let Ok(value) = String::from_utf8(entry[split + 1..].to_vec()) {
                found.insert(name.to_owned(), value);
            }
        }
    }
    Some(found)
}

type Blocks = (Vec<Vec<u8>>, Vec<Vec<u8>>);

#[cfg(target_os = "linux")]
fn blocks(pid: u32) -> Option<Blocks> {
    if pid == 0 {
        return None;
    }
    let split = |bytes: Vec<u8>| -> Vec<Vec<u8>> {
        bytes.split(|b| *b == 0).filter(|s| !s.is_empty()).map(<[u8]>::to_vec).collect()
    };
    let arguments = split(std::fs::read(format!("/proc/{pid}/cmdline")).ok()?);
    let environment = std::fs::read(format!("/proc/{pid}/environ")).map(split).unwrap_or_default();
    Some((arguments, environment))
}

#[cfg(target_os = "macos")]
fn blocks(pid: u32) -> Option<Blocks> {
    let pid = i32::try_from(pid).ok().filter(|pid| *pid > 0)?;
    let mut max: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    let mut name = [libc::CTL_KERN, libc::KERN_ARGMAX];
    if unsafe {
        libc::sysctl(name.as_mut_ptr(), 2, (&raw mut max).cast(), &mut size, std::ptr::null_mut(), 0)
    } != 0
    {
        return None;
    }
    let mut buffer = vec![0u8; usize::try_from(max).ok()?];
    let mut size = buffer.len();
    // The kernel copies argc, the executable path, its arguments and then its
    // environment, each NUL-terminated, from the process's own stack.
    let mut name = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    if unsafe {
        libc::sysctl(name.as_mut_ptr(), 3, buffer.as_mut_ptr().cast(), &mut size, std::ptr::null_mut(), 0)
    } != 0
    {
        return None;
    }
    buffer.truncate(size);
    let argc = i32::from_ne_bytes(buffer.get(..4)?.try_into().ok()?);
    let mut at = 4 + buffer.get(4..)?.iter().position(|b| *b == 0)?;
    // The executable path is padded with NULs before the first argument.
    while buffer.get(at) == Some(&0) {
        at += 1;
    }
    let mut strings = buffer[at..].split(|b| *b == 0);
    let mut arguments = Vec::new();
    for _ in 0..argc {
        arguments.push(strings.next()?.to_vec());
    }
    // A rewritten title leaves NUL padding where the original arguments were.
    arguments.retain(|a| !a.is_empty());
    let environment = strings.take_while(|s| !s.is_empty()).map(<[u8]>::to_vec).collect();
    Some((arguments, environment))
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn blocks(_pid: u32) -> Option<Blocks> {
    None
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests {
    use super::*;
    #[test]
    fn reads_only_named_variables_a_child_started_with() {
        struct Guard(std::process::Child, std::path::PathBuf);
        impl Drop for Guard {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
                let _ = std::fs::remove_dir_all(&self.1);
            }
        }
        // A copy, because macOS withholds a platform binary's environment.
        let dir = std::env::temp_dir().join(format!("graffitty-env-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::copy("/bin/sleep", dir.join("sleep")).unwrap();
        let child = std::process::Command::new(dir.join("sleep"))
            .arg("30")
            .env("GRAFFITTY_ENV_TEST_HOME", "/accounts/Ω = it's")
            .env("GRAFFITTY_ENV_TEST_EMPTY", "")
            .env("GRAFFITTY_ENV_TEST_SECRET", "not requested")
            .env_remove("GRAFFITTY_ENV_TEST_UNSET")
            .spawn()
            .unwrap();
        let guard = Guard(child, dir);
        let names = ["GRAFFITTY_ENV_TEST_HOME", "GRAFFITTY_ENV_TEST_EMPTY", "GRAFFITTY_ENV_TEST_UNSET"];
        let found = variables(guard.0.id(), &names).unwrap();
        assert_eq!(
            found,
            BTreeMap::from([
                ("GRAFFITTY_ENV_TEST_EMPTY".to_owned(), String::new()),
                ("GRAFFITTY_ENV_TEST_HOME".to_owned(), "/accounts/Ω = it's".to_owned()),
            ])
        );
        assert!(variables(0, &names).is_none());
    }

    #[test]
    fn reads_the_arguments_a_child_presents() {
        let mut child = std::process::Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let found = arguments(child.id());
        let _ = child.kill();
        let _ = child.wait();
        assert_eq!(found.unwrap(), ["/bin/sleep", "30"]);
        assert!(arguments(0).is_none());
    }
}

/// Preserve loader overrides for terminal children while the graphics stack
/// and its helpers use the system libraries. An empty value differs from unset.
const GUI_LOADER_ENV: [(&str, &str); 2] = [
    ("LD_LIBRARY_PATH", "GRAFFITTY_SHELL_LD_LIBRARY_PATH"),
    ("LD_PRELOAD", "GRAFFITTY_SHELL_LD_PRELOAD"),
];

pub fn sanitize_gui_loader(command: &mut std::process::Command) {
    sanitize_loader_from(command, |key| std::env::var_os(key));
}

fn sanitize_loader_from(
    command: &mut std::process::Command,
    read: impl Fn(&str) -> Option<std::ffi::OsString>,
) {
    for (key, saved) in GUI_LOADER_ENV {
        if let Some(value) = read(key) {
            command.env(saved, value);
        }
        command.env_remove(key);
    }
}

/// Apply before explicit per-terminal overrides. The session builder strips
/// all internal GRAFFITTY_* names before handing the environment to a holder.
pub fn shell_loader_values(
    read: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> impl Iterator<Item = (&'static str, std::ffi::OsString)> {
    GUI_LOADER_ENV
        .into_iter()
        .filter_map(move |(key, saved)| read(saved).map(|v| (key, v)))
}

#[cfg(test)]
#[test]
fn gpu_loader_roundtrip_preserves_unset_empty_and_toolchain_paths() {
    use std::{ffi::OsString, process::Command};
    for preload in [None, Some(""), Some("/tools/extra library.so")] {
        let mut command = Command::new("engine");
        sanitize_loader_from(&mut command, |key| match key {
            "LD_LIBRARY_PATH" => Some(OsString::from("/tools/lib:/fpga/lib")),
            "LD_PRELOAD" => preload.map(OsString::from),
            _ => None,
        });
        let changes: BTreeMap<_, _> = command
            .get_envs()
            .map(|(key, value)| (key, value))
            .collect();
        for (key, _) in GUI_LOADER_ENV {
            assert_eq!(changes[std::ffi::OsStr::new(key)], None);
        }
        let restored: BTreeMap<_, _> = shell_loader_values(|key| {
            changes
                .get(std::ffi::OsStr::new(key))
                .copied()
                .flatten()
                .map(OsString::from)
        })
        .collect();
        assert_eq!(restored["LD_LIBRARY_PATH"], "/tools/lib:/fpga/lib");
        assert_eq!(
            restored.get("LD_PRELOAD").cloned(),
            preload.map(OsString::from)
        );
    }
}
