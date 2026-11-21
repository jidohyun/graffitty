use graffitty_terminal_core::vt as libghostty_vt;
use graffitty_terminal_core::copy_mode::{
    CopyMode, Effect as CopyEffect, Input as CopyInput, Key as CopyKey,
};
use base64::Engine as _;
use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;

use godot::classes::control::FocusMode;
use godot::classes::display_server::Feature as DisplayFeature;
use godot::classes::notify::ControlNotification;
use godot::classes::object::ConnectFlags;
use std::collections::HashMap;

use godot::classes::file_access::CompressionMode;
use godot::classes::image::Format as GdImageFormat;
use godot::classes::{
    Control, DisplayServer, EditorInterface, Engine, IControl, Image as GdImage, ImageTexture,
    Input as GdInput, InputEvent, InputEventKey, InputEventMouse, InputEventMouseButton,
    InputEventMouseMotion, InputEventPanGesture, Os, ProjectSettings, RenderingServer,
};
use godot::global::{Error as GdError, Key as GKey, MouseButton, MouseButtonMask};
use godot::prelude::*;
use libghostty_vt::alloc::{Allocator as VtAllocator, Bytes as VtBytes};
use libghostty_vt::key::Mods as VtMods;
use libghostty_vt::kitty::graphics as kgfx;
use libghostty_vt::render::{CellIterator, CursorVisualStyle, RenderState, RowIterator};
use libghostty_vt::screen::{CellWide, Screen};
use libghostty_vt::fmt::Formatter;
use libghostty_vt::style::{Palette as VtPalette, RgbColor, StyleColor, Underline};
use libghostty_vt::terminal::{
    ColorScheme, ConformanceLevel, DeviceAttributeFeature, DeviceAttributes, DeviceType, Mode,
    PrimaryDeviceAttributes, ScrollViewport, SecondaryDeviceAttributes, SizeReportSize,
};
use libghostty_vt::{
    Error as VtError, Terminal as Vt, build_info, focus, mouse, paste,
};
use unicode_width::UnicodeWidthChar;

use crate::font::Fonts;
use crate::elastic_gesture::{PAN_TO_PIXELS, PanPhases, clock};
use crate::scroll::{ElasticConfig, ElasticGesture, PIXELS_PER_ROW, ScrollGesture, Scroller};
use crate::input::{Input, MouseGeometry, event_mods, typing_unicode};
use crate::plugin;
use crate::pty::{Drained, Pty, Writer};
use crate::run::{PixelGrid, Run, RunCache};
use crate::terminal_snapshot::{Painter, Presentation, TerminalRenderSnapshot};
use crate::theme::{self, Theme};

const DEFAULT_PAD: f32 = 4.0;

/// What a theme may change about the cell box. The font decides the glyph; these
/// decide the room around it, which is what makes a terminal look tight or airy.
#[derive(Clone, Copy)]
struct CellMetrics {
    /// Inset from the control's edge to the grid, in pixels.
    pad: f32,
    /// Multipliers on the measured line box and advance (kitty's
    /// adjust_line_height / adjust_column_width, as factors rather than deltas).
    line_height: f32,
    column_width: f32,
}

impl Default for CellMetrics {
    fn default() -> Self {
        Self {
            pad: DEFAULT_PAD,
            line_height: 1.0,
            column_width: 1.0,
        }
    }
}
const SCROLL_LINES: f64 = 3.0;
/// Parse pty output every frame, but re-record the grid at most this often.
const REPAINT_MIN_SECS: f64 = 1.0 / 60.0;
/// Codepoints drawn per cell; extra combining marks would just overlap.
const GLYPHS_PER_CELL: usize = 8;
/// Apply reflow and SIGWINCH once the size has stopped changing to avoid
/// spam-drawing the prompt and messing up the scrollback during resize.
const RESIZE_SETTLE_SECS: f64 = 0.1;
const MAX_SCROLLBACK: u32 = 100_000;
/// Selection autoscroll scrolls one row per tick.
const SELECTION_SCROLL_SECS: f64 = 0.015;
#[derive(GodotClass)]
#[class(tool, base = Control)]
pub struct Terminal {
    base: Base<Control>,
    #[export]
    pub(crate) font_size: i32,
    /// Use the normal renderer/input/IME without spawning a local shell.
    #[var]
    remote_mode: bool,
    remote_shell_pid: i64,
    /// Presentation visibility is independent of the Control's canvas ancestry.
    /// An inactive SubViewport does not make its children invisible to Godot.
    #[var(get = is_render_active, set = set_render_active)]
    render_active: bool,
    render_snapshot_ready: bool,
    awaiting_remote_scene: bool,
    render_image_budget: usize,
    pending_server_font: Option<GString>,
    /// When true, only explicit bindings activate terminal actions.
    #[var]
    use_custom_key_bindings: bool,
    /// Godot keycode-with-modifiers -> action name. An empty map unbinds all.
    #[var]
    key_bindings: VarDictionary,
    /// Keycode-with-modifiers -> required terminal state ("prompt",
    /// "alt_screen", or either negated with "!"). While it does not hold,
    /// the key binding is skipped and the key reaches the program.
    #[var]
    key_binding_conditions: VarDictionary,
    #[export]
    ligatures: bool,
    #[export]
    scrollback: u32,
    /// Command to run; empty means $SHELL.
    #[export]
    pub(crate) shell: GString,
    /// Host-provided per-PTY context, never process-global environment mutation.
    #[var]
    environment: VarDictionary,
    /// Where the shell starts; empty means project root, then $HOME.
    #[export]
    working_directory: GString,
    /// Spawn as a login shell so profiles rebuild the environment.
    /// Passes -l, so turn this off when shell is not a shell.
    #[export]
    login_shell: bool,
    #[export]
    shell_integration: bool,
    #[export]
    clipboard_write: bool,
    #[export(enum = (Deny, Ask, Allow))]
    clipboard_read: i32,
    #[export]
    open_hyperlinks: bool,
    /// Remote clients must not interpret server file paths on this device.
    #[var]
    web_only_hyperlinks: bool,
    /// Hosts that project this Control can show its tooltip in window space.
    #[export]
    show_hyperlink_tooltip: bool,
    /// Auto follows the editor theme (or the OS dark mode in games).
    #[export(enum = (Auto, Dark, Light))]
    color_scheme: i32,
    /// Run inside the editor too, like a tool script. Ignored in games.
    /// Off keeps terminals in edited scenes inert.
    #[export]
    pub(crate) run_in_editor: bool,
    /// How opaque the terminal's own background is, 0..1.
    ///
    /// It applies to the DEFAULT background only — a cell that asked for a
    /// colour keeps it at full strength, which is what kitty's
    /// background_opacity and Ghostty's background-opacity do.
    ///
    /// 0 leaves whatever is behind the terminal showing through, which is the
    /// point when the terminal is painted onto a world.
    #[export(range = (0.0, 1.0, 0.01))]
    background_opacity: f32,
    /// Room between the control's edge and the grid, in pixels.
    #[export(range = (0.0, 64.0, 0.5))]
    cell_padding: f32,
    /// Multipliers on the font's own line box and advance, for a theme that
    /// wants airier or tighter text than the face was cut for.
    #[export(range = (0.5, 3.0, 0.01))]
    line_height: f32,
    #[export(range = (0.5, 3.0, 0.01))]
    column_width: f32,
    /// Selection colours. Purple background with the cell's own foreground by
    /// default; both fully transparent swap the cell's foreground and background.
    #[export]
    selection_bg: Color,
    #[export]
    selection_fg: Color,
    /// Auto follows the application's own DECSCUSR, which is what a terminal
    /// should do; the rest override it.
    #[export(enum = (Auto, Block, Bar, Underline, Hollow))]
    #[var(get = get_terminal_cursor_shape, set = set_live_cursor_shape)]
    cursor_shape: i32,
    /// Megabytes of images the Kitty graphics protocol may store. **Zero
    /// disables the protocol**, which is the library's default: a vt does not
    /// budget memory for images until its embedder says how much.
    ///
    /// It is a ceiling, not an allocation — nothing is reserved. The default is
    /// Ghostty's own `image-storage-limit`, which counts in decimal megabytes:
    /// 320 * 1000 * 1000.
    #[export(range = (0.0, 4096.0, 1.0))]
    kitty_image_storage_mb: i32,
    /// Mebibytes one Kitty graphics transmission may buffer. A chunked image
    /// accumulates here before it is decoded.
    ///
    /// The library's own default is far smaller than the app's: measured
    /// here, a 288 KB base64 payload arrives and a 501 KB one never appears,
    /// **with no error** — which is every screenshot.
    ///
    /// Ghostty the application sets 65 MiB (`terminal/apc.zig`, "Kitty
    /// graphics payloads can be very large"), so that is what this uses.
    #[export(range = (0.0, 512.0, 1.0))]
    kitty_apc_max_mb: i32,
    /// Font files for regular, bold, italic and bold-italic, in that order.
    /// Empty uses the bundled JetBrains Mono chain; fewer than four reuses
    /// the first face for the missing styles.
    ///
    /// The bundled fallbacks (emoji, CJK, system) stay behind whatever is
    /// given here.
    #[export(file = "*.ttf,*.otf,*.woff2")]
    font_paths: PackedStringArray,
    /// Installed family name. Explicit font_paths take precedence.
    #[export]
    font_family: GString,
    /// Ordered installed families, after primary styles and before built-in fallback.
    #[export]
    font_fallbacks: PackedStringArray,
    advanced_options: crate::options::Options,
    keyboard: crate::bindings::Keyboard,
    /// Window-space point for the platform IME's candidate window, when the
    /// host computes it.
    ///
    /// A terminal drawn into a SubViewport and projected onto 3D geometry has
    /// no meaningful global_position, so the point this control would work
    /// out for itself lands somewhere else on screen entirely.
    ime_anchor: Option<Vector2i>,
    /// Colours the host set outright. An editor or OS theme change must not
    /// overwrite them, so refresh_theme() steps aside while this is set.
    explicit_theme: Option<Theme>,
    /// What ready() resolved, so respawn() can repeat it.
    spawn: Option<Spawn>,
    state: Option<State>,
    /// The platform input method is off while copy mode reads keys as Vim
    /// commands, so Hangul mode cannot compose them; its prompt turns it on.
    ime_suppressed: bool,
}

#[godot_api]
impl Terminal {
    #[signal]
    fn input_ready();

    #[signal]
    fn colors_changed();

    /// Resolved host defaults only; never publish the application's OSC overrides.
    #[func]
    fn remote_theme(&self) -> VarDictionary {
        let theme = self.explicit_theme.clone()
            .or_else(|| self.state.as_ref().map(|st| st.theme.clone()))
            .unwrap_or_else(|| theme::resolve(self.in_editor(), self.scheme_pref()));
        // Keep integer RGB channels across Godot's boundary. Parsing a JSON
        // string in GDScript would turn them into floats and break the wire schema.
        crate::graph_client::to_variant(&serde_json::to_value(theme.query_defaults()).unwrap()).to()
    }

    #[func]
    fn is_render_active(&self) -> bool { self.render_active }

    /// Captures need a painted scene, not merely an allocated viewport or VT.
    #[func]
    fn is_render_snapshot_ready(&self) -> bool {
        self.render_active && self.render_snapshot_ready
            && self.state.as_ref().is_some_and(|st| !st.needs_paint && st.scene_requested.is_empty())
    }

    /// Freeze resolved drawing state with independent font/image ownership.
    /// The returned presentation has no shell, input, timers or live VT state.
    #[func]
    fn capture_render_state(&mut self) -> Option<Gd<TerminalRenderSnapshot>> {
        let size = self.base().get_size();
        let position = self.base().get_position();
        let state = self.state.as_mut()?;
        match state.paint(size, true) {
            Ok((_, Some(presentation))) => Some(TerminalRenderSnapshot::new(presentation, size, position)),
            Ok((_, None)) => None,
            Err(error) => { godot_error!("Terminal presentation snapshot: {error}"); None }
        }
    }

    /// A new subscription replaces a hidden pane's retained (possibly stale) scene.
    #[func]
    fn remote_expect_scene(&mut self) {
        self.awaiting_remote_scene = true;
        self.render_snapshot_ready = false;
    }

    #[func]
    fn set_render_active(&mut self, active: bool) {
        if self.render_active == active { return; }
        self.render_active = active;
        self.render_snapshot_ready = false;
        self.base_mut().set_process(active);
        if active && self.state.is_none() && self.base().is_node_ready() {
            self.ready();
        }
        if active {
            if let Some(font) = self.pending_server_font.take() { self.apply_server_font(font); }
            self.base_mut().queue_redraw();
        }
        if !active {
            self.clear_preedit();
            self.sync_terminal_key_focus(false);
        }
        if let Some(st) = self.state.as_mut() {
            // Keep the latest VT state dirty, but prepare pixels only on return.
            st.needs_paint = true;
            st.since_repaint = REPAINT_MIN_SECS;
            if !active {
                st.selecting = false;
                st.hover_position = None;
                st.hover_link = None;
            }
        }
    }

    /// Release GPU resources only after outgoing transition captures have drawn.
    #[func]
    fn release_render_resources(&mut self) {
        if self.render_active { return; }
        self.render_snapshot_ready = false;
        let Some(st) = self.state.as_mut() else { return };
        st.scene_pixels.clear();
        st.scene_textures.clear();
        st.scene_requested.clear();
        st.kitty_images.clear();
        st.runs = RunCache::new();
        let mut rs = RenderingServer::singleton();
        for canvas in [st.canvas_bg, st.canvas_fg, st.canvas_quick, st.canvas_img_below, st.canvas_img_above] {
            rs.canvas_item_clear(canvas);
        }
        st.needs_paint = true;
    }

    #[func]
    fn set_render_image_budget(&mut self, bytes: i64) {
        self.render_image_budget = bytes.max(0) as usize;
        if let Some(st) = self.state.as_mut() {
            st.scene_budget = self.render_image_budget;
            st.trim_scene_textures();
        }
    }

    #[func]
    fn remote_set_asset_texture(&mut self, key: GString, texture: Gd<godot::classes::Texture2D>, width: i64, height: i64) {
        if !self.render_active { return; }
        let Some(st) = self.state.as_mut() else { return };
        if width <= 0 || height <= 0 || width > 8192 || height > 8192 || width as usize * height as usize * 4 > st.scene_budget { return }
        let key = graffitty_protocol::terminal_scene::AssetKey(key.to_string());
        st.scene_requested.remove(&key);
        st.scene_pixels.remove(&key);
        st.scene_textures.insert(key, (texture, width as usize * height as usize * 4, st.remote_revision));
        st.scene_imports += 1;
        st.trim_scene_textures();
        st.needs_paint = true;
        self.render_snapshot_ready = false;
    }
    #[func]
    fn remote_image_stats(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        if let Some(st) = &self.state {
            out.set("textures", st.scene_textures.len() as i64);
            out.set("bytes", st.scene_textures.values().map(|(_, bytes, _)| *bytes).sum::<usize>() as i64);
            out.set("budget", st.scene_budget as i64);
            out.set("uploads", st.scene_uploads as i64);
            out.set("imports", st.scene_imports as i64);
            out.set("pending", st.scene_requested.len() as i64);
        }
        out
    }
    #[func]
    fn remote_apply_scene(&mut self, mut update: Gd<crate::terminal_scene::TerminalSceneUpdate>) {
        // A subscribed pane can receive its only snapshot before it becomes
        // visible. Initialize its replica now; painting and processing remain
        // disabled until activation.
        //
        // Dropping this commit also loses the base for subsequent deltas,
        // leaving an idle pane blank after reconnect.
        if self.state.is_none() && self.base().is_node_ready() {
            self.initialize_state();
        }
        let Some(st) = self.state.as_mut().filter(|st| st.pty.is_remote()) else { return };
        let mut update = update.bind_mut();
        if let Some(pixels) = update.pixels.take() {
            st.scene_requested.remove(&pixels.key);
            if self.render_active && pixels.rgba.len() <= st.scene_budget {
                st.scene_pixels.insert(pixels.key.clone(), pixels);
                st.trim_scene_textures();
                st.needs_paint = true;
                self.render_snapshot_ready = false;
            }
        }
        let Some(commit) = update.commit.take() else { return };
        if st.holds() {
            st.hold(Held::Scene(commit));
        } else {
            self.apply_scene(commit);
        }
    }

    #[func]
    fn remote_take_asset_requests(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        if !self.render_active { return out; }
        let Some(st) = self.state.as_mut() else { return out };
        let Some(scene) = &st.scene_graphics else { return out };
        let visible = graffitty_terminal_core::image_render::scene_placements(&st.vt, scene, (st.geo.cell_w, st.geo.cell_h)).unwrap_or_default();
        let mut remaining = st.scene_budget;
        let mut wanted = std::collections::HashSet::new();
        for image in &scene.images {
            if !visible.iter().any(|p| p.image_id == image.id) { continue; }
            let bytes = (image.width as usize).saturating_mul(image.height as usize).saturating_mul(4);
            if bytes > remaining { continue; }
            if !wanted.insert(image.asset.clone()) { continue; }
            remaining -= bytes;
            if st.scene_textures.contains_key(&image.asset) || st.scene_pixels.contains_key(&image.asset) { continue }
            let now = std::time::Instant::now();
            if st.scene_requested.get(&image.asset).is_some_and(|at| now.duration_since(*at).as_secs() < 10) { continue }
            st.scene_requested.insert(image.asset.clone(), now);
            out.push(&GString::from(image.asset.0.as_str()));
        }
        // Reserve space for visible assets first, then retain recently used
        // resident assets within the remaining budget.
        //
        // Scene snapshots only include placed images: absence does not mean
        // the owner forgot the content-addressed asset or cannot place it
        // again later.
        let mut retained = wanted.clone();
        let mut resident: Vec<_> = st.scene_textures.iter()
            .map(|(key, (_, bytes, revision))| (key.clone(), *bytes, *revision))
            .chain(st.scene_pixels.iter().map(|(key, pixels)| (key.clone(), pixels.rgba.len(), st.remote_revision)))
            .collect();
        resident.sort_unstable_by_key(|(_, _, revision)| std::cmp::Reverse(*revision));
        for (key, bytes, _) in resident {
            if retained.contains(&key) { continue; }
            if bytes <= remaining {
                remaining -= bytes;
                retained.insert(key);
            }
        }
        st.scene_pixels.retain(|key, _| retained.contains(key));
        st.scene_requested.retain(|key, _| wanted.contains(key));
        let previous = st.scene_textures.len();
        st.scene_textures.retain(|key, _| retained.contains(key));
        st.needs_paint |= previous != st.scene_textures.len();
        out
    }
    #[func]
    fn get_text(&self, scrollback: bool) -> VarDictionary {
        let mut result = VarDictionary::new();
        let text = self
            .state
            .as_ref()
            .ok_or_else(|| "Terminal is not ready".to_owned())
            .and_then(|st| crate::terminal_text::capture(&st.vt, st.geo.cols, scrollback));
        match text {
            Ok(text) => result.set("text", &GString::from(text.as_str())),
            Err(error) => result.set("error", &GString::from(error.as_str())),
        }
        result
    }

    /// Authenticated remote views render cells locally. No pixels or terminal
    /// escape sequences leave this API, and observers never answer VT queries.
    #[func]
    fn remote_snapshot(&mut self) -> VarDictionary {
        let mut out = VarDictionary::new();
        let Some(st) = self.state.as_mut() else {
            return out;
        };
        let Ok(snapshot) = st.render_state.update(&st.vt) else {
            return out;
        };
        let Ok(colors) = snapshot.colors() else {
            return out;
        };
        let hex =
            |c: RgbColor| GString::from(format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b).as_str());
        out.set("columns", i64::from(st.geo.cols));
        out.set("rows", i64::from(st.geo.rows));
        out.set("foreground", &hex(colors.foreground));
        out.set("background", &hex(colors.background));
        out.set("title", &GString::from(st.title.as_str()));
        out.set("exited", st.exited);
        out.set("font_size", i64::from(st.base_pt));
        out.set("cell_width", f64::from(st.geo.cell_w));
        out.set("cell_height", f64::from(st.geo.cell_h));
        let mut modes = VarArray::new();
        for number in [
            1_u16, 9, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 2004,
        ] {
            if st
                .vt
                .mode(Mode::new(number, libghostty_vt::terminal::ModeKind::Dec))
                .unwrap_or(false)
            {
                modes.push(&i64::from(number).to_variant());
            }
        }
        out.set("input_modes", &modes);
        out.set(
            "kitty_keys",
            i64::from(st.vt.kitty_keyboard_flags().map(|f| f.bits()).unwrap_or(0)),
        );

