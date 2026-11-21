//! Bounded NUL-delimited CDP messages over a private nonblocking transport.
use std::{
    collections::VecDeque,
    io::{Read, Write},
    thread,
    time::Duration,
};
use tungstenite::Message;
pub trait Duplex: Read + Write + Send {}
impl<T: Read + Write + Send> Duplex for T {}
pub struct Control {
    stream: Box<dyn Duplex>,
    buffer: Vec<u8>,
    output: VecDeque<Vec<u8>>,
    output_offset: usize,
    output_bytes: usize,
}
const CONTROL_LIMIT: usize = 32 * 1024 * 1024;
impl Control {
    pub fn new(stream: impl Duplex + 'static) -> std::io::Result<Self> {
        // CDP can send large scripts while Chromium is sending events. Neither
        // direction may block the other, and a partial write must retain its
        // exact offset until the socket becomes writable again.
        Ok(Self {
            stream: Box::new(stream),
            buffer: Vec::new(),
            output: VecDeque::new(),
            output_offset: 0,
            output_bytes: 0,
        })
    }
    pub fn send(&mut self, message: Message) -> Result<(), tungstenite::Error> {
        let Message::Text(text) = message else {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "Chromium control accepts only text messages",
            )
            .into());
        };
        if text.len().saturating_add(1) > CONTROL_LIMIT.saturating_sub(self.output_bytes) {
            return Err(tungstenite::Error::WriteBufferFull(Box::new(
                Message::Text(text),
            )));
        }
        let mut bytes = Vec::with_capacity(text.len() + 1);
        bytes.extend_from_slice(text.as_bytes());
        bytes.push(0);
        self.output_bytes += bytes.len();
        self.output.push_back(bytes);
        self.flush()?;
        Ok(())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        while let Some(bytes) = self.output.front() {
            match self.stream.write(&bytes[self.output_offset..]) {
                Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
                Ok(count) => {
                    self.output_offset += count;
                    self.output_bytes -= count;
                    if self.output_offset == bytes.len() {
                        self.output.pop_front();
                        self.output_offset = 0;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
    pub fn read(&mut self) -> Result<Message, tungstenite::Error> {
        self.flush()?;
        loop {
            if let Some(end) = self.buffer.iter().position(|b| *b == 0) {
                let bytes: Vec<_> = self.buffer.drain(..=end).collect();
                return Ok(Message::Text(
                    String::from_utf8_lossy(&bytes[..end]).into_owned().into(),
                ));
            }
            if self.buffer.len() > CONTROL_LIMIT {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "Chromium control message exceeds the 32 MiB limit",
                )
                .into());
            }
            let mut bytes = [0; 65536];
            let n = match self.stream.read(&mut bytes) {
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    // Preserve the old two-millisecond idle polling budget;
                    // an empty nonblocking socket must not spin the worker.
                    thread::sleep(Duration::from_millis(2));
                    return Err(error.into());
                }
                result => result?,
            };
            if n == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "Chromium host closed its private control connection",
                )
                .into());
            }
            self.buffer.extend_from_slice(&bytes[..n]);
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;
    use std::time::Instant;

    #[test]
    fn control_preserves_partial_writes_and_reads_under_backpressure() {
        let (stream, mut peer) = UnixStream::pair().unwrap();
        peer.set_nonblocking(true).unwrap();
        stream.set_nonblocking(true).unwrap();
        let mut control = Control::new(stream).unwrap();
        let large = "x".repeat(4 * 1024 * 1024);
        control.send(Message::Text(large.clone().into())).unwrap();
        control.send(Message::Text("second".into())).unwrap();
        assert!(
            control.output_bytes > 0,
            "fixture must fill the socket buffer"
        );
        peer.write_all(b"{\"id\":1}\0").unwrap();
        assert_eq!(control.read().unwrap(), Message::Text("{\"id\":1}".into()));

        let expected = [large.as_bytes(), b"\0second\0"].concat();
        let mut received = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(5);
        while received.len() < expected.len() && Instant::now() < deadline {
            let mut chunk = [0; 65536];
            match peer.read(&mut chunk) {
                Ok(count) => received.extend_from_slice(&chunk[..count]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                result => panic!("unexpected socket result: {result:?}"),
            }
            assert!(matches!(control.read(), Err(tungstenite::Error::Io(error))
                if error.kind() == std::io::ErrorKind::WouldBlock));
        }
        assert_eq!(
            received, expected,
            "partial frames must neither repeat nor truncate"
        );
        assert_eq!(control.output_bytes, 0);
        assert!(control.output.is_empty());
    }

    #[test]
    fn private_control_eof_is_not_a_normal_websocket_close() {
        let (stream, peer) = UnixStream::pair().unwrap();
        let mut control = Control::new(stream).unwrap();
        drop(peer);
        assert!(matches!(control.read(), Err(tungstenite::Error::Io(error))
            if error.kind() == std::io::ErrorKind::UnexpectedEof
                && error.to_string().contains("Chromium host")));
    }

    #[test]
    fn control_rejects_output_beyond_its_bound_without_enqueuing_it() {
        let (stream, _peer) = UnixStream::pair().unwrap();
        stream.set_nonblocking(true).unwrap();
        let mut control = Control::new(stream).unwrap();
        control
            .send(Message::Text("x".repeat(CONTROL_LIMIT - 1).into()))
            .unwrap();
        let remaining = control.output_bytes;
        assert!(remaining > 0);
        let rejected = "y".repeat(CONTROL_LIMIT - remaining);
        assert!(matches!(
            control.send(Message::Text(rejected.into())),
            Err(tungstenite::Error::WriteBufferFull(_))
        ));
        assert_eq!(control.output_bytes, remaining);
    }
}

#[cfg(all(test, windows))]
mod windows_tests {
    use super::*;
    use graffitty_session_transport::{self as ipc, ControlStream};
    use std::time::Instant;

    #[test]
    fn private_pipe_checks_peer_and_keeps_duplex_progress_under_backpressure() {
        let path = std::path::PathBuf::from(format!(
            r"\\.\pipe\graffitty-control-test-{}",
            uuid::Uuid::new_v4()
        ));
        let listener = ipc::bind(&path).unwrap();
        let mut peer = ipc::connect(&format!("ipc://{}", path.display())).unwrap();
        let stream = ControlStream::accept(&listener).unwrap();
        assert_eq!(stream.client_process_id().unwrap(), std::process::id());
        let mut control = Control::new(stream).unwrap();
        let payload = "x".repeat(1024 * 1024);
        control.send(Message::Text(payload.clone().into())).unwrap();
        assert!(
            control.output_bytes > 0,
            "fixture must fill the native pipe"
        );
        peer.write_all(b"{\"id\":7}\0").unwrap();
        assert_eq!(control.read().unwrap(), Message::Text("{\"id\":7}".into()));
        let mut received = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(10);
        while received.len() < payload.len() + 1 {
            let mut bytes = [0; 65536];
            match peer.read(&mut bytes) {
                Ok(count) => received.extend_from_slice(&bytes[..count]),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                result => panic!("unexpected pipe result: {result:?}"),
            }
            assert!(matches!(control.read(), Err(tungstenite::Error::Io(error))
                if error.kind() == std::io::ErrorKind::WouldBlock));
            assert!(Instant::now() < deadline, "CDP output stalled");
        }
        assert_eq!(received, [payload.as_bytes(), b"\0"].concat());
        assert_eq!(control.output_bytes, 0);
    }
}
