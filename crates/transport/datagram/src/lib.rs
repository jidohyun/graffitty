//! Encrypted Chromium video datagrams alongside the WebSocket session.
//!
//! The WebSocket handles login, control, terminal updates, acknowledgements,
//! and keyframe requests. When the client reaches the owner's UDP port,
//! Chromium video moves to UDP. Packet loss then delays only the affected frame.
//!
//! Each datagram starts with a fixed RTP header (RFC 3550). It carries
//! version 2, the last-fragment marker, payload type, sequence number,
//! 90 kHz frame timestamp, and connection SSRC.
//!
//! The login's datagram key seals the payload and authenticates the RTP
//! header as associated data. See `graffitty_remote_auth::Datagram`.
//!
//! Split each GRT2 video message into data shards, followed by Reed-Solomon
//! parity shards. Each payload carries one shard. Its header includes:
//!
//! - Session and flow frame number.
//! - Previous frame sent on this link for that session.
//! - Shard index, data and parity counts, and message length.
//!
//! The previous-frame link distinguishes a lost frame from a frame number
//! skipped because video traveled over the WebSocket.
//!
//! Recover loss in this order:
//!
//! 1. Rebuild missing shards from 20% parity, with at least two parity
//!    shards per frame. This avoids a round trip, as in GameStream's Sunshine,
//!    Wolf, and Moonshine hosts and Moonlight clients.
//! 2. If parity is insufficient, send RTCP-style generic NACKs (RFC 4585) in
//!    encrypted feedback for the remaining data shards or a whole frame.
//!    The sender retransmits what it still holds.
//! 3. Abandon an incomplete frame if recovery fails. The decoder sees a
//!    sequence gap and requests a keyframe over the WebSocket, like a
//!    GameStream IDR request.
use graffitty_remote_auth::{DATAGRAM_OVERHEAD, Datagram};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    sync::Arc,
    time::{Duration, Instant},
};

pub type Result<T> = std::result::Result<T, String>;

/// Fits the IPv6 minimum MTU and common VPN tunnels without fragmentation.
pub const MAX_DATAGRAM: usize = 1200;
pub const RTP_HEADER: usize = 12;
/// Session, frame, previous frame, index, data and parity counts, length.
const FRAGMENT_HEADER: usize = 8 + 8 + 8 + 2 + 2 + 2 + 4;
pub const FRAGMENT_DATA: usize = MAX_DATAGRAM - RTP_HEADER - DATAGRAM_OVERHEAD - FRAGMENT_HEADER;
/// The WebSocket's own message limit.
pub const MAX_MESSAGE: usize = 8 * 1024 * 1024 + 64 * 1024;
const MAX_FRAGMENTS: usize = MAX_MESSAGE.div_ceil(FRAGMENT_DATA);
/// GameStream's defaults: Sunshine, Wolf and Moonshine send 20% parity, and
/// Moonlight asks for at least two parity packets per frame.
pub const FEC_PERCENT: usize = 20;
pub const MIN_PARITY: usize = 2;

/// Dynamic RTP payload types (RFC 3551 section 6).
pub const VIDEO: u8 = 96;
pub const FEEDBACK: u8 = 97;
pub const HELLO: u8 = 98;

/// RTP fixed header without CSRCs, padding or extensions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rtp {
    pub marker: bool,
    pub payload_type: u8,
    pub sequence: u16,
    pub timestamp: u32,
    pub ssrc: u32,
}

impl Rtp {
    pub fn encode(&self) -> [u8; RTP_HEADER] {
        let mut header = [0; RTP_HEADER];
        header[0] = 0x80;
        header[1] = (u8::from(self.marker) << 7) | (self.payload_type & 0x7f);
        header[2..4].copy_from_slice(&self.sequence.to_be_bytes());
        header[4..8].copy_from_slice(&self.timestamp.to_be_bytes());
        header[8..12].copy_from_slice(&self.ssrc.to_be_bytes());
        header
    }

    pub fn parse(packet: &[u8]) -> Option<Self> {
        if packet.len() < RTP_HEADER || packet[0] != 0x80 {
            return None;
        }
        Some(Self {
            marker: packet[1] & 0x80 != 0,
            payload_type: packet[1] & 0x7f,
            sequence: u16::from_be_bytes([packet[2], packet[3]]),
            timestamp: u32::from_be_bytes(packet[4..8].try_into().unwrap()),
            ssrc: u32::from_be_bytes(packet[8..12].try_into().unwrap()),
        })
    }
}

/// Client to owner: path keepalive and loss reports.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Feedback {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hello: Option<Hello>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub nacks: Vec<Nack>,
}

/// `confirmed` once this client has received the owner's reply: the path
/// works in both directions and video may move to it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hello {
    pub time: u64,
    pub confirmed: bool,
}

/// Missing fragment indices of a frame; empty asks for the whole frame.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Nack {
    pub session: u64,
    pub frame: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing: Vec<u16>,
}

/// Owner to client: echoes the hello's time for a round-trip sample.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HelloReply {
    pub time: u64,
}

const MAX_NACKS: usize = 64;
/// More missing fragments than this are requested as the whole frame.
const MAX_MISSING: usize = 48;
/// Feedback JSON beyond this starts another datagram.
const FEEDBACK_BUDGET: usize = MAX_DATAGRAM - RTP_HEADER - DATAGRAM_OVERHEAD - 64;

fn fragments(len: usize) -> usize {
    len.div_ceil(FRAGMENT_DATA).max(1)
}

/// Parity shards protecting `data` data shards.
pub fn parity(data: usize) -> usize {
    (data * FEC_PERCENT).div_ceil(100).max(MIN_PARITY)
}

/// One data shard; the last is shorter unless the message fills it.
fn data_shard(message: &[u8], index: usize) -> &[u8] {
    let start = index * FRAGMENT_DATA;
    &message[start..(start + FRAGMENT_DATA).min(message.len())]
}

/// Reed-Solomon shards share one size: shorter data shards are zero-padded.
fn padded(shard: &[u8]) -> std::borrow::Cow<'_, [u8]> {
    if shard.len() == FRAGMENT_DATA {
        std::borrow::Cow::Borrowed(shard)
    } else {
        let mut padded = shard.to_vec();
        padded.resize(FRAGMENT_DATA, 0);
        std::borrow::Cow::Owned(padded)
    }
}

/// One sealed datagram waiting for pacing budget.
struct Queued {
    session: u64,
    /// Part of a keyframe: a later keyframe does not flush it.
    key: bool,
    packet: Vec<u8>,
}

struct Sent {
    session: u64,
    frame: u64,
    previous: u64,
    key: bool,
    message: Arc<Vec<u8>>,
    timestamp: u32,
    at: Instant,
    resent: Option<Instant>,
    probed: Option<Instant>,
}

