//! Identical session messages over private IPC or an explicitly enabled WebSocket.
//! A WebSocket client's messages are encrypted channel records from the moment
//! its password is verified; plaintext or forged records end the connection.
use graffitty_remote_auth::{Channel, Kind};
use graffitty_session_transport::{Packet, Peer};
use std::net::TcpStream;
use tungstenite::{Error, Message, WebSocket, protocol::CloseFrame};

pub enum Connection {
    Local(Peer),
    Network(NetworkPeer),
}
pub struct NetworkPeer {
    socket: WebSocket<TcpStream>,
    pending: usize,
    channel: Option<Channel>,
    loopback: bool,
}
impl NetworkPeer {
    pub fn new(socket: WebSocket<TcpStream>, loopback: bool) -> Self {
        Self { socket, pending: 0, channel: None, loopback }
    }
}
fn rejected(message: impl Into<String>) -> Error {
    Error::Io(std::io::Error::new(std::io::ErrorKind::InvalidData, message.into()))
}

/// Godot's bundled wslay rejects newer codes such as 1013 and hides the
/// original reason behind "Protocol error". Use the widely supported 1011,
/// and keep the UTF-8 reason within a control frame's 123-byte allowance.
pub fn failure_close(authenticated: bool, reason: &str) -> CloseFrame {
    let mut end = reason.len().min(123);
    while !reason.is_char_boundary(end) { end -= 1; }
    CloseFrame {
        code: if authenticated {
            tungstenite::protocol::frame::coding::CloseCode::Error
        } else {
            tungstenite::protocol::frame::coding::CloseCode::Policy
        },
        reason: reason[..end].to_owned().into(),
    }
}
impl Connection {
    #[cfg(unix)]
    pub fn raw_fd(&self) -> std::os::fd::RawFd {
        use std::os::fd::AsRawFd;
        match self {
            Self::Local(peer) => peer.raw_fd(),
            Self::Network(peer) => peer.socket.get_ref().as_raw_fd(),
        }
    }
    pub fn pending_bytes(&self) -> usize {
        match self {
            Self::Local(s) => s.pending_bytes(),
            Self::Network(peer) => peer.pending,
        }
    }
    pub fn is_local(&self) -> bool {
        matches!(self, Self::Local(_))
    }
    /// A WebSocket from this machine, which may present the local capability.
    pub fn is_loopback(&self) -> bool {
        matches!(self, Self::Network(peer) if peer.loopback)
    }
    pub fn is_cli(&self) -> bool {
        matches!(self, Self::Local(peer) if peer.is_line_mode())
    }
    /// Every later message in both directions is a channel record.
    pub fn secure(&mut self, channel: Channel) -> Result<(), Error> {
        match self {
            Self::Network(peer) if peer.channel.is_none() => {
                peer.channel = Some(channel);
                Ok(())
            }
            _ => Err(rejected("Password login is only available on network connections")),
        }
    }
    pub fn send(&mut self, message: Message) -> Result<(), Error> {
        match self {
            Self::Network(peer) => {
                let message = match (&mut peer.channel, message) {
                    (Some(channel), Message::Text(text)) => Message::Binary(
                        channel.seal(Kind::Text, text.as_bytes()).map_err(rejected)?.into(),
                    ),
                    (Some(channel), Message::Binary(bytes)) => Message::Binary(
                        channel.seal(Kind::Binary, &bytes).map_err(rejected)?.into(),
                    ),
                    (_, message) => message,
                };
                let size = message.len();
                match peer.socket.send(message) {
                    Ok(()) => {
                        peer.pending = 0;
                        Ok(())
                    }
                    Err(error) => {
                        peer.pending += size;
                        Err(error)
                    }
                }
            }
            Self::Local(s) => match message {
                Message::Text(text) => s
                    .send(Packet::Text(text.as_bytes().to_vec()))
                    .map_err(Into::into),
                Message::Binary(bytes) => {
                    s.send(Packet::Binary(bytes.to_vec())).map_err(Into::into)
                }
                _ => Ok(()),
            },
        }
    }
    pub fn read(&mut self) -> Result<Message, Error> {
        match self {
            Self::Network(peer) => match (peer.socket.read()?, &mut peer.channel) {
                (Message::Binary(record), Some(channel)) => {
                    match channel.open(&record).map_err(rejected)? {
                        (Kind::Text, bytes) => Ok(Message::Text(
                            String::from_utf8(bytes)
                                .map_err(|_| rejected("Invalid text record"))?
                                .into(),
                        )),
                        (Kind::Binary, bytes) => Ok(Message::Binary(bytes.into())),
                    }
                }
                (Message::Text(_), Some(_)) => {
                    Err(rejected("Unencrypted message on an encrypted connection"))
                }
                (message, _) => Ok(message),
            },
            Self::Local(s) => match s.read()? {
                Packet::Text(bytes) => Ok(Message::Text(
                    String::from_utf8(bytes)
                        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidData))?
                        .into(),
                )),
                Packet::Binary(bytes) => Ok(Message::Binary(bytes.into())),
            },
        }
    }
    pub fn flush(&mut self) -> Result<(), Error> {
        match self {
            Self::Network(peer) => {
                let result = peer.socket.flush();
                if result.is_ok() {
                    peer.pending = 0;
                }
                result
            }
            Self::Local(s) => s.flush().map_err(Into::into),
        }
    }
    pub fn close(&mut self, reason: Option<CloseFrame>) -> Result<(), Error> {
        match self {
            Self::Network(peer) => peer.socket.close(reason),
            Self::Local(_) => Ok(()),
        }
    }
}

