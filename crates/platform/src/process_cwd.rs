//! Read a process directory as native path bytes, never human-formatted lsof text.
use std::path::PathBuf;

pub fn for_pid(pid: u32) -> Option<PathBuf> {
    if pid == 0 {
        return None;
    }
    #[cfg(target_os = "linux")]
    {
        std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
    }
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStringExt;
        let pid = i32::try_from(pid).ok()?;
        let mut info = std::mem::MaybeUninit::<libc::proc_vnodepathinfo>::zeroed();
        let size = std::mem::size_of::<libc::proc_vnodepathinfo>();
        // The kernel writes this fixed-size, zero-initialized C record. Read its
        // fields only after a complete reply; paths remain native byte strings.
        let count = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDVNODEPATHINFO,
                0,
                info.as_mut_ptr().cast(),
                size as i32,
            )
        };
        if count != size as i32 {
            return None;
        }
        let info = unsafe { info.assume_init() };
        let bytes: Vec<u8> = info
            .pvi_cdir
            .vip_path
            .iter()
            .flatten()
            .map(|v| *v as u8)
            .collect();
        let end = bytes.iter().position(|b| *b == 0)?;
        if end == 0 {
            return None;
        }
        Some(std::ffi::OsString::from_vec(bytes[..end].to_vec()).into())
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        None
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests {
    use super::*;
    #[test]
    fn live_child_directory_preserves_unicode_backslashes_and_newlines() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("graffitty-cwd-{}-{unique}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        let directory = root.join("spaces Ω ' \\xce\\xa9\nsecond line");
        std::fs::create_dir(&directory).unwrap();
        struct Guard(std::process::Child, PathBuf);
        impl Drop for Guard {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
                let _ = std::fs::remove_dir_all(&self.1);
            }
        }
        let child = std::process::Command::new("/bin/sh")
            .args(["-c", "sleep 30"])
            .current_dir(&directory)
            .spawn()
            .unwrap();
        let guard = Guard(child, root);
        assert_eq!(
            for_pid(guard.0.id()).unwrap(),
            directory.canonicalize().unwrap()
        );
        assert!(for_pid(0).is_none());
    }
}