        let mut cursor = VarArray::new();
        if snapshot.cursor_visible().unwrap_or(false) && !st.exited {
            if let Ok(Some(vp)) = snapshot.cursor_viewport() {
                cursor.push(&i64::from(vp.x.saturating_sub(vp.at_wide_tail as u16)).to_variant());
                cursor.push(&i64::from(vp.y).to_variant());
            }
        }
        out.set("cursor", &cursor);
        // DECSCUSR preserves the application's insert/command caret independently
        // of whether the server window currently has keyboard focus.
        let shape = match snapshot
            .cursor_visual_style()
            .unwrap_or(CursorVisualStyle::Block)
        {
            CursorVisualStyle::Bar => 6,
            CursorVisualStyle::Underline => 4,
            _ => 2,
        };
        let cursor_style = shape - i64::from(snapshot.cursor_blinking().unwrap_or(false));
        out.set("cursor_style", cursor_style);
        let mut rows = VarArray::new();
        let Ok(mut row_it) = st.rows.update(&snapshot) else {
            return out;
        };
        let mut graphemes: Vec<char> = Vec::new();
        while let Some(row) = row_it.next() {
            let mut cells = VarArray::new();
            let Ok(mut cell_it) = st.cells.update(row) else {
                break;
            };
            let mut col: i64 = 0;
            while let Some(cell) = cell_it.next() {
                let n = cell.graphemes_len().unwrap_or(0) as usize;
                let mut fg = cell.fg_color().ok().flatten().unwrap_or(colors.foreground);
                let mut bg = cell.bg_color().ok().flatten().unwrap_or(colors.background);
                let mut bits: i64 = 0;
                let mut invisible = false;
                if let Ok(style) = cell.style() {
                    if style.inverse {
                        std::mem::swap(&mut fg, &mut bg);
                    }
                    invisible = style.invisible;
                    for (on, bit) in [
                        (style.bold, 1),
                        (style.italic, 2),
                        (style.faint, 4),
                        (style.underline != Underline::None, 8),
                        (style.strikethrough, 16),
                    ] {
                        if on {
                            bits |= bit;
                        }
                    }
                }
                graphemes.resize(n, '\0');
                let text = if n > 0 && !invisible && cell.graphemes_buf(&mut graphemes).is_ok() {
                    graphemes.iter().collect::<String>()
                } else {
                    String::new()
                };
                let wide = matches!(cell.raw_cell().and_then(|c| c.wide()), Ok(CellWide::Wide));
                // Empty cells with colored backgrounds still carry visible state.
                if !text.is_empty() || hex(bg) != hex(colors.background) {
                    let mut entry = VarArray::new();
                    for value in [
                        col.to_variant(),
                        (if wide { 2_i64 } else { 1_i64 }).to_variant(),
                        GString::from(text.as_str()).to_variant(),
                        hex(fg).to_variant(),
                        hex(bg).to_variant(),
                        bits.to_variant(),
                    ] {
                        entry.push(&value);
                    }
                    cells.push(&entry.to_variant());
                }
                col += 1;
            }
            rows.push(&cells.to_variant());
        }
        out.set("lines", &rows);
        out
    }

    /// Apply a server-generated presentation stream, never run a local shell.
    #[func]
    fn remote_feed(&mut self, data: PackedByteArray, columns: i64, rows: i64) {
        let Some(st) = self.state.as_mut().filter(|st| st.pty.is_remote()) else {
            return;
        };
        if st.holds() {
            st.hold(Held::Presentation(data, columns, rows));
        } else {
            self.apply_presentation(data.as_slice(), columns, rows);
        }
    }

    /// Deliver the owner's independent bell event using this client's settings.
    #[func]
    fn remote_bell(&mut self) {
        if !self.render_active {
            if self.advanced_options.audible_bell { DisplayServer::singleton().beep(); }
            self.base_mut().call_deferred("emit_signal", &["bell".to_variant()]);
            return;
        }
        if let Some(st) = self.state.as_mut().filter(|st| st.pty.is_remote()) {
            st.bell.set(true);
        }
    }

    /// Authoritative PTY stream: local query replies must never reach the shell.
    #[func]
    fn remote_feed_stream(
        &mut self,
        data: PackedByteArray,
        columns: i64,
        rows: i64,
        reset: bool,
        exited: bool,
    ) {
        let Some(st) = self.state.as_mut().filter(|st| st.pty.is_remote()) else {
            return;
        };
        if st.holds() {
            st.hold(Held::Stream { data, columns, rows, reset, exited });
        } else {
            self.apply_stream(data.as_slice(), columns, rows, reset, exited);
        }
    }

    #[func]
    fn remote_revision(&self) -> i64 {
        self.state
            .as_ref()
            .map(|st| {
                let offset = st.vt.scrollbar().map(|s| s.offset as u64).unwrap_or(0);
                (st.remote_revision.wrapping_add(offset << 32)) as i64
            })
            .unwrap_or(0)
    }

    #[func]
    fn remote_take_input(&mut self) -> PackedByteArray {
        let Some(st) = self.state.as_mut() else { return PackedByteArray::new(); };
        let data = if st.attachment_busy {
            std::mem::take(&mut st.attachment_prefix)
        } else { st.writer.take_remote() };
        let waiting = !data.is_empty() && st.writer.waiting();
        if waiting { self.poll_input_delivery(); }
        PackedByteArray::from(data.as_slice())
    }

    #[func]
    fn poll_input_delivery(&mut self) {
        let Some(st) = self.state.as_ref() else { return; };
        st.writer.poll();
        let remaining = st.writer.remaining();
        if let Some(remaining) = remaining {
            // Runs even for hidden nodes. Recheck the monotonic deadline:
            // SceneTree can count part of the frame in which a timer starts.
            let callback = self.to_gd().callable("poll_input_delivery");
            let mut timer = self.base().get_tree()
                .create_timer_ex(remaining.as_secs_f64().max(0.001))
                .ignore_time_scale(true).done();
            timer.connect("timeout", &callback);
        }
    }

    #[func]
    fn remote_discard_input(&mut self) {
        if let Some(st) = self.state.as_mut() {
            st.writer.take_all();
            st.attachment_prefix.clear();
        }
    }

    #[func]
    fn remote_take_attachment(&mut self) -> VarDictionary {
        let mut result = VarDictionary::new();
        if let Some(st) = self.state.as_mut() {
            if let Some(file) = st.attachment.take() {
                match file {
                    Ok(file) => { result.set("name", file.name.as_str()); result.set("data", &PackedByteArray::from(file.bytes.as_slice())); },
                    Err(error) => { result.set("error", error.as_str()); },
                }
            }
        }
        result
    }

    #[func]
    fn file_paste_finished(&mut self, success: bool) {
        if let Some(st) = self.state.as_mut() {
            st.attachment_busy = false;
            // Keep Enter/typing ordered after the image. A failed upload must
            // never submit a draft with its attachment missing or replay input.
            if !success { st.writer.take_all(); }
            st.writer.notify();
        }
    }

    /// Native IME image content uses the same Rust validation and upload path.
    #[func]
    fn paste_image_base64(&mut self, data: GString) {
        use base64::Engine as _;
        let Some(st) = self.state.as_mut().filter(|s| !s.exited && !s.attachment_busy) else { return; };
        let data = data.to_string();
        let result = (|| -> anyhow::Result<_> {
            anyhow::ensure!(data.len() <= graffitty_protocol::file_transfer::MAX_BYTES.div_ceil(3) * 4, "Image is too large");
            let bytes = base64::engine::general_purpose::STANDARD.decode(data)?;
            graffitty_client_core::clipboard_paste::Attachment::image(bytes)
        })();
        st.queue_attachment(result);
    }

    #[func]
    fn paste_file(&mut self, path: GString) {
        let Some(st) = self.state.as_mut().filter(|s| !s.exited && !s.attachment_busy) else { return; };
        st.queue_attachment(graffitty_client_core::clipboard_paste::Attachment::file(std::path::Path::new(&path.to_string())));
    }

    #[func]
    fn remote_write_input(&mut self, data: PackedByteArray) {
        if let Some(st) = self
            .state
            .as_mut()
            .filter(|st| !st.exited && !st.pty.is_remote())
        {
            st.writer.write(data.as_slice());
        }
    }

    /// Encode a key event without taking desktop focus or dispatching desktop
    /// shortcuts. Arrows never trigger typing effects; other navigation can
    /// opt out of impulses and particles with `effects`.
    #[func]
    fn send_key(&mut self, key: Gd<InputEventKey>, #[opt(default = true)] effects: bool) -> bool {
        let Some(st) = self.state.as_mut() else {
            return false;
        };
        // An open overlay owns keys from every route (Android key bar, prefix
        // pass-through), and a frozen replica's modes may be stale for encoding.
        if st.frozen()
            && (st.modal_key(&key)
                || st.navigation_key(&key, false)
                || st.quick_select_key(&key, false))
        {
            return true;
        }
        // So does the release of a press that closed the overlay.
        if !key.is_pressed() && st.quick_keys.remove(&key.get_keycode().ord()) {
            return true;
        }
        if st.exited {
            return false;
        }
        let bytes = st.input.encode_key(&st.vt, &key, false);
        if !bytes.is_empty() {
            st.writer.write_key(bytes, cfg!(target_os = "macos") && key.is_pressed()
                && key.get_keycode() == GKey::NONE && key.get_physical_keycode() == GKey::NONE
                && key.get_unicode() >= 32);
            st.needs_paint = true;
            if self.render_active && effects && let Some(unicode) = typing_unicode(&key) {
                let cell = Vector2i::new(i32::from(st.cursor_cell.0), i32::from(st.cursor_cell.1));
                self.base_mut().call_deferred("emit_signal", &[
                    "keystroke".to_variant(), cell.to_variant(), unicode.to_variant(),
                ]);
            }
        }
        true
    }

    #[func]
    fn grid_pixel_size(&self, columns: i64, rows: i64) -> Vector2 {
        let Some(st) = self.state.as_ref() else {
            return Vector2::ZERO;
        };
        Vector2::new(
            columns.clamp(1, 500) as f32 * st.geo.cell_w + 2.0 * st.geo.pad,
            rows.clamp(1, 300) as f32 * st.geo.cell_h + 2.0 * st.geo.pad,
        )
    }

    /// Renderer-neutral snapshot; no canvas readback or escape parsing by worlds.
    /// Read in response to ui_state_changed; paint-only changes need no query.
    #[func]
    fn get_ui_state(&self) -> VarDictionary {
        let mut result = VarDictionary::new();
        let Some(st) = self.state.as_ref() else {
            return result;
        };
        result.set("title", &GString::from(st.title.as_str()));
        result.set("cwd", &GString::from(String::from_utf8_lossy(st.vt.pwd().unwrap_or(b"")).as_ref()));
        result.set("progress_state", i64::from(st.progress.state));
        result.set("progress_value", i64::from(st.progress.value));
        result.set(
            "alternate_screen",
            st.vt.active_screen().ok() == Some(Screen::Alternate),
        );
        result.set("exited", st.exited);
        // Copy mode, search or Quick Select; the screen is frozen while set.
        result.set("modal", &GString::from(st.modal_mode().unwrap_or("")));
        result.set("held_output", !st.held.is_empty());
        result.set("columns", i64::from(st.geo.cols));
        result.set("rows", i64::from(st.geo.rows));
        if let Some(copy) = &st.copy {
            result.set("flash_active", copy.flash_active());
            result.set("copy_status", &GString::from(copy.status().as_str()));
            let top = st.vt.scrollbar().map_or(0, |s| s.offset);
            let mut labels = Array::<VarDictionary>::new();
            for (row, col, label) in copy.labels(top, st.geo.rows) {
                let mut entry = VarDictionary::new();
                entry.set("row", i64::from(row));
                entry.set("column", i64::from(col));
                entry.set("label", &GString::from(label.to_string().as_str()));
                labels.push(&entry);
            }
            result.set("copy_labels", &labels);
        }
        if let Ok(scroll) = st.vt.scrollbar() {
            result.set("scroll_total", scroll.total as i64);
            result.set("scroll_offset", scroll.offset as i64);
            result.set("scroll_fraction", st.scroll_fraction);
            result.set("scroll_page", scroll.len as i64);
        }
        result
    }

    /// Font actions are handled by the world so reference-layout scaling survives.
    #[signal]
    fn shortcut_action(action: GString);

    /// Whether a direct binding's `when` state holds; unconditional bindings
    /// always do. Unknown names fail closed, leaving the key to the program.
    #[func]
    fn key_condition_holds(&self, code: i64) -> bool {
        let Some(condition) = self
            .key_binding_conditions
            .get(code)
            .and_then(|v| v.try_to::<GString>().ok())
        else {
            return true;
        };
        let Some(st) = self.state.as_ref() else {
            return false;
        };
        let condition = condition.to_string();
        let (negated, name) = match condition.strip_prefix('!') {
            Some(name) => (true, name),
            None => (false, condition.as_str()),
        };
        let state = match name {
            "prompt" => st.vt.is_cursor_at_prompt().unwrap_or(false),
            "alt_screen" => st.vt.active_screen().ok() == Some(Screen::Alternate),
            _ => return false,
        };
        state != negated
    }

    /// Run a terminal-local action. Returns false if it does not apply (e.g. scrolling a TUI).
    #[func]
    fn perform_action(&mut self, action: GString) -> bool {
        self.keyboard.action(&action.to_string())
            || self
                .state
                .as_mut()
                .is_some_and(|st| st.perform_action(&action.to_string()))
    }

    #[func]
    fn get_scroll_fraction(&self) -> f64 {
        self.state.as_ref().map_or(0.0, |st| st.scroll_fraction)
    }

    /// Whether touch scroll update `sequence` moved or pulled the rows, or
    /// reached the application; `null` when this terminal did not get it.
    /// Like Chromium's unconsumed fling update, `false` means the fling ran
    /// into an end.
    #[func]
    fn touch_scrolled(&self, sequence: i64) -> Variant {
        match self.state.as_ref().and_then(|st| st.touch_scrolled) {
            Some((last, scrolled)) if last == sequence => scrolled.to_variant(),
            _ => Variant::nil(),
        }
    }

    /// How far the rubber band displaces the content, in pixels: negative
    /// when pulled down from the top, positive when pulled up from the bottom.
    #[func]
    fn get_scroll_stretch(&self) -> f64 {
        self.state.as_ref().map_or(0.0, |st| f64::from(st.pull()))
    }

    /// Absolute scrollback row, independent of mouse-reporting/TUI modes.
    #[func]
    fn scroll_to_row(&mut self, row: i64) {
        self.scroll_to_position(row as f64);
    }

    /// Absolute fractional position for scrollbar dragging.
    #[func]
    fn scroll_to_position(&mut self, row: f64) {
        if !row.is_finite() {
            return;
        }
        let Some(st) = self.state.as_mut() else {
            return;
        };
        if st.vt.active_screen().ok() == Some(Screen::Alternate) {
            return;
        }
        if let Ok(scroll) = st.vt.scrollbar() {
            let row = row.clamp(0.0, scroll.total.saturating_sub(scroll.len) as f64);
            st.scroll_fraction = if st.smooth_scroll_allowed() {
                row.fract()
            } else {
                0.0
            };
            st.vt
                .scroll_viewport(ScrollViewport::Row(row.floor() as usize));
            st.ui_state_dirty = true;
            st.needs_paint = true;
            st.since_repaint = REPAINT_MIN_SECS;
        }
    }

    #[func]
    fn search_scrollback(&mut self, query: GString, direction: i32) -> i64 {
        let Some(st) = self.state.as_mut() else {
            return 0;
        };
        // Literal and case-sensitive, opening copy mode on the newest match.
        if st.copy.is_none() {
            st.start_copy(false);
        }
        let found = st
            .copy
            .as_mut()
            .map_or(0, |copy| copy.find_text(&mut st.vt, &query.to_string(), direction < 0));
        st.ui_state_dirty = true;
        st.needs_paint = true;
        found as i64
    }
    #[func]
    fn copy_last_output(&mut self) -> bool {
        let Some(st) = self.state.as_mut() else {
            return false;
        };
        let selected = crate::navigation::last_output(&mut st.vt);
        if selected {
            st.copy_selection(false);
            st.needs_paint = true;
        }
        selected
    }

    /// Quick Select state for accessibility, automation and diagnostics.
    #[func]
    fn get_quick_select_state(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        let quick = self.state.as_ref().and_then(|s| s.quick_select.as_ref());
        out.set("active", quick.is_some());
        let mut matches = Array::<VarDictionary>::new();
        if let Some(q) = quick {
            out.set("input", &GString::from(q.input.as_str()));
            for m in &q.matches {
                let mut entry = VarDictionary::new();
                entry.set("text", &GString::from(m.text.as_str()));
                entry.set("label", &GString::from(m.label.as_str()));
                matches.push(&entry);
            }
        }
        out.set("matches", &matches);
        out
    }

    #[signal]
    fn notification_received(title: GString, body: GString);

    #[signal]
    fn notification_command_received(packet: GString);
    #[signal]
    fn clipboard_read_requested(id: i64, selection: GString);
    #[signal]
    fn clipboard_cancelled();
    #[signal]
    fn clipboard_reply_ready(generation: i64, ticket: i64, data: PackedByteArray);
    #[signal]
    fn hyperlink_activated(uri: GString);
    #[signal]
    fn hyperlink_context_menu_requested(uri: GString, openable: bool, web: bool);

    #[func]
    fn answer_clipboard_read(&mut self, id: i64, allow: bool) {
        let mut remote_reply = None;
        if let Some(st) = self.state.as_mut() {
            if !st.exited && st.integration.clipboard_request.is_some_and(|r| r.0 == id) {
                let (_, selector, bel) = st.integration.clipboard_request.take().unwrap();
                let Some(ticket) = st.integration.remote_clipboard_ticket.take() else { return; };
                let reply = if let Some((primary, types)) = st.integration.extended_read.take() {
                    if allow { crate::clipboard::read(primary, &types) }
                    else { crate::clipboard::status("read", "EPERM") }
                } else if allow { clipboard_text_reply(selector, bel) } else { String::new() };
                remote_reply = Some((st.integration.clipboard_generation, ticket, reply.into_bytes()));
            }
        }
        if let Some((generation, ticket, bytes)) = remote_reply {
            self.base_mut().emit_signal("clipboard_reply_ready", &[generation.to_variant(), ticket.to_variant(), PackedByteArray::from(bytes.as_slice()).to_variant()]);
        }
    }
    #[func]
    fn remote_clipboard_reset(&mut self, generation: i64) {
        if let Some(st) = self.state.as_mut() {
            st.integration.clipboard = Default::default();
            st.integration.clipboard_request = None;
            st.integration.extended_read = None;
            st.integration.remote_clipboard_ticket = None;
            st.integration.announce_clipboard = false;
            st.integration.clipboard_generation = generation;
        }
        self.base_mut().emit_signal("clipboard_cancelled", &[]);
    }
    #[func]
    fn remote_clipboard(&mut self, generation: i64, ticket: i64, operation: GString) -> VarDictionary {
        if self.state.as_ref().is_some_and(|st| st.integration.clipboard_generation != generation) { self.remote_clipboard_reset(generation); }
        let mut result = VarDictionary::new();
        let Some(st) = self.state.as_mut().filter(|st| !st.exited) else { return result; };
        let before = st.integration.clipboard_request;
        let Ok(operation) = serde_json::from_str(&operation.to_string()) else { return result; };
        let bytes = st.integration.clipboard_operation(operation, self.clipboard_read, self.clipboard_write);
        let pending = before.is_none() && st.integration.clipboard_request.is_some();
        if pending { st.integration.remote_clipboard_ticket = Some(ticket); }
        result.set("pending", pending);
        result.set("data", &PackedByteArray::from(bytes.as_bytes()));
        result
    }
    #[func]
    fn activate_hyperlink(&mut self, uri: GString) {
        if !can_open_link(&uri.to_string(), self.web_only_hyperlinks) {
            return;
        }
        self.base_mut()
            .emit_signal("hyperlink_activated", &[uri.to_variant()]);
        if self.open_hyperlinks {
            let _ = Os::singleton().shell_open(&uri);
        }
    }
    #[func]
    fn get_hyperlink_at(&self, cell: Vector2i) -> GString {
        self.state
            .as_ref()
            .and_then(|st| {
                if cell.x < 0
                    || cell.y < 0
                    || cell.x >= st.geo.cols as i32
                    || cell.y >= st.geo.rows as i32
                {
                    return None;
                }
                crate::protocol::custom_hyperlink(
                    &st.vt,
                    cell.x as u16,
                    cell.y as u32,
                    &st.options.hyperlinks,
                )
            })
            .unwrap_or_default()
            .as_str()
            .into()
    }
    #[func]
    fn get_prompt_rows(&self) -> PackedInt32Array {
        let rows: Vec<i32> = self
            .state
            .as_ref()
            .map(|st| {
                crate::protocol::prompt_rows(&st.vt)
                    .into_iter()
                    .map(|r| r as i32)
                    .collect()
            })
            .unwrap_or_default();
        PackedInt32Array::from(rows.as_slice())
    }
    #[func]
    fn scroll_to_prompt(&mut self, direction: i64) {
        if let Some(st) = self.state.as_mut() {
            if crate::protocol::jump_prompt(&mut st.vt, direction) {
                st.scroll_fraction = 0.0;
                st.ui_state_dirty = true;
                st.needs_paint = true;
            }
        }
    }

    #[signal]
    fn title_changed(title: GString);
    #[signal]
    fn bell();

    #[signal]
    fn audible_bell_requested();
    #[signal]
    fn exited(code: i64);
    /// Typing activity, including changes to uncommitted IME text, at its
    /// cell. IME updates are visual activity only; they are not written to
    /// the PTY.
    ///
    /// Arrow navigation and key releases do not emit typing activity.
    /// Backspace and forward Delete use control codes 8 and 127 respectively.
    ///
    /// A host routes input itself and can hook that; anything else — a world
    /// plugin drawing sparks where you type — cannot, which is why this
    /// exists.
    #[signal]
    fn keystroke(cell: Vector2i, unicode: i64);
    /// The cursor changed cell, from typing, output or an escape. Saves polling
    /// get_cursor_cell() every frame for effects that follow the caret.
    #[signal]
    fn cursor_moved(cell: Vector2i);
    /// The grid reflowed: a resize, a font change, a padding change.
    #[signal]
    fn grid_resized(cols: i64, rows: i64);
    /// The shell wrote. Effects that should answer output rather than only
    /// keystrokes need this; the payload is how many bytes arrived.
    #[signal]
    fn output(bytes: i64);
    /// Recorded terminal pixels changed (output, blink, selection, IME, or resize).
    #[signal]
    fn frame_changed();
    /// Metadata, grid or scroll state may have changed. Independent of painting,
    /// so hidden panes and synchronized output still update their host UI.
    /// Coalesced once per process tick; consumers compare get_ui_state snapshots.
    #[signal]
    fn ui_state_changed();
    /// Copy mode put this text on the clipboard; a host may confirm it.
    #[signal]
    fn copied(text: GString);

    #[func]
    fn is_exited(&self) -> bool {
        self.state.as_ref().is_none_or(|st| st.exited)
    }

    #[func]
    fn set_remote_shell_pid(&mut self, pid: i64) { self.remote_shell_pid = pid; }

    #[func]
    fn get_shell_pid(&self) -> i64 { self.remote_shell_pid }

    #[func]
    fn has_running_child_processes(&self) -> bool {
        #[cfg(windows)]
        {
            self.state
                .as_ref()
                .is_some_and(|st| st.pty.has_running_children())
        }
        #[cfg(not(windows))]
        {
            true
        } // Unix close policy also detects exec-replaced shells via ps.
    }

    /// Return the cursor's viewport cell as (column, row).
    /// Return `(-1, -1)` when it is hidden or the terminal has not started.
    ///
    /// Hosts use this position to follow shell prompts, program output,
    /// cursor-movement escapes, and full-screen apps.
    #[func]
    fn get_cursor_cell(&self) -> Vector2i {
        match self.state.as_ref() {
            Some(st) if st.cursor_on => {
                Vector2i::new(i32::from(st.cursor_cell.0), i32::from(st.cursor_cell.1))
            }
            _ => Vector2i::new(-1, -1),
        }
    }

    /// Last painted cursor geometry in cell units, relative to get_cursor_cell().
    /// Includes DECSCUSR shape, wide cells, and the resolved cursor color.
    #[func]
    fn get_cursor_render_info(&self) -> VarDictionary {
        let mut result = VarDictionary::new();
        if let Some(st) = self.state.as_ref() {
            result.set("rect", st.cursor_render_rect);
            result.set("color", st.cursor_render_color);
        }
        result
    }

    /// Bounds of the latest completed presentation, in viewport cell coordinates.
    /// Missing rectangles mean empty, not a zero-sized rectangle at the origin.
    /// This reports observations only; it does not change manual or typing zoom.
    #[func]
    fn get_visible_area(&self) -> VarDictionary {
        let mut result = VarDictionary::new();
        let Some(st) = self.state.as_ref().filter(|st| st.visible_area.ready) else { return result };
        let tracker = &st.visible_area;
        let area = &tracker.area;
        result.set("generation", tracker.generation as i64);
        result.set("grid", Vector2i::new(i32::from(area.columns), i32::from(area.rows)));
        result.set("graphics_present", area.graphics_present);
        result.set("scroll_fraction", st.scroll_fraction);
        result.set("cell_size", Vector2::new(st.geo.cell_w, st.geo.cell_h));
        result.set("grid_origin", Vector2::new(st.geo.pad, st.geo.pad - st.scroll_fraction as f32 * st.geo.cell_h));
        for (name, bounds) in [("text", area.text), ("content", area.content),
                               ("cursor", area.cursor), ("framing", area.framing_bounds())] {
            if let Some(b) = bounds {
                result.set(name, Rect2i::new(
                    Vector2i::new(i32::from(b.left), i32::from(b.top)),
                    Vector2i::new(i32::from(b.right - b.left), i32::from(b.bottom - b.top)),
                ));
            }
        }
        result
    }

    /// Terminal grid as (columns, rows), so a caller can normalise the cursor.
    #[func]
    fn get_grid_size(&self) -> Vector2i {
        self.state.as_ref().map_or(Vector2i::ZERO, |st| {
            Vector2i::new(i32::from(st.geo.cols), i32::from(st.geo.rows))
        })
    }

    /// Draw the in-progress IME text with the terminal's own font, baseline,
    /// cell metrics, and dotted underline.
    ///
    /// `mark` is the half-open character range being composed. An empty range
    /// marks the last character. Korean input needs this because starting the
    /// next syllable commits the previous one.
    #[func]
    fn set_preedit(&mut self, text: GString, mark: Vector2i) {
        if !self.render_active { return; }
        let chars: Vec<char> = text.to_string().chars().collect();
        let (from, len) = if mark.y > 0 {
            (mark.x.max(0) as usize, mark.y as usize)
        } else if chars.is_empty() {
            (0, 0)
        } else {
            (chars.len() - 1, 1)
        };
        let mark = (
            from.min(chars.len()),
            len.min(chars.len().saturating_sub(from)),
        );
        let mut typed = None;
        if let Some(st) = self.state.as_mut() {
            if st.preedit == chars && st.preedit_mark == mark {
                return;
            }
            if st.preedit != chars && !chars.is_empty() {
                let index = mark.0.min(chars.len() - 1);
                // Match the preedit renderer's cell advances, including Hangul.
                let offset: usize = chars[..index]
                    .iter()
                    .map(|ch| {
                        if UnicodeWidthChar::width(*ch).unwrap_or(1) > 1 {
                            2
                        } else {
                            1
                        }
                    })
                    .sum();
                let column = (usize::from(st.cursor_cell.0) + offset)
                    .min(usize::from(st.geo.cols.saturating_sub(1)));
                typed = Some((
                    Vector2i::new(column as i32, i32::from(st.cursor_cell.1)),
                    chars[index] as i64,
                ));
                st.blink_elapsed = 0.0;
                st.blink_on = true;
                st.cursor_blink_on = true;
            }
            st.preedit = chars;
            st.preedit_mark = mark;
            // Mark the surface dirty when the IME composition changes.
            // The VT does not own that text, so it will not request a redraw.
            st.needs_paint = true;
        }
        self.base_mut().queue_redraw();
        if let Some((cell, unicode)) = typed {
            self.base_mut().call_deferred(
                "emit_signal",
                &[
                    "keystroke".to_variant(),
                    cell.to_variant(),
                    unicode.to_variant(),
                ],
            );
        }
    }

    /// Install server fonts and metrics without deriving a grid from this viewport.
    #[func]
    fn apply_server_font(&mut self, document: GString) -> bool {
        if !self.render_active { self.pending_server_font = Some(document); return true; }
        let result = (|| -> Result<(), String> {
            let value: serde_json::Value = serde_json::from_str(&document.to_string()).map_err(|e| e.to_string())?;
            let fonts = Fonts::server(&value["faces"])?;
            let ligatures = value["ligatures"].as_bool().ok_or("Missing server ligature setting")?;
            let size = value["size"].as_i64().filter(|v| (1..=72).contains(v)).ok_or("Invalid server font size")? as i32;
            let metrics = &value["metrics"];
            let metric = |key: &str| -> Result<f32, String> { metrics[key].as_f64().filter(|v| v.is_finite() && *v >= 0. && *v < 4096.).map(|v| v as f32).ok_or_else(|| format!("Invalid font metric {key}")) };
            let (width, height, baseline, underline, thickness) = (metric("width")?, metric("height")?, metric("baseline")?, metric("underline")?, metric("thickness")?);
            if width < 1. || height < 1. { return Err("Empty server cell".into()); }
            let st = self.state.as_mut().ok_or("Terminal is not ready")?;
            st.fonts = fonts;
            st.server_font = true;
            st.ligatures = ligatures;
            self.ligatures = ligatures;
            st.base_pt = size;
            st.font_size = size;
            st.geo.pad = 4.;
            st.geo.cell_w = width;
            st.geo.cell_h = height;
            st.geo.ascent = baseline;
            st.geo.underline = underline;
            st.geo.thick = thickness;
            st.vt.resize(st.geo.cols, st.geo.rows, width as u32, height as u32).map_err(|e| e.to_string())?;
            st.shared_geo.set(st.geo.shared());
            st.geo_changed = true;
            st.runs = RunCache::new();
            st.needs_paint = true;
            Ok(())
        })();
        if let Err(error) = result { godot_error!("Server font: {error}"); return false; }
        self.cell_padding = 4.;
        self.base_mut().queue_redraw();
        true
    }

    /// Cell box in pixels, the unit the grid above is measured in.
    #[func]
    fn get_cell_size(&self) -> Vector2 {
        self.state.as_ref().map_or(Vector2::ZERO, |st| {
            Vector2::new(st.geo.cell_w, st.geo.cell_h)
        })
    }

    /// Change the live terminal's base point size and reflow the PTY. The
    /// exported `font_size` property is spawn-time configuration; callers that
    /// need a runtime zoom must use this method.
    #[func]
    fn set_live_font_size(&mut self, points: i32) {
        if self.base().has_meta("server_font_owned") { return; }
        if let Some(st) = self.state.as_mut() {
            st.set_font_pt(points);
        }
    }

    #[func]
    fn get_live_font_size(&self) -> i32 {
        self.state.as_ref().map_or(self.font_size, |st| st.base_pt)
    }

    /// Where the IME's candidate window belongs, in THIS control's
    /// coordinates: under the cursor cell, on the next line's top edge.
    ///
    /// A host that paints the terminal somewhere other than the window
    /// projects this point itself and pushes the result to set_ime_anchor().
    #[func]
    fn get_cursor_anchor_local(&self) -> Vector2 {
        self.state.as_ref().map_or(Vector2::ZERO, |st| {
            Vector2::new(
                st.geo.pad + st.cursor_cell.0 as f32 * st.geo.cell_w,
                st.geo.pad + st.cursor_cell.1 as f32 * st.geo.cell_h + st.geo.cell_h,
            )
        })
    }

    /// Place the platform IME's candidate window at this window-space point.
    #[func]
    fn set_ime_anchor(&mut self, window_point: Vector2i) {
        self.ime_anchor = Some(window_point);
    }

    /// Go back to deriving the candidate window's position from this control's
    /// own position, which is right when the control is in the window.
    #[func]
    fn clear_ime_anchor(&mut self) {
        self.ime_anchor = None;
    }

    /// Colours, outright. `ansi` is positional from index 0 and may run all 256;
    /// whatever is left keeps the standard cube and grey ramp. Survives theme
    /// changes until clear_colors().
    #[func]
    fn set_colors(&mut self, bg: Color, fg: Color, cursor: Color, ansi: PackedColorArray) {
        let theme = theme::explicit(bg, fg, cursor, &ansi.to_vec());
        self.explicit_theme = Some(theme.clone());
        if let Some(st) = self.state.as_mut()
            && let Err(e) = st.apply_theme(theme)
        {
            godot_error!("[graffitty] colours failed: {e}");
        }
        self.signals().colors_changed().emit();
    }

    /// One palette entry, 0..255, without restating the rest. Sparse by design:
    /// a preset sets color0..color255 the way kitty's config does, and the
    /// entries it leaves out keep whatever they had.
    #[func]
    fn set_palette_color(&mut self, index: i32, color: Color) {
        if !(0..256).contains(&index) {
            godot_error!("[graffitty] palette index {index} out of range");
            return;
        }
        let mut theme = match self.explicit_theme.clone() {
            Some(theme) => theme,
            None => match self.state.as_ref() {
                Some(st) => st.theme.clone(),
                None => return,
            },
        };
        theme.palette[index as usize] = theme::rgb_of(color);
        self.explicit_theme = Some(theme.clone());
        if let Some(st) = self.state.as_mut()
            && let Err(e) = st.apply_theme(theme)
        {
            godot_error!("[graffitty] palette entry failed: {e}");
        }
        self.signals().colors_changed().emit();
    }

    /// What the bundled libghostty-vt was compiled with. Kitty graphics is a
    /// build-time option in the Zig core, so whether this terminal can ever show
    /// an image is not answerable any other way.
    #[func]
    fn vt_build_info(&self) -> VarDictionary {
        let mut out = VarDictionary::new();
        out.set(
            "kitty_graphics",
            build_info::supports_kitty_graphics().unwrap_or(false),
        );
        out.set("simd", build_info::supports_simd().unwrap_or(false));
        // What we asked for: the vt exposes no getter for it.
        out.set(
            "kitty_apc_max_bytes",
            i64::from(self.kitty_apc_max_mb) * 1024 * 1024,
        );
        out.set(
            "kitty_storage_limit",
            self.state
                .as_ref()
                .and_then(|st| st.vt.kitty_image_storage_limit().ok().flatten())
                .map_or(-1, |limit| limit as i64),
        );
        out.set(
            "tmux_control_mode",
            build_info::supports_tmux_control_mode().unwrap_or(false),
        );
        out
    }

    /// Return metadata for each inked cell so effects can group cells without
    /// rasterizing glyphs again or opening fonts in GDScript.
    ///
    /// - The first codepoint of the cluster and the VT's wide-cell flag.
    /// - `style` bits: 1 bold, 2 italic, 4 faint, 8 underline, 16 strikethrough,
    ///   32 overline, 64 inverse, 128 blink.
    /// - The resolved `font` slot. Slots 0–3 are style faces. Higher slots are fallbacks.
    ///
    /// For example, group emoji separately or animate Hangul on its own.
    /// This walks the viewport once per call. Request it when an effect starts.
    #[func]
    fn get_write_color(&self) -> Color {
        let Some(st) = self.state.as_ref() else {
            return Color::WHITE;
        };
        let fg = color(st.vt.fg_color().ok().flatten().unwrap_or(st.theme.fg));
        let Ok(style) = st.vt.cursor_style() else {
            return fg;
        };
        let value = if style.inverse {
            style.bg_color
        } else {
            style.fg_color
        };
        match value {
            StyleColor::Rgb(rgb) => color(rgb),
            StyleColor::Palette(index) => st
                .vt
                .color_palette()
                .map(|p| color(p.get(index)))
                .unwrap_or(fg),
            StyleColor::None => {
                if style.inverse {
                    st.bg
                } else {
                    fg
                }
            }
        }
    }

    #[func]
    fn cell_glyphs(&mut self) -> Array<VarDictionary> {
        let mut out = Array::new();
        if !self.render_active { return out; }
        let Some(st) = self.state.as_mut() else {
            return out;
        };
        let Ok(snapshot) = st.render_state.update(&st.vt) else {
            return out;
        };
        let Ok(colors) = snapshot.colors() else {
            return out;
        };
        let Ok(mut row_it) = st.rows.update(&snapshot) else {
            return out;
        };
        let fonts = &st.fonts;
        let cell_iter = &mut st.cells;
        let mut graphemes: Vec<char> = Vec::new();
        let mut row: i64 = 0;
        while let Some(r) = row_it.next() {
            let Ok(mut cell_it) = cell_iter.update(r) else {
                break;
            };
            let mut col: i64 = 0;
            while let Some(cell) = cell_it.next() {
                let n = cell.graphemes_len().unwrap_or(0) as usize;
                if n == 0 {
                    col += 1;
                    continue;
                }
                graphemes.resize(n, '\0');
                if cell.graphemes_buf(&mut graphemes).is_err() {
                    col += 1;
                    continue;
                }
                let cp = graphemes[0] as u32;
                let wide = matches!(cell.raw_cell().and_then(|c| c.wide()), Ok(CellWide::Wide));
                let mut bits: i64 = 0;
                let mut bold = false;
                let mut italic = false;
                if cell.has_styling().unwrap_or(false) {
                    if let Ok(style) = cell.style() {
                        bold = style.bold;
                        italic = style.italic;
                        for (on, bit) in [
                            (style.bold, 1),
                            (style.italic, 2),
                            (style.faint, 4),
                            (style.underline != Underline::None, 8),
                            (style.strikethrough, 16),
                            (style.overline, 32),
                            (style.inverse, 64),
                            (style.blink, 128),
                        ] {
                            if on {
                                bits |= bit;
                            }
                        }
                    }
                }
                let face = Fonts::style_index(bold, italic);
                let mut entry = VarDictionary::new();
                entry.set("col", col);
                entry.set("row", row);
                entry.set("cp", i64::from(cp));
                let inverse = cell.style().map(|s| s.inverse).unwrap_or(false);
                let fg = if inverse {
                    cell.bg_color().ok().flatten().unwrap_or(colors.background)
                } else {
                    cell.fg_color().ok().flatten().unwrap_or(colors.foreground)
                };
                entry.set("foreground", color(fg));
                entry.set("cluster", n as i64);
                entry.set("wide", wide);
                entry.set("style", bits);
                entry.set("font", i64::from(fonts.resolve_index(cp, face, || wide)));
                out.push(&entry);
                col += 1;
            }
            row += 1;
        }
        out
    }

    /// Where this terminal's images are, in cells.
    ///
    /// A world that wants to treat images as their own layer — its own
    /// surface, its own motion — needs to know which cells they occupy, and
    /// only the terminal knows.
    #[func]
    fn image_placements(&mut self) -> Array<VarDictionary> {
        let mut out = Array::new();
        if !self.render_active { return out; }
        let Some(st) = self.state.as_mut() else {
            return out;
        };
        let Ok(placements) = st.visible_image_placements() else { return out };
        for p in placements {
            let [x, y, w, h] = p.dest;
            let [sx, sy, sw, sh] = p.source;
            let mut entry = VarDictionary::new();
            entry.set("image_id", i64::from(p.image_id));
            entry.set("col", (x / st.geo.cell_w).floor() as i64);
            entry.set("row", (y / st.geo.cell_h).floor() as i64);
            entry.set("cols", (w / st.geo.cell_w).ceil() as i64);
            entry.set("rows", (h / st.geo.cell_h).ceil() as i64);
            entry.set("pixel_width", w as i64);
            entry.set("pixel_height", h as i64);
            entry.set("z", i64::from(p.z));
            entry.set("dest", Rect2::new(Vector2::new(st.geo.pad + x, st.geo.pad + y), Vector2::new(w, h)));
            entry.set("source", Rect2::new(Vector2::new(sx, sy), Vector2::new(sw, sh)));
            out.push(&entry);
        }
        out
    }

    /// Keep graphics on their existing retained layers, with their own
    /// presentation material. Both live rendering and effect captures use it.
    #[func]
    fn set_image_plane_material(&mut self, material: Gd<godot::classes::ShaderMaterial>) {
        if let Some(st) = self.state.as_mut() {
            let mut rs = RenderingServer::singleton();
            rs.canvas_item_set_material(st.canvas_img_above, material.get_rid());
            rs.canvas_item_set_material(st.canvas_img_below, material.get_rid());
            st.image_material = Some(material);
        }
    }

    /// Presentation only. The replicated geometry and PTY keep logical cell metrics.
    #[func]
    fn set_pixel_grid(&mut self, density: f32, origin_pixels: Vector2) {
        let grid = PixelGrid { density, phase: origin_pixels - origin_pixels.floor() };
        if let Some(st) = self.state.as_mut() && st.pixel_grid != grid {
            st.pixel_grid = grid;
            st.needs_paint = true;
        }
    }

    /// Glyphs are recorded during process(), outside Godot's canvas draw
    /// context. Supply their raster density explicitly; never resize the PTY.
    #[func]
    fn set_raster_scale(&mut self, scale: f32) {
        if !scale.is_finite() {
            return;
        }
        if let Some(st) = self.state.as_mut() {
            let scale = scale.clamp(1.0, 16.0);
            if (st.raster_scale - scale).abs() > 0.001 {
                st.raster_scale = scale;
                st.needs_paint = true;
            }
        }
    }

    /// Restart the shell in the existing terminal node. Keep its size,
    /// colors, and scene connections.
    ///
    /// The host decides when to call this after the shell exits.
    #[func]
    fn respawn(&mut self) {
        let Some(spawn) = self.spawn.clone() else {
            godot_error!("[graffitty] respawn before the terminal ever started");
            return;
        };
        let size = self.base().get_size();
        let parent_canvas = self.base().get_canvas_item();
        let theme = self
            .explicit_theme
            .clone()
            .unwrap_or_else(|| theme::resolve(self.in_editor(), self.scheme_pref()));
        // Drop first: the old State owns the pty and its canvas items, and two
        // live grids on one canvas would paint over each other.
        self.state = None;
        match State::new(&spawn, theme, size, parent_canvas) {
            Ok(state) => self.state = Some(state),
            Err(e) => godot_error!("[graffitty] respawn failed: {e}"),
        }
        let input_ready = self.to_gd().callable("emit_signal").bind(&["input_ready".to_variant()]);
        if let Some(st) = self.state.as_mut() {
            st.scene_budget = self.render_image_budget;
            st.writer.on_input(input_ready);
        }
        self.base_mut().queue_redraw();
    }

    /// Write text to the shell as if it had been typed. Raw: no bracketed paste
    /// wrapper, no control stripping, so a caller can send an escape on purpose.
    #[func]
    fn send_text(&mut self, text: GString) {
        let bytes = text.to_string();
        if bytes.is_empty() {
            return;
        }
        // A pane in a tab not shown yet has no replica, but its program still
        // takes text, e.g. notification replies. Rendering stays disabled.
        if self.state.is_none() && self.base().is_node_ready() {
            self.initialize_state();
        }
        let Some(st) = self.state.as_mut().filter(|st| !st.exited) else {
            return;
        };
        st.writer.write(bytes.as_bytes());
        // The program gets the text; a frozen overlay keeps its own view.
        if !st.frozen() {
            let _ = st.vt.set_selection(None);
            st.scroll_fraction = 0.0;
            st.vt.scroll_viewport(ScrollViewport::Bottom);
        }
        st.ui_state_dirty = true;
        st.needs_paint = true;
    }

    /// Paste text the way a clipboard paste goes in: encoded through libghostty,
    /// which strips controls and brackets it when the application asked for
    /// bracketed paste.
    #[func]
    fn paste_text(&mut self, text: GString) {
        if let Some(st) = self.state.as_mut().filter(|st| !st.exited) {
            st.paste_str(&text.to_string());
            st.needs_paint = true;
        }
    }

    fn cell_metrics(&self) -> CellMetrics {
        CellMetrics {
            pad: self.cell_padding.max(0.0),
            line_height: self.line_height.clamp(0.5, 3.0),
            column_width: self.column_width.clamp(0.5, 3.0),
        }
    }

    fn selection_colors(&self) -> crate::selection::SelectionColors {
        crate::selection::SelectionColors {
            background: (self.selection_bg.a > 0.0).then(|| theme::rgb_of(self.selection_bg)),
            foreground: (self.selection_fg.a > 0.0).then(|| theme::rgb_of(self.selection_fg)),
        }
    }

    /// Change the cell box on a running terminal: padding in pixels, and the
    /// two multipliers on the font's own metrics. Reflows, because the grid
    /// that fits the control changes with it.
    #[func]
    fn set_live_cell_metrics(&mut self, padding: f32, line_height: f32, column_width: f32) {
        if self.base().has_meta("server_font_owned") { return; }
        if self.state.as_ref().is_some_and(|st| st.server_font) { return; }
        self.cell_padding = padding.max(0.0);
        self.line_height = line_height.clamp(0.5, 3.0);
        self.column_width = column_width.clamp(0.5, 3.0);
        let metrics = self.cell_metrics();
        if let Some(st) = self.state.as_mut()
            && let Err(e) = st.set_metrics(metrics)
        {
            godot_error!("[graffitty] cell metrics failed: {e}");
        }
    }

    /// Alpha zero means unset independently per colour. Both unset restores
    /// inversion; only foreground unset preserves the cell's original ink.
    #[func]
    fn set_selection_colors(&mut self, bg: Color, fg: Color) {
        self.selection_bg = bg;
        self.selection_fg = fg;
        let selection = self.selection_colors();
        if let Some(st) = self.state.as_mut() {
            st.selection = selection;
            st.needs_paint = true;
        }
    }

    // Avoid Control::get_cursor_shape, which describes the mouse pointer.
    #[func]
    fn get_terminal_cursor_shape(&self) -> i32 {
        self.cursor_shape
    }

    /// 0 auto (DECSCUSR), 1 block, 2 bar, 3 underline, 4 hollow block.
    #[func]
    fn set_live_cursor_shape(&mut self, shape: i32) {
        self.cursor_shape = shape;
        if let Some(st) = self.state.as_mut() {
            st.cursor_shape = shape;
            st.needs_paint = true;
        }
    }

    /// Change how opaque the default background is on a running terminal.
    #[func]
    fn set_live_background_opacity(&mut self, opacity: f32) {
        self.background_opacity = opacity.clamp(0.0, 1.0);
        if let Some(st) = self.state.as_mut() {
            st.bg_opacity = self.background_opacity;
            st.needs_paint = true;
        }
        self.base_mut().queue_redraw();
    }

    /// Hand the palette back to the generated one.
    #[func]
    fn clear_colors(&mut self) {
        self.explicit_theme = None;
        let theme = theme::resolve(self.in_editor(), self.scheme_pref());
        if let Some(st) = self.state.as_mut()
            && let Err(e) = st.apply_theme(theme)
        {
            godot_error!("[graffitty] colours failed: {e}");
        }
        self.signals().colors_changed().emit();
    }

    /// Change the faces on a running terminal and reflow to the new cell box.
    /// The exported `font_paths` is spawn-time configuration, as `font_size`
    /// is to set_live_font_size().
    #[func]
    fn set_live_font_paths(&mut self, paths: PackedStringArray) {
        self.apply_live_fonts(paths, GString::new(), self.font_fallbacks.clone());
    }

    /// Select an installed family, or restore bundled fonts with an empty name.
    #[func]
    fn set_live_font_family(&mut self, family: GString) {
        self.apply_live_fonts(
            PackedStringArray::new(),
            family,
            self.font_fallbacks.clone(),
        );
    }

    #[func]
    fn validate_pattern(pattern: GString) -> GString {
        match fancy_regex::Regex::new(&pattern.to_string()) {
            Ok(regex) => {
                if regex.is_match("").unwrap_or(false) {
                    GString::from("Patterns must not match empty text")
                } else {
                    GString::new()
                }
            }
            Err(error) => GString::from(format!("Invalid regex: {error}").as_str()),
        }
    }

    #[func]
    fn validate_iskeyword(rules: GString) -> GString {
        match graffitty_terminal_core::copy_mode::IsKeyword::parse(&rules.to_string()) {
            Ok(_) => GString::new(),
            Err(error) => GString::from(error.as_str()),
        }
    }

    #[func]
    fn configure_advanced(&mut self, values: VarDictionary) {
        let mut options = crate::options::Options::parse(&values);
        if !self.ligatures && !options.font_features.is_empty() {
            for feature in ["calt", "liga", "dlig"] {
                options.font_features.set(feature, 0);
            }
        }
        self.keyboard.configure(&values);
        if let Some(st) = self.state.as_mut() {
            st.input
                .set_word_boundaries(options.word_boundaries.as_deref());
            if let Some(copy) = st.copy.as_mut() {
                copy.set_iskeyword(options.iskeyword.clone());
            }
            st.options = options.clone();
            st.ligatures = self.ligatures;
            st.quick_select = None;
            st.needs_paint = true;
        }
        if let Some(spawn) = self.spawn.as_mut() {
            spawn.advanced_options = options.clone();
        }
        self.advanced_options = options;
    }

    /// Atomically apply primary styles and fallback order to a running session.
    #[func]
    fn set_live_font_config(
        &mut self,
        paths: PackedStringArray,
        family: GString,
        fallbacks: PackedStringArray,
    ) {
        self.apply_live_fonts(paths, family, fallbacks);
    }

    fn apply_live_fonts(
        &mut self,
        paths: PackedStringArray,
        family: GString,
        fallbacks: PackedStringArray,
    ) {
        if self.base().has_meta("server_font_owned") { return; }
        let list = paths.to_vec();
        if let Some(st) = self.state.as_mut()
            && let Err(e) = st.set_fonts(&list, &family.to_string(), &fallbacks.to_vec())
        {
            godot_error!("[graffitty] font change failed: {e}");
            return;
        }
        self.font_paths = paths;
        self.font_family = family.clone();
        self.font_fallbacks = fallbacks.clone();
        if let Some(spawn) = self.spawn.as_mut() {
            spawn.font_paths = list;
            spawn.font_family = family.to_string();
            spawn.font_fallbacks = fallbacks.to_vec();
        }
    }

    #[func]
    fn on_editor_settings_changed(&mut self) {
        self.refresh_theme();
        self.refresh_ligatures();
    }

    fn refresh_theme(&mut self) {
        if self.explicit_theme.is_some() || !self.in_editor() {
            return;
        }
        let pref = self.scheme_pref();
        let Some(st) = self.state.as_mut() else {
            return;
        };
        let theme = theme::resolve(true, pref);
        if theme == st.theme {
            return;
        }
        if let Err(e) = st.apply_theme(theme) {
            godot_error!("[graffitty] theme change failed: {e}");
        }
        self.signals().colors_changed().emit();
    }

    fn refresh_ligatures(&mut self) {
        if !self.in_editor() {
            return;
        }
        let pref = self.ligatures_pref();
        if let Some(st) = self.state.as_mut()
            && st.ligatures != pref
        {
            st.ligatures = pref;
            st.needs_paint = true;
        }
    }

    fn ime_window_id(&self) -> Option<i32> {
        // Hiding a native Window destroys its DisplayServer entry before its
        // terminal viewport releases focus. There is no IME left to update.
        self.base()
            .get_window()
            .filter(|window| window.is_visible())
            .map(|window| window.get_window_id())
            .filter(|id| *id >= 0)
    }

    fn set_ime_active(&self, active: bool) {
        self.sync_terminal_key_focus(active && self.owns_ime());
        if !DisplayServer::singleton().has_feature(DisplayFeature::IME) {
            return;
        }
        if let Some(window_id) = self.ime_window_id() {
            DisplayServer::singleton()
                .window_set_ime_active_ex(active)
                .window_id(window_id)
                .done();
        }
    }

    fn sync_terminal_key_focus(&self, active: bool) {
        if let Some(window_id) = self.ime_window_id() {
            crate::set_terminal_key_focus(window_id, self.base().instance_id().to_i64() as u64, active);
        }
    }

    fn owns_ime(&self) -> bool {
        // Focus belongs to a viewport: several offscreen terminals can all
        // retain it. The host disables GUI input on every inactive viewport.
        self.render_active && self.base().has_focus()
            && self.base().is_visible_in_tree()
            && self
                .base()
                .get_viewport()
                .is_some_and(|vp| !vp.is_input_disabled())
            && self
                .base()
                .get_window()
                .is_some_and(|window| window.has_focus())
    }

    fn clear_preedit(&mut self) {
        if self.state.as_ref().is_some_and(|st| !st.preedit.is_empty()) {
            self.set_preedit(GString::new(), Vector2i::ZERO);
        }
    }
}

