//! The owner's UDP endpoint for Chromium video.
//!
//! - Listen on the remote listener's address and port number. TCP and UDP
//!   can use the same number.
//! - After encrypted login, send the port and SSRC in `ready` to clients that
//!   advertised `video-datagram-v1`.
//! - The client sends hello packets to open NAT and firewall state. Switch
//!   video to UDP after the client confirms a reply.
//! - Return video to the WebSocket when hellos stop. Clients whose SSH tunnel
//!   or proxy cannot carry UDP stay on the WebSocket.
use crate::{Client, chromium_flow::Flow};
use graffitty_video_datagram as wire;
use std::{
    collections::HashMap,
    net::{SocketAddr, TcpListener, UdpSocket},
    time::{Duration, Instant},
};

pub const FEATURE: &str = "video-datagram-v1";
/// Clients send a hello at least every second while connected.
const SILENT: Duration = Duration::from_secs(3);
/// Pacing bounds in bytes per second.
const MIN_RATE: f64 = 1.0e6;
const MAX_RATE: f64 = 125.0e6;

#[derive(Default)]
pub struct Datagrams {
    endpoint: Option<(UdpSocket, SocketAddr)>,
    failed: Option<SocketAddr>,
}

pub struct Peer {
    pub sender: wire::Sender,
    address: Option<SocketAddr>,
    pub active: bool,
    heard: Instant,
    traced: Option<(Instant, wire::SenderStats)>,
}

impl Peer {
    pub fn new(cipher: graffitty_remote_auth::Datagram, ssrc: u32) -> Self {
        Self {
            sender: wire::Sender::new(cipher, ssrc),
            address: None,
            active: false,
            heard: Instant::now(),
            traced: None,
        }
    }
}

/// Video restarts at a keyframe on the new path; frames in flight on the old
/// one may never be acknowledged.
fn restart_video(c: &mut Client) {
    c.video_cursors.clear();
    for flow in c.chromium_flow.values_mut() {
        flow.restart();
    }
}

impl Datagrams {
    /// Follow the remote listener: bound beside it, closed without it.
    pub fn sync(&mut self, listener: Option<&TcpListener>) {
        let address = listener.and_then(|listener| listener.local_addr().ok());
        if self.endpoint.as_ref().map(|(_, a)| *a) == address
            || (self.endpoint.is_none() && self.failed == address)
        {
            return;
        }
        self.endpoint = None;
        self.failed = None;
        let Some(address) = address else { return };
        match UdpSocket::bind(address)
            .and_then(|socket| socket.set_nonblocking(true).map(|()| socket))
        {
            Ok(socket) => {
                enlarge_send_buffer(&socket);
                self.endpoint = Some((socket, address));
            }
            Err(error) => {
                // Video stays on the WebSocket; nothing else depends on it.
                eprintln!("[network] Video datagrams unavailable on udp {address}: {error}");
                self.failed = Some(address);
            }
        }
    }

    pub fn port(&self) -> Option<u16> {
        self.endpoint.as_ref().map(|(_, address)| address.port())
    }

    #[cfg(unix)]
    pub fn raw_fd(&self) -> Option<i32> {
        use std::os::fd::AsRawFd;
        self.endpoint.as_ref().map(|(socket, _)| socket.as_raw_fd())
    }

    /// Reads every waiting datagram: hellos, path confirmation and NACKs.
    pub fn receive(&self, clients: &mut [Client]) {
        let Some((socket, _)) = &self.endpoint else {
            return;
        };
        let mut buffer = [0u8; 2048];
        let now = Instant::now();
        loop {
            let (len, from) = match socket.recv_from(&mut buffer) {
                Ok(received) => received,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => return,
                // ICMP errors for earlier sends surface here on some systems.
                Err(_) => continue,
            };
            let packet = &buffer[..len];
            let Some(rtp) = wire::Rtp::parse(packet) else {
                continue;
            };
            let Some(c) = clients.iter_mut().find(|c| {
                c.authenticated
                    && c.datagram
                        .as_ref()
                        .is_some_and(|p| p.sender.ssrc() == rtp.ssrc)
            }) else {
                continue;
            };
            let peer = c.datagram.as_mut().unwrap();
            // Unauthentic packets, including any from another address that
            // only copied a header, change nothing.
            let Ok(feedback) = peer.sender.open(packet) else {
                continue;
            };
            // Any authenticated report from the confirmed address shows the
            // path still works.
            //
            // A congested tunnel can lose three one-second hellos in a row
            // while loss reports still arrive; returning video to the
            // WebSocket then restarts every stream at a keyframe.
            if peer.address == Some(from) {
                peer.heard = now;
            }
            if let Some(hello) = feedback.hello {
                peer.address = Some(from);
                peer.heard = now;
                if let Ok(reply) = peer.sender.reply(&hello) {
                    let _ = socket.send_to(&reply, from);
                }
                if hello.confirmed && !peer.active {
                    peer.active = true;
                    eprintln!(
                        "[network] Client {} video moved to udp {from}",
                        c.frontend_client
                    );
                    restart_video(c);
                    continue;
                }
            }
            if !peer.active {
                continue;
            }
            let mut lost = Vec::new();
            for nack in &feedback.nacks {
                if peer.sender.nack(nack, now).unwrap_or(false) {
                    lost.push(nack.session);
                }
            }
            for session in lost {
                if let Some(flow) = c.chromium_flow.get_mut(&session) {
                    flow.lost();
                }
            }
        }
    }

