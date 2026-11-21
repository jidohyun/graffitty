//! WezTerm-compatible default Quick Select matching and label assignment.
//! Pattern order and label algorithm adapted from WezTerm (MIT, Copyright
//! 2018-present Wez Furlong); label algorithm originally tmux-thumbs (MIT,
//! Copyright 2019 Ferran Basora). See third-party/quick-select-LICENSE.
use libghostty_vt::screen::{CellWide, Screen, TrackedGridRef};
use libghostty_vt::terminal::{Point, PointCoordinate, PointSpace};
use libghostty_vt::{Error, Terminal};
use std::collections::HashMap;
use std::sync::LazyLock;

pub const ALPHABET: &str = "asdfqwerzxcvjklmiuopghtybn";
pub const PATTERNS: [&str; 16] = [
    r"\[[^]]*\]\(([^)]+)\)",
    r"(?:https?://|git@|git://|ssh://|ftp://|file://)\S+",
    r"--- a/(\S+)",
    r"\+\+\+ b/(\S+)",
    r"sha256:([0-9a-f]{64})",
    // Windows paths, whatever host runs the terminal: drive (`C:\`, `C:/`) or
    // UNC (`\\server\share`) roots, and relative paths with a backslash.
    // MSYS `/c/...` paths are ordinary Unix paths below.
    r"(?:\b[A-Za-z]:[\\/]|\\\\[.\w\-@$]+\\)(?:[.\w\-@$~]+(?:[\\/]+[.\w\-@$~]+)*[\\/]?)?",
    r"[.\w\-@$~]+(?:/+[.\w\-@$~]+)*(?:\\+[.\w\-@$~]+)+(?:[\\/]+[.\w\-@$~]+)*",
    r"(?:[.\w\-@~]+)?(?:/+[.\w\-@]+)+",
    r"#[0-9a-fA-F]{6}",
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
    r"Qm[0-9a-zA-Z]{44}",
    r"[0-9a-f]{7,40}",
    r"\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}",
    r"[A-f0-9:]+:+[A-f0-9:]+[%\w\d]+",
    r"0x[0-9a-fA-F]+",
    r"[0-9]{4,}",
];
static PATTERN: LazyLock<fancy_regex::Regex> =
    LazyLock::new(|| fancy_regex::Regex::new(&format!("(?m)({})", PATTERNS.join("|"))).unwrap());

pub fn labels(alphabet: &str, count: usize) -> Vec<String> {
    let alphabet: Vec<String> = alphabet
        .chars()
        .map(|c| c.to_lowercase().to_string())
        .collect();
    let mut primary = alphabet.clone();
    let mut secondary = Vec::new();
    while primary.len() + secondary.len() < count {
        let Some(prefix) = primary.pop() else { break };
        let extra: Vec<_> = alphabet
            .iter()
            .take(count - primary.len() - secondary.len())
            .map(|s| format!("{prefix}{s}"))
            .collect();
        secondary.splice(0..0, extra);
    }
    primary.truncate(count - secondary.len());
    primary.extend(secondary);
    primary
}

pub struct Match {
    pub text: String,
    pub label: String,
    pub start: TrackedGridRef,
    pub end: TrackedGridRef,
}
impl Match {
    /// Resolve fresh snapshots only while the terminal is borrowed. Pins may
    /// have moved with output/reflow or disappeared when scrollback was evicted.
    pub fn select_text(&self, vt: &Terminal<'_, '_>) -> Option<String> {
        let start = self.start.snapshot(vt).ok()??;
        let end = self.end.snapshot(vt).ok()??;
        let selection = libghostty_vt::selection::Selection::new(start, end, false);
        let mut formatter = libghostty_vt::fmt::Formatter::new(vt).ok()?;
        formatter.set_unwrap(true).ok()?.set_trim(true).ok()?;
        // SAFETY: both tracked endpoints were resolved against this borrowed terminal above.
        unsafe { formatter.set_selection(Some(&selection)) }.ok()?;
        let text = formatter.format_alloc(None).ok()?;
        let text = std::str::from_utf8(&text).ok()?.to_owned();
        vt.set_selection(Some(&selection)).ok()?;
        Some(text)
    }

    pub fn bounds(&self) -> Option<(PointCoordinate, PointCoordinate)> {
        Some((
            self.start.point(PointSpace::Screen).ok()??,
            self.end.point(PointSpace::Screen).ok()??,
        ))
    }
}

pub struct QuickSelect {
    pub matches: Vec<Match>,
    pub input: String,
    pub current: Option<usize>,
    pub screen: Screen,
}