#[godot_api]
impl IControl for Terminal {
    fn init(base: Base<Control>) -> Self {
        Self {
            base,
            font_size: 14,
            remote_mode: true,
            remote_shell_pid: -1,
            render_active: true,
            render_snapshot_ready: false,
            awaiting_remote_scene: true,
            render_image_budget: 64 * 1024 * 1024,
            pending_server_font: None,
            use_custom_key_bindings: false,
            key_bindings: VarDictionary::new(),
            key_binding_conditions: VarDictionary::new(),
            ligatures: true,
            scrollback: 1000,
            shell: GString::new(),
            environment: VarDictionary::new(),
            working_directory: GString::new(),
            login_shell: true,
            shell_integration: true,
            clipboard_write: true,
            clipboard_read: 1,
            open_hyperlinks: true,
            web_only_hyperlinks: false,
            show_hyperlink_tooltip: true,
            color_scheme: theme::SCHEME_AUTO,
            run_in_editor: false,
            background_opacity: 1.0,
            kitty_image_storage_mb: 320,
            kitty_apc_max_mb: 65,
            cell_padding: DEFAULT_PAD,
            line_height: 1.0,
            column_width: 1.0,
            selection_bg: Color::from_rgba8(127, 102, 153, 255),
            selection_fg: Color::from_rgba(0.0, 0.0, 0.0, 0.0),
            cursor_shape: 0,
            font_paths: PackedStringArray::new(),
            font_family: GString::new(),
            font_fallbacks: PackedStringArray::new(),
            advanced_options: Default::default(),
            keyboard: Default::default(),
            ime_anchor: None,
            explicit_theme: None,
            spawn: None,
            state: None,
            ime_suppressed: false,
        }
    }

    fn get_tooltip(&self, _at_position: Vector2) -> GString {
        if self.show_hyperlink_tooltip {
            self.base().get_tooltip_text()
        } else {
            GString::new()
        }
    }

    fn ready(&mut self) {
        self.base_mut().set_focus_mode(FocusMode::ALL);
        if !self.render_active { self.base_mut().set_process(false); return; }
        self.initialize_state();
    }

    fn process(&mut self, delta: f64) {
        let _span = crate::profile::Span::new("Terminal");
        let visible = self.render_active && self.base().is_visible_in_tree();
        // Hidden replicas only service pending semantic events. No IME polling,
        // geometry work, blink animation, image upload or glyph preparation.
        if !visible && self.state.as_ref().is_none_or(|st| {
            !st.ui_state_dirty && !st.refresh_held && st.copied.is_none()
                && !st.bell.get() && (st.held.is_empty() || st.frozen())
        }) {
            return;
        }
        self.apply_held();
        if let Some(text) = self.state.as_mut().and_then(|st| st.copied.take()) {
            self.base_mut()
                .call_deferred("emit_signal", &["copied".to_variant(), text.to_variant()]);
        }
        // Read focus from the owner before painting the first frame.
        // A focus notification can arrive before State exists, and replacing
        // State while focused does not emit another FOCUS_ENTER.
        //
        // Without the check, the hollow cursor can stay until focus returns.
        if visible {
            let focused = self.base().has_focus();
            let win_focused = self.base().get_window().is_some_and(|window| window.has_focus());
            if let Some(st) = self.state.as_mut()
                && (st.focused != focused || st.win_focused != win_focused)
            {
                st.focused = focused;
                st.win_focused = win_focused;
                st.needs_paint = true;
                st.report_focus();
            }
        }
        let owns_ime = visible && self.owns_ime();
        self.sync_terminal_key_focus(owns_ime);
        if !owns_ime {
            self.clear_preedit();
        }
        let suppress = owns_ime
            && self
                .state
                .as_ref()
                .is_some_and(|st| st.copy.as_ref().is_some_and(|copy| !copy.wants_text()));
        if suppress != self.ime_suppressed {
            self.ime_suppressed = suppress;
            self.clear_preedit();
            self.set_ime_active(!suppress);
        }
        let control_size = self.base().get_size();
        let mouse_pos = if visible { self.base().get_local_mouse_position() } else { Vector2::ZERO };
        let global_position = if visible { self.base().get_global_position() } else { Vector2::ZERO };
        let ime_anchor = self.ime_anchor;
        let read_policy = self.clipboard_read;
        let write_enabled = self.clipboard_write;
        let window_id = if owns_ime { self.ime_window_id() } else { None };
        let Some(st) = self.state.as_mut() else {
            return;
        };
        if visible { st.upload_scene_image(); }
        if owns_ime && DisplayServer::singleton().has_feature(DisplayFeature::IME) {
            // `global_position` is local to the control's viewport. Use it directly
            // when that viewport is the window.
            //
            // A host that draws the terminal elsewhere must project the cursor
            // into window coordinates and supply `ime_anchor`.
            let cursor = ime_anchor.unwrap_or_else(|| {
                Vector2i::new(
                    (global_position.x + st.geo.pad + st.cursor_cell.0 as f32 * st.geo.cell_w)
                        .round() as i32,
                    (global_position.y
                        + st.geo.pad
                        + st.cursor_cell.1 as f32 * st.geo.cell_h
                        + st.geo.cell_h)
                        .round() as i32,
                )
            });
            if let Some(window_id) = window_id {
                DisplayServer::singleton()
                    .window_set_ime_position_ex(cursor)
                    .window_id(window_id)
                    .done();
            }
        }
        // Replayable scene bytes must never mutate a desktop clipboard.
        st.clipboard_write_enabled.set(false);
        st.writer.flush();

        // A drag held past the edge keeps scrolling until released.
        if visible && st.selecting {
            let rectangle = GdInput::singleton().is_key_pressed(GKey::ALT);
            let geo = st.geo.mouse();
            st.autoscroll_accum += delta;
            while st.autoscroll_accum >= SELECTION_SCROLL_SECS {
                st.autoscroll_accum -= SELECTION_SCROLL_SECS;
                if st
                    .input
                    .selection_autoscroll(&st.vt, mouse_pos.x, mouse_pos.y, rectangle, geo)
                {
                    st.ui_state_dirty = true;
                    st.needs_paint = true;
                }
            }
        }

        if st.tick_elastic(clock()) {
            st.needs_paint = true;
            st.since_repaint = REPAINT_MIN_SECS;
        }

        let mut dirty = st.needs_paint;
        if visible && (control_size.x != st.geo.width || control_size.y != st.geo.height) {
            if st.pending_size == Some(control_size) {
                st.settle += delta;
                if st.settle >= RESIZE_SETTLE_SECS {
                    st.pending_size = None;
                    if st.refit(control_size) {
                        dirty = true;
                    }
                }
            } else {
                st.pending_size = Some(control_size);
                st.settle = 0.0;
            }
        }
        // Drain to EOF, not to child exit; final output may still be in flight.
        let mut out_bytes: usize = 0;
        if !st.eof {
            match st.pty.drain(|chunk| {
                out_bytes += chunk.len();
                st.progress.feed(chunk);
                st.integration.feed(
                    &mut st.vt,
                    &st.writer,
                    chunk,
                    read_policy,
                    write_enabled,
                    (st.geo.cell_w as u32, st.geo.cell_h as u32),
                )
            }) {
                Drained::Data => dirty = true,
                Drained::Eof => st.eof = true,
                Drained::Empty => {}
            }
        }
        let mut exit = None;
        if !st.exited {
            exit = st.pty.exit_status().map(|status| {
                st.exited = true;
                dirty = true;
                status
            });
        }
        let bell = st.bell.take();
        let audible_bell = bell && st.options.audible_bell;
        if st.visual_bell_remaining > 0.0 {
            st.visual_bell_remaining = (st.visual_bell_remaining - delta).max(0.0);
            dirty = true;
        }
        if bell {
            st.visual_bell_remaining = st.options.visual_bell_duration;
            dirty = true;
        }
        st.ui_state_dirty |= out_bytes > 0 || st.geo_changed || exit.is_some();
        let title = if st.ui_state_dirty {
            st.refresh_title()
        } else {
            None
        };
        if out_bytes > 0 || st.geo_changed || title.is_some() || exit.is_some() {
            st.remote_revision = st.remote_revision.wrapping_add(1);
        }

        if visible { st.blink_elapsed += delta; }
        let blink_on = (st.blink_elapsed % 1.0) < 0.5;
        if blink_on != st.blink_on && (st.cursor_blinks || st.text_blinks) {
            dirty = true;
        }
        st.blink_on = blink_on;
        let cursor_on =
            (st.blink_elapsed % (st.options.cursor_period * 2.0)) < st.options.cursor_period;
        if st.cursor_blink_on != cursor_on && st.cursor_blinks {
            dirty = true;
        }
        st.cursor_blink_on = cursor_on;
        let synchronized = st.vt.mode(Mode::SYNC_OUTPUT).unwrap_or(false);
        st.sync_elapsed = if synchronized {
            st.sync_elapsed + delta
        } else {
            0.0
        };
        // A crashed client must not leave the renderer frozen indefinitely.
        if st.sync_elapsed >= 1.0 {
            let _ = st.vt.set_mode(Mode::SYNC_OUTPUT, false);
        }
        let defer_render = synchronized && st.sync_elapsed < 1.0;
        let mut bg_changed = false;
        let mut frame_changed = false;
        st.since_repaint += delta;
        if dirty && defer_render {
            st.needs_paint = true;
        }
        if dirty && !defer_render {
            // Hidden terminals keep draining but skip the re-record;
            // needs_paint stays sticky for the first visible frame.
            if visible && st.since_repaint >= REPAINT_MIN_SECS {
                // Carry the overshoot so steady output holds the cap, not half it.
                st.since_repaint = (st.since_repaint - REPAINT_MIN_SECS).min(REPAINT_MIN_SECS);
                st.needs_paint = false;
                match st.repaint(control_size) {
                    Ok(changed) => {
                        bg_changed = changed;
                        frame_changed = true;
                    }
                    Err(e) => {
                        st.needs_paint = true;
                        godot_error!("[graffitty] repaint failed: {e}");
                    }
                }
            } else {
                st.needs_paint = true;
            }
        }

        let ui_state_changed = std::mem::take(&mut st.ui_state_dirty);
        let cursor_moved = std::mem::take(&mut st.cursor_changed);
        let grid_resized = std::mem::take(&mut st.geo_changed);
        let cursor_cell = Vector2i::new(i32::from(st.cursor_cell.0), i32::from(st.cursor_cell.1));
        let grid = Vector2i::new(i32::from(st.geo.cols), i32::from(st.geo.rows));

        let notification = st.integration.notification.take();
        let notification_commands = std::mem::take(&mut st.integration.notification_commands);
        let clipboard_request = if st.integration.announce_clipboard {
            st.integration.announce_clipboard = false;
            st.integration.clipboard_request
        } else {
            None
        };
        let pointer = if st.hover_link.is_none() {
            pointer_shape(
                st.integration
                    .pointers
                    .current(st.vt.active_screen().ok() == Some(Screen::Alternate)),
            )
        } else {
            godot::classes::control::CursorShape::POINTING_HAND
        };
        let tooltip = GString::from(st.hover_link.as_ref().map_or("", |link| link.uri.as_str()));
        if visible {
            self.base_mut().set_tooltip_text(&tooltip);
            self.base_mut().set_default_cursor_shape(pointer);
        }
        for packet in notification_commands {
            self.base_mut().call_deferred(
                "emit_signal",
                &[
                    "notification_command_received".to_variant(),
                    GString::from(packet.as_str()).to_variant(),
                ],
            );
        }
        if let Some((title, body)) = notification {
            self.base_mut().call_deferred(
                "emit_signal",
                &[
                    "notification_received".to_variant(),
                    GString::from(title.as_str()).to_variant(),
                    GString::from(body.as_str()).to_variant(),
                ],
            );
        }
        if let Some((id, selector, _)) = clipboard_request {
            self.base_mut().call_deferred(
                "emit_signal",
                &[
                    "clipboard_read_requested".to_variant(),
                    id.to_variant(),
                    GString::from((selector as char).to_string().as_str()).to_variant(),
                ],
            );
        }

        // Deferred so handlers may call back into this Terminal.
        if out_bytes > 0 {
            self.base_mut().call_deferred(
                "emit_signal",
                &["output".to_variant(), (out_bytes as i64).to_variant()],
            );
        }
        if cursor_moved {
            self.base_mut().call_deferred(
                "emit_signal",
                &["cursor_moved".to_variant(), cursor_cell.to_variant()],
            );
        }
        if grid_resized {
            self.base_mut().call_deferred(
                "emit_signal",
                &[
                    "grid_resized".to_variant(),
                    i64::from(grid.x).to_variant(),
                    i64::from(grid.y).to_variant(),
                ],
            );
        }
        if let Some(code) = exit {
            self.base_mut().call_deferred(
                "emit_signal",
                &["exited".to_variant(), i64::from(code).to_variant()],
            );
        }
        if let Some(title) = title {
            self.base_mut().call_deferred(
                "emit_signal",
                &["title_changed".to_variant(), title.to_variant()],
            );
        }
        if bell {
            self.base_mut()
                .call_deferred("emit_signal", &["bell".to_variant()]);
        }
        if audible_bell {
            self.base_mut().call_deferred("emit_signal", &["audible_bell_requested".to_variant()]);
        }
        if bg_changed {
            self.base_mut().queue_redraw();
        }
        if ui_state_changed {
            self.base_mut()
                .call_deferred("emit_signal", &["ui_state_changed".to_variant()]);
        }
        if frame_changed {
            self.render_snapshot_ready = !self.remote_mode || !self.awaiting_remote_scene;
            self.base_mut()
                .call_deferred("emit_signal", &["frame_changed".to_variant()]);
        }
    }

