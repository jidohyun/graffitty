//! A frontend's VT replica. Query responses belong exclusively to the server.
use crate::{effects, images::ImageMirror, tools};
use anyhow::{Result, anyhow, ensure};
use graffitty_terminal_core::{
    TerminalLimits,
    progress::Progress,
    screen,
    vt::{
        Terminal, render::{CursorVisualStyle, RenderState},
        selection::gesture::Gesture,
        terminal::ScrollViewport,
    },
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Update {
    pub columns: u16,
    pub rows: u16,
    #[serde(default)]
    pub reset: bool,
    #[serde(default)]
    pub exited: bool,
    pub limits: TerminalLimits,
}

/// Owner output that arrived while copy mode froze the screen.
enum Held {
    Stream(Update, Vec<u8>),
    Scene(crate::scene::Commit),
}

/// Godot's HELD_LIMIT: past this, held output applies even while frozen.
const HELD_LIMIT: usize = 64 * 1024 * 1024;

pub struct Mirror {
    // Tracked references must be retired before the VT they belong to.
    pub tools: tools::Controller,
    held: Vec<Held>,
    held_bytes: usize,
    pub selection_gesture: Option<Gesture<'static>>,
    pub vt: Terminal<'static, 'static>,
    pub images: ImageMirror,
    pub events: effects::Events,
    pub progress: Progress,
    pub columns: u16,
    pub rows: u16,
    pub limits: TerminalLimits,
    pub scroll: f32,
    pub revision: u64,
    pub exited: bool,
    cell: (u32, u32),
}

impl Mirror {
    /// Copy mode reads a still screen, as tmux copy mode does: owner output
    /// waits, then applies in order on refresh (`r`) or exit.
    fn hold(&mut self, update: Held) -> Result<bool> {
        self.held_bytes += 256
            + match &update {
                Held::Stream(_, bytes) => bytes.len(),
                Held::Scene(commit) => {
                    commit.text.len() + if commit.terminal.is_some() { 1 << 20 } else { 0 }
                }
            };
        self.held.push(update);
        self.tools.held_output = true;
        self.revision = self.revision.wrapping_add(1);
        if self.held_bytes > HELD_LIMIT {
            return self.catch_up_now();
        }
        Ok(false)
    }

    /// Apply held output once copy mode closed or asked for a refresh.
    /// Returns true when the caller must reapply its frontend appearance.
    pub fn catch_up(&mut self) -> Result<bool> {
        let refresh = self.tools.take_refresh();
        if self.held.is_empty() || (self.tools.frozen() && !refresh) {
            self.tools.held_output = !self.held.is_empty();
            return Ok(false);
        }
        self.catch_up_now()
    }

    fn catch_up_now(&mut self) -> Result<bool> {
        self.vt.scroll_viewport(ScrollViewport::Bottom);
        let mut reset = false;
        let held = std::mem::take(&mut self.held);
        self.held_bytes = 0;
        self.tools.held_output = false;
        for update in held {
            reset |= match update {
                Held::Stream(update, bytes) => self.apply_now(&update, &bytes)?,
                Held::Scene(commit) => self.apply_scene_now(commit)?,
            };
        }
        if self.tools.frozen() {
            // A refresh keeps copy mode open on the viewport it shows.
            self.vt.scroll_viewport(ScrollViewport::Bottom);
            self.vt
                .scroll_viewport(ScrollViewport::Delta(-(self.scroll.ceil() as isize)));
            self.tools.refresh_copy(&mut self.vt);
            let bar = self.vt.scrollbar()?;
            self.scroll = bar.total.saturating_sub(bar.len).saturating_sub(bar.offset) as f32;
            self.vt.scroll_viewport(ScrollViewport::Bottom);
        }
        self.revision = self.revision.wrapping_add(1);
        Ok(reset)
    }

    pub fn apply_scene(&mut self, commit: crate::scene::Commit) -> Result<bool> {
        if self.tools.frozen() {
            return self.hold(Held::Scene(commit));
        }
        let reset = self.catch_up()?;
        Ok(self.apply_scene_now(commit)? || reset)
    }

    fn apply_scene_now(&mut self, mut commit: crate::scene::Commit) -> Result<bool> {
        let reset = commit.terminal.is_some();
        if let Some(terminal) = commit.terminal.take() {
            self.tools.cancel();
            if let Some(mut gesture) = self.selection_gesture.take() { gesture.reset(&self.vt); }
            self.vt = terminal.adopt();
            self.events = effects::Events::attach(&mut self.vt)?;
        }
        if self.limits != commit.update.limits {
            self.images = ImageMirror::new_with_limits(&mut self.vt, self.cell, commit.update.limits)?;
            self.vt.set_kitty_image_storage_limit(0)?;
            self.limits = commit.update.limits;
        }
        self.columns = commit.update.columns;
        self.rows = commit.update.rows;
        self.exited = commit.update.exited;
        self.vt.resize(self.columns, self.rows, self.cell.0, self.cell.1)?;
        if let Some(graphics) = commit.graphics { self.images.scene = Some(graphics); }
        self.progress.feed(&commit.text);
        self.events.feed(&mut self.images, &mut self.vt, &commit.text);
        self.revision = self.revision.wrapping_add(1);
        Ok(reset)
    }
    pub fn new(columns: u16, rows: u16, cell: (u32, u32), limits: TerminalLimits) -> Result<Self> {
        let (vt, images, events) = Self::create(columns, rows, cell, limits)?;
        Ok(Self {
            tools: Default::default(),
            held: Vec::new(),
            held_bytes: 0,
            selection_gesture: None,
            vt,
            images,
            events,
            progress: Progress::new(),
            columns,
            rows,
            limits,
            scroll: 0.,
            revision: 0,
            exited: false,
            cell,
        })
    }

    fn create(
        columns: u16,
        rows: u16,
        cell: (u32, u32),
        limits: TerminalLimits,
    ) -> Result<(Terminal<'static, 'static>, ImageMirror, effects::Events)> {
        ensure!(
            columns > 0 && rows > 0,
            "Terminal grid dimensions must be nonzero"
        );
        limits.validate().map_err(anyhow::Error::msg)?;
        let mut vt = graffitty_terminal_core::new_vt(columns, rows, limits.scrollback_bytes as usize)?;
        let images = ImageMirror::new_with_limits(&mut vt, cell, limits)?;
        let events = effects::Events::attach(&mut vt)?;
        // Deliberately no on_pty_write, bell, or notification callback: replay
        // cannot answer the application's queries or deliver notifications twice.
        Ok((vt, images, events))
    }

    /// Replace VT state while retaining the viewer's scroll preference. Adapters
    /// may explicitly set scroll to zero for their own checkpoint UX policy.
    /// Callers must reapply their appearance defaults after a successful reset.
    pub fn reset(&mut self, columns: u16, rows: u16, limits: TerminalLimits) -> Result<()> {
        let (vt, images, events) = Self::create(columns, rows, self.cell, limits)?;
        self.tools.cancel();
        self.tools.held_output = !self.held.is_empty();
        if let Some(mut gesture) = self.selection_gesture.take() {
            gesture.reset(&self.vt);
        }
        self.vt = vt;
        self.images = images;
        self.events = events;
        self.progress = Progress::new();
        self.columns = columns;
        self.rows = rows;
        self.limits = limits;
        self.revision = self.revision.wrapping_add(1);
        Ok(())
    }

    pub fn cell_size(&self) -> (u32, u32) {
        self.cell
    }

    pub fn set_cell_size(&mut self, cell: (u32, u32)) -> Result<()> {
        self.images.set_cell_size(&mut self.vt, cell)?;
        self.cell = cell;
        self.revision = self.revision.wrapping_add(1);
        Ok(())
    }

    /// Returns true when the caller must reapply its frontend appearance.
    pub fn apply(&mut self, update: &Update, bytes: &[u8]) -> Result<bool> {
        ensure!(
            update.columns > 0 && update.rows > 0,
            "Terminal grid dimensions must be nonzero"
        );
        if self.tools.frozen() {
            return self.hold(Held::Stream(update.clone(), bytes.to_vec()));
        }
        let reset = self.catch_up()?;
        Ok(self.apply_now(update, bytes)? || reset)
    }

    fn apply_now(&mut self, update: &Update, bytes: &[u8]) -> Result<bool> {
        if update.reset {
            self.reset(
                update.columns,
                update.rows,
                update.limits,
            )?;
        } else if (update.columns, update.rows) != (self.columns, self.rows) {
            self.vt
                .resize(update.columns, update.rows, self.cell.0, self.cell.1)?;
        }
        self.progress.feed(bytes);
        self.events.feed(&mut self.images, &mut self.vt, bytes);
        self.columns = update.columns;
        self.rows = update.rows;
        self.exited = update.exited;
        self.revision = self.revision.wrapping_add(1);
        Ok(update.reset)
    }

    pub fn text(&self, scrollback: bool) -> Result<String> {
        graffitty_terminal_core::terminal_text::capture(&self.vt, self.columns, scrollback)
            .map_err(anyhow::Error::msg)
    }

    /// Snapshot the fractional viewport; glyph shaping and pixels stay outside.
    pub fn frame(&mut self, font_size: u16) -> Result<(screen::Frame, f32)> {
        let rows = f32::from(self.rows);
        self.frame_visible(font_size, rows)
    }

    /// Like `frame`, for a text area `visible_rows` cells tall: rows below the
    /// grid that the area's remainder or the scroll translation reveals are
    /// appended (see `extra_rows`).
    pub fn frame_visible(&mut self, font_size: u16, visible_rows: f32) -> Result<(screen::Frame, f32)> {
        self.scroll = self.scroll.clamp(0., self.vt.scrollback_rows()? as f32);
        self.vt.scroll_viewport(ScrollViewport::Bottom);
        self.vt
            .scroll_viewport(ScrollViewport::Delta(-(self.scroll.ceil() as isize)));
        let result = (|| {
            let mut frame = screen::snapshot(&self.vt, self.columns, self.rows, self.exited)
                .map_err(|e| anyhow!(e.to_string()))?;
            let mut state = RenderState::new()?;
            let view = state.update(&self.vt)?;
            if view.cursor_visual_style()? == CursorVisualStyle::BlockHollow {
                frame.cursor_style = 8 - u8::from(view.cursor_blinking()?);
            }
            frame.font_size = font_size;
            self.tools.decorate(&self.vt, &mut frame, self.rows);
            let fraction = self.scroll.ceil() - self.scroll;
            let extra = extra_rows(visible_rows, self.rows, self.scroll);
            if extra > 0 {
                self.vt.scroll_viewport(ScrollViewport::Delta(extra as isize));
                let next = screen::snapshot(&self.vt, self.columns, self.rows, self.exited)
                    .map_err(|e| anyhow!(e.to_string()))?;
                let skip = next.lines.len().saturating_sub(extra);
                frame.lines.extend(next.lines.into_iter().skip(skip));
            }
            Ok((frame, fraction))
        })();
        self.vt.scroll_viewport(ScrollViewport::Bottom);
        result
    }
}

/// Rows drawn below the grid (Godot terminal.rs `extra_rows`): the text area's
/// sub-row remainder plus the fractional scroll translation, limited to the
/// history rows below the viewport. A live bottom reveals nothing.
pub fn extra_rows(visible_rows: f32, rows: u16, scroll: f32) -> usize {
    let fraction = scroll.ceil() - scroll;
    ((visible_rows + fraction - f32::from(rows)).ceil().max(0.) as usize)
        .min(scroll.max(0.).ceil() as usize)
        .min(usize::from(rows))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extra_rows_cover_remainder_and_fraction_within_history() {
        assert_eq!(extra_rows(30., 30, 0.), 0);
        assert_eq!(extra_rows(30.7, 30, 0.), 0, "the live bottom has no rows below");
        assert_eq!(extra_rows(30.7, 30, 5.), 1);
        assert_eq!(extra_rows(30.7, 30, 4.5), 2, "remainder plus half a row");
        assert_eq!(extra_rows(30., 30, 4.25), 1);
        assert_eq!(extra_rows(30.7, 30, 0.5), 1, "limited to the history below");
    }

    #[test]
    fn coalesced_rich_clipboard_transfer_keeps_final_commit_after_64_packets() {
        use base64::{Engine as _, engine::general_purpose::STANDARD};
        use graffitty_terminal_core::clipboard_core::{Action, Transfer};
        let payload = vec![0xa5; 200 * 1024];
        let encoded = STANDARD.encode(&payload);
        let mut wire = b"before\r\n\x1b]5522;type=write\x1b\\".to_vec();
        for part in encoded.as_bytes().chunks(4096) {
            wire.extend_from_slice(b"\x1b]5522;type=wdata:mime=aW1hZ2UvcG5n;");
            wire.extend_from_slice(part);
            wire.extend_from_slice(b"\x1b\\");
        }
        wire.extend_from_slice(b"\x1b]5522;type=wdata\x1b\\after");
        // One coalesced IPC payload and arbitrary transport fragment boundaries
        // must complete the same transfer and leave surrounding terminal text.
        for chunk_size in [wire.len(), 37] {
            let mut mirror = Mirror::new(24, 4, (10, 22), Default::default()).unwrap();
            let update = Update {
                columns: 24,
                rows: 4,
                reset: false,
                exited: false,
                limits: Default::default(),
            };
            for part in wire.chunks(chunk_size) {
                mirror.apply(&update, part).unwrap();
            }
            let mut transfer = Transfer::default();
            let mut committed = None;
            for event in mirror.events.drain() {
                if let effects::Event::Rich(packet) = event {
                    if let Action::Write { data, .. } = transfer.feed(&packet, true, true) {
                        assert!(committed.replace(data).is_none(), "exactly one commit");
                    }
                }
            }
            assert_eq!(
                committed.expect("final commit must survive coalescing")["image/png"].as_slice(),
                payload
            );
            let text = mirror.text(false).unwrap();
            assert!(text.contains("before") && text.contains("after"));
        }
    }

    #[test]
    fn checkpoint_keeps_limits_retires_modal_refs_and_allows_fresh_output() {
        let limits = TerminalLimits {
            kitty_image_storage_mb: 0,
            ..Default::default()
        };
        let mut mirror = Mirror::new(24, 4, (10, 22), limits).unwrap();
        mirror.vt.vt_write(b"https://example.test\r\n");
        mirror
            .tools
            .start(&mut mirror.vt, "quick_select", "")
            .unwrap();
        assert!(mirror.tools.active());
        let epoch = mirror.events.epoch;
        let update = Update {
            columns: 24,
            rows: 4,
            reset: true,
            exited: false,
            limits,
        };
        mirror
            .apply(
                &update,
                b"\x1bc\x1b_Ga=T,f=24,s=1,v=1,i=7,q=2;/wAA\x1b\\AFTER",
            )
            .unwrap();
        assert!(!mirror.tools.active());
        assert_ne!(mirror.events.epoch, epoch);
        assert_eq!(mirror.limits, limits);
        assert!(mirror.vt.kitty_graphics().unwrap().is_none_or(|graphics| graphics.image(7).is_none()));
        assert_ne!(mirror.vt.is_kitty_image_from_file_allowed().unwrap(), Some(true));
        assert!(mirror.text(true).unwrap().contains("AFTER"));
    }

    #[test]
    fn fractional_frame_is_a_view_and_preserves_retained_history() {
        let mut mirror = Mirror::new(24, 4, (10, 22), Default::default()).unwrap();
        let update = Update {
            columns: 24,
            rows: 4,
            reset: false,
            exited: false,
            limits: Default::default(),
        };
        mirror
            .apply(&update, b"one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix")
            .unwrap();
        let text = mirror.text(true).unwrap();
        mirror.scroll = 1.5;
        let (frame, fraction) = mirror.frame(16).unwrap();
        assert_eq!(fraction, 0.5);
        assert_eq!(frame.lines.len(), 5);
        assert_eq!(mirror.text(true).unwrap(), text);
        let scrollbar = mirror.vt.scrollbar().unwrap();
        assert_eq!(scrollbar.offset, scrollbar.total - scrollbar.len);
    }

    #[test]
    fn copy_mode_freezes_output_until_refresh_or_exit() {
        let mut mirror = Mirror::new(24, 4, (10, 22), Default::default()).unwrap();
        let update = Update {
            columns: 24,
            rows: 4,
            reset: false,
            exited: false,
            limits: Default::default(),
        };
        mirror.apply(&update, b"BEFORE\r\n").unwrap();
        mirror.tools.start(&mut mirror.vt, "copy_mode", "").unwrap();
        mirror.vt.scroll_viewport(ScrollViewport::Bottom);
        mirror.apply(&update, b"DURING\r\n").unwrap();
        assert!(!mirror.text(true).unwrap().contains("DURING"), "Copy mode holds owner output");
        assert!(mirror.tools.status().ends_with("[frozen: new output, r refreshes]"));
        assert_eq!(mirror.tools.snapshot()["copy"]["held_output"], true);
        let key = |mirror: &mut Mirror, key: &str| {
            mirror
                .tools
                .key(&mut mirror.vt, &serde_json::json!({"action":"key","key":key}))
                .unwrap();
            mirror.vt.scroll_viewport(ScrollViewport::Bottom);
            mirror.catch_up().unwrap();
        };
        key(&mut mirror, "r");
        assert!(mirror.text(true).unwrap().contains("DURING"), "r applies held output");
        assert_eq!(mirror.tools.mode(), Some("copy_mode"), "r keeps copy mode open");
        mirror.apply(&update, b"FIRST ").unwrap();
        mirror.apply(&update, b"SECOND\r\n").unwrap();
        assert!(!mirror.text(true).unwrap().contains("FIRST"));
        key(&mut mirror, "Escape");
        assert!(!mirror.tools.active());
        assert!(mirror.text(true).unwrap().contains("FIRST SECOND"), "Held output applies in order on exit");
        assert!(!mirror.tools.status().contains("frozen"));
    }
}
