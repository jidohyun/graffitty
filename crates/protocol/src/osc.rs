//! OSC 4723 carries Graffitty-specific commands from a program to the pane
//! that displays it. The number spells GRAF on a phone keypad.
//!
//! The first field after the number selects the command.
//!
//! ```text
//! ESC ] 4723 ; claim=<nonce> BEL
//! ESC ] 4723 ; effects ; hold=<id> ; off=<names> [; on=<names>] [; until=<scope>] BEL
//! ESC ] 4723 ; effects ; release=<id> BEL
//! ESC ] 4723 ; effects ; release BEL
//! ```
//!
//! - A pane claim identifies which pane displays the program.
//!   See `docs/developers/automation-and-extensions/pane-claim.md`.
//! - An effect hold turns off named effects while that pane is focused.
//!   See `docs/developers/automation-and-extensions/effect-holds.md`.
//!
//! Inside tmux, wrap every form in a DCS passthrough so it reaches the
//! outer terminal.
use serde::{Deserialize, Serialize};

/// The OSC number.
pub const OSC: u16 = 4723;
/// Nonces are 32 lowercase hexadecimal characters.
pub const NONCE_LEN: usize = 32;
/// Hold ids are short tokens: letters, digits, `.`, `_`, `-`.
pub const MAX_ID_LEN: usize = 64;
/// The longest OSC body libghostty must keep to report any Graffitty sequence.
/// A full hold with every name spelled out stays under this.
pub const MAX_SEQUENCE_BYTES: usize = 512;

/// Every presentation effect a hold can name, matching the client inventory.
pub const EFFECTS: [&str; 16] = [
    "camera.zoom", "camera.tilt", "camera.drift", "camera.shake", "camera.dof",
    "sheet.curvature", "sheet.ripple", "sheet.splash", "sheet.gloss", "sheet.shadow",
    "lighting", "sparks", "cursor_trail", "pane_zoom", "tab_switch", "session_switch",
];
/// Group names the client expands; `all` is every effect.
pub const GROUPS: [&str; 4] = ["all", "camera", "sheet", "typing"];

pub fn valid_effect(name: &str) -> bool {
    EFFECTS.contains(&name) || GROUPS.contains(&name)
}

pub fn valid_nonce(nonce: &str) -> bool {
    nonce.len() == NONCE_LEN && nonce.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_LEN
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// How long a hold lasts without an explicit release.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    /// Until the foreground process group that printed it ends or changes.
    #[default]
    Process,
    /// Until the pane closes or its terminal is reset.
    Pane,
    /// Only an explicit release removes it.
    Clear,
}

impl Scope {
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "process" => Self::Process,
            "pane" => Self::Pane,
            "clear" => Self::Clear,
            _ => return None,
        })
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::Process => "process",
            Self::Pane => "pane",
            Self::Clear => "clear",
        }
    }
}

/// One effect hold, exactly as a program asked for it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hold {
    pub id: String,
    /// Effects or groups this hold turns off.
    pub off: Vec<String>,
    /// Effects or groups this hold keeps on even if another hold of the same
    /// pane turns them off.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub on: Vec<String>,
    #[serde(default)]
    pub until: Scope,
}

impl Hold {
    /// Reject unknown names, bad ids, and holds that select nothing.
    pub fn validate(&self) -> Result<(), String> {
        if !valid_id(&self.id) {
            return Err(format!("Invalid hold id {:?}: 1-{MAX_ID_LEN} letters, digits, '.', '_' or '-'", self.id));
        }
        for name in self.off.iter().chain(&self.on) {
            if !valid_effect(name) {
                return Err(format!("Unknown effect {name:?}"));
            }
        }
        if self.off.is_empty() && self.on.is_empty() {
            return Err("A hold must name at least one effect in off or on".into());
        }
        Ok(())
    }
}

/// What a program said about effects.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effects {
    Hold(Hold),
    /// `None` releases every hold the pane printed.
    Release(Option<String>),
}

/// Every message the OSC can carry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Message {
    Claim(String),
    Effects(Effects),
}

/// Parse an OSC body (everything between `ESC ]` and the terminator).
/// Anything else, including other OSC numbers and malformed forms, is `None`.
pub fn parse(content: &[u8]) -> Option<Message> {
    let content = std::str::from_utf8(content.strip_prefix(b"4723;")?).ok()?;
    if let Some(nonce) = content.strip_prefix("claim=") {
        return valid_nonce(nonce).then(|| Message::Claim(nonce.to_owned()));
    }
    let body = content.strip_prefix("effects")?;
    if body.is_empty() {
        return None;
    }
    let mut hold = Hold::default();
    let (mut is_hold, mut release) = (false, None);
    for field in body.strip_prefix(';')?.split(';') {
        let (key, value) = field.split_once('=').unwrap_or((field, ""));
        match key {
            "hold" => { is_hold = true; hold.id = value.to_owned(); }
            "off" => hold.off = names(value),
            "on" => hold.on = names(value),
            "until" => hold.until = Scope::parse(value)?,
            "release" => release = Some(value.to_owned()),
            _ => return None,
        }
    }
    match (is_hold, release) {
        (true, None) => hold.validate().ok().map(|()| Message::Effects(Effects::Hold(hold))),
        (false, Some(id)) if id.is_empty() => Some(Message::Effects(Effects::Release(None))),
        (false, Some(id)) => valid_id(&id).then(|| Message::Effects(Effects::Release(Some(id)))),
        _ => None,
    }
}