    fn can_drop_data(&self, _position: Vector2, data: Variant) -> bool {
        self.state.as_ref().is_some_and(|st| !st.exited) && data.try_to::<GString>().is_ok()
    }
    fn drop_data(&mut self, _position: Vector2, data: Variant) {
        if let Ok(text) = data.try_to::<GString>() {
            self.paste_text(text);
        }
    }

    fn gui_input(&mut self, mut event: Gd<InputEvent>) {
        if self.state.is_none() {
            return;
        }
        if let Ok(motion) = event.clone().try_cast::<InputEventMouseMotion>() {
            self.state.as_mut().unwrap().hover_position = Some(motion.get_position());
        }

        let mut restore_top = None;
        let positional = event.clone().try_cast::<InputEventMouseMotion>().is_ok()
            || event
                .clone()
                .try_cast::<InputEventMouseButton>()
                .is_ok_and(|button| {
                    !matches!(
                        button.get_button_index(),
                        MouseButton::WHEEL_UP
                            | MouseButton::WHEEL_DOWN
                            | MouseButton::WHEEL_LEFT
                            | MouseButton::WHEEL_RIGHT
                    )
                });
        let control_height = self.base().get_size().y;
        if positional
            && let Some(st) = self.state.as_mut()
            && st.smooth_scroll_allowed()
        {
            let mut mapped = event.duplicate().unwrap().cast::<InputEventMouse>();
            let mut point = mapped.get_position();
            let inside = point.y >= st.geo.pad && point.y < control_height;
            point = st.content_transform(control_height).affine_inverse() * point;
            // Exposed bottom rows belong to later integer viewports.
            // Gesture selection stores absolute pins, so restoring afterward
            // preserves selection across both snapshots.
            if inside && point.y >= st.geo.pad + f32::from(st.geo.rows) * st.geo.cell_h {
                if let Ok(bar) = st.vt.scrollbar() {
                    let shift = (((point.y - st.geo.pad) / st.geo.cell_h).floor() as usize + 1
                        - usize::from(st.geo.rows))
                    .min(bar.total.saturating_sub(bar.len).saturating_sub(bar.offset) as usize);
                    restore_top = Some(bar.offset as usize);
                    st.vt
                        .scroll_viewport(ScrollViewport::Row(bar.offset as usize + shift));
                    point.y -= shift as f32 * st.geo.cell_h;
                }
            }
            mapped.set_position(point);
            event = mapped.upcast();
        }
        if let Ok(key) = event.clone().try_cast::<InputEventKey>() {
            self.handle_key(&key);
        } else if let Ok(btn) = event.clone().try_cast::<InputEventMouseButton>() {
            self.handle_mouse_button(&btn);
        } else if let Ok(motion) = event.clone().try_cast::<InputEventMouseMotion>() {
            self.handle_mouse_motion(&motion);
        } else if let Ok(pan) = event.try_cast::<InputEventPanGesture>() {
            self.handle_pan(&pan);
        }
        if let Some(top) = restore_top
            && let Some(st) = self.state.as_mut()
        {
            st.vt.scroll_viewport(ScrollViewport::Row(top));
        }
    }

    /// Re-emit the title after reparenting (a dock move) or a theme change:
    /// both rebuild tabs, which restart from the node name. THEME_CHANGED
    /// also arrives after a new editor theme applies.
    fn on_notification(&mut self, what: ControlNotification) {
        if what == ControlNotification::MOUSE_EXIT
            && let Some(st) = self.state.as_mut()
        {
            st.hover_position = None;
            st.needs_paint |= st.hover_link.take().is_some();
            self.base_mut().set_tooltip_text("");
        }
        if (what == ControlNotification::ENTER_TREE || what == ControlNotification::THEME_CHANGED)
            && let Some(st) = self.state.as_mut()
        {
            st.title.clear();
            st.ui_state_dirty = true;
        }
        if what == ControlNotification::FOCUS_ENTER || what == ControlNotification::FOCUS_EXIT {
            let active = what == ControlNotification::FOCUS_ENTER;
            // Focus sets the input method itself; process() reapplies copy mode.
            self.ime_suppressed = false;
            if !active {
                self.keyboard.reset();
                self.clear_preedit();
            }
            if let Some(st) = self.state.as_mut() {
                st.focused = active;
                st.needs_paint = true;
                st.report_focus();
            }
            self.set_ime_active(active);
        }
        if what == ControlNotification::EXIT_TREE {
            self.sync_terminal_key_focus(false);
        }
        if what == ControlNotification::OS_IME_UPDATE {
            // This notification is broadcast, including to input-disabled
            // SubViewports. Only the actual input owner may display it.
            if !self.owns_ime() {
                self.clear_preedit();
                return;
            }
            // Godot delivers a composition here and nowhere else: it is not
            // an input event, so a host feeding this control through
            // push_input never sees it.
            //
            // Reading it also keeps Godot's IME state in step with the
            // focused terminal.
            //
            // The committed codepoints still arrive through InputEventKey and
            // are encoded by input.rs; only the uncommitted run is ours to
            // draw.
            let ds = DisplayServer::singleton();
            let composition = ds.ime_get_text();
            let selection = ds.ime_get_selection();
            self.set_preedit(composition, selection);
            if let Some(st) = self.state.as_mut() {
                st.needs_paint = true;
            }
        }
        if (what == ControlNotification::WM_WINDOW_FOCUS_IN
            || what == ControlNotification::WM_WINDOW_FOCUS_OUT)
            && let Some(st) = self.state.as_mut()
        {
            st.win_focused = what == ControlNotification::WM_WINDOW_FOCUS_IN;
            st.needs_paint = true;
            st.report_focus();
        }
        if what == ControlNotification::THEME_CHANGED {
            self.refresh_theme();
        }
    }

    /// Background only; the grid lives on retained canvas items.
    fn draw(&mut self) {
        let _span = crate::profile::Span::new("Terminal.draw");
        if !self.render_active { return; }
        let size = self.base().get_size();
        let Some((mut bg, opacity)) = self.state.as_ref().map(|st| (st.bg, st.bg_opacity)) else {
            return;
        };
        if opacity <= 0.0 {
            return;
        }
        bg.a = opacity;
        self.base_mut()
            .draw_rect(Rect2::new(Vector2::ZERO, size), bg);
    }
}

impl Terminal {
    fn initialize_state(&mut self) {
        if Engine::singleton().is_editor_hint() && !self.run_in_editor {
            return;
        }
        // Godot does not activate the platform IME for custom controls by
        // itself.  Without this, macOS's Korean input source never sends a
        // composition to the terminal.
        if self.render_active { self.set_ime_active(true); }
        crate::install_ime_shim();
        self.base_mut().set_clip_contents(true);
        let size = self.base().get_size();
        let parent_canvas = self.base().get_canvas_item();
        let scale = if Engine::singleton().is_editor_hint() {
            EditorInterface::singleton().get_editor_scale()
        } else {
            1.0
        };
        let mut shell_environment: HashMap<String, String> = self
            .environment
            .iter_shared()
            .filter_map(|(k, v)| {
                Some((
                    k.try_to::<GString>().ok()?.to_string(),
                    v.try_to::<GString>().ok()?.to_string(),
                ))
            })
            .collect();
        let spawn = Spawn {
            remote: true,
            font_size: self.font_size.clamp(1, 72),
            scale,
            ligatures: self.ligatures_pref(),
            scrollback: self.scrollback.min(MAX_SCROLLBACK),
            shell: self.shell.to_string(),
            environment: shell_environment,
            cwd: resolve_cwd(&self.working_directory.to_string()),
            login: self.login_shell,
            background_opacity: self.background_opacity.clamp(0.0, 1.0),
            // Decimal MB, as Ghostty's image-storage-limit counts them.
            kitty_storage_bytes: (self.kitty_image_storage_mb.max(0) as u64) * 1000 * 1000,
            kitty_apc_bytes: (self.kitty_apc_max_mb.max(0) as usize) * 1024 * 1024,
            metrics: self.cell_metrics(),
            selection: self.selection_colors(),
            cursor_shape: self.cursor_shape,
            font_paths: self.font_paths.to_vec(),
            font_family: self.font_family.to_string(),
            font_fallbacks: self.font_fallbacks.to_vec(),
            advanced_options: self.advanced_options.clone(),
        };
        let theme = self
            .explicit_theme
            .clone()
            .unwrap_or_else(|| theme::resolve(self.in_editor(), self.scheme_pref()));
        match State::new(&spawn, theme, size, parent_canvas) {
            Ok(state) => self.state = Some(state),
            Err(e) => godot_error!("[graffitty] failed to start terminal: {e}"),
        }
        let input_ready = self.to_gd().callable("emit_signal").bind(&["input_ready".to_variant()]);
        if let Some(st) = self.state.as_mut() {
            st.scene_budget = self.render_image_budget;
            st.writer.on_input(input_ready);
        }
        self.spawn = Some(spawn);
        if self.in_editor()
            && let Some(mut settings) = EditorInterface::singleton().get_editor_settings()
        {
            settings.connect_flags(
                "settings_changed",
                &self.to_gd().callable("on_editor_settings_changed"),
                ConnectFlags::DEFERRED,
            );
        }
        let active = self.render_active;
        self.base_mut().set_process(active);
        if active {
            self.base_mut().grab_focus();
            self.base_mut().queue_redraw();
        }
    }

    /// Apply one owner scene commit to this replica.
    fn apply_scene(&mut self, mut commit: graffitty_client_core::scene::Commit) {
        let Some(st) = self.state.as_mut() else { return };
        self.awaiting_remote_scene = false;
        let output_received = !commit.text.is_empty() || commit.terminal.is_some();
        let pending = st.writer.suspend();
        if let Some(prepared) = commit.terminal.take() {
            let mut vt = prepared.adopt();
            let distance = st.vt.scrollbar().map(|b| b.total.saturating_sub(b.len).saturating_sub(b.offset)).unwrap_or(0);
            st.input.reset_tracking(&st.vt);
            st.quick_select = None;
            st.copy = None;
            st.selecting = false;
            st.render_state = RenderState::new().expect("Render state");
            let _ = vt.set_default_bg_color(Some(st.theme.bg));
            let _ = vt.set_default_fg_color(Some(st.theme.fg));
            let _ = vt.set_default_cursor_color(Some(st.theme.cursor));
            let _ = vt.set_default_color_palette(Some(VtPalette(st.theme.palette)));
            vt.scroll_viewport(ScrollViewport::Bottom);
            if distance > 0 { vt.scroll_viewport(ScrollViewport::Delta(-(distance as isize))); }
            st.vt = vt;
            st.integration = Integration::default();
            st.install_replica_callbacks();
        }
        st.geo.cols = commit.update.columns;
        st.geo.rows = commit.update.rows;
        let _ = st.vt.resize(st.geo.cols, st.geo.rows, st.geo.cell_w as u32, st.geo.cell_h as u32);
        st.shared_geo.set(st.geo.shared());
        st.geo_changed = true;
        if !commit.text.is_empty() {
            st.progress.feed(&commit.text);
            st.integration.feed(&mut st.vt, &st.writer, &commit.text, 0, false, (st.geo.cell_w as u32, st.geo.cell_h as u32));
        }
        if let Some(graphics) = commit.graphics.take() {
            st.scene_requested.retain(|key, _| graphics.images.iter().any(|image| &image.asset == key));
            st.scene_graphics = Some(graphics);
        }
        st.scene_budget = self.render_image_budget.min(commit.update.limits.storage_bytes() as usize);
        let just_exited = commit.update.exited && !st.exited;
        st.exited = commit.update.exited;
        st.integration.notification = None;
        st.integration.notification_commands.clear();
        st.writer.restore(pending);
        if output_received { st.writer.output_received(); }
        st.ui_state_dirty = true;
        st.needs_paint = true;
        st.remote_revision = st.remote_revision.wrapping_add(1);
        if just_exited {
            self.base_mut().call_deferred(
                "emit_signal",
                &["exited".to_variant(), (-1_i64).to_variant()],
            );
        }
    }

    fn apply_presentation(&mut self, data: &[u8], columns: i64, rows: i64) {
        let Some(st) = self.state.as_mut() else {
            return;
        };
        let cols = columns.clamp(1, 500) as u16;
        let rows = rows.clamp(1, 300) as u16;
        if st.geo.cols != cols || st.geo.rows != rows {
            st.geo.cols = cols;
            st.geo.rows = rows;
            let _ = st
                .vt
                .resize(cols, rows, st.geo.cell_w as u32, st.geo.cell_h as u32);
            st.shared_geo.set(st.geo.shared());
            st.geo_changed = true;
        }
        st.progress.feed(data);
        st.vt.vt_write(data);
        st.ui_state_dirty = true;
        st.needs_paint = true;
    }

    fn apply_stream(&mut self, data: &[u8], columns: i64, rows: i64, reset: bool, exited: bool) {
        let Some(st) = self.state.as_mut() else {
            return;
        };
        let pending = st.writer.suspend();
        let cols = columns.clamp(1, 500) as u16;
        let rows = rows.clamp(1, 300) as u16;
        if reset {
            st.scroll_fraction = 0.0;
            st.pending_scroll = 0.0;
            st.vt.reset();
            st.integration = Integration::default();
            st.progress = crate::progress::Progress::new();
            st.kitty_images.clear();
            // Native scene replicas keep placements and textures separately
            // from the VT image store. Reset must discard both representations.
            st.scene_graphics = None;
            st.scene_pixels.clear();
            st.scene_textures.clear();
            st.scene_requested.clear();
        }
        if st.geo.cols != cols || st.geo.rows != rows {
            st.geo.cols = cols;
            st.geo.rows = rows;
            let _ = st
                .vt
                .resize(cols, rows, st.geo.cell_w as u32, st.geo.cell_h as u32);
            st.shared_geo.set(st.geo.shared());
            st.geo_changed = true;
        }
        st.progress.feed(data);
        let pending_bell = st.bell.get();
        st.integration.feed(
            &mut st.vt,
            &st.writer,
            data,
            0,
            false,
            (st.geo.cell_w as u32, st.geo.cell_h as u32),
        );
        // Notifications travel independently, including for unsubscribed panes.
        // Preserve a queued owner bell, but do not replay BEL from the stream.
        st.bell.set(pending_bell);
        st.integration.notification = None;
        st.integration.notification_commands.clear();
        st.writer.restore(pending);
        if !data.is_empty() { st.writer.output_received(); }
        let just_exited = exited && !st.exited;
        st.exited = exited;
        st.ui_state_dirty = true;
        st.needs_paint = true;
        if just_exited {
            // Match local PTY lifecycle notifications, including a metadata-only
            // EOF frame. The stream reports exit state, but not an exit code.
            self.base_mut().call_deferred(
                "emit_signal",
                &["exited".to_variant(), (-1_i64).to_variant()],
            );
        }
    }

    /// Catch the replica up on output held while an overlay froze it: once the
    /// overlay closes, on refresh, or when too much output has piled up.
    fn apply_held(&mut self) {
        let Some(st) = self.state.as_mut() else { return };
        if st.held.is_empty() {
            st.refresh_held = false;
            return;
        }
        if st.frozen() && !st.refresh_held {
            return;
        }
        st.refresh_held = false;
        st.held_bytes = 0;
        for update in std::mem::take(&mut st.held) {
            match update {
                Held::Presentation(data, columns, rows) => {
                    self.apply_presentation(data.as_slice(), columns, rows)
                }
                Held::Stream { data, columns, rows, reset, exited } => {
                    self.apply_stream(data.as_slice(), columns, rows, reset, exited)
                }
                Held::Scene(commit) => self.apply_scene(commit),
            }
        }
        // A refresh keeps copy mode open, but only on the screen it started on.
        let Some(st) = self.state.as_mut() else { return };
        match st.copy.as_mut() {
            Some(copy) if copy.screen() == st.vt.active_screen().ok() => copy.refresh(&mut st.vt),
            Some(_) => st.end_copy(),
            None => {}
        }
    }

    /// Exported games have no EditorInterface, so editor paths must stay
    /// unreachable there even with the flag on.
    fn in_editor(&self) -> bool {
        self.run_in_editor && Engine::singleton().is_editor_hint()
    }

    /// Node property in games; the editor setting for editor terminals.
    fn scheme_pref(&self) -> i32 {
        if !self.in_editor() {
            return self.color_scheme;
        }
        EditorInterface::singleton()
            .get_editor_settings()
            .map(|s| s.get_setting(plugin::COLOR_SCHEME_SETTING))
            .and_then(|v| v.try_to::<i64>().ok())
            .map(|v| v as i32)
            .unwrap_or(theme::SCHEME_AUTO)
    }

    fn ligatures_pref(&self) -> bool {
        if !self.in_editor() {
            return self.ligatures;
        }
        EditorInterface::singleton()
            .get_editor_settings()
            .map(|s| s.get_setting(plugin::LIGATURES_SETTING))
            .and_then(|v| v.try_to::<bool>().ok())
            .unwrap_or(true)
    }

    /// Changes the text size, or hands the action to a host that owns it.
    fn font_size_action(&mut self, action: &GString) {
        if self
            .base()
            .get_signal_connection_list("shortcut_action")
            .is_empty()
        {
            let delta = match action.to_string().as_str() {
                "increase_font_size" => 1,
                "decrease_font_size" => -1,
                _ => 0,
            };
            if let Some(st) = self.state.as_mut() {
                st.adjust_font_pt(delta);
            }
        } else {
            self.base_mut().call_deferred(
                "emit_signal",
                &["shortcut_action".to_variant(), action.to_variant()],
            );
        }
    }

    fn handle_key(&mut self, key: &Gd<InputEventKey>) {
        let custom = self.use_custom_key_bindings && !self.in_editor();
        if !key.is_pressed() && self.keyboard.release(key.get_keycode().ord()) {
            self.base_mut().accept_event();
            return;
        }
        if let Some(st) = self.state.as_mut() {
            let repeat = st.font_repeat.clone();
            if !key.is_echo() {
                st.font_repeat = None;
            } else if let Some((_, action)) = repeat.filter(|(code, _)| *code == key.get_keycode().ord()) {
                self.font_size_action(&action);
                self.base_mut().accept_event();
                return;
            }
        }
        if let Some(st) = self.state.as_mut() {
            if st.modal_key(key)
                || st.navigation_key(key, !custom)
                || st.quick_select_key(key, !custom)
            {
                self.base_mut().accept_event();
                return;
            }
        }
        if custom && key.is_pressed() {
            let code = i64::from(key.get_keycode_with_modifiers().ord());
            let action = match self
                .keyboard
                .press(code, key.get_keycode().ord(), key.is_echo())
            {
                crate::bindings::Decision::Consume => {
                    self.base_mut().accept_event();
                    return;
                }
                crate::bindings::Decision::Action(action) => Some(GString::from(action.as_str())),
                crate::bindings::Decision::Pass => self
                    .key_bindings
                    .get(code)
                    .and_then(|v| v.try_to::<GString>().ok())
                    .filter(|_| self.key_condition_holds(code)),
            };
            if let Some(action) = action {
                let name = action.to_string();
                let font_action = matches!(
                    name.as_str(),
                    "increase_font_size" | "decrease_font_size" | "reset_font_size"
                );
                let handled = font_action || self.perform_action(action.clone());
                if handled {
                    if let Some(st) = self.state.as_mut() {
                        st.quick_keys.insert(key.get_keycode().ord());
                    }
                    if font_action {
                        // Holding a font-size key repeats it; reset has nothing to repeat.
                        if name != "reset_font_size" {
                            if let Some(st) = self.state.as_mut() {
                                st.font_repeat = Some((key.get_keycode().ord(), action.clone()));
                            }
                        }
                        self.font_size_action(&action);
                    }
                    self.base_mut().accept_event();
                    return;
                }
            }
        }
        // Left unconsumed so the editor's shortcut handling sees it.
        if is_editor_passthrough(key) {
            return;
        }

        if key.is_pressed() {
            if !custom && is_chord(key, GKey::C) {
                if let Some(st) = self.state.as_ref() {
                    st.copy_selection(false);
                }
                self.base_mut().accept_event();
                return;
            }
            if !custom && is_chord(key, GKey::V) {
                if let Some(st) = self.state.as_mut().filter(|st| !st.exited) {
                    st.paste_clipboard();
                    st.needs_paint = true;
                }
                self.base_mut().accept_event();
                return;
            }

            // Per-terminal zoom through the rebindable editor shortcuts.
            if self.in_editor() {
                let ev = key.clone().upcast::<InputEvent>();
                let delta = if plugin::shortcut_matches(plugin::INCREASE_FONT_SHORTCUT, &ev) {
                    Some(1)
                } else if plugin::shortcut_matches(plugin::DECREASE_FONT_SHORTCUT, &ev) {
                    Some(-1)
                } else if plugin::shortcut_matches(plugin::RESET_FONT_SHORTCUT, &ev) {
                    Some(0)
                } else {
                    None
                };
                if let Some(delta) = delta {
                    if let Some(st) = self.state.as_mut() {
                        st.adjust_font_pt(delta);
                    }
                    self.base_mut().accept_event();
                    return;
                }
            }

            // Scrollback keys. Primary screen only, so TUIs keep them.
            let shift_only = key.is_shift_pressed()
                && !key.is_ctrl_pressed()
                && !key.is_alt_pressed()
                && !key.is_meta_pressed();
            if !custom
                && shift_only
                && let Some(st) = self.state.as_mut()
            {
                if matches!(key.get_keycode(), GKey::UP | GKey::DOWN)
                    && st.vt.active_screen().ok() != Some(Screen::Alternate)
                {
                    crate::protocol::jump_prompt(
                        &mut st.vt,
                        if key.get_keycode() == GKey::UP { -1 } else { 1 },
                    );
                    st.quick_keys.insert(key.get_keycode().ord());
                    st.ui_state_dirty = true;
                    st.needs_paint = true;
                    self.base_mut().accept_event();
                    return;
                }
                let scroll = match key.get_keycode() {
                    GKey::PAGEUP => Some(ScrollViewport::Delta(-(st.geo.rows as isize))),
                    GKey::PAGEDOWN => Some(ScrollViewport::Delta(st.geo.rows as isize)),
                    GKey::HOME => Some(ScrollViewport::Top),
                    GKey::END => Some(ScrollViewport::Bottom),
                    _ => None,
                };
                if let Some(scroll) = scroll
                    && st.vt.active_screen().ok() != Some(Screen::Alternate)
                {
                    st.scroll_fraction = 0.0;
                    st.vt.scroll_viewport(scroll);
                    st.quick_keys.insert(key.get_keycode().ord());
                    st.ui_state_dirty = true;
                    st.needs_paint = true;
                    self.base_mut().accept_event();
                    return;
                }
            }
        }

        if let Some(st) = self.state.as_mut().filter(|st| !st.exited) {
            let composing = !st.preedit.is_empty();
            if std::env::var_os("GRAFFITTY_KEY_TRACE").is_some() {
                godot_print!(
                    "[key] keycode={} unicode={} pressed={} echo={} composing={} preedit={:?}",
                    key.get_keycode().ord(),
                    key.get_unicode(),
                    key.is_pressed(),
                    key.is_echo(),
                    composing,
                    st.preedit.iter().collect::<String>()
                );
            }
            if key.is_pressed() {
                st.blink_elapsed = 0.0;
                st.blink_on = true;
                st.cursor_blink_on = true;
            }
            let bytes = st.input.encode_key(&st.vt, key, composing);
            let mut typed = None;
            if !bytes.is_empty() {
                st.writer.write_key(bytes, cfg!(target_os = "macos") && key.is_pressed()
                && key.get_keycode() == GKey::NONE && key.get_physical_keycode() == GKey::NONE
                && key.get_unicode() >= 32);
                let _ = st.vt.set_selection(None);
                st.scroll_fraction = 0.0;
                st.vt.scroll_viewport(ScrollViewport::Bottom);
                st.ui_state_dirty = true;
                st.needs_paint = true;
                typed = Some(Vector2i::new(
                    i32::from(st.cursor_cell.0),
                    i32::from(st.cursor_cell.1),
                ));
            }
            if self.render_active && let Some(cell) = typed && let Some(unicode) = typing_unicode(key) {
                self.base_mut().call_deferred(
                    "emit_signal",
                    &[
                        "keystroke".to_variant(),
                        cell.to_variant(),
                        unicode.to_variant(),
                    ],
                );
            }
            self.base_mut().accept_event();
        }
    }

    fn handle_mouse_button(&mut self, btn: &Gd<InputEventMouseButton>) {
        let index = btn.get_button_index();
        let pressed = btn.is_pressed();
        let pos = btn.get_position();
        let mods = event_mods(btn.clone().upcast());
        if pressed {
            self.base_mut().grab_focus();
        }
        let Some(st) = self.state.as_mut() else {
            return;
        };
        let wheel = matches!(index, MouseButton::WHEEL_UP | MouseButton::WHEEL_DOWN);
        if st.copy.is_some() {
            // Copy mode owns the pointer: a click moves its cursor and the
            // wheel scrolls the frozen screen; nothing reaches the program.
            if pressed && index == MouseButton::LEFT {
                let (col, row) = st.cell_at(pos);
                if let Some(copy) = st.copy.as_mut() {
                    copy.place(&mut st.vt, col, row as u16);
                }
                st.needs_paint = true;
                st.ui_state_dirty = true;
            }
            self.base_mut().accept_event();
            if pressed && wheel {
                let factor = btn.get_factor() as f64;
                let up = index == MouseButton::WHEEL_UP;
                self.scroll(if up { factor } else { -factor }, false, mods, pos, None);
            }
            return;
        }
        if st.quick_select.is_some() && !wheel {
            self.base_mut().accept_event();
            return;
        }
        if !pressed && st.local_mouse_buttons.remove(&index.ord()) {
            if st.selecting && st.selection_button == index.ord() {
                st.selecting = false;
                if btn.is_canceled() {
                    // Pinch/focus cancellation is not a completed selection:
                    // clear its highlight and repeat-click state, without copying.
                    st.input.reset_tracking(&st.vt);
                    let _ = st.vt.set_selection(None);
                } else {
                    st.input
                        .selection_release(&st.vt, pos.x, pos.y, st.geo.mouse());
                    match st.options.copy_on_select.as_str() {
                        "clipboard" => st.copy_selection(false),
                        "primary" => st.copy_selection(true),
                        "both" => {
                            st.copy_selection(false);
                            st.copy_selection(true);
                        }
                        _ => {}
                    }
                }
            }
            let link = st.link_pressed.take().filter(|(uri, start, button)| {
                !btn.is_canceled() && *button == index.ord()
                    && start.distance_to(pos) < 5.0
                    && st.link_at(pos).is_some_and(|link| link.uri == *uri)
            });
            st.needs_paint = true;
            if let Some((uri, _, _)) = link {
                self.base_mut().call_deferred(
                    "activate_hyperlink",
                    &[GString::from(uri.as_str()).to_variant()],
                );
            }
            self.base_mut().accept_event();
            return;
        }
        // The configured bypass owns application mouse routing. Shift selects
        // locally only when reporting is inactive or Shift is that bypass.
        let tracking = !st.exited
            && st.vt.is_mouse_tracking().unwrap_or(false)
            && !st.options.bypasses_mouse(mods);
        let force_selection = !tracking && index == MouseButton::LEFT && mods.contains(VtMods::SHIFT);
        let mask = btn.get_modifiers_mask().ord() as i64;
        let action = if force_selection {
            Some("select".to_owned())
        } else if let Some(bindings) = &st.options.mouse_bindings {
            bindings
                .get(&(index.ord(), mask))
                .or_else(|| {
                    if st.options.bypasses_mouse(mods) {
                        bindings.get(&(index.ord(), mask & !st.options.mouse_bypass))
                    } else {
                        None
                    }
                })
                .cloned()
        } else {
            Some(
                match index {
                    MouseButton::LEFT if mods.intersects(VtMods::CTRL | VtMods::SUPER) => {
                        "open_link"
                    }
                    MouseButton::LEFT => "select",
                    MouseButton::MIDDLE => "paste_primary",
                    MouseButton::WHEEL_UP => "scroll_up",
                    MouseButton::WHEEL_DOWN => "scroll_down",
                    _ => "",
                }
                .to_owned(),
            )
        };
        if pressed && action.as_deref() == Some("open_link") {
            if let Some(link) = st.link_at(pos) {
                st.link_pressed = Some((link.uri, pos, index.ord()));
                st.local_mouse_buttons.insert(index.ord());
                self.base_mut().accept_event();
                return;
            }
        }
        // Right-click on a link to show Copy Link Address and Open, even when
        // a full-screen app tracks the mouse. Right-clicks elsewhere reach the
        // app. An explicit binding still takes priority.
        //
        // The workspace handles unmodified right-drag panning before sending a
        // completed click here. `local_mouse_buttons` consumes the release so
        // the app cannot receive half a click.
        if pressed
            && index == MouseButton::RIGHT
            && action.as_deref().is_none_or(str::is_empty)
            && let Some(link) = st.link_at(pos)
        {
            st.local_mouse_buttons.insert(index.ord());
            let web = crate::protocol::web_link(&link.uri);
            let openable = can_open_link(&link.uri, self.web_only_hyperlinks);
            self.base_mut().call_deferred(
                "emit_signal",
                &[
                    "hyperlink_context_menu_requested".to_variant(),
                    GString::from(link.uri.as_str()).to_variant(),
                    openable.to_variant(),
                    web.to_variant(),
                ],
            );
            self.base_mut().accept_event();
            return;
        }
        if tracking {
            if matches!(index, MouseButton::WHEEL_UP | MouseButton::WHEEL_DOWN) {
                if pressed {
                    self.scroll(
                        if index == MouseButton::WHEEL_UP {
                            btn.get_factor() as f64
                        } else {
                            -(btn.get_factor() as f64)
                        },
                        false,
                        mods,
                        pos,
                        None,
                    );
                }
            } else {
                let button = match index {
                    MouseButton::LEFT => Some(mouse::Button::Left),
                    MouseButton::RIGHT => Some(mouse::Button::Right),
                    MouseButton::MIDDLE => Some(mouse::Button::Middle),
                    MouseButton::XBUTTON1 => Some(mouse::Button::Eight),
                    MouseButton::XBUTTON2 => Some(mouse::Button::Nine),
                    MouseButton::WHEEL_LEFT => Some(mouse::Button::Six),
                    MouseButton::WHEEL_RIGHT => Some(mouse::Button::Seven),
                    _ => None,
                };
                // Wheel reports are presses only; side buttons retain their
                // release packets, including SGR's 128/129 button numbers.
                if let Some(button) = button.filter(|_| {
                    pressed || !matches!(index, MouseButton::WHEEL_LEFT | MouseButton::WHEEL_RIGHT)
                }) {
                    let bytes = st.input.encode_button(
                        &st.vt,
                        button,
                        pressed,
                        mods,
                        (pos.x, pos.y),
                        st.geo.mouse(),
                    );
                    st.writer.write(bytes);
                }
            }
            self.base_mut().accept_event();
            return;
        }
        if !pressed {
            return;
        }
        let Some(action) = action else {
            return;
        };
        if action.is_empty() {
            return;
        }
        match action.as_str() {
            "select" => {
                // A click opens a link on release; moving still selects text.
                st.link_pressed =
                    if index == MouseButton::LEFT && mods.is_empty() && !btn.is_double_click() {
                        st.link_at(pos).map(|link| (link.uri, pos, index.ord()))
                    } else {
                        None
                    };
                st.input
                    .selection_press(&st.vt, pos.x, pos.y, st.geo.mouse());
                st.selecting = true;
                st.selection_button = index.ord();
                st.needs_paint = true;
                st.local_mouse_buttons.insert(index.ord());
            }
            "paste_primary" => {
                if !st.exited
                    && DisplayServer::singleton().has_feature(DisplayFeature::CLIPBOARD_PRIMARY)
                {
                    st.paste_str(
                        &DisplayServer::singleton()
                            .clipboard_get_primary()
                            .to_string(),
                    );
                }
                st.local_mouse_buttons.insert(index.ord());
            }
            "scroll_up" | "scroll_down" => {
                self.scroll(
                    if action == "scroll_up" {
                        btn.get_factor() as f64
                    } else {
                        -(btn.get_factor() as f64)
                    },
                    false,
                    mods,
                    pos,
                    None,
                );
            }
            "open_link" => return,
            _ => {
                st.local_mouse_buttons.insert(index.ord());
                self.perform_action(GString::from(action.as_str()));
            }
        }
        self.base_mut().accept_event();
    }

