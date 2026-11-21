//! Bounded OSC 5522 transfers, independent of the window system and clipboard provider.
use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use std::collections::BTreeMap;
const LIMIT: usize = 64 * 1024 * 1024;
#[derive(Default)]
pub struct Transfer {
    data: Option<BTreeMap<String, String>>,
    aliases: Vec<(String, String)>,
    primary: bool,
    size: usize,
}
pub type Data = BTreeMap<String, std::sync::Arc<Vec<u8>>>;

pub enum Action {
    Write { primary: bool, data: Data },
    None,
    Reply(String),
    Read { primary: bool, types: Vec<String> },
}
pub fn status(kind: &str, value: &str) -> String {
    format!("\x1b]5522;type={kind}:status={value}\x1b\\")
}
fn decode(s: &str) -> Option<String> {
    String::from_utf8(B64.decode(s).ok()?).ok()
}
impl Transfer {
    fn fail(&mut self, code: &str) -> Action {
        self.data = None;
        self.aliases.clear();
        Action::Reply(status("write", code))
    }
    pub fn feed(&mut self, packet: &str, writable: bool, primary_supported: bool) -> Action {
        let (metadata, payload) = packet.split_once(';').unwrap_or((packet, ""));
        let meta: BTreeMap<_, _> = metadata
            .split(':')
            .filter_map(|s| s.split_once('='))
            .collect();
        let kind = meta.get("type").copied().unwrap_or("");
        let primary = meta.get("loc") == Some(&"primary");
        if kind == "read" {
            let Some(types) = decode(payload) else {
                return Action::None;
            };
            if primary && !primary_supported {
                return Action::Reply(status("read", "ENOSYS"));
            }
            return Action::Read {
                primary,
                types: types
                    .split_whitespace()
                    .take(64)
                    .map(str::to_owned)
                    .collect(),
            };
        }
        if kind == "write" {
            if !writable {
                return self.fail("EPERM");
            }
            if primary && !primary_supported {
                return self.fail("ENOSYS");
            }
            self.data = Some(BTreeMap::new());
            self.primary = primary;
            self.size = 0;
            self.aliases.clear();
            return Action::None;
        }
        if self.data.is_none() {
            return Action::None;
        }
        if !writable {
            return self.fail("EPERM");
        }
        if kind == "walias" {
            let Some(target) = meta.get("mime").and_then(|s| decode(s)) else {
                return self.fail("EINVAL");
            };
            let Some(names) = decode(payload) else {
                return self.fail("EINVAL");
            };
            for name in names.split_whitespace() {
                if self.aliases.len() >= 64 {
                    return self.fail("EFBIG");
                }
                self.aliases.push((name.into(), target.clone()));
            }
            return Action::None;
        }
        if kind != "wdata" {
            return self.fail("EINVAL");
        }
        if let Some(mime) = meta.get("mime") {
            let Some(mime) = decode(mime).filter(|s| s.contains('/') && !s.contains('\0')) else {
                return self.fail("EINVAL");
            };
            self.size += payload.len();
            if self.size > (LIMIT / 3 + 1) * 4 || self.data.as_ref().unwrap().len() >= 64 {
                return self.fail("EFBIG");
            }
            self.data
                .as_mut()
                .unwrap()
                .entry(mime)
                .or_default()
                .push_str(payload);
            return Action::None;
        }
        if !payload.is_empty() {
            return self.fail("EINVAL");
        }
        let mut decoded = BTreeMap::new();
        for (mime, payload) in self.data.take().unwrap() {
            let Ok(bytes) = B64.decode(payload) else {
                return self.fail("EINVAL");
            };
            decoded.insert(mime, std::sync::Arc::new(bytes));
        }
        for (alias, target) in std::mem::take(&mut self.aliases) {
            let Some(bytes) = decoded.get(&target).cloned() else {
                return self.fail("EINVAL");
            };
            decoded.insert(alias, bytes);
        }
        Action::Write {
            primary: self.primary,
            data: decoded,
        }
    }
}
pub fn read_with(types: &[String], mut get: impl FnMut(&str) -> Option<Vec<u8>>) -> String {
    let mut reply = status("read", "OK");
    let mut total = 0;
    let mut seen = std::collections::HashSet::new();
    for mime in types {
        if !seen.insert(mime) {
            continue;
        }
        if let Some(data) = get(mime) {
            total += data.len();
            if total > LIMIT {
                break;
            }
            let encoded_mime = B64.encode(mime.as_bytes());
            if data.is_empty() {
                reply += &format!("\x1b]5522;type=read:status=DATA:mime={encoded_mime};\x1b\\");
            }
            for chunk in data.chunks(4096) {
                reply += &format!(
                    "\x1b]5522;type=read:status=DATA:mime={encoded_mime};{}\x1b\\",
                    B64.encode(chunk)
                );
            }
        }
    }
    reply + &status("read", "DONE")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rich_write_is_atomic_with_chunks_aliases_and_binary_data() {
        let mut transfer = Transfer::default();
        assert!(matches!(
            transfer.feed("type=write", true, false),
            Action::None
        ));
        let mime = B64.encode("application/octet-stream");
        for chunk in ["AAEC", "/w=="] {
            assert!(matches!(
                transfer.feed(&format!("type=wdata:mime={mime};{chunk}"), true, false),
                Action::None
            ));
        }
        assert!(matches!(
            transfer.feed(
                &format!(
                    "type=walias:mime={mime};{}",
                    B64.encode("application/x-custom")
                ),
                true,
                false
            ),
            Action::None
        ));
        let Action::Write { primary, data } = transfer.feed("type=wdata", true, false) else {
            panic!("Missing completed write")
        };
        assert!(!primary);
        assert_eq!(data["application/octet-stream"].as_slice(), &[0, 1, 2, 255]);
        assert!(std::sync::Arc::ptr_eq(
            &data["application/octet-stream"],
            &data["application/x-custom"]
        ));
        assert!(matches!(
            transfer.feed("type=wdata", true, false),
            Action::None
        ));
    }
    #[test]
    fn policy_revocation_and_malformed_transfers_never_commit() {
        let mut transfer = Transfer::default();
        transfer.feed("type=write", true, false);
        assert!(
            matches!(transfer.feed("type=wdata", false, false), Action::Reply(r) if r==status("write", "EPERM"))
        );
        assert!(matches!(
            transfer.feed("type=wdata", true, false),
            Action::None
        ));
        transfer.feed("type=write", true, false);
        transfer.feed("type=wdata:mime=dGV4dC9wbGFpbg==;!invalid!", true, false);
        assert!(
            matches!(transfer.feed("type=wdata", true, false), Action::Reply(r) if r==status("write", "EINVAL"))
        );
        assert!(
            matches!(transfer.feed("type=write:loc=primary", true, false), Action::Reply(r) if r==status("write", "ENOSYS"))
        );
        assert!(
            matches!(transfer.feed("type=read:loc=primary;dGV4dC9wbGFpbg==", true, true), Action::Read { primary: true, types } if types==["text/plain"])
        );
    }
    #[test]
    fn rich_read_preserves_binary_data_chunks_empty_types_and_deduplicates() {
        let bytes: Vec<_> = (0..9000).map(|n| (n % 256) as u8).collect();
        let mut calls = vec![];
        let reply = read_with(
            &[
                "image/png".into(),
                "empty/type".into(),
                "image/png".into(),
                "missing/type".into(),
            ],
            |mime| {
                calls.push(mime.to_owned());
                match mime {
                    "image/png" => Some(bytes.clone()),
                    "empty/type" => Some(vec![]),
                    _ => None,
                }
            },
        );
        assert_eq!(calls, ["image/png", "empty/type", "missing/type"]);
        assert!(
            reply.starts_with(&status("read", "OK")) && reply.ends_with(&status("read", "DONE"))
        );
        let prefix = format!(
            "\x1b]5522;type=read:status=DATA:mime={};",
            B64.encode("image/png")
        );
        let actual: Vec<u8> = reply
            .split(&prefix)
            .skip(1)
            .flat_map(|part| B64.decode(part.split("\x1b\\").next().unwrap()).unwrap())
            .collect();
        assert_eq!(actual, bytes);
        assert!(reply.contains(&format!(
            "type=read:status=DATA:mime={};\x1b\\",
            B64.encode("empty/type")
        )));
    }
}
