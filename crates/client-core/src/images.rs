//! Ordered mirror stream decoding. Pixel compositing belongs to the renderer.
use anyhow::{Result, anyhow, ensure};
use graffitty_terminal_core::vt::Terminal;
use graffitty_terminal_core::{
    images, inline_images,
    terminal_protocol::{Event, Observer},
};

const CELL: (u32, u32) = (10, 22);

pub struct ImageMirror {
    pub scene: Option<graffitty_protocol::terminal_scene::Graphics>,
    pub assets: std::collections::BTreeMap<graffitty_protocol::terminal_scene::AssetKey, crate::scene::Pixels>,
    requested: std::collections::BTreeMap<graffitty_protocol::terminal_scene::AssetKey, std::time::Instant>,
    observer: Observer,
    inline: inline_images::Images,
    cell: (u32, u32),
    limits: graffitty_terminal_core::TerminalLimits,
}

impl Default for ImageMirror {
    fn default() -> Self {
        Self {
            scene: None,
            assets: Default::default(),
            requested: Default::default(),
            observer: Default::default(),
            inline: Default::default(),
            cell: CELL,
            limits: Default::default(),
        }
    }
}

impl ImageMirror {
    pub fn missing_assets(&mut self, vt: &Terminal<'_, '_>) -> Vec<graffitty_protocol::terminal_scene::AssetKey> {
        let Some(scene) = &self.scene else { return Vec::new() };
        let visible = graffitty_terminal_core::image_render::scene_placements(vt, scene, (self.cell.0 as f32, self.cell.1 as f32)).unwrap_or_default();
        let mut missing = Vec::new();
        for image in &scene.images {
            if !visible.iter().any(|p| p.image_id == image.id) || self.assets.contains_key(&image.asset) { continue }
            let now = std::time::Instant::now();
            if self.requested.get(&image.asset).is_some_and(|at| now.duration_since(*at).as_secs() < 10) { continue }
            self.requested.insert(image.asset.clone(), now);
            missing.push(image.asset.clone());
        }
        missing
    }
    pub fn receive_asset(&mut self, pixels: crate::scene::Pixels) {
        self.requested.remove(&pixels.key);
        self.assets.insert(pixels.key.clone(), pixels);
        while self.assets.values().map(|p| p.rgba.len()).sum::<usize>() > self.limits.storage_bytes() as usize {
            let stale = self.assets.keys().find(|key| self.scene.as_ref().is_none_or(|scene| !scene.images.iter().any(|image| &image.asset == *key))).cloned();
            if let Some(key) = stale { self.assets.remove(&key); } else { break }
        }
    }
    pub fn new(vt: &mut Terminal<'_, '_>) -> Result<Self> {
        Self::new_with_cells(vt, CELL)
    }

    pub fn new_with_cells(vt: &mut Terminal<'_, '_>, cell: (u32, u32)) -> Result<Self> {
        Self::new_with_limits(vt, cell, Default::default())
    }

    pub fn new_with_limits(
        vt: &mut Terminal<'_, '_>,
        cell: (u32, u32),
        limits: graffitty_terminal_core::TerminalLimits,
    ) -> Result<Self> {
        images::configure_with_limits(vt, limits).map_err(|error| anyhow!(error.to_string()))?;
        // The server resolves external uploads and sends pixels. A remote peer
        // can never ask this frontend to reopen a server-side path or SHM name.
        vt.set_kitty_image_from_file_allowed(false)?;
        vt.set_kitty_image_temp_file_dir(None)?;
        vt.set_kitty_image_from_shared_mem_allowed(false)?;
        let mut mirror = Self {
            limits,
            ..Self::default()
        };
        mirror.set_cell_size(vt, cell)?;
        Ok(mirror)
    }

    pub fn cell_size(&self) -> (u32, u32) {
        self.cell
    }

    pub fn limits(&self) -> graffitty_terminal_core::TerminalLimits {
        self.limits
    }

    pub fn set_cell_size(&mut self, vt: &mut Terminal<'_, '_>, cell: (u32, u32)) -> Result<()> {
        ensure!(
            (1..=256).contains(&cell.0) && (1..=256).contains(&cell.1),
            "Invalid terminal image cell size"
        );
        vt.resize(vt.cols()?, vt.rows()?, cell.0, cell.1)?;
        self.cell = cell;
        Ok(())
    }

    pub fn feed(&mut self, vt: &mut Terminal<'_, '_>, bytes: &[u8]) {
        self.feed_with_events(vt, bytes, |_| {});
    }

    pub fn feed_with_events(
        &mut self,
        vt: &mut Terminal<'_, '_>,
        bytes: &[u8],
        mut effect: impl FnMut(&Event),
    ) {
        let mut offset = 0;
        let inline = &mut self.inline;
        let cell = self.cell;
        let limits = self.limits;
        self.observer.feed_each(bytes, |end, event| {
            vt.vt_write(&bytes[offset..end]);
            offset = end;
            effect(&event);
            match event {
                Event::Erase { command, count } => inline_images::erase(vt, command, count),
                Event::Sixel(data) => {
                    if let Some((png, width, height)) = inline_images::sixel(&data) {
                        inline_images::place(vt, &png, width, height, cell);
                    }
                }
                Event::ItermImage(packet) => inline.iterm(&packet, vt, cell, images::inline_decode),
                Event::Reset => {
                    *inline = Default::default();
                    images::apply_policy(vt, limits, false)
                        .expect("Validated mirror image policy must survive terminal reset");
                }
                _ => {}
            }
        });
        vt.vt_write(&bytes[offset..]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fragmented_and_coalesced_preview_erasure() {
        let stream = b"\x1b[3;4H\x1bP0;1q\"1;1;2;6#1;2;100;0;0!2~\x1b\\";
        let erase = b"\x1b[3;1H\x1b[2K";
        for split in 0..=erase.len() {
            let mut vt = graffitty_terminal_core::new_vt(20, 10, 10).unwrap();
            let mut mirror = ImageMirror::new_with_cells(&mut vt, (10, 20)).unwrap();
            mirror.feed(&mut vt, stream);
            assert_eq!(
                graffitty_terminal_core::image_render::placements(&vt, (10., 20.))
                    .unwrap()
                    .len(),
                1
            );
            let mut batch = b"\x1b[22;0t".repeat(80);
            batch.extend_from_slice(&erase[..split]);
            mirror.feed(&mut vt, &batch);
            mirror.feed(&mut vt, &erase[split..]);
            assert!(
                graffitty_terminal_core::image_render::placements(&vt, (10., 20.))
                    .unwrap()
                    .is_empty()
            );
        }
    }
}
