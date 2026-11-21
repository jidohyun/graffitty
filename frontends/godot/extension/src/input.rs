use graffitty_terminal_core::vt as libghostty_vt;
use std::time::Instant;

use godot::classes::{InputEventKey, InputEventWithModifiers};
use godot::global::Key as GKey;
use godot::obj::Gd;
use libghostty_vt::key::{self, Key};
use libghostty_vt::selection::gesture::{
    Autoscroll, AutoscrollTickEvent, DragEvent, Geometry, Gesture, PressEvent, ReleaseEvent,
};
use libghostty_vt::terminal::{Point, PointCoordinate};
use libghostty_vt::{Terminal, mouse};

/// Pixel geometry for mapping surface positions to cells.
#[derive(Clone, Copy)]
pub struct MouseGeometry {
    pub screen_width: u32,
    pub screen_height: u32,
    pub cell_width: u32,
    pub cell_height: u32,
    pub padding: u32,
}

impl MouseGeometry {
    fn encoder_size(self) -> mouse::EncoderSize {
        mouse::EncoderSize {
            screen_width: self.screen_width,
            screen_height: self.screen_height,
            cell_width: self.cell_width,
            cell_height: self.cell_height,
            padding_top: self.padding,
            padding_bottom: self.padding,
            padding_left: self.padding,
            padding_right: self.padding,
        }
    }

    fn gesture_geometry(self, term: &Terminal<'static, 'static>) -> Geometry {
        Geometry {
            columns: u32::from(term.cols().unwrap_or(1)),
            cell_width: self.cell_width.max(1),
            padding_left: self.padding,
            screen_height: self.screen_height.max(1),
        }
    }

    fn viewport_coord(self, term: &Terminal<'static, 'static>, x: f32, y: f32) -> PointCoordinate {
        let pad = self.padding as f32;
        let cols = term.cols().unwrap_or(1);
        let rows = term.rows().unwrap_or(1);
        let cx = if x > pad {
            ((x - pad) / self.cell_width.max(1) as f32)
                .clamp(0.0, f32::from(cols.saturating_sub(1))) as u16
        } else {
            0
        };
        let cy = if y > pad {
            ((y - pad) / self.cell_height.max(1) as f32)
                .clamp(0.0, f32::from(rows.saturating_sub(1))) as u32
        } else {
            0
        };
        PointCoordinate { x: cx, y: cy }
    }

    fn viewport_point(self, term: &Terminal<'static, 'static>, x: f32, y: f32) -> Point {
        Point::Viewport(self.viewport_coord(term, x, y))
    }
}

pub struct Input {
    key_encoder: key::Encoder<'static>,
    key_event: key::Event<'static>,
    mouse_encoder: mouse::Encoder<'static>,
    mouse_event: mouse::Event<'static>,
    gesture: Gesture<'static>,
    press: PressEvent<'static>,
    release: ReleaseEvent<'static>,
    drag: DragEvent<'static>,
    autoscroll: AutoscrollTickEvent<'static>,
    epoch: Instant,
    buf: Vec<u8>,
}

impl Input {
    pub fn reset_tracking(&mut self, vt: &Terminal<'static, 'static>) { self.gesture.reset(vt); }
    pub fn new() -> libghostty_vt::error::Result<Self> {
        let mut press = PressEvent::new()?;
        press.set_repeat_interval(std::time::Duration::from_millis(500))?;
        Ok(Self {
            key_encoder: key::Encoder::new()?,
            key_event: key::Event::new()?,
            mouse_encoder: mouse::Encoder::new()?,
            mouse_event: mouse::Event::new()?,
            gesture: Gesture::new()?,
            press,
            release: ReleaseEvent::new()?,
            drag: DragEvent::new()?,
            autoscroll: AutoscrollTickEvent::new()?,
            epoch: Instant::now(),
            buf: Vec::with_capacity(64),
        })
    }

