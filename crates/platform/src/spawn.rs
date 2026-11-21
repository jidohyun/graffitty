//! Host executable and working-directory validation before creating a PTY.
use graffitty_protocol::limits::TerminalLimits;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub struct Prepared {
    pub shell: PathBuf,
    pub args: Vec<String>,
    pub login: bool,
    pub cwd: Option<PathBuf>,
    pub env: BTreeMap<String, String>,
    pub shell_integration: bool,
    pub limits: TerminalLimits,
}

pub fn prepare(
    options: &graffitty_protocol::spawn::SpawnOptions,
    default_shell: &str,
    source_cwd: Option<&Path>,
) -> Result<Prepared, String> {
    options.validate()?;
    let shell = options.shell.as_deref().unwrap_or(default_shell);
    let path = Path::new(shell);
    let executable = |path: &Path| {
        let Ok(metadata) = path.metadata() else {
            return false;
        };
        if !metadata.is_file() {
            return false;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if metadata.permissions().mode() & 0o111 == 0 {
                return false;
            }
        }
        true
    };
    let shell = if path.components().count() > 1 || path.is_absolute() {
        executable(path).then(|| path.to_owned())
    } else {
        let search = options
            .env
            .get("PATH")
            .map(std::ffi::OsString::from)
            .or_else(|| std::env::var_os("PATH"))
            .unwrap_or_default();
        let name = command_file(path, cfg!(windows));
        std::env::split_paths(&search)
            .map(|dir| dir.join(&name))
            .find(|path| executable(path))
    }
    .ok_or_else(|| format!("Shell is not an executable file: {shell}"))?;
    // Resolve relative executables before changing the child's directory.
    // Legacy Windows shells (including Windows PowerShell) cannot initialize
    // when launched through a verbatim \\?\ executable path.
    let shell = match dunce::canonicalize(&shell) {
        Ok(resolved) => resolved,
        // Microsoft Store app execution aliases (WindowsApps\pwsh.exe) cannot
        // be opened as files (os error 1920), but CreateProcess starts them.
        Err(_) if cfg!(windows) && shell.is_absolute() => shell,
        Err(e) => return Err(format!("Cannot resolve shell: {e}")),
    };
    // PowerShell's update banner can fail before the first prompt when a new
    // pane is resized to a narrow grid (7.6.6 calls PadRight with a negative
    // width).
    //
    // Default interactive launches omit banners; explicit argument lists
    // remain the caller's launch contract, and profiles still run.
    let args = if cfg!(windows)
        && options.args.is_empty()
        && shell.file_stem().and_then(|s| s.to_str()).is_some_and(|s| {
            s.eq_ignore_ascii_case("pwsh") || s.eq_ignore_ascii_case("powershell")
        })
    {
        vec!["-NoLogo".into()]
    } else {
        options.args.clone()
    };
    let requested = options.cwd.as_deref().map(Path::new).or(source_cwd);
    let cwd = requested
        .map(|path| {
            if !path.is_absolute() {
                return Err("Working directory must be an absolute path".into());
            }
            if !path.is_dir() {
                return Err(format!(
                    "Working directory does not exist: {}",
                    path.display()
                ));
            }
            dunce::canonicalize(path).map_err(|e| format!("Cannot resolve working directory: {e}"))
        })
        .transpose()?;
    let mut env = options.env.clone();
    // The child starts in the resolved directory. A shell keeps a PWD naming
    // that same directory, so a path through a symlink stays as the user wrote it.
    if cfg!(unix) && !env.contains_key("PWD") {
        if let (Some(requested), Some(resolved)) = (requested, cwd.as_deref()) {
            if requested != resolved {
                env.insert("PWD".into(), requested.to_string_lossy().into_owned());
            }
        }
    }
    Ok(Prepared {
        shell,
        args,
        login: options.login.unwrap_or(cfg!(unix)),
        cwd,
        env,
        shell_integration: options.shell_integration.unwrap_or(false),
        limits: options.terminal_limits(),
    })
}

/// The file a command name refers to on `PATH`. On Windows, `nvim` is `nvim.exe`.
fn command_file(name: &Path, windows: bool) -> PathBuf {
    if windows && name.extension().is_none() { name.with_extension("exe") } else { name.to_owned() }
}

#[cfg(test)]
mod names {
    use super::command_file;
    use std::path::{Path, PathBuf};
    #[test]
    fn windows_commands_without_an_extension_are_exe_files() {
        assert_eq!(command_file(Path::new("nvim"), true), PathBuf::from("nvim.exe"));
        assert_eq!(command_file(Path::new("pwsh.exe"), true), PathBuf::from("pwsh.exe"));
        assert_eq!(command_file(Path::new("nvim"), false), PathBuf::from("nvim"));
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_working_directory_keeps_its_path_in_pwd() {
        let root = std::env::temp_dir().join(format!("graffitty-pwd-{}", std::process::id()));
        let real = root.join("real");
        let link = root.join("link");
        std::fs::create_dir_all(&real).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let options = graffitty_protocol::spawn::SpawnOptions {
            cwd: Some(link.to_string_lossy().into_owned()),
            ..Default::default()
        };
        let prepared = super::prepare(&options, "/bin/sh", None).unwrap();
        assert_eq!(prepared.cwd, Some(real.canonicalize().unwrap()));
        assert_eq!(prepared.env.get("PWD").map(String::as_str), link.to_str());
        let resolved = graffitty_protocol::spawn::SpawnOptions {
            cwd: Some(real.canonicalize().unwrap().to_string_lossy().into_owned()),
            ..Default::default()
        };
        let resolved = super::prepare(&resolved, "/bin/sh", None).unwrap();
        assert!(!resolved.env.contains_key("PWD"), "A resolved directory needs no PWD hint");
        std::fs::remove_dir_all(&root).unwrap();
    }
}

#[cfg(all(test, windows))]
mod tests {
    #[test]
    fn prepared_powershell_starts_with_a_usable_executable_path() {
        use std::os::windows::process::CommandExt;
        let shell = std::path::PathBuf::from(std::env::var_os("SystemRoot").unwrap())
            .join("System32/WindowsPowerShell/v1.0/powershell.exe");
        let options = graffitty_protocol::spawn::SpawnOptions {
            shell: Some(shell.to_str().unwrap().into()),
            ..Default::default()
        };
        let prepared = super::prepare(&options, "powershell.exe", None).unwrap();
        assert_eq!(prepared.args, ["-NoLogo"]);
        let explicit = graffitty_protocol::spawn::SpawnOptions {
            args: vec!["-NoProfile".into()],
            ..options
        };
        assert_eq!(
            super::prepare(&explicit, "powershell.exe", None).unwrap().args,
            ["-NoProfile"]
        );
        let output = std::process::Command::new(prepared.shell)
            .args([
                "-NoLogo",
                "-NoProfile",
                "-Command",
                "Write-Output GRAFFITTY_SPAWN_OK",
            ])
            .creation_flags(0x08000000)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stdout).contains("GRAFFITTY_SPAWN_OK"));
    }
}
