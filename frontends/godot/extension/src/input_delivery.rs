//! Preserve IME commit boundaries across deferred frontend input delivery.
use std::{collections::VecDeque, time::{Duration, Instant}};

// A silent application must still receive the key that follows a composition.
// Output normally releases the boundary earlier; this is not a shell-ready ack.
pub const COMMIT_WAIT: Duration = Duration::from_millis(150);
const LIMIT: usize = 4 * 1024 * 1024;

#[derive(Default)]
pub struct InputDelivery {
    batches: VecDeque<(Vec<u8>, bool)>,
    bytes: usize,
    waiting: Option<Instant>,
}
impl InputDelivery {
    pub fn push(&mut self, data: &[u8], commit: bool) {
        let data = &data[..data.len().min(LIMIT.saturating_sub(self.bytes))];
        if data.is_empty() { return; }
        self.bytes += data.len();
        // Godot emits one Unicode event per committed codepoint. Keep all of
        // those codepoints together, but never append a physical key to them.
        if let Some((last, kind)) = self.batches.back_mut() && *kind == commit {
            last.extend_from_slice(data);
        } else {
            self.batches.push_back((data.to_vec(), commit));
        }
    }
    pub fn ready(&self, now: Instant) -> bool {
        self.bytes != 0 && self.waiting.is_none_or(|until| now >= until)
    }
    pub fn waiting(&self) -> bool { self.waiting.is_some() }
    pub fn remaining(&self, now: Instant) -> Option<Duration> {
        self.waiting.and_then(|until| until.checked_duration_since(now))
            .filter(|left| !left.is_zero())
    }
    pub fn take(&mut self, now: Instant) -> Vec<u8> {
        if !self.ready(now) { return Vec::new(); }
        self.waiting = None;
        let mut data = Vec::new();
        while let Some((bytes, commit)) = self.batches.pop_front() {
            self.bytes -= bytes.len();
            data.extend(bytes);
            if commit {
                self.waiting = Some(now + COMMIT_WAIT);
                break;
            }
        }
        data
    }
    pub fn output_received(&mut self) { self.waiting = None; }
    pub fn take_all(&mut self) -> Vec<u8> {
        self.waiting = None;
        self.bytes = 0;
        self.batches.drain(..).flat_map(|(data, _)| data).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn commit_and_shortcut_are_separate_until_output() {
        for key in [b"\x1b[C".as_slice(), b"\x13", b"\x1b", b"\t"] {
            let mut q = InputDelivery::default();
            let now = Instant::now();
            q.push("한".as_bytes(), true);
            q.push("글".as_bytes(), true);
            q.push(key, false);
            q.push(b"later", false);
            assert_eq!(q.take(now), "한글".as_bytes());
            assert!(q.take(now).is_empty());
            q.output_received();
            assert_eq!(q.take(now), [key, b"later"].concat());
        }
    }
    #[test]
    fn silent_app_timeout_and_multiple_commits_preserve_order() {
        let mut q = InputDelivery::default();
        let now = Instant::now();
        q.push(b"a", true); q.push(b"b", false); q.push(b"c", true); q.push(b"d", false);
        assert_eq!(q.take(now), b"a");
        assert!(q.take(now + COMMIT_WAIT / 2).is_empty());
        assert_eq!(q.take(now + COMMIT_WAIT), b"bc");
        assert!(q.take(now + COMMIT_WAIT).is_empty());
        q.output_received();
        assert_eq!(q.take(now + COMMIT_WAIT), b"d");
    }
    #[test]
    fn output_before_dispatch_does_not_release_future_boundary() {
        let mut q = InputDelivery::default();
        let now = Instant::now();
        q.push(b"a", true); q.push(b"b", false);
        q.output_received();
        assert_eq!(q.take(now), b"a");
        assert!(!q.ready(now));
        assert_eq!(q.take_all(), b"b");
        q.push(b"fresh", false);
        assert_eq!(q.take(now), b"fresh");
    }
    #[test]
    fn ordinary_input_has_no_wait() {
        let mut q = InputDelivery::default();
        let now = Instant::now();
        q.push(b"abc", false); q.push(b"\x13", false);
        assert_eq!(q.take(now), b"abc\x13");
        assert!(!q.waiting());
    }
}