/// Retained for retransmission until acknowledged, too old or over budget.
const HISTORY_BYTES: usize = 16 * 1024 * 1024;
const HISTORY_AGE: Duration = Duration::from_secs(2);
/// One frame's fragments are resent at most this often, whatever the
/// receiver asks: duplicate NACKs for one loss must not multiply traffic.
const RESEND_SPACING: Duration = Duration::from_millis(10);
/// The pacer's bucket: at most this much leaves in one burst.
const BURST: f64 = (16 * MAX_DATAGRAM) as f64;

/// The owner's half of one client's datagram link.
pub struct Sender {
    cipher: Datagram,
    ssrc: u32,
    sequence: u16,
    epoch: Instant,
    /// The last frame of each session sent on this link.
    chain: HashMap<u64, u64>,
    history: VecDeque<Sent>,
    history_bytes: usize,
    /// Retransmissions and probes go before new frames.
    urgent: VecDeque<Queued>,
    queue: VecDeque<Queued>,
    rate: f64,
    budget: f64,
    refilled: Instant,
    pub stats: SenderStats,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SenderStats {
    pub frames: u64,
    pub datagrams: u64,
    pub retransmitted: u64,
    pub probes: u64,
    pub nacks: u64,
    /// Keyframes that dropped their session's stale queue.
    pub flushed: u64,
}

impl Sender {
    pub fn new(cipher: Datagram, ssrc: u32) -> Self {
        let now = Instant::now();
        Self {
            cipher,
            ssrc,
            sequence: 0,
            epoch: now,
            chain: HashMap::new(),
            history: VecDeque::new(),
            history_bytes: 0,
            urgent: VecDeque::new(),
            queue: VecDeque::new(),
            rate: 12.5e6,
            budget: BURST,
            refilled: now,
            stats: SenderStats::default(),
        }
    }

    pub fn ssrc(&self) -> u32 {
        self.ssrc
    }

    /// Forget everything sent: the link starts new chains, for instance after
    /// video returned to the WebSocket.
    pub fn clear(&mut self) {
        self.chain.clear();
        self.history.clear();
        self.history_bytes = 0;
        self.urgent.clear();
        self.queue.clear();
    }

    /// Fragment and queue one GRT2 message carrying flow frame `frame`.
    pub fn send(&mut self, session: u64, frame: u64, message: Vec<u8>, now: Instant) -> Result<()> {
        self.queue_frame(session, frame, message, now, false)
    }

    /// Queue a keyframe.
    ///
    /// Everything of its session still waiting to be sent or resent depends
    /// on pictures the keyframe replaces: sending it first only delays the
    /// keyframe on a link that is already behind.
    ///
    /// Drop it and start a new chain, unless an earlier keyframe is itself
    /// still queued.
    pub fn send_keyframe(&mut self, session: u64, frame: u64, message: Vec<u8>, now: Instant) -> Result<()> {
        let queued_key = self.queue.iter().chain(&self.urgent).any(|q| q.session == session && q.key);
        if !queued_key {
            self.queue.retain(|q| q.session != session);
            self.urgent.retain(|q| q.session != session);
            let mut bytes = 0;
            self.history.retain(|sent| {
                if sent.session == session { bytes += sent.message.len(); }
                sent.session != session
            });
            self.history_bytes -= bytes;
            self.chain.remove(&session);
            self.stats.flushed += 1;
        }
        self.queue_frame(session, frame, message, now, true)
    }

    fn queue_frame(&mut self, session: u64, frame: u64, message: Vec<u8>, now: Instant, key: bool) -> Result<()> {
        if message.len() > MAX_MESSAGE {
            return Err("Video message exceeds the datagram limit".into());
        }
        let previous = self.chain.insert(session, frame).unwrap_or(0);
        let sent = Sent {
            session,
            frame,
            previous,
            key,
            message: Arc::new(message),
            timestamp: (now.saturating_duration_since(self.epoch).as_micros() * 9 / 100) as u32,
            at: now,
            resent: None,
            probed: None,
        };
        let data = fragments(sent.message.len());
        for index in 0..data {
            let packet = self.fragment(&sent, index as u16, data_shard(&sent.message, index))?;
            self.queue.push_back(Queued { session, key, packet });
        }
        let recovery = reed_solomon_simd::encode(
            data,
            parity(data),
            (0..data).map(|index| padded(data_shard(&sent.message, index))),
        )
        .map_err(|error| error.to_string())?;
        for (offset, shard) in recovery.iter().enumerate() {
            let packet = self.fragment(&sent, (data + offset) as u16, shard)?;
            self.queue.push_back(Queued { session, key, packet });
        }
        self.history_bytes += sent.message.len();
        self.history.push_back(sent);
        self.stats.frames += 1;
        self.trim(now);
        Ok(())
    }

    fn fragment(&mut self, sent: &Sent, index: u16, shard: &[u8]) -> Result<Vec<u8>> {
        let data = fragments(sent.message.len());
        let parity = parity(data);
        let rtp = Rtp {
            marker: index as usize + 1 == data + parity,
            payload_type: VIDEO,
            sequence: self.sequence,
            timestamp: sent.timestamp,
            ssrc: self.ssrc,
        };
        self.sequence = self.sequence.wrapping_add(1);
        let mut plain = Vec::with_capacity(FRAGMENT_HEADER + shard.len());
        plain.extend_from_slice(&sent.session.to_be_bytes());
        plain.extend_from_slice(&sent.frame.to_be_bytes());
        plain.extend_from_slice(&sent.previous.to_be_bytes());
        plain.extend_from_slice(&index.to_be_bytes());
        plain.extend_from_slice(&(data as u16).to_be_bytes());
        plain.extend_from_slice(&(parity as u16).to_be_bytes());
        plain.extend_from_slice(&(sent.message.len() as u32).to_be_bytes());
        plain.extend_from_slice(shard);
        self.cipher.seal(&rtp.encode(), &plain)
    }

    fn trim(&mut self, now: Instant) {
        while let Some(oldest) = self.history.front() {
            if self.history_bytes <= HISTORY_BYTES
                && now.saturating_duration_since(oldest.at) <= HISTORY_AGE
            {
                break;
            }
            self.history_bytes -= oldest.message.len();
            self.history.pop_front();
        }
    }

    /// The client's cumulative acknowledgement: its decoder consumed every
    /// frame of `session` up to `frame`.
    pub fn acknowledge(&mut self, session: u64, frame: u64) {
        let mut bytes = 0;
        self.history.retain(|sent| {
            let keep = sent.session != session || sent.frame > frame;
            if !keep {
                bytes += sent.message.len();
            }
            keep
        });
        self.history_bytes -= bytes;
    }

