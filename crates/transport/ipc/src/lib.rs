//! Private, bounded session IPC and local JSON connections.
//! Session framing uses local sockets; [`local_json`] additionally supports
//! explicit loopback TCP addresses for local command tools.
pub mod local_json;
use interprocess::local_socket::{
    GenericFilePath, Stream, prelude::*,
};
#[cfg(unix)]
use interprocess::local_socket::{Listener, ListenerNonblockingMode, ListenerOptions};
#[cfg(windows)]
pub type Listener = interprocess::os::windows::named_pipe::PipeListener<
    interprocess::os::windows::named_pipe::pipe_mode::Bytes,
    interprocess::os::windows::named_pipe::pipe_mode::Bytes,
>;
use std::{
    collections::VecDeque,
    io::{self, Read, Write},
    path::Path,
};

pub const MAX_PACKET: usize = 8 * 1024 * 1024;
pub const MAX_PENDING: usize = 16 * 1024 * 1024;

/// An owned, non-consuming readiness probe. The duplicate prevents a closed
/// descriptor being reused underneath a window's background wake monitor.
pub struct Readiness {
    #[cfg(unix)]
    handle: std::os::fd::OwnedFd,
    #[cfg(windows)]
    handle: std::os::windows::io::OwnedHandle,
}
impl Readiness {
    pub fn is_ready(&self) -> bool {
        #[cfg(unix)] {
            use std::os::fd::AsRawFd;
            let mut fd = libc::pollfd { fd: self.handle.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            // EOF and errors also wake the owner so it can retire the session.
            unsafe { libc::poll(&mut fd, 1, 0) != 0 }
        }
        #[cfg(windows)] {
            use std::os::windows::io::AsRawHandle;
            let mut bytes = 0;
            let ok = unsafe { windows_sys::Win32::System::Pipes::PeekNamedPipe(
                self.handle.as_raw_handle(), std::ptr::null_mut(), 0,
                std::ptr::null_mut(), &mut bytes, std::ptr::null_mut()) };
            ok == 0 || bytes > 0
        }
    }
}

pub fn bind(path: &Path) -> io::Result<Listener> {
    #[cfg(unix)]
    let name = path.to_fs_name::<GenericFilePath>()?;
    #[cfg(unix)]
    let options = ListenerOptions::new()
        .name(name)
        .nonblocking(ListenerNonblockingMode::Both);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::other("Missing IPC directory"))?;
        let metadata = std::fs::symlink_metadata(parent)?;
        if !metadata.is_dir() || metadata.permissions().mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "IPC directory must be private (0700)",
            ));
        }
    }
    #[cfg(windows)]
    let listener = {
        use interprocess::os::windows::{
            named_pipe::PipeListenerOptions, security_descriptor::SecurityDescriptor,
        };
        use std::{os::windows::process::CommandExt, process::Command};
        let system = std::path::PathBuf::from(
            std::env::var_os("SystemRoot").ok_or_else(|| io::Error::other("Missing SystemRoot"))?,
        )
        .join("System32");
        let output = Command::new(system.join("whoami.exe"))
            .args(["/user", "/fo", "csv", "/nh"])
            .creation_flags(0x08000000)
            .output()?;
        if !output.status.success() {
            return Err(io::Error::other("Cannot resolve current user"));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let sid = text
            .trim()
            .split(',')
            .next_back()
            .unwrap_or("")
            .trim_matches('"');
        if !sid.starts_with("S-1-") || !sid[4..].bytes().all(|b| b.is_ascii_digit() || b == b'-') {
            return Err(io::Error::other("Invalid current-user SID"));
        }
        let sddl = widestring::U16CString::from_str(format!("D:P(A;;GA;;;{sid})"))
            .map_err(io::Error::other)?;
        let mut options = PipeListenerOptions::new();
        options.path = widestring::U16CString::from_os_str(path.as_os_str())
            .map_err(io::Error::other)?.into();
        options.nonblocking = true;
        // The local-socket wrapper defaults to 512 bytes. Large graph replies
        // then need hundreds of owner wakeups and can exceed RPC deadlines.
        options.input_buffer_size_hint = 65536;
        options.output_buffer_size_hint = 65536;
        options.security_descriptor = Some(SecurityDescriptor::deserialize(&sddl)?);
        options.create()?
    };
    #[cfg(unix)]
    let listener = options.create_sync()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(listener)
}

