use super::{Result, WindowSize, protocol};
use std::io::Write;
use std::time::Duration;

fn graphics_reply(bytes: &[u8], id: u32) -> bool {
    let text = String::from_utf8_lossy(bytes);
    text.split("\x1b_G").skip(1).any(|packet| {
        let Some((packet, _)) = packet.split_once("\x1b\\") else {
            return false;
        };
        let Some((keys, response)) = packet.split_once(';') else {
            return false;
        };
        response == "OK" && keys.split(',').any(|key| key == format!("i={id}"))
    })
}

fn device_attributes(bytes: &[u8]) -> bool {
    bytes
        .windows(3)
        .enumerate()
        .filter(|(_, prefix)| *prefix == b"\x1b[?")
        .any(|(start, _)| {
            let tail = &bytes[start + 3..];
            tail.iter()
                .position(|&c| !(c.is_ascii_digit() || c == b';'))
                .is_some_and(|end| tail[end] == b'c')
        })
}

pub(super) fn detect(timeout: Duration) -> Result<&'static str> {
    let mut tty = Tty::open()?;
    let mut probes = Vec::new();
    for (index, mode) in ["stream", "file", "memory"].iter().enumerate() {
        if let Ok(payload) = protocol::Payload::new(mode, &[0, 0, 0]) {
            let id = index as u32 + 1;
            protocol::command(
                &mut tty,
                &format!("a=q,f=24,s=1,v=1,i={id},{}", payload.keys()),
                payload.data(),
                false,
            )?;
            probes.push(payload);
        }
    }
    tty.write_all(b"\x1b[c")?;
    tty.flush()?;
    let response = tty.response(timeout)?;
    if !graphics_reply(&response, 1) {
        return Err("This terminal did not confirm Kitty graphics support; use --transfer-mode=stream to skip detection when support is known".into());
    }
    Ok(if graphics_reply(&response, 3) {
        "memory"
    } else if graphics_reply(&response, 2) {
        "file"
    } else {
        "stream"
    })
}

pub(super) fn hold() -> Result<()> {
    Tty::open()?.wait_for_key()
}

pub(super) fn window_size(timeout: Duration) -> Result<WindowSize> {
    let mut size = native_window_size()?;
    if size.width == 0 || size.height == 0 || size.columns == 0 || size.rows == 0 {
        let mut tty = Tty::open()?;
        tty.write_all(b"\x1b[14t\x1b[18t\x1b[c")?;
        tty.flush()?;
        let response = tty.response(timeout)?;
        for packet in String::from_utf8_lossy(&response).split("\x1b[").skip(1) {
            let Some((parameters, _)) = packet.split_once('t') else {
                continue;
            };
            let values: Vec<u32> = parameters
                .split(';')
                .filter_map(|part| part.parse().ok())
                .collect();
            match values.as_slice() {
                [4, height, width] => {
                    size.width = *width;
                    size.height = *height;
                }
                [8, rows, columns] => {
                    size.rows = *rows;
                    size.columns = *columns;
                }
                _ => (),
            }
        }
    }
    size.validate()
}

#[cfg(unix)]
fn native_window_size() -> Result<WindowSize> {
    use std::os::fd::AsRawFd;
    let mut size = std::mem::MaybeUninit::<libc::winsize>::zeroed();
    // SAFETY: TIOCGWINSZ writes a winsize into this valid, initialized buffer.
    let got_size = unsafe {
        libc::ioctl(
            std::io::stdout().as_raw_fd(),
            libc::TIOCGWINSZ,
            size.as_mut_ptr(),
        )
    } == 0;
    if !got_size {
        // fzf captures stdout and runs previews in a background process group.
        // Reading the window size is safe there; changing termios would suspend
        // the preview with SIGTTOU before it can emit an image.
        let file = std::fs::File::open("/dev/tty")?;
        if unsafe {
            libc::ioctl(
                file.as_raw_fd(),
                libc::TIOCGWINSZ,
                size.as_mut_ptr(),
            )
        } != 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
    }
    let size = unsafe { size.assume_init() };
    Ok(WindowSize {
        columns: size.ws_col.into(),
        rows: size.ws_row.into(),
        width: size.ws_xpixel.into(),
        height: size.ws_ypixel.into(),
    })
}