    pub fn set_word_boundaries(&mut self, boundaries: Option<&[char]>) {
        // Recreate gesture events to restore library defaults when unset.
        if let (Ok(press), Ok(drag), Ok(release), Ok(autoscroll)) = (
            PressEvent::new(),
            DragEvent::new(),
            ReleaseEvent::new(),
            AutoscrollTickEvent::new(),
        ) {
            self.press = press;
            self.drag = drag;
            self.release = release;
            self.autoscroll = autoscroll;
            let _ = self
                .press
                .set_repeat_interval(std::time::Duration::from_millis(500));
            if let Some(chars) = boundaries {
                let _ = self.press.set_word_boundary_codepoints(chars);
                let _ = self.drag.set_word_boundary_codepoints(chars);
                let _ = self.autoscroll.set_word_boundary_codepoints(chars);
            }
        }
    }

    /// Encode a key event as PTY bytes using the terminal's current modes.
    ///
    /// `composing` means an IME composition is active. If the IME consumed the
    /// key, the event still has a physical keycode, but its text went into the
    /// composition.
    ///
    /// Legacy encodings emit no bytes for that event. The Kitty keyboard
    /// protocol also sees the physical key, so an app such as Neovim can
    /// receive `k` beside `ㅏ` once per syllable started.
    pub fn encode_key(
        &mut self,
        term: &Terminal<'static, 'static>,
        ev: &Gd<InputEventKey>,
        composing: bool,
    ) -> &[u8] {
        self.buf.clear();

        // ConPTY accepts Win32 key records. Preserve modified Enter for native
        // console applications (e.g. crossterm), which cannot opt into kitty.
        // https://github.com/microsoft/terminal/blob/main/src/terminal/input/terminalInput.cpp
        #[cfg(windows)]
        if ev.get_keycode() == GKey::ENTER
            && (ev.is_shift_pressed() || ev.is_ctrl_pressed() || ev.is_alt_pressed())
            && !ev.is_meta_pressed()
        {
            let modifiers = u8::from(ev.is_shift_pressed()) * 16
                + u8::from(ev.is_ctrl_pressed()) * 8
                + u8::from(ev.is_alt_pressed()) * 2;
            self.buf.extend_from_slice(
                format!("\x1b[13;28;13;{};{modifiers};1_", u8::from(ev.is_pressed())).as_bytes());
            return &self.buf;
        }

        let action = if ev.is_echo() {
            key::Action::Repeat
        } else if ev.is_pressed() {
            key::Action::Press
        } else {
            key::Action::Release
        };

        let mods = event_mods(ev.clone().upcast());
        // macOS keycode translation may fall back to the physical US key when
        // Option produces a non-ASCII symbol. key_label retains the active
        // layout's unmodified key, including for releases and dead keys.
        let layout_key = if cfg!(target_os = "macos") && mods.contains(key::Mods::ALT) {
            map_key(ev.get_key_label()).or_else(|| map_key(ev.get_keycode()))
        } else {
            map_key(ev.get_keycode())
        };
        let (vt_key, unshifted) = layout_key.unwrap_or((Key::Unidentified, '\0'));

        // Preserve the layout's character for Ctrl+Shift combinations too:
        // Ghostty needs it to distinguish those shortcuts from plain Ctrl.
        // Windows AltGr additionally consumes Ctrl+Alt when producing text.
        let altgr =
            cfg!(windows) && mods.contains(key::Mods::CTRL) && mods.contains(key::Mods::ALT);
        let text = key_text(ev.get_unicode(), unshifted, mods, action);

        // Missing text can signal IME consumption only for a text key
        // pressed without Control, Alt, or Command.
        //
        // Escape, Enter, and arrow keys remain reportable. The macOS shim can
        // replay them after a commit.
        if composing
            && text.is_none()
            && unshifted != '\0'
            && !mods.intersects(key::Mods::CTRL | key::Mods::ALT | key::Mods::SUPER)
        {
            return &self.buf;
        }

        // Modifiers that already shaped the produced text are consumed.
        let consumed = match text {
            Some(_) if altgr => mods & (key::Mods::SHIFT | key::Mods::CTRL | key::Mods::ALT),
            Some(_) if !mods.contains(key::Mods::CTRL) => mods & key::Mods::SHIFT,
            _ => key::Mods::empty(),
        };

        let mut utf8 = [0u8; 4];
        self.key_event
            .set_action(action)
            .set_key(vt_key)
            .set_mods(mods)
            .set_consumed_mods(consumed)
            .set_unshifted_codepoint(unshifted)
            .set_utf8(text.map(|ch| &*ch.encode_utf8(&mut utf8)));

        let _ = crate::key_encoding::encode(
            term,
            &mut self.key_encoder,
            &self.key_event,
            &mut self.buf,
        );
        &self.buf
    }

