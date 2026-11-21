//! Bounded OSC 99 assembly, independent of the window system and native helper.
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Serialize;
use std::collections::BTreeMap;

const TEXT_LIMIT: usize = 64 * 1024;
const ICON_LIMIT: usize = 4 * 1024 * 1024;
#[derive(Clone, Debug, Serialize)]
pub struct Notification {
    pub id: String,
    pub title: String,
    pub body: String,
    pub buttons: Vec<String>,
    pub focus: bool,
    pub report: bool,
    pub close_report: bool,
    pub occasion: String,
    pub urgency: u8,
    pub timeout: i64,
    pub app_name: String,
    pub types: Vec<String>,
    pub icon_names: Vec<String>,
    pub sound: String,
    #[serde(skip)]
    pub icon: Vec<u8>,
}
impl Default for Notification {
    fn default() -> Self {
        Self {
            id: String::new(),
            title: String::new(),
            body: String::new(),
            buttons: vec![],
            focus: true,
            report: false,
            close_report: false,
            occasion: "always".into(),
            urgency: 1,
            timeout: -1,
            app_name: String::new(),
            types: vec![],
            icon_names: vec![],
            sound: "system".into(),
            icon: vec![],
        }
    }
}
#[derive(Debug)]
pub enum Command {
    Query(String),
    Alive(String),
    Close(String),
    Show(Notification),
}
#[derive(Default)]
struct Draft {
    value: Notification,
    raw: BTreeMap<String, Vec<u8>>,
    tails: BTreeMap<String, String>,
    icon_id: String,
}
#[derive(Default)]
pub struct Assembler {
    drafts: BTreeMap<String, Draft>,
    icons: BTreeMap<String, Vec<u8>>,
}
pub fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_+.-".contains(&b))
}
pub fn reply(id: &str, kind: &str, payload: &str) -> Vec<u8> {
    format!(
        "\x1b]99;i={}{};{}\x1b\\",
        if identifier(id) { id } else { "0" },
        if kind.is_empty() {
            String::new()
        } else {
            format!(":p={kind}")
        },
        payload
    )
    .into_bytes()
}
fn clean(value: &str, multiline: bool) -> String {
    value
        .chars()
        .filter(|c| (multiline && matches!(c, '\n' | '\t')) || !c.is_control())
        .collect()
}
fn decode(value: &str) -> Option<Vec<u8>> {
    if !value
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
        || value.len() % 4 == 1
    {
        return None;
    }
    let mut padded = value.to_owned();
    while padded.len() % 4 != 0 {
        padded.push('=');
    }
    STANDARD.decode(padded).ok()
}
impl Assembler {
    pub fn receive(&mut self, packet: &str) -> Option<Command> {
        if packet.len() > 16 * 1024 {
            return None;
        }
        let (metadata, payload) = packet.split_once(';')?;
        let mut meta: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        for part in metadata.split(':') {
            if let Some((key, value)) = part.split_once('=') {
                if key.len() == 1 {
                    meta.entry(key).or_default().push(value);
                }
            }
        }
        let field = |key: &str| meta.get(key).and_then(|v| v.last()).copied();
        let id = field("i").unwrap_or("");
        if !id.is_empty() && !identifier(id) {
            return None;
        }
        let kind = field("p").unwrap_or("title");
        match kind {
            "?" => return Some(Command::Query(id.into())),
            "alive" => return Some(Command::Alive(id.into())),
            "close" => {
                self.drafts.remove(id);
                return Some(Command::Close(id.into()));
            }
            _ => {}
        }
        if !matches!(kind, "title" | "body" | "buttons" | "icon") {
            return None;
        }
        let encoded = field("e") == Some("1");
        if kind == "icon" && !encoded {
            return None;
        }
        if payload.len() > if encoded { 4096 } else { 2048 } {
            return None;
        }
        if encoded
            && !payload
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"+/=".contains(&b))
        {
            self.drafts.remove(id);
            return None;
        }
        if !self.drafts.contains_key(id) && self.drafts.len() >= 32 {
            return None;
        }
        let draft = self.drafts.entry(id.into()).or_default();
        draft.value.id = id.into();
        let tail = draft.tails.entry(kind.into()).or_default();
        let bytes = if encoded {
            tail.push_str(payload);
            let end = tail.len() / 4 * 4;
            let Some(bytes) = decode(&tail[..end]) else {
                self.drafts.remove(id);
                return None;
            };
            *tail = tail[end..].into();
            bytes
        } else {
            if !tail.is_empty() {
                self.drafts.remove(id);
                return None;
            }
            payload.as_bytes().to_vec()
        };
        let raw = draft.raw.entry(kind.into()).or_default();
        raw.extend(bytes);
        if raw.len()
            > if kind == "icon" {
                ICON_LIMIT
            } else {
                TEXT_LIMIT
            }
        {
            self.drafts.remove(id);
            return None;
        }
        if let Some(actions) = field("a") {
            for a in actions.split(',') {
                match a {
                    "focus" => draft.value.focus = true,
                    "-focus" => draft.value.focus = false,
                    "report" => draft.value.report = true,
                    "-report" => draft.value.report = false,
                    _ => {}
                }
            }
        }
        if let Some(v) = field("c") {
            draft.value.close_report = v == "1";
        }
        if let Some(v) = field("o").filter(|v| matches!(*v, "always" | "unfocused" | "invisible")) {
            draft.value.occasion = v.into();
        }
        if let Some(v) = field("u")
            .and_then(|v| v.parse::<u8>().ok())
            .filter(|v| *v <= 2)
        {
            draft.value.urgency = v;
        }
        if let Some(v) = field("w").and_then(|v| v.parse::<i64>().ok()) {
            draft.value.timeout = v.max(-1);
        }
        for (key, output) in [
            ("f", &mut draft.value.app_name),
            ("s", &mut draft.value.sound),
        ] {
            if let Some(v) = field(key).and_then(decode) {
                *output = clean(&String::from_utf8_lossy(&v), false);
            }
        }
        for (key, output) in [
            ("n", &mut draft.value.icon_names),
            ("t", &mut draft.value.types),
        ] {
            for v in meta
                .get(key)
                .into_iter()
                .flatten()
                .filter_map(|v| decode(v))
            {
                let v = clean(&String::from_utf8_lossy(&v), false);
                if !v.is_empty() && output.len() < 32 {
                    output.push(v);
                }
            }
        }
        if let Some(v) = field("g").filter(|v| identifier(v)) {
            draft.icon_id = v.into();
        }
        if field("d") == Some("0") {
            return None;
        }
        let mut draft = self.drafts.remove(id)?;
        for (kind, tail) in draft.tails {
            let bytes = decode(&tail)?;
            let limit = if kind == "icon" {
                ICON_LIMIT
            } else {
                TEXT_LIMIT
            };
            let raw = draft.raw.entry(kind).or_default();
            raw.extend(bytes);
            if raw.len() > limit {
                return None;
            }
        }
        let get = |kind: &str| {
            clean(
                &String::from_utf8_lossy(
                    draft.raw.get(kind).map(Vec::as_slice).unwrap_or_default(),
                ),
                true,
            )
        };
        draft.value.title = get("title");
        draft.value.body = get("body");
        draft.value.buttons = get("buttons")
            .split('\u{2028}')
            .filter(|s| !s.is_empty())
            .take(16)
            .map(str::to_owned)
            .collect();
        draft.value.icon = draft.raw.remove("icon").unwrap_or_default();
        if !draft.icon_id.is_empty() {
            if !draft.value.icon.is_empty() {
                if self.icons.len() >= 16
                    || self.icons.values().map(Vec::len).sum::<usize>() + draft.value.icon.len()
                        > 16 * ICON_LIMIT
                {
                    if let Some(old) = self.icons.keys().next().cloned() {
                        self.icons.remove(&old);
                    }
                }
                self.icons.insert(draft.icon_id, draft.value.icon.clone());
            } else {
                draft.value.icon = self.icons.get(&draft.icon_id).cloned().unwrap_or_default();
            }
        }
        if draft.value.title.is_empty() {
            draft.value.title = std::mem::take(&mut draft.value.body);
        }
        if draft.value.title.is_empty() {
            return None;
        }
        Some(Command::Show(draft.value))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunks_unicode_actions_and_icon_reuse_are_scoped() {
        let mut a = Assembler::default();
        let title = STANDARD.encode("한글 title");
        let split = title.len() - 2;
        assert!(
            a.receive(&format!("i=x:e=1:d=0;{}", &title[..split]))
                .is_none()
        );
        let Some(Command::Show(n)) =
            a.receive(&format!("i=x:e=1:a=report,-focus:c=1;{}", &title[split..]))
        else {
            panic!()
        };
        assert_eq!(n.title, "한글 title");
        assert!(n.report && n.close_report && !n.focus);
        assert!(a.receive("i=a:p=icon:e=1:g=one:d=0;AQID").is_none());
        let Some(Command::Show(n)) = a.receive("i=a;Icon") else {
            panic!()
        };
        assert_eq!(n.icon, [1, 2, 3]);
        let Some(Command::Show(n)) = a.receive("i=b:g=one;Reuse") else {
            panic!()
        };
        assert_eq!(n.icon, [1, 2, 3]);
        let Some(Command::Show(n)) = Assembler::default().receive("i=b:g=one;Other") else {
            panic!()
        };
        assert!(n.icon.is_empty());
        assert_eq!(reply("x", "close", ""), b"\x1b]99;i=x:p=close;\x1b\\");
    }
    #[test]
    fn malformed_packets_and_bounded_drafts_do_not_escape() {
        let mut a = Assembler::default();
        assert!(a.receive("i=bad id;No").is_none());
        assert!(a.receive("i=x:e=1:d=0;Y").is_none());
        assert!(a.receive("i=x:e=1;!").is_none());
        let Some(Command::Show(n)) = a.receive("i=x;Fresh") else {
            panic!()
        };
        assert_eq!(n.title, "Fresh");
        for i in 0..33 {
            a.receive(&format!("i={i}:d=0;partial"));
        }
        assert_eq!(a.drafts.len(), 32);
        assert!(matches!(a.receive("i=0:p=close;"), Some(Command::Close(_))));
        assert_eq!(a.drafts.len(), 31);
    }
}