fn names(value: &str) -> Vec<String> {
    value.split(',').filter(|s| !s.is_empty()).map(str::to_owned).collect()
}

/// The claim as a terminal sequence.
pub fn encode_claim(nonce: &str, tmux: bool) -> Vec<u8> {
    wrap(format!("\x1b]{OSC};claim={nonce}\x07"), tmux)
}

/// An effects message as a terminal sequence.
pub fn encode_effects(message: &Effects, tmux: bool) -> Vec<u8> {
    let body = match message {
        Effects::Hold(hold) => {
            let mut body = format!("hold={}", hold.id);
            if !hold.off.is_empty() { body += &format!(";off={}", hold.off.join(",")); }
            if !hold.on.is_empty() { body += &format!(";on={}", hold.on.join(",")); }
            if hold.until != Scope::Process { body += &format!(";until={}", hold.until.name()); }
            body
        }
        Effects::Release(Some(id)) => format!("release={id}"),
        Effects::Release(None) => "release".into(),
    };
    wrap(format!("\x1b]{OSC};effects;{body}\x07"), tmux)
}

/// Inside tmux the sequence is wrapped in a DCS passthrough (inner ESC doubled)
/// so tmux forwards it to the outer terminal.
fn wrap(sequence: String, tmux: bool) -> Vec<u8> {
    if tmux {
        format!("\x1bPtmux;{}\x1b\\", sequence.replace('\x1b', "\x1b\x1b")).into_bytes()
    } else {
        sequence.into_bytes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NONCE: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn claims_round_trip_and_reject_everything_else() {
        assert_eq!(encode_claim(NONCE, false), format!("\x1b]4723;claim={NONCE}\x07").into_bytes());
        assert_eq!(
            encode_claim(NONCE, true),
            format!("\x1bPtmux;\x1b\x1b]4723;claim={NONCE}\x07\x1b\\").into_bytes()
        );
        assert_eq!(parse(format!("4723;claim={NONCE}").as_bytes()), Some(Message::Claim(NONCE.into())));
        for body in [
            format!("47230;claim={NONCE}"),
            format!("4723;claim={}", NONCE.to_uppercase()),
            format!("4723;claim={NONCE}0"),
            format!("4723;claim={}", &NONCE[1..]),
            format!("4723;nonce={NONCE}"),
            format!("7501;claim={NONCE}"),
            "4723;claim=".into(),
        ] {
            assert_eq!(parse(body.as_bytes()), None, "{body}");
        }
    }

    #[test]
    fn effect_holds_round_trip() {
        let hold = Hold {
            id: "md-preview".into(),
            off: vec!["sparks".into(), "camera".into()],
            on: vec!["cursor_trail".into()],
            until: Scope::Pane,
        };
        let encoded = encode_effects(&Effects::Hold(hold.clone()), false);
        assert_eq!(
            encoded,
            b"\x1b]4723;effects;hold=md-preview;off=sparks,camera;on=cursor_trail;until=pane\x07"
        );
        assert_eq!(parse(&encoded[2..encoded.len() - 1]), Some(Message::Effects(Effects::Hold(hold))));
        assert!(encoded.len() <= MAX_SEQUENCE_BYTES);
        let everything = Hold { id: "x".repeat(MAX_ID_LEN), off: EFFECTS.iter().map(|s| s.to_string()).collect(),
            on: EFFECTS.iter().map(|s| s.to_string()).collect(), until: Scope::Clear };
        // The OSC parser receives the inner sequence after tmux unwraps its
        // DCS transport. Escaping/wrapping is not part of the OSC byte budget.
        let encoded = encode_effects(&Effects::Hold(everything.clone()), false);
        assert!(encoded.len() <= MAX_SEQUENCE_BYTES);
        assert_eq!(parse(&encoded[2..encoded.len() - 1]), Some(Message::Effects(Effects::Hold(everything))));
        assert_eq!(parse(b"4723;effects;hold=a;off=typing"), Some(Message::Effects(Effects::Hold(Hold {
            id: "a".into(), off: vec!["typing".into()], on: vec![], until: Scope::Process }))));
        assert_eq!(parse(b"4723;effects;release=a"), Some(Message::Effects(Effects::Release(Some("a".into())))));
        assert_eq!(parse(b"4723;effects;release"), Some(Message::Effects(Effects::Release(None))));
        assert_eq!(encode_effects(&Effects::Release(None), false), b"\x1b]4723;effects;release\x07");
        assert_eq!(encode_effects(&Effects::Release(Some("a".into())), false), b"\x1b]4723;effects;release=a\x07");
    }

    #[test]
    fn malformed_effect_messages_are_ignored() {
        for body in [
            "4723;effects",
            "4723;effects;",
            "4723;effects;hold=a",
            "4723;effects;hold=;off=sparks",
            "4723;effects;hold=a b;off=sparks",
            "4723;effects;hold=a;off=glitter",
            "4723;effects;hold=a;off=sparks;until=forever",
            "4723;effects;hold=a;off=sparks;release=a",
            "4723;effects;hold=a;off=sparks;color=red",
            "4723;effects;release=a b",
            "4723;effect;hold=a;off=sparks",
        ] {
            assert_eq!(parse(body.as_bytes()), None, "{body}");
        }
    }
}
