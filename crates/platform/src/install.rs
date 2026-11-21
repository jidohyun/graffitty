//! Paths to installed executables that stay valid after an upgrade.
use std::path::{Path, PathBuf};

/// Returns a path to `exe` that still works after an upgrade.
///
/// Linux keeps each version in its own directory, `installs/<version>`. The
/// link `installs/current` points to the version in use.
///
/// An upgrade deletes old version directories, so a long-running process (the
/// session server, a terminal's `gft`) must use the path through `current`.
///
/// Other platforms replace the executable in place, so `exe` is returned
/// unchanged.
pub fn stable_path(exe: &Path) -> PathBuf {
    for version in exe.ancestors().skip(1) {
        let Some(installs) = version.parent() else { break };
        let current = installs.join("current");
        let linked = std::fs::symlink_metadata(&current).is_ok_and(|m| m.file_type().is_symlink());
        if linked
            && let Ok(rest) = exe.strip_prefix(version)
            && current.join(rest).is_file()
        {
            return current.join(rest);
        }
    }
    exe.to_path_buf()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_versioned_installation_is_addressed_through_its_current_link() {
        let root = std::env::temp_dir().join(format!("graffitty-install-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for version in ["0.1.0", "0.2.0"] {
            std::fs::create_dir_all(root.join(version).join("tools")).unwrap();
            std::fs::write(root.join(version).join("tools/gft"), version).unwrap();
        }
        std::os::unix::fs::symlink("0.2.0", root.join("current")).unwrap();
        // An older version's path maps to `current` too: it restarts as the new version.
        for version in ["0.1.0", "0.2.0"] {
            assert_eq!(stable_path(&root.join(version).join("tools/gft")), root.join("current/tools/gft"));
        }
        // A file that the current version does not have keeps its own path.
        std::fs::write(root.join("0.1.0/tools/old"), "").unwrap();
        assert_eq!(stable_path(&root.join("0.1.0/tools/old")), root.join("0.1.0/tools/old"));
        std::fs::remove_file(root.join("current")).unwrap();
        assert_eq!(stable_path(&root.join("0.2.0/tools/gft")), root.join("0.2.0/tools/gft"));
        std::fs::remove_dir_all(&root).unwrap();
    }
}
