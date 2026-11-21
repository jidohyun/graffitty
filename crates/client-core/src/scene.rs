//! Shared transaction assembly and background preparation for all frontends.
//! A partial snapshot never mutates the visible VT. Heavy snapshot parsing and
//! image decoding run on the receiver thread; adapters receive owned results.
use crate::mirror::Update;
use anyhow::{Result, ensure};
use graffitty_protocol::terminal_scene::{AssetChunk, AssetKey, Graphics, Transaction};
use graffitty_terminal_core::vt::{Terminal};
use std::{collections::BTreeMap, sync::Arc};

/// A default-allocated terminal with no callbacks, borrowed references,
/// custom allocator, or image decoder state. Its exclusive ownership can
/// cross a thread boundary. Once adopted, adapters get the ordinary !Send
/// Terminal.
///
/// Never add an API here accepting callbacks or exposing a borrowed Terminal.
pub struct PreparedTerminal(Terminal<'static, 'static>);
// Ghostty's VT has no thread affinity. The Rust wrapper is !Send because it
// permits arbitrary allocators/callbacks; this constructor permits neither.
unsafe impl Send for PreparedTerminal {}
impl PreparedTerminal {
    fn new(update: &Update) -> Result<Self> {
        let limits = update.limits;
        limits.validate().map_err(anyhow::Error::msg)?;
        let mut vt = graffitty_terminal_core::new_vt(update.columns, update.rows, limits.scrollback_bytes as usize)?;
        vt.set_kitty_image_storage_limit(0)?;
        vt.set_kitty_image_from_file_allowed(false)?;
        vt.set_kitty_image_temp_file_dir(None)?;
        vt.set_kitty_image_from_shared_mem_allowed(false)?;
        Ok(Self(vt))
    }
    pub fn adopt(self) -> Terminal<'static, 'static> {
        self.0
    }
}

pub struct Commit {
    pub update: Update,
    pub revision: u64,
    /// Total text and metadata payload bytes in this committed transaction.
    pub payload_bytes: usize,
    pub graphics: Option<Graphics>,
    pub terminal: Option<PreparedTerminal>,
    pub text: Vec<u8>,
}
impl Commit {
    /// Finish already-prepared state on the worker, not on the UI thread.
    /// Geometry/limit changes remain ordered boundaries; a newer snapshot
    /// supersedes them independently in the presentation mailbox.
    pub(crate) fn fold_delta(&mut self, newer: &mut Self) -> bool {
        if newer.terminal.is_some() || newer.update.reset
            || self.update.columns != newer.update.columns
            || self.update.rows != newer.update.rows
            || self.update.limits != newer.update.limits
        { return false; }
        let Some(terminal) = self.terminal.as_mut() else { return false; };
        terminal.0.vt_write(&newer.text);
        self.update = newer.update.clone();
        self.revision = newer.revision;
        self.payload_bytes = self.payload_bytes.saturating_add(newer.payload_bytes);
        if newer.graphics.is_some() { self.graphics = newer.graphics.take(); }
        true
    }
}