    /// Scroll by pixels (precision) or wheel ticks, positive up: mouse
    /// reporting, alternate scroll, or the viewport, like ghostty.
    ///
    /// `gesture` carries the phases of a precision touchpad or touch scroll.
    /// Only those can pull the content past an edge; a wheel has no release.
    ///
    /// Returns whether the scroll had an effect: it moved or pulled the rows,
    /// or went to the application. Like Chromium's unconsumed fling update,
    /// `false` tells a fling it has run into an end and should stop.
    fn scroll(&mut self, yoff: f64, precision: bool, mods: VtMods, pos: Vector2, gesture: Option<ScrollGesture>) -> bool {
        let now = clock();
        if let (Some(gesture), Some(st)) = (gesture, self.state.as_mut()) {
            st.gesture_began(gesture);
        }
        let scrolled = self.scroll_by(yoff, precision, mods, pos, gesture.map(|gesture| (gesture.momentum, gesture.time.unwrap_or(now))));
        if let (Some(gesture), Some(st)) = (gesture, self.state.as_mut()) {
            st.gesture_ended(gesture, now);
        }
        scrolled
    }

    fn scroll_by(&mut self, yoff: f64, precision: bool, mods: VtMods, pos: Vector2, phased: Option<(bool, f64)>) -> bool {
        if !yoff.is_finite() || yoff == 0.0 {
            return true;
        }
        let Some(st) = self.state.as_mut() else {
            return true;
        };

        st.ui_state_dirty = true;
        let cell = f64::from(st.geo.cell_h).max(1.0);
        let adjusted = if precision {
            yoff
        } else {
            // Undo Godot's 0.3 wheel scale and ramp slow fractional notches to a full tick.
            let ticks = if cfg!(target_os = "macos") {
                let raw = yoff / 0.3;
                raw.signum() * raw.abs().max(1.0)
            } else {
                yoff
            };
            ticks * cell * SCROLL_LINES
        };

        let overlay = st.quick_select.is_some() || st.copy.is_some();
        let tracking = !overlay
            && !st.exited
            && st.vt.is_mouse_tracking().unwrap_or(false)
            && !st.options.bypasses_mouse(mods);
        let alt_scroll = !overlay
            && !st.exited
            && st.vt.active_screen().ok() == Some(Screen::Alternate)
            && st.vt.mode(Mode::ALT_SCROLL).unwrap_or(false)
            && !st.options.bypasses_mouse(mods);

        let now = std::time::Instant::now();
        let fresh = st
            .last_scroll
            .is_none_or(|last| now.duration_since(last).as_millis() >= 250);
        st.last_scroll = Some(now);
        if precision && st.smooth_scroll_allowed() {
            if let Ok(bar) = st.vt.scrollbar() {
                let rows = yoff * st.options.scroll_multiplier / PIXELS_PER_ROW;
                let max = bar.total.saturating_sub(bar.len) as usize;
                let (from, pulled) = (bar.offset as f64 + st.scroll_fraction, st.elastic.elastic.stretch());
                let (mut top, mut fraction, unused) =
                    crate::scroll::position(bar.offset as usize, st.scroll_fraction, rows, max);
                if let Some((momentum, time)) = phased {
                    let scroller = Scroller {
                        offset: (top as f64 + fraction) * PIXELS_PER_ROW,
                        max: max as f64 * PIXELS_PER_ROW,
                        bounds: f64::from(st.geo.rows) * PIXELS_PER_ROW,
                    };
                    st.elastic.elastic.update(-rows * PIXELS_PER_ROW, unused * PIXELS_PER_ROW, time, clock(), momentum, scroller);
                    // Scrolling away from a pulled edge first lets the pull go.
                    let back = st.elastic.elastic.reconcile(scroller);
                    if back != 0.0 {
                        (top, fraction, _) = crate::scroll::position(top, fraction, back / PIXELS_PER_ROW, max);
                    }
                }
                st.vt.scroll_viewport(ScrollViewport::Row(top));
                st.scroll_fraction = fraction;
                st.pending_scroll = 0.0;
                st.needs_paint = true;
                st.since_repaint = REPAINT_MIN_SECS;
                return top as f64 + fraction != from || st.elastic.elastic.stretch() != pulled;
            }
            return true;
        }
        st.scroll_fraction = 0.0;
        let adjusted = if precision {
            yoff * cell / PIXELS_PER_ROW
        } else {
            adjusted
        };
        let movement = adjusted * st.options.scroll_multiplier;
        if fresh || movement.signum() != st.pending_scroll.signum() {
            st.pending_scroll = 0.0;
        }
        let poff = st.pending_scroll + movement;
        let lines = if precision && fresh && poff != 0.0 && poff.abs() < cell {
            poff.signum()
        } else {
            (poff / cell).trunc()
        };
        st.pending_scroll = if precision && fresh && poff.abs() < cell {
            0.0
        } else {
            poff - lines * cell
        };
        if lines == 0.0 {
            return true;
        }
        st.since_repaint = REPAINT_MIN_SECS;

        if tracking {
            let _ = st.vt.set_selection(None);
            let geo = st.geo.mouse();
            for _ in 0..lines.abs() as usize {
                let bytes = st
                    .input
                    .encode_scroll(&st.vt, lines > 0.0, mods, (pos.x, pos.y), geo);
                st.writer.write(bytes);
            }
        } else if alt_scroll {
            let _ = st.vt.set_selection(None);
            let app_keys = st.vt.mode(Mode::DECCKM).unwrap_or(false);
            let seq: &[u8] = match (app_keys, lines > 0.0) {
                (true, true) => b"\x1bOA",
                (true, false) => b"\x1bOB",
                (false, true) => b"\x1b[A",
                (false, false) => b"\x1b[B",
            };
            for _ in 0..lines.abs() as usize {
                st.writer.write(seq);
            }
        } else if let Some(copy) = st.copy.as_mut() {
            copy.scroll_view(&mut st.vt, -(lines as i64));
        } else {
            let before = st.vt.scrollbar().ok().map(|bar| bar.offset);
            st.vt
                .scroll_viewport(ScrollViewport::Delta(-(lines as isize)));
            st.needs_paint = true;
            return st.vt.scrollbar().ok().map(|bar| bar.offset) != before;
        }
        st.needs_paint = true;
        true
    }

    /// macOS and Wayland deliver trackpad scrolling as pan gestures rather
    /// than wheel buttons.
    fn handle_pan(&mut self, pan: &Gd<InputEventPanGesture>) {
        let mods = event_mods(pan.clone().upcast());
        // A finger moves the rows exactly as far as it travelled, as Chromium
        // moves a page: its travel (in this terminal's pixels) over the row
        // height, expressed in the scroll's 15-pixels-per-row units. Trackpads
        // keep the precision-device distance.
        let travel = pan.has_meta("touch_travel").then(|| pan.get_meta("touch_travel").try_to::<Vector2>().ok()).flatten();
        let yoff = match (travel, self.state.as_ref()) {
            (Some(travel), Some(st)) if st.geo.cell_h > 0.0 => {
                f64::from(travel.y) / f64::from(st.geo.cell_h) * PIXELS_PER_ROW / st.options.scroll_multiplier.max(1e-6)
            }
            _ => f64::from(-pan.get_delta().y) * PAN_TO_PIXELS,
        };
        let gesture = self.pan_gesture(pan);
        let scrolled = self.scroll(yoff, true, mods, pan.get_position(), gesture);
        // The touch recognizer asks whether its fling update scrolled; one
        // that scrolled nothing ran into an end, and the fling stops there.
        if pan.has_meta("touch_scroll_sequence") {
            let sequence = pan.get_meta("touch_scroll_sequence").try_to::<i64>().unwrap_or(-1);
            if let Some(st) = self.state.as_mut() {
                st.touch_scrolled = Some((sequence, scrolled));
            }
        }
        self.base_mut().accept_event();
    }

    /// The scroll phases a pan gesture carries, where the platform reports them.
    fn pan_gesture(&mut self, pan: &Gd<InputEventPanGesture>) -> Option<ScrollGesture> {
        self.state.as_mut().and_then(|st| st.pan_phases.read(pan, &st.elastic))
    }

    fn handle_mouse_motion(&mut self, motion: &Gd<InputEventMouseMotion>) {
        if self
            .state
            .as_ref()
            .is_some_and(|s| s.quick_select.is_some())
        {
            self.base_mut().accept_event();
            return;
        }
        let pos = motion.get_position();
        if let Some(st) = self.state.as_mut() {
            if st
                .link_pressed
                .as_ref()
                .is_some_and(|(_, start, _)| start.distance_to(pos) >= 5.0)
            {
                st.link_pressed = None;
            }
            st.update_hover(st.link_at(pos));
            let tooltip =
                GString::from(st.hover_link.as_ref().map_or("", |link| link.uri.as_str()));
            let pointer = if st.hover_link.is_some() {
                godot::classes::control::CursorShape::POINTING_HAND
            } else {
                pointer_shape(
                    st.integration
                        .pointers
                        .current(st.vt.active_screen().ok() == Some(Screen::Alternate)),
                )
            };
            self.base_mut().set_tooltip_text(&tooltip);
            self.base_mut().set_default_cursor_shape(pointer);
        }
        let mods = event_mods(motion.clone().upcast());
        let mask = motion.get_button_mask().ord();

        if let Some(st) = self.state.as_mut() {
            let geo = st.geo.mouse();
            if st.selecting {
                st.input
                    .selection_drag(&st.vt, pos.x, pos.y, mods.contains(VtMods::ALT), geo);
                st.needs_paint = true;
            } else if !st.exited
                && st.vt.is_mouse_tracking().unwrap_or(false)
                && !st.options.bypasses_mouse(mods)
            {
                let held = if mask & MouseButtonMask::LEFT.ord() != 0 {
                    Some(mouse::Button::Left)
                } else if mask & MouseButtonMask::RIGHT.ord() != 0 {
                    Some(mouse::Button::Right)
                } else if mask & MouseButtonMask::MIDDLE.ord() != 0 {
                    Some(mouse::Button::Middle)
                } else {
                    None
                };
                let bytes = st
                    .input
                    .encode_motion(&st.vt, held, mods, (pos.x, pos.y), geo);
                st.writer.write(bytes);
            }
        }
    }
}

/// Grid geometry derived from the font metrics and control size.
#[derive(Clone, Copy)]
struct Geometry {
    /// Kept here because fit(), the hit test and every draw need it, and it is
    /// per-terminal now rather than a constant.
    pad: f32,
    cell_w: f32,
    cell_h: f32,
    ascent: f32,
    /// Base stroke width for sprites, underlines and cursors: the font's
    /// underline thickness. Whole pixels.
    thick: f32,
    /// Underline offset from the cell top, from the font metrics.
    underline: f32,
    cols: u16,
    rows: u16,
    width: f32,
    height: f32,
}

impl Geometry {
    fn fit(&mut self, size: Vector2) {
        self.width = size.x;
        self.height = size.y;
        self.cols = (((size.x - 2.0 * self.pad) / self.cell_w).floor()).max(1.0) as u16;
        self.rows = (((size.y - 2.0 * self.pad) / self.cell_h).floor()).max(1.0) as u16;
    }

    fn shared(&self) -> SharedGeo {
        SharedGeo {
            cols: self.cols,
            rows: self.rows,
            cell_w: self.cell_w as u32,
            cell_h: self.cell_h as u32,
        }
    }

    fn mouse(&self) -> MouseGeometry {
        MouseGeometry {
            screen_width: self.width as u32,
            screen_height: self.height as u32,
            cell_width: self.cell_w as u32,
            cell_height: self.cell_h as u32,
            padding: self.pad as u32,
        }
    }
}

/// Cell geometry from the font metrics at `font_size`, before fit().
/// Integral metrics; the mouse encoder and gestures take integer px.
fn measure(fonts: &Fonts, font_size: i32, metrics: CellMetrics) -> Result<Geometry, String> {
    let primary = fonts.primary();
    let advance = primary.get_char_size('M' as u32, font_size).x;
    let line = primary.get_height_ex().font_size(font_size).done();
    let cell_w = (advance * metrics.column_width.max(0.1)).ceil();
    let cell_h = (line * metrics.line_height.max(0.1)).ceil();
    // A taller line box grows around the glyph, not under it, so the baseline
    // takes half the extra room. Otherwise the text sticks to the cell's top.
    let ascent =
        (primary.get_ascent_ex().font_size(font_size).done() + (cell_h - line) * 0.5).round();
    let thick = primary
        .get_underline_thickness_ex()
        .font_size(font_size)
        .done()
        .round()
        .max(1.0);
    let underline = primary
        .get_underline_position_ex()
        .font_size(font_size)
        .done();
    if cell_w <= 0.0 || cell_h <= 0.0 {
        return Err("font produced zero cell size".into());
    }
    Ok(Geometry {
        pad: metrics.pad,
        cell_w,
        cell_h,
        ascent,
        thick,
        underline: (ascent + underline).round(),
        cols: 0,
        rows: 0,
        width: 0.0,
        height: 0.0,
    })
}

#[derive(Clone, Copy)]
struct SharedGeo {
    cols: u16,
    rows: u16,
    cell_w: u32,
    cell_h: u32,
}

/// Node configuration resolved at spawn time. `font_size` is the base pt,
/// `scale` the editor display scale applied on top. Kept on the node so
/// respawn() can start the same shell again without rebuilding it.
#[derive(Clone)]
struct Spawn {
    remote: bool,
    font_size: i32,
    scale: f32,
    ligatures: bool,
    scrollback: u32,
    shell: String,
    environment: HashMap<String, String>,
    cwd: PathBuf,
    login: bool,
    background_opacity: f32,
    kitty_storage_bytes: u64,
    kitty_apc_bytes: usize,
    metrics: CellMetrics,
    selection: crate::selection::SelectionColors,
    cursor_shape: i32,
    font_paths: Vec<GString>,
    font_family: String,
    font_fallbacks: Vec<GString>,
    advanced_options: crate::options::Options,
}

fn resolve_cwd(configured: &str) -> PathBuf {
    let globalize =
        |p: &str| PathBuf::from(ProjectSettings::singleton().globalize_path(p).to_string());
    if !configured.is_empty() {
        let path = globalize(configured);
        if path.is_dir() {
            return path;
        }
        godot_warn!("[graffitty] working_directory {configured} does not exist, using default");
    }
    let project = globalize("res://");
    if project.is_dir() {
        return project;
    }
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."))
}

/// An owner update that arrived while an overlay froze the screen.
enum Held {
    Presentation(PackedByteArray, i64, i64),
    Stream {
        data: PackedByteArray,
        columns: i64,
        rows: i64,
        reset: bool,
        exited: bool,
    },
    Scene(graffitty_client_core::scene::Commit),
}

/// Held output beyond this is applied even while frozen, so a long copy-mode
/// session over a busy program cannot grow without bound.
const HELD_LIMIT: usize = 64 * 1024 * 1024;

struct State {
    quick_select: Option<crate::quick_select::QuickSelect>,
    options: crate::options::Options,
    visual_bell_remaining: f64,
    cursor_blink_on: bool,
    quick_keys: std::collections::HashSet<i32>,
    /// The held key that keeps changing the text size, with its action.
    font_repeat: Option<(i32, GString)>,
    /// Vi copy mode (and its search prompt) while open.
    copy: Option<CopyMode>,
    /// Text copy mode copied, announced by the next process().
    copied: Option<String>,
    /// Owner updates waiting while `frozen()`, applied in order by `apply_held`.
    held: Vec<Held>,
    held_bytes: usize,
    /// Apply held output without closing the overlay (copy mode `r`).
    refresh_held: bool,
    integration: Integration,
    clipboard_write_enabled: Rc<Cell<bool>>,
    attachment: Option<Result<graffitty_client_core::clipboard_paste::Attachment, String>>,
    attachment_busy: bool,
    attachment_prefix: Vec<u8>,
    sync_elapsed: f64,
    blink_elapsed: f64,
    blink_on: bool,
    cursor_blinks: bool,
    text_blinks: bool,
    hover_link: Option<crate::protocol::HyperlinkMatch>,
    hover_position: Option<Vector2>,
    link_pressed: Option<(String, Vector2, i32)>,
    progress: crate::progress::Progress,
    vt: Vt<'static, 'static>,
    pty: Pty,
    writer: Writer,
    input: Input,
    render_state: RenderState<'static>,
    rows: RowIterator<'static>,
    cells: CellIterator<'static>,
    fonts: Rc<Fonts>,
    server_font: bool,
    font_size: i32,
    base_pt: i32,
    spawn_pt: i32,
    scale: f32,
    ligatures: bool,
    runs: RunCache,
    geo: Geometry,
    shared_geo: Rc<Cell<SharedGeo>>,
    bell: Rc<Cell<bool>>,
    theme: Theme,
    scheme: Rc<Cell<ColorScheme>>,
    exited: bool,
    eof: bool,
    selecting: bool,
    selection_button: i32,
    local_mouse_buttons: std::collections::HashSet<i32>,
    pending_scroll: f64,
    scroll_fraction: f64,
    /// The rubber band past either end of the scrollback.
    elastic: ElasticGesture,
    pan_phases: PanPhases,
    /// The last touch scroll update (its sequence) and whether it scrolled.
    touch_scrolled: Option<(i64, bool)>,
    last_scroll: Option<std::time::Instant>,
    autoscroll_accum: f64,
    focused: bool,
    win_focused: bool,
    reported_focus: bool,
    title: String,
    /// Viewport cell the cursor last painted at, and whether it was visible.
    /// Cached from repaint() so callers can read it without driving the vt.
    cursor_cell: (u16, u16),
    visible_area: graffitty_terminal_core::visible_area::Tracker,
    cursor_on: bool,
    cursor_render_rect: Rect2,
    cursor_render_color: Color,
    /// Set when repaint() moved the cursor or the grid reflowed, so process()
    /// can turn them into signals without polling anything.
    cursor_changed: bool,
    geo_changed: bool,
    /// Draw the current IME composition at the cursor. The input method owns
    /// this text. It enters the terminal grid only when the IME commits it.
    preedit: Vec<char>,
    /// Half-open range of `preedit` being composed right now, which is the part
    /// that carries the rule. The rest is settled and reads as plain text.
    preedit_mark: (usize, usize),
    canvas_bg: Rid,
    canvas_fg: Rid,
    /// Kitty graphics images live on their own canvas items so the protocol's
    /// z can be honoured: z < 0 goes under the glyphs, z >= 0 over them.
    canvas_img_below: Rid,
    canvas_img_above: Rid,
    canvas_quick: Rid,
    /// Decoded images, by image id. The vt owns the bytes; this owns the
    /// texture made from them.
    kitty_images: HashMap<u32, (u64, Gd<ImageTexture>)>,
    image_material: Option<Gd<godot::classes::ShaderMaterial>>,
    scene_graphics: Option<graffitty_protocol::terminal_scene::Graphics>,
    scene_pixels: HashMap<graffitty_protocol::terminal_scene::AssetKey, graffitty_client_core::scene::Pixels>,
    scene_textures: HashMap<graffitty_protocol::terminal_scene::AssetKey, (Gd<godot::classes::Texture2D>, usize, u64)>,
    scene_requested: HashMap<graffitty_protocol::terminal_scene::AssetKey, std::time::Instant>,
    scene_uploads: u64,
    scene_imports: u64,
    scene_budget: usize,
    bg: Color,
    bg_opacity: f32,
    metrics: CellMetrics,
    /// Independent foreground/background overrides; both unset means swap.
    selection: crate::selection::SelectionColors,
    cursor_shape: i32,
    remote_revision: u64,
    needs_paint: bool,
    /// Semantic invalidation is separate from repainting (blink, selection, IME).
    /// Remains observable while hidden, without repeatedly querying the VT.
    ui_state_dirty: bool,
    pixel_grid: PixelGrid,
    raster_scale: f32,
    since_repaint: f64,
    pending_size: Option<Vector2>,
    settle: f64,
}

impl Drop for State {
    fn drop(&mut self) {
        let mut rs = RenderingServer::singleton();
        rs.free_rid(self.canvas_quick);
        rs.free_rid(self.canvas_img_above);
        rs.free_rid(self.canvas_img_below);
        rs.free_rid(self.canvas_fg);
        rs.free_rid(self.canvas_bg);
    }
}

impl State {
    /// Copy mode, search and Quick Select read a still screen, as tmux copy
    /// mode does. The owner keeps running the program and answering its
    /// queries; only this replica waits.
    fn frozen(&self) -> bool {
        self.copy.is_some() || self.quick_select.is_some()
    }

    /// Updates also wait behind ones already held, so they apply in order.
    fn holds(&self) -> bool {
        self.frozen() || !self.held.is_empty()
    }

    fn hold(&mut self, update: Held) {
        // Rough per-update overhead; an adopted terminal carries a full screen.
        self.held_bytes += 256
            + match &update {
                Held::Presentation(data, ..) | Held::Stream { data, .. } => data.len(),
                Held::Scene(commit) => {
                    commit.text.len() + if commit.terminal.is_some() { 1 << 20 } else { 0 }
                }
            };
        if self.held_bytes > HELD_LIMIT {
            self.refresh_held = true;
        }
        if self.held.is_empty() {
            // The status line reports waiting output.
            self.ui_state_dirty = true;
            self.needs_paint = true;
        }
        self.held.push(update);
    }

