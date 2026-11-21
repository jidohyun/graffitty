//! Verified per-client native chromium transport; video remains the fallback.
use crate::{Client, Error, Server, send};
use graffitty_chromium_video::shared_gpu::Channel;
use serde_json::{Value, json};
use std::collections::HashMap;

const MECHANISM: &str = if cfg!(windows) { "d3d-shared-nt-v1" } else { "mach-iosurface-v1" };

#[derive(Default)]
pub struct Channels(HashMap<u64, (Channel, u64)>);
impl Channels {
    pub fn active(&self, id: u64) -> bool {
        self.0.get(&id).is_some_and(|(channel, _)| channel.active())
    }
    pub fn retain(&mut self, mut live: impl FnMut(u64) -> bool) {
        self.0.retain(|id, _| live(*id));
    }
    pub fn handle(server: &Server, client: &mut Client, value: &Value) -> Result<(), Error> {
        let result = (|| -> Result<Value, String> {
            let id = value["session"].as_u64().ok_or("Missing chromium session")?;
            if !server
                .chromiums
                .get(&id)
                .is_some_and(|b| b.workspace == client.workspace)
            {
                return Err("Unknown chromium in this workspace".into());
            }
            match value["type"].as_str() {
                Some("chromium_gpu_offer") => {
                    client.gpu.0.remove(&id);
                    if value["mechanism"] != MECHANISM {
                        return Err("Unsupported GPU resource mechanism".into());
                    }
                    let crate::connection::Connection::Local(peer) = &client.socket else {
                        return Err("Native GPU exchange requires a direct local connection".into());
                    };
                    let pid = peer
                        .local_peer_pid()
                        .ok_or("Cannot verify native socket peer")?;
                    let endpoint = value["endpoint"]
                        .as_str()
                        .ok_or("Missing native GPU endpoint")?;
                    client.gpu.0.insert(id, (Channel::new(endpoint, pid)?, 0));
                    Ok(json!({"active":false,"mechanism":MECHANISM}))
                }
                Some("chromium_gpu_confirm") => {
                    let (channel, _) = client
                        .gpu
                        .0
                        .get_mut(&id)
                        .ok_or("No GPU probe for this connection")?;
                    match channel.confirm() {
                        Ok(active) => Ok(json!({"active":active,"mechanism":MECHANISM})),
                        Err(error) => {
                            client.gpu.0.remove(&id);
                            Err(error)
                        }
                    }
                }
                Some("chromium_gpu_reject") => {
                    client.gpu.0.remove(&id);
                    client.revisions.remove(&id);
                    client.video_cursors.remove(&id);
                    Ok(json!({"active":false}))
                }
                _ => Err("Unknown GPU command".into()),
            }
        })();
        send(
            client,
            match result {
                Ok(result) => json!({"type":"ack","request":value["request"],"result":result}),
                Err(error) => json!({"type":"error","request":value["request"],"message":error}),
            },
        )
    }
    /// True means this client has a verified GPU channel (including when no new
    /// frame is available). A failed native send drops it and resumes video.
    pub fn deliver(&mut self, id: u64, video: &crate::chromium_video::Pipeline) -> bool {
        let Some((channel, previous)) = self.0.get_mut(&id).filter(|(c, _)| c.active()) else {
            return false;
        };
        let Some((revision, surface)) = video.surface() else {
            return true;
        };
        if *previous == revision {
            return true;
        }
        match channel.send(&surface, revision) {
            Ok(sent) => {
                if sent {
                    *previous = revision;
                }
                true
            }
            Err(_) => {
                self.0.remove(&id);
                false
            }
        }
    }
}