    pub fn encode_button(
        &mut self,
        term: &Terminal<'static, 'static>,
        button: mouse::Button,
        pressed: bool,
        mods: key::Mods,
        pos: (f32, f32),
        geo: MouseGeometry,
    ) -> &[u8] {
        self.buf.clear();
        self.mouse_event
            .set_mods(mods)
            .set_position(mouse::Position { x: pos.0, y: pos.1 })
            .set_button(Some(button))
            .set_action(if pressed {
                mouse::Action::Press
            } else {
                mouse::Action::Release
            });
        let _ = self
            .mouse_encoder
            .set_options_from_terminal(term)
            .set_size(geo.encoder_size())
            .and_then(|encoder| encoder.encode_to_vec(&self.mouse_event, &mut self.buf));
        &self.buf
    }

    pub fn encode_motion(
        &mut self,
        term: &Terminal<'static, 'static>,
        held: Option<mouse::Button>,
        mods: key::Mods,
        pos: (f32, f32),
        geo: MouseGeometry,
    ) -> &[u8] {
        self.buf.clear();
        self.mouse_event
            .set_mods(mods)
            .set_position(mouse::Position { x: pos.0, y: pos.1 })
            .set_button(held)
            .set_action(mouse::Action::Motion);
        let _ = self
            .mouse_encoder
            .set_options_from_terminal(term)
            .set_size(geo.encoder_size())
            .and_then(|encoder| encoder
                .set_any_button_pressed(held.is_some())
                .set_track_last_cell(true)
                .encode_to_vec(&self.mouse_event, &mut self.buf));
        &self.buf
    }

    /// Wheel tick as a mouse button 4/5 press; wheel buttons never release.
    pub fn encode_scroll(
        &mut self,
        term: &Terminal<'static, 'static>,
        up: bool,
        mods: key::Mods,
        pos: (f32, f32),
        geo: MouseGeometry,
    ) -> &[u8] {
        self.buf.clear();

        let button = if up {
            mouse::Button::Four
        } else {
            mouse::Button::Five
        };

        self.mouse_event
            .set_mods(mods)
            .set_position(mouse::Position { x: pos.0, y: pos.1 })
            .set_button(Some(button))
            .set_action(mouse::Action::Press);
        let _ = self
            .mouse_encoder
            .set_options_from_terminal(term)
            .set_size(geo.encoder_size())
            .and_then(|encoder| encoder.encode_to_vec(&self.mouse_event, &mut self.buf));
        &self.buf
    }

    /// Left press; repeated clicks widen to word/line via gesture state.
    pub fn selection_press(
        &mut self,
        term: &Terminal<'static, 'static>,
        x: f32,
        y: f32,
        geo: MouseGeometry,
    ) {
        let point = geo.viewport_point(term, x, y);
        let Ok(grid_ref) = term.grid_ref(point) else {
            return;
        };
        let selection = self
            .press
            .set_repeat_distance(f64::from(geo.cell_width))
            .and_then(|e| e.set_time(graffitty_terminal_core::selection::gesture_event_time(self.epoch.elapsed())))
            .and_then(|e| e.set_position(f64::from(x), f64::from(y)))
            .and_then(|e| e.apply(&mut self.gesture, term, grid_ref));
        if let Ok(selection) = selection {
            let _ = term.set_selection(selection.as_ref());
        }
    }

