//! Translate frontend input into libghostty events, with encoding owned by the VT.
//!
//! Application shortcuts must be handled before calling this module. `key` is
//! either a named key or the printable text produced by the keyboard layout.
use anyhow::{Result, bail, ensure};
use graffitty_terminal_core::vt::{Terminal, key, mouse};

pub use graffitty_terminal_core::vt::key::Action as KeyAction;
pub use graffitty_terminal_core::vt::mouse::{
    Action as MouseAction, Button as MouseButton, EncoderSize as MouseGeometry,
};

pub fn modifiers(ctrl: bool, alt: bool, shift: bool, meta: bool) -> key::Mods {
    let mut mods = key::Mods::empty();
    mods.set(key::Mods::CTRL, ctrl);
    mods.set(key::Mods::ALT, alt);
    mods.set(key::Mods::SHIFT, shift);
    mods.set(key::Mods::SUPER, meta);
    mods
}

pub fn encode(
    vt: &Terminal<'_, '_>,
    key: &str,
    ctrl: bool,
    alt: bool,
    shift: bool,
    meta: bool,
) -> Result<Vec<u8>> {
    encode_action(vt, key, ctrl, alt, shift, meta, KeyAction::Press)
}

/// Call for releases as well as presses: apps can request kitty event reporting.
pub fn encode_action(
    vt: &Terminal<'_, '_>,
    value: &str,
    ctrl: bool,
    alt: bool,
    shift: bool,
    meta: bool,
    action: KeyAction,
) -> Result<Vec<u8>> {
    if value.is_empty() {
        return Ok(Vec::new());
    }
    let (logical, unshifted, text) = identify(value)?;
    let mods = modifiers(ctrl, alt, shift, meta);
    let text = text.filter(|_| action != KeyAction::Release);
    let mut event = key::Event::new()?;
    event
        .set_action(action)
        .set_key(logical)
        .set_unshifted_codepoint(unshifted)
        .set_mods(mods)
        .set_consumed_mods(if text.is_some() && !ctrl && !meta {
            mods & key::Mods::SHIFT
        } else {
            key::Mods::empty()
        })
        .set_utf8(text);
    let mut encoder = key::Encoder::new()?;
    // Cursor/keypad application modes, kitty flags, modifyOtherKeys and Alt's
    // escape-prefix policy are read anew after every terminal mode change.
    encoder.set_options_from_terminal(vt);
    // This API's `alt` means terminal Alt. Native Option text/IME is resolved by
    // the frontend before reaching us; never silently drop a requested Alt.
    encoder.set_macos_option_as_alt(key::OptionAsAlt::True);
    let mut bytes = Vec::with_capacity(32);
    encoder.encode_to_vec(&event, &mut bytes)?;
    Ok(bytes)
}