struct Pending {
    revision: u64,
    base: u64,
    total: usize,
    offset: usize,
    update: Update,
    terminal: Option<PreparedTerminal>,
    text: Vec<u8>,
    graphics_bytes: usize,
    metadata: Vec<u8>,
}
#[derive(Default)]
pub struct Replica {
    revision: u64,
    pending: Option<Pending>,
}
impl Replica {
    pub fn push(
        &mut self,
        update: Update,
        transaction: Transaction,
        bytes: &[u8],
    ) -> Result<Option<Commit>> {
        ensure!(
            (1..=500).contains(&update.columns) && (1..=300).contains(&update.rows),
            "Invalid terminal dimensions"
        );
        ensure!(
            transaction.total <= 256 * 1024 * 1024,
            "Terminal snapshot exceeds budget"
        );
        ensure!(
            transaction.graphics_bytes <= transaction.total
                && transaction.graphics_bytes <= 16 * 1024 * 1024,
            "Placement metadata exceeds budget"
        );
        if transaction.offset == 0 {
            ensure!(
                self.pending.is_none() || (transaction.snapshot && transaction.replace),
                "Snapshot replaced without explicit resync"
            );
            ensure!(
                transaction.snapshot || transaction.base == self.revision,
                "Terminal revision gap"
            );
            self.pending = Some(Pending {
                revision: transaction.revision,
                base: transaction.base,
                total: transaction.total,
                offset: 0,
                terminal: if transaction.snapshot {
                    Some(PreparedTerminal::new(&update)?)
                } else {
                    None
                },
                update,
                text: Vec::new(),
                graphics_bytes: transaction.graphics_bytes,
                metadata: Vec::new(),
            });
        }
        let pending = self
            .pending
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("Missing terminal snapshot start"))?;
        ensure!(
            pending.revision == transaction.revision
                && pending.base == transaction.base
                && pending.total == transaction.total
                && pending.graphics_bytes == transaction.graphics_bytes
                && pending.offset == transaction.offset
                && pending.offset + bytes.len() <= pending.total,
            "Invalid terminal transaction sequence"
        );
        let text_len = (pending.total - pending.graphics_bytes)
            .saturating_sub(pending.offset)
            .min(bytes.len());
        if let Some(terminal) = &mut pending.terminal {
            terminal.0.vt_write(&bytes[..text_len]);
        } else {
            pending.text.extend_from_slice(&bytes[..text_len]);
        }
        pending.metadata.extend_from_slice(&bytes[text_len..]);
        pending.offset += bytes.len();
        if !transaction.commit {
            return Ok(None);
        }
        ensure!(pending.offset == pending.total, "Premature terminal commit");
        let pending = self.pending.take().unwrap();
        self.revision = pending.revision;
        let graphics = if pending.metadata.is_empty() {
            None
        } else {
            Some(serde_json::from_slice(&pending.metadata)?)
        };
        Ok(Some(Commit {
            update: pending.update,
            revision: pending.revision,
            payload_bytes: pending.total,
            graphics,
            terminal: pending.terminal,
            text: pending.text,
        }))
    }
    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