    /// Opens a client's feedback datagram.
    pub fn open(&mut self, packet: &[u8]) -> Result<Feedback> {
        let rtp = Rtp::parse(packet).ok_or("Not a video datagram")?;
        if rtp.ssrc != self.ssrc || rtp.payload_type != FEEDBACK {
            return Err("Unexpected datagram".into());
        }
        let plain = self.cipher.open(packet, RTP_HEADER)?;
        let feedback: Feedback =
            serde_json::from_slice(&plain).map_err(|_| "Invalid datagram feedback")?;
        if feedback.nacks.len() > MAX_NACKS
            || feedback.nacks.iter().any(|n| n.missing.len() > MAX_MISSING)
        {
            return Err("Too many lost fragments in one report".into());
        }
        Ok(feedback)
    }

    /// Queues the reply to a hello; the caller sends it to the hello's source.
    pub fn reply(&mut self, hello: &Hello) -> Result<Vec<u8>> {
        let rtp = Rtp {
            marker: false,
            payload_type: HELLO,
            sequence: self.sequence,
            timestamp: 0,
            ssrc: self.ssrc,
        };
        self.sequence = self.sequence.wrapping_add(1);
        let body =
            serde_json::to_vec(&HelloReply { time: hello.time }).map_err(|e| e.to_string())?;
        self.cipher.seal(&rtp.encode(), &body)
    }

    /// Retransmit what a NACK names, if this link still holds the frame.
    /// Returns whether the report described a frame this link sent.
    pub fn nack(&mut self, nack: &Nack, now: Instant) -> Result<bool> {
        self.stats.nacks += 1;
        let Some(position) = self
            .history
            .iter()
            .position(|s| s.session == nack.session && s.frame == nack.frame)
        else {
            return Ok(false);
        };
        let sent = &self.history[position];
        if sent
            .resent
            .is_some_and(|at| now.saturating_duration_since(at) < RESEND_SPACING)
        {
            return Ok(true);
        }
        // Retransmissions carry data shards; parity only helps the first time.
        let count = fragments(sent.message.len());
        let indices: Vec<u16> = if nack.missing.is_empty() {
            (0..count as u16).collect()
        } else {
            nack.missing
                .iter()
                .copied()
                .filter(|&i| (i as usize) < count)
                .collect()
        };
        let sent = Sent {
            message: sent.message.clone(),
            resent: None,
            probed: None,
            ..*sent
        };
        for index in indices {
            let packet = self.fragment(&sent, index, data_shard(&sent.message, index as usize))?;
            self.urgent.push_back(Queued { session: sent.session, key: sent.key, packet });
            self.stats.retransmitted += 1;
        }
        self.history[position].resent = Some(now);
        Ok(true)
    }

    /// Tail-loss probe: a session's newest frame still unacknowledged after
    /// `after` may have lost its final fragments, which no later packet would
    /// reveal. Resending its last fragment lets the receiver report the rest.
    pub fn probe(&mut self, now: Instant, after: Duration) -> Result<()> {
        let mut newest: HashMap<u64, usize> = HashMap::new();
        for (position, sent) in self.history.iter().enumerate() {
            newest.insert(sent.session, position);
        }
        for position in newest.into_values() {
            let sent = &self.history[position];
            let since = sent.probed.or(sent.resent).unwrap_or(sent.at).max(sent.at);
            if now.saturating_duration_since(since) < after {
                continue;
            }
            let last = fragments(sent.message.len()) as u16 - 1;
            let sent = Sent {
                message: sent.message.clone(),
                resent: None,
                probed: None,
                ..*sent
            };
            let packet = self.fragment(&sent, last, data_shard(&sent.message, last as usize))?;
            self.urgent.push_back(Queued { session: sent.session, key: sent.key, packet });
            self.history[position].probed = Some(now);
            self.stats.probes += 1;
        }
        Ok(())
    }

    /// Pacing rate in bytes per second.
    pub fn set_rate(&mut self, bytes_per_second: f64) {
        self.rate = bytes_per_second.max(1.0);
    }

    pub fn pending(&self) -> bool {
        !self.urgent.is_empty() || !self.queue.is_empty()
    }

    /// Sends queued datagrams within the pacing budget. A full socket buffer
    /// keeps the datagram for the next call.
    pub fn poll(
        &mut self,
        now: Instant,
        mut send: impl FnMut(&[u8]) -> std::io::Result<()>,
    ) -> std::io::Result<()> {
        let elapsed = now.saturating_duration_since(self.refilled).as_secs_f64();
        self.refilled = now;
        self.budget = (self.budget + elapsed * self.rate).min(BURST);
        while self.budget > 0.0 {
            let urgent = !self.urgent.is_empty();
            let Some(queued) = (if urgent {
                self.urgent.pop_front()
            } else {
                self.queue.pop_front()
            }) else {
                break;
            };
            match send(&queued.packet) {
                Ok(()) => {
                    self.budget -= queued.packet.len() as f64;
                    self.stats.datagrams += 1;
                }
                Err(error) => {
                    if urgent {
                        self.urgent.push_front(queued)
                    } else {
                        self.queue.push_front(queued)
                    }
                    return if error.kind() == std::io::ErrorKind::WouldBlock {
                        Ok(())
                    } else {
                        Err(error)
                    };
                }
            }
        }
        Ok(())
    }
}

struct Partial {
    previous: u64,
    data: u16,
    parity: u16,
    length: u32,
    /// Data shards, then parity shards.
    shards: Vec<Option<Box<[u8]>>>,
    received: u16,
    bytes: usize,
    first: Instant,
    last: Instant,
    reported: Reports,
}

/// A frame known only from a later frame's previous-frame link.
struct Gap {
    since: Instant,
    reported: Reports,
}

#[derive(Default)]
struct Reports {
    count: u8,
    at: Option<Instant>,
}

impl Partial {
    /// Any `data` shards rebuild the frame.
    fn decodable(&self) -> bool {
        self.received >= self.data
    }

    fn missing_data(&self) -> impl Iterator<Item = u16> + '_ {
        (0..self.data).filter(|&i| self.shards[i as usize].is_none())
    }