/// The console reports its grid but never pixels; the terminal answers CSI 14 t.
#[cfg(windows)]
fn native_window_size() -> Result<WindowSize> {
    use windows_sys::Win32::System::Console::{CONSOLE_SCREEN_BUFFER_INFO, GetConsoleScreenBufferInfo};
    // CONOUT$ is the attached console even when stdout is captured (fzf previews).
    let output = Console::open("CONOUT$")?;
    // SAFETY: the info buffer is writable and output is a live console handle.
    let mut info: CONSOLE_SCREEN_BUFFER_INFO = unsafe { std::mem::zeroed() };
    if unsafe { GetConsoleScreenBufferInfo(output.0, &mut info) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let window = info.srWindow;
    Ok(WindowSize {
        columns: (window.Right - window.Left + 1).max(0) as u32,
        rows: (window.Bottom - window.Top + 1).max(0) as u32,
        width: 0,
        height: 0,
    })
}

#[cfg(unix)]
struct Tty {
    file: std::fs::File,
    saved: libc::termios,
}

#[cfg(unix)]
impl Tty {
    fn open() -> Result<Self> {
        use std::os::fd::AsRawFd;
        let file = std::fs::OpenOptions::new().read(true).write(true).open("/dev/tty")
            .map_err(|error| format!("Cannot open controlling terminal: {error}. For scripts, pass --stdin=no --use-window-size=COLS,ROWS,WIDTH,HEIGHT --transfer-mode=stream"))?;
        let mut saved = std::mem::MaybeUninit::<libc::termios>::uninit();
        // SAFETY: tcgetattr initializes saved on success; file owns the FD.
        if unsafe { libc::tcgetattr(file.as_raw_fd(), saved.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let saved = unsafe { saved.assume_init() };
        let mut raw = saved;
        unsafe {
            libc::cfmakeraw(&mut raw);
        }
        if unsafe { libc::tcsetattr(file.as_raw_fd(), libc::TCSANOW, &raw) } != 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(Self { file, saved })
    }

    fn read(&mut self, timeout: Duration) -> Result<Vec<u8>> {
        use std::io::Read;
        use std::os::fd::AsRawFd;
        let fd = self.file.as_raw_fd();
        if fd as usize >= libc::FD_SETSIZE {
            return Err("Terminal file descriptor exceeds select capacity".into());
        }
        let timeout = timeout.min(Duration::from_secs(60));
        let mut wait = libc::timeval {
            tv_sec: timeout.as_secs() as _,
            tv_usec: timeout.subsec_micros() as _,
        };
        // macOS poll(2) reports POLLNVAL for /dev/tty. select(2) supports
        // that device on both macOS and Linux.
        // SAFETY: FD_SET is bounded above; select receives initialized storage
        // and one live descriptor owned by this object.
        let ready = unsafe {
            let mut set = std::mem::zeroed::<libc::fd_set>();
            libc::FD_ZERO(&mut set);
            libc::FD_SET(fd, &mut set);
            libc::select(
                fd + 1,
                &mut set,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut wait,
            )
        };
        if ready < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        if ready == 0 {
            return Ok(Vec::new());
        }
        let mut bytes = [0u8; 4096];
        let count = self.file.read(&mut bytes)?;
        if count == 0 {
            return Err("Controlling terminal closed".into());
        }
        if bytes[..count].contains(&3) {
            return Err("Interrupted".into());
        }
        Ok(bytes[..count].to_vec())
    }

}

impl Tty {
    fn response(&mut self, timeout: Duration) -> Result<Vec<u8>> {
        let start = std::time::Instant::now();
        let mut bytes = Vec::new();
        while start.elapsed() < timeout {
            bytes.extend_from_slice(&self.read(timeout.saturating_sub(start.elapsed()))?);
            if device_attributes(&bytes) {
                return Ok(bytes);
            }
            if bytes.len() > 64 * 1024 {
                return Err("Terminal query response exceeds 64 KiB".into());
            }
        }
        Err("Timed out waiting for terminal response".into())
    }

    fn wait_for_key(&mut self) -> Result<()> {
        while self.read(Duration::from_secs(60))?.is_empty() {}
        Ok(())
    }
}

#[cfg(unix)]
impl Write for Tty {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.file.write(bytes)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

#[cfg(unix)]
impl Drop for Tty {
    fn drop(&mut self) {
        use std::os::fd::AsRawFd;
        // SAFETY: saved was obtained for this file, whose lifetime includes drop.
        unsafe {
            libc::tcsetattr(self.file.as_raw_fd(), libc::TCSANOW, &self.saved);
        }
    }
}

/// A handle to the process's console (CONIN$ or CONOUT$), even when standard
/// streams are redirected.
#[cfg(windows)]
struct Console(windows_sys::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl Console {
    fn open(name: &str) -> Result<Self> {
        use windows_sys::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::Storage::FileSystem::{CreateFileW, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING};
        let path: Vec<u16> = name.encode_utf16().chain([0]).collect();
        // SAFETY: path is NUL-terminated; the returned handle is owned by Console.
        let handle = unsafe {
            CreateFileW(path.as_ptr(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                std::ptr::null(), OPEN_EXISTING, 0, std::ptr::null_mut())
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(format!("Cannot open console {name}: {}. For scripts, pass --stdin=no --use-window-size=COLS,ROWS,WIDTH,HEIGHT --transfer-mode=stream",
                std::io::Error::last_os_error()).into());
        }
        Ok(Self(handle))
    }

    fn mode(&self) -> Result<u32> {
        let mut mode = 0;
        // SAFETY: mode is writable and self.0 is a live console handle.
        if unsafe { windows_sys::Win32::System::Console::GetConsoleMode(self.0, &mut mode) } == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(mode)
    }

    fn set_mode(&self, mode: u32) -> Result<()> {
        // SAFETY: self.0 is a live console handle.
        if unsafe { windows_sys::Win32::System::Console::SetConsoleMode(self.0, mode) } == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        Ok(())
    }
}

#[cfg(windows)]
impl Drop for Console {
    fn drop(&mut self) {
        // SAFETY: Console owns this handle.
        unsafe { windows_sys::Win32::Foundation::CloseHandle(self.0) };
    }
}

/// Raw VT console input, the Windows counterpart of a raw /dev/tty: terminal
/// replies arrive as characters, and Ctrl+C as byte 3.
#[cfg(windows)]
struct Tty {
    input: Console,
    output: Console,
    input_mode: u32,
    output_mode: u32,
}

#[cfg(windows)]
impl Tty {
    fn open() -> Result<Self> {
        use windows_sys::Win32::System::Console::{
            ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, ENABLE_PROCESSED_INPUT,
            ENABLE_VIRTUAL_TERMINAL_INPUT, ENABLE_VIRTUAL_TERMINAL_PROCESSING,
        };
        let input = Console::open("CONIN$")?;
        let output = Console::open("CONOUT$")?;
        let input_mode = input.mode()?;
        let output_mode = output.mode()?;
        let tty = Self { input, output, input_mode, output_mode };
        tty.input.set_mode(
            input_mode & !(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)
                | ENABLE_VIRTUAL_TERMINAL_INPUT,
        )?;
        tty.output.set_mode(output_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING)?;
        Ok(tty)
    }

    fn read(&mut self, timeout: Duration) -> Result<Vec<u8>> {
        use windows_sys::Win32::Foundation::{WAIT_OBJECT_0, WAIT_TIMEOUT};
        use windows_sys::Win32::System::Console::{INPUT_RECORD, KEY_EVENT, ReadConsoleInputW};
        use windows_sys::Win32::System::Threading::WaitForSingleObject;
        let millis = timeout.min(Duration::from_secs(60)).as_millis() as u32;
        // SAFETY: input is a live console handle.
        match unsafe { WaitForSingleObject(self.input.0, millis) } {
            WAIT_OBJECT_0 => (),
            WAIT_TIMEOUT => return Ok(Vec::new()),
            _ => return Err(std::io::Error::last_os_error().into()),
        }
        // The handle is signaled by any input record; focus, mouse and resize
        // records carry no characters and are consumed here.
        let mut records: [INPUT_RECORD; 512] = unsafe { std::mem::zeroed() };
        let mut count = 0;
        // SAFETY: records is writable for its length; count receives the number read.
        if unsafe { ReadConsoleInputW(self.input.0, records.as_mut_ptr(), records.len() as u32, &mut count) } == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let mut units = Vec::new();
        for record in &records[..count as usize] {
            if u32::from(record.EventType) != KEY_EVENT {
                continue;
            }
            // SAFETY: EventType selects the KeyEvent member.
            let key = unsafe { record.Event.KeyEvent };
            let unit = unsafe { key.uChar.UnicodeChar };
            if key.bKeyDown != 0 && unit != 0 {
                units.extend(std::iter::repeat_n(unit, usize::from(key.wRepeatCount.max(1))));
            }
        }
        let bytes = String::from_utf16_lossy(&units).into_bytes();
        if bytes.contains(&3) {
            return Err("Interrupted".into());
        }
        Ok(bytes)
    }
}

#[cfg(windows)]
impl Write for Tty {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        use windows_sys::Win32::System::Console::WriteConsoleW;
        // Queries and probes are ASCII escape sequences.
        let text: Vec<u16> = String::from_utf8_lossy(bytes).encode_utf16().collect();
        let mut offset = 0;
        while offset < text.len() {
            let mut written = 0;
            let remaining = &text[offset..];
            // SAFETY: remaining is readable for its length; output is a live console handle.
            if unsafe { WriteConsoleW(self.output.0, remaining.as_ptr().cast(), remaining.len() as u32, &mut written, std::ptr::null()) } == 0 {
                return Err(std::io::Error::last_os_error());
            }
            offset += written as usize;
        }
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(windows)]
impl Drop for Tty {
    fn drop(&mut self) {
        let _ = self.input.set_mode(self.input_mode);
        let _ = self.output.set_mode(self.output_mode);
    }
}