fn identify(value: &str) -> Result<(key::Key, char, Option<&str>)> {
    use key::Key;
    let named = match value {
        "Enter" | "Return" | "\r" | "\n" => Some(Key::Enter),
        "Escape" | "Esc" | "\u{1b}" => Some(Key::Escape),
        "Backspace" | "\u{8}" | "\u{7f}" => Some(Key::Backspace),
        "Tab" | "\t" => Some(Key::Tab),
        "ArrowUp" => Some(Key::ArrowUp),
        "ArrowDown" => Some(Key::ArrowDown),
        "ArrowLeft" => Some(Key::ArrowLeft),
        "ArrowRight" => Some(Key::ArrowRight),
        "Home" => Some(Key::Home),
        "End" => Some(Key::End),
        "PageUp" => Some(Key::PageUp),
        "PageDown" => Some(Key::PageDown),
        "Delete" => Some(Key::Delete),
        "Insert" => Some(Key::Insert),
        "Shift" | "ShiftLeft" => Some(Key::ShiftLeft),
        "ShiftRight" => Some(Key::ShiftRight),
        "Control" | "ControlLeft" => Some(Key::ControlLeft),
        "ControlRight" => Some(Key::ControlRight),
        "Alt" | "AltLeft" => Some(Key::AltLeft),
        "AltRight" => Some(Key::AltRight),
        "Meta" | "MetaLeft" => Some(Key::MetaLeft),
        "MetaRight" => Some(Key::MetaRight),
        "CapsLock" => Some(Key::CapsLock),
        "NumLock" => Some(Key::NumLock),
        "ScrollLock" => Some(Key::ScrollLock),
        "PrintScreen" => Some(Key::PrintScreen),
        "Pause" => Some(Key::Pause),
        "NumpadEnter" => Some(Key::NumpadEnter),
        _ => None,
    };
    if let Some(key) = named {
        return Ok((key, '\0', None));
    }
    const FUNCTIONS: [Key; 25] = [
        Key::F1,
        Key::F2,
        Key::F3,
        Key::F4,
        Key::F5,
        Key::F6,
        Key::F7,
        Key::F8,
        Key::F9,
        Key::F10,
        Key::F11,
        Key::F12,
        Key::F13,
        Key::F14,
        Key::F15,
        Key::F16,
        Key::F17,
        Key::F18,
        Key::F19,
        Key::F20,
        Key::F21,
        Key::F22,
        Key::F23,
        Key::F24,
        Key::F25,
    ];
    if let Some(number) = value
        .strip_prefix('F')
        .and_then(|s| s.parse::<usize>().ok())
    {
        if let Some(key) = number.checked_sub(1).and_then(|n| FUNCTIONS.get(n)) {
            return Ok((*key, '\0', None));
        }
        bail!("Unknown function key {value}");
    }
    if value == "Space" {
        return Ok((Key::Space, ' ', Some(" ")));
    }
    let mut chars = value.chars();
    let ch = chars.next().expect("empty keys handled by encode_action");
    ensure!(
        chars.next().is_none(),
        "Expected one printable character or a named key, got {value:?}"
    );
    ensure!(
        !ch.is_control() && !(0xf700..=0xf8ff).contains(&(ch as u32)),
        "Expected printable key text, got {value:?}"
    );
    const LETTERS: [Key; 26] = [
        Key::A,
        Key::B,
        Key::C,
        Key::D,
        Key::E,
        Key::F,
        Key::G,
        Key::H,
        Key::I,
        Key::J,
        Key::K,
        Key::L,
        Key::M,
        Key::N,
        Key::O,
        Key::P,
        Key::Q,
        Key::R,
        Key::S,
        Key::T,
        Key::U,
        Key::V,
        Key::W,
        Key::X,
        Key::Y,
        Key::Z,
    ];
    const DIGITS: [Key; 10] = [
        Key::Digit0,
        Key::Digit1,
        Key::Digit2,
        Key::Digit3,
        Key::Digit4,
        Key::Digit5,
        Key::Digit6,
        Key::Digit7,
        Key::Digit8,
        Key::Digit9,
    ];
    let unshifted = match ch {
        'A'..='Z' => ch.to_ascii_lowercase(),
        '~' => '`',
        '!' => '1',
        '@' => '2',
        '#' => '3',
        '$' => '4',
        '%' => '5',
        '^' => '6',
        '&' => '7',
        '*' => '8',
        '(' => '9',
        ')' => '0',
        '_' => '-',
        '+' => '=',
        '{' => '[',
        '}' => ']',
        '|' => '\\',
        ':' => ';',
        '"' => '\'',
        '<' => ',',
        '>' => '.',
        '?' => '/',
        other => other,
    };
    let logical = match unshifted {
        'a'..='z' => LETTERS[unshifted as usize - 'a' as usize],
        '0'..='9' => DIGITS[unshifted as usize - '0' as usize],
        ' ' => Key::Space,
        '`' => Key::Backquote,
        '\\' => Key::Backslash,
        '[' => Key::BracketLeft,
        ']' => Key::BracketRight,
        ',' => Key::Comma,
        '=' => Key::Equal,
        '-' => Key::Minus,
        '.' => Key::Period,
        '\'' => Key::Quote,
        ';' => Key::Semicolon,
        '/' => Key::Slash,
        _ => Key::Unidentified,
    };
    Ok((logical, unshifted, Some(value)))
}

#[derive(Clone, Copy, Debug)]
pub struct MouseInput {
    pub action: MouseAction,
    /// For Motion, the currently held button, or None for a plain hover.
    pub button: Option<MouseButton>,
    /// Terminal surface pixels, after undoing world projection and pane offset.
    pub position: (f32, f32),
    pub geometry: MouseGeometry,
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub meta: bool,
}

/// Keep one encoder per pane to reuse the native encoder allocation.
pub struct MouseEncoder {
    encoder: mouse::Encoder<'static>,
}

impl MouseEncoder {
    pub fn new() -> Result<Self> {
        Ok(Self {
            encoder: mouse::Encoder::new()?,
        })
    }

