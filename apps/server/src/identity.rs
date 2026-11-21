/// Preserve the operating system's hostname spelling for remote display names.
pub fn hostname() -> String {
    #[cfg(unix)]
    {
        let mut bytes = [0u8; 256];
        // Leave a terminating byte even on systems that truncate without NUL.
        if unsafe { libc::gethostname(bytes.as_mut_ptr().cast(), bytes.len() - 1) } == 0 {
            let end = bytes.iter().position(|&byte| byte == 0).unwrap_or(bytes.len());
            return String::from_utf8_lossy(&bytes[..end]).trim().to_owned();
        }
    }
    std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .unwrap_or_default()
}

/// The server process's OS account, not an environment variable or a client guess.
/// Unavailable identity is omitted from the UI rather than invented.
pub fn username() -> String {
    #[cfg(unix)]
    {
        let mut buffer = vec![0u8; 1024];
        loop {
            let mut account = std::mem::MaybeUninit::<libc::passwd>::uninit();
            let mut result = std::ptr::null_mut();
            let status = unsafe {
                libc::getpwuid_r(libc::geteuid(), account.as_mut_ptr(), buffer.as_mut_ptr().cast(), buffer.len(), &mut result)
            };
            if status == libc::ERANGE && buffer.len() < 64 * 1024 {
                buffer.resize(buffer.len() * 2, 0);
                continue;
            }
            if status == 0 && !result.is_null() {
                let name = unsafe { (*result).pw_name };
                if !name.is_null() {
                    return display_username(unsafe { std::ffi::CStr::from_ptr(name) }.to_string_lossy().as_ref());
                }
            }
            break;
        }
    }
    #[cfg(windows)]
    {
        #[link(name = "advapi32")]
        unsafe extern "system" {
            fn GetUserNameW(buffer: *mut u16, size: *mut u32) -> i32;
        }
        let mut buffer = [0u16; 257]; // UNLEN + NUL.
        let mut length = buffer.len() as u32;
        if unsafe { GetUserNameW(buffer.as_mut_ptr(), &mut length) } != 0 {
            let end = buffer.iter().position(|&ch| ch == 0).unwrap_or(buffer.len());
            return display_username(&String::from_utf16_lossy(&buffer[..end]));
        }
    }
    String::new()
}

fn display_username(name: &str) -> String {
    if name.len() > 255 || name.chars().any(char::is_control) { String::new() } else { name.trim().to_owned() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_metadata_is_safe_for_display_and_persistence() {
        assert_eq!(display_username("Developer"), "Developer");
        assert_eq!(display_username("bad\nname"), "");
        assert_eq!(display_username(&"x".repeat(256)), "");
        let account = username();
        assert!(account.len() <= 255 && !account.chars().any(char::is_control));
    }
}
