//! One bounded, leased CDP endpoint per server-owned chromium. The UI never owns
//! a DevTools listener or forwards page contents through its rendering loop.
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet, VecDeque},
    net::{TcpListener, TcpStream},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use tungstenite::{
    Error, HandshakeError, Message, WebSocket,
    handshake::{
        MidHandshake,
        server::{Callback, ErrorResponse, Request, Response, ServerHandshake},
    },
    protocol::{CloseFrame, WebSocketConfig, frame::coding::CloseCode},
};
const LIMIT: usize = 32 * 1024 * 1024;
const REQUESTS: usize = 4096;

#[derive(Debug)]
pub struct AttachError(pub &'static str, pub &'static str);
impl std::fmt::Display for AttachError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.1)
    }
}
impl std::error::Error for AttachError {}

struct Authorization {
    path: String,
    accepted: Arc<AtomicBool>,
}
impl Callback for Authorization {
    fn on_request(self, request: &Request, response: Response) -> Result<Response, ErrorResponse> {
        self.accepted
            .store(request.uri().to_string() == self.path, Ordering::Relaxed);
        Ok(response) // Complete the upgrade, then reject with WebSocket close 1008.
    }
}
struct Handshake {
    state: MidHandshake<ServerHandshake<TcpStream, Authorization>>,
    accepted: Arc<AtomicBool>,
    started: Instant,
}
struct Lease {
    token: String,
    listener: Option<TcpListener>,
    pending: Vec<Handshake>,
    peer: Option<WebSocket<TcpStream>>,
    deadline: Instant,
    sessions: HashSet<String>,
    auto_attach: bool,
}
struct Pending {
    token: String,
    id: Value,
    session: Option<Value>,
    method: String,
    started: Instant,
}
pub struct Command {
    pub message: Value,
    pub borrowed: bool,
}
#[derive(Default)]
pub struct Broker {
    lease: Option<Lease>,
    pending: HashMap<u64, Pending>,
    cleanup: VecDeque<Value>,
}
fn blocked(error: &Error) -> bool {
    matches!(error, Error::Io(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut))
}
fn close(peer: &mut WebSocket<TcpStream>, code: CloseCode, reason: &'static str) {
    let _ = peer.close(Some(CloseFrame {
        code,
        reason: reason.into(),
    }));
    let _ = peer.flush();
}
impl Broker {
    pub fn is_active(&self) -> bool {
        self.lease.is_some()
    }
    pub fn open(
        &mut self,
        chromium: u64,
        target: &str,
    ) -> Result<Value, Box<dyn std::error::Error>> {
        if self.lease.is_some() {
            return Err(Box::new(AttachError(
                "chromium_busy",
                "This chromium already has a Playwright attachment",
            )));
        }
        if self.pending.len() >= REQUESTS {
            return Err(Box::new(AttachError(
                "chromium_busy",
                "Previous attachment commands are still completing",
            )));
        }
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let result = json!({"endpoint":format!("ws://127.0.0.1:{port}/{token}"), "lease":token,
            "target_id":target, "expires_in_ms":30000, "chromium":format!("%{chromium}")});
        self.lease = Some(Lease {
            token,
            listener: Some(listener),
            pending: vec![],
            peer: None,
            deadline: Instant::now() + Duration::from_secs(30),
            sessions: HashSet::new(),
            auto_attach: false,
        });
        Ok(result)
    }
    pub fn release(&mut self, token: Option<&str>) {
        if token.is_some_and(|token| self.lease.as_ref().is_none_or(|lease| lease.token != token)) {
            return;
        }
        let Some(mut lease) = self.lease.take() else {
            return;
        };
        if let Some(peer) = &mut lease.peer {
            close(peer, CloseCode::Normal, "Attachment released");
        }
        // These are chromium-session agents installed by the borrowed client.
        self.cleanup
            .push_back(json!({"method":"Target.setAutoAttach", "params":{
            "autoAttach":false,"waitForDebuggerOnStart":false,"flatten":true}}));
        self.cleanup
            .push_back(json!({"method":"Target.setDiscoverTargets", "params":{"discover":false}}));
        for session in lease.sessions {
            self.detach(session);
        }
        // Keep outstanding IDs until their replies arrive: a late attach reply
        // still creates a session which must be detached, never given to a new lease.
    }
    fn detach(&mut self, session: String) {
        self.cleanup
            .push_back(json!({"method":"Target.detachFromTarget", "params":{"sessionId":session}}));
    }
    fn send_client(&mut self, message: &Value) {
        let Some(peer) = self.lease.as_mut().and_then(|lease| lease.peer.as_mut()) else {
            return;
        };
        let text = message.to_string();
        if text.len() > LIMIT {
            self.release(None);
            return;
        }
        if let Err(error) = peer.send(Message::Text(text.into())) {
            if !blocked(&error) {
                self.release(None);
            }
        }
    }
    /// Poll a bounded amount of socket work on every owner CDP receive, including
    /// while an ordinary owner command is waiting for its response.
    pub fn poll(&mut self) -> Vec<Command> {
        if self.lease.as_ref().is_some_and(|lease| {
            self.pending.values().any(|request| {
                request.token == lease.token && request.started.elapsed() > Duration::from_secs(30)
            })
        }) {
            self.release(None);
            // Retain bounded tombstones until their replies arrive, so even a
            // very late attach cannot leave a borrowed CDP agent in the owner.
        }
        let mut messages = Vec::new();
        let mut failed = false;
        if let Some(lease) = &mut self.lease {
            if lease.peer.is_none() && Instant::now() > lease.deadline {
                failed = true;
            }
            if let Some(listener) = &lease.listener {
                for _ in 0..8 {
                    let Ok((stream, _)) = listener.accept() else {
                        break;
                    };
                    if lease.pending.len() >= 8 {
                        continue;
                    }
                    if stream.set_nonblocking(true).is_err() {
                        continue;
                    }
                    let _ = stream.set_nodelay(true);
                    let accepted = Arc::new(AtomicBool::new(false));
                    let config = WebSocketConfig::default()
                        .read_buffer_size(4096)
                        .write_buffer_size(0)
                        .max_write_buffer_size(LIMIT)
                        .max_message_size(Some(LIMIT))
                        .max_frame_size(Some(LIMIT));
                    let callback = Authorization {
                        path: format!("/{}", lease.token),
                        accepted: accepted.clone(),
                    };
                    match tungstenite::accept_hdr_with_config(stream, callback, Some(config)) {
                        Ok(mut peer) => {
                            if accepted.load(Ordering::Relaxed) && lease.peer.is_none() {
                                lease.peer = Some(peer);
                            } else {
                                close(&mut peer, CloseCode::Policy, "Unauthorized attachment");
                            }
                        }
                        Err(HandshakeError::Interrupted(state)) => lease.pending.push(Handshake {
                            state,
                            accepted,
                            started: Instant::now(),
                        }),
                        Err(_) => {}
                    }
                }
            }
            for pending in std::mem::take(&mut lease.pending) {
                if pending.started.elapsed() > Duration::from_secs(5) {
                    continue;
                }
                match pending.state.handshake() {
                    Ok(mut peer) => {
                        if pending.accepted.load(Ordering::Relaxed) && lease.peer.is_none() {
                            lease.peer = Some(peer);
                        } else {
                            close(&mut peer, CloseCode::Policy, "Unauthorized attachment");
                        }
                    }
                    Err(HandshakeError::Interrupted(state)) => {
                        lease.pending.push(Handshake { state, ..pending })
                    }
                    Err(_) => {}
                }
            }
            if let Some(peer) = &mut lease.peer {
                lease.listener = None;
                if let Err(error) = peer.flush() {
                    failed |= !blocked(&error);
                }
                let mut bytes = 0;
                for _ in 0..128 {
                    match peer.read() {
                        Ok(Message::Text(text)) => {
                            bytes += text.len();
                            let Ok(value) = serde_json::from_str::<Value>(&text) else {
                                failed = true;
                                break;
                            };
                            if !value["method"].is_string()
                                || !value["id"].is_u64()
                                || bytes > 4 * 1024 * 1024
                            {
                                failed = true;
                                break;
                            }
                            messages.push(value);
                        }
                        Ok(Message::Close(_)) => {
                            let _ = peer.flush();
                            failed = true;
                            break;
                        }
                        Ok(Message::Ping(_) | Message::Pong(_)) => {}
                        Ok(_) => {
                            failed = true;
                            break;
                        }
                        Err(error) if blocked(&error) => break,
                        Err(_) => {
                            failed = true;
                            break;
                        }
                    }
                }
            }
        }
        if failed {
            self.release(None);
            messages.clear();
        }
        let mut commands: Vec<_> = self
            .cleanup
            .drain(..)
            .map(|message| Command {
                message,
                borrowed: false,
            })
            .collect();
        for message in messages {
            let Some(lease) = &mut self.lease else {
                break;
            };
            let method = message["method"].as_str().unwrap();
            let unknown_session = message["sessionId"]
                .as_str()
                .is_some_and(|s| !lease.sessions.contains(s));
            let detach_other = method == "Target.detachFromTarget"
                && message["params"]["sessionId"]
                    .as_str()
                    .is_none_or(|s| !lease.sessions.contains(s));
            if matches!(
                method,
                "Browser.close"
                    | "Target.createBrowserContext"
                    | "Target.disposeBrowserContext"
                    | "Target.sendMessageToTarget"
            ) || unknown_session
                || detach_other
                || method.starts_with("Graffitty.")
            {
                let mut response = json!({"id":message["id"],"error":{"code":-32000,"message":"Graffitty owns this chromium and context; attach to the existing page"}});
                if let Some(session) = message.get("sessionId") {
                    response["sessionId"] = session.clone();
                }
                self.send_client(&response);
            } else {
                if method == "Target.setAutoAttach" && message.get("sessionId").is_none() {
                    lease.auto_attach = message["params"]["autoAttach"] == true;
                }
                if self.pending.len() + commands.len() >= REQUESTS {
                    self.release(None);
                    break;
                }
                commands.push(Command {
                    message,
                    borrowed: true,
                });
            }
        }
        if self.lease.is_none() {
            commands.retain(|command| !command.borrowed);
        }
        commands
    }
    pub fn sent(&mut self, id: u64, message: &Value) {
        let Some(lease) = &self.lease else {
            return;
        };
        self.pending.insert(
            id,
            Pending {
                token: lease.token.clone(),
                id: message["id"].clone(),
                session: message.get("sessionId").cloned(),
                method: message["method"].as_str().unwrap().into(),
                started: Instant::now(),
            },
        );
    }
    /// Returns true for borrowed replies/events; ordinary owner replies are untouched.
    pub fn receive(&mut self, value: &Value) -> bool {
        if let Some(id) = value["id"].as_u64() {
            let Some(request) = self.pending.remove(&id) else {
                return false;
            };
            let current = self
                .lease
                .as_ref()
                .is_some_and(|lease| lease.token == request.token);
            if request.method == "Target.attachToTarget"
                || request.method == "Target.attachToBrowserTarget"
            {
                if let Some(session) = value["result"]["sessionId"].as_str() {
                    if current {
                        self.lease.as_mut().unwrap().sessions.insert(session.into());
                    } else {
                        self.detach(session.into());
                    }
                }
            }
            if current {
                let mut response = value.clone();
                response["id"] = request.id;
                if let Some(session) = request.session {
                    response["sessionId"] = session;
                }
                self.send_client(&response);
            }
            return true;
        }
        let Some(lease) = &mut self.lease else {
            return false;
        };
        let method = value["method"].as_str().unwrap_or("");
        let parent = value["sessionId"].as_str();
        let owned = parent.is_some_and(|session| lease.sessions.contains(session));
        if method == "Target.attachedToTarget" {
            if !owned && !(parent.is_none() && lease.auto_attach) {
                return false;
            }
            if let Some(session) = value["params"]["sessionId"].as_str() {
                lease.sessions.insert(session.into());
            }
        }
        let root_target_event = parent.is_none() && method.starts_with("Target.");
        if !owned && !root_target_event {
            return false;
        }
        if method == "Target.detachedFromTarget" {
            if let Some(session) = value["params"]["sessionId"].as_str() {
                lease.sessions.remove(session);
            }
        }
        self.send_client(value);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{thread, time::Duration};

    #[test]
    fn leased_socket_authorizes_remaps_and_releases_only_borrowed_sessions() {
        let mut broker = Broker::default();
        let opened = broker.open(17, "primary-page").unwrap();
        let endpoint = opened["endpoint"].as_str().unwrap().to_owned();
        let lease = opened["lease"].as_str().unwrap().to_owned();
        let worker = thread::spawn(move || {
            // A correct token with extra URI data is still not the leased URL.
            let (mut wrong, _) = tungstenite::connect(format!("{endpoint}?extra=1")).unwrap();
            let Message::Close(Some(frame)) = wrong.read().unwrap() else {
                panic!("Expected policy close")
            };
            assert_eq!(frame.code, CloseCode::Policy);
            let (mut socket, _) = tungstenite::connect(endpoint).unwrap();
            let mut call = |message: Value| -> Value {
                socket
                    .send(Message::Text(message.to_string().into()))
                    .unwrap();
                serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap()
            };
            assert_eq!(
                call(json!({"id":1,"method":"Browser.getVersion"})),
                json!({"id":1,"result":{"product":"Chrome/test"}})
            );
            assert!(
                call(json!({"id":2,"method":"Browser.close"}))["error"]["message"]
                    .as_str()
                    .unwrap()
                    .contains("Graffitty owns")
            );
            assert_eq!(
                call(
                    json!({"id":3,"method":"Target.attachToTarget","params":{"targetId":"primary-page","flatten":true}})
                )["result"]["sessionId"],
                "borrowed"
            );
            assert_eq!(
                call(
                    json!({"id":4,"method":"Runtime.evaluate","sessionId":"borrowed","params":{"expression":"42"}})
                ),
                json!({"id":4,"sessionId":"borrowed","result":{"value":42}})
            );
            assert!(call(json!({"id":5,"method":"Target.detachFromTarget","params":{"sessionId":"owner-session"}})).get("error").is_some());
            socket.close(None).unwrap();
            let _ = socket.read();
        });
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut sequence = 100;
        let mut detached = Vec::new();
        while Instant::now() < deadline {
            for command in broker.poll() {
                sequence += 1;
                if !command.borrowed {
                    if command.message["method"] == "Target.detachFromTarget" {
                        detached.push(command.message["params"]["sessionId"].clone());
                    }
                    continue;
                }
                broker.sent(sequence, &command.message);
                assert_ne!(command.message["method"], "Browser.close");
                let result = match command.message["method"].as_str().unwrap() {
                    "Browser.getVersion" => json!({"product":"Chrome/test"}),
                    "Target.attachToTarget" => json!({"sessionId":"borrowed"}),
                    "Runtime.evaluate" => json!({"value":42}),
                    other => panic!("Unexpected command {other}"),
                };
                assert!(broker.receive(&json!({"id":sequence,"result":result})));
                assert!(!broker.receive(&json!({"id":9999,"result":{"owner":true}})));
                assert!(!broker.receive(&json!({"method":"Runtime.consoleAPICalled","sessionId":"owner-session","params":{}})));
            }
            if worker.is_finished() && broker.lease.is_none() {
                break;
            }
            thread::sleep(Duration::from_millis(1));
        }
        assert!(
            worker.is_finished(),
            "WebSocket client must finish within the bounded test deadline"
        );
        worker.join().unwrap();
        assert!(broker.lease.is_none());
        assert!(
            !broker.is_active(),
            "Disconnected automation releases capture demand"
        );
        assert_eq!(detached, vec![json!("borrowed")]);
        let next = broker.open(17, "primary-page").unwrap();
        broker.release(Some(&lease));
        assert_eq!(broker.lease.as_ref().unwrap().token, next["lease"]);
        assert!(
            broker.is_active(),
            "A stale release must not suspend the current page"
        );
    }

    #[test]
    fn revoked_attachment_late_reply_cleans_its_session_without_touching_new_lease() {
        let mut broker = Broker::default();
        let old = broker.open(1, "page").unwrap();
        broker.sent(77, &json!({"id":1,"method":"Target.attachToTarget"}));
        broker.release(Some(old["lease"].as_str().unwrap()));
        let new = broker.open(1, "page").unwrap();
        assert!(broker.receive(&json!({"id":77,"result":{"sessionId":"late-old-session"}})));
        assert!(broker.lease.as_ref().unwrap().sessions.is_empty());
        assert_eq!(broker.lease.as_ref().unwrap().token, new["lease"]);
        let cleanup = broker.poll();
        assert!(cleanup.iter().any(|command| command.message["method"]
            == "Target.detachFromTarget"
            && command.message["params"]["sessionId"] == "late-old-session"));
        assert!(broker.pending.is_empty());
    }
}
