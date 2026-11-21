//! Status facts from OSC 7501 (the Program Status Protocol), kept per
//! terminal exactly as reported. A report replaces its record; `clear`
//! removes a record and its children.
//!
//! The turn goes up each time the root record leaves `working`, for any
//! reason.
//!
//! Adapted from herdr-core `crates/herdr-core/src/status.rs`
//! (https://github.com/herdrdev/herdr-core, Apache-2.0; see
//! `licenses/herdr-core-Apache-2.0.txt`). Changed for Graffitty: the facts live
//! in their own [`ProgramStatus`] rather than on herdr's terminal record, and
//! reports come from libghostty-rs's `Terminal::on_program_status`.

use libghostty_vt::terminal::{ProgramStatus as VtReport, ProgramStatusKind, ProgramStatusState};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const MAX_RECORDS: usize = 256;

/// One OSC 7501 report, exactly as the program sent it (strings decoded).
#[derive(Clone, Debug, PartialEq)]
pub struct StatusReport {
    /// idle, working, done, blocked, error, or clear (remove records).
    pub state: &'static str,
    /// permission, question or auth, only when blocked and said.
    pub kind: Option<&'static str>,
    /// 0..=100, only for working and blocked when sent.
    pub progress: Option<u8>,
    /// Empty for the root record.
    pub id: String,
    pub app: String,
    pub title: String,
    pub message: String,
}

impl StatusReport {
    /// Copy a report out of libghostty's callback. A state or kind newer than
    /// these bindings yields `None`: Graffitty only stores what it understands.
    pub fn from_vt(r: VtReport<'_>) -> Option<Self> {
        let state = match r.state().ok()? {
            ProgramStatusState::Idle => "idle",
            ProgramStatusState::Working => "working",
            ProgramStatusState::Done => "done",
            ProgramStatusState::Blocked => "blocked",
            ProgramStatusState::Error => "error",
            ProgramStatusState::Clear => "clear",
            _ => return None,
        };
        let kind = match r.kind().unwrap_or(ProgramStatusKind::None) {
            ProgramStatusKind::Permission => Some("permission"),
            ProgramStatusKind::Question => Some("question"),
            ProgramStatusKind::Auth => Some("auth"),
            _ => None,
        };
        let text = |b: &[u8]| String::from_utf8_lossy(b).into_owned();
        Some(Self {
            state,
            kind,
            progress: r.progress(),
            id: text(r.id()),
            app: text(r.app()),
            title: text(r.title()),
            message: text(r.message()),
        })
    }
}

/// One 7501 record. Words are the program's own; nothing is translated.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Status {
    /// idle, working, done, blocked or error.
    pub state: String,
    /// permission, question or auth (blocked only, when the program said).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// 0..100 (working or blocked, when the program said).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub app: String,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub title: String,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub msg: String,
}

impl Status {
    fn from(r: &StatusReport) -> Status {
        Status {
            state: r.state.into(),
            kind: r.kind.map(Into::into),
            progress: r.progress,
            app: r.app.clone(),
            title: r.title.clone(),
            msg: r.message.clone(),
        }
    }

    /// The report again as OSC 7501, for replaying into a fresh parser.
    pub fn encode(&self, id: &str) -> String {
        let mut fields = vec![format!("state={}", self.state)];
        let mut push = |key: &str, value: &str| {
            if !value.is_empty() {
                fields.push(format!("{key}={value}"));
            }
        };
        push("id", id);
        push("kind", self.kind.as_deref().unwrap_or(""));
        push("progress", &self.progress.map(|p| p.to_string()).unwrap_or_default());
        push("app", &self.app);
        push("title", &base64(self.title.as_bytes()));
        push("msg", &base64(self.msg.as_bytes()));
        format!("\x1b]7501;{}\x1b\\", fields.join(":"))
    }
}

/// Everything one terminal's program said through OSC 7501.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct ProgramStatus {
    /// The root record: what the program says it is doing now. None if it
    /// never said, after it cleared it, or after it exited.
    pub status: Option<Status>,
    /// When that word last changed, ms since the epoch; None if it never said.
    pub status_ms: Option<u64>,
    /// Other 7501 records by id (programs reporting on several things).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub records: BTreeMap<String, Status>,
    /// Goes up each time the status leaves `working`.
    pub turn: u64,
    /// Whether the program ever sent a 7501 report.
    pub reported: bool,
}

/// What a report changed, for events and waiters.
#[derive(Default, Debug, PartialEq)]
pub struct Change {
    pub status: bool,
    /// A fresh root report, not a child record.
    pub root_report: bool,
    pub turn_ended: bool,
    /// It just got stuck: blocked on the user or errored (wasn't that before).
    pub stuck: bool,
}

impl ProgramStatus {
    fn working(&self) -> bool {
        self.status.as_ref().is_some_and(|s| s.state == "working")
    }

    fn end_turn(&mut self, was_working: bool) -> bool {
        let ended = was_working && !self.working();
        if ended {
            self.turn += 1;
        }
        ended
    }

    fn stuck(&self) -> Option<&str> {
        self.status.as_ref().map(|s| s.state.as_str()).filter(|w| *w == "blocked" || *w == "error")
    }

    /// The root record's word (idle, working, done, blocked, error).
    pub fn word(&self) -> Option<&str> {
        self.status.as_ref().map(|s| s.state.as_str())
    }

