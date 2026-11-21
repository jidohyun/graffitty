//! The same bounded authentication state machine is used by both server frontends.
use super::*;
use serde_json::{Value, json};
use std::sync::mpsc::{Receiver, TryRecvError};

#[derive(Default)]
pub struct Session {
    pending: Option<Pending>,
    factor: Option<SecondFactor>,
    delivery: Option<Receiver<bool>>,
    context: Option<Value>,
    channel: Option<Channel>,
    datagram: Option<Datagram>,
    failed: bool,
}
/// Every login field the server acts on is part of what OPAQUE authenticates,
/// so nobody on the path can rewrite the request.
///
/// Both ends serialize the parsed request, without its `type` and OPAQUE
/// `message`, with sorted keys.
pub fn context(value: &Value) -> Result<Vec<u8>> {
    if value["version"] != graffitty_protocol::VERSION {
        return Err("Unsupported protocol; update the client and server".into());
    }
    for field in ["workspace", "workspace_fallback", "require_workspace", "new_session", "spawn", "saved"] {
        if value.get(field).is_some() {
            return Err("Select sessions after connecting to the server".into());
        }
    }
    let mut bound = value
        .as_object()
        .ok_or("Invalid authentication message")?
        .clone();
    bound.remove("type");
    bound.remove("message");
    let mut context = b"graffitty-remote-opaque-v2\0".to_vec();
    canonical(&Value::Object(bound), &mut context);
    if context.len() > 4096 {
        return Err("Authentication message too large".into());
    }
    Ok(context)
}
/// Key order must not depend on serde_json's `preserve_order` feature, which
/// either end's dependencies could enable.
fn canonical(value: &Value, out: &mut Vec<u8>) {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<_> = map.iter().collect();
            entries.sort_unstable_by(|a, b| a.0.cmp(b.0));
            out.push(b'{');
            for (index, (key, value)) in entries.into_iter().enumerate() {
                if index > 0 {
                    out.push(b',');
                }
                out.extend_from_slice(Value::from(key.as_str()).to_string().as_bytes());
                out.push(b':');
                canonical(value, out);
            }
            out.push(b'}');
        }
        Value::Array(items) => {
            out.push(b'[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(b',');
                }
                canonical(item, out);
            }
            out.push(b']');
        }
        scalar => out.extend_from_slice(scalar.to_string().as_bytes()),
    }
}
impl Session {
    pub fn timeout_seconds(&self) -> u64 {
        if self.factor.is_some() {
            150
        } else if self.pending.is_some() {
            30
        } else {
            10
        }
    }
    pub fn step(&mut self, server: &mut Server, value: &Value) -> Result<Value> {
        if self.failed {
            return Err("Authentication failed".into());
        }
        let result = self.step_inner(server, value);
        if result.is_err() {
            self.failed = true;
            self.pending = None;
            self.factor = None;
        }
        result
    }
    /// The server's half of the encrypted channel, available once
    /// `auth_finish` verified the password. Install it before replying.
    pub fn take_channel(&mut self) -> Option<Channel> {
        self.channel.take()
    }
    /// The server's half of the video datagram cipher, from the same login.
    pub fn take_datagram(&mut self) -> Option<Datagram> {
        self.datagram.take()
    }
    fn step_inner(&mut self, server: &mut Server, value: &Value) -> Result<Value> {
        match value["type"].as_str().unwrap_or("") {
            "auth_start" if self.context.is_none() => {
                let context = context(value)?;
                let (pending, message) =
                    server.start(value["message"].as_str().unwrap_or(""), &context)?;
                self.pending = Some(pending);
                self.context = Some(value.clone());
                Ok(json!({"type":"auth_challenge","message":message}))
            }
            "auth_finish" => {
                let pending = self
                    .pending
                    .take()
                    .ok_or("Unexpected authentication message")?;
                let key = pending.finish(value["message"].as_str().unwrap_or(""))?;
                self.channel = Some(key.channel(Role::Server));
                self.datagram = Some(key.datagram(Role::Server));
                if let Some(profile) = &server.telegram_credential {
                    let factor = SecondFactor::new(key);
                    self.delivery = Some(deliver(
                        profile.clone(),
                        server.telegram_chat_id.clone(),
                        Zeroizing::new(factor.code().into()),
                    ));
                    self.factor = Some(factor);
                    Ok(json!({"type":"auth_wait"}))
                } else {
                    Ok(json!({"type":"authenticated","context":self.context.take()}))
                }
            }
            "auth_code" if self.delivery.is_none() => {
                let mut factor = self.factor.take().ok_or("Unexpected authentication code")?;
                if !factor.verify(value["proof"].as_str().unwrap_or("")) {
                    return Err("Invalid or expired Telegram code".into());
                }
                Ok(json!({"type":"authenticated","context":self.context.take()}))
            }
            _ => Err("Unexpected authentication message".into()),
        }
    }
    pub fn poll(&mut self) -> Result<Option<Value>> {
        let Some(receiver) = &self.delivery else {
            return Ok(None);
        };
        match receiver.try_recv() {
            Ok(true) => {
                self.delivery = None;
                Ok(Some(json!({"type":"auth_code_required","expires_in":120})))
            }
            Err(TryRecvError::Empty) => Ok(None),
            _ => {
                self.delivery = None;
                self.factor = None;
                self.failed = true;
                Err("Could not deliver Telegram code; access denied".into())
            }
        }
    }
}
fn deliver(profile: String, chat: Option<String>, code: Zeroizing<String>) -> Receiver<bool> {
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let result = (|| -> Option<()> {
            let credentials = telegram::resolve(&profile, chat.as_deref()).ok()?;
            let token = credentials.token;
            let chat = credentials.chat;
            // Never log request URLs: the bot credential is part of Telegram's API URL.
            let agent: ureq::Agent = ureq::Agent::config_builder()
                .timeout_global(Some(Duration::from_secs(10)))
                .build()
                .into();
            let mut response = agent.post(format!("https://api.telegram.org/bot{}/sendMessage", token.as_str()))
                .send_json(json!({"chat_id":chat,"text":format!("Graffitty remote sign-in code: {}\nExpires in 2 minutes. Enter only in the client you are connecting.", code.as_str())})).ok()?;
            let body: Value = response.body_mut().read_json().ok()?;
            (body["ok"] == true).then_some(())
        })();
        let _ = tx.send(result.is_some());
    });
    rx
}

