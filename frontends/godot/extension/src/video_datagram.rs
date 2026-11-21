//! The client's chromium video datagram link.
//!
//! A worker thread receives, reassembles and reports losses promptly,
//! independent of the engine's frame rate; RemoteConnection takes complete
//! GRT2 messages each frame and handles them exactly like WebSocket packets.
use godot::classes::RefCounted;
use godot::prelude::*;
use graffitty_remote_auth as auth;
use graffitty_video_datagram as wire;
use std::{
    collections::VecDeque,
    net::{IpAddr, SocketAddr, UdpSocket},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

/// Hellos probe the path until the owner answers, then keep it alive.
const PROBE: Duration = Duration::from_millis(250);
const KEEPALIVE: Duration = Duration::from_secs(1);
/// Without replies for this long the path is no longer confirmed.
const SILENT: Duration = Duration::from_secs(3);
/// Messages the engine has not taken yet; older ones are dropped, and the
/// decoder's sequence check then requests a keyframe.
const QUEUE: usize = 256;

#[derive(Default)]
struct Shared {
    stop: AtomicBool,
    /// Complete messages with their arrival times.
    messages: Mutex<VecDeque<(Instant, Vec<u8>)>>,
    /// Frames the receiver gave up on, as (session, frame).
    abandoned: Mutex<Vec<(u64, u64)>>,
    status: Mutex<Status>,
}

#[derive(Default, Clone, Copy)]
struct Status {
    confirmed: bool,
    round_trip: Option<Duration>,
    stats: wire::ReceiverStats,
    dropped: u64,
}

#[derive(GodotClass)]
#[class(base=RefCounted, no_init)]
pub struct VideoDatagramLink {
    base: Base<RefCounted>,
    shared: Arc<Shared>,
    worker: Option<thread::JoinHandle<()>>,
    ages: Vec<i32>,
}

impl VideoDatagramLink {
    pub fn start(
        cipher: auth::Datagram,
        host: IpAddr,
        port: u16,
        ssrc: u32,
    ) -> std::io::Result<Gd<Self>> {
        let local: SocketAddr = if host.is_ipv4() {
            "0.0.0.0:0"
        } else {
            "[::]:0"
        }
        .parse()
        .unwrap();
        let socket = UdpSocket::bind(local)?;
        socket.connect(SocketAddr::new(host, port))?;
        socket.set_read_timeout(Some(Duration::from_millis(4)))?;
        enlarge_receive_buffer(&socket);
        let shared = Arc::new(Shared::default());
        let worker = {
            let shared = shared.clone();
            thread::Builder::new()
                .name("video-datagrams".into())
                .spawn(move || run(socket, wire::Receiver::new(cipher, ssrc), &shared))?
        };
        Ok(Gd::from_init_fn(|base| Self {
            base,
            shared,
            worker: Some(worker),
            ages: Vec::new(),
        }))
    }
}

/// End-to-end tests emulate a lossy link by discarding this percentage of
/// received datagrams, deterministically.
fn emulated_loss() -> u64 {
    std::env::var("GRAFFITTY_TEST_DATAGRAM_LOSS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
        .min(90)
}

/// End-to-end tests emulate a narrow path such as a VPN tunnel: datagrams
/// beyond `GRAFFITTY_TEST_DATAGRAM_RATE` bytes per second wait in a shallow
/// drop-tail queue, and overflow is lost like a full tunnel's.
///
/// Every datagram also takes `GRAFFITTY_TEST_DATAGRAM_DELAY` milliseconds to
/// cross it.
struct Bottleneck {
    rate: f64,
    budget: f64,
    at: Instant,
    delay: Duration,
    queue: VecDeque<(Instant, Vec<u8>)>,
    queued: usize,
}

/// About 128 full datagrams: a tunnel's short queue, not a router's buffer.
const BOTTLENECK_QUEUE: usize = 128 * 1200;

impl Bottleneck {
    fn from_environment() -> Option<Self> {
        let rate: f64 = std::env::var("GRAFFITTY_TEST_DATAGRAM_RATE").ok()?.parse().ok()?;
        let delay = std::env::var("GRAFFITTY_TEST_DATAGRAM_DELAY").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        (rate > 0.0).then(|| Self { rate, budget: 0.0, at: Instant::now(), delay: Duration::from_millis(delay), queue: VecDeque::new(), queued: 0 })
    }

    fn admit(&mut self, packet: &[u8]) {
        if self.queued + packet.len() <= BOTTLENECK_QUEUE {
            self.queued += packet.len();
            self.queue.push_back((Instant::now() + self.delay, packet.to_vec()));
        }
    }

    fn release(&mut self, now: Instant) -> Vec<Vec<u8>> {
        self.budget = (self.budget + now.saturating_duration_since(self.at).as_secs_f64() * self.rate).min(4.0 * 1200.0);
        self.at = now;
        let mut released = Vec::new();
        while self.queue.front().is_some_and(|(due, packet)| *due <= now && packet.len() as f64 <= self.budget) {
            let (_, packet) = self.queue.pop_front().unwrap();
            self.budget -= packet.len() as f64;
            self.queued -= packet.len();
            released.push(packet);
        }
        released
    }
}

fn run(socket: UdpSocket, mut receiver: wire::Receiver, shared: &Shared) {
    let mut buffer = [0u8; 2048];
    let loss = emulated_loss();
    let mut bottleneck = Bottleneck::from_environment();
    let mut seed = 0x9e37_79b9_7f4a_7c15u64;
    let mut hello_at: Option<Instant> = None;
    let mut replied: Option<Instant> = None;
    while !shared.stop.load(Ordering::Relaxed) {
        let now = Instant::now();
        let confirmed = replied.is_some_and(|at| now.saturating_duration_since(at) < SILENT);
        let interval = if confirmed { KEEPALIVE } else { PROBE };
        if hello_at.is_none_or(|at| now.saturating_duration_since(at) >= interval) {
            if let Ok(hello) = receiver.hello(now, confirmed) {
                // Unreachable hosts are retried by the next hello.
                let _ = socket.send(&hello);
            }
            hello_at = Some(now);
        }
        let mut arrived = Vec::new();
        match socket.recv(&mut buffer) {
            Ok(_)
                if loss > 0 && {
                    seed ^= seed << 13;
                    seed ^= seed >> 7;
                    seed ^= seed << 17;
                    seed % 100 < loss
                } => {}
            Ok(len) => match &mut bottleneck {
                Some(bottleneck) => bottleneck.admit(&buffer[..len]),
                None => arrived.push(buffer[..len].to_vec()),
            },
            // Timeouts, and ICMP refusals reported on a connected socket.
            Err(_) => {}
        }
        if let Some(bottleneck) = &mut bottleneck {
            arrived.extend(bottleneck.release(Instant::now()));
        }
        for packet in arrived {
            if let Ok(wire::Received::Reply(_)) = receiver.receive(&packet, Instant::now()) {
                if !confirmed {
                    // Confirm the path at once rather than at the next probe.
                    hello_at = None;
                }
                replied = Some(Instant::now());
            }
        }
        if let Ok(reports) = receiver.poll(Instant::now()) {
            for report in reports {
                let _ = socket.send(&report);
            }
        }
        let abandoned = receiver.take_abandoned();
        if !abandoned.is_empty() {
            shared.abandoned.lock().unwrap().extend(abandoned);
        }
        let ready = receiver.take();
        let mut dropped = 0;
        if !ready.is_empty() {
            let mut messages = shared.messages.lock().unwrap();
            let arrived = Instant::now();
            messages.extend(ready.into_iter().map(|message| (arrived, message)));
            while messages.len() > QUEUE {
                messages.pop_front();
                dropped += 1;
            }
        }
        let mut status = shared.status.lock().unwrap();
        status.confirmed = confirmed;
        status.round_trip = receiver.round_trip();
        status.stats = receiver.stats;
        status.dropped += dropped;
    }
}

fn enlarge_receive_buffer(socket: &UdpSocket) {
    // A keyframe arrives as a burst of datagrams while the worker may be
    // descheduled; the default receive buffer would drop its tail.
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let bytes: libc::c_int = 4 * 1024 * 1024;
        unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_RCVBUF,
                (&bytes as *const libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
    }
    #[cfg(not(unix))]
    let _ = socket;
}

#[godot_api]
impl VideoDatagramLink {
    /// Complete GRT2 chromium messages, oldest first.
    #[func]
    fn take_messages(&mut self) -> Array<PackedByteArray> {
        let mut result = Array::new();
        self.ages.clear();
        for (arrived, message) in self.shared.messages.lock().unwrap().drain(..) {
            self.ages.push(arrived.elapsed().as_millis().min(i32::MAX as u128) as i32);
            result.push(&PackedByteArray::from(message.as_slice()));
        }
        result
    }

    /// Milliseconds each message of the last take_messages() waited for the
    /// engine; the client reports that hold with its acknowledgement.
    #[func]
    fn message_ages(&self) -> PackedInt32Array {
        PackedInt32Array::from(self.ages.as_slice())
    }

    /// Frames lost beyond repair since the last call, as flat [session,
    /// frame] pairs of wire ids.
    ///
    /// The client acknowledges them so the owner's window, which may hold
    /// nothing newer, does not wait for them forever.
    #[func]
    fn take_abandoned(&mut self) -> PackedInt64Array {
        let mut result = PackedInt64Array::new();
        for (session, frame) in self.shared.abandoned.lock().unwrap().drain(..) {
            result.push(session as i64);
            result.push(frame as i64);
        }
        result
    }

    /// The owner answered recently: video may be arriving here.
    #[func]
    fn confirmed(&self) -> bool {
        self.shared.status.lock().unwrap().confirmed
    }

    #[func]
    fn stats(&self) -> VarDictionary {
        let status = *self.shared.status.lock().unwrap();
        let mut result = VarDictionary::new();
        result.set("confirmed", status.confirmed);
        result.set(
            "round_trip_ms",
            status
                .round_trip
                .map_or(-1.0, |rtt| rtt.as_secs_f64() * 1000.0),
        );
        result.set("datagrams", status.stats.datagrams as i64);
        result.set("frames", status.stats.frames as i64);
        result.set("duplicates", status.stats.duplicates as i64);
        result.set("nacked", status.stats.nacked as i64);
        result.set("recovered", status.stats.recovered as i64);
        result.set("abandoned", status.stats.abandoned as i64);
        result.set("rejected", status.stats.rejected as i64);
        result.set("dropped", status.dropped as i64);
        result
    }

    #[func]
    fn stop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

impl Drop for VideoDatagramLink {
    fn drop(&mut self) {
        self.stop();
    }
}