    fn modal_mode(&self) -> Option<&'static str> {
        if self.quick_select.is_some() {
            Some("quick_select")
        } else if let Some(copy) = &self.copy {
            Some(if copy.wants_text() { "search" } else { "copy_mode" })
        } else {
            None
        }
    }

    fn link_at(&self, pos: Vector2) -> Option<crate::protocol::HyperlinkMatch> {
        let bounds = Rect2::new(Vector2::splat(self.geo.pad), Vector2::new(
            f32::from(self.geo.cols) * self.geo.cell_w, f32::from(self.geo.rows) * self.geo.cell_h));
        if !self.pixel_grid.rect(bounds).contains_point(pos) {
            return None;
        }
        let (x, y) = self.cell_at(pos);
        crate::protocol::hyperlink_match(&self.vt, x, y, &self.options.hyperlinks)
    }

    fn refresh_hover(&mut self) {
        let link = self.hover_position.and_then(|pos| {
            self.link_at(pos + Vector2::new(0.0, self.scroll_fraction as f32 * self.geo.cell_h))
        });
        self.update_hover(link);
    }

    fn update_hover(&mut self, link: Option<crate::protocol::HyperlinkMatch>) {
        if self.hover_link != link {
            self.hover_link = link;
            self.needs_paint = true;
        }
    }

    fn cell_at(&self, pos: Vector2) -> (u16, u32) {
        let cell = self.pixel_grid.cell(pos, self.geo.pad, Vector2::new(self.geo.cell_w, self.geo.cell_h));
        (
            cell.x.clamp(0.0, self.geo.cols.saturating_sub(1) as f32) as u16,
            cell.y.clamp(0.0, self.geo.rows.saturating_sub(1) as f32) as u32,
        )
    }
    fn new(spawn: &Spawn, theme: Theme, size: Vector2, parent_canvas: Rid) -> Result<Self, String> {
        let fonts = Fonts::configured(
            &spawn.font_paths,
            &spawn.font_family,
            &spawn.font_fallbacks,
            &spawn.advanced_options,
        )?;
        let font_size = ((spawn.font_size as f32) * spawn.scale).round().max(2.0) as i32;
        let mut geo = measure(&fonts, font_size, spawn.metrics)?;
        geo.fit(size);

        let pty = Pty::remote();
        let writer = pty.writer();

        let shared_geo = Rc::new(Cell::new(geo.shared()));
        let bell = Rc::new(Cell::new(false));

        let mut vt = graffitty_terminal_core::new_vt(geo.cols, geo.rows, spawn.scrollback as usize)
        .map_err(|e| format!("terminal: {e}"))?;
        vt.resize(geo.cols, geo.rows, geo.cell_w as u32, geo.cell_h as u32)
            .map_err(|e| format!("terminal resize: {e}"))?;
        install_vt_log();
        install_png_decoder();
        if spawn.remote {
            // External image transports belong to the server's filesystem.
            // It resolves them to inline pixels before sending remote state.
            vt.set_kitty_image_from_file_allowed(false)
                .map_err(|e| e.to_string())?;
            vt.set_kitty_image_temp_file_dir(None)
                .map_err(|e| e.to_string())?;
            vt.set_kitty_image_from_shared_mem_allowed(false)
                .map_err(|e| e.to_string())?;
        }
        // Zero is the library default and it means OFF: the vt stores no images
        // until its embedder budgets the memory for them.
        if spawn.kitty_storage_bytes > 0
            && let Err(e) = vt.set_kitty_image_storage_limit(spawn.kitty_storage_bytes)
        {
            godot_warn!("[graffitty] kitty image storage unavailable: {e}");
        }
        if spawn.kitty_apc_bytes > 0 {
            // Two knobs, and the kitty one alone is not enough: with only it
            // raised, a 400 KiB payload still vanished and a second image
            // after a first never arrived at all.
            //
            // The generic APC budget is the one that was running out.
            if let Err(e) = vt.set_apc_max_bytes(Some(spawn.kitty_apc_bytes)) {
                godot_warn!("[graffitty] apc limit unavailable: {e}");
            }
            if let Err(e) = vt.set_apc_max_bytes_kitty(Some(spawn.kitty_apc_bytes)) {
                godot_warn!("[graffitty] kitty apc limit unavailable: {e}");
            }
        }

        vt.set_default_bg_color(Some(theme.bg))
            .and_then(|vt| vt.set_default_fg_color(Some(theme.fg)))
            .and_then(|vt| vt.set_default_cursor_color(Some(theme.cursor)))
            .and_then(|vt| vt.set_default_color_palette(Some(VtPalette(theme.palette))))
            .map_err(|e| format!("theme: {e}"))?;
        let scheme = Rc::new(Cell::new(theme.scheme));
        let sc = scheme.clone();
        vt.on_color_scheme(move |_t| Some(sc.get()))
            .map_err(|e| format!("effect: {e}"))?;

        let w = writer.clone();
        vt.on_pty_write(move |_t, data| w.write(data))
            .map_err(|e| format!("effect: {e}"))?;
        let sg = shared_geo.clone();
        vt.on_size(move |_t| {
            let g = sg.get();
            Some(SizeReportSize {
                rows: g.rows,
                columns: g.cols,
                cell_width: g.cell_w,
                cell_height: g.cell_h,
            })
        })
        .map_err(|e| format!("effect: {e}"))?;
        vt.on_device_attributes(|_t| {
            Some(DeviceAttributes {
                primary: PrimaryDeviceAttributes::new(
                    ConformanceLevel::VT220,
                    &[
                        DeviceAttributeFeature::COLUMNS_132,
                        DeviceAttributeFeature::SELECTIVE_ERASE,
                        DeviceAttributeFeature::ANSI_COLOR,
                        DeviceAttributeFeature::SIXEL,
                    ],
                ),
                secondary: SecondaryDeviceAttributes {
                    device_type: DeviceType::VT220,
                    firmware_version: 1,
                    rom_cartridge: 0,
                },
                tertiary: Default::default(),
            })
        })
        .map_err(|e| format!("effect: {e}"))?;
        vt.on_xtversion(|_t| Some("graffitty"))
            .map_err(|e| format!("effect: {e}"))?;
        let ev = bell.clone();
        vt.on_bell(move |_t| ev.set(true))
            .map_err(|e| format!("effect: {e}"))?;

        let clipboard_write_enabled = Rc::new(Cell::new(false));
        let allow_write = clipboard_write_enabled.clone();
        vt.on_clipboard_write(move |_vt, request| {
            use libghostty_vt::terminal::{ClipboardLocation, ClipboardWriteError};
            let result = (|| {
            if !allow_write.get() {
                return Err(ClipboardWriteError::Denied);
            }
            let mut contents = request.contents();
            let text = if contents.len() == 0 {
                ""
            } else {
                let data = contents
                    .find(|c| c.mime == b"text/plain" || c.mime.starts_with(b"text/plain;"))
                    .ok_or(ClipboardWriteError::Unsupported)?
                    .data;
                std::str::from_utf8(data).map_err(|_| ClipboardWriteError::InvalidData)?
            };
            if text.len() > 1024 * 1024 {
                return Err(ClipboardWriteError::InvalidData);
            }
            let mut ds = DisplayServer::singleton();
            if request.location() == ClipboardLocation::Standard {
                ds.clipboard_set(text);
            } else if ds.has_feature(DisplayFeature::CLIPBOARD_PRIMARY) {
                ds.clipboard_set_primary(text);
            } else {
                ds.clipboard_set(text);
            }
            Ok(())
            })();
            // Ghostty 521cf2c answers writes through the request (OSC 5522 acks).
            request.reply(result, false);
        })
        .map_err(|e| format!("clipboard: {e}"))?;

        let mut input = Input::new().map_err(|e| format!("input: {e}"))?;
        input.set_word_boundaries(spawn.advanced_options.word_boundaries.as_deref());
        let render_state = RenderState::new().map_err(|e| format!("render: {e}"))?;
        let rows = RowIterator::new().map_err(|e| format!("render: {e}"))?;
        let cells = CellIterator::new().map_err(|e| format!("render: {e}"))?;

        // A parent's own commands draw before its children, so backgrounds
        // sit below glyph ink, which may overflow its cell.
        let mut rs = RenderingServer::singleton();
        let canvas_bg = rs.canvas_item_create();
        rs.canvas_item_set_parent(canvas_bg, parent_canvas);
        rs.canvas_item_set_visibility_layer(canvas_bg, 1 << 17);
        // Siblings of the glyph layer, ordered around it by z index.
        let canvas_img_below = rs.canvas_item_create();
        rs.canvas_item_set_parent(canvas_img_below, parent_canvas);
        rs.canvas_item_set_visibility_layer(canvas_img_below, 1 << 19);
        rs.canvas_item_set_z_index(canvas_img_below, 1);
        let canvas_fg = rs.canvas_item_create();
        rs.canvas_item_set_parent(canvas_fg, parent_canvas);
        rs.canvas_item_set_visibility_layer(canvas_fg, 1 << 18);
        rs.canvas_item_set_z_index(canvas_fg, 2);
        let canvas_img_above = rs.canvas_item_create();
        rs.canvas_item_set_parent(canvas_img_above, parent_canvas);
        rs.canvas_item_set_visibility_layer(canvas_img_above, 1 << 19);
        rs.canvas_item_set_z_index(canvas_img_above, 3);
        let canvas_quick = rs.canvas_item_create();
        rs.canvas_item_set_parent(canvas_quick, parent_canvas);
        rs.canvas_item_set_visibility_layer(canvas_quick, 1 << 18);
        rs.canvas_item_set_z_index(canvas_quick, 4);

        Ok(Self {
            quick_select: None,
            options: spawn.advanced_options.clone(),
            visual_bell_remaining: 0.0,
            cursor_blink_on: true,
            quick_keys: Default::default(),
            font_repeat: None,
            copy: None,
            copied: None,
            held: Vec::new(),
            held_bytes: 0,
            refresh_held: false,
            integration: Integration::default(),
            clipboard_write_enabled,
            attachment: None,
            attachment_busy: false,
            attachment_prefix: Vec::new(),
            sync_elapsed: 0.0,
            blink_elapsed: 0.0,
            blink_on: true,
            cursor_blinks: false,
            text_blinks: false,
            hover_link: None,
            hover_position: None,
            link_pressed: None,
            progress: crate::progress::Progress::new(),
            vt,
            pty,
            writer,
            input,
            render_state,
            rows,
            cells,
            fonts,
            server_font: false,
            font_size,
            base_pt: spawn.font_size,
            spawn_pt: spawn.font_size,
            scale: spawn.scale,
            ligatures: spawn.ligatures,
            runs: RunCache::new(),
            geo,
            shared_geo,
            bell,
            exited: false,
            eof: false,
            selecting: false,
            selection_button: MouseButton::LEFT.ord(),
            local_mouse_buttons: Default::default(),
            pending_scroll: 0.0,
            scroll_fraction: 0.0,
            elastic: ElasticGesture::new(ElasticConfig::terminal()),
            pan_phases: PanPhases::default(),
            touch_scrolled: None,
            last_scroll: None,
            autoscroll_accum: 0.0,
            focused: false,
            win_focused: true,
            reported_focus: false,
            title: String::new(),
            cursor_cell: (0, 0),
            visible_area: Default::default(),
            cursor_on: false,
            cursor_render_rect: Rect2::new(Vector2::ZERO, Vector2::ONE),
            cursor_render_color: Color::WHITE,
            cursor_changed: false,
            geo_changed: false,
            preedit: Vec::new(),
            preedit_mark: (0, 0),
            canvas_bg,
            canvas_fg,
            canvas_img_below,
            canvas_img_above,
            canvas_quick,
            kitty_images: HashMap::new(),
            image_material: None,
            scene_graphics: None,
            scene_pixels: HashMap::new(),
            scene_textures: HashMap::new(),
            scene_requested: HashMap::new(),
            scene_uploads: 0,
            scene_imports: 0,
            scene_budget: spawn.kitty_storage_bytes as usize,
            bg: color(theme.bg),
            bg_opacity: spawn.background_opacity,
            metrics: spawn.metrics,
            selection: spawn.selection,
            cursor_shape: spawn.cursor_shape,
            theme,
            scheme,
            remote_revision: 1,
            needs_paint: true,
            ui_state_dirty: true,
            pixel_grid: PixelGrid::default(),
            raster_scale: 1.0,
            since_repaint: REPAINT_MIN_SECS,
            pending_size: None,
            settle: 0.0,
        })
    }

    fn perform_action(&mut self, action: &str) -> bool {
        if let Some(text) = action.strip_prefix("send_text:") {
            if !self.exited {
                self.writer.write(text.as_bytes());
            }
            return true;
        }
        match action {
            "search" => self.start_copy(true),
            "copy_mode" => self.start_copy(false),
            "quick_select" => {
                self.end_copy();
                self.quick_select = self.make_quick_select().ok();
                self.selecting = false;
                let _ = self.vt.set_selection(None);
            }
            "copy_last_output" => {
                if crate::navigation::last_output(&mut self.vt) {
                    self.copy_selection(false);
                }
            }
            "copy" => match self.copy.as_mut() {
                Some(copy) => {
                    if let Some(text) = copy.copy_text(&mut self.vt) {
                        DisplayServer::singleton().clipboard_set(text.as_str());
                        self.copied = Some(text);
                    }
                }
                None => self.copy_selection(false),
            },
            "paste" => {
                if self.exited {
                    return false;
                }
                self.paste_clipboard();
            }
            "previous_prompt" | "next_prompt" | "scroll_page_up" | "scroll_page_down"
            | "scroll_top" | "scroll_bottom" => {
                if self.vt.active_screen().ok() == Some(Screen::Alternate) {
                    return false;
                }
                self.scroll_fraction = 0.0;
                match action {
                    "previous_prompt" => {
                        crate::protocol::jump_prompt(&mut self.vt, -1);
                    }
                    "next_prompt" => {
                        crate::protocol::jump_prompt(&mut self.vt, 1);
                    }
                    "scroll_page_up" => self
                        .vt
                        .scroll_viewport(ScrollViewport::Delta(-(self.geo.rows as isize))),
                    "scroll_page_down" => self
                        .vt
                        .scroll_viewport(ScrollViewport::Delta(self.geo.rows as isize)),
                    "scroll_top" => self.vt.scroll_viewport(ScrollViewport::Top),
                    _ => self.vt.scroll_viewport(ScrollViewport::Bottom),
                }
            }
            "ignore" => {}
            _ => return false,
        }
        self.ui_state_dirty = true;
        self.needs_paint = true;
        true
    }

    /// Open copy mode at the terminal cursor; `search` starts at the `/` prompt.
    fn start_copy(&mut self, search: bool) {
        self.quick_select = None;
        self.selecting = false;
        let fresh = self.copy.is_none();
        let (vt, cursor) = (&mut self.vt, self.cursor_cell);
        let copy = self.copy.get_or_insert_with(|| CopyMode::new(vt, cursor));
        copy.set_iskeyword(self.options.iskeyword.clone());
        if search {
            copy.open_search(vt, false, fresh);
        }
        self.ui_state_dirty = true;
        self.needs_paint = true;
    }

    fn end_copy(&mut self) {
        if let Some(copy) = self.copy.take() {
            copy.finish(&mut self.vt);
            self.ui_state_dirty = true;
            self.needs_paint = true;
        }
    }

    fn apply_copy_effect(&mut self, effect: CopyEffect) {
        match effect {
            CopyEffect::None => {}
            CopyEffect::Exit => self.end_copy(),
            CopyEffect::Copy { text, exit } => {
                DisplayServer::singleton().clipboard_set(text.as_str());
                self.copied = Some(text);
                if exit {
                    self.end_copy();
                }
            }
            CopyEffect::Refresh => self.refresh_held = true,
        }
        self.ui_state_dirty = true;
        self.needs_paint = true;
    }

    /// Copy mode takes Vim keys directly; a configured binding overrides one.
    /// Quick Select only acts on its configured bindings.
    fn modal_key(&mut self, key: &Gd<InputEventKey>) -> bool {
        let Some(mode) = self.modal_mode() else {
            return false;
        };
        let configured = self.options.modal.contains_key(mode);
        if mode == "quick_select" && !configured {
            return false;
        }
        if !key.is_pressed() {
            self.quick_keys.remove(&key.get_keycode().ord());
            return true;
        }
        let action = self
            .options
            .modal
            .get(mode)
            .and_then(|bindings| bindings.get(&i64::from(key.get_keycode_with_modifiers().ord())))
            .cloned();
        self.quick_keys.insert(key.get_keycode().ord());
        if action.as_deref() == Some("ignore") {
            return true;
        }
        if mode != "quick_select" {
            let vt = &mut self.vt;
            let Some(copy) = self.copy.as_mut() else {
                return false;
            };
            let effect = match action {
                Some(action) => copy.action(vt, &action),
                None => copy_input(key, copy.wants_text())
                    .map_or(CopyEffect::None, |input| copy.key(vt, input)),
            };
            self.apply_copy_effect(effect);
            return true;
        }
        if action.as_deref() == Some("copy") {
            self.copy_selection(false);
            return true;
        }
        if action.as_deref() == Some("refresh") {
            self.refresh_held = true;
            return true;
        }
        if action.as_deref() == Some("accept") {
            if let Some(q) = self.quick_select.take() {
                if let Some(index) = q.current {
                    if let Some(text) = q.matches[index].select_text(&self.vt) {
                        DisplayServer::singleton().clipboard_set(text.as_str());
                    }
                }
            }
            self.needs_paint = true;
            return true;
        }
        let (code, ctrl, shift) = match action.as_deref() {
            Some("cancel") => (GKey::ESCAPE, false, false),
            Some("next") => (GKey::DOWN, false, false),
            Some("previous") => (GKey::UP, false, false),
            Some("left") => (GKey::LEFT, false, false),
            Some("right") => (GKey::RIGHT, false, false),
            Some("up") => (GKey::UP, false, false),
            Some("down") => (GKey::DOWN, false, false),
            Some("page_up") => (GKey::PAGEUP, false, false),
            Some("page_down") => (GKey::PAGEDOWN, false, false),
            Some("line_start") => (GKey::HOME, false, false),
            Some("line_end") => (GKey::END, false, false),
            Some("top") => (GKey::HOME, true, false),
            Some("bottom") => (GKey::END, true, false),
            Some("toggle_selection") => (GKey::SPACE, false, false),
            Some("accept") => (GKey::ENTER, false, false),
            Some("backspace") => (GKey::BACKSPACE, false, false),
            Some("clear") => (GKey::U, true, false),
            _ => (GKey::NONE, key.is_ctrl_pressed(), key.is_shift_pressed()),
        };
        let mut mapped = InputEventKey::new_gd();
        mapped.set_keycode(code);
        mapped.set_pressed(true);
        mapped.set_ctrl_pressed(ctrl);
        mapped.set_shift_pressed(shift);
        if action.is_none() {
            mapped.set_unicode(key.get_unicode());
            mapped.set_alt_pressed(key.is_alt_pressed());
            mapped.set_meta_pressed(key.is_meta_pressed());
        }
        self.quick_select_key(&mapped, false);
        true
    }

    fn make_quick_select(&self) -> libghostty_vt::error::Result<crate::quick_select::QuickSelect> {
        if let Some(pattern) = &self.options.quick_pattern {
            crate::quick_select::QuickSelect::find(
                &self.vt,
                pattern,
                false,
                &self.options.quick_alphabet,
            )
        } else {
            crate::quick_select::QuickSelect::new(&self.vt)
        }
    }

    /// The default chords: Ctrl+Shift+X copy mode, F search, O last output.
    fn navigation_key(&mut self, key: &Gd<InputEventKey>, defaults: bool) -> bool {
        let code = key.get_keycode();
        let chord = key.is_ctrl_pressed()
            && key.is_shift_pressed()
            && !key.is_alt_pressed()
            && !key.is_meta_pressed();
        if !key.is_pressed()
            || !defaults
            || !chord
            || self.copy.is_some()
            || !matches!(code, GKey::F | GKey::X | GKey::O)
        {
            return false;
        }
        if code == GKey::O {
            self.quick_select = None;
            self.selecting = false;
            if crate::navigation::last_output(&mut self.vt) {
                self.copy_selection(false);
            }
        } else {
            self.start_copy(code == GKey::F);
        }
        self.quick_keys.insert(code.ord());
        self.ui_state_dirty = true;
        self.needs_paint = true;
        true
    }

    fn quick_select_key(&mut self, key: &Gd<InputEventKey>, defaults: bool) -> bool {
        if self
            .quick_select
            .as_ref()
            .is_some_and(|q| self.vt.active_screen().ok() != Some(q.screen))
        {
            self.quick_select = None;
            self.needs_paint = true;
        }
        let code = key.get_keycode();
        if !key.is_pressed() {
            return self.quick_keys.remove(&code.ord()) || self.quick_select.is_some();
        }
        if key.is_echo() && self.quick_keys.contains(&code.ord()) {
            return true;
        }
        let activate = defaults
            && code == GKey::SPACE
            && key.is_ctrl_pressed()
            && key.is_shift_pressed()
            && !key.is_alt_pressed()
            && !key.is_meta_pressed();
        if self.quick_select.is_none() {
            if !activate {
                return false;
            }
            self.quick_keys.insert(code.ord());
            if !key.is_echo() {
                match self.make_quick_select() {
                    Ok(q) => {
                        self.quick_select = Some(q);
                        self.ui_state_dirty = true;
                        self.selecting = false;
                        let _ = self.vt.set_selection(None);
                    }
                    Err(e) => godot_warn!("[graffitty] Quick Select: {e}"),
                }
                self.needs_paint = true;
            }
            return true;
        }
        self.quick_keys.insert(code.ord());
        self.ui_state_dirty = true;
        self.needs_paint = true;
        let plain = !key.is_ctrl_pressed()
            && !key.is_alt_pressed()
            && !key.is_meta_pressed()
            && !key.is_shift_pressed();
        let ctrl_only = key.is_ctrl_pressed()
            && !key.is_shift_pressed()
            && !key.is_alt_pressed()
            && !key.is_meta_pressed();
        if code == GKey::ESCAPE && plain {
            self.quick_select = None;
            return true;
        }
        let q = self.quick_select.as_mut().unwrap();
        if code == GKey::BACKSPACE && plain {
            q.input.pop();
        } else if code == GKey::U && ctrl_only {
            q.input.clear();
        } else if (plain
            && matches!(
                code,
                GKey::UP | GKey::DOWN | GKey::ENTER | GKey::PAGEUP | GKey::PAGEDOWN
            ))
            || (ctrl_only && matches!(code, GKey::P | GKey::N))
        {
            if let Some(current) = q.current {
                let count = q.matches.len();
                let top = self.vt.scrollbar().map(|s| s.offset).unwrap_or(0);
                let page = self.geo.rows as u64;
                let next = if code == GKey::PAGEUP {
                    q.matches
                        .iter()
                        .position(|m| {
                            m.bounds().is_some_and(|(s, _)| {
                                (s.y as u64) > top.saturating_sub(page) && (s.y as u64) < top
                            })
                        })
                        .unwrap_or(current.saturating_sub(1))
                } else if code == GKey::PAGEDOWN {
                    q.matches
                        .iter()
                        .position(|m| m.bounds().is_some_and(|(s, _)| s.y as u64 >= top + page))
                        .unwrap_or(current)
                } else if matches!(code, GKey::UP | GKey::ENTER | GKey::P) {
                    (current + count - 1) % count
                } else {
                    (current + 1) % count
                };
                q.current = Some(next);
                if let Some((s, _)) = q.matches[next].bounds() {
                    self.vt.scroll_viewport(ScrollViewport::Row(s.y as usize));
                }
            }
        } else if !key.is_ctrl_pressed() && !key.is_alt_pressed() && !key.is_meta_pressed() {
            if let Some(c) = char::from_u32(key.get_unicode()).filter(|c| !c.is_control()) {
                q.input.push(c);
            }
        }
        if let Some((index, paste)) = q.selected() {
            let q = self.quick_select.take().unwrap();
            let m = &q.matches[index];
            if let Some(text) = m.select_text(&self.vt).filter(|s| !s.is_empty()) {
                let mut ds = DisplayServer::singleton();
                ds.clipboard_set(text.as_str());
                if ds.has_feature(DisplayFeature::CLIPBOARD_PRIMARY) {
                    ds.clipboard_set_primary(text.as_str());
                }
                if paste && !self.exited {
                    self.paste_str(&text);
                }
            }
        }
        true
    }

    /// Swap default colors in place; explicit cell colors stay untouched.
    fn apply_theme(&mut self, theme: Theme) -> Result<(), String> {
        self.vt
            .set_default_bg_color(Some(theme.bg))
            .and_then(|vt| vt.set_default_fg_color(Some(theme.fg)))
            .and_then(|vt| vt.set_default_cursor_color(Some(theme.cursor)))
            .and_then(|vt| vt.set_default_color_palette(Some(VtPalette(theme.palette))))
            .map_err(|e| format!("theme: {e}"))?;
        // Only the session owner notifies applications, after installing the
        // same defaults used by this mirror. Replay never generates PTY input.
        self.scheme.set(theme.scheme);
        self.theme = theme;
        self.needs_paint = true;
        Ok(())
    }

    /// Transient per-terminal size, 0 resets to the spawn size.
    fn adjust_font_pt(&mut self, delta: i32) {
        let pt = if delta == 0 {
            self.spawn_pt
        } else {
            (self.base_pt + delta).clamp(1, 72)
        };
        self.set_font_pt(pt);
    }

    /// Re-measure with new padding or multipliers. Same shape as set_fonts:
    /// the cell box changed, so the grid has to be refitted and the pty told.
    fn set_metrics(&mut self, metrics: CellMetrics) -> Result<(), String> {
        if self.server_font { self.geo.pad = metrics.pad; self.metrics.pad = metrics.pad; return Ok(()); }
        self.metrics = metrics;
        let mut geo = measure(&self.fonts, self.font_size, metrics)?;
        geo.fit(Vector2::new(self.geo.width, self.geo.height));
        self.geo = geo;
        self.geo_changed = true;
        if let Err(e) = self
            .vt
            .resize(geo.cols, geo.rows, geo.cell_w as u32, geo.cell_h as u32)
        {
            return Err(format!("terminal resize failed: {e}"));
        }
        self.pty
            .resize(geo.cols, geo.rows, geo.cell_w as u16, geo.cell_h as u16);
        self.shared_geo.set(geo.shared());
        self.runs = RunCache::new();
        self.needs_paint = true;
        Ok(())
    }

    /// Swap the faces under a running terminal. The cell box changes with the
    /// font, so this is a reflow, not a repaint.
    fn set_fonts(
        &mut self,
        paths: &[GString],
        family: &str,
        fallbacks: &[GString],
    ) -> Result<(), String> {
        if self.server_font { return Ok(()); }
        let fonts = Fonts::configured(paths, family, fallbacks, &self.options)?;
        let mut geo = measure(&fonts, self.font_size, self.metrics)?;
        geo.fit(Vector2::new(self.geo.width, self.geo.height));
        self.fonts = fonts;
        self.geo = geo;
        self.geo_changed = true;
        if let Err(e) = self
            .vt
            .resize(geo.cols, geo.rows, geo.cell_w as u32, geo.cell_h as u32)
        {
            return Err(format!("terminal resize failed: {e}"));
        }
        self.pty
            .resize(geo.cols, geo.rows, geo.cell_w as u16, geo.cell_h as u16);
        self.shared_geo.set(geo.shared());
        // Cached runs were shaped with the old faces.
        self.runs = RunCache::new();
        self.needs_paint = true;
        Ok(())
    }

    fn set_font_pt(&mut self, pt: i32) {
        if self.server_font { return; }
        let pt = pt.clamp(1, 72);
        if pt == self.base_pt {
            return;
        }
        let effective = ((pt as f32) * self.scale).round().max(2.0) as i32;
        if effective != self.font_size {
            let mut geo = match measure(&self.fonts, effective, self.metrics) {
                Ok(geo) => geo,
                Err(e) => {
                    godot_error!("[graffitty] font size change failed: {e}");
                    return;
                }
            };
            geo.fit(Vector2::new(self.geo.width, self.geo.height));
            self.geo = geo;
            self.geo_changed = true;
            self.font_size = effective;
            if let Err(e) = self
                .vt
                .resize(geo.cols, geo.rows, geo.cell_w as u32, geo.cell_h as u32)
            {
                godot_error!("[graffitty] terminal resize failed: {e}");
            }
            self.pty
                .resize(geo.cols, geo.rows, geo.cell_w as u16, geo.cell_h as u16);
            self.shared_geo.set(geo.shared());
            // Cached runs were shaped at the old size.
            self.runs = RunCache::new();
            self.needs_paint = true;
        }
        self.base_pt = pt;
    }

    /// One CSI I/O per transition of the combined focus, mode 1004 only.
    /// Apps that enable the mode get no initial state, the crate has no
    /// mode change hook.
    fn report_focus(&mut self) {
        let combined = self.focused && self.win_focused;
        if combined == self.reported_focus {
            return;
        }
        self.reported_focus = combined;
        if self.exited || !self.vt.mode(Mode::FOCUS_EVENT).unwrap_or(false) {
            return;
        }
        let mut buf = [0u8; 8];
        let event = if combined {
            focus::Event::Gained
        } else {
            focus::Event::Lost
        };
        if let Ok(n) = event.encode(&mut buf) {
            self.writer.write(&buf[..n]);
        }
    }

    /// Report the OSC title verbatim, including clearing it. The host owns
    /// the working-directory fallback and explicit pane/tab names.
    fn refresh_title(&mut self) -> Option<String> {
        let title = self
            .vt
            .title()
            .map(|title| String::from_utf8_lossy(title).into_owned())
            .unwrap_or_default();
        if title == self.title {
            return None;
        }
        self.title = title.clone();
        Some(title)
    }

    fn install_replica_callbacks(&mut self) {
        // Prepared snapshots have no callbacks on their worker. Install native
        // UI effects only after the terminal is adopted on Godot's main thread.
        let allow_write = self.clipboard_write_enabled.clone();
        let _ = self.vt.on_clipboard_write(move |_vt, request| {
            use libghostty_vt::terminal::{ClipboardLocation, ClipboardWriteError};
            let result = (|| {
            if !allow_write.get() { return Err(ClipboardWriteError::Denied) }
            let mut contents = request.contents();
            let text = if contents.len() == 0 { "" } else {
                let data = contents.find(|c| c.mime == b"text/plain" || c.mime.starts_with(b"text/plain;"))
                    .ok_or(ClipboardWriteError::Unsupported)?.data;
                std::str::from_utf8(data).map_err(|_| ClipboardWriteError::InvalidData)?
            };
            if text.len() > 1024 * 1024 { return Err(ClipboardWriteError::InvalidData) }
            let mut ds = DisplayServer::singleton();
            if request.location() != ClipboardLocation::Standard && ds.has_feature(DisplayFeature::CLIPBOARD_PRIMARY) {
                ds.clipboard_set_primary(text);
            } else { ds.clipboard_set(text); }
            Ok(())
            })();
            request.reply(result, false);
        });
    }

    fn visible_image_placements(&self) -> libghostty_vt::error::Result<Vec<graffitty_terminal_core::image_render::Placement>> {
        let cell = (self.geo.cell_w, self.geo.cell_h);
        match &self.scene_graphics {
            Some(scene) => graffitty_terminal_core::image_render::scene_placements(&self.vt, scene, cell),
            None => graffitty_terminal_core::image_render::placements(&self.vt, cell),
        }
    }

    fn upload_scene_image(&mut self) {
        // At most one CPU upload per frame. The local shared-surface
        // path installs imported Texture2D resources without this CPU copy.
        let Some(key) = self.scene_pixels.keys().next().cloned() else { return };
        let pixels = self.scene_pixels.remove(&key).unwrap();
        let data = PackedByteArray::from(pixels.rgba.as_ref());
        if let Some(image) = GdImage::create_from_data(pixels.width as i32, pixels.height as i32, false, GdImageFormat::RGBA8, &data) {
            if let Some(texture) = ImageTexture::create_from_image(&image) {
                self.scene_textures.insert(key, (texture.upcast(), pixels.rgba.len(), self.remote_revision));
                self.scene_uploads += 1;
                self.needs_paint = true;
            }
        }
        self.trim_scene_textures();
    }

    fn trim_scene_textures(&mut self) {
        let mut remaining = self.scene_budget;
        self.scene_pixels.retain(|_, pixels| {
            if pixels.rgba.len() > remaining { return false; }
            remaining -= pixels.rgba.len();
            true
        });
        while self.scene_textures.values().map(|(_, size, _)| size).sum::<usize>() > remaining && !self.scene_textures.is_empty() {
            let oldest = self.scene_textures.iter().min_by_key(|(_, (_, _, revision))| *revision).map(|(key, _)| key.clone()).unwrap();
            self.scene_textures.remove(&oldest);
            self.needs_paint = true;
        }
    }

    /// Kitty graphics placements, as textured rects on the cells they occupy.
    ///
    /// The vt already holds the images — it parses and stores them whether or
    /// not anything draws them, which is why an unsupported terminal swallows
    /// the escape and shows nothing.
    ///
    /// This turns each visible placement into one rect, under or over the
    /// glyphs by the placement's own z.
    fn paint_images(&mut self, rs: &Painter, extra_rows: u16, seen: &mut Vec<u32>) {
        if extra_rows == 0 {
            rs.canvas_item_clear(self.canvas_img_below);
            rs.canvas_item_clear(self.canvas_img_above);
        }
        let (pad, cell_w, cell_h) = (self.geo.pad, self.geo.cell_w, self.geo.cell_h);
        let Ok(placements) = self.visible_image_placements() else { return };
        let Ok(graphics) = self.vt.kitty_graphics() else { return };
        for p in placements {
            let [x, y, w, h] = p.dest;
            if extra_rows > 0 && y < f32::from(self.geo.rows.saturating_sub(extra_rows)) * cell_h {
                continue;
            }
            let texture = if let Some(scene) = &self.scene_graphics {
                let Some(image) = scene.images.iter().find(|image| image.id == p.image_id) else { continue };
                let Some((texture, _, touched)) = self.scene_textures.get_mut(&image.asset) else { continue };
                *touched = self.remote_revision;
                texture.clone()
            } else {
                let Some(image) = graphics.as_ref().and_then(|graphics| graphics.image(p.image_id)) else { continue };
                if kitty_texture(&mut self.kitty_images, p.image_id, &image).is_none() { continue; }
                self.kitty_images[&p.image_id].1.clone().upcast()
            };
            seen.push(p.image_id);
            let [sx, sy, sw, sh] = p.source;
            let dest = Rect2::new(Vector2::new(pad + x, pad + y + f32::from(extra_rows) * cell_h), Vector2::new(w, h));
            let source = Rect2::new(Vector2::new(sx, sy), Vector2::new(sw, sh));
            let layer = if p.z < 0 { self.canvas_img_below } else { self.canvas_img_above };
            rs.image(layer, dest, texture, source);
        }
    }

    /// Copy the active selection to the system (or primary) clipboard.
    fn copy_selection(&self, primary: bool) {
        let Ok(Some(mut formatter)) = Formatter::new_selection(&self.vt) else { return };
        if formatter.set_trim(true).and_then(|f| f.set_unwrap(false)).is_err() { return }
        let Ok(bytes) = formatter.format_alloc(None) else { return };
        let Ok(text) = std::str::from_utf8(&bytes) else {
            return;
        };
        if text.is_empty() {
            return;
        }
        let mut ds = DisplayServer::singleton();
        if primary {
            // Godot warns on every call where no primary clipboard exists.
            if ds.has_feature(DisplayFeature::CLIPBOARD_PRIMARY) {
                ds.clipboard_set_primary(text);
            }
        } else {
            ds.clipboard_set(text);
        }
    }

    /// Paste, encoded through libghostty (strips controls, bracketed paste).
    fn paste_clipboard(&mut self) {
        if self.attachment_busy { return; }
        match crate::clipboard::paste() {
            Ok(crate::clipboard::Paste::Text(text)) => self.paste_str(&text),
            Ok(crate::clipboard::Paste::File(file)) => self.queue_attachment(Ok(file)),
            Ok(crate::clipboard::Paste::Empty) => {},
            Err(error) => self.queue_attachment(Err(error)),
        }
    }

    fn queue_attachment(&mut self, file: anyhow::Result<graffitty_client_core::clipboard_paste::Attachment>) {
        self.attachment_prefix = self.writer.take_all();
        self.attachment = Some(file.map_err(|e| e.to_string()));
        self.attachment_busy = true;
        self.writer.notify();
    }

    /// The same encoding for text that did not come from the clipboard.
    fn paste_str(&mut self, text: &str) {
        let text = text.to_string();
        if text.is_empty() {
            return;
        }

        let bracketed = self.vt.mode(Mode::BRACKETED_PASTE).unwrap_or(false);
        let mut data = text.into_bytes();
        let mut buf = vec![0u8; data.len() + 16];
        let written = match paste::encode(&mut data, bracketed, &mut buf) {
            Ok(n) => n,
            Err(VtError::OutOfSpace { required }) => {
                buf.resize(required, 0);
                match paste::encode(&mut data, bracketed, &mut buf) {
                    Ok(n) => n,
                    Err(_) => return,
                }
            }
            Err(_) => return,
        };
        self.writer.write(&buf[..written]);
        if !self.frozen() {
            let _ = self.vt.set_selection(None);
            self.scroll_fraction = 0.0;
            self.vt.scroll_viewport(ScrollViewport::Bottom);
        }
        self.ui_state_dirty = true;
    }

    /// Reflow and SIGWINCH only when the cell grid actually changed.
    fn refit(&mut self, size: Vector2) -> bool {
        if self.pty.is_remote() {
            self.geo.width = size.x;
            self.geo.height = size.y;
            return false;
        }
        let (cols, rows) = (self.geo.cols, self.geo.rows);
        self.geo.fit(size);
        if self.geo.cols == cols && self.geo.rows == rows {
            return false;
        }
        self.geo_changed = true;
        self.scroll_fraction = 0.0;
        if let Err(e) = self.vt.resize(
            self.geo.cols,
            self.geo.rows,
            self.geo.cell_w as u32,
            self.geo.cell_h as u32,
        ) {
            godot_error!("[graffitty] terminal resize failed: {e}");
        }
        self.pty.resize(
            self.geo.cols,
            self.geo.rows,
            self.geo.cell_w as u16,
            self.geo.cell_h as u16,
        );
        self.shared_geo.set(self.geo.shared());
        if self.quick_select.is_some() {
            self.quick_select = self.make_quick_select().ok();
        }
        true
    }

    fn scroller(&self) -> Scroller {
        let bar = self.vt.scrollbar().ok();
        Scroller {
            offset: bar.as_ref().map_or(0.0, |bar| bar.offset as f64 + self.scroll_fraction) * PIXELS_PER_ROW,
            max: bar.as_ref().map_or(0.0, |bar| bar.total.saturating_sub(bar.len) as f64) * PIXELS_PER_ROW,
            bounds: f64::from(self.geo.rows) * PIXELS_PER_ROW,
        }
    }

    fn gesture_began(&mut self, gesture: ScrollGesture) {
        let allowed = self.smooth_scroll_allowed();
        self.elastic.began(gesture, allowed);
    }

    fn gesture_ended(&mut self, gesture: ScrollGesture, now: f64) {
        let scroller = self.scroller();
        self.elastic.ended(gesture, now, scroller);
    }

    /// Advance the rubber band. Returns whether the pull changed.
    fn tick_elastic(&mut self, now: f64) -> bool {
        let (scroller, allowed) = (self.scroller(), self.smooth_scroll_allowed());
        if self.pan_phases.stopped(&self.elastic) {
            self.elastic.end(now, scroller);
        }
        self.elastic.tick(now, scroller, allowed)
    }

    /// How far the rubber band displaces the content, in pixels, positive
    /// when pulled past the bottom.
    fn pull(&self) -> f32 {
        (self.elastic.elastic.stretch() / PIXELS_PER_ROW) as f32 * self.geo.cell_h
    }

    /// Where the grid is drawn: shifted by the sub-row scroll and the rubber
    /// band, which Android draws as a stretch from the pulled edge.
    fn content_transform(&self, height: f32) -> Transform2D {
        let shift = -(self.scroll_fraction as f32) * self.geo.cell_h;
        let pull = self.pull();
        if self.elastic.elastic.config().scales {
            let scale = 1.0 + pull.abs() / height.max(1.0);
            let pivot = if pull > 0.0 { height } else { 0.0 };
            Transform2D::from_cols(
                Vector2::RIGHT,
                Vector2::new(0.0, scale),
                Vector2::new(0.0, shift + pivot * (1.0 - scale)),
            )
        } else {
            Transform2D::from_cols(Vector2::RIGHT, Vector2::DOWN, Vector2::new(0.0, shift - pull))
        }
    }

    fn smooth_scroll_allowed(&self) -> bool {
        self.quick_select.is_none()
            && self.copy.is_none()
            && self.vt.active_screen().ok() != Some(Screen::Alternate)
            && !self.vt.is_mouse_tracking().unwrap_or(false)
    }

    /// Re-record the grid; returns whether the background color changed.
    fn repaint(&mut self, size: Vector2) -> libghostty_vt::error::Result<bool> {
        self.paint(size, false).map(|(changed, _)| changed)
    }

    fn paint(&mut self, size: Vector2, record: bool) -> libghostty_vt::error::Result<(bool, Option<Presentation>)> {
        let (canvas_bg, canvas_fg) = (self.canvas_bg, self.canvas_fg);
        let rs = Painter::new([canvas_bg, canvas_fg, self.canvas_img_below, self.canvas_img_above, self.canvas_quick], record, self.pixel_grid);
        rs.canvas_item_clear(canvas_bg);
        rs.canvas_item_clear(canvas_fg);
        rs.canvas_item_clear(self.canvas_quick);
        let old_fraction = self.scroll_fraction;
        if !self.smooth_scroll_allowed() {
            self.scroll_fraction = 0.0;
        }
        if self
            .vt
            .scrollbar()
            .is_ok_and(|bar| bar.offset >= bar.total.saturating_sub(bar.len))
        {
            self.scroll_fraction = 0.0;
        }
        self.ui_state_dirty |= self.scroll_fraction != old_fraction;
        // Output or scrolling can change the target under a stationary pointer.
        self.refresh_hover();
        let transform = self.content_transform(size.y);
        for canvas in [
            canvas_bg,
            canvas_fg,
            self.canvas_img_below,
            self.canvas_img_above,
            self.canvas_quick,
        ] {
            rs.canvas_item_set_transform(canvas, transform);
        }
        let mut visible_images = Vec::new();
        self.paint_images(&rs, 0, &mut visible_images);
        if self
            .quick_select
            .as_ref()
            .is_some_and(|q| self.vt.active_screen().ok() != Some(q.screen))
        {
            self.quick_select = None;
        }
        let quick_segments = self
            .quick_select
            .as_ref()
            .map(|q| {
                q.segments(
                    self.vt.scrollbar().map(|s| s.offset).unwrap_or(0),
                    self.geo.rows,
                    self.geo.cols,
                )
            })
            .unwrap_or_default();
        let mut quick_cells = vec![
            false;
            if self.quick_select.is_some() {
                self.geo.cols as usize * self.geo.rows as usize
            } else {
                0
            }
        ];
        for (row, left, right, _) in &quick_segments {
            for col in *left..*right {
                quick_cells[*row as usize * self.geo.cols as usize + col as usize] = true;
            }
        }
        // Copy mode: search matches (1, current 2) and its cursor, by viewport cell.
        let copy_cursor = self.copy.as_ref().and_then(|copy| copy.cursor_viewport(&self.vt));
        let flash_active = self.copy.as_ref().is_some_and(CopyMode::flash_active);
        let mut copy_cells = Vec::new();
        if let Some(copy) = &self.copy {
            let top = self.vt.scrollbar().map(|s| s.offset).unwrap_or(0);
            copy_cells = vec![0u8; self.geo.cols as usize * self.geo.rows as usize];
            for (row, from, to, current) in copy.highlights(top, self.geo.rows, self.geo.cols) {
                for col in from..to {
                    let cell = &mut copy_cells[row as usize * self.geo.cols as usize + col as usize];
                    *cell = (*cell).max(if current { 2 } else { 1 });
                }
            }
        }
        // Include the pane's sub-row remainder as well as the scroll translation.
        // One extra row is insufficient when their sum exceeds a cell height.
        let bar = self.vt.scrollbar()?;
        let extra_rows = if self.smooth_scroll_allowed() {
            (((size.y - self.geo.pad) / self.geo.cell_h + self.scroll_fraction as f32
                - f32::from(self.geo.rows))
            .ceil()
            .max(0.0) as usize)
                .min(bar.total.saturating_sub(bar.len).saturating_sub(bar.offset) as usize)
                .min(usize::from(self.geo.rows)) as u16
        } else {
            0
        };
        if extra_rows > 0 {
            let top = bar.offset as usize;
            self.vt
                .scroll_viewport(ScrollViewport::Row(top + usize::from(extra_rows)));
            self.paint_images(&rs, extra_rows, &mut visible_images);
            self.vt.scroll_viewport(ScrollViewport::Row(top));
        }
        self.kitty_images
            .retain(|id, _| visible_images.contains(id));
        let mut snapshot = self.render_state.update(&self.vt)?;
        let colors = snapshot.colors()?;
        let terminal_cursor_style = snapshot.cursor_visual_style()?;
        self.cursor_blinks = match self.options.cursor_blink {
            0 => false,
            1 => true,
            _ => snapshot.cursor_blinking()?,
        };
        self.text_blinks = false;
        // Palette for resolving SGR 58 underline color indexes.
        let palette = self.vt.color_palette().ok();

        let bg = color(colors.background);
        let bg_changed = bg != self.bg;
        self.bg = bg;

        // TUIs such as Pi hide the hardware cursor but still position it for
        // IME. Track that position independently of whether we draw the cursor;
        // keystrokes and preedit must not use its last visible location.
        let cursor_position = snapshot.cursor_viewport()?.map(|mut vp| {
            // A cursor on a wide char's spacer tail belongs to its head.
            vp.x = vp.x.saturating_sub(vp.at_wide_tail as u16);
            vp
        });
        if let Some(vp) = cursor_position {
            if (vp.x, vp.y) != self.cursor_cell {
                self.cursor_changed = true;
            }
            self.cursor_cell = (vp.x, vp.y);
        }
        let mut visible_area = graffitty_terminal_core::visible_area::VisibleArea::new(
            self.geo.cols, self.geo.rows, cursor_position.map(|vp| (vp.x, vp.y)),
        );
        visible_area.graphics_present = !visible_images.is_empty();
        let cursor_vp = if self.quick_select.is_none()
            && self.copy.is_none()
            && !self.exited
            && snapshot.cursor_visible()?
        {
            cursor_position
        } else {
            None
        };
        self.cursor_on = cursor_vp.is_some();
        // The cursor cell's glyphs, redrawn over the cursor block.
        let mut cursor_cell = None;

        let thick = self.geo.thick;
        // One baseline rule for text underlines and the underline cursor,
        // clamped so the line cannot escape the cell.
        let underline_y = self.geo.underline.min(self.geo.cell_h - thick);
        // Strikethrough centers on lowercase, so baseline minus half of
        // x-height plus thickness. JetBrains Mono's x-height ratio is 0.53.
        let strike_y = (self.geo.ascent - 0.5 * (0.53 * self.font_size as f32 + thick))
            .round()
            .clamp(0.0, self.geo.cell_h - thick);

        let mut graphemes: Vec<char> = Vec::new();
        let mut run: Option<Run> = None;
        let runs = &mut self.runs;
        let fonts = &self.fonts;
        let (cell_w, ascent, font_size) = (self.geo.cell_w, self.geo.ascent, self.font_size);
        let raster_scale = self.raster_scale;
        let outline_width = self.options.outline_width;
        let outline_color = self.options.outline_color;
        let default_bg = colors.background;
        let selection = self.selection;
        // Cells the composition covers, as (row, first col, end col). Like
        // ghostty, they draw neither glyph nor background under the preedit,
        // so an application's painted cursor cell does not show through.
        let preedit_cells = (!self.preedit.is_empty()).then(|| {
            let (col, row) = self.cursor_cell;
            let mut end = col;
            for ch in &self.preedit {
                let w = if UnicodeWidthChar::width(*ch).unwrap_or(1) > 1 { 2 } else { 1 };
                if end + w > self.geo.cols {
                    break;
                }
                end += w;
            }
            (row, col, end)
        });
        let mut flush = |run: &mut Option<Run>, y: f32| {
            if let Some(r) = run.take() {
                rs.run(
                    runs,
                    canvas_fg,
                    fonts.style_font(r.style),
                    r,
                    y + ascent,
                    cell_w,
                    font_size,
                    raster_scale,
                    outline_width,
                    outline_color,
                );
            }
        };
        for pass in 0..=usize::from(extra_rows > 0) {
            if pass == 1 {
                // RenderState::update consumes the terminal's dirty flags. Two
                // independent caches lose selection clears and changed rows.
                // Finish drawing the main viewport before reusing its cache
                // for the rows exposed by fractional scrolling.
                drop(snapshot);
                let top = bar.offset as usize;
                self.vt
                    .scroll_viewport(ScrollViewport::Row(top + usize::from(extra_rows)));
                let result = self.render_state.update(&self.vt);
                // Restore even if updating the render state failed.
                self.vt.scroll_viewport(ScrollViewport::Row(top));
                snapshot = result?;
            }
            let mut row_it = self.rows.update(&snapshot)?;
            let mut y = self.geo.pad;
            let mut row_i: u16 = 0;
            if pass == 1 {
                for _ in 0..self.geo.rows.saturating_sub(extra_rows) {
                    row_it.next();
                }
                row_i = self.geo.rows;
                y += f32::from(row_i) * self.geo.cell_h;
            }
            while let Some(row) = row_it.next() {
                let row_selected = row.selection()?.is_some();
                let mut cell_it = self.cells.update(row)?;
                let mut x = self.geo.pad;
                let mut col: u16 = 0;
                while let Some(cell) = cell_it.next() {
                    let selected = row_selected && cell.is_selected()?;
                    let quick_match = quick_cells
                        .get(row_i as usize * self.geo.cols as usize + col as usize)
                        .copied()
                        .unwrap_or(false);
                    let n = cell.graphemes_len()? as usize;
                    let cell_rect = Rect2::new(
                        Vector2::new(x, y),
                        Vector2::new(self.geo.cell_w, self.geo.cell_h),
                    );

                    // Empty cells include the second column of a wide glyph. Resolve
                    // their SGR inverse and selection colors exactly like glyph cells.
                    let (mut fg, mut bg) = crate::selection::resolve_cell_colors(
                        cell,
                        colors.foreground,
                        colors.background,
                        selection,
                        selected,
                    )?;
                    let mut bold = false;
                    let mut italic = false;
                    let mut faint = false;
                    let mut invisible = false;
                    let mut strikethrough = false;
                    let mut overline = false;
                    let mut underline = Underline::None;
                    let mut underline_color = StyleColor::None;

                    if cell.has_styling()? {
                        let style = cell.style()?;
                        bold = style.bold;
                        italic = style.italic;
                        faint = style.faint;
                        self.text_blinks |= style.blink;
                        invisible = style.invisible || (style.blink && !self.blink_on);
                        strikethrough = style.strikethrough;
                        overline = style.overline;
                        underline = style.underline;
                        underline_color = style.underline_color;
                    }

                    // Track the underlying grid, not transient selection/search/blink
                    // overlays. Reuse this cell walk; do not consume VT dirty flags
                    // with a second RenderState or expose a partially updated frame.
                    graphemes.resize(n, '\0');
                    cell.graphemes_buf(&mut graphemes)?;
                    if pass == 0 {
                        let style = cell.style()?;
                        let raw_fg = cell.fg_color()?.unwrap_or(colors.foreground);
                        let raw_bg = cell.bg_color()?.unwrap_or(colors.background);
                        let background = if style.inverse { raw_fg } else { raw_bg };
                        let ink = !style.invisible && (
                            graphemes.iter().any(|ch| !ch.is_whitespace() && *ch != '\0')
                            || (n > 0 && (style.underline != Underline::None
                                || style.strikethrough || style.overline))
                        );
                        let width = if matches!(cell.raw_cell().and_then(|c| c.wide()), Ok(CellWide::Wide)) { 2 } else { 1 };
                        visible_area.observe(col, row_i, width, ink, background != colors.background);
                    }

                    let copy_mark = copy_cells
                        .get(row_i as usize * self.geo.cols as usize + col as usize)
                        .copied()
                        .unwrap_or(0);
                    if flash_active {
                        if copy_mark == 0 {
                            // Flash backdrop: replace SGR/selection colors with
                            // quiet gray ink; matches retain their original ink.
                            let gray = if u16::from(colors.background.r)
                                + u16::from(colors.background.g)
                                + u16::from(colors.background.b)
                                > 384
                            {
                                160
                            } else {
                                100
                            };
                            fg = RgbColor {
                                r: gray,
                                g: gray,
                                b: gray,
                            };
                            bg = None;
                            underline_color = StyleColor::None;
                            faint = true;
                        } else {
                            (fg, _) = crate::selection::resolve_cell_colors(
                                cell,
                                colors.foreground,
                                colors.background,
                                selection,
                                false,
                            )?;
                            bg = Some(flash_match_background(fg));
                            faint = false;
                        }
                    } else if copy_mark > 0 && !selected {
                        fg = RgbColor { r: 0, g: 0, b: 0 };
                        bg = Some(if copy_mark == 2 {
                            RgbColor { r: 255, g: 158, b: 59 }
                        } else {
                            RgbColor { r: 229, g: 192, b: 123 }
                        });
                        faint = false;
                    }
                    // Its own color: the theme cursor can match the selection.
                    if !flash_active && copy_cursor.is_some_and(|(x, y, wide)| {
                        y == row_i && (col == x || (wide && col == x + 1))
                    }) {
                        fg = RgbColor { r: 0, g: 0, b: 0 };
                        bg = Some(RgbColor { r: 64, g: 200, b: 224 });
                        faint = false;
                    }
                    if quick_match {
                        fg = RgbColor {
                            r: 80,
                            g: 220,
                            b: 120,
                        };
                        bg = Some(RgbColor { r: 0, g: 0, b: 0 });
                        bold = true;
                        faint = false;
                    }
                    let under_preedit = preedit_cells
                        .is_some_and(|(row, from, to)| row == row_i && (from..to).contains(&col));
                    if let Some(bg) = bg
                        .filter(|_| !under_preedit)
                        .and_then(|b| cell_bg(b, default_bg))
                    {
                        rs.canvas_item_add_rect(canvas_bg, cell_rect, bg);
                    }

                    // Concealed cells keep their background and draw no ink,
                    // like xterm. Decorations count as ink.
                    let hovered = self
                        .hover_link
                        .as_ref()
                        .is_some_and(|link| link.cells.contains(&(col, u32::from(row_i))));
                    if n == 0 || invisible || under_preedit {
                        flush(&mut run, y);
                        if hovered && !invisible && !under_preedit {
                            let mut ink = color(fg);
                            if faint {
                                ink.a = 0.6;
                            }
                            rs.underline(
                                canvas_fg,
                                cell_rect,
                                ink,
                                thick,
                                underline_y,
                                Underline::Single,
                            );
                        }
                        x += self.geo.cell_w;
                        col += 1;
                        continue;
                    }

                    let mut fg = color(fg);
                    if faint {
                        fg.a = 0.6;
                    }

                    // The private-use codepoint and its combining marks carry
                    // image coordinates, never font glyphs (even if the image
                    // has been deleted or has not finished uploading yet).
                    if graphemes[0] == graffitty_terminal_core::image_render::PLACEHOLDER {
                        flush(&mut run, y);
                        x += self.geo.cell_w;
                        col += 1;
                        continue;
                    }
                    let count = n.min(GLYPHS_PER_CELL);
                    let style = Fonts::style_index(bold, italic);
                    let baseline = Vector2::new(x, y + self.geo.ascent);
                    let wide =
                        || matches!(cell.raw_cell().and_then(|c| c.wide()), Ok(CellWide::Wide));
                    let at_cursor = cursor_vp
                        .as_ref()
                        .is_some_and(|vp| vp.x == col && vp.y == row_i);

                    // Runs hold single-codepoint ASCII cells of one style and
                    // color; the cursor cell stays out so a ligature under the
                    // cursor splits into plain characters, like ghostty.
                    let run_cell = (self.ligatures || (!self.server_font && !self.options.font_features.is_empty()))
                        && n == 1
                        && (0x20..=0x7e).contains(&(graphemes[0] as u32))
                        && !at_cursor
                        && self
                            .fonts
                            .resolve_index(graphemes[0] as u32, style, || false)
                            == i32::from(style);
                    if run
                        .as_ref()
                        .is_some_and(|r| !run_cell || r.style != style || r.fg != fg)
                    {
                        flush(&mut run, y);
                    }
                    if run_cell {
                        match run.as_mut() {
                            Some(r) => r.text.push(graphemes[0]),
                            None => {
                                run = Some(Run {
                                    text: graphemes[0].to_string(),
                                    style,
                                    fg,
                                    x,
                                })
                            }
                        }
                    } else {
                        if at_cursor {
                            let mut glyphs = ['\0'; GLYPHS_PER_CELL];
                            glyphs[..count].copy_from_slice(&graphemes[..count]);
                            cursor_cell = Some((glyphs, count, style, baseline, wide()));
                        }
                        let shaped = rs.grapheme(&self.fonts, canvas_fg, baseline, &graphemes[..count], style,
                            wide(), self.font_size, fg, raster_scale, outline_width, outline_color);
                        for ch in if shaped { &graphemes[..0] } else { &graphemes[..count] } {
                            let cp = *ch as u32;
                            if rs.sprite(canvas_fg, cell_rect, fg, self.geo.thick, cp) {
                                continue;
                            }
                            if let Some(font) = self.fonts.resolve(cp, style, wide) {
                                rs.character(&font, canvas_fg, baseline, cp, self.font_size,
                                    fg, raster_scale, outline_width, outline_color);
                            }
                        }
                    }

                    if hovered {
                        rs.underline(
                            canvas_fg,
                            cell_rect,
                            fg,
                            thick,
                            underline_y,
                            Underline::Single,
                        );
                    } else if !matches!(underline, Underline::None) {
                        // Explicit SGR 58 color wins, else the text color.
                        let ul = match underline_color {
                            StyleColor::Rgb(c) => color(c),
                            StyleColor::Palette(i) => palette
                                .as_ref()
                                .map(|p| color(p.0[i.0 as usize]))
                                .unwrap_or(fg),
                            StyleColor::None => fg,
                        };
                        rs.underline(canvas_fg, cell_rect, ul, thick, underline_y, underline);
                    }
                    if strikethrough {
                        let line = Rect2::new(
                            Vector2::new(x, y + strike_y),
                            Vector2::new(self.geo.cell_w, thick),
                        );
                        rs.canvas_item_add_rect(canvas_fg, line, fg);
                    }
                    if overline {
                        let line =
                            Rect2::new(Vector2::new(x, y), Vector2::new(self.geo.cell_w, thick));
                        rs.canvas_item_add_rect(canvas_fg, line, fg);
                    }

                    x += self.geo.cell_w;
                    col += 1;
                }
                flush(&mut run, y);
                y += self.geo.cell_h;
                row_i += 1;
            }
        }
        self.runs.end_frame();

        if !self.preedit.is_empty() {
            // Drawn here, not by the host: the composition belongs on the
            // same baseline, in the same face and at the same cell pitch as
            // the text it will become.
            //
            // A host drawing it into an overlay has to guess all three, and a
            // Hangul syllable magnifies every one of those guesses.
            let (col, row) = self.cursor_cell;
            let fg = color(colors.foreground);
            let mut x = self.geo.pad + f32::from(col) * self.geo.cell_w;
            let y = self.geo.pad + f32::from(row) * self.geo.cell_h;
            let right = self.geo.pad + f32::from(self.geo.cols) * self.geo.cell_w;
            let (mark_from, mark_len) = self.preedit_mark;
            let mut rule: Option<(f32, f32)> = None;
            for (i, ch) in self.preedit.iter().enumerate() {
                let cp = *ch as u32;
                let wide = UnicodeWidthChar::width(*ch).unwrap_or(1) > 1;
                let advance = self.geo.cell_w * if wide { 2.0 } else { 1.0 };
                if x + advance > right {
                    break;
                }
                let baseline = Vector2::new(x, y + self.geo.ascent);
                let cell = Rect2::new(Vector2::new(x, y), Vector2::new(advance, self.geo.cell_h));
                if !rs.sprite(canvas_fg, cell, fg, thick, cp) {
                    if let Some(font) = self.fonts.resolve(cp, 0, || wide) {
                        rs.character(&font, canvas_fg, baseline, cp, self.font_size,
                            fg, raster_scale, outline_width, outline_color);
                    }
                }
                if i >= mark_from && i < mark_from + mark_len {
                    let (lo, hi) = rule.unwrap_or((x, x));
                    rule = Some((lo.min(x), hi.max(x + advance)));
                }
                x += advance;
            }
            // ghostty's own dotted rule, at the font's underline position: the
            // convention every terminal here uses for text that is not committed.
            if let Some((lo, hi)) = rule {
                let cell = Rect2::new(Vector2::new(lo, y), Vector2::new(hi - lo, self.geo.cell_h));
                rs.underline(canvas_fg, cell, fg, thick, underline_y, Underline::Dotted);
            }
        }

        // Movie Maker renders a virtual foreground window, even when its
        // native window is hidden. Preserve the control's actual focus and
        // DECSCUSR shape without changing OS focus, IME ownership or terminal
        // focus reports.
        //
        // Ordinary interactive windows keep their native state.
        let cursor_focused = self.focused
            && (self.win_focused || crate::movie_writer::is_active());
        // No cursor while composing, like ghostty: the composition is the caret.
        if let Some(vp) = cursor_vp.filter(|_| {
            self.preedit.is_empty()
                && (!self.cursor_blinks || self.cursor_blink_on || !cursor_focused)
        }) {
            let c = color(colors.cursor.unwrap_or(colors.foreground));
            let wide_cursor = matches!(&cursor_cell, Some((.., true)));
            let origin = Vector2::new(
                self.geo.pad + f32::from(vp.x) * self.geo.cell_w,
                self.geo.pad + vp.y as f32 * self.geo.cell_h,
            );
            let size = Vector2::new(
                self.geo.cell_w * if wide_cursor { 2.0 } else { 1.0 },
                self.geo.cell_h,
            );
            // Other panes remain hollow; only the focused control uses its
            // requested cursor shape in the captured foreground window.
            let cursor_style = if cursor_focused {
                match self.cursor_shape {
                    1 => CursorVisualStyle::Block,
                    2 => CursorVisualStyle::Bar,
                    3 => CursorVisualStyle::Underline,
                    4 => CursorVisualStyle::BlockHollow,
                    // Auto: DECSCUSR, so an application that asks for a bar
                    // while it edits a line still gets one.
                    _ => terminal_cursor_style,
                }
            } else {
                CursorVisualStyle::BlockHollow
            };
            let thick = match cursor_style {
                CursorVisualStyle::Bar if self.options.beam > 0.0 => self.options.beam,
                CursorVisualStyle::Underline if self.options.underline > 0.0 => {
                    self.options.underline
                }
                _ => thick,
            }
            .max(1.0);
            let underline_y = underline_y.min(size.y - thick);
            let (offset, extent) = match cursor_style {
                CursorVisualStyle::Bar => (
                    Vector2::new(-((thick + 1.0) / 2.0).floor(), 0.0),
                    Vector2::new(thick, size.y),
                ),
                CursorVisualStyle::Underline => {
                    (Vector2::new(0.0, underline_y), Vector2::new(size.x, thick))
                }
                _ => (Vector2::ZERO, size),
            };
            let cell_size = Vector2::new(self.geo.cell_w, self.geo.cell_h);
            let cell_origin = Vector2::new(
                self.geo.pad + self.cursor_cell.0 as f32 * self.geo.cell_w,
                self.geo.pad + self.cursor_cell.1 as f32 * self.geo.cell_h,
            );
            self.cursor_render_rect = Rect2::new(
                (origin - cell_origin + offset) / cell_size,
                extent / cell_size,
            );
            self.cursor_render_color = c;
            match cursor_style {
                // Centered on the cell's left edge, between characters.
                CursorVisualStyle::Bar => rs.canvas_item_add_rect(
                    canvas_fg,
                    Rect2::new(
                        Vector2::new(origin.x - ((thick + 1.0) / 2.0).floor(), origin.y),
                        Vector2::new(thick, size.y),
                    ),
                    c,
                ),
                CursorVisualStyle::Underline => rs.canvas_item_add_rect(
                    canvas_fg,
                    Rect2::new(
                        Vector2::new(origin.x, origin.y + underline_y),
                        Vector2::new(size.x, thick),
                    ),
                    c,
                ),
                CursorVisualStyle::BlockHollow => {
                    let t = thick.min(size.x / 2.0).min(size.y / 2.0);
                    for [x0, y0, x1, y1] in [
                        [0.0, 0.0, size.x, t],
                        [0.0, size.y - t, size.x, size.y],
                        [0.0, t, t, size.y - t],
                        [size.x - t, t, size.x, size.y - t],
                    ] {
                        let frame = Rect2::new(
                            Vector2::new(origin.x + x0, origin.y + y0),
                            Vector2::new(x1 - x0, y1 - y0),
                        );
                        rs.canvas_item_add_rect(canvas_fg, frame, c);
                    }
                }
                // Block, and any future style, as the filled block; only
                // this style repaints the glyph underneath.
                _ => {
                    rs.canvas_item_add_rect(canvas_fg, Rect2::new(origin, size), c);
                    if let Some((chars, count, style, baseline, wide)) = cursor_cell {
                        // Godot leaves color glyphs untinted, matching ghostty.
                        let text = color(colors.background);
                        let cell = Rect2::new(
                            Vector2::new(baseline.x, baseline.y - self.geo.ascent),
                            Vector2::new(self.geo.cell_w, self.geo.cell_h),
                        );
                        let shaped = rs.grapheme(&self.fonts, canvas_fg, baseline, &chars[..count], style,
                            wide, self.font_size, text, self.raster_scale, 0, text);
                        for ch in if shaped { &chars[..0] } else { &chars[..count] } {
                            let cp = *ch as u32;
                            if rs.sprite(canvas_fg, cell, text, self.geo.thick, cp) {
                                continue;
                            }
                            if let Some(font) = self.fonts.resolve(cp, style, || wide) {
                                rs.character(&font, canvas_fg, baseline, cp, self.font_size,
                                    text, raster_scale, 0, text);
                            }
                        }
                    }
                }
            }
        }

        if self.quick_select.is_some() {
            let canvas_fg = self.canvas_quick;
            let font = self.fonts.primary();
            let black = Color::from_rgb(0.0, 0.0, 0.0);
            let yellow = Color::from_rgb(1.0, 0.8, 0.2);
            for (row, col, _, label) in &quick_segments {
                let pos = Vector2::new(
                    self.geo.pad + *col as f32 * self.geo.cell_w,
                    self.geo.pad + *row as f32 * self.geo.cell_h,
                );
                let width =
                    label.len().min((self.geo.cols - col) as usize) as f32 * self.geo.cell_w;
                rs.canvas_item_add_rect(
                    canvas_fg,
                    Rect2::new(pos, Vector2::new(width, self.geo.cell_h)),
                    black,
                );
                rs.text(font, canvas_fg, pos + Vector2::new(0.0, self.geo.ascent),
                    label.as_str(), self.font_size, yellow, width, raster_scale, 0, yellow);
            }
        }

        if let Some(copy) = &self.copy {
            let mut status = copy.status();
            if !self.held.is_empty() {
                status.push_str(if copy.wants_text() {
                    "  [frozen: new output]"
                } else {
                    "  [frozen: new output, r refreshes]"
                });
            }
            let position = Vector2::new(self.geo.pad, size.y - self.geo.cell_h - self.geo.pad);
            rs.canvas_item_add_rect(
                self.canvas_quick,
                Rect2::new(position, Vector2::new(size.x, self.geo.cell_h)),
                Color::from_rgba(0.05, 0.05, 0.05, 0.95),
            );
            rs.text(self.fonts.primary(), self.canvas_quick,
                position + Vector2::new(0.0, self.geo.ascent), status.as_str(),
                self.font_size, Color::WHITE, size.x, raster_scale, 0, Color::WHITE);
            // Keep jump labels visible even on the status overlay row.
            let top = self.vt.scrollbar().map_or(0, |s| s.offset);
            for (row, col, label) in copy.labels(top, self.geo.rows) {
                let pos = Vector2::new(
                    self.geo.pad + f32::from(col) * self.geo.cell_w,
                    self.geo.pad + f32::from(row) * self.geo.cell_h,
                );
                rs.canvas_item_add_rect(
                    self.canvas_quick,
                    Rect2::new(pos, Vector2::new(self.geo.cell_w, self.geo.cell_h)),
                    Color::from_rgb(1.0, 0.8, 0.2),
                );
                rs.text(self.fonts.primary(), self.canvas_quick,
                    pos + Vector2::new(0.0, self.geo.ascent), &label.to_string(),
                    self.font_size, Color::BLACK, self.geo.cell_w, raster_scale, 0, Color::BLACK);
            }
        }
        if self.visual_bell_remaining > 0.0 {
            let mut tint = self.options.visual_bell_color;
            tint.a *=
                (self.visual_bell_remaining / self.options.visual_bell_duration.max(0.001)) as f32;
            rs.canvas_item_add_rect(self.canvas_quick, Rect2::new(Vector2::ZERO, size), tint);
        }
        if self.exited {
            rs.canvas_item_add_rect(
                canvas_fg,
                Rect2::new(Vector2::ZERO, size),
                Color::from_rgba(0.0, 0.0, 0.0, 0.55),
            );
            let msg = "[process exited]";
            let primary = self.fonts.primary();
            let width = primary
                .get_string_size_ex(msg)
                .font_size(self.font_size)
                .done()
                .x;
            rs.text(primary, canvas_fg, Vector2::new((size.x - width) / 2.0, size.y / 2.0),
                msg, self.font_size, Color::WHITE, -1.0, raster_scale, 0, Color::WHITE);
        }

        let mut background = self.bg;
        background.a = self.bg_opacity;
        let frame = rs.finish(self.image_material.as_ref(), background);
        self.visible_area.publish(visible_area);
        Ok((bg_changed, frame))
    }
}