#[cfg(test)]
mod tests {
    use super::*;
    fn start_login(server: &mut Server, password: &str, context: &Value) -> (Session, Client, Value) {
        let (client, message) = Client::start(password, &super::context(context).unwrap()).unwrap();
        let mut session = Session::default();
        let mut start = context.clone();
        start["type"] = json!("auth_start");
        start["message"] = json!(message);
        let challenge = session.step(server, &start).unwrap();
        (session, client, challenge)
    }
    #[test]
    fn login_has_no_session_selection() {
        let base = json!({"version":graffitty_protocol::VERSION,"features":["bell"]});
        assert!(context(&base).is_ok());
        for field in ["workspace", "workspace_fallback", "require_workspace", "new_session", "spawn", "saved"] {
            let mut request = base.clone();
            request[field] = json!("$0");
            assert!(context(&request).is_err(), "{field}");
        }
    }
    #[test]
    fn wire_login_opens_the_encrypted_channel() {
        let mut config = Config::default();
        config.set_password("a persistent password").unwrap();
        let mut server = Server::new(config, "temporary").unwrap();
        let context = json!({"version":graffitty_protocol::VERSION,"features":["bell"]});
        let (mut session, client, challenge) = start_login(&mut server, "a persistent password", &context);
        assert!(session.take_channel().is_none(), "No channel before the password is verified");
        let (key, finish) = client
            .finish(challenge["message"].as_str().unwrap())
            .unwrap();
        let result = session
            .step(&mut server, &json!({"type":"auth_finish","message":finish}))
            .unwrap();
        assert!(result["context"].get("workspace").is_none());
        assert_eq!(result["type"], "authenticated");
        let mut server_channel = session.take_channel().unwrap();
        let mut server_datagram = session.take_datagram().unwrap();
        let mut client_datagram = key.datagram(Role::Client);
        let packet = server_datagram.seal(&[0x80], b"video").unwrap();
        assert_eq!(client_datagram.open(&packet, 1).unwrap(), b"video");
        let mut client_channel = key.channel(Role::Client);
        let record = server_channel.seal(Kind::Text, b"ready").unwrap();
        assert_eq!(client_channel.open(&record).unwrap(), (Kind::Text, b"ready".to_vec()));
        assert!(
            session
                .step(&mut server, &json!({"type":"auth_finish","message":finish}))
                .is_err()
        );
    }
    #[test]
    fn plaintext_tokens_and_old_protocols_are_rejected() {
        let mut server = Server::new(Config::default(), "temporary").unwrap();
        for request in [
            json!({"type":"auth","version":graffitty_protocol::VERSION,"token":"temporary"}),
            json!({"type":"auth_start","version":2,"message":""}),
        ] {
            assert!(Session::default().step(&mut server, &request).is_err());
        }
    }
    #[test]
    fn context_ignores_key_order_and_whitespace() {
        let a: Value = serde_json::from_str(
            r#"{"type":"auth_start","version":1,"features":["bell"],"caps":{"b":1,"a":[2,{"d":3,"c":4}]}}"#,
        )
        .unwrap();
        let b: Value = serde_json::from_str(
            r#"{ "caps": {"a": [2, {"c": 4, "d": 3}], "b": 1}, "features": ["bell"], "version": 1, "message": "x" }"#,
        )
        .unwrap();
        assert_eq!(super::context(&a).unwrap(), super::context(&b).unwrap());
        assert!(
            String::from_utf8(super::context(&a).unwrap())
                .unwrap()
                .ends_with(r#"{"caps":{"a":[2,{"c":4,"d":3}],"b":1},"features":["bell"],"version":1}"#)
        );
    }
    #[test]
    fn rewritten_login_requests_fail() {
        let mut server = Server::new(Config::default(), "temporary password").unwrap();
        let context = json!({"version":graffitty_protocol::VERSION,"features":["stream","scene-flow-v1"]});
        let (client, message) =
            Client::start("temporary password", &super::context(&context).unwrap()).unwrap();
        let mut rewritten = context.clone();
        rewritten["type"] = json!("auth_start");
        rewritten["message"] = json!(message);
        rewritten["features"] = json!(["bell"]);
        let challenge = Session::default().step(&mut server, &rewritten).unwrap();
        assert!(client.finish(challenge["message"].as_str().unwrap()).is_err());
    }
    #[test]
    fn delivery_and_code_fail_closed_without_network() {
        let mut server = Server::new(Config::default(), "temporary password").unwrap();
        let (c, m) = Client::start("temporary password", b"test").unwrap();
        let (s, m) = server.start(&m, b"test").unwrap();
        let (key, m) = c.finish(&m).unwrap();
        let mut factor = SecondFactor::new(s.finish(&m).unwrap());
        let proof = key.code_proof(factor.code());
        factor.started = Instant::now() - Duration::from_secs(121);
        assert!(!factor.verify(&proof));
        let (tx, rx) = std::sync::mpsc::sync_channel(1);
        let mut session = Session {
            factor: Some(factor),
            delivery: Some(rx),
            ..Default::default()
        };
        assert!(session.poll().unwrap().is_none());
        tx.send(false).unwrap();
        assert!(session.poll().is_err());
        assert!(
            session
                .step(&mut server, &json!({"type":"auth_code","proof":proof}))
                .is_err()
        );
    }
    #[test]
    fn delivered_code_completes_only_its_own_login() {
        let mut server = Server::new(Config::default(), "temporary password").unwrap();
        let (client, message) = Client::start("temporary password", b"test").unwrap();
        let (pending, message) = server.start(&message, b"test").unwrap();
        let (key, finish) = client.finish(&message).unwrap();
        let factor = SecondFactor::new(pending.finish(&finish).unwrap());
        let proof = key.code_proof(factor.code());
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let mut session = Session {
            factor: Some(factor),
            delivery: Some(receiver),
            context: Some(json!({"features":[]})),
            ..Default::default()
        };
        sender.send(true).unwrap();
        assert_eq!(
            session.poll().unwrap().unwrap()["type"],
            "auth_code_required"
        );
        let request = json!({"type":"auth_code","proof":proof});
        let result = session.step(&mut server, &request).unwrap();
        assert_eq!(result["type"], "authenticated");
        assert_eq!(result["context"]["features"], json!([]));
        assert!(session.step(&mut server, &request).is_err());
    }
}
