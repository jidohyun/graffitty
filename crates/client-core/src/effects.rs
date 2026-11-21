//! Bounded frontend protocol effects; native clipboard access stays in adapters.
use crate::images::ImageMirror;
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use graffitty_terminal_core::{protocol, vt::Terminal};
use serde::{Deserialize, Serialize};
use std::{
    cell::RefCell,
    collections::VecDeque,
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
const MAX_TEXT: usize = 1024 * 1024;
static EPOCH: AtomicU64 = AtomicU64::new(1);
#[derive(Debug)]
pub enum Event {
    Read(u8, bool),
    Write(String),
    Rich(String),
}
pub struct Events {
    pub epoch: u64,
    queue: Rc<RefCell<VecDeque<Event>>>,
}
impl Events {
    pub fn attach(vt: &mut Terminal<'static, 'static>) -> Result<Self> {
        let queue = Rc::new(RefCell::new(VecDeque::new()));
        let writes = queue.clone();
        vt.on_clipboard_write(move |_, request| {
            let result = (|| {
            use graffitty_terminal_core::vt::terminal::ClipboardWriteError;
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
            if text.len() > MAX_TEXT {
                return Err(ClipboardWriteError::InvalidData);
            }
            let mut queue = writes.borrow_mut();
            let queued_bytes: usize = queue
                .iter()
                .map(|event| match event {
                    Event::Write(text) | Event::Rich(text) => text.len(),
                    _ => 0,
                })
                .sum();
            if queue.len() >= 64 || queued_bytes + text.len() > MAX_TEXT {
                return Err(ClipboardWriteError::Denied);
            }
            queue.push_back(Event::Write(text.into()));
            Ok(())
            })();
            // Ghostty 521cf2c answers writes through the request (OSC 5522 acks).
            request.reply(result, false);
        })?;
        Ok(Self {
            epoch: EPOCH.fetch_add(1, Ordering::Relaxed),
            queue,
        })
    }
    pub fn feed(
        &mut self,
        images: &mut ImageMirror,
        vt: &mut Terminal<'static, 'static>,
        bytes: &[u8],
    ) {
        // ImageMirror already observes the same ordered stream for inline
        // images. Sharing it avoids buffering/decoding each protocol packet twice.
        images.feed_with_events(vt, bytes, |event| {
            let next = match event {
                protocol::Event::ClipboardRead(selector, bel) => Some(Event::Read(*selector, *bel)),
                protocol::Event::Clipboard5522(packet) => Some(Event::Rich(packet.clone())),
                _ => None,
            };
            if let Some(next) = next {
                let mut queue = self.queue.borrow_mut();
                let bytes: usize = queue
                    .iter()
                    .chain(std::iter::once(&next))
                    .map(|e| match e {
                        Event::Write(s) | Event::Rich(s) => s.len(),
                        _ => 0,
                    })
                    .sum();
                if queue.len() < 8192 && bytes <= 8 * MAX_TEXT {
                    queue.push_back(next);
                }
            }
        });
    }

    pub fn drain(&mut self) -> Vec<Event> {
        self.queue.borrow_mut().drain(..).collect()
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct Preferences {
    pub clipboard_read: String,
    pub clipboard_write: bool,
    pub open_hyperlinks: bool,
    pub hyperlink_patterns: Vec<String>,
    /// Program and literal arguments; {url} is substituted without a shell.
    pub hyperlink_handler: Vec<String>,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            clipboard_read: "ask".into(),
            clipboard_write: true,
            open_hyperlinks: true,
            hyperlink_patterns: vec![r#"(?:https?://|ftp://|file://)[^\s<>\"]+"#.into()],
            hyperlink_handler: vec![],
        }
    }
}
impl Preferences {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            matches!(self.clipboard_read.as_str(), "deny" | "ask" | "allow"),
            "Clipboard read policy must be deny, ask, or allow"
        );
        ensure!(
            self.hyperlink_patterns.len() <= 32
                && self.hyperlink_patterns.iter().all(|p| p.len() <= 8192),
            "Too many or oversized hyperlink patterns"
        );
        compile_links(&self.hyperlink_patterns)?;
        ensure!(
            self.hyperlink_handler.len() <= 32
                && self
                    .hyperlink_handler
                    .iter()
                    .all(|arg| arg.len() <= 8192 && !arg.chars().any(char::is_control)),
            "Invalid hyperlink command arguments"
        );
        if let Some(program) = self.hyperlink_handler.first() {
            ensure!(
                !program.is_empty()
                    && !program.contains("{url}")
                    && self
                        .hyperlink_handler
                        .iter()
                        .skip(1)
                        .any(|a| a.contains("{url}")),
                "Hyperlink command needs a program and a {{url}} argument"
            );
        }
        Ok(())
    }
}
pub fn reply(selector: u8, bel: bool, text: &str) -> Result<Vec<u8>> {
    ensure!(text.len() <= MAX_TEXT, "Clipboard content exceeds 1 MiB");
    Ok(format!(
        "\x1b]52;{};{}{}",
        selector as char,
        STANDARD.encode(text.as_bytes()),
        if bel { "\x07" } else { "\x1b\\" }
    )
    .into_bytes())
}

#[cfg(test)]
static LINKS: std::sync::LazyLock<Vec<Arc<fancy_regex::Regex>>> = std::sync::LazyLock::new(|| {
    vec![Arc::new(
        fancy_regex::Regex::new(r#"(?:https?://|ftp://|file://)[^\s<>\"]+"#).unwrap(),
    )]
});
pub fn compile_links(patterns: &[String]) -> Result<Vec<Arc<fancy_regex::Regex>>> {
    patterns
        .iter()
        .map(|pattern| {
            Ok(Arc::new(
                fancy_regex::Regex::new(pattern).context("Invalid hyperlink pattern")?,
            ))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunked_osc52_keeps_write_before_read_and_opaque_strings_cannot_inject() {
        let mut vt = graffitty_terminal_core::new_vt(30, 3, 10).unwrap();
        let mut images = ImageMirror::new(&mut vt).unwrap();
        let mut events = Events::attach(&mut vt).unwrap();
        let wire = b"\x1b]52;c;SGVsbG8=\x07\x1b]52;c;?\x1b\\";
        for byte in wire {
            events.feed(&mut images, &mut vt, &[*byte]);
        }
        let received = events.drain();
        assert!(
            matches!(&received[..], [Event::Write(text), Event::Read(b'c',false)] if text=="Hello")
        );
        events.feed(&mut images, &mut vt, b"\x1b_hidden\x1b]52;c;?\x07\x1b\\");
        assert!(events.drain().is_empty());
        assert_eq!(reply(b'c', false, "한").unwrap(), b"\x1b]52;c;7ZWc\x1b\\");
        assert!(reply(b'c', false, &"x".repeat(MAX_TEXT + 1)).is_err());
    }
    #[test]
    fn explicit_osc8_and_plain_urls_use_shared_terminal_lookup() {
        let mut vt = graffitty_terminal_core::new_vt(80, 3, 10).unwrap();
        vt.vt_write(b"\x1b]8;;https://example.test/hidden\x1b\\link\x1b]8;;\x1b\\\r\nhttps://example.test/plain");
        assert_eq!(
            protocol::custom_hyperlink(&vt, 1, 0, &LINKS).as_deref(),
            Some("https://example.test/hidden")
        );
        assert_eq!(
            protocol::custom_hyperlink(&vt, 10, 1, &LINKS).as_deref(),
            Some("https://example.test/plain")
        );
        assert!(!protocol::openable_link("javascript:alert(1)"));
        assert!(!protocol::openable_link("https://example.test/\nother"));
    }
}