/// Keep the kernel's send queue small. Backpressure then reaches the
/// owner early enough to drop stale video before it delays terminal updates.
pub fn limit_unsent(stream: &TcpStream) {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    const NOTSENT_LOWAT: libc::c_int = libc::TCP_NOTSENT_LOWAT;
    // <netinet/tcp.h>; the libc crate does not define it for Apple targets.
    #[cfg(target_vendor = "apple")]
    const NOTSENT_LOWAT: libc::c_int = 0x201;
    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    {
        use std::os::fd::AsRawFd;
        let bytes: libc::c_int = 128 * 1024;
        unsafe {
            libc::setsockopt(
                stream.as_raw_fd(),
                libc::IPPROTO_TCP,
                NOTSENT_LOWAT,
                (&bytes as *const libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
    let _ = stream;
}

/// Keep cancellable socket clones for pending HTTP and CLI handshakes.
/// Disabling sharing can then close those sockets immediately, even before
/// the client joins the authenticated list.
#[derive(Default)]
pub struct Handshakes {
    next: std::sync::atomic::AtomicU64,
    sockets: std::sync::Mutex<std::collections::HashMap<u64, TcpStream>>,
}
pub struct HandshakeLease {
    id: u64,
    registry: std::sync::Arc<Handshakes>,
}
impl Handshakes {
    pub fn track(self: &std::sync::Arc<Self>, socket: &TcpStream) -> std::io::Result<HandshakeLease> {
        let id = self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.sockets.lock().unwrap().insert(id, socket.try_clone()?);
        Ok(HandshakeLease { id, registry: self.clone() })
    }
    pub fn revoke(&self) {
        for (_, socket) in self.sockets.lock().unwrap().drain() {
            let _ = socket.shutdown(std::net::Shutdown::Both);
        }
    }
}
impl Drop for HandshakeLease {
    fn drop(&mut self) { self.registry.sockets.lock().unwrap().remove(&self.id); }
}
#[cfg(test)]
mod handshake_tests {
    use super::*;
    use std::io::Read;
    #[test]
    fn failure_close_preserves_reason_with_a_godot_compatible_code() {
        let close = failure_close(true, "Formatter hyperlink cell mismatch");
        assert_eq!(u16::from(close.code), 1011);
        assert_eq!(close.reason, "Formatter hyperlink cell mismatch");
        assert_eq!(u16::from(failure_close(false, "Invalid password").code), 1008);
        let long = failure_close(true, &"한글".repeat(100));
        assert!(long.reason.len() <= 123);
        assert!(std::str::from_utf8(long.reason.as_bytes()).is_ok());
    }
    #[test]
    fn revocation_closes_silent_handshake_without_waiting_for_timeout() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let mut peer = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        peer.set_read_timeout(Some(std::time::Duration::from_millis(200))).unwrap();
        let (server, _) = listener.accept().unwrap();
        let registry = std::sync::Arc::new(Handshakes::default());
        let _lease = registry.track(&server).unwrap();
        registry.revoke();
        assert_eq!(peer.read(&mut [0u8; 1]).unwrap(), 0);
    }
}
