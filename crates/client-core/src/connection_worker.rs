//! Own the socket and request correlation away from a frontend's render loop.
use crate::{client::Event, server::Connection};
use anyhow::{Result, anyhow};
use graffitty_protocol::SessionId;
use serde_json::Value;
use std::{
    collections::BTreeMap,
    sync::mpsc::{self, Receiver, SyncSender},
    time::Duration,
};

enum Command {
    Json(Value),
    Input(SessionId, Vec<u8>),
    Binary(Value, Vec<u8>),
}
pub struct Worker {
    input: SyncSender<Command>,
    pub output: Receiver<Result<Event, String>>,
    pub server_pid: Option<u32>,
    pub peer_pid: Option<u32>,
}
impl Worker {
    pub fn new(mut connection: Connection) -> Self {
        let (input, commands) = mpsc::sync_channel(128);
        let (events, output) = mpsc::sync_channel(64);
        let server_pid = connection.server_pid;
        let peer_pid = connection.client.local_peer_pid();
        std::thread::Builder::new()
            .name("session-connection".into())
            .spawn(move || {
                let mut requests = BTreeMap::new();
                let result = (|| -> Result<()> {
                    loop {
                        for _ in 0..128 {
                            match commands.try_recv() {
                                Ok(Command::Json(mut value)) => {
                                    if let Some(original) =
                                        value.as_object_mut().and_then(|v| v.remove("request"))
                                    {
                                        requests.insert(
                                            connection.client.request_async(value)?,
                                            original,
                                        );
                                    } else {
                                        connection.client.send(&value)?;
                                    }
                                }
                                Ok(Command::Binary(mut value, bytes)) => {
                                    if let Some(original) = value.as_object_mut().and_then(|v| v.remove("request")) {
                                        requests.insert(connection.client.request_binary_async(value, &bytes)?, original);
                                    } else {
                                        connection.client.send_binary(&value, &bytes)?;
                                    }
                                }
                                Ok(Command::Input(id, bytes)) => {
                                    connection.client.input(id, &bytes)?
                                }
                                Err(mpsc::TryRecvError::Empty) => break,
                                Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
                            }
                        }
                        for event in connection.client.poll()? {
                            if events.send(Ok(event)).is_err() {
                                return Ok(());
                            }
                        }
                        let ids: Vec<_> = requests.keys().copied().collect();
                        for id in ids {
                            if let Some(mut reply) = connection.client.take_reply_message(id) {
                                reply["request"] = requests.remove(&id).unwrap();
                                if events.send(Ok(Event::Message(reply))).is_err() {
                                    return Ok(());
                                }
                            }
                        }
                        std::thread::sleep(Duration::from_millis(1));
                    }
                })();
                if let Err(error) = result {
                    let _ = events.send(Err(error.to_string()));
                }
            })
            .expect("Start session connection worker");
        Self {
            input,
            output,
            server_pid,
            peer_pid,
        }
    }
    pub fn send(&self, value: Value) -> Result<()> {
        self.input
            .try_send(Command::Json(value))
            .map_err(|_| anyhow!("Session command queue is full or closed"))
    }
    pub fn binary(&self, header: Value, bytes: Vec<u8>) -> Result<()> {
        self.input.try_send(Command::Binary(header, bytes))
            .map_err(|_| anyhow!("Session command queue is full or closed"))
    }
    pub fn input(&self, session: SessionId, bytes: Vec<u8>) -> Result<()> {
        self.input
            .try_send(Command::Input(session, bytes))
            .map_err(|_| anyhow!("Session input queue is full or closed"))
    }
}
