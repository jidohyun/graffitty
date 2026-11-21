//! Ship the terminal description with the process that owns the shells.
use portable_pty::CommandBuilder;
use std::{
    ffi::OsString,
    fs, io,
    path::{Path, PathBuf},
};

const ENTRY: &[u8] = include_bytes!("../terminfo/xterm-ghostty");

pub fn configure(command: &mut CommandBuilder) -> io::Result<()> {
    let base = command
        .get_env("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| {
            if cfg!(windows) {
                command.get_env("LOCALAPPDATA").map(PathBuf::from)
            } else {
                command
                    .get_env("HOME")
                    .map(|home| PathBuf::from(home).join(".local/share"))
            }
        })
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "Missing user data directory for terminfo",
            )
        })?;
    let directory = install(&base.join("graffitty/terminfo"))?;
    let mut search = OsString::from(directory);
    search.push(":");
    // An empty final component retains ncurses' normal system database.
    if let Some(existing) = command.get_env("TERMINFO_DIRS") {
        search.push(existing);
    }
    command.env("TERMINFO_DIRS", search);
    Ok(())
}

fn install(root: &Path) -> io::Result<PathBuf> {
    let hash = blake3::hash(ENTRY).to_hex();
    let directory = root.join(&hash[..16]);
    // ncurses installations use either the first character or its hex value.
    for layout in ["x", "78"] {
        let parent = directory.join(layout);
        let destination = parent.join("xterm-ghostty");
        if fs::read(&destination).is_ok_and(|bytes| bytes == ENTRY) {
            continue;
        }
        fs::create_dir_all(&parent)?;
        let temporary = parent.join(format!(".xterm-ghostty-{}", uuid::Uuid::new_v4()));
        fs::write(&temporary, ENTRY)?;
        if let Err(error) = fs::rename(&temporary, &destination) {
            let _ = fs::remove_file(&temporary);
            // Another server may have finished the same installation first.
            if !fs::read(&destination).is_ok_and(|bytes| bytes == ENTRY) {
                return Err(error);
            }
        }
    }
    Ok(directory)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::process::Command;

    #[test]
    fn bundled_entry_is_readable_without_user_or_ghostty_resources() {
        let root =
            std::env::temp_dir().join(format!("graffitty-terminfo-test-{}", uuid::Uuid::new_v4()));
        let home = root.join("home");
        fs::create_dir_all(&home).unwrap();
        let mut shell = CommandBuilder::new("/bin/sh");
        shell.env_clear();
        shell.env("HOME", &home);
        shell.env("XDG_DATA_HOME", root.join("data"));
        shell.env("TERMINFO_DIRS", root.join("extra"));
        configure(&mut shell).unwrap();
        let search = shell.get_env("TERMINFO_DIRS").unwrap();
        assert!(search.to_string_lossy().ends_with("/extra"));
        let output = Command::new("/usr/bin/infocmp")
            .env_clear()
            .env("HOME", &home)
            .env("TERMINFO_DIRS", search)
            .args(["-x", "xterm-ghostty"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let capabilities = String::from_utf8(output.stdout).unwrap();
        assert!(capabilities.contains("colors#256"));
        assert!(capabilities.contains("Tc,"));
        // A damaged cache is repaired before another shell starts.
        let directory = install(&root.join("data/graffitty/terminfo")).unwrap();
        fs::write(directory.join("x/xterm-ghostty"), b"broken").unwrap();
        install(&root.join("data/graffitty/terminfo")).unwrap();
        assert_eq!(fs::read(directory.join("x/xterm-ghostty")).unwrap(), ENTRY);
        fs::remove_dir_all(root).unwrap();
    }
}