    pub fn selection_drag(
        &mut self,
        term: &Terminal<'static, 'static>,
        x: f32,
        y: f32,
        rectangle: bool,
        geo: MouseGeometry,
    ) {
        let point = geo.viewport_point(term, x, y);
        let Ok(grid_ref) = term.grid_ref(point) else {
            return;
        };
        let selection = self
            .drag
            .set_rectangle(rectangle)
            .and_then(|e| e.set_position(f64::from(x), f64::from(y)))
            .and_then(|e| {
                e.apply(
                    &mut self.gesture,
                    term,
                    grid_ref,
                    geo.gesture_geometry(term),
                )
            });
        if let Ok(selection) = selection {
            let _ = term.set_selection(selection.as_ref());
        }
    }

    pub fn selection_release(
        &mut self,
        term: &Terminal<'static, 'static>,
        x: f32,
        y: f32,
        geo: MouseGeometry,
    ) {
        let point = geo.viewport_point(term, x, y);
        let grid_ref = term.grid_ref(point).ok();
        let _ = self.release.apply(&mut self.gesture, term, grid_ref);
    }

    /// Scroll and extend the selection while a drag sits past the viewport
    /// edges. Returns whether a tick ran.
    pub fn selection_autoscroll(
        &mut self,
        term: &Terminal<'static, 'static>,
        x: f32,
        y: f32,
        rectangle: bool,
        geo: MouseGeometry,
    ) -> bool {
        if !matches!(
            self.gesture.autoscroll(term),
            Ok(Autoscroll::Up | Autoscroll::Down)
        ) {
            return false;
        }
        let viewport = geo.viewport_coord(term, x, y);
        let selection = self
            .autoscroll
            .set_rectangle(rectangle)
            .and_then(|e| e.set_position(f64::from(x), f64::from(y)))
            .and_then(|e| {
                e.apply(
                    &mut self.gesture,
                    term,
                    viewport,
                    geo.gesture_geometry(term),
                )
            });
        if let Ok(selection) = selection {
            let _ = term.set_selection(selection.as_ref());
        }
        true
    }
}

/// Visual typing activity shared by direct (Android) and focused GUI input.
/// Arrow navigation and key releases still encode normally, without effects.
pub fn typing_unicode(ev: &Gd<InputEventKey>) -> Option<i64> {
    if !ev.is_pressed()
        || matches!(ev.get_keycode(), GKey::LEFT | GKey::RIGHT | GKey::UP | GKey::DOWN)
    {
        return None;
    }
    Some(match ev.get_keycode() {
        GKey::BACKSPACE => 8,
        GKey::DELETE => 127,
        _ => i64::from(ev.get_unicode()),
    })
}

fn key_text(unicode: u32, unshifted: char, mods: key::Mods, action: key::Action) -> Option<char> {
    if action == key::Action::Release || mods.contains(key::Mods::SUPER) {
        return None;
    }
    if unicode >= 0x20 && unicode != 0x7f {
        return char::from_u32(unicode);
    }
    // Android hardware chords may supply zero (or a C0 byte) as unicode.
    // ASCII letters have a known shifted form; do not guess punctuation or
    // non-ASCII layout output. Keep the original Ctrl/Shift flags for encoding.
    if mods.contains(key::Mods::CTRL) && unshifted.is_ascii_lowercase() {
        return Some(if mods.contains(key::Mods::SHIFT) {
            unshifted.to_ascii_uppercase()
        } else {
            unshifted
        });
    }
    None
}

pub fn event_mods(ev: Gd<InputEventWithModifiers>) -> key::Mods {
    let mut mods = key::Mods::empty();
    if ev.is_shift_pressed() {
        mods |= key::Mods::SHIFT;
    }
    if ev.is_ctrl_pressed() {
        mods |= key::Mods::CTRL;
    }
    if ev.is_alt_pressed() {
        mods |= key::Mods::ALT;
    }
    if ev.is_meta_pressed() {
        mods |= key::Mods::SUPER;
    }
    mods
}

