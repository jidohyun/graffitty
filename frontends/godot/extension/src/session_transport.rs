//! Thin IPC client. Session semantics live exclusively in gft.
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_session_transport::{self as ipc, Packet, Peer};

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SessionTransport {
    base: Base<RefCounted>,
    peer: Option<Peer>,
    error: String,
}
#[godot_api]
impl IRefCounted for SessionTransport {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            peer: None,
            error: String::new(),
        }
    }
}
#[godot_api]
impl SessionTransport {
    #[func]
    fn connect_private(&mut self, endpoint: GString) -> bool {
        self.peer = None;
        self.error.clear();
        match ipc::connect(&endpoint.to_string()) {
            Ok(stream) => {
                self.peer = Some(Peer::new(stream));
                true
            }
            Err(error) => {
                self.error = error.to_string();
                false
            }
        }
    }
    #[func]
    fn is_open(&self) -> bool {
        self.peer.is_some()
    }
    #[func]
    fn last_error(&self) -> GString {
        self.error.as_str().into()
    }
    #[func]
    fn disconnect_private(&mut self) {
        self.peer = None;
    }
    #[func]
    fn send_packet(&mut self, bytes: PackedByteArray, text: bool) -> bool {
        let Some(peer) = &mut self.peer else {
            return false;
        };
        let packet = if text {
            Packet::Text(bytes.to_vec())
        } else {
            Packet::Binary(bytes.to_vec())
        };
        match peer.send(packet) {
            Ok(()) => true,
            Err(error) => {
                self.error = error.to_string();
                self.peer = None;
                false
            }
        }
    }
    #[func]
    fn poll_packets(&mut self) -> Array<VarDictionary> {
        let mut packets = Array::new();
        let Some(peer) = &mut self.peer else {
            return packets;
        };
        let result = (|| -> std::io::Result<()> {
            match peer.flush() {
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                result => result?,
            }
            let mut total = 0;
            for _ in 0..128 {
                let packet = match peer.read() {
                    Ok(packet) => packet,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                    Err(e) => return Err(e),
                };
                let (text, data) = match packet {
                    Packet::Text(bytes) => (true, bytes),
                    Packet::Binary(bytes) => (false, bytes),
                };
                total += data.len();
                let mut item = VarDictionary::new();
                item.set("text", text);
                item.set("data", &PackedByteArray::from(data.as_slice()));
                packets.push(&item);
                if total >= ipc::MAX_PACKET {
                    break;
                }
            }
            Ok(())
        })();
        if let Err(error) = result {
            self.error = error.to_string();
            self.peer = None;
        }
        packets
    }
}
