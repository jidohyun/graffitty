//! Per-connection replication cursors. An in-flight snapshot is immutable;
//! later owner revisions are delivered after its commit, never spliced into it.
use crate::{Client, Error, Message, Session, packet, queue};
use graffitty_protocol::terminal_scene::{AssetChunk, AssetKey, Graphics, Transaction};
use graffitty_terminal_core::scene::Asset;
use serde_json::json;
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
};

const CHUNK: usize = 64 * 1024;

fn checkpoint_backlog(bytes: usize, at_boundary: bool) -> bool {
    at_boundary && bytes > CHUNK
}

/// End-to-end credit, including bytes already accepted by the OS TCP buffer.
#[derive(Default)]
struct Flow {
    enabled: bool,
    sequence: u64,
    outstanding: VecDeque<(u64, usize)>,
    bytes: usize,
}
impl Flow {
    fn available(&self) -> bool {
        // Reserve one full chunk before sending. Small updates from several
        // panes can share the same 128 KiB payload budget, while a packet cap
        // also bounds metadata and decoder work for empty/tiny transactions.
        !self.enabled || (self.bytes <= CHUNK && self.outstanding.len() < 8)
    }
    fn tag(&mut self, header: &mut serde_json::Value, bytes: usize) {
        if self.enabled {
            self.sequence += 1;
            header["flow"] = json!(self.sequence);
            self.outstanding.push_back((self.sequence, bytes));
            self.bytes += bytes;
        }
    }
    fn acknowledge(&mut self, sequence: u64) {
        if sequence > self.sequence { return; }
        while self.outstanding.front().is_some_and(|(n, _)| *n <= sequence) {
            self.bytes -= self.outstanding.pop_front().unwrap().1;
        }
    }
}
struct Pending {
    bytes: Arc<Vec<u8>>,
    offset: usize,
    revision: u64,
    base: u64,
    generation: u64,
    snapshot: bool,
    graphics: Graphics,
    columns: u16,
    rows: u16,
    exited: bool,
    limits: crate::spawn::TerminalLimits,
    graphics_bytes: usize,
}
#[derive(Default)]
struct Cursor {
    revision: u64,
    generation: u64,
    pending: Option<Pending>,
    graphics: Graphics,
    resnapshot: bool,
}

#[derive(Default)]
pub struct Replication {
    flow: Flow,
    last_terminal: Option<u64>,
    cursors: HashMap<u64, Cursor>,
    assets: VecDeque<(u64, Arc<Asset>, usize)>,
    #[cfg(target_os = "macos")]
    pub gpu: Option<graffitty_chromium_video::shared_gpu::Channel>,
    sequence: u64,
}

