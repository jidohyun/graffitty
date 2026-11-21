//! Literal, visible-screen search with continuation-safe jump labels.
use super::{CopyMode, Effect, Pos, Search, Span, Terminal, literal_regex};
use libghostty_vt::terminal::ScrollViewport;
use std::collections::HashSet;

const LABELS: &str = "asdfghjklqwertyuiopzxcvbnmASDFGHJKLQWERTYUIOPZXCVBNM";

impl CopyMode {
    /// While searching with s, the renderer dims cells outside the matches.
    pub fn flash_active(&self) -> bool {
        self.prompt.as_ref().is_some_and(|p| p.flash)
    }
    /// Jump labels as `(viewport row, column, character)` for the frontend.
    pub fn labels(&self, top: u64, rows: u16) -> Vec<(u16, u16, char)> {
        self.flash_labels
            .iter()
            .filter_map(|(_, at, label)| {
                (u64::from(at.y) >= top && u64::from(at.y) < top + u64::from(rows))
                    .then(|| ((u64::from(at.y) - top) as u16, at.x, *label))
            })
            .collect()
    }

    pub(super) fn accept_flash(&mut self, vt: &mut Terminal<'_, '_>, target: Pos) -> Effect {
        let prompt = self.prompt.take().unwrap();
        self.search = prompt.previous;
        self.flash_labels.clear();
        if prompt.yank {
            return self.yank_range(vt, prompt.origin, target, Span::Exclusive);
        }
        self.cursor = self.text.clamp(vt, target);
        self.want_x = self.cursor.x;
        if prompt.remote {
            self.yank = true;
            self.keys = "y".into();
        }
        self.sync(vt);
        Effect::None
    }

    pub(super) fn update_flash(&mut self, vt: &mut Terminal<'_, '_>) {
        let prompt = self.prompt.as_ref().unwrap();
        let pattern = prompt.text.clone();
        let origin = prompt.origin;
        let top = prompt.view.unwrap_or(0);
        vt.scroll_viewport(ScrollViewport::Row(top as usize));
        let bottom = (top + vt.scrollbar().map_or(1, |s| s.len)) as u32;
        let insensitive = !pattern.chars().any(char::is_uppercase);
        self.search = if pattern.is_empty() {
            None
        } else {
            literal_regex(&pattern, insensitive).map(|regex| Search {
                matches: self.text.search_rows(vt, &regex, top as u32, bottom, true),
                pattern,
                regex,
                backward: false,
                whole_keyword: false,
            })
        };
        if self.search.as_ref().is_some_and(|s| s.matches.is_empty()) {
            self.cancel_prompt(vt);
            return;
        }
        let previous = std::mem::take(&mut self.flash_labels);
        let Some(search) = &self.search else {
            return;
        };
        // A label must never consume a character that could extend ANY match.
        // Fold continuations even for smartcase queries: adding an uppercase
        // character can change a previously case-insensitive query's matches.
        let continuations: HashSet<char> = search
            .matches
            .iter()
            .filter_map(|(_, end)| {
                self.text
                    .next(vt, *end)
                    .map(|(_, c)| c.to_ascii_lowercase())
            })
            .collect();
        let mut available: Vec<char> = LABELS
            .chars()
            .filter(|c| !continuations.contains(&c.to_ascii_lowercase()))
            .collect();
        let mut matches = search.matches.clone();
        matches.sort_by_key(|(start, _)| {
            (i64::from(start.y) - i64::from(origin.y)).unsigned_abs() * u64::from(self.text.cols)
                + u64::from(start.x.abs_diff(origin.x))
        });
        let mut occupied = HashSet::new();
        let targets: HashSet<Pos> = matches.iter().map(|(start, _)| *start).collect();
        // Preserve labels for surviving targets as the query is narrowed.
        for reuse in [true, false] {
            for (start, end) in &matches {
                if self
                    .flash_labels
                    .iter()
                    .any(|(target, _, _)| target == start)
                {
                    continue;
                }
                let old = previous
                    .iter()
                    .find(|(target, _, _)| target == start)
                    .and_then(|(_, _, c)| available.iter().position(|a| a == c));
                let index = if reuse {
                    old
                } else {
                    (!available.is_empty()).then_some(0)
                };
                let Some(index) = index else {
                    continue;
                };
                // After the match when possible; at its start at the right edge.
                let at = self
                    .text
                    .next(vt, *end)
                    .filter(|(p, _)| p.y == end.y && p.x < self.text.cols && !targets.contains(p))
                    .map_or(*start, |(p, _)| p);
                let at = if occupied.contains(&at) { *start } else { at };
                if !occupied.insert(at) {
                    continue;
                }
                self.flash_labels
                    .push((*start, at, available.remove(index)));
            }
        }
        // Keep the cursor in place while typing. Enter jumps to the next match;
        // Tab/Shift-Tab can choose an unlabeled match when labels run out.
    }
}
