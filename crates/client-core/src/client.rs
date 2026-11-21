//! Nonblocking packet replay and request correlation shared by both frontends.
use crate::transport::ClientTransport;
use anyhow::{Context, Result, anyhow, ensure};
use graffitty_protocol::{ChromiumId, SessionId};
use graffitty_transport::ipc::{self as ipc, Packet};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    io,
    time::{Duration, Instant},
};

pub enum Event {
    Scene { session: SessionId, commit: crate::scene::Commit },
    Asset { session: SessionId, pixels: crate::scene::Pixels },
    Ready(Value),
    Topology(Value),
    Resources(Value),
    Notification(Value),
    FrontendRequest(Value),
    Chromium {
        session: ChromiumId,
        header: Value,
        bytes: Vec<u8>,
    },
    Message(Value),
    Binary {
        header: Value,
        bytes: Vec<u8>,
    },
}

pub struct Client {
    transport: ClientTransport,
    controller: Option<crate::controller::Bridge>,
    controller_pending: std::sync::Arc<std::sync::atomic::AtomicBool>,
    graph: crate::graph_state::GraphState,
    sequence: u64,
    pending: BTreeSet<u64>,
    replies: BTreeMap<u64, Value>,
    queued: VecDeque<Event>,
    read_error: Option<io::Error>,
    scene_worker: crate::scene_worker::Worker,
    wakeup: Option<std::sync::Arc<crate::wakeup::Wakeup>>,
    poll_pending: std::sync::Arc<std::sync::atomic::AtomicBool>,
    revision: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

impl Client {
    /// The caller authenticates the transport before adopting it.
    pub fn new(transport: ClientTransport) -> Self {
        Self {
            transport,
            controller: None,
            controller_pending: Default::default(),
            graph: Default::default(),
            sequence: 0,
            pending: Default::default(),
            replies: Default::default(),
            queued: Default::default(),
            read_error: None,
            scene_worker: Default::default(),
            wakeup: None,
            poll_pending: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true)),
            revision: Default::default(),
        }
    }

    pub(crate) fn queue(&mut self, events: Vec<Event>) {
        self.queued.extend(events);
        self.poll_pending.store(true, std::sync::atomic::Ordering::Release);
    }

    pub fn wakeup(&mut self) -> Result<std::sync::Arc<crate::wakeup::Wakeup>> {
        if self.wakeup.is_none() {
            self.wakeup = Some(std::sync::Arc::new(crate::wakeup::Wakeup {
                transport: self.transport.readiness()?,
                pending: self.poll_pending.clone(),
                controller_pending: self.controller_pending.clone(),
                preparing: self.scene_worker.in_flight.clone(),
                prepared: self.scene_worker.ready.clone(),
                revision: self.revision.clone(),
                probes: Default::default(),
            }));
        }
        Ok(self.wakeup.as_ref().unwrap().clone())
    }
    /// Last validated server graph, independent of any UI toolkit.
    pub fn graph(&self) -> Option<&graffitty_protocol::graph::Snapshot> { self.graph.snapshots.get(&0) }

    pub fn revision(&self) -> u64 { self.revision.load(std::sync::atomic::Ordering::Acquire) }

    pub fn is_remote(&self) -> bool {
        self.transport.is_remote()
    }

    pub fn publish_controller(&mut self, alias: &str, identity: &str) -> Result<()> {
        self.controller = None;
        if alias.is_empty() { return Ok(()); }
        ensure!(self.is_remote(), "Server aliases require a remote attachment");
        self.controller = Some(crate::controller::Bridge::with_wakeup(
            &crate::controller::state_directory()?, alias, identity, Some(self.controller_pending.clone()),
        )?);
        Ok(())
    }

    pub fn local_peer_pid(&self) -> Option<u32> {
        self.transport.local_peer_pid()
    }

    pub fn send(&mut self, value: &Value) -> Result<()> {
        let bytes = serde_json::to_vec(value)?;
        ensure!(
            bytes.len() <= ipc::MAX_PACKET,
            "Session output limit reached"
        );
        self.transport.send(Packet::Text(bytes))?;
        self.poll_pending.store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    }

    pub fn request_async(&mut self, value: Value) -> Result<u64> {
        self.request_payload_async(value, None)
    }

    pub fn request_binary_async(&mut self, value: Value, bytes: &[u8]) -> Result<u64> {
        self.request_payload_async(value, Some(bytes))
    }

    fn request_payload_async(&mut self, mut value: Value, bytes: Option<&[u8]>) -> Result<u64> {
        ensure!(value.is_object(), "Session request must be an object");
        ensure!(
            self.pending.len() < 1024,
            "Too many pending session requests"
        );
        self.sequence = self
            .sequence
            .checked_add(1)
            .context("Session request IDs exhausted")?;
        value["request"] = json!(self.sequence);
        if let Some(bytes) = bytes { self.send_binary(&value, bytes)?; } else { self.send(&value)?; }
        self.pending.insert(self.sequence);
        Ok(self.sequence)
    }

    pub fn take_reply(&mut self, sequence: u64) -> Option<Result<Value>> {
        let reply = self.take_reply_message(sequence)?;
        Some(if reply["type"] == "error" {
            Err(anyhow!(
                reply["message"]
                    .as_str()
                    .unwrap_or("Server error")
                    .to_owned()
            ))
        } else {
            Ok(reply)
        })
    }

    /// Keep structured errors intact for adapters (for example revision-CAS
    /// conflicts carrying the authoritative workspace snapshot).
    pub fn take_reply_message(&mut self, sequence: u64) -> Option<Value> {
        let reply = self.replies.remove(&sequence)?;
        self.pending.remove(&sequence);
        Some(reply)
    }

    pub fn has_reply(&self, sequence: u64) -> bool {
        self.replies.contains_key(&sequence)
    }

    /// Includes completed replies until consumed or canceled by their caller.
    pub fn pending_request_count(&self) -> usize {
        self.pending.len()
    }

    pub fn cancel_request(&mut self, sequence: u64) {
        self.pending.remove(&sequence);
        self.replies.remove(&sequence);
    }

    /// Startup/explicit actions may wait while still replaying unrelated events.
    /// Ordinary frame loops should use request_async and poll.
    pub fn request(
        &mut self,
        value: Value,
        timeout: Duration,
        mut event: impl FnMut(Event),
    ) -> Result<Value> {
        let id = self.request_async(value)?;
        let result = (|| {
            let deadline = Instant::now() + timeout;
            loop {
                for next in self.poll()? {
                    event(next);
                }
                if let Some(reply) = self.take_reply(id) {
                    return reply;
                }
                ensure!(Instant::now() < deadline, "Session server reply timed out");
                std::thread::sleep(Duration::from_millis(2));
            }
        })();
        if result.is_err() {
            self.cancel_request(id);
        }
        result
    }

    /// User input and explicitly authorized protocol replies share the wire.
    /// Scrolling/focus changes are presentation choices left to the adapter.
    pub fn input(&mut self, session: SessionId, bytes: &[u8]) -> Result<()> {
        self.send_binary(&json!({"type":"input","session":session}), bytes)
    }

    pub fn send_binary(&mut self, header: &Value, bytes: &[u8]) -> Result<()> {
        let packet = graffitty_protocol::pack(header, bytes)?;
        ensure!(
            packet.len() <= graffitty_protocol::MAX_COMMAND_PACKET,
            "Session output limit reached"
        );
        self.transport.send(Packet::Binary(packet))?;
        self.poll_pending.store(true, std::sync::atomic::Ordering::Release);
        Ok(())
    }

    pub fn subscribe(&mut self, sessions: &[SessionId]) -> Result<()> {
        ensure!(sessions.len() <= 32, "Too many session subscriptions");
        self.send(&json!({"type":"subscribe","sessions":sessions}))
    }

    /// Fair, bounded polling. Subsystem messages remain observable to adapters;
    /// canceled replies cannot grow the response table.
    pub fn poll(&mut self) -> Result<Vec<Event>> {
        let result = self.poll_inner();
        if result.is_err() || self.read_error.is_some() { self.controller = None; }
        result
    }

    fn poll_inner(&mut self) -> Result<Vec<Event>> {
        self.poll_pending.store(true, std::sync::atomic::Ordering::Release);
        if self.read_error.is_none() {
            let requests = self.controller.as_mut().map(|c| c.poll()).unwrap_or_default();
            for request in requests { self.send(&request)?; }
        }
        let mut flush_pending = false;
        if self.read_error.is_none() { match self.transport.flush() {
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => { flush_pending = true; }
            result => result?,
        } }
        let mut events: Vec<_> = self.queued.drain(..).collect();
        if !events.is_empty() { self.revision.fetch_add(1, std::sync::atomic::Ordering::Release); }
        for _ in 0..8 {
            let Ok(prepared) = self.scene_worker.output.try_recv() else { break; };
            self.revision.fetch_add(1, std::sync::atomic::Ordering::Release);
            use crate::scene_worker::Prepared;
            match prepared {
                Prepared::Terminal(session, commit) => events.push(Event::Scene { session, commit }),
                Prepared::Asset(session, pixels) => events.push(Event::Asset { session, pixels }),
                Prepared::Error(session, error) => {
                    self.send(&json!({"type":"terminal_resync","session":session}))?;
                    events.push(Event::Message(json!({"type":"terminal_replica_error","session":session,"message":error})));
                }
            }
        }
        if !self.scene_worker.flush() { return Ok(events) }
        if self.read_error.is_some() {
            if !events.is_empty() || !self.scene_worker.idle() { return Ok(events) }
            return Err(self.read_error.take().unwrap().into());
        }
        let mut total = 0;
        for _ in 0..128 {
            let packet = match self.transport.read() {
                Ok(packet) => {
                    self.revision.fetch_add(1, std::sync::atomic::Ordering::Release);
                    packet
                },
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    self.poll_pending.store(flush_pending, std::sync::atomic::Ordering::Release);
                    break;
                }
                Err(e) if total > 0 || !events.is_empty() || !self.scene_worker.idle() => {
                    // A final close reply/event and EOF often arrive in the
                    // same poll. Deliver those packets before reporting EOF.
                    self.read_error = Some(e);
                    break;
                }
                Err(e) => return Err(e.into()),
            };
            match packet {
                Packet::Text(bytes) => {
                    total += bytes.len();
                    let value = crate::graph_state::decode_message(&bytes).map_err(anyhow::Error::msg)?;
                    if self.controller.as_mut().is_some_and(|c| c.complete(&value)) { continue; }
                    if value["type"] == "topology" {
                        if let Some(snapshot) = value.get("graph") {
                            self.graph.receive(0, snapshot.clone()).map_err(anyhow::Error::msg)?;
                        }
                    } else if matches!(value["type"].as_str(),Some("ready" | "session_switched" | "session_closed")) {
                        self.graph.replace(0,None);
                    }
                    if let Some(id) = value["request"].as_u64() {
                        if self.pending.contains(&id) {
                            self.replies.insert(id, value);
                        }
                    } else {
                        events.push(match value["type"].as_str() {
                            Some("ready") => Event::Ready(value),
                            Some("topology") => Event::Topology(value),
                            Some("resources") => Event::Resources(value),
                            Some("notification") => Event::Notification(value),
                            Some("frontend_request") => Event::FrontendRequest(value),
                            _ => Event::Message(value),
                        });
                    }
                }
                Packet::Binary(bytes) => {
                    total += bytes.len();
                    let (header, payload) = graffitty_protocol::unpack(&bytes, ipc::MAX_PACKET)?;
                    if header["type"] == "terminal" {
                        let job = crate::scene_worker::Job::Terminal(SessionId(header["session"].as_u64().context("Missing terminal ID")?),
                            serde_json::from_value(header.clone())?, serde_json::from_value(header["scene"].clone())?, payload.to_vec());
                        if !self.scene_worker.submit(job) { break }
                        continue;
                    }
                    if header["type"] == "terminal_asset" {
                        let job = crate::scene_worker::Job::Asset(SessionId(header["session"].as_u64().context("Missing asset session")?),
                            serde_json::from_value(header["asset"].clone())?, payload.to_vec());
                        if !self.scene_worker.submit(job) { break }
                        continue;
                    }
                    events.push(match header["type"].as_str() {
                        Some("chromium") => Event::Chromium {
                            session: ChromiumId(
                                header["session"].as_u64().context("Missing chromium ID")?,
                            ),
                            bytes: payload.to_vec(),
                            header,
                        },
                        _ => Event::Binary {
                            bytes: payload.to_vec(),
                            header,
                        },
                    });
                }
            }
            if total >= ipc::MAX_PACKET {
                break;
            }
        }
        Ok(events)
    }
}