    /// Paces queued video and probes for lost frame tails; returns whether
    /// datagrams are still waiting for pacing budget.
    pub fn send(&self, c: &mut Client) -> bool {
        let Some(peer) = c.datagram.as_mut() else {
            return false;
        };
        if !peer.active {
            return false;
        }
        let now = Instant::now();
        let address = peer.address;
        let fallback = if now.saturating_duration_since(peer.heard) > SILENT {
            Some("hellos stopped".to_owned())
        } else if let (Some((socket, _)), Some(address)) = (&self.endpoint, address) {
            let (rate, probe) = pacing(&c.chromium_flow);
            peer.sender.set_rate(rate);
            trace_sender(peer, rate, now);
            let _ = peer.sender.probe(now, probe);
            peer.sender
                .poll(now, |packet| socket.send_to(packet, address).map(|_| ()))
                .err()
                .map(|e| e.to_string())
        } else {
            Some("endpoint closed".to_owned())
        };
        if let Some(reason) = fallback {
            eprintln!(
                "[network] Client {} video returns to the WebSocket: {reason}",
                c.frontend_client
            );
            peer.active = false;
            peer.sender.clear();
            restart_video(c);
            return false;
        }
        peer.sender.pending()
    }
}

/// Opt-in, once a second: what the link carried and how much it lost.
fn trace_sender(peer: &mut Peer, rate: f64, now: Instant) {
    static TRACE: std::sync::LazyLock<bool> = std::sync::LazyLock::new(|| {
        std::env::var("RUST_LOG").is_ok_and(|v| v.contains("graffitty_video"))
    });
    if !*TRACE { return; }
    let stats = peer.sender.stats;
    match peer.traced {
        Some((at, before)) if now - at >= Duration::from_secs(1) => {
            eprintln!("datagram link rate_mbps={:.1} frames={} datagrams={} retransmitted={} probes={} nacks={}",
                rate * 8.0 / 1e6, stats.frames - before.frames, stats.datagrams - before.datagrams,
                stats.retransmitted - before.retransmitted, stats.probes - before.probes, stats.nacks - before.nacks);
            peer.traced = Some((now, stats));
        }
        None => peer.traced = Some((now, stats)),
        _ => {}
    }
}

/// Spread each round trip's window over that round trip, with headroom:
/// the delay-based windows bound what is in flight, pacing only removes the
/// line-rate bursts that overflow shallow Wi-Fi and router queues.
fn pacing(flows: &HashMap<u64, Flow>) -> (f64, Duration) {
    let round_trip = flows
        .values()
        .filter_map(Flow::round_trip)
        .min()
        .unwrap_or(Duration::from_millis(20));
    let window: usize = flows.values().map(Flow::window_bytes).sum();
    let rate = (2.0 * window.max(64 * 1024) as f64
        / round_trip.max(Duration::from_millis(5)).as_secs_f64())
    .clamp(MIN_RATE, MAX_RATE);
    (rate, (round_trip * 3).max(Duration::from_millis(30)))
}

/// A keyframe burst should not overflow the default socket buffer before
/// pacing drains it.
fn enlarge_send_buffer(socket: &UdpSocket) {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let bytes: libc::c_int = 4 * 1024 * 1024;
        unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_SNDBUF,
                (&bytes as *const libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
    }
    #[cfg(not(unix))]
    let _ = socket;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pacing_follows_windows_and_round_trips() {
        let none = HashMap::new();
        let (rate, probe) = pacing(&none);
        assert_eq!(
            rate,
            2.0 * 65536.0 / 0.02,
            "Without measurements, 64 KiB per assumed 20 ms round trip"
        );
        assert_eq!(probe, Duration::from_millis(60));
        let flows = HashMap::from([(1, Flow::default()), (2, Flow::default())]);
        let (rate, _) = pacing(&flows);
        assert!(
            rate > 2.0 * 65536.0 / 0.02,
            "Each pane's window adds budget"
        );
        assert!(rate <= MAX_RATE);
    }

    #[test]
    fn the_endpoint_follows_the_listener_port() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut datagrams = Datagrams::default();
        datagrams.sync(Some(&listener));
        assert_eq!(
            datagrams.port(),
            Some(listener.local_addr().unwrap().port()),
            "Same port number, other protocol"
        );
        datagrams.sync(None);
        assert_eq!(datagrams.port(), None);
    }
}