    /// The message, rebuilt from parity when data shards are missing.
    fn assemble(self) -> Result<(Vec<u8>, bool)> {
        let data = self.data as usize;
        let mut shards = self.shards;
        let recovered = shards[..data].iter().any(Option::is_none);
        if recovered {
            let restored = reed_solomon_simd::decode(
                data,
                self.parity as usize,
                shards[..data]
                    .iter()
                    .enumerate()
                    .filter_map(|(i, shard)| shard.as_deref().map(|shard| (i, padded(shard)))),
                shards[data..]
                    .iter()
                    .enumerate()
                    .filter_map(|(i, shard)| shard.as_deref().map(|shard| (i, shard))),
            )
            .map_err(|error| error.to_string())?;
            for (index, shard) in restored {
                shards[index] = Some(shard.into_boxed_slice());
            }
        }
        let mut message = Vec::with_capacity(data * FRAGMENT_DATA);
        for shard in shards.into_iter().take(data) {
            message.extend_from_slice(&shard.ok_or("Unrecoverable video frame")?);
        }
        message.truncate(self.length as usize);
        Ok((message, recovered))
    }
}

impl Reports {
    fn due(&self, now: Instant, retry: Duration) -> bool {
        self.count < REPORTS
            && self
                .at
                .is_none_or(|at| now.saturating_duration_since(at) >= retry)
    }
    fn exhausted(&self, now: Instant, retry: Duration) -> bool {
        self.count >= REPORTS
            && self
                .at
                .is_some_and(|at| now.saturating_duration_since(at) >= retry)
    }
    fn record(&mut self, now: Instant) {
        self.count += 1;
        self.at = Some(now);
    }
}

/// Loss reports per frame before it is abandoned.
const REPORTS: u8 = 3;
/// Packets of one frame may arrive slightly out of order.
const REORDER: Duration = Duration::from_millis(3);
/// No frame waits longer than this, whatever the round trip.
const ABANDON: Duration = Duration::from_millis(600);
/// Memory bound for incomplete frames.
const PARTIAL_BYTES: usize = 32 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ReceiverStats {
    pub datagrams: u64,
    pub frames: u64,
    pub duplicates: u64,
    pub nacked: u64,
    /// Frames rebuilt from parity without waiting for retransmission.
    pub recovered: u64,
    pub abandoned: u64,
    pub rejected: u64,
}

#[derive(Debug)]
pub enum Received {
    Video,
    /// The owner answered a hello: the path works both ways.
    Reply(Duration),
}

/// The client's half: reassembles frames and reports losses.
pub struct Receiver {
    cipher: Datagram,
    ssrc: u32,
    epoch: Instant,
    sequence: u16,
    partial: BTreeMap<(u64, u64), Partial>,
    partial_bytes: usize,
    gaps: BTreeMap<(u64, u64), Gap>,
    /// Each session's last delivered or abandoned frame.
    delivered: HashMap<u64, u64>,
    ready: VecDeque<Vec<u8>>,
    /// Frames given up on, as (session, frame), until the client takes them.
    abandoned: Vec<(u64, u64)>,
    round_trip: Option<Duration>,
    pub stats: ReceiverStats,
}

impl Receiver {
    pub fn new(cipher: Datagram, ssrc: u32) -> Self {
        Self {
            cipher,
            ssrc,
            epoch: Instant::now(),
            sequence: 0,
            partial: BTreeMap::new(),
            partial_bytes: 0,
            gaps: BTreeMap::new(),
            delivered: HashMap::new(),
            ready: VecDeque::new(),
            abandoned: Vec::new(),
            round_trip: None,
            stats: ReceiverStats::default(),
        }
    }

    pub fn round_trip(&self) -> Option<Duration> {
        self.round_trip
    }

    /// Complete GRT2 messages in delivery order.
    pub fn take(&mut self) -> Vec<Vec<u8>> {
        self.ready.drain(..).collect()
    }

    /// Frames this receiver gave up on, as (session, frame). The client
    /// acknowledges them: the owner's window may hold nothing newer, so no
    /// later frame would ever reveal the loss, and the stream would freeze.
    pub fn take_abandoned(&mut self) -> Vec<(u64, u64)> {
        std::mem::take(&mut self.abandoned)
    }

    pub fn receive(&mut self, packet: &[u8], now: Instant) -> Result<Received> {
        let result = self.receive_inner(packet, now);
        if result.is_err() {
            self.stats.rejected += 1;
        }
        result
    }

    fn receive_inner(&mut self, packet: &[u8], now: Instant) -> Result<Received> {
        let rtp = Rtp::parse(packet).ok_or("Not a video datagram")?;
        if rtp.ssrc != self.ssrc {
            return Err("Datagram for another connection".into());
        }
        let plain = self.cipher.open(packet, RTP_HEADER)?;
        self.stats.datagrams += 1;
        match rtp.payload_type {
            VIDEO => self.fragment(&plain, now).map(|()| Received::Video),
            HELLO => {
                let reply: HelloReply =
                    serde_json::from_slice(&plain).map_err(|_| "Invalid hello reply")?;
                let sample = now
                    .saturating_duration_since(self.epoch)
                    .saturating_sub(Duration::from_millis(reply.time));
                self.round_trip = Some(
                    self.round_trip
                        .map_or(sample, |previous| (previous * 7 + sample) / 8),
                );
                Ok(Received::Reply(sample))
            }
            _ => Err("Unexpected datagram type".into()),
        }
    }