/// Godot keycode to libghostty key plus its unshifted codepoint.
fn map_key(key: GKey) -> Option<(Key, char)> {
    Some(match key {
        GKey::A => (Key::A, 'a'),
        GKey::B => (Key::B, 'b'),
        GKey::C => (Key::C, 'c'),
        GKey::D => (Key::D, 'd'),
        GKey::E => (Key::E, 'e'),
        GKey::F => (Key::F, 'f'),
        GKey::G => (Key::G, 'g'),
        GKey::H => (Key::H, 'h'),
        GKey::I => (Key::I, 'i'),
        GKey::J => (Key::J, 'j'),
        GKey::K => (Key::K, 'k'),
        GKey::L => (Key::L, 'l'),
        GKey::M => (Key::M, 'm'),
        GKey::N => (Key::N, 'n'),
        GKey::O => (Key::O, 'o'),
        GKey::P => (Key::P, 'p'),
        GKey::Q => (Key::Q, 'q'),
        GKey::R => (Key::R, 'r'),
        GKey::S => (Key::S, 's'),
        GKey::T => (Key::T, 't'),
        GKey::U => (Key::U, 'u'),
        GKey::V => (Key::V, 'v'),
        GKey::W => (Key::W, 'w'),
        GKey::X => (Key::X, 'x'),
        GKey::Y => (Key::Y, 'y'),
        GKey::Z => (Key::Z, 'z'),
        GKey::KEY_0 => (Key::Digit0, '0'),
        GKey::KEY_1 => (Key::Digit1, '1'),
        GKey::KEY_2 => (Key::Digit2, '2'),
        GKey::KEY_3 => (Key::Digit3, '3'),
        GKey::KEY_4 => (Key::Digit4, '4'),
        GKey::KEY_5 => (Key::Digit5, '5'),
        GKey::KEY_6 => (Key::Digit6, '6'),
        GKey::KEY_7 => (Key::Digit7, '7'),
        GKey::KEY_8 => (Key::Digit8, '8'),
        GKey::KEY_9 => (Key::Digit9, '9'),
        GKey::SPACE => (Key::Space, ' '),
        GKey::ENTER => (Key::Enter, '\0'),
        GKey::KP_ENTER => (Key::NumpadEnter, '\0'),
        GKey::KP_0 => (Key::Numpad0, '0'),
        GKey::KP_1 => (Key::Numpad1, '1'),
        GKey::KP_2 => (Key::Numpad2, '2'),
        GKey::KP_3 => (Key::Numpad3, '3'),
        GKey::KP_4 => (Key::Numpad4, '4'),
        GKey::KP_5 => (Key::Numpad5, '5'),
        GKey::KP_6 => (Key::Numpad6, '6'),
        GKey::KP_7 => (Key::Numpad7, '7'),
        GKey::KP_8 => (Key::Numpad8, '8'),
        GKey::KP_9 => (Key::Numpad9, '9'),
        GKey::KP_PERIOD => (Key::NumpadDecimal, '.'),
        GKey::KP_ADD => (Key::NumpadAdd, '+'),
        GKey::KP_SUBTRACT => (Key::NumpadSubtract, '-'),
        GKey::KP_MULTIPLY => (Key::NumpadMultiply, '*'),
        GKey::KP_DIVIDE => (Key::NumpadDivide, '/'),
        GKey::TAB => (Key::Tab, '\0'),
        GKey::BACKSPACE => (Key::Backspace, '\0'),
        GKey::ESCAPE => (Key::Escape, '\0'),
        GKey::UP => (Key::ArrowUp, '\0'),
        GKey::DOWN => (Key::ArrowDown, '\0'),
        GKey::LEFT => (Key::ArrowLeft, '\0'),
        GKey::RIGHT => (Key::ArrowRight, '\0'),
        GKey::HOME => (Key::Home, '\0'),
        GKey::END => (Key::End, '\0'),
        GKey::PAGEUP => (Key::PageUp, '\0'),
        GKey::PAGEDOWN => (Key::PageDown, '\0'),
        GKey::INSERT => (Key::Insert, '\0'),
        GKey::DELETE => (Key::Delete, '\0'),
        GKey::MINUS => (Key::Minus, '-'),
        GKey::EQUAL => (Key::Equal, '='),
        GKey::BRACKETLEFT => (Key::BracketLeft, '['),
        GKey::BRACKETRIGHT => (Key::BracketRight, ']'),
        GKey::BACKSLASH => (Key::Backslash, '\\'),
        GKey::SEMICOLON => (Key::Semicolon, ';'),
        GKey::APOSTROPHE => (Key::Quote, '\''),
        GKey::COMMA => (Key::Comma, ','),
        GKey::PERIOD => (Key::Period, '.'),
        GKey::SLASH => (Key::Slash, '/'),
        GKey::QUOTELEFT => (Key::Backquote, '`'),
        GKey::F1 => (Key::F1, '\0'),
        GKey::F2 => (Key::F2, '\0'),
        GKey::F3 => (Key::F3, '\0'),
        GKey::F4 => (Key::F4, '\0'),
        GKey::F5 => (Key::F5, '\0'),
        GKey::F6 => (Key::F6, '\0'),
        GKey::F7 => (Key::F7, '\0'),
        GKey::F8 => (Key::F8, '\0'),
        GKey::F9 => (Key::F9, '\0'),
        GKey::F10 => (Key::F10, '\0'),
        GKey::F11 => (Key::F11, '\0'),
        GKey::F12 => (Key::F12, '\0'),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_shift_letters_preserve_all_modifiers_in_terminal_encoding() {
        let mut term = graffitty_terminal_core::new_vt(80, 24, 0).unwrap();
        for extended in [false, true] {
            if extended {
                term.vt_write(b"\x1b[>1u");
            }
            for (mods, expected) in [
                (key::Mods::CTRL | key::Mods::SHIFT, b"\x1b[117;6u".as_slice()),
                (key::Mods::CTRL | key::Mods::ALT | key::Mods::SHIFT, b"\x1b[117;8u".as_slice()),
            ] {
                // IME printable text, Android key chords, and hardware C0 text.
                for unicode in [u32::from('U'), 0, 0x15] {
                    for action in [key::Action::Press, key::Action::Repeat] {
                        let text = key_text(unicode, 'u', mods, action).unwrap().to_string();
                        let mut event = key::Event::new().unwrap();
                        event.set_key(Key::U)
                            .set_unshifted_codepoint('u')
                            .set_mods(mods)
                            .set_action(action)
                            .set_utf8(Some(text.as_str()));
                        let mut encoder = key::Encoder::new().unwrap();
                        let mut bytes = Vec::new();
                        crate::key_encoding::encode(&term, &mut encoder, &event, &mut bytes).unwrap();
                        assert_eq!(bytes, expected, "unicode={unicode}, mods={mods:?}, extended={extended}");
                    }
                }
            }
        }
    }

    #[test]
    fn key_text_preserves_layout_text_and_omits_releases() {
        let press = key::Action::Press;
        assert_eq!(key_text(u32::from('한'), '\0', key::Mods::empty(), press), Some('한'));
        assert_eq!(key_text(u32::from('U'), 'u', key::Mods::SHIFT, press), Some('U'));
        assert_eq!(key_text(0x15, 'u', key::Mods::CTRL, press), Some('u'));
        assert_eq!(key_text(0, '=', key::Mods::CTRL | key::Mods::SHIFT, press), None);
        assert_eq!(key_text(u32::from('u'), 'u', key::Mods::SUPER, press), None);
        assert_eq!(key_text(u32::from('U'), 'u', key::Mods::CTRL | key::Mods::SHIFT, key::Action::Release), None);
    }
}