    pub fn encode(&mut self, vt: &Terminal<'_, '_>, input: &MouseInput) -> Result<Vec<u8>> {
        ensure!(
            input.position.0.is_finite() && input.position.1.is_finite(),
            "Mouse position must be finite"
        );
        let size = input.geometry;
        ensure!(
            size.cell_width > 0
                && size.cell_height > 0
                && size.screen_width > 0
                && size.screen_height > 0,
            "Mouse geometry must be nonzero"
        );
        ensure!(
            u64::from(size.padding_left) + u64::from(size.padding_right)
                < u64::from(size.screen_width)
                && u64::from(size.padding_top) + u64::from(size.padding_bottom)
                    < u64::from(size.screen_height),
            "Padding must leave terminal content"
        );
        ensure!(
            input.action == MouseAction::Motion || input.button.is_some(),
            "Mouse press/release needs a button"
        );
        let mut event = mouse::Event::new()?;
        event
            .set_action(input.action)
            .set_button(input.button)
            .set_position(mouse::Position {
                x: input.position.0,
                y: input.position.1,
            })
            .set_mods(modifiers(input.ctrl, input.alt, input.shift, input.meta));
        self.encoder
            .set_options_from_terminal(vt)
            .set_size(size)?
            .set_any_button_pressed(input.action != MouseAction::Release && input.button.is_some())
            .set_track_last_cell(false);
        let mut bytes = Vec::with_capacity(32);
        self.encoder.encode_to_vec(&event, &mut bytes)?;
        Ok(bytes)
    }

    pub fn reset(&mut self) {
        self.encoder.reset();
    }
}