impl QuickSelect {
    pub fn new(vt: &Terminal<'_, '_>) -> libghostty_vt::error::Result<Self> {
        Self::find(vt, &PATTERN, false, ALPHABET)
    }
    pub fn search(vt: &Terminal<'_, '_>, query: &str) -> libghostty_vt::error::Result<Self> {
        let escaped: String = query
            .chars()
            .flat_map(|c| {
                if "\\.^$|?*+()[]{}".contains(c) {
                    vec!['\\', c]
                } else {
                    vec![c]
                }
            })
            .collect();
        let pattern =
            fancy_regex::Regex::new(if query.is_empty() { "(?!)" } else { &escaped }).unwrap();
        Self::find(vt, &pattern, true, ALPHABET)
    }
    pub fn find(
        vt: &Terminal<'_, '_>,
        pattern: &fancy_regex::Regex,
        all: bool,
        alphabet: &str,
    ) -> libghostty_vt::error::Result<Self> {
        let scroll = vt.scrollbar()?;
        let cols = vt.cols()?;
        let scope = if all {
            vt.total_rows()?
        } else {
            1000usize.max(vt.rows()? as usize)
        };
        let mut first = (scroll.offset as usize).saturating_sub(scope);
        let total = vt.total_rows()?;
        let mut last = (scroll.offset as usize + vt.rows()? as usize + scope).min(total);
        // Include the beginning of a logical line crossing the search boundary.
        while first > 0
            && vt
                .grid_ref(point(0, first))?
                .row()?
                .is_wrap_continuation()?
        {
            first -= 1;
        }
        while last < total && vt.grid_ref(point(0, last))?.row()?.is_wrap_continuation()? {
            last += 1;
        }
        let mut found = Vec::new();
        let mut text = String::new();
        let mut coords = Vec::new();
        let mut graphemes = vec!['\0'; 8];
        for y in first..last {
            let wrapped = vt.grid_ref(point(0, y))?.row()?.is_wrapped()?;
            for x in 0..cols {
                let cell = vt.grid_ref(point(x, y))?;
                let wide = cell.cell()?.wide()?;
                if matches!(wide, CellWide::SpacerTail | CellWide::SpacerHead) {
                    continue;
                }
                let n = match cell.graphemes(&mut graphemes) {
                    Err(Error::OutOfSpace { required }) => {
                        graphemes.resize(required, '\0');
                        cell.graphemes(&mut graphemes)?
                    }
                    other => other?,
                };
                let start = PointCoordinate { x, y: y as u32 };
                let end = PointCoordinate {
                    x: (x + if wide == CellWide::Wide { 1 } else { 0 }).min(cols - 1),
                    y: y as u32,
                };
                let byte = text.len();
                if n == 0 {
                    text.push(' ');
                } else {
                    text.extend(&graphemes[..n]);
                }
                coords.push((byte, text.len(), start, end));
            }
            if !wrapped || y + 1 == last {
                for captures in pattern.captures_iter(&text).flatten() {
                    // WezTerm selects the last participating capture, e.g. only
                    // the destination of a Markdown link, or the hash after sha256:.
                    if let Some(m) = (0..captures.len()).rev().find_map(|i| captures.get(i)) {
                        let start = coords.iter().find(|c| c.1 > m.start()).map(|c| c.2);
                        let end = coords.iter().rev().find(|c| c.0 < m.end()).map(|c| c.3);
                        if let (Some(start), Some(end)) = (start, end) {
                            found.push(Match {
                                text: m.as_str().to_owned(),
                                label: String::new(),
                                start: vt.track_grid_ref(Point::Screen(start))?,
                                end: vt.track_grid_ref(Point::Screen(end))?,
                            });
                        }
                    }
                }
                text.clear();
                coords.clear();
            }
        }
        let mut ids = HashMap::new();
        for m in found.iter().rev() {
            let next = ids.len();
            ids.entry(m.text.clone()).or_insert(next);
        }
        let labels = labels(alphabet, ids.len());
        for m in &mut found {
            m.label = labels.get(ids[&m.text]).cloned().unwrap_or_default();
        }
        let current = if scroll.offset < scroll.total.saturating_sub(scroll.len) {
            found
                .iter()
                .position(|m| m.bounds().is_some_and(|(s, _)| s.y as u64 >= scroll.offset))
        } else {
            found.len().checked_sub(1)
        };
        Ok(Self {
            matches: found,
            input: String::new(),
            current,
            screen: vt.active_screen()?,
        })
    }

    pub fn selected(&self) -> Option<(usize, bool)> {
        let lower = self.input.to_lowercase();
        if lower.is_empty() {
            return None;
        }
        self.matches
            .iter()
            .enumerate()
            .rev()
            .find(|(_, m)| m.label == lower)
            .map(|(i, _)| (i, lower != self.input))
    }