/// PNG for the Kitty graphics protocol, decoded by Godot.
///
/// libghostty accepts `f=100` only if its embedder supplies a decoder — its
/// own RustPngDecoder needs the crate's `png` feature and has no public
/// constructor anyway.
///
/// Godot decodes PNG already, so this links no image codec of its own, the
/// same reason the texture path hands bytes straight to the engine.
fn decode_inline_image(data: &[u8]) -> Option<(Vec<u8>, u32, u32)> {
    let mut image = GdImage::new_gd();
    let bytes = PackedByteArray::from(data);
    let result = if data.starts_with(b"\x89PNG") {
        image.load_png_from_buffer(&bytes)
    } else if data.starts_with(b"\xff\xd8") {
        image.load_jpg_from_buffer(&bytes)
    } else if data.starts_with(b"RIFF") {
        image.load_webp_from_buffer(&bytes)
    } else if data.starts_with(b"BM") {
        image.load_bmp_from_buffer(&bytes)
    } else {
        return None;
    };
    if result != GdError::OK {
        return None;
    }
    Some((
        image.save_png_to_buffer().to_vec(),
        image.get_width() as u32,
        image.get_height() as u32,
    ))
}

struct GodotPngDecoder;

impl kgfx::DecodePng for GodotPngDecoder {
    fn decode_png<'alloc>(
        &mut self,
        alloc: &'alloc VtAllocator<'_>,
        data: &[u8],
    ) -> Option<kgfx::DecodedImage<'alloc>> {
        let started = std::time::Instant::now();
        let mut image = GdImage::new_gd();
        if image.load_png_from_buffer(&PackedByteArray::from(data)) != GdError::OK {
            return None;
        }
        // libghostty takes RGBA8 and nothing else.
        if image.get_format() != GdImageFormat::RGBA8 {
            image.convert(GdImageFormat::RGBA8);
        }
        let pixels = image.get_data();
        // The buffer must come from libghostty's allocator; it frees it.
        let mut bytes = VtBytes::new_zeroed_with_alloc(alloc, pixels.len()).ok()?;
        trace_decode(
            "godot",
            image.get_width() as u32,
            image.get_height() as u32,
            started,
        );
        bytes.copy_from_slice(pixels.as_slice());
        Some(kgfx::DecodedImage {
            width: image.get_width() as u32,
            height: image.get_height() as u32,
            data: bytes,
        })
    }
}