impl Replication {
    pub fn terminal_order(&self, sessions: &[u64]) -> Vec<u64> {
        let mut order = sessions.to_vec();
        if let Some(index) = self.last_terminal.and_then(|id| order.iter().position(|s| *s == id)) {
            let count = order.len();
            order.rotate_left((index + 1) % count);
        }
        order
    }
    pub fn enable_flow(&mut self) { self.flow.enabled = true; }
    pub fn acknowledge(&mut self, sequence: u64) { self.flow.acknowledge(sequence); }
    pub fn pending(&self) -> bool {
        if !self.flow.available() { return false; }
        // A full native mailbox is retried on the event loop's normal tick.
        // Spinning here would consume a CPU while the renderer is busy.
        #[cfg(target_os = "macos")]
        let byte_assets = self.gpu.as_ref().is_none_or(|gpu| !gpu.active());
        #[cfg(not(target_os = "macos"))]
        let byte_assets = true;
        (byte_assets && !self.assets.is_empty())
            || self.cursors.values().any(|c| c.pending.is_some())
    }
    pub fn retain(&mut self, sessions: &[u64]) {
        self.cursors.retain(|id, _| sessions.contains(id));
        self.assets.retain(|(id, ..)| sessions.contains(id));
    }
    pub fn subscribe(&mut self, sessions: &[u64]) {
        self.retain(sessions);
        for cursor in self.cursors.values_mut() {
            cursor.resnapshot = true;
        }
    }
    pub fn request(&mut self, session: u64, asset: Arc<Asset>) -> Result<(), Error> {
        if self
            .assets
            .iter()
            .any(|(id, a, _)| *id == session && a.key == asset.key)
        {
            return Ok(());
        }
        if self.assets.len() >= 128
            || self
                .assets
                .iter()
                .map(|(_, a, _)| a.rgba.len())
                .sum::<usize>()
                + asset.rgba.len()
                > 512 * 1024 * 1024
        {
            return Err("Pending image asset budget exceeded".into());
        }
        self.assets.push_back((session, asset, 0));
        Ok(())
    }
    pub fn forget(&mut self, session: u64) {
        self.cursors.remove(&session);
    }
    pub fn terminal(&mut self, session: &mut Session) -> Result<Option<Vec<u8>>, Error> {
        if !self.flow.available() { return Ok(None); }
        let cursor = self.cursors.entry(session.id).or_default();
        // Never replay an obsolete unfinished delta when a complete current
        // state is available. Finish snapshots to guarantee progress even under
        // continuous output; the next transaction samples the latest owner.
        if session.scene_ready() && cursor.pending.as_ref().is_some_and(|p|
            !p.snapshot && p.revision != session.revision) {
            cursor.pending = None;
            cursor.resnapshot = true;
        }
        if cursor.pending.is_none()
            && (cursor.resnapshot
                || cursor.revision != session.revision
                || cursor.generation != session.scene_generation)
        {
            let behind = session
                .presentation_chunks
                .front()
                .is_some_and(|(r, _)| cursor.revision + 1 < *r);
            let snapshot = cursor.resnapshot
                || cursor.revision == 0
                || cursor.generation != session.scene_generation
                || behind
                // A few missed revisions can be tiny scrolling deltas.
                // Replacing those with the entire scrollback amplifies
                // traffic and delays every other pane sharing the bounded
                // credit window.
                //
                // Keep one chunk of deltas; collapse larger redraw backlogs.
                || checkpoint_backlog(
                    session.presentation_chunks.iter()
                        .filter(|(r, _)| *r > cursor.revision)
                        .map(|(_, bytes)| bytes.len()).sum(),
                    session.scene_ready(),
                );
            // A checkpoint cannot serialize an unfinished control string. Live
            // projected text can still flow while an image is being received.
            if snapshot && !session.scene_ready() {
                return Ok(None);
            }
            cursor.resnapshot = false;
            let mut bytes = if snapshot {
                session.scene_checkpoint()?
            } else {
                Arc::new(
                    session
                        .presentation_chunks
                        .iter()
                        .filter(|(r, _)| *r > cursor.revision)
                        .flat_map(|(_, bytes)| bytes.iter().copied())
                        .collect(),
                )
            };
            let graphics = session.scene_graphics()?;
            let metadata = if snapshot || cursor.graphics != graphics {
                serde_json::to_vec(&graphics)?
            } else {
                Vec::new()
            };
            let graphics_bytes = metadata.len();
            if !metadata.is_empty() {
                Arc::make_mut(&mut bytes).extend_from_slice(&metadata);
            }
            cursor.pending = Some(Pending {
                bytes,
                offset: 0,
                revision: session.revision,
                base: cursor.revision,
                generation: session.scene_generation,
                snapshot,
                graphics,
                columns: session.columns,
                rows: session.rows,
                exited: session.exited,
                limits: session.limits,
                graphics_bytes,
            });
        }
        let Some(pending) = cursor.pending.as_mut() else {
            return Ok(None);
        };
        let end = (pending.offset + CHUNK).min(pending.bytes.len());
        let commit = end == pending.bytes.len();
        let transaction = Transaction {
            revision: pending.revision,
            base: pending.base,
            snapshot: pending.snapshot,
            replace: pending.snapshot,
            offset: pending.offset,
            total: pending.bytes.len(),
            commit,
            graphics_bytes: pending.graphics_bytes,
        };
        let mut header = json!({"type":"terminal", "scene":transaction, "session":session.id,
            "columns":pending.columns,"rows":pending.rows,"exited":pending.exited,"limits":pending.limits});
        self.flow.tag(&mut header, end - pending.offset);
        self.last_terminal = Some(session.id);
        let out = packet(&header, &pending.bytes[pending.offset..end]);
        pending.offset = end;
        if commit {
            cursor.revision = pending.revision;
            cursor.generation = pending.generation;
            cursor.graphics = pending.graphics.clone();
            cursor.pending = None;
        }
        Ok(Some(out))
    }
    pub fn asset(
        &mut self,
        sessions: &mut std::collections::BTreeMap<u64, Session>,
        local: bool,
    ) -> Option<Vec<u8>> {
        if !self.flow.available() { return None; }
        let (session, asset, offset) = self.assets.front_mut()?;
        #[cfg(target_os = "macos")]
        if *offset == 0 {
            if let Some(channel) = self.gpu.as_ref().filter(|c| c.active()) {
                let next = self.sequence + 1;
                match sessions
                    .get_mut(session)
                    .ok_or_else(|| "Session closed".to_string())
                    .and_then(|s| s.shared_image(asset))
                    .and_then(|surface| channel.send(&surface, next))
                {
                    Ok(false) => return None,
                    Ok(true) => {
                        self.sequence = next;
                        let header = json!({"type":"terminal_asset_gpu","session":session,"asset":asset.key,"sequence":next,"width":asset.width,"height":asset.height});
                        self.assets.pop_front();
                        return Some(packet(&header, &[]));
                    }
                    Err(_) => self.gpu = None,
                }
            }
        }
        // The owner has already decoded the upload. Direct IPC consumers use
        // those pixels, including reconnects; only network delivery trades
        // client decoding for the smaller retained compressed payload.
        let (format, bytes) = if local {
            ("rgba", asset.rgba.as_ref())
        } else {
            asset.png.as_ref().map_or(("rgba", asset.rgba.as_ref()), |png| ("png", png.as_ref()))
        };
        let end = (*offset + CHUNK).min(bytes.len());
        let chunk = AssetChunk {
            asset: asset.key.clone(),
            width: asset.width,
            height: asset.height,
            format: format.into(),
            offset: *offset,
            total: bytes.len(),
        };
        let mut header = json!({"type":"terminal_asset","session":session,"asset":chunk});
        self.flow.tag(&mut header, end - *offset);
        let out = packet(
            &header,
            &bytes[*offset..end],
        );
        *offset = end;
        if end == bytes.len() {
            self.assets.pop_front();
        }
        Some(out)
    }
}

