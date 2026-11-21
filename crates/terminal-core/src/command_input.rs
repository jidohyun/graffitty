//! Virtual keystrokes use the owner's current VT modes, without a GUI event queue.
use crate::{Error, key_encoding};
use libghostty_vt::{
    Terminal,
    key::{self, Key, Mods},
};

#[derive(Clone, Debug)]
pub struct Stroke {
    key: Key,
    unshifted: char,
    text: Option<char>,
    mods: Mods,
}

impl Stroke {
    pub fn typing_unicode(&self) -> Option<u32> {
        if matches!(self.key, Key::ArrowLeft | Key::ArrowRight | Key::ArrowUp | Key::ArrowDown) {
            return None;
        }
        Some(match self.key {
            Key::Backspace => 8,
            Key::Delete => 127,
            _ => self.text.map_or(0, u32::from),
        })
    }
    pub fn character(ch: char) -> Self {
        let (key, unshifted) = physical(ch);
        Self {
            key,
            unshifted,
            text: Some(ch),
            mods: Mods::empty(),
        }
    }

    pub fn parse(value: &str) -> Result<Self, &'static str> {
        // A trailing '+' is a literal key, including Ctrl++.
        let (prefix, name) = if let Some(prefix) = value.strip_suffix("++") {
            (prefix, "+")
        } else if value == "+" {
            ("", "+")
        } else {
            value.rsplit_once('+').unwrap_or(("", value))
        };
        let mut mods = Mods::empty();
        if !prefix.is_empty() {
            for modifier in prefix.split('+') {
                mods |= match modifier {
                    "Ctrl" => Mods::CTRL,
                    "Alt" => Mods::ALT,
                    "Shift" => Mods::SHIFT,
                    "Meta" => Mods::SUPER,
                    _ => return Err("Unsupported key or modifier"),
                };
            }
        }
        let key = match name {
            "Enter" => Key::Enter,
            "Tab" => Key::Tab,
            "Escape" => Key::Escape,
            "Backspace" => Key::Backspace,
            "Delete" => Key::Delete,
            "ArrowLeft" => Key::ArrowLeft,
            "ArrowRight" => Key::ArrowRight,
            "ArrowUp" => Key::ArrowUp,
            "ArrowDown" => Key::ArrowDown,
            "Home" => Key::Home,
            "End" => Key::End,
            "PageUp" => Key::PageUp,
            "PageDown" => Key::PageDown,
            "Space" => Key::Space,
            _ => {
                let mut chars = name.chars();
                let ch = chars
                    .next()
                    .filter(|c| c.is_ascii() && !c.is_ascii_control())
                    .ok_or("Unsupported key or modifier")?;
                if chars.next().is_some() {
                    return Err("Unsupported key or modifier");
                }
                let mut stroke = Self::character(if mods.contains(Mods::SHIFT) {
                    ch.to_ascii_uppercase()
                } else {
                    ch
                });
                stroke.mods = mods;
                return Ok(stroke);
            }
        };
        Ok(Self {
            key,
            unshifted: if key == Key::Space { ' ' } else { '\0' },
            text: (key == Key::Space).then_some(' '),
            mods,
        })
    }

    /// Press and release are one queued write; extended keyboard applications
    /// still receive both, while legacy releases encode to no bytes.
    pub fn encode(&self, vt: &Terminal<'_, '_>) -> Result<Vec<u8>, Error> {
        let mut encoder = key::Encoder::new()?;
        let mut event = key::Event::new()?;
        let text = self
            .text
            .filter(|_| !self.mods.intersects(Mods::CTRL | Mods::SUPER));
        let mut bytes = Vec::new();
        for action in [key::Action::Press, key::Action::Release] {
            let text = text.filter(|_| action == key::Action::Press);
            event
                .set_action(action)
                .set_key(self.key)
                .set_mods(self.mods)
                .set_unshifted_codepoint(self.unshifted)
                .set_consumed_mods(if text.is_some() {
                    self.mods & Mods::SHIFT
                } else {
                    Mods::empty()
                })
                .set_utf8(text.map(|c| c.to_string()));
            key_encoding::encode(vt, &mut encoder, &event, &mut bytes)?;
        }
        Ok(bytes)
    }
}

fn physical(ch: char) -> (Key, char) {
    let ch = ch.to_ascii_lowercase();
    let letters = [
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
    if ch.is_ascii_lowercase() {
        return (letters[ch as usize - 'a' as usize], ch);
    }
    let digits = [
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
    if ch.is_ascii_digit() {
        return (digits[ch as usize - '0' as usize], ch);
    }
    let key = match ch {
        ' ' => Key::Space,
        '-' => Key::Minus,
        '=' => Key::Equal,
        '[' => Key::BracketLeft,
        ']' => Key::BracketRight,
        '\\' => Key::Backslash,
        ';' => Key::Semicolon,
        '\'' => Key::Quote,
        ',' => Key::Comma,
        '.' => Key::Period,
        '/' => Key::Slash,
        '`' => Key::Backquote,
        _ => return (Key::Unidentified, '\0'),
    };
    (key, ch)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owner_modes_control_keys_including_alt_and_extended_releases() {
        let mut vt = crate::new_vt(80, 24, 0).unwrap();
        for (name, expected) in [
            ("Alt+b", b"\x1bb".as_slice()),
            ("Ctrl+u", b"\x15"),
            ("Shift+Enter", b"\r"),
            ("ArrowUp", b"\x1b[A"),
            ("+", b"+"),
        ] {
            assert_eq!(
                Stroke::parse(name).unwrap().encode(&vt).unwrap(),
                expected,
                "{name}"
            );
        }
        assert_eq!(
            Stroke::character('한').encode(&vt).unwrap(),
            "한".as_bytes()
        );
        vt.vt_write(b"\x1b[?1h");
        assert_eq!(
            Stroke::parse("ArrowUp").unwrap().encode(&vt).unwrap(),
            b"\x1bOA"
        );
        vt.vt_write(b"\x1b[>11u");
        assert_eq!(
            Stroke::parse("Alt+b").unwrap().encode(&vt).unwrap(),
            b"\x1b[98;3u\x1b[98;3:3u"
        );
        for name in ["", "Hyper+a", "Ctrl+Unknown", "Ctrl++a"] {
            assert!(Stroke::parse(name).is_err());
        }
    }
}