    fn stamp(&mut self, was: Option<String>) {
        if self.word().map(str::to_owned) != was {
            self.status_ms = Some(now_ms());
        }
    }

    pub fn apply(&mut self, r: &StatusReport) -> Change {
        let (was_working, was_word) = (self.working(), self.word().map(str::to_owned));
        let was = self.stuck().map(String::from);
        self.reported = true;
        if r.state == "clear" {
            if r.id.is_empty() {
                self.status = None;
                self.records.clear();
            } else {
                let child = format!("{}/", r.id);
                self.records.retain(|id, _| *id != r.id && !id.starts_with(&child));
            }
        } else if r.id.is_empty() {
            self.status = Some(Status::from(r));
        } else {
            // Over the limit, the record updated longest ago goes (approximated by first id).
            if !self.records.contains_key(&r.id) && self.records.len() >= MAX_RECORDS - 1 {
                let oldest = self.records.keys().next().cloned().expect("non-empty");
                self.records.remove(&oldest);
            }
            self.records.insert(r.id.clone(), Status::from(r));
        }
        self.stamp(was_word);
        Change {
            status: true,
            root_report: r.id.is_empty(),
            turn_ended: self.end_turn(was_working),
            stuck: self.stuck().is_some() && self.stuck() != was.as_deref(),
        }
    }

    /// The program ended: its status facts reset.
    pub fn reset(&mut self) -> Change {
        let (was_working, was_word) = (self.working(), self.word().map(str::to_owned));
        let had = self.status.is_some() || !self.records.is_empty();
        self.status = None;
        self.records.clear();
        self.stamp(was_word);
        Change { status: had, turn_ended: self.end_turn(was_working), ..Default::default() }
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().enumerate().fold(0u32, |n, (i, b)| n | (*b as u32) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() { TABLE[(n >> (18 - 6 * i) & 63) as usize] as char } else { '=' });
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    fn report(state: &'static str, id: &str) -> StatusReport {
        StatusReport {
            state,
            kind: None,
            progress: None,
            id: id.into(),
            app: String::new(),
            title: String::new(),
            message: String::new(),
        }
    }

    #[test]
    fn the_turn_counts_every_way_of_leaving_working() {
        let mut t = ProgramStatus::default();
        assert!(!t.apply(&report("idle", "")).turn_ended);
        t.apply(&report("working", ""));
        assert!(t.apply(&report("done", "")).turn_ended); // finished
        t.apply(&report("working", ""));
        assert!(t.apply(&report("idle", "")).turn_ended); // interrupted
        t.apply(&report("working", ""));
        assert!(t.apply(&report("blocked", "")).turn_ended); // asks permission
        t.apply(&report("working", ""));
        assert!(t.apply(&report("clear", "")).turn_ended); // cleared
        t.apply(&report("working", ""));
        assert!(!t.apply(&report("working", "sub")).turn_ended, "child records don't count");
        assert!(t.reset().turn_ended); // exited
        assert_eq!(t.turn, 5);
        assert!(t.status.is_none() && t.reported);
    }

    #[test]
    fn the_status_time_moves_only_when_the_word_changes() {
        let mut t = ProgramStatus::default();
        assert_eq!(t.status_ms, None, "never said anything");
        t.apply(&report("working", ""));
        let since = t.status_ms.expect("its first word");
        t.status_ms = Some(1);
        t.apply(&report("working", ""));
        t.apply(&report("done", "sub"));
        assert_eq!(t.status_ms, Some(1), "the same word again, or a child record");
        t.apply(&report("done", ""));
        assert!(t.status_ms >= Some(since));
        t.status_ms = Some(1);
        t.reset();
        assert!(t.status_ms > Some(1), "exiting clears the word");
    }

    #[test]
    fn getting_stuck_is_news_even_outside_a_turn() {
        let mut t = ProgramStatus::default();
        t.apply(&report("idle", ""));
        assert!(t.apply(&report("error", "")).stuck, "e.g. it failed while starting");
        assert!(!t.apply(&report("error", "")).stuck, "once");
        assert!(t.apply(&report("blocked", "")).stuck);
        assert!(!t.apply(&report("idle", "")).stuck);
    }

    #[test]
    fn clear_removes_a_record_and_its_children() {
        let mut t = ProgramStatus::default();
        for id in ["build", "build/test", "buildx", "deploy"] {
            t.apply(&report("working", id));
        }
        t.apply(&report("clear", "build"));
        assert_eq!(t.records.keys().collect::<Vec<_>>(), ["buildx", "deploy"]);
    }

    #[test]
    fn reports_encode_back_to_what_the_parser_reads() {
        let mut screen = crate::new_vt(80, 24, 1 << 20).unwrap();
        let seen = Rc::new(RefCell::new(Vec::new()));
        let sink = seen.clone();
        screen
            .on_program_status(move |_, r| sink.borrow_mut().extend(StatusReport::from_vt(r)))
            .unwrap();
        let sent = StatusReport {
            state: "blocked",
            kind: Some("permission"),
            progress: Some(40),
            id: "a/b".into(),
            app: "claude-code".into(),
            title: "Run tests".into(),
            message: "Apply these changes?".into(),
        };
        screen.vt_write(Status::from(&sent).encode("a/b").as_bytes());
        assert_eq!(*seen.borrow(), vec![sent]);
        assert_eq!(base64(b"Apply?"), "QXBwbHk/");
        assert_eq!(base64(b"ab"), "YWI=");
    }
}