/// PNG decoded by the `png` crate, straight into libghostty's own buffer.
///
/// This is the same decoder libghostty's RustPngDecoder wraps, minus its
/// extra copy: it allocates the destination first and lets `next_frame` write
/// there, so the bytes are touched once.
///
/// It also calls nothing in the engine, which matters the day the pty is
/// drained off the main thread — a Godot decode in that callback would be a
/// threading bug, this is not.
struct PngCrateDecoder;

impl kgfx::DecodePng for PngCrateDecoder {
    fn decode_png<'alloc>(
        &mut self,
        alloc: &'alloc VtAllocator<'_>,
        data: &[u8],
    ) -> Option<kgfx::DecodedImage<'alloc>> {
        use png::{Decoder, Transformations};

        let started = std::time::Instant::now();
        let mut decoder = Decoder::new(std::io::Cursor::new(data));
        // libghostty takes RGBA8 only: expand palette and grayscale, drop 16-bit.
        decoder.set_transformations(Transformations::ALPHA | Transformations::STRIP_16);
        let mut frame = decoder.read_info().ok()?;
        let size = frame.output_buffer_size()?;
        let mut bytes = VtBytes::new_zeroed_with_alloc(alloc, size).ok()?;
        let info = frame.next_frame(&mut bytes).ok()?;
        frame.finish().ok()?;
        trace_decode("png", info.width, info.height, started);
        Some(kgfx::DecodedImage {
            width: info.width,
            height: info.height,
            data: bytes,
        })
    }
}

fn trace_decode(which: &str, width: u32, height: u32, started: std::time::Instant) {
    if std::env::var_os("GRAFFITTY_IMAGE_TRACE").is_some() {
        godot_print!(
            "[image] {which} decoded {width}x{height} in {:.2} ms",
            started.elapsed().as_secs_f64() * 1000.0
        );
    }
}

/// Set `GRAFFITTY_VT_LOG` to send libghostty diagnostics to stderr.
///
/// Use it to see why the VT rejected an image, such as an APC payload
/// over budget, an unsupported medium, or oversized dimensions.
fn install_vt_log() {
    if std::env::var_os("GRAFFITTY_VT_LOG").is_none() {
        return;
    }
    thread_local! {
        static INSTALLED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }
    INSTALLED.with(|installed| {
        if installed.get() {
            return;
        }
        installed.set(true);
        // SAFETY: installed once, on Godot's main thread, before any terminal
        // exists; libghostty does not lock this process-wide hook.
        if let Err(e) =
            unsafe { libghostty_vt::log::set_logger(Some(Box::new(libghostty_vt::log::LogStderr))) }
        {
            godot_warn!("[graffitty] vt logging unavailable: {e}");
        }
    });
}

/// Once per thread, before any terminal starts reading.
fn install_png_decoder() {
    thread_local! {
        static INSTALLED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    }
    INSTALLED.with(|installed| {
        if installed.get() {
            return;
        }
        installed.set(true);
        // Set `GRAFFITTY_PNG_DECODER=godot` to use the engine decoder.
        // Use it for comparisons or as a fallback if the Rust decoder fails.
        //
        // One 1280×720 PNG took 6.05 ms with png and 10.69 ms with Godot.
        // The zune-png trial took 7.93 ms.
        let decoder: Box<dyn kgfx::DecodePng> =
            match std::env::var("GRAFFITTY_PNG_DECODER").as_deref() {
                Ok("godot") => Box::new(GodotPngDecoder),
                _ => Box::new(PngCrateDecoder),
            };
        // SAFETY: installed once, on Godot's main thread, before the first
        // terminal parses; libghostty does not lock this process-wide hook.
        if let Err(e) = unsafe { kgfx::set_png_decoder(Some(decoder)) } {
            godot_warn!("[graffitty] kitty graphics png decoder unavailable: {e}");
        }
    });
}

/// A Godot texture for a kitty image, kept by image id.
///
/// Godot decodes PNG and inflates deflate itself, so this extension links no
/// image codec of its own: the bytes go straight to the engine.
fn kitty_texture(
    cache: &mut HashMap<u32, (u64, Gd<ImageTexture>)>,
    id: u32,
    image: &kgfx::Image<'_>,
) -> Option<Rid> {
    let generation = image.generation().ok()?;
    if let Some((stored, texture)) = cache.get(&id) {
        if *stored == generation {
            return Some(texture.get_rid());
        }
    }
    let width = image.width().ok()? as i32;
    let height = image.height().ok()? as i32;
    let format = image.format().ok()?;
    let compression = image.compression().ok()?;
    let mut bytes = PackedByteArray::from(image.data().ok()??);
    if matches!(compression, kgfx::Compression::ZlibDeflate) {
        // zlib is raw deflate behind a two-byte header, and DEFLATE is the mode
        // Godot exposes. Channels come from the format, four at most.
        let expected = (width as usize) * (height as usize) * 4;
        let body = bytes.subarray(2..);
        bytes = body.decompress(expected, CompressionMode::DEFLATE).ok()?;
    }
    let gd_image = match format {
        kgfx::ImageFormat::Png => {
            let mut img = GdImage::new_gd();
            if img.load_png_from_buffer(&bytes) != GdError::OK {
                return None;
            }
            img
        }
        kgfx::ImageFormat::Rgba => {
            GdImage::create_from_data(width, height, false, GdImageFormat::RGBA8, &bytes)?
        }
        kgfx::ImageFormat::Rgb => {
            GdImage::create_from_data(width, height, false, GdImageFormat::RGB8, &bytes)?
        }
        kgfx::ImageFormat::GrayAlpha => {
            GdImage::create_from_data(width, height, false, GdImageFormat::LA8, &bytes)?
        }
        kgfx::ImageFormat::Gray => {
            GdImage::create_from_data(width, height, false, GdImageFormat::L8, &bytes)?
        }
        // The enum can grow; a format this build does not know is not drawn.
        _ => return None,
    };
    let texture = ImageTexture::create_from_image(&gd_image)?;
    let rid = texture.get_rid();
    cache.insert(id, (generation, texture));
    Some(rid)
}

fn color(c: RgbColor) -> Color {
    Color::from_rgba8(c.r, c.g, c.b, 255)
}

/// Keep the original match ink legible, including dark ANSI colors.
fn flash_match_background(fg: RgbColor) -> RgbColor {
    if color(fg).srgb_to_linear().luminance() > 0.18 {
        RgbColor { r: 18, g: 22, b: 30 }
    } else {
        RgbColor {
            r: 230,
            g: 235,
            b: 245,
        }
    }
}

/// Apply `background_opacity` to the default background. Explicit cell
/// colors remain opaque, so `\033[41m` stays red over any world.
///
/// `draw()` fills the entire control with the default color and alpha.
/// Skip default cells here to avoid painting the fill twice. For example,
/// compositing 0.5 alpha over 0.5 gives 0.75.
fn cell_bg(c: RgbColor, default: RgbColor) -> Option<Color> {
    (c != default).then(|| color(c))
}

/// Copy/paste chord: Cmd on macOS, Ctrl+Shift elsewhere. A key for copy mode.
///
/// Letters come from the Latin keycode: an input method in Hangul mode
/// reports jamo, or no text, for the same physical keys. The search prompt
/// takes typed text instead, including committed syllables.
fn copy_input(key: &Gd<InputEventKey>, text: bool) -> Option<CopyInput> {
    if key.is_meta_pressed() {
        return None;
    }
    let code = key.get_keycode();
    let (ctrl, shift) = (key.is_ctrl_pressed(), key.is_shift_pressed());
    let named = match code {
        GKey::ESCAPE => Some(CopyKey::Escape),
        GKey::ENTER | GKey::KP_ENTER => Some(CopyKey::Enter),
        GKey::BACKSPACE => Some(CopyKey::Backspace),
        GKey::TAB => Some(CopyKey::Tab),
        GKey::UP => Some(CopyKey::Up),
        GKey::DOWN => Some(CopyKey::Down),
        GKey::LEFT => Some(CopyKey::Left),
        GKey::RIGHT => Some(CopyKey::Right),
        GKey::PAGEUP => Some(CopyKey::PageUp),
        GKey::PAGEDOWN => Some(CopyKey::PageDown),
        GKey::HOME => Some(CopyKey::Home),
        GKey::END => Some(CopyKey::End),
        GKey::F3 => Some(CopyKey::F3),
        _ => None,
    };
    if let Some(named) = named {
        return Some(CopyInput { key: named, ctrl, shift });
    }
    let letter = (GKey::A.ord()..=GKey::Z.ord()).contains(&code.ord()).then(|| {
        let c = char::from(b'a' + (code.ord() - GKey::A.ord()) as u8);
        if shift { c.to_ascii_uppercase() } else { c }
    });
    let typed = char::from_u32(key.get_unicode()).filter(|c| !c.is_control() && *c != '\0');
    let c = if text && !ctrl {
        typed?
    } else if key.is_alt_pressed() {
        return None;
    } else {
        letter
            .or(typed)
            .or((code == GKey::SPACE).then_some(' '))?
    };
    Some(CopyInput { key: CopyKey::Char(c), ctrl, shift })
}

fn is_chord(key: &Gd<InputEventKey>, which: GKey) -> bool {
    if key.get_keycode() != which {
        return false;
    }
    if cfg!(target_os = "macos") {
        key.is_meta_pressed()
    } else {
        key.is_ctrl_pressed() && key.is_shift_pressed()
    }
}

/// Chords that belong to the editor even while a terminal is focused,
/// from the editor setting registered by the plugin.
fn is_editor_passthrough(key: &Gd<InputEventKey>) -> bool {
    if !(key.is_ctrl_pressed() || key.is_alt_pressed() || key.is_meta_pressed()) {
        return false;
    }
    if !Engine::singleton().is_editor_hint() {
        return false;
    }
    let Some(settings) = EditorInterface::singleton().get_editor_settings() else {
        return false;
    };
    // The toggle shortcut is always passed through, no separate listing.
    if plugin::shortcut_matches(plugin::TOGGLE_SHORTCUT, &key.clone().upcast::<InputEvent>()) {
        return true;
    }
    let chords = settings
        .get_setting(plugin::PASSTHROUGH_SETTING)
        .try_to::<GString>()
        .unwrap_or_default();
    let combo = key.get_keycode_with_modifiers();
    let os = Os::singleton();
    chords
        .to_string()
        .split(',')
        .map(str::trim)
        .filter(|chord| !chord.is_empty())
        .any(|chord| os.find_keycode_from_string(chord) == combo)
}

#[derive(Default)]
struct Integration {
    observer: crate::protocol::Observer,
    title_stack: Vec<String>,
    notification: Option<(String, String)>,
    pointers: crate::protocol::Pointers,
    clipboard_request: Option<(i64, u8, bool)>,
    announce_clipboard: bool,
    clipboard: crate::clipboard::Transfer,
    inline_images: crate::inline_images::Images,
    extended_read: Option<(bool, Vec<String>)>,
    notification_commands: Vec<String>,
    clipboard_generation: i64,
    remote_clipboard_ticket: Option<i64>,
}
impl Integration {
    fn clipboard_operation(&mut self, operation: graffitty_protocol::clipboard::Operation, read_policy: i32, write_enabled: bool) -> String {
        use graffitty_protocol::clipboard::Operation;
        match operation {
            Operation::Rich { packet } => self.rich_clipboard(&packet, read_policy, write_enabled),
            Operation::ReadText { selector, bel } => {
                if !matches!(selector, b'c' | b'p' | b's') || (selector != b'c' && !DisplayServer::singleton().has_feature(DisplayFeature::CLIPBOARD_PRIMARY)) { return String::new(); }
                if read_policy == 2 { clipboard_text_reply(selector, bel) }
                else {
                    if read_policy == 1 && self.clipboard_request.is_none() {
                        self.clipboard_request = Some((next_clipboard_request(), selector, bel));
                        self.announce_clipboard = true;
                    }
                    String::new()
                }
            }
            Operation::WriteText { selector, encoded } => {
                if write_enabled && matches!(selector, b'c' | b'p' | b's') && (selector == b'c' || DisplayServer::singleton().has_feature(DisplayFeature::CLIPBOARD_PRIMARY)) {
                    if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(encoded) {
                        if bytes.len() <= 1024 * 1024 {
                            if let Ok(text) = String::from_utf8(bytes) { crate::clipboard::write_text(selector != b'c', &text); }
                        }
                    }
                }
                String::new()
            }
        }
    }
    fn rich_clipboard(&mut self, packet: &str, read_policy: i32, write_enabled: bool) -> String {
        match self.clipboard.feed(packet, write_enabled) {
            crate::clipboard::Action::None => String::new(),
            crate::clipboard::Action::Reply(reply) => reply,
            crate::clipboard::Action::Read { primary, types } => {
                if types == ["."] || read_policy == 2 { crate::clipboard::read(primary, &types) }
                else if read_policy == 0 { crate::clipboard::status("read", "EPERM") }
                else if self.clipboard_request.is_some() { crate::clipboard::status("read", "EBUSY") }
                else {
                    let id = next_clipboard_request();
                    self.clipboard_request = Some((id, if primary { b'p' } else { b'c' }, false));
                    self.extended_read = Some((primary, types));
                    self.announce_clipboard = true;
                    String::new()
                }
            }
        }
    }
    fn feed(
        &mut self,
        vt: &mut Vt<'static, 'static>,
        writer: &Writer,
        bytes: &[u8],
        _read_policy: i32,
        _write_enabled: bool,
        cell: (u32, u32),
    ) {
        use crate::protocol::Event;
        let before = vt.active_screen().ok();
        let mut events = Vec::new();
        self.observer.feed_each(bytes, |end, event| events.push((end, event)));
        let mut offset = 0;
        for (end, event) in events {
            vt.vt_write(&bytes[offset..end]);
            offset = end;
            match event {
                // Clipboard side effects arrive exclusively through the owner-routed
                // channel, never through replayable presentation bytes.
                Event::ClipboardRead(_, _) | Event::ClipboardWrite(_, _) | Event::Clipboard5522(_) => {},
                Event::Notification(title, body) => self.notification = Some((title, body)),
                Event::Pointer(shape) => {
                    if let Some(reply) = self
                        .pointers
                        .apply(vt.active_screen().ok() == Some(Screen::Alternate), &shape)
                    {
                        writer.write(reply.as_bytes());
                    }
                }
                Event::Reset => {
                    self.pointers = Default::default();
                    self.title_stack.clear();
                }
                Event::Sixel(data) => {
                    if let Some((png, w, h)) = crate::inline_images::sixel(&data) {
                        crate::inline_images::place(vt, &png, w, h, cell);
                    }
                }
                Event::ItermImage(packet) => {
                    self.inline_images
                        .iterm(&packet, vt, cell, decode_inline_image)
                }
                Event::KittyHeader(_) => {}
                Event::Erase { command, count } => crate::inline_images::erase(vt, command, count),
                Event::Capabilities(query) => {
                    writer.write(crate::protocol::capabilities(&query).as_bytes())
                }
                Event::Notify99(packet) => {
                    // Preserve metadata and order for application-owned native lifetimes.
                    if let Some(reply) = crate::protocol::notification_query(&packet) {
                        writer.write(reply.as_bytes());
                    } else if self.notification_commands.len() < 256 && packet.len() <= 8192 {
                        self.notification_commands.push(packet);
                    }
                }
                Event::TitlePush => {
                    if self.title_stack.len() == 16 {
                        self.title_stack.remove(0);
                    }
                    self.title_stack.push(String::from_utf8_lossy(vt.title().unwrap_or(b"")).into_owned());
                }
                Event::TitlePop => {
                    if let Some(title) = self.title_stack.pop() {
                        let safe: String = title.chars().filter(|c| !c.is_control()).collect();
                        vt.vt_write(format!("\x1b]2;{safe}\x1b\\").as_bytes());
                    }
                }
            }
        }
        vt.vt_write(&bytes[offset..]);
        // Returning from a full-screen app must reveal the restored shell,
        // rather than a previously scrolled primary viewport.
        if before == Some(Screen::Alternate) && vt.active_screen().ok() == Some(Screen::Primary) {
            vt.scroll_viewport(ScrollViewport::Bottom);
        }
    }
}
fn next_clipboard_request() -> i64 {
    static NEXT: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(1);
    NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
}
fn clipboard_text_reply(selector: u8, bel: bool) -> String {
    let ds = DisplayServer::singleton();
    if selector != b'c' && !ds.has_feature(DisplayFeature::CLIPBOARD_PRIMARY) { return String::new(); }
    let text = if selector == b'c' { ds.clipboard_get() } else { ds.clipboard_get_primary() }.to_string();
    if text.len() > 1024 * 1024 { return String::new(); }
    format!("\x1b]52;{};{}{}", selector as char,
        base64::engine::general_purpose::STANDARD.encode(text.as_bytes()),
        if bel { "\x07" } else { "\x1b\\" })
}

/// Mobile and remote clients open only web URLs on this device; other schemes
/// name resources on the shell's host. Applies to custom handlers too.
fn can_open_link(uri: &str, web_only: bool) -> bool {
    crate::protocol::openable_link(uri)
        && (crate::protocol::web_link(uri)
            || !(cfg!(any(target_os = "android", target_os = "ios")) || web_only))
}

fn pointer_shape(name: &str) -> godot::classes::control::CursorShape {
    use godot::classes::control::CursorShape as C;
    match name {
        "pointer" => C::POINTING_HAND,
        "crosshair" => C::CROSS,
        "wait" => C::WAIT,
        "progress" => C::BUSY,
        "not-allowed" | "no-drop" => C::FORBIDDEN,
        "move" | "all-scroll" => C::MOVE,
        "help" => C::HELP,
        "ew-resize" | "col-resize" => C::HSIZE,
        "ns-resize" | "row-resize" => C::VSIZE,
        "nesw-resize" => C::BDIAGSIZE,
        "nwse-resize" => C::FDIAGSIZE,
        "default" => C::ARROW,
        _ => C::IBEAM,
    }
}
