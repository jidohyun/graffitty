//! Small process/file differences used by the CLI. Windows files inherit their parent ACL.
#[cfg(unix)]
pub use std::os::unix::fs::OpenOptionsExt;
#[cfg(windows)]
pub trait OpenOptionsExt { fn mode(&mut self, mode: u32) -> &mut Self; }
#[cfg(windows)]
impl OpenOptionsExt for std::fs::OpenOptions { fn mode(&mut self, _: u32) -> &mut Self { self } }
#[cfg(windows)]
pub trait CommandExt { fn exec(&mut self) -> std::io::Error; }
#[cfg(windows)]
impl CommandExt for std::process::Command {
    fn exec(&mut self) -> std::io::Error {
        match self.status() { Ok(status) => std::process::exit(status.code().unwrap_or(1)), Err(error) => error }
    }
}
#[cfg(unix)]
pub fn symlink_file(target: &std::path::Path, link: &std::path::Path) -> std::io::Result<()> { std::os::unix::fs::symlink(target, link) }
#[cfg(windows)]
pub fn symlink_file(target: &std::path::Path, link: &std::path::Path) -> std::io::Result<()> { std::os::windows::fs::symlink_file(target, link) }

#[cfg(windows)]
pub fn processes() -> Vec<(i64, i64, String, String)> {
    use windows_sys::Win32::{Foundation::{CloseHandle, INVALID_HANDLE_VALUE, FILETIME}, System::{Diagnostics::ToolHelp::*, Threading::*}};
    let mut rows = Vec::new();
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE { return rows; }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of_val(&entry) as u32;
        let mut valid = Process32FirstW(snapshot, &mut entry) != 0;
        while valid {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID);
            if !handle.is_null() {
                let mut start: FILETIME = std::mem::zeroed();
                let mut exit = start; let mut kernel = start; let mut user = start;
                if GetProcessTimes(handle, &mut start, &mut exit, &mut kernel, &mut user) != 0 {
                    let mut path = vec![0u16; 32768]; let mut length = path.len() as u32;
                    let executable = if QueryFullProcessImageNameW(handle, 0, path.as_mut_ptr(), &mut length) != 0 {
                        String::from_utf16_lossy(&path[..length as usize])
                    } else { String::from_utf16_lossy(&entry.szExeFile[..entry.szExeFile.iter().position(|x| *x == 0).unwrap_or(entry.szExeFile.len())]) };
                    rows.push((entry.th32ProcessID as i64, entry.th32ParentProcessID as i64,
                        (((start.dwHighDateTime as u64) << 32) | start.dwLowDateTime as u64).to_string(), executable));
                }
                CloseHandle(handle);
            }
            valid = Process32NextW(snapshot, &mut entry) != 0;
        }
        CloseHandle(snapshot);
    }
    rows
}
#[cfg(windows)]
pub fn listener_ports(pid: i64) -> std::collections::HashSet<u16> {
    use windows_sys::Win32::{NetworkManagement::IpHelper::*, Networking::WinSock::AF_INET};
    let mut bytes = 0u32;
    unsafe { GetExtendedTcpTable(std::ptr::null_mut(), &mut bytes, 0, AF_INET as u32, TCP_TABLE_OWNER_PID_LISTENER, 0); }
    if bytes == 0 { return Default::default(); }
    let mut buffer = vec![0u32; (bytes as usize).div_ceil(4)];
    let ok = unsafe { GetExtendedTcpTable(buffer.as_mut_ptr().cast(), &mut bytes, 0, AF_INET as u32, TCP_TABLE_OWNER_PID_LISTENER, 0) };
    if ok != 0 { return Default::default(); }
    let table = buffer.as_ptr().cast::<MIB_TCPTABLE_OWNER_PID>();
    let count = unsafe { (*table).dwNumEntries as usize };
    if 4 + count * std::mem::size_of::<MIB_TCPROW_OWNER_PID>() > buffer.len() * 4 { return Default::default(); }
    let rows = unsafe { std::slice::from_raw_parts(std::ptr::addr_of!((*table).table).cast::<MIB_TCPROW_OWNER_PID>(), count) };
    rows.iter().filter(|row| row.dwOwningPid as i64 == pid).map(|row| u16::from_be(row.dwLocalPort as u16)).collect()
}

#[cfg(all(test, windows))]
mod tests {
    #[test]
    fn windows_inventory_finds_current_process_and_tcp_listener() {
        let pid = std::process::id() as i64;
        let rows = super::processes();
        let current = rows.iter().find(|row| row.0 == pid).expect("current process missing");
        assert!(!current.2.is_empty());
        assert!(current.3.to_lowercase().ends_with(".exe"));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        assert!(super::listener_ports(pid).contains(&listener.local_addr().unwrap().port()));
    }
}