    fn fragment(&mut self, plain: &[u8], now: Instant) -> Result<()> {
        if plain.len() <= FRAGMENT_HEADER {
            return Err("Short video fragment".into());
        }
        let number = |at: usize| u64::from_be_bytes(plain[at..at + 8].try_into().unwrap());
        let (session, frame, previous) = (number(0), number(8), number(16));
        let half = |at: usize| u16::from_be_bytes([plain[at], plain[at + 1]]);
        let (index, data, parity) = (half(24), half(26), half(28));
        let length = u32::from_be_bytes(plain[30..34].try_into().unwrap());
        let shard = &plain[FRAGMENT_HEADER..];
        let total = data as usize + parity as usize;
        let last =
            (length as usize).saturating_sub((data as usize).saturating_sub(1) * FRAGMENT_DATA);
        let expected = if index + 1 < data || index >= data {
            FRAGMENT_DATA
        } else {
            last
        };
        if data == 0
            || data as usize > MAX_FRAGMENTS
            || data as usize != fragments(length as usize)
            || parity as usize != self::parity(data as usize)
            || index as usize >= total
            || frame == 0
            || previous >= frame
            || shard.len() != expected
        {
            return Err("Invalid video fragment".into());
        }
        if self.delivered.get(&session).is_some_and(|&d| frame <= d) {
            self.stats.duplicates += 1;
            return Ok(());
        }
        self.gaps.remove(&(session, frame));
        if previous == 0 && !self.partial.contains_key(&(session, frame)) {
            // A chain start (a keyframe that flushed its sender's queue, or a
            // new link) depends on nothing before it.
            //
            // Older frames still incomplete will never be completed: waiting
            // for them only holds the keyframe back.
            let older = self.partial.range((session, 0)..(session, frame)).map(|(key, _)| key.1)
                .chain(self.gaps.range((session, 0)..(session, frame)).map(|(key, _)| key.1))
                .max();
            if let Some(older) = older {
                self.abandon(session, older);
            }
        }
        let partial = self
            .partial
            .entry((session, frame))
            .or_insert_with(|| Partial {
                previous,
                data,
                parity,
                length,
                shards: vec![None; total],
                received: 0,
                bytes: 0,
                first: now,
                last: now,
                reported: Reports::default(),
            });
        if (
            partial.data,
            partial.parity,
            partial.length,
            partial.previous,
        ) != (data, parity, length, previous)
        {
            return Err("Inconsistent video fragment".into());
        }
        partial.last = now;
        // Shards beyond what decoding needs, from parity or retransmission.
        if partial.decodable() || partial.shards[index as usize].is_some() {
            self.stats.duplicates += 1;
            return Ok(());
        }
        partial.shards[index as usize] = Some(shard.into());
        partial.received += 1;
        partial.bytes += shard.len();
        self.partial_bytes += shard.len();
        // The frame before this one, unless already delivered or under way.
        if previous != 0
            && self.delivered.get(&session).is_none_or(|&d| previous > d)
            && !self.partial.contains_key(&(session, previous))
        {
            self.gaps.entry((session, previous)).or_insert(Gap {
                since: now,
                reported: Reports::default(),
            });
        }
        while self.partial_bytes > PARTIAL_BYTES {
            let Some((&(session, frame), _)) = self.partial.iter().next() else {
                break;
            };
            self.abandon(session, frame);
        }
        self.deliver(session);
        Ok(())
    }

    fn deliver(&mut self, session: u64) {
        loop {
            let Some((&(_, frame), partial)) = self
                .partial
                .range((session, 0)..=(session, u64::MAX))
                .next()
            else {
                return;
            };
            if !partial.decodable() {
                return;
            }
            // A chain starts at zero, or at a frame whose predecessor this
            // receiver never learned of and no longer waits for.
            let delivered = self.delivered.get(&session).copied();
            let follows = partial.previous == 0
                || delivered.is_some_and(|d| partial.previous <= d)
                || (delivered.is_none()
                    && !self.gaps.contains_key(&(session, partial.previous))
                    && !self.partial.contains_key(&(session, partial.previous)));
            if !follows {
                return;
            }
            let partial = self.partial.remove(&(session, frame)).unwrap();
            self.partial_bytes -= partial.bytes;
            match partial.assemble() {
                Ok((message, recovered)) => {
                    self.stats.recovered += u64::from(recovered);
                    self.ready.push_back(message);
                }
                Err(_) => {
                    // Shards that pass authentication but do not decode
                    // cannot be repaired; the decoder requests a keyframe.
                    self.abandon(session, frame);
                    continue;
                }
            }
            self.delivered.insert(session, frame);
            self.gaps.retain(|&(s, f), _| s != session || f > frame);
            self.stats.frames += 1;
        }
    }

    /// Give up on a frame; later frames of its session may proceed.
    fn abandon(&mut self, session: u64, frame: u64) {
        if let Some(partial) = self.partial.remove(&(session, frame)) {
            self.partial_bytes -= partial.bytes;
        }
        self.gaps.remove(&(session, frame));
        let delivered = self.delivered.entry(session).or_insert(frame);
        *delivered = (*delivered).max(frame);
        let delivered = *delivered;
        let stale: Vec<_> = self
            .partial
            .range((session, 0)..=(session, delivered))
            .map(|(k, _)| *k)
            .collect();
        for key in stale {
            let partial = self.partial.remove(&key).unwrap();
            self.partial_bytes -= partial.bytes;
        }
        self.gaps.retain(|&(s, f), _| s != session || f > delivered);
        self.abandoned.push((session, frame));
        self.stats.abandoned += 1;
    }

    fn retry(&self) -> Duration {
        self.round_trip
            .map_or(Duration::from_millis(60), |rtt| rtt * 3 / 2)
            .max(Duration::from_millis(15))
    }

    /// Reports losses that are due and abandons frames that cannot complete.
    /// Returns sealed feedback datagrams to send.
    pub fn poll(&mut self, now: Instant) -> Result<Vec<Vec<u8>>> {
        let retry = self.retry();
        let mut nacks = Vec::new();
        let mut abandon = Vec::new();
        let newest: HashMap<u64, u64> =
            self.partial
                .keys()
                .fold(HashMap::new(), |mut newest, &(session, frame)| {
                    newest.insert(session, frame);
                    newest
                });
        for (&(session, frame), partial) in &mut self.partial {
            if partial.decodable() {
                continue;
            }
            if partial.reported.exhausted(now, retry)
                || now.saturating_duration_since(partial.first) >= ABANDON
            {
                abandon.push((session, frame));
                continue;
            }
            // Wait briefly for reordered fragments unless a later frame
            // already shows that this one's transmission ended.
            let ended = newest.get(&session).is_some_and(|&n| n > frame);
            if (ended || now.saturating_duration_since(partial.last) >= REORDER)
                && partial.reported.due(now, retry)
            {
                // Parity already covers part of the loss: ask only for as many
                // data shards as are still needed.
                let needed = (partial.data - partial.received) as usize;
                let missing: Vec<u16> = partial.missing_data().take(needed).collect();
                nacks.push(Nack {
                    session,
                    frame,
                    missing: if missing.len() > MAX_MISSING {
                        Vec::new()
                    } else {
                        missing
                    },
                });
                partial.reported.record(now);
            }
        }
        for (&(session, frame), gap) in &mut self.gaps {
            if gap.reported.exhausted(now, retry)
                || now.saturating_duration_since(gap.since) >= ABANDON
            {
                abandon.push((session, frame));
            } else if now.saturating_duration_since(gap.since) >= REORDER
                && gap.reported.due(now, retry)
            {
                nacks.push(Nack {
                    session,
                    frame,
                    missing: Vec::new(),
                });
                gap.reported.record(now);
            }
        }
        let sessions: Vec<u64> = abandon.iter().map(|(session, _)| *session).collect();
        for (session, frame) in abandon {
            self.abandon(session, frame);
        }
        for session in sessions {
            self.deliver(session);
        }
        self.stats.nacked += nacks.len() as u64;
        let mut packets = Vec::new();
        let mut batch = Feedback::default();
        for nack in nacks {
            batch.nacks.push(nack);
            if batch.nacks.len() >= MAX_NACKS
                || serde_json::to_vec(&batch).map_err(|e| e.to_string())?.len() > FEEDBACK_BUDGET
            {
                let last = batch.nacks.pop().unwrap();
                if !batch.nacks.is_empty() {
                    packets.push(self.seal(&batch)?);
                }
                batch = Feedback {
                    hello: None,
                    nacks: vec![last],
                };
            }
        }
        if !batch.nacks.is_empty() {
            packets.push(self.seal(&batch)?);
        }
        Ok(packets)
    }