pub fn connect(endpoint: &str) -> io::Result<Stream> {
    let path = endpoint
        .strip_prefix("ipc://")
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Expected ipc:// endpoint"))?;
    let stream = Stream::connect(path.to_fs_name::<GenericFilePath>()?)?;
    stream.set_nonblocking(true)?;
    Ok(stream)
}

pub fn accept(listener: &Listener) -> io::Result<Stream> {
    #[cfg(unix)]
    { listener.accept() }
    #[cfg(windows)]
    {
        listener.accept().map(|pipe| {
            interprocess::os::windows::named_pipe::local_socket::Stream::from(pipe).into()
        })
    }
}

/// Unframed private transport for protocols that supply their own framing.
/// Uses the same bounded, nonblocking native I/O as session IPC.
pub struct ControlStream(Stream);
impl ControlStream {
    pub fn accept(listener: &Listener) -> io::Result<Self> {
        accept(listener).map(Self)
    }
    #[cfg(windows)]
    pub fn client_process_id(&self) -> io::Result<u32> {
        use std::os::windows::io::{AsHandle, AsRawHandle};
        let Stream::NamedPipe(pipe) = &self.0;
        let mut pid = 0;
        if unsafe { windows_sys::Win32::System::Pipes::GetNamedPipeClientProcessId(
            pipe.as_handle().as_raw_handle(), &mut pid) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(pid)
    }
}
impl Read for ControlStream {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        read_stream(&mut self.0, bytes)
    }
}
impl Write for ControlStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        write_stream(&mut self.0, bytes)
    }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}