#[derive(Clone)]
pub struct Pixels {
    pub key: AssetKey,
    pub width: u32,
    pub height: u32,
    pub rgba: Arc<[u8]>,
}
#[derive(Default)]
pub struct Assets {
    pending: BTreeMap<AssetKey, (AssetChunk, Vec<u8>)>,
}
impl Assets {
    pub fn push(&mut self, chunk: AssetChunk, bytes: &[u8]) -> Result<Option<Pixels>> {
        ensure!(
            chunk.width > 0
                && chunk.height > 0
                && chunk.width <= 8192
                && chunk.height <= 8192
                && u64::from(chunk.width) * u64::from(chunk.height) <= 64 * 1024 * 1024
                && chunk.total <= 256 * 1024 * 1024,
            "Image exceeds budget"
        );
        if chunk.offset == 0 {
            ensure!(self.pending.len() < 32, "Too many image transfers");
            self.pending
                .insert(chunk.asset.clone(), (chunk.clone(), Vec::new()));
        }
        ensure!(
            self.pending
                .values()
                .map(|(_, data)| data.len())
                .sum::<usize>()
                + bytes.len()
                <= 320_000_000,
            "Pending image byte budget exceeded"
        );
        let (first, data) = self
            .pending
            .get_mut(&chunk.asset)
            .ok_or_else(|| anyhow::anyhow!("Missing image transfer start"))?;
        ensure!(
            data.len() == chunk.offset
                && data.len() + bytes.len() <= chunk.total
                && first.total == chunk.total
                && first.width == chunk.width
                && first.height == chunk.height
                && first.format == chunk.format,
            "Invalid image transfer sequence"
        );
        data.extend_from_slice(bytes);
        if data.len() != chunk.total {
            return Ok(None);
        }
        let (_, data) = self.pending.remove(&chunk.asset).unwrap();
        let rgba = graffitty_terminal_core::scene::decode_asset(&chunk, data)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
        Ok(Some(Pixels {
            key: chunk.asset,
            width: chunk.width,
            height: chunk.height,
            rgba,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn update() -> Update {
        Update {
            columns: 20,
            rows: 5,
            reset: false,
            exited: false,
            limits: Default::default(),
        }
    }
    fn tx(
        revision: u64,
        base: u64,
        snapshot: bool,
        offset: usize,
        total: usize,
        commit: bool,
    ) -> Transaction {
        Transaction {
            revision,
            base,
            snapshot,
            replace: false,
            offset,
            total,
            commit,
            graphics_bytes: 0,
        }
    }
    #[test]
    fn partial_snapshot_keeps_visible_terminal_until_atomic_adoption() {
        let mut view = crate::mirror::Mirror::new(20, 5, (10, 20), Default::default()).unwrap();
        view.apply(&update(), b"OLD_VISIBLE").unwrap();
        let mut replica = Replica::default();
        assert!(
            replica
                .push(update(), tx(9, 0, true, 0, 13, false), b"\x1bcNEW")
                .unwrap()
                .is_none()
        );
        assert!(view.text(false).unwrap().contains("OLD_VISIBLE"));
        let commit = replica
            .push(update(), tx(9, 0, true, 5, 13, true), b"_VISIBLE")
            .unwrap()
            .unwrap();
        view.apply_scene(commit).unwrap();
        let text = view.text(false).unwrap();
        assert!(text.contains("NEW_VISIBLE") && !text.contains("OLD_VISIBLE"));
        let commit = replica
            .push(update(), tx(10, 9, false, 0, 1, true), b"!")
            .unwrap()
            .unwrap();
        view.apply_scene(commit).unwrap();
        assert!(view.text(false).unwrap().contains("NEW_VISIBLE!"));
    }
    #[test]
    fn revision_gaps_and_replaced_or_truncated_snapshots_are_rejected() {
        let mut replica = Replica::default();
        assert!(
            replica
                .push(update(), tx(4, 3, false, 0, 1, true), b"x")
                .is_err()
        );
        replica.reset();
        replica
            .push(update(), tx(4, 0, true, 0, 10, false), b"first")
            .unwrap();
        assert!(
            replica
                .push(update(), tx(5, 0, true, 0, 5, true), b"later")
                .is_err()
        );
        assert!(
            replica
                .push(update(), tx(4, 0, true, 5, 10, true), b"bad")
                .is_err()
        );
    }
    #[test]
    fn prepared_snapshot_can_cross_worker_boundary_without_callbacks() {
        let commit = std::thread::spawn(|| {
            Replica::default()
                .push(update(), tx(1, 0, true, 0, 4, true), b"TEXT")
                .unwrap()
                .unwrap()
        })
        .join()
        .unwrap();
        let mut view = crate::mirror::Mirror::new(20, 5, (10, 20), Default::default()).unwrap();
        view.apply_scene(commit).unwrap();
        assert!(view.text(false).unwrap().contains("TEXT"));
    }
    #[test]
    fn large_graphics_metadata_is_chunked_separately_from_text() {
        let mut replica = Replica::default();
        let graphics = Graphics {
            images: (1..2000)
                .map(|id| graffitty_protocol::terminal_scene::Image {
                    id,
                    asset: AssetKey("a".repeat(64)),
                    width: 1,
                    height: 1,
                })
                .collect(),
            placements: vec![],
        };
        let metadata = serde_json::to_vec(&graphics).unwrap();
        assert!(metadata.len() > graffitty_protocol::MAX_HEADER);
        let mut bytes = b"TEXT".to_vec();
        bytes.extend(&metadata);
        let mut committed = None;
        for (i, part) in bytes.chunks(16384).enumerate() {
            let offset = i * 16384;
            let mut transaction = tx(
                1,
                0,
                true,
                offset,
                bytes.len(),
                offset + part.len() == bytes.len(),
            );
            transaction.graphics_bytes = metadata.len();
            committed = replica.push(update(), transaction, part).unwrap();
        }
        let commit = committed.unwrap();
        assert_eq!(commit.graphics.as_ref().unwrap().images.len(), 1999);
        let mut view = crate::mirror::Mirror::new(20, 5, (10, 20), Default::default()).unwrap();
        view.apply_scene(commit).unwrap();
        assert_eq!(view.text(false).unwrap().trim(), "TEXT");
    }
    #[test]
    fn explicit_resync_replaces_only_staging_not_visible_state() {
        let mut replica = Replica::default();
        replica
            .push(update(), tx(1, 0, true, 0, 100, false), b"STALE")
            .unwrap();
        let mut replacement = tx(2, 0, true, 0, 5, true);
        replacement.replace = true;
        let commit = replica
            .push(update(), replacement, b"FRESH")
            .unwrap()
            .unwrap();
        let mut view = crate::mirror::Mirror::new(20, 5, (10, 20), Default::default()).unwrap();
        view.apply_scene(commit).unwrap();
        assert_eq!(view.text(false).unwrap().trim(), "FRESH");
    }
}