    /// A path probe and keepalive.
    pub fn hello(&mut self, now: Instant, confirmed: bool) -> Result<Vec<u8>> {
        let time = now.saturating_duration_since(self.epoch).as_millis() as u64;
        self.seal(&Feedback {
            hello: Some(Hello { time, confirmed }),
            nacks: Vec::new(),
        })
    }

    fn seal(&mut self, feedback: &Feedback) -> Result<Vec<u8>> {
        let rtp = Rtp {
            marker: false,
            payload_type: FEEDBACK,
            sequence: self.sequence,
            timestamp: 0,
            ssrc: self.ssrc,
        };
        self.sequence = self.sequence.wrapping_add(1);
        let body = serde_json::to_vec(feedback).map_err(|e| e.to_string())?;
        self.cipher.seal(&rtp.encode(), &body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use graffitty_remote_auth::{Client, Config, Role, Server};

    fn link() -> (Sender, Receiver) {
        let password = "datagram link password";
        let mut server = Server::new(Config::default(), password).unwrap();
        let (client, message) = Client::start(password, b"test").unwrap();
        let (pending, message) = server.start(&message, b"test").unwrap();
        let (client_key, finish) = client.finish(&message).unwrap();
        let server_key = pending.finish(&finish).unwrap();
        (
            Sender::new(server_key.datagram(Role::Server), 7),
            Receiver::new(client_key.datagram(Role::Client), 7),
        )
    }

    fn message(seed: u8, len: usize) -> Vec<u8> {
        (0..len).map(|i| seed.wrapping_add(i as u8)).collect()
    }

    /// Sends everything queued, dropping datagrams whose ordinal `drop` rejects.
    fn transmit(
        sender: &mut Sender,
        now: Instant,
        mut drop: impl FnMut(usize) -> bool,
    ) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        sender.set_rate(1e12);
        let mut ordinal = 0;
        let mut at = now;
        while sender.pending() {
            // Each call refills at least one full burst.
            at += Duration::from_secs(1);
            sender
                .poll(at, |packet| {
                    if !drop(ordinal) {
                        out.push(packet.to_vec());
                    }
                    ordinal += 1;
                    Ok(())
                })
                .unwrap();
        }
        out
    }

    #[test]
    fn rtp_headers_round_trip_and_reject_other_versions() {
        let rtp = Rtp {
            marker: true,
            payload_type: VIDEO,
            sequence: 65535,
            timestamp: 90_000,
            ssrc: 0xdead_beef,
        };
        let encoded = rtp.encode();
        assert_eq!(encoded[0], 0x80);
        assert_eq!(Rtp::parse(&encoded), Some(rtp));
        let mut padded = encoded;
        padded[0] = 0xa0;
        assert_eq!(
            Rtp::parse(&padded),
            None,
            "Padding, extensions and CSRCs are not used"
        );
        assert!(FRAGMENT_DATA > 1100, "Most of each datagram is payload");
    }

    #[test]
    fn frames_fragment_and_reassemble_in_order() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        let large = message(1, FRAGMENT_DATA * 5 + 17);
        sender.send(3, 1, large.clone(), now).unwrap();
        sender.send(3, 2, message(2, 10), now).unwrap();
        sender.send(4, 9, message(3, FRAGMENT_DATA), now).unwrap();
        let mut packets = transmit(&mut sender, now, |_| false);
        assert!(
            packets.iter().all(|p| p.len() <= MAX_DATAGRAM),
            "Datagrams fit the path MTU"
        );
        packets.reverse();
        for packet in &packets {
            receiver.receive(packet, now).unwrap();
        }
        let ready = receiver.take();
        assert_eq!(ready.len(), 3);
        assert_eq!(ready.iter().filter(|m| **m == large).count(), 1);
        let session3: Vec<_> = ready.iter().filter(|m| m.len() != FRAGMENT_DATA).collect();
        assert_eq!(
            session3,
            vec![&large, &message(2, 10)],
            "A session's frames are delivered in order"
        );
        for packet in &packets {
            receiver.receive(packet, now).unwrap_err();
        }
        assert!(
            receiver.take().is_empty(),
            "Replayed datagrams deliver nothing"
        );
    }