#[cfg(target_os = "macos")]
pub fn gpu_command(c: &mut Client, value: &serde_json::Value) -> Result<(), Error> {
    let result = (|| -> Result<bool, Error> {
        match value["type"].as_str() {
            Some("terminal_gpu_offer") => {
                let crate::connection::Connection::Local(peer) = &c.socket else {
                    return Err("Native resources require a direct local connection".into());
                };
                let pid = peer.local_peer_pid().ok_or("Cannot verify socket peer")?;
                if value["mechanism"] != "mach-iosurface-v1" {
                    return Err("Unsupported resource mechanism".into());
                }
                c.scenes.gpu = Some(graffitty_chromium_video::shared_gpu::Channel::new(
                    value["endpoint"].as_str().ok_or("Missing GPU endpoint")?,
                    pid,
                )?);
                Ok(false)
            }
            Some("terminal_gpu_confirm") => Ok(c
                .scenes
                .gpu
                .as_mut()
                .ok_or("No resource probe")?
                .confirm()?),
            _ => {
                c.scenes.gpu = None;
                Ok(false)
            }
        }
    })();
    crate::send(
        c,
        match result {
            Ok(active) => {
                json!({"type":"ack","request":value["request"],"result":{"active":active}})
            }
            Err(error) => {
                json!({"type":"error","request":value["request"],"message":error.to_string()})
            }
        },
    )
}

pub fn send_updates(c: &mut Client, session: &mut Session) -> Result<(), Error> {
    if let Some(bytes) = c.scenes.terminal(session)? {
        queue(c, Message::Binary(bytes.into()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn small_backlogs_stay_incremental_and_large_backlogs_checkpoint() {
        assert!(!checkpoint_backlog(0, true));
        assert!(!checkpoint_backlog(1024, true));
        assert!(!checkpoint_backlog(CHUNK, true));
        assert!(checkpoint_backlog(CHUNK + 1, true));
        // Never serialize a partial OSC/APC/control string as a snapshot.
        assert!(!checkpoint_backlog(CHUNK * 100, false));
    }

    #[test]
    fn credits_bound_outstanding_packets_and_reject_future_acknowledgements() {
        let mut flow = Flow { enabled: true, ..Default::default() };
        let mut header = json!({});
        flow.tag(&mut header, CHUNK);
        flow.tag(&mut header, CHUNK);
        assert!(!flow.available());
        flow.acknowledge(3);
        assert!(!flow.available());
        flow.acknowledge(1);
        assert!(flow.available());
        assert_eq!(flow.outstanding.len(), 1);
        flow.acknowledge(1);
        assert_eq!(flow.outstanding.len(), 1);
        flow.acknowledge(2);
        assert!(flow.outstanding.is_empty());
        assert_eq!(flow.bytes, 0);
    }

    #[test]
    fn small_pane_updates_share_byte_credit_but_packet_count_stays_bounded() {
        let mut flow = Flow { enabled: true, ..Default::default() };
        let mut header = json!({});
        for _ in 0..8 {
            assert!(flow.available());
            flow.tag(&mut header, 100);
        }
        assert!(!flow.available());
        assert_eq!(flow.bytes, 800);
        flow.acknowledge(9);
        assert!(!flow.available(), "Future acknowledgments cannot release credit");
        flow.acknowledge(2);
        assert_eq!(flow.bytes, 600);
        assert!(flow.available());
        flow.tag(&mut header, CHUNK);
        assert!(!flow.available(), "A full chunk exhausts the remaining byte budget");
        assert!(flow.bytes <= CHUNK * 2);
    }

}

pub fn requested_key(value: &serde_json::Value) -> Result<AssetKey, Error> {
    let key: AssetKey = serde_json::from_value(value["asset"].clone())?;
    if key.0.len() != 64 || !key.0.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("Invalid image asset key".into());
    }
    Ok(key)
}
