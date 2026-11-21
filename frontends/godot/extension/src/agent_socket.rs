//! Bounded, nonblocking local transport. Authorization/dispatch live in the host.
use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use std::collections::HashMap;
use std::io::{Read, Write};
use graffitty_session_transport::local_json as transport;
use transport::{Listener, Stream};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::time::{Duration, Instant};

/// One request line, newline included. graffitty's MAX_REQUEST matches it.
const MAX_REQUEST: usize = 4 * 1024 * 1024;
/// A response may carry a whole request-sized message plus event metadata.
const MAX_RESPONSE: usize = MAX_REQUEST + 64 * 1024;

struct Peer {
    stream: Stream,
    input: Vec<u8>,
    output: Option<Vec<u8>>,
    written: usize,
    dispatched: bool,
    started: Instant,
}
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AgentSocket {
    base: Base<RefCounted>,
    listener: Option<Listener>,
    directory: String,
    peers: HashMap<i64, Peer>,
    next: i64,
}
#[godot_api]
impl IRefCounted for AgentSocket {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            listener: None,
            directory: String::new(),
            peers: HashMap::new(),
            next: 0,
        }
    }
}
#[godot_api]
impl AgentSocket {
    #[func]
    fn start(&mut self, directory: GString) -> bool {
        if self.listener.is_some() {
            return false;
        }
        let dir = directory.to_string();
        // Never reuse/remove a preexisting directory, including a symlink.
        if std::fs::create_dir(&dir).is_err() {
            return false;
        }
        self.directory = dir.clone();
        #[cfg(windows)]
        if transport::restrict_directory(std::path::Path::new(&dir)).is_err() { return false; }
        #[cfg(unix)]
        if std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).is_err() {
            return false;
        }
        let Ok(listener) = Listener::bind(std::path::Path::new(&dir)) else {
            return false;
        };
        if listener.set_nonblocking(true).is_err() {
            return false;
        }
        self.listener = Some(listener);
        true
    }
    #[func]
    fn endpoint(&self) -> GString {
        self.listener.as_ref().and_then(|s| s.endpoint(std::path::Path::new(&self.directory)).ok()).unwrap_or_default().as_str().into()
    }
    #[func]
    fn poll(&mut self) -> Array<VarDictionary> {
        let mut requests = Array::new();
        if let Some(listener) = &self.listener {
            for _ in 0..8 {
                if self.peers.len() >= 64 {
                    break;
                }
                let Ok(stream) = listener.accept() else {
                    break;
                };
                if stream.set_nonblocking(true).is_err() {
                    continue;
                }
                stream.grow_send_buffer(MAX_RESPONSE + 1);
                self.next += 1;
                self.peers.insert(
                    self.next,
                    Peer {
                        stream,
                        input: Vec::new(),
                        output: None,
                        written: 0,
                        dispatched: false,
                        started: Instant::now(),
                    },
                );
            }
        }
        self.peers.retain(|id, peer| {
            if peer.started.elapsed() > Duration::from_secs(65) {
                return false;
            }
            // Move everything the kernel accepts now: multi-MiB lines must not
            // advance one small chunk per frame.
            if let Some(output) = &peer.output {
                while peer.written < output.len() {
                    match peer.stream.write(&output[peer.written..]) {
                        Ok(0) => return false,
                        Ok(n) => peer.written += n,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(_) => return false,
                    }
                }
                return peer.written < output.len();
            }
            if !peer.dispatched {
                let mut buffer = [0u8; 65536];
                let mut complete = false;
                while !complete {
                    match peer.stream.read(&mut buffer) {
                        Ok(0) => return false,
                        Ok(n) => {
                            peer.input.extend_from_slice(&buffer[..n]);
                            complete = buffer[..n].contains(&b'\n');
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(_) => return false,
                    }
                    if peer.input.len() > MAX_REQUEST {
                        return false;
                    }
                }
                let end = if complete {
                    peer.input.iter().position(|b| *b == b'\n')
                } else {
                    None
                };
                if let Some(end) = end {
                    let Ok(json) = std::str::from_utf8(&peer.input[..end]) else {
                        return false;
                    };
                    let mut item = VarDictionary::new();
                    item.set("peer", *id);
                    item.set("json", json);
                    requests.push(&item);
                    peer.dispatched = true;
                }
            }
            true
        });
        requests
    }
    #[func]
    fn respond(&mut self, id: i64, json: GString) {
        if let Some(peer) = self.peers.get_mut(&id) {
            let mut bytes = json.to_string().into_bytes();
            if bytes.len() > MAX_RESPONSE {
                bytes = br#"{"error":{"code":"response_too_large","message":"Response exceeds 4 MiB"}}"#.to_vec();
            }
            bytes.push(b'\n');
            peer.output = Some(bytes);
        }
    }
}
impl Drop for AgentSocket {
    fn drop(&mut self) {
        self.listener = None;
        if !self.directory.is_empty() {
            let _ = std::fs::remove_file(format!("{}/api.sock", self.directory));
            let _ = std::fs::remove_dir(&self.directory);
        }
    }
}