    #[test]
    fn parity_rebuilds_lost_shards_without_a_round_trip() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        // 12 data shards: 20% parity is 3 shards.
        let frame = message(9, FRAGMENT_DATA * 11 + 5);
        assert_eq!(parity(12), 3);
        assert_eq!(
            parity(1),
            MIN_PARITY,
            "Small frames keep the minimum parity"
        );
        sender.send(1, 5, frame.clone(), now).unwrap();
        let packets = transmit(&mut sender, now, |i| i == 0 || i == 6 || i == 11);
        assert_eq!(packets.len(), 12, "Three of fifteen shards were lost");
        for packet in packets {
            receiver.receive(&packet, now).unwrap();
        }
        assert_eq!(
            receiver.take(),
            vec![frame],
            "Lost data shards, including the short last one, are rebuilt"
        );
        assert!(
            receiver
                .poll(now + Duration::from_secs(1))
                .unwrap()
                .is_empty(),
            "Nothing is reported"
        );
        assert_eq!(receiver.stats.recovered, 1);
        assert_eq!(sender.stats.retransmitted, 0);
    }

    #[test]
    fn losses_beyond_parity_request_only_the_shards_still_needed() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        // 5 data shards and 2 parity: shards 0-4 data, 5-6 parity.
        let frame = message(9, FRAGMENT_DATA * 4 + 3);
        sender.send(1, 5, frame.clone(), now).unwrap();
        sender.send(1, 6, message(4, 100), now).unwrap();
        for packet in transmit(&mut sender, now, |i| [1, 3, 5, 6].contains(&i)) {
            receiver.receive(&packet, now).unwrap();
        }
        assert!(
            receiver.take().is_empty(),
            "A later complete frame waits for the incomplete one"
        );
        let reports = receiver.poll(now).unwrap();
        assert_eq!(reports.len(), 1);
        let feedback = sender.open(&reports[0]).unwrap();
        assert_eq!(
            feedback.nacks,
            vec![Nack {
                session: 1,
                frame: 5,
                missing: vec![1, 3]
            }]
        );
        assert!(sender.nack(&feedback.nacks[0], now).unwrap());
        let resent = transmit(&mut sender, now, |_| false);
        assert_eq!(resent.len(), 2, "Only the missing data shards are resent");
        for packet in resent {
            receiver.receive(&packet, now).unwrap();
        }
        assert_eq!(receiver.take(), vec![frame, message(4, 100)]);
        assert_eq!(sender.stats.retransmitted, 2);
    }

    #[test]
    fn parity_shortens_retransmission_requests() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        let frame = message(3, FRAGMENT_DATA * 4 + 3);
        sender.send(1, 1, frame.clone(), now).unwrap();
        sender.send(1, 2, message(4, 10), now).unwrap();
        // Three data shards lost, one parity shard arrived: two more needed.
        for packet in transmit(&mut sender, now, |i| [0, 1, 2, 6].contains(&i)) {
            receiver.receive(&packet, now).unwrap();
        }
        let feedback = sender.open(&receiver.poll(now).unwrap()[0]).unwrap();
        assert_eq!(
            feedback.nacks,
            vec![Nack {
                session: 1,
                frame: 1,
                missing: vec![0, 1]
            }]
        );
        sender.nack(&feedback.nacks[0], now).unwrap();
        for packet in transmit(&mut sender, now, |_| false) {
            receiver.receive(&packet, now).unwrap();
        }
        assert_eq!(
            receiver.take(),
            vec![frame, message(4, 10)],
            "Parity fills in the third"
        );
        assert_eq!(receiver.stats.recovered, 1);
    }

    #[test]
    fn a_wholly_lost_frame_is_requested_through_the_chain() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        sender.send(2, 1, message(1, 50), now).unwrap();
        sender.send(2, 2, message(2, 50), now).unwrap();
        sender.send(2, 3, message(3, 50), now).unwrap();
        // Each one-shard frame has two parity shards: datagrams 3-5 are frame 2.
        for packet in transmit(&mut sender, now, |i| (3..6).contains(&i)) {
            receiver.receive(&packet, now).unwrap();
        }
        assert_eq!(
            receiver.take(),
            vec![message(1, 50)],
            "Frame 3 waits for the missing frame 2"
        );
        let later = now + REORDER;
        let feedback = sender.open(&receiver.poll(later).unwrap()[0]).unwrap();
        assert_eq!(
            feedback.nacks,
            vec![Nack {
                session: 2,
                frame: 2,
                missing: vec![]
            }]
        );
        sender.nack(&feedback.nacks[0], later).unwrap();
        for packet in transmit(&mut sender, later, |_| false) {
            receiver.receive(&packet, later).unwrap();
        }
        assert_eq!(receiver.take(), vec![message(2, 50), message(3, 50)]);
    }

    #[test]
    fn unrecoverable_frames_are_abandoned_so_later_frames_proceed() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        // Two data and two parity shards; losing three leaves it short.
        sender
            .send(2, 10, message(1, FRAGMENT_DATA * 2), now)
            .unwrap();
        sender.send(2, 11, message(2, 40), now).unwrap();
        for packet in transmit(&mut sender, now, |i| i < 3) {
            receiver.receive(&packet, now).unwrap();
        }
        let mut at = now;
        for _ in 0..REPORTS {
            at += Duration::from_millis(100);
            assert_eq!(
                receiver.poll(at).unwrap().len(),
                1,
                "Each retry reports the loss again"
            );
        }
        assert!(receiver.take().is_empty());
        at += Duration::from_millis(100);
        assert!(receiver.poll(at).unwrap().is_empty());
        assert_eq!(
            receiver.take(),
            vec![message(2, 40)],
            "The decoder sees the gap and requests a keyframe"
        );
        assert_eq!(receiver.stats.abandoned, 1);
        assert_eq!(receiver.take_abandoned(), vec![(2, 10)]);
    }

    #[test]
    fn a_lost_newest_frame_is_reported_for_acknowledgement() {
        // The owner's window holds only this frame, so nothing later arrives.
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        sender.send(4, 7, message(1, FRAGMENT_DATA * 2), now).unwrap();
        for packet in transmit(&mut sender, now, |i| i < 3) {
            receiver.receive(&packet, now).unwrap();
        }
        assert!(receiver.take_abandoned().is_empty(), "A fresh loss is still being repaired");
        let at = now + ABANDON;
        receiver.poll(at).unwrap();
        assert!(receiver.take().is_empty());
        assert_eq!(receiver.take_abandoned(), vec![(4, 7)], "The client acknowledges the lost frame");
        assert!(receiver.take_abandoned().is_empty(), "Each abandoned frame is reported once");
    }

    #[test]
    fn a_keyframe_flushes_its_sessions_stale_queue_and_starts_a_chain() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        // Frame 1 arrives only in part; 2 and 3 are still queued behind it.
        sender.send(6, 1, message(1, FRAGMENT_DATA * 8), now).unwrap();
        let first = transmit(&mut sender, now, |_| false);
        for packet in &first[..3] {
            receiver.receive(packet, now).unwrap();
        }
        sender.send(6, 2, message(2, FRAGMENT_DATA * 8), now).unwrap();
        sender.send(6, 3, message(3, FRAGMENT_DATA * 8), now).unwrap();
        sender.send(7, 1, message(9, 40), now).unwrap();
        sender.send_keyframe(6, 4, message(4, FRAGMENT_DATA * 2), now).unwrap();
        assert_eq!(sender.stats.flushed, 1);
        let packets = transmit(&mut sender, now, |_| false);
        assert_eq!(packets.len(), 3 + 4, "Only the other session's frame and the keyframe remain queued");
        for packet in &packets {
            receiver.receive(packet, now).unwrap();
        }
        assert_eq!(receiver.take(), vec![message(9, 40), message(4, FRAGMENT_DATA * 2)],
            "The keyframe is delivered without waiting for the frames it replaces");
        assert_eq!(receiver.take_abandoned(), vec![(6, 1)], "The half-received frame is given up for acknowledgement");
        assert!(receiver.poll(now + Duration::from_secs(1)).unwrap().is_empty(), "Nothing flushed is reported missing");
        // A second keyframe leaves a keyframe that is still queued alone.
        sender.send_keyframe(6, 5, message(5, FRAGMENT_DATA * 2), now).unwrap();
        sender.send_keyframe(6, 6, message(6, FRAGMENT_DATA * 2), now).unwrap();
        assert_eq!(sender.stats.flushed, 2);
        for packet in transmit(&mut sender, now, |_| false) {
            receiver.receive(&packet, now).unwrap();
        }
        assert_eq!(receiver.take().len(), 2, "A queued keyframe is not flushed by the next one");
    }

    #[test]
    fn new_chains_skip_frames_sent_over_the_websocket() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        sender.send(5, 3, message(1, 20), now).unwrap();
        for packet in transmit(&mut sender, now, |_| false) {
            receiver.receive(&packet, now).unwrap();
        }
        sender.clear();
        sender.send(5, 9, message(2, 20), now).unwrap();
        for packet in transmit(&mut sender, now, |_| false) {
            receiver.receive(&packet, now).unwrap();
        }
        assert_eq!(
            receiver.take(),
            vec![message(1, 20), message(2, 20)],
            "Frames 4 to 8 travelled another way"
        );
        assert!(
            receiver
                .poll(now + Duration::from_secs(1))
                .unwrap()
                .is_empty(),
            "Nothing is reported missing"
        );
    }

    #[test]
    fn tail_loss_probes_reveal_a_lost_final_fragment() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        let frame = message(7, FRAGMENT_DATA + 1);
        sender.send(1, 1, frame.clone(), now).unwrap();
        // The final data shard and both parity shards are lost.
        for packet in transmit(&mut sender, now, |i| i >= 1) {
            receiver.receive(&packet, now).unwrap();
        }
        sender
            .probe(now + Duration::from_millis(5), Duration::from_millis(10))
            .unwrap();
        assert!(!sender.pending(), "No probe before the threshold");
        let later = now + Duration::from_millis(20);
        sender.probe(later, Duration::from_millis(10)).unwrap();
        for packet in transmit(&mut sender, later, |_| false) {
            receiver.receive(&packet, later).unwrap();
        }
        assert_eq!(receiver.take(), vec![frame]);
        sender.acknowledge(1, 1);
        sender
            .probe(later + Duration::from_secs(1), Duration::from_millis(10))
            .unwrap();
        assert!(!sender.pending(), "Acknowledged frames are never probed");
    }

    #[test]
    fn random_loss_and_reordering_deliver_intact_frames_in_order() {
        let (mut sender, mut receiver) = link();
        let mut seed = 0x2545_f491_4f6c_dd1du64;
        let mut random = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let start = Instant::now();
        let mut at = start;
        let mut expected: HashMap<u64, Vec<(u64, Vec<u8>)>> = HashMap::new();
        let mut delivered = Vec::new();
        let mut in_flight: Vec<Vec<u8>> = Vec::new();
        for frame in 1..=300u64 {
            at += Duration::from_millis(16);
            let session = frame % 3;
            let body = message(
                frame as u8,
                1 + (random() % (FRAGMENT_DATA as u64 * 6)) as usize,
            );
            // The receiver can only tell frames apart by content.
            let mut tagged = frame.to_be_bytes().to_vec();
            tagged.extend_from_slice(&body);
            sender.send(session, frame, tagged.clone(), at).unwrap();
            expected.entry(session).or_default().push((frame, tagged));
            sender.set_rate(1e12);
            sender
                .poll(at + Duration::from_secs(1), |packet| {
                    if random() % 10 != 0 {
                        in_flight.push(packet.to_vec());
                    }
                    Ok(())
                })
                .unwrap();
            // Mild reordering: swap neighbours now and then.
            for i in 1..in_flight.len() {
                if random() % 8 == 0 {
                    in_flight.swap(i - 1, i);
                }
            }
            for packet in in_flight.drain(..) {
                receiver.receive(&packet, at).unwrap();
            }
            for report in receiver.poll(at).unwrap() {
                if random() % 10 == 0 {
                    continue;
                }
                for nack in sender.open(&report).unwrap().nacks {
                    sender.nack(&nack, at).unwrap();
                }
            }
            delivered.extend(receiver.take());
        }
        for _ in 0..80 {
            at += Duration::from_millis(16);
            sender.probe(at, Duration::from_millis(40)).unwrap();
            sender.set_rate(1e12);
            sender
                .poll(at + Duration::from_secs(1), |packet| {
                    if random() % 10 != 0 {
                        in_flight.push(packet.to_vec());
                    }
                    Ok(())
                })
                .unwrap();
            for packet in in_flight.drain(..) {
                receiver.receive(&packet, at).unwrap();
            }
            for report in receiver.poll(at).unwrap() {
                for nack in sender.open(&report).unwrap().nacks {
                    sender.nack(&nack, at).unwrap();
                }
            }
            delivered.extend(receiver.take());
        }
        let mut last: HashMap<u64, u64> = HashMap::new();
        for message in &delivered {
            let frame = u64::from_be_bytes(message[..8].try_into().unwrap());
            let session = frame % 3;
            let original = &expected[&session]
                .iter()
                .find(|(f, _)| *f == frame)
                .unwrap()
                .1;
            assert_eq!(message, original, "Frame {frame} is intact");
            assert!(
                last.get(&session).is_none_or(|&l| frame > l),
                "Session {session} stays in order"
            );
            last.insert(session, frame);
        }
        let recovered = delivered.len() as f64 / 300.0;
        assert!(
            recovered > 0.97,
            "Retransmission recovers almost every frame under 10% loss ({recovered})"
        );
        assert!(
            receiver.stats.recovered > 30,
            "Parity rebuilds many frames ({:?})",
            receiver.stats
        );
        assert!(
            sender.stats.retransmitted > 0 && receiver.stats.nacked > 0,
            "Retransmission covers the rest"
        );
    }

    #[test]
    fn pacing_limits_bursts_and_hello_measures_the_round_trip() {
        let (mut sender, mut receiver) = link();
        let now = Instant::now();
        sender
            .send(1, 1, message(0, FRAGMENT_DATA * 40), now)
            .unwrap();
        sender.set_rate(1_000_000.0);
        let mut sent = 0;
        sender
            .poll(now, |_| {
                sent += 1;
                Ok(())
            })
            .unwrap();
        assert!(sent <= 17, "At most one burst leaves at once ({sent})");
        let mut more = 0;
        sender
            .poll(now + Duration::from_millis(12), |_| {
                more += 1;
                Ok(())
            })
            .unwrap();
        assert!(
            (9..=12).contains(&more),
            "12 ms at 1 MB/s is about ten datagrams ({more})"
        );
        let hello = receiver.hello(now, false).unwrap();
        let feedback = sender.open(&hello).unwrap();
        let reply = sender.reply(&feedback.hello.unwrap()).unwrap();
        assert!(matches!(
            receiver
                .receive(&reply, now + Duration::from_millis(30))
                .unwrap(),
            Received::Reply(_)
        ));
        assert!(receiver.round_trip().unwrap() >= Duration::from_millis(29));
        let mut forged = receiver.hello(now, true).unwrap();
        forged[9] ^= 1;
        assert!(
            sender.open(&forged).is_err(),
            "Another connection's SSRC is rejected"
        );
    }
}
