//! Local authenticated JSON transport. Unix keeps domain sockets; Windows uses loopback TCP.
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::time::Duration;

pub enum Stream {
    Ipc(crate::BlockingStream),
    Tcp(TcpStream),
    #[cfg(unix)]
    Unix(UnixStream),
}
impl Stream {
    pub fn connect(endpoint: &str) -> io::Result<Self> {
        if endpoint.starts_with("ipc://") {
            return Ok(Self::Ipc(crate::BlockingStream::connect(endpoint)?));
        }
        if let Some(address) = endpoint.strip_prefix("tcp://") {
            let address: SocketAddr = address
                .parse()
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "Invalid TCP endpoint"))?;
            if !address.ip().is_loopback() {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "Graph TCP endpoint must be loopback",
                ));
            }
            let stream = TcpStream::connect_timeout(&address, Duration::from_secs(5))?;
            stream.set_nodelay(true)?;
            return Ok(Self::Tcp(stream));
        }
        #[cfg(unix)]
        {
            Ok(Self::Unix(UnixStream::connect(endpoint)?))
        }
        #[cfg(not(unix))]
        {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "Windows requires a tcp://127.0.0.1:port graph endpoint",
            ))
        }
    }
    pub fn set_read_timeout(&self, value: Option<Duration>) -> io::Result<()> {
        match self {
            Self::Ipc(s) => s.set_read_timeout(value),
            Self::Tcp(s) => s.set_read_timeout(value),
            #[cfg(unix)]
            Self::Unix(s) => s.set_read_timeout(value),
        }
    }
    pub fn set_write_timeout(&self, value: Option<Duration>) -> io::Result<()> {
        match self {
            Self::Ipc(s) => s.set_write_timeout(value),
            Self::Tcp(s) => s.set_write_timeout(value),
            #[cfg(unix)]
            Self::Unix(s) => s.set_write_timeout(value),
        }
    }
    pub fn set_nonblocking(&self, value: bool) -> io::Result<()> {
        match self {
            Self::Ipc(s) => s.set_nonblocking(value),
            Self::Tcp(s) => s.set_nonblocking(value),
            #[cfg(unix)]
            Self::Unix(s) => s.set_nonblocking(value),
        }
    }
    pub fn grow_send_buffer(&self, bytes: usize) {
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            let fd = match self {
                Self::Ipc(_) => return,
                Self::Tcp(s) => s.as_raw_fd(),
                Self::Unix(s) => s.as_raw_fd(),
            };
            let size = bytes.min(i32::MAX as usize) as libc::c_int;
            unsafe {
                libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_SNDBUF,
                    (&size as *const libc::c_int).cast(),
                    std::mem::size_of_val(&size) as libc::socklen_t,
                );
            }
        }
        #[cfg(not(unix))]
        let _ = bytes;
    }
}
impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Ipc(s) => s.read(buf),
            Self::Tcp(s) => s.read(buf),
            #[cfg(unix)]
            Self::Unix(s) => s.read(buf),
        }
    }
}
impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Self::Ipc(s) => s.write(buf),
            Self::Tcp(s) => s.write(buf),
            #[cfg(unix)]
            Self::Unix(s) => s.write(buf),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Ipc(s) => s.flush(),
            Self::Tcp(s) => s.flush(),
            #[cfg(unix)]
            Self::Unix(s) => s.flush(),
        }
    }
}
pub enum Listener {
    Tcp(TcpListener),
    #[cfg(unix)]
    Unix(UnixListener),
}
impl Listener {
    pub fn bind(directory: &Path) -> io::Result<Self> {
        #[cfg(unix)]
        {
            Ok(Self::Unix(UnixListener::bind(directory.join("api.sock"))?))
        }
        #[cfg(not(unix))]
        {
            let _ = directory;
            Ok(Self::Tcp(TcpListener::bind((
                std::net::Ipv4Addr::LOCALHOST,
                0,
            ))?))
        }
    }
    pub fn endpoint(&self, _directory: &Path) -> io::Result<String> {
        match self {
            Self::Tcp(s) => Ok(format!("tcp://{}", s.local_addr()?)),
            #[cfg(unix)]
            Self::Unix(_) => Ok(_directory.join("api.sock").to_string_lossy().into_owned()),
        }
    }
    pub fn set_nonblocking(&self, value: bool) -> io::Result<()> {
        match self {
            Self::Tcp(s) => s.set_nonblocking(value),
            #[cfg(unix)]
            Self::Unix(s) => s.set_nonblocking(value),
        }
    }
    pub fn accept(&self) -> io::Result<Stream> {
        match self {
            Self::Tcp(s) => {
                let (stream, peer) = s.accept()?;
                if !peer.ip().is_loopback() {
                    return Err(io::ErrorKind::PermissionDenied.into());
                }
                stream.set_nodelay(true)?;
                Ok(Stream::Tcp(stream))
            }
            #[cfg(unix)]
            Self::Unix(s) => Ok(Stream::Unix(s.accept()?.0)),
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn tcp_round_trip_and_loopback_restriction() {
        let listener = Listener::Tcp(TcpListener::bind("127.0.0.1:0").unwrap());
        let endpoint = listener.endpoint(Path::new("")).unwrap();
        let worker = std::thread::spawn(move || {
            let mut stream = listener.accept().unwrap();
            let mut bytes = [0; 4];
            stream.read_exact(&mut bytes).unwrap();
            assert_eq!(&bytes, b"ping");
            stream.write_all(b"pong").unwrap();
        });
        let mut stream = Stream::connect(&endpoint).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        stream.write_all(b"ping").unwrap();
        let mut bytes = [0; 4];
        stream.read_exact(&mut bytes).unwrap();
        assert_eq!(&bytes, b"pong");
        worker.join().unwrap();
        assert!(Stream::connect("tcp://192.0.2.1:1234").is_err());
        assert!(Stream::connect("tcp://localhost:1234").is_err());
    }
}

/// Restrict even a custom TEMP location to the current Windows identity.
#[cfg(windows)]
pub fn restrict_directory(path: &Path) -> io::Result<()> {
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    let system = std::path::PathBuf::from(
        std::env::var_os("SystemRoot").ok_or_else(|| io::Error::other("Missing SystemRoot"))?,
    )
    .join("System32");
    let user = Command::new(system.join("whoami.exe"))
        .args(["/user", "/fo", "csv", "/nh"])
        .creation_flags(0x08000000)
        .output()?;
    if !user.status.success() {
        return Err(io::Error::other("Cannot resolve current Windows user"));
    }
    let output = String::from_utf8_lossy(&user.stdout);
    let sid = output
        .trim()
        .split(',')
        .next_back()
        .unwrap_or("")
        .trim_matches('"');
    if !sid.starts_with("S-1-") || !sid[4..].bytes().all(|c| c.is_ascii_digit() || c == b'-') {
        return Err(io::Error::other("Invalid Windows SID"));
    }
    let status = Command::new(system.join("icacls.exe"))
        .arg(path)
        .args(["/inheritance:r", "/grant:r", &format!("*{sid}:(OI)(CI)F")])
        .creation_flags(0x08000000)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if !status.success() {
        return Err(io::Error::other("Cannot restrict agent runtime directory"));
    }
    Ok(())
}