pub fn encode_mouse(vt: &Terminal<'_, '_>, input: &MouseInput) -> Result<Vec<u8>> {
    MouseEncoder::new()?.encode(vt, input)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn terminal() -> Terminal<'static, 'static> {
        graffitty_terminal_core::new_vt(80, 24, 100).unwrap()
    }

    #[test]
    fn modifier_abi_is_not_the_xterm_modifier_parameter() {
        assert_eq!(modifiers(false, false, true, false).bits(), 1);
        assert_eq!(modifiers(true, false, false, false).bits(), 2);
        assert_eq!(modifiers(false, true, false, false).bits(), 4);
        assert_eq!(modifiers(false, false, false, true).bits(), 8);
        let vt = terminal();
        assert_eq!(
            encode(&vt, "c", true, false, false, false).unwrap(),
            b"\x03"
        );
        assert_eq!(
            encode(&vt, "b", false, true, false, false).unwrap(),
            b"\x1bb"
        );
        assert_eq!(
            encode(&vt, "ArrowRight", true, false, false, false).unwrap(),
            b"\x1b[1;5C"
        );
        assert_eq!(
            encode(&vt, "ArrowRight", false, true, false, false).unwrap(),
            b"\x1b[1;3C"
        );
    }

    #[test]
    fn key_modes_follow_application_changes() {
        let mut vt = terminal();
        assert_eq!(
            encode(&vt, "ArrowUp", false, false, false, false).unwrap(),
            b"\x1b[A"
        );
        vt.vt_write(b"\x1b[?1h");
        assert_eq!(
            encode(&vt, "ArrowUp", false, false, false, false).unwrap(),
            b"\x1bOA"
        );
        vt.vt_write(b"\x1b[?1l\x1b[?67h");
        assert_eq!(
            encode(&vt, "Backspace", false, false, false, false).unwrap(),
            b"\x08"
        );
        vt.vt_write(b"\x1b[?67l");
        assert_eq!(
            encode(&vt, "Backspace", false, false, false, false).unwrap(),
            b"\x7f"
        );
        assert_eq!(
            encode(&vt, "F1", false, false, false, false).unwrap(),
            b"\x1bOP"
        );
        assert_eq!(
            encode(&vt, "PageDown", false, false, false, false).unwrap(),
            b"\x1b[6~"
        );
        assert_eq!(
            encode(&vt, "Tab", false, false, true, false).unwrap(),
            b"\x1b[Z"
        );
    }

    #[test]
    fn kitty_events_and_modifiers_are_not_flattened_to_text() {
        let mut vt = terminal();
        vt.vt_write(b"\x1b[>11u");
        assert_eq!(
            encode(&vt, "Enter", false, false, true, false).unwrap(),
            b"\x1b[13;2u"
        );
        assert_eq!(
            encode_action(&vt, "Enter", false, false, true, false, KeyAction::Release).unwrap(),
            b"\x1b[13;2:3u"
        );
        assert_eq!(
            encode_action(&vt, "Enter", false, false, true, false, KeyAction::Repeat).unwrap(),
            b"\x1b[13;2:2u"
        );
        assert_eq!(
            encode(&vt, "c", true, false, false, false).unwrap(),
            b"\x1b[99;5u"
        );
        assert_eq!(
            encode(&vt, "c", false, false, false, true).unwrap(),
            b"\x1b[99;9u"
        );
        vt.vt_write(b"\x1b[<u");
        assert!(
            encode_action(&vt, "Enter", false, false, false, false, KeyAction::Release)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn printable_unicode_and_modified_punctuation() {
        let vt = terminal();
        for value in ["한", "é", "🦀", "A", "?", " "] {
            assert_eq!(
                encode(&vt, value, false, false, false, false).unwrap(),
                value.as_bytes()
            );
        }
        assert_eq!(
            encode(&vt, "[", true, false, false, false).unwrap(),
            b"\x1b[91;5u"
        );
        assert_eq!(
            encode(&vt, "Space", true, false, false, false).unwrap(),
            b"\0"
        );
        assert!(encode(&vt, "F99", false, false, false, false).is_err());
    }

    fn pointer(action: MouseAction, button: Option<MouseButton>) -> MouseInput {
        MouseInput {
            action,
            button,
            position: (25., 45.),
            ctrl: false,
            alt: false,
            shift: false,
            meta: false,
            geometry: MouseGeometry {
                screen_width: 800,
                screen_height: 480,
                cell_width: 10,
                cell_height: 20,
                padding_top: 0,
                padding_bottom: 0,
                padding_left: 0,
                padding_right: 0,
            },
        }
    }

    #[test]
    fn mouse_tracking_obeys_normal_drag_and_all_motion_modes() {
        let mut vt = terminal();
        let press = pointer(MouseAction::Press, Some(MouseButton::Left));
        assert!(encode_mouse(&vt, &press).unwrap().is_empty());
        vt.vt_write(b"\x1b[?1000h\x1b[?1006h");
        assert_eq!(encode_mouse(&vt, &press).unwrap(), b"\x1b[<0;3;3M");
        assert_eq!(
            encode_mouse(&vt, &pointer(MouseAction::Release, Some(MouseButton::Left))).unwrap(),
            b"\x1b[<0;3;3m"
        );
        let drag = pointer(MouseAction::Motion, Some(MouseButton::Left));
        assert!(encode_mouse(&vt, &drag).unwrap().is_empty());
        vt.vt_write(b"\x1b[?1002h");
        assert_eq!(encode_mouse(&vt, &drag).unwrap(), b"\x1b[<32;3;3M");
        let hover = pointer(MouseAction::Motion, None);
        assert!(encode_mouse(&vt, &hover).unwrap().is_empty());
        vt.vt_write(b"\x1b[?1003h");
        assert_eq!(encode_mouse(&vt, &hover).unwrap(), b"\x1b[<35;3;3M");
    }

    #[test]
    fn side_buttons_and_horizontal_wheel_use_actual_sgr_button_codes() {
        let mut vt = terminal();
        vt.vt_write(b"\x1b[?1000h\x1b[?1006h");
        for (button, number) in [
            (MouseButton::Eight, 128),
            (MouseButton::Nine, 129),
            (MouseButton::Six, 66),
            (MouseButton::Seven, 67),
        ] {
            assert_eq!(
                encode_mouse(&vt, &pointer(MouseAction::Press, Some(button))).unwrap(),
                format!("\x1b[<{number};3;3M").as_bytes()
            );
        }
        assert_eq!(
            encode_mouse(
                &vt,
                &pointer(MouseAction::Release, Some(MouseButton::Eight))
            )
            .unwrap(),
            b"\x1b[<128;3;3m"
        );
        let mut shifted = pointer(MouseAction::Press, Some(MouseButton::Seven));
        shifted.shift = true;
        assert_eq!(encode_mouse(&vt, &shifted).unwrap(), b"\x1b[<71;3;3M");
    }

    #[test]
    fn mouse_modifiers_geometry_and_pixel_mode() {
        let mut vt = terminal();
        vt.vt_write(b"\x1b[?1003h\x1b[?1006h");
        let mut event = pointer(MouseAction::Press, Some(MouseButton::Left));
        event.ctrl = true;
        assert_eq!(encode_mouse(&vt, &event).unwrap(), b"\x1b[<16;3;3M");
        event.ctrl = false;
        event.alt = true;
        assert_eq!(encode_mouse(&vt, &event).unwrap(), b"\x1b[<8;3;3M");
        event.alt = false;
        event.shift = true;
        assert_eq!(encode_mouse(&vt, &event).unwrap(), b"\x1b[<4;3;3M");
        let mut encoder = MouseEncoder::new().unwrap();
        let mut motion = pointer(MouseAction::Motion, None);
        assert_eq!(encoder.encode(&vt, &motion).unwrap(), b"\x1b[<35;3;3M");
        vt.vt_write(b"\x1b[?1016h");
        assert_eq!(encoder.encode(&vt, &motion).unwrap(), b"\x1b[<35;25;45M");
        motion.position.0 += 1.;
        assert_eq!(encoder.encode(&vt, &motion).unwrap(), b"\x1b[<35;26;45M");
        motion.geometry.cell_width = 0;
        assert!(encoder.encode(&vt, &motion).is_err());
    }
}