fn read_stream(stream: &mut Stream, bytes: &mut [u8]) -> io::Result<usize> {
    if bytes.is_empty() {
        return Ok(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::{AsHandle, AsRawHandle};
        use windows_sys::Win32::System::Pipes::PeekNamedPipe;
        let Stream::NamedPipe(pipe) = stream;
        let mut available = 0;
        // interprocess's byte reader converts ERROR_NO_DATA on an idle
        // nonblocking pipe to zero bytes, which is indistinguishable from EOF.
        // Peek first so idle connections retain normal WouldBlock semantics.
        let success = unsafe {
            PeekNamedPipe(
                pipe.as_handle().as_raw_handle(),
                std::ptr::null_mut(),
                0,
                std::ptr::null_mut(),
                &mut available,
                std::ptr::null_mut(),
            )
        };
        if success == 0 {
            let error = io::Error::last_os_error();
            if matches!(error.raw_os_error(), Some(109 | 233)) {
                return Ok(0);
            }
            return Err(error);
        }
        if available == 0 {
            return Err(io::ErrorKind::WouldBlock.into());
        }
        let count = bytes.len().min(available as usize);
        return pipe.read(&mut bytes[..count]);
    }
    #[cfg(not(windows))]
    stream.read(bytes)
}

fn write_stream(stream: &mut Stream, bytes: &[u8]) -> io::Result<usize> {
    #[cfg(unix)]
    {
        use std::os::fd::{AsFd, AsRawFd};
        let Stream::UdSocket(socket) = stream;
        // Rust executables ignore SIGPIPE, but an embedded client (Godot) may
        // not. A closing owner must produce a write error, not kill its host.
        //
        // Suppress the signal for this send only; do not change process
        // policy.
        let sent = unsafe {
            libc::send(socket.as_fd().as_raw_fd(), bytes.as_ptr().cast(), bytes.len(), libc::MSG_NOSIGNAL)
        };
        if sent < 0 { Err(io::Error::last_os_error()) } else { Ok(sent as usize) }
    }
    // The default interprocess named pipe has a 512-byte buffer. Windows
    // nonblocking writes larger than its capacity can make no progress.
    #[cfg(windows)]
    {
    let bytes = &bytes[..bytes.len().min(512)];
    match stream.write(bytes) {
        // A nonblocking Windows byte pipe reports a full buffer as success
        // with zero bytes. Retain the queued packet and retry after draining.
        Ok(0) if cfg!(windows) && !bytes.is_empty() => Err(io::ErrorKind::WouldBlock.into()),
        result => result,
    }
    }
}

#[cfg(unix)]
pub fn listener_fd(listener: &Listener) -> std::os::fd::RawFd {
    use std::os::fd::{AsFd, AsRawFd};
    let Listener::UdSocket(listener) = listener;
    listener.as_fd().as_raw_fd()
}

/// Deadline-aware byte stream for the existing one-request CLI API.
pub struct BlockingStream {
    stream: Stream,
    read_timeout: std::cell::Cell<Option<std::time::Duration>>,
    write_timeout: std::cell::Cell<Option<std::time::Duration>>,
    nonblocking: std::cell::Cell<bool>,
}
impl BlockingStream {
    pub fn connect(endpoint: &str) -> io::Result<Self> {
        Ok(Self {
            stream: connect(endpoint)?,
            read_timeout: Default::default(),
            write_timeout: Default::default(),
            nonblocking: Default::default(),
        })
    }
    pub fn set_read_timeout(&self, timeout: Option<std::time::Duration>) -> io::Result<()> {
        self.read_timeout.set(timeout);
        Ok(())
    }
    pub fn set_write_timeout(&self, timeout: Option<std::time::Duration>) -> io::Result<()> {
        self.write_timeout.set(timeout);
        Ok(())
    }
    pub fn set_nonblocking(&self, value: bool) -> io::Result<()> {
        self.nonblocking.set(value);
        Ok(())
    }
    #[cfg(windows)]
    pub fn server_process_id(&self) -> io::Result<u32> {
        use std::os::windows::io::{AsHandle, AsRawHandle};
        let Stream::NamedPipe(pipe) = &self.stream;
        let mut pid = 0;
        if unsafe { windows_sys::Win32::System::Pipes::GetNamedPipeServerProcessId(
            pipe.as_handle().as_raw_handle(), &mut pid
        ) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(pid)
    }
}
fn wait_io<T>(
    nonblocking: bool,
    timeout: Option<std::time::Duration>,
    mut operation: impl FnMut() -> io::Result<T>,
) -> io::Result<T> {
    let started = std::time::Instant::now();
    loop {
        match operation() {
            Err(e) if !nonblocking && e.kind() == io::ErrorKind::WouldBlock => {
                if timeout.is_some_and(|t| started.elapsed() >= t) {
                    return Err(io::ErrorKind::TimedOut.into());
                }
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
            result => return result,
        }
    }
}
impl Read for BlockingStream {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        wait_io(self.nonblocking.get(), self.read_timeout.get(), || {
            read_stream(&mut self.stream, bytes)
        })
    }
}
impl Write for BlockingStream {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        wait_io(self.nonblocking.get(), self.write_timeout.get(), || {
            write_stream(&mut self.stream, bytes)
        })
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Debug, PartialEq)]
pub enum Packet {
    Text(Vec<u8>),
    Binary(Vec<u8>),
}

/// One nonblocking connection; partial reads/writes never lose packet boundaries.
pub struct Peer {
    stream: Stream,
    input: Vec<u8>,
    output: VecDeque<Vec<u8>>,
    written: usize,
    pending: usize,
    line_mode: bool,
}

impl Peer {
    /// Kernel peer identity, used to bind native resource exchange to this
    /// connection. A forwarded Unix socket identifies the relay process.
    pub fn local_peer_pid(&self) -> Option<u32> {
        #[cfg(windows)]
        {
            use std::os::windows::io::{AsHandle, AsRawHandle};
            use windows_sys::Win32::System::Pipes::{GetNamedPipeInfo, GetNamedPipeClientProcessId, GetNamedPipeServerProcessId, PIPE_SERVER_END};
            let Stream::NamedPipe(pipe) = &self.stream;
            let handle = pipe.as_handle().as_raw_handle();
            let (mut flags, mut pid) = (0, 0);
            let ok = unsafe {
                if GetNamedPipeInfo(handle, &mut flags, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()) == 0 { return None; }
                if flags & PIPE_SERVER_END != 0 { GetNamedPipeClientProcessId(handle, &mut pid) }
                else { GetNamedPipeServerProcessId(handle, &mut pid) }
            };
            if ok != 0 && pid > 0 { return Some(pid); }
        }
        #[cfg(target_os = "macos")]
        {
            let mut pid: libc::pid_t = 0;
            let mut size = std::mem::size_of_val(&pid) as libc::socklen_t;
            let result = unsafe {
                libc::getsockopt(
                    self.raw_fd(),
                    libc::SOL_LOCAL,
                    libc::LOCAL_PEERPID,
                    (&mut pid as *mut libc::pid_t).cast(),
                    &mut size,
                )
            };
            if result == 0 && pid > 0 {
                return Some(pid as u32);
            }
        }
        None
    }
    pub fn pending_bytes(&self) -> usize {
        self.pending
    }
    pub fn readiness(&self) -> io::Result<Readiness> {
        #[cfg(unix)] {
            use std::os::fd::AsFd;
            let Stream::UdSocket(stream) = &self.stream;
            Ok(Readiness { handle: stream.as_fd().try_clone_to_owned()? })
        }
        #[cfg(windows)] {
            use std::os::windows::io::AsHandle;
            let Stream::NamedPipe(stream) = &self.stream;
            Ok(Readiness { handle: stream.as_handle().try_clone_to_owned()? })
        }
    }
    #[cfg(unix)]
    pub fn raw_fd(&self) -> std::os::fd::RawFd {
        use std::os::fd::{AsFd, AsRawFd};
        let Stream::UdSocket(stream) = &self.stream;
        stream.as_fd().as_raw_fd()
    }
    pub fn new(stream: Stream) -> Self {
        Self {
            stream,
            input: Vec::new(),
            output: VecDeque::new(),
            written: 0,
            pending: 0,
            line_mode: false,
        }
    }
    pub fn is_line_mode(&self) -> bool {
        self.line_mode
    }
    pub fn send(&mut self, packet: Packet) -> io::Result<()> {
        let (kind, data) = match packet {
            Packet::Text(b) => (1u8, b),
            Packet::Binary(b) => (2u8, b),
        };
        if data.len() > MAX_PACKET || self.pending + data.len() + 5 > MAX_PENDING {
            return Err(io::Error::other("Session output limit reached"));
        }
        let mut bytes = Vec::with_capacity(data.len() + 5);
        if !self.line_mode {
            bytes.push(kind);
            bytes.extend_from_slice(&(data.len() as u32).to_le_bytes());
        }
        bytes.extend_from_slice(&data);
        if self.line_mode {
            bytes.push(b'\n');
        }
        self.pending += bytes.len();
        self.output.push_back(bytes);
        // Successful enqueue owns the packet even when the kernel is full.
        match self.flush() {
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(()),
            result => result,
        }
    }
    pub fn flush(&mut self) -> io::Result<()> {
        while let Some(bytes) = self.output.front() {
            let n = write_stream(&mut self.stream, &bytes[self.written..])?;
            if n == 0 {
                return Err(io::ErrorKind::WriteZero.into());
            }
            self.written += n;
            self.pending -= n;
            if self.written == bytes.len() {
                self.output.pop_front();
                self.written = 0;
            }
        }
        Ok(())
    }
    pub fn read(&mut self) -> io::Result<Packet> {
        loop {
            if self.input.first() == Some(&b'{') {
                self.line_mode = true;
            }
            if self.line_mode {
                if let Some(end) = self.input.iter().position(|b| *b == b'\n') {
                    let mut data: Vec<_> = self.input.drain(..=end).collect();
                    data.pop();
                    return Ok(Packet::Text(data));
                }
            } else if self.input.len() >= 5 {
                let kind = self.input[0];
                let size = u32::from_le_bytes(self.input[1..5].try_into().unwrap()) as usize;
                if ![1, 2].contains(&kind) || size > MAX_PACKET {
                    return Err(io::ErrorKind::InvalidData.into());
                }
                if self.input.len() >= size + 5 {
                    let bytes: Vec<_> = self.input.drain(..size + 5).skip(5).collect();
                    return Ok(if kind == 1 {
                        Packet::Text(bytes)
                    } else {
                        Packet::Binary(bytes)
                    });
                }
            }
            if self.input.len() > MAX_PACKET + 5 {
                return Err(io::ErrorKind::InvalidData.into());
            }
            let mut buffer = [0; 65536];
            let n = read_stream(&mut self.stream, &mut buffer)?;
            if n == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            self.input.extend_from_slice(&buffer[..n]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        thread,
        time::{Duration, Instant},
    };
    fn receive(peer: &mut Peer) -> Packet {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match peer.read() {
                Ok(p) => return p,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(1))
                }
                Err(e) => panic!("{e}"),
            }
        }
    }
    #[cfg(unix)]
    #[test]
    fn closed_peer_returns_error_without_sigpipe() {
        // Changing the signal disposition in the ordinary parallel test runner
        // would affect unrelated tests, so reproduce Godot's policy in a child.
        if std::env::var_os("GR_IPC_SIGPIPE_CHILD").is_none() {
            let result = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", "tests::closed_peer_returns_error_without_sigpipe"])
                .env("GR_IPC_SIGPIPE_CHILD", "1")
                .output().unwrap();
            assert!(result.status.success(), "Child failed: {:?} {}", result.status, String::from_utf8_lossy(&result.stderr));
            return;
        }
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = directory.path().join("s");
        let listener = bind(&path).unwrap();
        let mut peer = Peer::new(connect(&format!("ipc://{}", path.display())).unwrap());
        drop(accept(&listener).unwrap());
        unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL); }
        assert_eq!(peer.read().unwrap_err().kind(), io::ErrorKind::UnexpectedEof);
        assert_eq!(peer.send(Packet::Text(b"detach".to_vec())).unwrap_err().kind(), io::ErrorKind::BrokenPipe);
    }
    #[test]
    fn private_packet_round_trip_and_bounds() {
        let dir = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        #[cfg(unix)]
        let path = dir.path().join("session.sock");
        #[cfg(windows)]
        let path =
            std::path::PathBuf::from(format!(r"\\.\pipe\graffitty-test-{}", std::process::id()));
        let listener = bind(&path).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let mut client = Peer::new(connect(&format!("ipc://{}", path.display())).unwrap());
        let mut server = Peer::new(accept(&listener).unwrap());
        #[cfg(any(windows, target_os = "macos"))]
        {
            assert_eq!(client.local_peer_pid(), Some(std::process::id()));
            assert_eq!(server.local_peer_pid(), Some(std::process::id()));
        }
        assert_eq!(client.read().unwrap_err().kind(), io::ErrorKind::WouldBlock);
        assert_eq!(server.read().unwrap_err().kind(), io::ErrorKind::WouldBlock);
        client.send(Packet::Text(b"hello".to_vec())).unwrap();
        assert_eq!(receive(&mut server), Packet::Text(b"hello".to_vec()));
        server.send(Packet::Binary(vec![0, 1, 2, 255])).unwrap();
        assert_eq!(receive(&mut client), Packet::Binary(vec![0, 1, 2, 255]));
        let payload = vec![42; 1024 * 1024];
        client.send(Packet::Binary(payload.clone())).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if let Err(error) = client.flush() {
                assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
            }
            match server.read() {
                Ok(packet) => {
                    assert_eq!(packet, Packet::Binary(payload));
                    break;
                }
                Err(error) => assert_eq!(error.kind(), io::ErrorKind::WouldBlock),
            }
            assert!(
                Instant::now() < deadline,
                "Backpressured packet stalled: {} bytes pending, {} received",
                client.pending,
                server.input.len()
            );
            // Exercise backpressure with the paced polling used by the owner,
            // rather than a busy loop that hides tiny Windows pipe buffers.
            thread::sleep(Duration::from_millis(1));
        }
        assert!(
            client
                .send(Packet::Binary(vec![0; MAX_PACKET + 1]))
                .is_err()
        );
        assert!(connect("tcp://127.0.0.1:1234").is_err());
        drop(server);
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let kind = client.read().unwrap_err().kind();
            if kind == io::ErrorKind::WouldBlock && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(1));
                continue;
            }
            assert_eq!(kind, io::ErrorKind::UnexpectedEof);
            break;
        }
    }
    #[test]
    fn fragmented_frames_and_cli_lines() {
        let dir = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        #[cfg(unix)]
        let path = dir.path().join("fragment.sock");
        #[cfg(windows)]
        let path = std::path::PathBuf::from(format!(
            r"\\.\pipe\graffitty-fragment-{}",
            std::process::id()
        ));
        let listener = bind(&path).unwrap();
        let mut stream = connect(&format!("ipc://{}", path.display())).unwrap();
        let mut server = Peer::new(accept(&listener).unwrap());
        stream.write_all(&[1, 3]).unwrap();
        assert_eq!(server.read().unwrap_err().kind(), io::ErrorKind::WouldBlock);
        stream.write_all(&[0, 0, 0, b'a', b'b', b'c']).unwrap();
        assert_eq!(receive(&mut server), Packet::Text(b"abc".to_vec()));
        drop(server);
        drop(stream);
        let mut stream = connect(&format!("ipc://{}", path.display())).unwrap();
        let mut server = Peer::new(accept(&listener).unwrap());
        stream.write_all(b"{\"method\":\"ping\"}\n").unwrap();
        assert_eq!(
            receive(&mut server),
            Packet::Text(b"{\"method\":\"ping\"}".to_vec())
        );
        assert!(server.is_line_mode());
    }
}
