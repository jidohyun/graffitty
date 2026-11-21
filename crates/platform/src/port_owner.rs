//! Name the process listening on a TCP port, for "address in use" messages.
//!
//! Best effort: another user's process is often not visible, and then the
//! caller says only that some program holds the port.
use std::net::SocketAddr;

pub struct Owner {
    pub pid: u32,
    /// The program's file name without directory or `.exe`.
    pub name: String,
}

impl Owner {
    /// True for a Graffitty session server, which runs as `gft`.
    pub fn is_graffitty(&self) -> bool {
        self.name.eq_ignore_ascii_case("gft")
    }
}

pub fn listening(address: SocketAddr) -> Option<Owner> {
    let pid = pid(address.port())?;
    Some(Owner { pid, name: name(pid)? })
}

#[cfg(target_os = "linux")]
fn pid(port: u16) -> Option<u32> {
    // A listening socket's inode, then the process holding a descriptor to it.
    let mut inodes = Vec::new();
    for table in ["/proc/net/tcp", "/proc/net/tcp6"] {
        for line in std::fs::read_to_string(table).unwrap_or_default().lines().skip(1) {
            let fields: Vec<&str> = line.split_whitespace().collect();
            // local_address is `HEXIP:HEXPORT`; state 0A is LISTEN.
            let (Some(local), Some(state), Some(inode)) = (fields.get(1), fields.get(3), fields.get(9)) else { continue };
            let listens = local.rsplit(':').next().and_then(|hex| u16::from_str_radix(hex, 16).ok()) == Some(port);
            if listens && *state == "0A" {
                inodes.push(format!("socket:[{inode}]"));
            }
        }
    }
    if inodes.is_empty() {
        return None;
    }
    for process in std::fs::read_dir("/proc").ok()?.flatten() {
        let Some(pid) = process.file_name().to_str().and_then(|name| name.parse::<u32>().ok()) else { continue };
        let Ok(descriptors) = std::fs::read_dir(process.path().join("fd")) else { continue };
        for descriptor in descriptors.flatten() {
            if std::fs::read_link(descriptor.path()).is_ok_and(|target| inodes.iter().any(|inode| target.as_os_str() == inode.as_str())) {
                return Some(pid);
            }
        }
    }
    None
}

#[cfg(target_os = "linux")]
fn name(pid: u32) -> Option<String> {
    let path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    Some(path.file_name()?.to_string_lossy().into_owned())
}

#[cfg(target_os = "macos")]
fn pid(port: u16) -> Option<u32> {
    // `-F` output is one field per line and not translated: `p<pid>`.
    let output = std::process::Command::new("/usr/sbin/lsof")
        .args(["-nP", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-Fp"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    String::from_utf8_lossy(&output.stdout).lines().find_map(|line| line.strip_prefix('p')?.parse().ok())
}

#[cfg(target_os = "macos")]
fn name(pid: u32) -> Option<String> {
    let mut buffer = [0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
    // SAFETY: the kernel writes at most `buffer.len()` bytes into the buffer.
    let length = unsafe { libc::proc_pidpath(i32::try_from(pid).ok()?, buffer.as_mut_ptr().cast(), buffer.len() as u32) };
    if length <= 0 {
        return None;
    }
    let path = std::path::PathBuf::from(String::from_utf8_lossy(&buffer[..length as usize]).into_owned());
    Some(path.file_name()?.to_string_lossy().into_owned())
}

#[cfg(windows)]
#[allow(non_snake_case)]
mod windows {
    use std::ffi::c_void;

    /// `MIB_TCPROW_OWNER_PID`: every field is a 32-bit value; ports are in
    /// network byte order in the low 16 bits.
    #[repr(C)]
    #[derive(Clone, Copy)]
    pub struct Row {
        pub state: u32,
        pub local_address: u32,
        pub local_port: u32,
        pub remote_address: u32,
        pub remote_port: u32,
        pub pid: u32,
    }

    #[link(name = "iphlpapi")]
    unsafe extern "system" {
        pub fn GetExtendedTcpTable(table: *mut c_void, size: *mut u32, order: i32, family: u32, class: u32, reserved: u32) -> u32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        pub fn OpenProcess(access: u32, inherit: i32, pid: u32) -> *mut c_void;
        pub fn QueryFullProcessImageNameW(process: *mut c_void, flags: u32, name: *mut u16, size: *mut u32) -> i32;
        pub fn CloseHandle(handle: *mut c_void) -> i32;
    }
    pub const AF_INET: u32 = 2;
    pub const TCP_TABLE_OWNER_PID_LISTENER: u32 = 3;
    pub const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
    pub const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
}

#[cfg(windows)]
fn pid(port: u16) -> Option<u32> {
    use windows::*;
    let mut size = 0u32;
    // SAFETY: a null table with size 0 only reports the size needed.
    let status = unsafe { GetExtendedTcpTable(std::ptr::null_mut(), &mut size, 0, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) };
    if status != ERROR_INSUFFICIENT_BUFFER {
        return None;
    }
    // u32 storage keeps the table aligned for its 32-bit fields.
    let mut table = vec![0u32; (size as usize).div_ceil(4) + 64];
    size = (table.len() * 4) as u32;
    // SAFETY: the table is `size` bytes long and the call writes within it.
    if unsafe { GetExtendedTcpTable(table.as_mut_ptr().cast(), &mut size, 0, AF_INET, TCP_TABLE_OWNER_PID_LISTENER, 0) } != 0 {
        return None;
    }
    // `MIB_TCPTABLE_OWNER_PID`: a count, then that many rows of six u32.
    let count = table[0] as usize;
    table[1..].chunks_exact(6).take(count).find_map(|row| {
        let row = Row { state: row[0], local_address: row[1], local_port: row[2], remote_address: row[3], remote_port: row[4], pid: row[5] };
        (u16::from_be(row.local_port as u16) == port).then_some(row.pid)
    })
}

#[cfg(windows)]
fn name(pid: u32) -> Option<String> {
    use windows::*;
    // SAFETY: the handle is checked, used for one query and closed.
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return None;
        }
        let mut buffer = [0u16; 1024];
        let mut length = buffer.len() as u32;
        let found = QueryFullProcessImageNameW(process, 0, buffer.as_mut_ptr(), &mut length);
        CloseHandle(process);
        if found == 0 {
            return None;
        }
        let path = std::path::PathBuf::from(String::from_utf16_lossy(&buffer[..length as usize]));
        Some(path.file_stem()?.to_string_lossy().into_owned())
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn pid(_port: u16) -> Option<u32> {
    None
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn name(_pid: u32) -> Option<String> {
    None
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos", windows)))]
mod tests {
    #[test]
    fn names_this_process_for_a_port_it_listens_on() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let owner = super::listening(listener.local_addr().unwrap()).expect("the listener's owner");
        assert_eq!(owner.pid, std::process::id());
        assert!(!owner.name.is_empty());
        assert!(!owner.is_graffitty(), "{}", owner.name);
    }
}