    /// Visible row segments, with inclusive endpoints converted to ranges.
    pub fn segments(&self, top: u64, rows: u16, cols: u16) -> Vec<(u16, u16, u16, String)> {
        let prefix = self.input.to_lowercase();
        let mut out = Vec::new();
        for m in self.matches.iter().rev() {
            if m.label.is_empty() || !m.label.starts_with(&prefix) {
                continue;
            }
            let Some((start, end)) = m.bounds() else {
                continue;
            };
            for y in (start.y as u64).max(top)..=(end.y as u64).min(top + rows as u64 - 1) {
                let x = if y == start.y as u64 { start.x } else { 0 };
                let right = if y == end.y as u64 { end.x + 1 } else { cols };
                out.push(((y - top) as u16, x, right, m.label.clone()));
            }
        }
        out
    }
}
fn point(x: u16, y: usize) -> Point {
    Point::Screen(PointCoordinate { x, y: y as u32 })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn terminal(cols: u16, rows: u16, text: &str) -> Terminal<'static, 'static> {
        let mut vt = crate::new_vt(cols, rows, 2000).unwrap();
        vt.vt_write(text.as_bytes());
        vt
    }
    #[test]
    fn wezterm_labels() {
        assert_eq!(labels("abcd", 6), ["a", "b", "c", "da", "db", "dc"]);
        assert_eq!(
            labels("abcd", 8),
            ["a", "b", "ca", "cb", "da", "db", "dc", "dd"]
        );
        assert_eq!(labels(ALPHABET, 792).len(), 676);
        assert!(labels(ALPHABET, 0).is_empty());
    }
    #[test]
    fn captures_duplicates_and_case() {
        let vt = terminal(
            100,
            8,
            "https://one.test\r\n[title](https://two.test)\r\n--- a/src/main.rs\r\nhttps://one.test",
        );
        let mut q = QuickSelect::new(&vt).unwrap();
        assert_eq!(
            q.matches
                .iter()
                .map(|m| m.text.as_str())
                .collect::<Vec<_>>(),
            [
                "https://one.test",
                "https://two.test",
                "src/main.rs",
                "https://one.test"
            ]
        );
        assert_eq!(q.matches[0].label, "a");
        assert_eq!(q.matches[3].label, "a");
        q.input = "a".into();
        assert_eq!(q.selected(), Some((3, false)));
        q.input = "A".into();
        assert_eq!(q.selected(), Some((3, true)));
        q.matches[3].label = "af".into();
        for input in ["Af", "aF", "AF"] {
            q.input = input.into();
            assert_eq!(q.selected(), Some((3, true)));
        }
    }
    #[test]
    fn full_graphemes_across_wide_wrap_boundaries() {
        let url = "https://example.test/한글/e\u{301}/🙂";
        for cols in 8..32 {
            let vt = terminal(cols, 8, url);
            let q = QuickSelect::new(&vt).unwrap();
            assert_eq!(q.matches.len(), 1, "width {cols}");
            assert_eq!(q.matches[0].text, url, "width {cols}");
            assert_eq!(
                q.matches[0].select_text(&vt).as_deref(),
                Some(url),
                "width {cols}"
            );
        }
    }

    #[test]
    fn windows_paths() {
        let text = r"C:\Users\me\a.txt D:/repo/src C:\ \\srv\share\dir\f.log src\main.rs ..\up\x.ps1 /c/Users/me/a.txt mixed/dir\f.rs";
        let vt = terminal(200, 4, text);
        let q = QuickSelect::new(&vt).unwrap();
        assert_eq!(
            q.matches.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(),
            [
                r"C:\Users\me\a.txt",
                "D:/repo/src",
                r"C:\",
                r"\\srv\share\dir\f.log",
                r"src\main.rs",
                r"..\up\x.ps1",
                "/c/Users/me/a.txt",
                r"mixed/dir\f.rs",
            ]
        );
    }

    #[test]
    fn default_pattern_categories_and_no_matches() {
        let sha = "a".repeat(64);
        let ipfs = format!("Qm{}", "z".repeat(44));
        let text = format!(
            "sha256:{sha} #aBc123 12345678-1234-1234-1234-123456789abc {ipfs} abcdef0 192.168.1.1 fe80::1%lo0 0xCAFE 1234"
        );
        let vt = terminal(120, 4, &text);
        let q = QuickSelect::new(&vt).unwrap();
        assert_eq!(
            q.matches
                .iter()
                .map(|m| m.text.as_str())
                .collect::<Vec<_>>(),
            [
                sha.as_str(),
                "#aBc123",
                "12345678-1234-1234-1234-123456789abc",
                ipfs.as_str(),
                "abcdef0",
                "192.168.1.1",
                "fe80::1%lo0",
                "0xCAFE",
                "1234"
            ]
        );
        let vt = terminal(20, 2, "hello world");
        let q = QuickSelect::new(&vt).unwrap();
        assert!(q.matches.is_empty());
        assert!(q.current.is_none());
        assert!(q.selected().is_none());
    }

    #[test]
    fn wrapped_unicode_and_scrollback() {
        let mut vt = terminal(20, 3, "한글 e\u{301} https://example.org/long/path\r\n");
        let q = QuickSelect::new(&vt).unwrap();
        let m = &q.matches[0];
        assert_eq!(m.text, "https://example.org/long/path");
        let (s, e) = m.bounds().unwrap();
        assert_eq!(s.x, 7);
        assert!(e.y > s.y);
        assert_eq!(m.select_text(&vt).as_deref(), Some(m.text.as_str()));
        for _ in 0..20 {
            vt.vt_write(b"line\r\n");
        }
        assert_eq!(m.select_text(&vt).as_deref(), Some(m.text.as_str()));
        let q = QuickSelect::new(&vt).unwrap();
        assert_eq!(q.matches[0].text, "https://example.org/long/path");
        assert!(q.segments(vt.scrollbar().unwrap().offset, 3, 20).is_empty());
    }
}
