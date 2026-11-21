//! Vi-style keyboard copy mode over a frozen terminal: motions, counts, visual
//! modes, text objects, a yank operator and incremental search.
//!
//! Frontends translate key events into [`Input`], apply the returned
//! [`Effect`] and paint [`CopyMode::cursor_viewport`] and
//! [`CopyMode::highlights`]. Positions are screen coordinates including
//! scrollback; they stay valid because copy mode freezes the screen.
use libghostty_vt::{
    Terminal,
    screen::{CellSemanticContent, CellWide, Screen},
    selection::Selection,
    terminal::{Point, PointCoordinate, ScrollViewport},
};
use std::collections::HashMap;
mod flash;
mod iskeyword;
mod surround;
mod vim_regex;
mod words;
pub use iskeyword::IsKeyword;
use surround::SurroundOp;

/// Cell position: screen row (scrollback included), then column.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Pos {
    pub y: u32,
    pub x: u16,
}

impl Pos {
    pub fn new(x: u16, y: u32) -> Self {
        Self { y, x }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Char(char),
    Escape,
    Enter,
    Backspace,
    Tab,
    Up,
    Down,
    Left,
    Right,
    PageUp,
    PageDown,
    Home,
    End,
    F3,
}

/// One key press. `Char` already carries Shift (`G`, `$`, `{`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Input {
    pub key: Key,
    pub ctrl: bool,
    pub shift: bool,
}

impl Input {
    pub fn key(key: Key) -> Self {
        Self {
            key,
            ctrl: false,
            shift: false,
        }
    }
    pub fn char(c: char) -> Self {
        Self::key(Key::Char(c))
    }
    pub fn ctrl(c: char) -> Self {
        Self {
            ctrl: true,
            ..Self::char(c)
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VisualKind {
    Char,
    Line,
    Block,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Effect {
    None,
    /// Leave copy mode: call [`CopyMode::finish`].
    Exit,
    /// Put `text` on the clipboard, then leave copy mode when `exit` is set.
    Copy {
        text: String,
        exit: bool,
    },
    /// Apply output held since copy mode froze the screen.
    Refresh,
}

/// Wide glyphs occupy a second cell that is never a cursor position.
const SPACER: char = '\0';
/// Bracket scans and text objects give up after this many cells.
const SCAN_LIMIT: usize = 1 << 20;
const MAX_MATCHES: usize = 100_000;

#[derive(Clone, Copy, Debug)]
struct Visual {
    anchor: Pos,
    kind: VisualKind,
    /// Block mode after `$`: every row extends to its own end.
    eol: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Find {
    Forward,
    Backward,
    Till,
    TillBack,
}

impl Find {
    fn forward(self) -> bool {
        matches!(self, Self::Forward | Self::Till)
    }
    fn till(self) -> bool {
        matches!(self, Self::Till | Self::TillBack)
    }
    fn reversed(self) -> Self {
        match self {
            Self::Forward => Self::Backward,
            Self::Backward => Self::Forward,
            Self::Till => Self::TillBack,
            Self::TillBack => Self::Till,
        }
    }
}

/// A key prefix waiting for its second key.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Wait {
    None,
    G,
    Z,
    Bracket(char),
    Object {
        around: bool,
    },
    Find(Find),
    Word,
    WordG,
    WordObject {
        around: bool,
    },
    /// vim-surround: the replacement after `ys{motion}`, `cs{target}` or `S`.
    Replacement,
    /// `d` and `c` only begin `ds` and `cs`/`cS`.
    D,
    C,
    Target(SurroundOp),
}

/// How a motion's range is yanked, as in Vim.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Span {
    Exclusive,
    Inclusive,
    Lines,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Motion {
    Left,
    Right,
    Up,
    Down,
    LineStart,
    FirstNonBlank,
    LineEnd,
    LastNonBlank,
    NextLine,
    PrevLine,
    Top,
    Bottom,
    ScreenTop,
    ScreenMiddle,
    ScreenBottom,
    Word { big: bool, back: bool, end: bool },
    Subword { back: bool, end: bool },
    Paragraph { forward: bool },
    Bracket,
    Prompt { forward: bool },
    Find(Find, char),
    RepeatFind { reverse: bool },
    Match { reverse: bool },
}

impl Motion {
    fn vertical(self) -> bool {
        matches!(self, Self::Up | Self::Down)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Scroll {
    Line(i64),
    Half(i64),
    Page(i64),
    Center,
    Top,
    Bottom,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Cmd {
    Motion(Motion),
    Scroll(Scroll),
    Visual(VisualKind),
    ToggleVisual,
    SwapEnds { horizontal: bool },
    Reselect,
    SelectMatch { reverse: bool },
    Yank,
    YankToEnd,
    Accept,
    Object { around: bool, kind: char },
    SubwordObject { around: bool },
    Search { backward: bool },
    Flash,
    Star { backward: bool },
    Refresh,
    Exit,
}

struct Search {
    pattern: String,
    regex: fancy_regex::Regex,
    backward: bool,
    /// Inclusive bounds, ordered; a wide final glyph includes its spacer.
    matches: Vec<(Pos, Pos)>,
    whole_keyword: bool,
}

struct Prompt {
    text: String,
    backward: bool,
    origin: Pos,
    view: Option<u64>,
    exit_on_cancel: bool,
    previous: Option<Search>,
    flash: bool,
    /// `ys`: the jump yanks from the cursor up to the target.
    yank: bool,
    /// `yr`: after the jump, the next motion yanks from the target.
    remote: bool,
}

pub struct CopyMode {
    cursor: Pos,
    /// Sticky column for vertical motions; `u16::MAX` follows line ends.
    want_x: u16,
    visual: Option<Visual>,
    last_visual: Option<(Visual, Pos)>,
    count: u32,
    yank: bool,
    yank_count: u32,
    wait: Wait,
    keys: String,
    last_find: Option<(Find, char)>,
    prompt: Option<Prompt>,
    search: Option<Search>,
    text: Text,
    screen: Option<Screen>,
    /// Viewport to restore on exit; `None` follows the bottom.
    entry_view: Option<u64>,
    flash_labels: Vec<(Pos, Pos, char)>,
    /// `ys`/`yS` waiting for a motion.
    surround: Option<SurroundOp>,
    wrap: Option<surround::Wrap>,
    asking: Option<surround::Asking>,
}

impl CopyMode {
    /// Start at `cursor`, a viewport cell (normally the terminal cursor).
    pub fn new(vt: &mut Terminal<'_, '_>, cursor: (u16, u16)) -> Self {
        let bar = vt.scrollbar().ok();
        let top = bar.map_or(0, |s| s.offset) as u32;
        let mut mode = Self {
            cursor: Pos::new(cursor.0, top + u32::from(cursor.1)),
            want_x: cursor.0,
            visual: None,
            last_visual: None,
            count: 0,
            yank: false,
            yank_count: 0,
            wait: Wait::None,
            keys: String::new(),
            last_find: None,
            prompt: None,
            search: None,
            text: Text::new(vt),
            screen: vt.active_screen().ok(),
            entry_view: bar.filter(|s| s.offset + s.len < s.total).map(|s| s.offset),
            flash_labels: Vec::new(),
            surround: None,
            wrap: None,
            asking: None,
        };
        mode.cursor = mode.text.clamp(vt, mode.cursor);
        mode.want_x = mode.cursor.x;
        mode.sync(vt);
        mode
    }

    /// Open the search prompt. `exit_on_cancel` makes Escape leave copy mode,
    /// for a search started outside it.
    pub fn open_search(&mut self, vt: &mut Terminal<'_, '_>, backward: bool, exit_on_cancel: bool) {
        self.clear_pending();
        self.flash_labels.clear();
        self.prompt = Some(Prompt {
            text: String::new(),
            backward,
            origin: self.cursor,
            view: vt.scrollbar().ok().map(|s| s.offset),
            exit_on_cancel,
            previous: self.search.take(),
            flash: false,
            yank: false,
            remote: false,
        });
    }

    /// Replace normal-word rules without changing WORDs or Space wordmotion.
    pub fn set_iskeyword(&mut self, keyword: IsKeyword) {
        self.text.keyword = keyword;
    }

    pub fn screen(&self) -> Option<Screen> {
        self.screen
    }

    /// A prompt takes typed text (the platform input method may compose it).
    pub fn wants_text(&self) -> bool {
        self.prompt.is_some() || self.asking.is_some()
    }

    pub fn key(&mut self, vt: &mut Terminal<'_, '_>, input: Input) -> Effect {
        if self.asking.is_some() {
            let effect = self.asking_key(vt, input);
            if effect == Effect::None {
                self.sync(vt);
            }
            return effect;
        }
        if self.prompt.is_some() {
            return self.prompt_key(vt, input);
        }
        let effect = self.normal_key(vt, input);
        if matches!(effect, Effect::None | Effect::Refresh) {
            self.sync(vt);
        }
        effect
    }

    /// A named action from a configured key binding.
    pub fn action(&mut self, vt: &mut Terminal<'_, '_>, action: &str) -> Effect {
        let key = |key| Input::key(key);
        match action {
            "cancel" if self.prompt.is_some() => self.key(vt, key(Key::Escape)),
            "cancel" => Effect::Exit,
            "accept" if self.prompt.is_some() => self.key(vt, key(Key::Enter)),
            "accept" => self.run(vt, Cmd::Accept),
            "copy" => match self.copy_text(vt) {
                Some(text) => Effect::Copy { text, exit: false },
                None => Effect::None,
            },
            "refresh" => Effect::Refresh,
            "next" | "previous" if self.prompt.is_some() => {
                self.prompt_step(vt, action == "previous");
                Effect::None
            }
            "next" => self.key(vt, Input::char('n')),
            "previous" => self.key(vt, Input::char('N')),
            "left" => self.key(vt, key(Key::Left)),
            "right" => self.key(vt, key(Key::Right)),
            "up" => self.key(vt, key(Key::Up)),
            "down" => self.key(vt, key(Key::Down)),
            "page_up" => self.key(vt, key(Key::PageUp)),
            "page_down" => self.key(vt, key(Key::PageDown)),
            "line_start" => self.key(vt, key(Key::Home)),
            "line_end" => self.key(vt, key(Key::End)),
            "top" => self
                .key(vt, Input::char('g'))
                .and(|| self.key(vt, Input::char('g'))),
            "bottom" => self.key(vt, Input::char('G')),
            "toggle_selection" => {
                let effect = self.run(vt, Cmd::ToggleVisual);
                self.sync(vt);
                effect
            }
            "backspace" => self.key(vt, key(Key::Backspace)),
            "clear" => self.key(vt, Input::ctrl('u')),
            _ => Effect::None,
        }
    }

    /// Text to copy without leaving: the selection, else the match under the
    /// cursor (which becomes the selection).
    pub fn copy_text(&mut self, vt: &mut Terminal<'_, '_>) -> Option<String> {
        if let Some(visual) = self.visual {
            return self.visual_text(vt, visual);
        }
        let (a, b) = self.match_at_cursor()?;
        self.range_text(vt, a, b, Span::Inclusive)
    }

    /// Search for literal, case-sensitive `query` from outside copy mode:
    /// the newest match first, then step on repeated calls. The current match
    /// is selected so it can be copied directly.
    pub fn find_text(&mut self, vt: &mut Terminal<'_, '_>, query: &str, backward: bool) -> usize {
        self.prompt = None;
        self.flash_labels.clear();
        let repeat = self.search.as_ref().is_some_and(|s| {
            !s.whole_keyword
                && s.pattern == query
                && s.regex.as_str() == literal(query, false).as_str()
        });
        if repeat {
            if let Some(p) = self.next_match(self.cursor, backward, 1) {
                self.cursor = p;
            }
        } else {
            self.search = literal_regex(query, false).map(|regex| Search {
                pattern: query.to_owned(),
                matches: self.text.search(vt, &regex),
                regex,
                backward,
                whole_keyword: false,
            });
            if let Some(&(start, _)) = self.search.as_ref().and_then(|s| s.matches.last()) {
                self.cursor = start;
            }
        }
        self.visual = None;
        self.want_x = self.cursor.x;
        reveal(vt, self.cursor.y);
        match self.match_at_cursor() {
            Some((a, b)) => set_selection(vt, a, b, false),
            None => {
                let _ = vt.set_selection(None);
            }
        }
        self.search.as_ref().map_or(0, |s| s.matches.len())
    }

    /// Re-read the screen after held output was applied.
    pub fn refresh(&mut self, vt: &mut Terminal<'_, '_>) {
        let keyword = std::mem::take(&mut self.text.keyword);
        self.text = Text::new(vt);
        self.text.keyword = keyword;
        self.cursor = self.text.clamp(vt, self.cursor);
        if let Some(visual) = self.visual.as_mut() {
            visual.anchor = self.text.clamp(vt, visual.anchor);
        }
        if let Some(search) = self.search.as_mut() {
            search.matches = self
                .text
                .search_keywords(vt, &search.regex, search.whole_keyword);
        }
        if self.prompt.as_ref().is_some_and(|p| p.flash) {
            self.update_prompt(vt);
        }
        self.sync(vt);
    }

    /// Clear the selection and restore the viewport copy mode started from.
    pub fn finish(self, vt: &mut Terminal<'_, '_>) {
        let _ = vt.set_selection(None);
        vt.scroll_viewport(match self.entry_view {
            Some(row) => ScrollViewport::Row(row as usize),
            None => ScrollViewport::Bottom,
        });
    }

    /// Scroll the view by `lines`, keeping the cursor on screen (mouse wheel).
    pub fn scroll_view(&mut self, vt: &mut Terminal<'_, '_>, lines: i64) {
        self.scroll(vt, Scroll::Line(lines), 1);
        self.sync(vt);
    }

    /// Move the cursor to a viewport cell (pointer click).
    pub fn place(&mut self, vt: &mut Terminal<'_, '_>, col: u16, row: u16) {
        let top = vt.scrollbar().map_or(0, |s| s.offset) as u32;
        self.clear_pending();
        self.cursor = self.text.clamp(vt, Pos::new(col, top + u32::from(row)));
        self.want_x = self.cursor.x;
        self.sync(vt);
    }

    /// The copy cursor as a viewport cell, and whether its glyph is wide.
    pub fn cursor_viewport(&self, vt: &Terminal<'_, '_>) -> Option<(u16, u16, bool)> {
        let bar = vt.scrollbar().ok()?;
        let y = u64::from(self.cursor.y);
        if y < bar.offset || y >= bar.offset + bar.len {
            return None;
        }
        let wide = self
            .text
            .cached_char(Pos::new(self.cursor.x.saturating_add(1), self.cursor.y))
            == Some(SPACER);
        Some((
            self.cursor.x.min(self.text.cols - 1),
            (y - bar.offset) as u16,
            wide,
        ))
    }

    /// Visible search matches as `(row, from, to_exclusive, current)`.
    pub fn highlights(&self, top: u64, rows: u16, cols: u16) -> Vec<(u16, u16, u16, bool)> {
        let Some(search) = &self.search else {
            return Vec::new();
        };
        let current = self.match_index();
        let bottom = top + u64::from(rows);
        let first = search
            .matches
            .partition_point(|(_, end)| u64::from(end.y) < top);
        let mut out = Vec::new();
        for (i, (start, end)) in search.matches.iter().enumerate().skip(first) {
            if u64::from(start.y) >= bottom {
                break;
            }
            for y in u64::from(start.y).max(top)..=u64::from(end.y).min(bottom - 1) {
                let from = if y == u64::from(start.y) { start.x } else { 0 };
                let to = if y == u64::from(end.y) {
                    end.x + 1
                } else {
                    cols
                };
                out.push(((y - top) as u16, from, to.min(cols), Some(i) == current));
            }
        }
        out
    }

    pub fn status(&self) -> String {
        if let Some(asking) = self.asking_status() {
            return asking;
        }
        if let Some(prompt) = &self.prompt {
            let prefix = if prompt.flash {
                "s "
            } else if prompt.backward {
                "?"
            } else {
                "/"
            };
            let mut status = format!("{prefix}{}", prompt.text);
            if !prompt.text.is_empty() {
                status += &self.match_status().unwrap_or_else(|| "  [no match]".into());
            }
            return status;
        }
        let mut status = String::from(match self.visual.map(|v| v.kind) {
            None => "COPY",
            Some(VisualKind::Char) => "VISUAL",
            Some(VisualKind::Line) => "V-LINE",
            Some(VisualKind::Block) => "V-BLOCK",
        });
        if !self.keys.is_empty() {
            status += "  ";
            status += &self.keys;
        }
        if let Some(search) = &self.search {
            status += &format!("  /{}", search.pattern);
            status += &self.match_status().unwrap_or_else(|| "  [no match]".into());
        }
        status += &format!(
            "  {}/{}:{}",
            self.cursor.y + 1,
            self.text.total,
            self.cursor.x + 1
        );
        status
    }

    fn match_status(&self) -> Option<String> {
        let search = self.search.as_ref()?;
        if search.matches.is_empty() {
            return None;
        }
        Some(match self.match_index() {
            Some(i) => format!("  [{}/{}]", i + 1, search.matches.len()),
            None => format!("  [{} matches]", search.matches.len()),
        })
    }

    fn match_index(&self) -> Option<usize> {
        let matches = &self.search.as_ref()?.matches;
        let i = matches.partition_point(|(start, _)| *start <= self.cursor);
        i.checked_sub(1).filter(|&i| matches[i].1 >= self.cursor)
    }

    fn match_at_cursor(&self) -> Option<(Pos, Pos)> {
        let i = self.match_index()?;
        self.search.as_ref().map(|s| s.matches[i])
    }

    fn clear_pending(&mut self) {
        self.count = 0;
        self.yank = false;
        self.yank_count = 0;
        self.wait = Wait::None;
        self.keys.clear();
        self.surround = None;
        self.wrap = None;
        self.asking = None;
    }

    fn pending(&self) -> bool {
        self.count > 0 || self.yank || self.wait != Wait::None || self.wrap.is_some()
    }

    /// The typed count, `None` when absent; counts before and after `y` multiply.
    fn take_count(&mut self) -> Option<u32> {
        let count = match (self.count, self.yank_count) {
            (0, 0) => None,
            (a, b) => Some(a.max(1).saturating_mul(b.max(1))),
        };
        self.count = 0;
        self.yank_count = 0;
        self.wait = Wait::None;
        self.keys.clear();
        count
    }

    fn normal_key(&mut self, vt: &mut Terminal<'_, '_>, input: Input) -> Effect {
        let ch = match input.key {
            Key::Char(c) if !input.ctrl => Some(c),
            _ => None,
        };
        if input.key == Key::Escape || (input.ctrl && input.key == Key::Char('[')) {
            if self.pending() {
                self.clear_pending();
            } else if self.visual.is_some() {
                self.leave_visual();
            } else {
                return Effect::Exit;
            }
            return Effect::None;
        }
        if input.ctrl && input.key == Key::Char('c') {
            return Effect::Exit;
        }
        let wait = std::mem::replace(&mut self.wait, Wait::None);
        if wait == Wait::Replacement {
            return self.replacement_key(vt, input);
        }
        if wait != Wait::None {
            let cmd = match (wait, ch) {
                (Wait::D, Some('s')) | (Wait::C, Some('s' | 'S')) => {
                    self.wait = Wait::Target(match (wait, ch) {
                        (Wait::D, _) => SurroundOp::Delete,
                        (_, Some('S')) => SurroundOp::Change { lines: true },
                        _ => SurroundOp::Change { lines: false },
                    });
                    self.keys.extend(ch);
                    return Effect::None;
                }
                (Wait::Target(op), Some(target)) => {
                    self.keys.clear();
                    return self.surround_target(vt, op, target);
                }
                (Wait::G, Some('S')) if self.visual.is_some() => {
                    self.visual_wrap(false);
                    return Effect::None;
                }
                (Wait::Find(find), Some(c)) => {
                    self.last_find = Some((find, c));
                    Some(Cmd::Motion(Motion::Find(find, c)))
                }
                (Wait::Object { around }, Some(' ')) => {
                    self.wait = Wait::WordObject { around };
                    self.keys.push(' ');
                    return Effect::None;
                }
                (Wait::Object { around }, Some(kind)) => Some(Cmd::Object { around, kind }),
                (Wait::Word, Some('g')) => {
                    self.wait = Wait::WordG;
                    self.keys.push('g');
                    return Effect::None;
                }
                (Wait::Word, Some(c @ ('w' | 'b' | 'e'))) => Some(Cmd::Motion(Motion::Subword {
                    back: c == 'b',
                    end: c == 'e',
                })),
                (Wait::WordG, Some('e')) => Some(Cmd::Motion(Motion::Subword {
                    back: true,
                    end: true,
                })),
                (Wait::Word, Some(c @ ('W' | 'B' | 'E'))) => Some(Cmd::Motion(Motion::Word {
                    big: true,
                    back: c == 'B',
                    end: c == 'E',
                })),
                (Wait::WordG, Some('E')) => Some(Cmd::Motion(Motion::Word {
                    big: true,
                    back: true,
                    end: true,
                })),
                (Wait::WordObject { around }, Some('w')) => Some(Cmd::SubwordObject { around }),
                (Wait::WordObject { around }, Some('W')) => Some(Cmd::Object { around, kind: 'W' }),
                (Wait::G, Some('g')) => Some(Cmd::Motion(Motion::Top)),
                (Wait::G, Some(c @ ('e' | 'E'))) => Some(Cmd::Motion(Motion::Word {
                    big: c == 'E',
                    back: true,
                    end: true,
                })),
                (Wait::G, Some('_')) => Some(Cmd::Motion(Motion::LastNonBlank)),
                (Wait::G, Some('$')) => Some(Cmd::Motion(Motion::LineEnd)),
                (Wait::G, Some('0' | '^')) => Some(Cmd::Motion(Motion::FirstNonBlank)),
                (Wait::G, Some('j')) => Some(Cmd::Motion(Motion::Down)),
                (Wait::G, Some('k')) => Some(Cmd::Motion(Motion::Up)),
                (Wait::G, Some('v')) => Some(Cmd::Reselect),
                (Wait::G, Some(c @ ('n' | 'N'))) => Some(Cmd::SelectMatch { reverse: c == 'N' }),
                (Wait::Z, Some('z' | '.')) => Some(Cmd::Scroll(Scroll::Center)),
                (Wait::Z, Some('t')) => Some(Cmd::Scroll(Scroll::Top)),
                (Wait::Z, Some('b' | '-')) => Some(Cmd::Scroll(Scroll::Bottom)),
                (Wait::Z, None) if input.key == Key::Enter => Some(Cmd::Scroll(Scroll::Top)),
                (Wait::Bracket(open), Some(c)) if c == open => Some(Cmd::Motion(Motion::Prompt {
                    forward: open == ']',
                })),
                _ => None,
            };
            return match cmd {
                Some(cmd) => self.run(vt, cmd),
                None => {
                    self.clear_pending();
                    Effect::None
                }
            };
        }
        if let Some(c) = ch.filter(|c| c.is_ascii_digit()) {
            let digit = c.to_digit(10).unwrap_or(0);
            let active = if self.yank {
                self.yank_count
            } else {
                self.count
            };
            if digit > 0 || active > 0 {
                let next = active.saturating_mul(10).saturating_add(digit).min(99_999);
                if self.yank {
                    self.yank_count = next;
                } else {
                    self.count = next;
                }
                self.keys.push(c);
                return Effect::None;
            }
        }
        let cmd = match (input.key, input.ctrl) {
            (Key::Char(c), true) => match c.to_ascii_lowercase() {
                'e' => Cmd::Scroll(Scroll::Line(1)),
                'y' => Cmd::Scroll(Scroll::Line(-1)),
                'd' => Cmd::Scroll(Scroll::Half(1)),
                'u' => Cmd::Scroll(Scroll::Half(-1)),
                'f' => Cmd::Scroll(Scroll::Page(1)),
                'b' => Cmd::Scroll(Scroll::Page(-1)),
                'v' => Cmd::Visual(VisualKind::Block),
                'n' | 'j' => Cmd::Motion(Motion::Down),
                'p' | 'k' => Cmd::Motion(Motion::Up),
                _ => return self.unknown(),
            },
            (Key::Home, true) => Cmd::Motion(Motion::Top),
            (Key::End, true) => Cmd::Motion(Motion::Bottom),
            (Key::Char(c), false) => {
                // vim-surround's ys is yS here (ys yanks to a flash target);
                // ySS, or ySs, takes the line.
                if self.yank && self.visual.is_none() {
                    match (self.surround, c) {
                        (None, 'S') => {
                            self.surround = Some(SurroundOp::Add);
                            self.keys.push(c);
                            return Effect::None;
                        }
                        (Some(SurroundOp::Add), 's' | 'S') => {
                            self.surround_line(vt);
                            return Effect::None;
                        }
                        _ => {}
                    }
                }
                if c == 'S' && self.visual.is_some() {
                    self.visual_wrap(true);
                    return Effect::None;
                }
                // Flash remote, as in flash.nvim's operator-pending `r`.
                if c == 'r' && self.yank && self.surround.is_none() && self.visual.is_none() {
                    self.open_search(vt, false, false);
                    let prompt = self.prompt.as_mut().unwrap();
                    prompt.flash = true;
                    prompt.remote = true;
                    return Effect::None;
                }
                let wait = match c {
                    'f' => Some(Wait::Find(Find::Forward)),
                    'F' => Some(Wait::Find(Find::Backward)),
                    't' => Some(Wait::Find(Find::Till)),
                    'T' => Some(Wait::Find(Find::TillBack)),
                    'g' => Some(Wait::G),
                    'd' if !self.yank && self.visual.is_none() => Some(Wait::D),
                    'c' if !self.yank && self.visual.is_none() => Some(Wait::C),
                    ' ' => Some(Wait::Word),
                    'z' => Some(Wait::Z),
                    '[' | ']' => Some(Wait::Bracket(c)),
                    'i' | 'a' if self.yank || self.visual.is_some() => {
                        Some(Wait::Object { around: c == 'a' })
                    }
                    _ => None,
                };
                if let Some(wait) = wait {
                    self.wait = wait;
                    self.keys.push(c);
                    return Effect::None;
                }
                match c {
                    'h' => Cmd::Motion(Motion::Left),
                    'l' => Cmd::Motion(Motion::Right),
                    'j' => Cmd::Motion(Motion::Down),
                    'k' => Cmd::Motion(Motion::Up),
                    'w' | 'W' | 'b' | 'B' | 'e' | 'E' => Cmd::Motion(Motion::Word {
                        big: c.is_ascii_uppercase(),
                        back: matches!(c, 'b' | 'B'),
                        end: matches!(c, 'e' | 'E'),
                    }),
                    '0' => Cmd::Motion(Motion::LineStart),
                    '^' => Cmd::Motion(Motion::FirstNonBlank),
                    '$' => Cmd::Motion(Motion::LineEnd),
                    '+' => Cmd::Motion(Motion::NextLine),
                    '-' => Cmd::Motion(Motion::PrevLine),
                    'G' => Cmd::Motion(Motion::Bottom),
                    'H' => Cmd::Motion(Motion::ScreenTop),
                    'M' => Cmd::Motion(Motion::ScreenMiddle),
                    'L' => Cmd::Motion(Motion::ScreenBottom),
                    '{' | '}' => Cmd::Motion(Motion::Paragraph { forward: c == '}' }),
                    '%' => Cmd::Motion(Motion::Bracket),
                    ';' | ',' => Cmd::Motion(Motion::RepeatFind { reverse: c == ',' }),
                    'n' | 'N' => Cmd::Motion(Motion::Match { reverse: c == 'N' }),
                    '*' | '#' => Cmd::Star { backward: c == '#' },
                    '/' | '?' => Cmd::Search { backward: c == '?' },
                    's' => Cmd::Flash,
                    'v' => Cmd::Visual(VisualKind::Char),
                    'V' => Cmd::Visual(VisualKind::Line),
                    'o' | 'O' => Cmd::SwapEnds {
                        horizontal: c == 'O',
                    },
                    'y' => Cmd::Yank,
                    'Y' => Cmd::YankToEnd,
                    'r' => Cmd::Refresh,
                    'q' => Cmd::Exit,
                    // Back to typing, like insert mode.
                    'i' | 'a' | 'I' | 'A' if !self.yank && self.visual.is_none() => Cmd::Exit,
                    _ => return self.unknown(),
                }
            }
            (Key::Left | Key::Backspace, _) => Cmd::Motion(Motion::Left),
            (Key::Right, _) => Cmd::Motion(Motion::Right),
            (Key::Up, _) => Cmd::Motion(Motion::Up),
            (Key::Down, _) => Cmd::Motion(Motion::Down),
            (Key::Home, _) => Cmd::Motion(Motion::LineStart),
            (Key::End, _) => Cmd::Motion(Motion::LineEnd),
            (Key::PageUp, _) => Cmd::Scroll(Scroll::Page(-1)),
            (Key::PageDown, _) => Cmd::Scroll(Scroll::Page(1)),
            (Key::Enter, _) => Cmd::Accept,
            (Key::F3, _) => Cmd::Motion(Motion::Match {
                reverse: input.shift,
            }),
            _ => return self.unknown(),
        };
        self.run(vt, cmd)
    }

    fn unknown(&mut self) -> Effect {
        self.clear_pending();
        Effect::None
    }

    fn run(&mut self, vt: &mut Terminal<'_, '_>, cmd: Cmd) -> Effect {
        match cmd {
            Cmd::Yank if self.visual.is_none() && !self.yank => {
                // An operator: keep the count for its motion.
                self.yank = true;
                self.keys.push('y');
                return Effect::None;
            }
            Cmd::Yank if self.visual.is_none() => {
                let count = self.take_count().unwrap_or(1);
                self.yank = false;
                if self.cursor.y + count > self.text.total {
                    return Effect::None;
                }
                let last = self.cursor.y + count - 1;
                return self.yank_range(vt, self.cursor, Pos::new(0, last), Span::Lines);
            }
            _ => {}
        }
        let count = self.take_count();
        let yank = std::mem::take(&mut self.yank);
        match cmd {
            Cmd::Motion(motion) => {
                // Operator motions may use the newline slot; normal cursors may not.
                let result = self.motion(vt, motion, count, yank);
                let Some((target, span)) = result else {
                    return Effect::None;
                };
                if yank {
                    return self.operator_range(vt, self.cursor, target, span);
                }
                self.move_to(vt, target, motion);
            }
            Cmd::Object { .. } | Cmd::SubwordObject { .. } => {
                let range = match cmd {
                    Cmd::SubwordObject { around } => self
                        .text
                        .subword_object(vt, self.cursor, around, count.unwrap_or(1))
                        .map(|(a, b)| (a, b, Span::Inclusive)),
                    Cmd::Object { around, kind } => {
                        self.object(vt, kind, around, count.unwrap_or(1))
                    }
                    _ => unreachable!(),
                };
                let Some((a, b, span)) = range else {
                    return Effect::None;
                };
                if yank {
                    return self.operator_range(vt, a, b, span);
                }
                if let Some(visual) = self.visual.as_mut() {
                    visual.anchor = a;
                    visual.eol = false;
                    visual.kind = if span == Span::Lines {
                        VisualKind::Line
                    } else {
                        VisualKind::Char
                    };
                    self.cursor = b;
                    self.want_x = b.x;
                }
            }
            Cmd::Scroll(scroll) => self.scroll(vt, scroll, count.unwrap_or(1)),
            Cmd::Visual(kind) => match self.visual.as_mut() {
                Some(visual) if visual.kind == kind => self.leave_visual(),
                Some(visual) => visual.kind = kind,
                None => {
                    self.visual = Some(Visual {
                        anchor: self.cursor,
                        kind,
                        eol: false,
                    })
                }
            },
            Cmd::ToggleVisual => match self.visual {
                Some(_) => self.leave_visual(),
                None => {
                    self.visual = Some(Visual {
                        anchor: self.cursor,
                        kind: VisualKind::Char,
                        eol: false,
                    })
                }
            },
            Cmd::SwapEnds { horizontal } => {
                if let Some(visual) = self.visual.as_mut() {
                    if horizontal && visual.kind == VisualKind::Block {
                        std::mem::swap(&mut visual.anchor.x, &mut self.cursor.x);
                    } else {
                        std::mem::swap(&mut visual.anchor, &mut self.cursor);
                    }
                    self.want_x = self.cursor.x;
                }
            }
            Cmd::Reselect => {
                if let Some((visual, cursor)) = self.last_visual {
                    self.visual = Some(visual);
                    self.cursor = cursor;
                    self.want_x = cursor.x;
                }
            }
            Cmd::SelectMatch { reverse } => {
                let found = self.search.as_ref().and_then(|search| {
                    let backward = search.backward != reverse;
                    match self.match_index() {
                        Some(i) => Some(search.matches[i]),
                        None => {
                            let start = self.next_match(self.cursor, backward, 1)?;
                            search.matches.iter().find(|(s, _)| *s == start).copied()
                        }
                    }
                });
                let Some((a, b)) = found else {
                    return Effect::None;
                };
                if yank {
                    return self.operator_range(vt, a, b, Span::Inclusive);
                }
                self.visual = Some(Visual {
                    anchor: a,
                    kind: VisualKind::Char,
                    eol: false,
                });
                self.cursor = b;
                self.want_x = b.x;
            }
            Cmd::Yank => return self.yank_visual(vt),
            Cmd::YankToEnd => {
                if let Some(visual) = self.visual.as_mut() {
                    visual.kind = VisualKind::Line;
                    return self.yank_visual(vt);
                }
                return match self.motion(vt, Motion::LineEnd, count, true) {
                    Some((target, _)) => self.yank_range(vt, self.cursor, target, Span::Inclusive),
                    None => Effect::None,
                };
            }
            Cmd::Accept => {
                if self.visual.is_some() {
                    return self.yank_visual(vt);
                }
                if let Some((a, b)) = self.match_at_cursor() {
                    return self.yank_range(vt, a, b, Span::Inclusive);
                }
            }
            Cmd::Search { backward } => self.open_search(vt, backward, false),
            Cmd::Flash => {
                self.open_search(vt, false, false);
                let prompt = self.prompt.as_mut().unwrap();
                prompt.flash = true;
                prompt.yank = yank;
                self.flash_labels.clear();
            }
            Cmd::Star { backward } => self.star(vt, backward, count.unwrap_or(1)),
            Cmd::Refresh => return Effect::Refresh,
            Cmd::Exit => return Effect::Exit,
        }
        Effect::None
    }

    fn move_to(&mut self, vt: &Terminal<'_, '_>, target: Pos, motion: Motion) {
        self.cursor = if self
            .visual
            .is_some_and(|v| matches!(v.kind, VisualKind::Char | VisualKind::Block))
            && motion == Motion::LineEnd
        {
            Pos::new(self.text.len(vt, target.y) as u16, target.y)
        } else if self.visual.is_some() {
            target
        } else {
            self.text.clamp(vt, target)
        };
        if !matches!(
            motion,
            Motion::Up
                | Motion::Down
                | Motion::Top
                | Motion::Bottom
                | Motion::ScreenTop
                | Motion::ScreenMiddle
                | Motion::ScreenBottom
        ) {
            self.want_x = if motion == Motion::LineEnd {
                u16::MAX
            } else {
                self.cursor.x
            };
        }
        if let Some(visual) = self.visual.as_mut()
            && visual.kind == VisualKind::Block
            && !motion.vertical()
        {
            visual.eol = motion == Motion::LineEnd;
        }
    }

    fn leave_visual(&mut self) {
        if let Some(visual) = self.visual.take() {
            self.last_visual = Some((visual, self.cursor));
        }
    }

    fn motion(
        &mut self,
        vt: &Terminal<'_, '_>,
        motion: Motion,
        count: Option<u32>,
        operator: bool,
    ) -> Option<(Pos, Span)> {
        let n = count.unwrap_or(1).max(1);
        let p = self.cursor;
        let t = &mut self.text;
        let last_row = t.total - 1;
        let column = |t: &mut Text, y: u32, want: u16| {
            if want == u16::MAX {
                let end = t.line_last(vt, y);
                if self.visual.is_some_and(|v| v.kind != VisualKind::Line) {
                    Pos::new(t.len(vt, end.y) as u16, end.y)
                } else {
                    end
                }
            } else if self
                .visual
                .is_some_and(|v| matches!(v.kind, VisualKind::Char | VisualKind::Block))
                && want as usize >= t.len(vt, y)
            {
                Pos::new(t.len(vt, y) as u16, y)
            } else {
                t.clamp(vt, Pos::new(want, y))
            }
        };
        let viewport = vt.scrollbar().ok();
        let view_row = |offset: i64| {
            let bar = viewport.as_ref();
            let top = bar.map_or(0, |b| b.offset) as i64;
            let len = bar.map_or(1, |b| b.len.max(1)) as i64;
            let row = if offset >= 0 {
                top + offset
            } else {
                top + len + offset
            };
            row.clamp(top, top + len - 1).clamp(0, i64::from(last_row)) as u32
        };
        Some(match motion {
            Motion::Left | Motion::Right => {
                let mut q = p;
                for _ in 0..n {
                    if motion == Motion::Right && t.ch(vt, q) == '\n' {
                        break;
                    }
                    match t.step(vt, q, motion == Motion::Right) {
                        Some((r, c))
                            if c != '\n'
                                || ((operator
                                    || self
                                        .visual
                                        .is_some_and(|v| v.kind == VisualKind::Char))
                                    && motion == Motion::Right) =>
                        {
                            q = r
                        }
                        _ => break,
                    }
                }
                (q, Span::Exclusive)
            }
            Motion::Up | Motion::Down => {
                let y = if motion == Motion::Up {
                    p.y.saturating_sub(n)
                } else {
                    (p.y + n).min(last_row)
                };
                if y == p.y {
                    return None;
                }
                (column(t, y, self.want_x), Span::Lines)
            }
            Motion::LineStart => (Pos::new(0, t.line_start(vt, p.y)), Span::Exclusive),
            Motion::FirstNonBlank => (t.first_non_blank(vt, p.y), Span::Exclusive),
            Motion::LineEnd | Motion::LastNonBlank => {
                let mut y = p.y;
                for _ in 1..n {
                    y = t.line_end(vt, y) + 1;
                    if y > last_row {
                        if t.line_end(vt, p.y) == last_row {
                            self.want_x = if motion == Motion::LineEnd {
                                u16::MAX
                            } else {
                                t.line_last(vt, p.y).x
                            };
                            if self.visual.is_none_or(|v| v.kind != VisualKind::Block) {
                                return None;
                            }
                        }
                        y = last_row;
                        break;
                    }
                }
                (t.line_last(vt, y), Span::Inclusive)
            }
            Motion::NextLine | Motion::PrevLine => {
                let mut y = p.y;
                for _ in 0..n {
                    y = if motion == Motion::NextLine {
                        (t.line_end(vt, y) + 1).min(last_row)
                    } else {
                        let above = t.line_start(vt, y).saturating_sub(1);
                        t.line_start(vt, above)
                    };
                }
                if y == p.y {
                    return None;
                }
                (t.first_non_blank(vt, y), Span::Lines)
            }
            Motion::Top | Motion::Bottom => {
                let y = match count {
                    Some(row) => (row - 1).min(last_row),
                    None if motion == Motion::Top => 0,
                    None => (0..=last_row)
                        .rev()
                        .find(|&y| !t.blank_row(vt, y))
                        .unwrap_or(last_row),
                };
                (column(t, y, self.want_x), Span::Lines)
            }
            Motion::ScreenTop => (
                column(t, view_row(i64::from(n) - 1), self.want_x),
                Span::Lines,
            ),
            Motion::ScreenMiddle => {
                let len = viewport.as_ref().map_or(1, |b| b.len.max(1)) as i64;
                let content = (0..len as u32)
                    .rev()
                    .find(|&i| !t.blank_row(vt, view_row(i64::from(i))))
                    .map_or(len - 1, i64::from);
                (column(t, view_row(content / 2), self.want_x), Span::Lines)
            }
            Motion::ScreenBottom => (column(t, view_row(-i64::from(n)), self.want_x), Span::Lines),
            Motion::Word { big, back, end } => {
                let mut q = p;
                for _ in 0..n {
                    let before = q;
                    // Reaching BOF while traversing the first word completes ge,
                    // even if a larger count was requested. Starting at BOF fails.
                    if back
                        && end
                        && before != Pos::new(0, 0)
                        && !is_blank(t.ch(vt, before))
                        && t.run_end(vt, before, false, big) == Pos::new(0, 0)
                    {
                        q = Pos::new(0, 0);
                        break;
                    }
                    q = match (back, end) {
                        (false, false) => t.word_forward(vt, q, big),
                        (true, false) => t.word_back(vt, q, big),
                        (false, true) => t.word_end(vt, q, big),
                        (true, true) => t.word_end_back(vt, q, big),
                    };
                    if back && end && q == before {
                        if operator {
                            return None;
                        }
                        break;
                    }
                }
                if back && end && q == p {
                    return None;
                }
                // w/W used by an operator stop before the next line on the
                // final repetition, even when its first word is indented.
                if operator && !back && !end && q.y > p.y {
                    let mut before = p;
                    for _ in 1..n {
                        before = t.word_forward(vt, before, big);
                    }
                    let line = t.line_end(vt, before.y);
                    if q.y > line {
                        if t.blank_row(vt, before.y) {
                            return Some((before, Span::Inclusive));
                        }
                        q = Pos::new(t.len(vt, line) as u16, line);
                    }
                }
                (
                    if end { t.clamp(vt, q) } else { q },
                    if end {
                        Span::Inclusive
                    } else {
                        Span::Exclusive
                    },
                )
            }
            Motion::Subword { back, end } => {
                let mut q = p;
                for _ in 0..n {
                    q = t.subword_motion(vt, q, back, end);
                }
                (
                    q,
                    if end {
                        Span::Inclusive
                    } else {
                        Span::Exclusive
                    },
                )
            }
            Motion::Paragraph { forward } => {
                let mut y = p.y;
                for i in 0..n {
                    let (next, edge) = t.paragraph(vt, y, forward);
                    if edge && i + 1 < n {
                        return None;
                    }
                    y = next;
                }
                let at_end = forward && y == last_row && !t.blank_row(vt, y);
                let target = if at_end {
                    t.line_last(vt, y)
                } else {
                    Pos::new(0, y)
                };
                (
                    target,
                    if at_end {
                        Span::Inclusive
                    } else {
                        Span::Exclusive
                    },
                )
            }
            Motion::Bracket => match count {
                Some(percent) => {
                    let y = (u64::from(t.total) * u64::from(percent.min(100)))
                        .div_ceil(100)
                        .saturating_sub(1) as u32;
                    (column(t, y, self.want_x), Span::Lines)
                }
                None => (t.bracket(vt, p)?, Span::Inclusive),
            },
            Motion::Prompt { forward } => {
                let prompts = crate::protocol::prompt_rows(vt);
                let mut y = p.y as usize;
                for _ in 0..n {
                    let next = if forward {
                        prompts.iter().copied().find(|&r| r > y)
                    } else {
                        prompts.iter().rev().copied().find(|&r| r < y)
                    };
                    match next {
                        Some(row) => y = row,
                        None if y == p.y as usize => return None,
                        None => break,
                    }
                }
                (Pos::new(0, y as u32), Span::Lines)
            }
            Motion::Find(find, c) => {
                let target = t.find(vt, p, find, c, n, false)?;
                (
                    target,
                    if find.forward() {
                        Span::Inclusive
                    } else {
                        Span::Exclusive
                    },
                )
            }
            Motion::RepeatFind { reverse } => {
                let (find, c) = self.last_find?;
                let find = if reverse { find.reversed() } else { find };
                let target = self.text.find(vt, p, find, c, n, true)?;
                (
                    target,
                    if find.forward() {
                        Span::Inclusive
                    } else {
                        Span::Exclusive
                    },
                )
            }
            Motion::Match { reverse } => {
                let backward = self.search.as_ref()?.backward != reverse;
                (self.next_match(p, backward, n)?, Span::Exclusive)
            }
        })
    }

    fn scroll(&mut self, vt: &mut Terminal<'_, '_>, scroll: Scroll, count: u32) {
        let Ok(bar) = vt.scrollbar() else {
            return;
        };
        let rows = bar.len.max(1) as i64;
        let max_top = bar.total.saturating_sub(bar.len) as i64;
        let last_row = i64::from(self.text.total) - 1;
        let y = i64::from(self.cursor.y);
        let n = i64::from(count.max(1));
        let (top, cursor) = match scroll {
            Scroll::Line(d) => (bar.offset as i64 + d * n, y),
            Scroll::Half(d) => {
                let delta = d * (rows / 2).max(1);
                (bar.offset as i64 + delta, y + delta)
            }
            Scroll::Page(d) => {
                let delta = d * (rows - 2).max(1) * n;
                let top = (bar.offset as i64 + delta).clamp(0, max_top);
                (top, if d > 0 { top } else { top + rows - 1 })
            }
            Scroll::Center => (y - rows / 2, y),
            Scroll::Top => (y, y),
            Scroll::Bottom => (y - rows + 1, y),
        };
        let top = top.clamp(0, max_top);
        vt.scroll_viewport(ScrollViewport::Row(top as usize));
        let row = cursor.clamp(top, top + rows - 1).clamp(0, last_row) as u32;
        if row != self.cursor.y {
            self.cursor = if self.want_x == u16::MAX {
                self.text.line_last(vt, row)
            } else {
                self.text.clamp(vt, Pos::new(self.want_x, row))
            };
        }
    }

    fn object(
        &mut self,
        vt: &Terminal<'_, '_>,
        kind: char,
        around: bool,
        count: u32,
    ) -> Option<(Pos, Pos, Span)> {
        let mut p = self.cursor;
        let visual = self
            .visual
            .filter(|v| v.anchor != p || v.kind == VisualKind::Line);
        if let Some(v) = visual {
            if matches!(kind, 'w' | 'W') && v.anchor <= p {
                p = self.text.next(vt, p)?.0;
                if !around
                    && self.text.ch(vt, p) == '\n'
                    && p.x > 0
                    && let Some((q, _)) = self.text.next(vt, p)
                {
                    p = q;
                }
            } else if kind == 'p' {
                p.y = p.y.checked_add(1).filter(|&y| y < self.text.total)?;
            }
        }
        let t = &mut self.text;
        if let Some(v) = visual.filter(|v| v.anchor > self.cursor)
            && matches!(kind, 'w' | 'W')
        {
            let big = kind == 'W';
            let mut q = self.cursor;
            for _ in 0..count {
                q = t.prev(vt, q)?.0;
                if q.x > 0 && t.ch(vt, q) == '\n' {
                    q = t.prev(vt, q)?.0;
                }
                let blank = is_blank(t.ch(vt, q));
                if around == blank {
                    q = t.word_back(vt, q, big);
                } else {
                    let start = t.run_end(vt, q, false, big);
                    if start == Pos::new(0, 0) {
                        q = t.next(vt, start)?.0;
                    } else {
                        q = t.prev(vt, start)?.0;
                        while is_blank(t.ch(vt, q)) && q.x > 0 {
                            q = t.prev(vt, q)?.0;
                        }
                        q = t.next(vt, q)?.0;
                    }
                }
            }
            return Some((v.anchor, q, Span::Inclusive));
        }
        let pair = |open, close| (open, close);
        let (a, b) = match kind {
            'w' | 'W' => {
                let range = t.counted_word_object(vt, p, kind == 'W', around, count);
                let (a, mut b) = range.or_else(|| {
                    self.visual?;
                    let (mut a, _) = t.counted_word_object(vt, p, kind == 'W', around, 1)?;
                    if !around && p.x == 0 && t.blank_row(vt, p.y) {
                        a = t.run_end(vt, a, false, kind == 'W');
                    }
                    let y = t.total - 1;
                    Some((a, Pos::new(t.len(vt, y) as u16, y)))
                })?;
                if self.visual.is_none()
                    && !around
                    && count > 1
                    && a.x == 0
                    && b.x == 0
                    && b.y > a.y
                    && b.y + 1 == t.total
                    && t.blank_row(vt, b.y)
                {
                    return Some((a, Pos::new(0, b.y - 1), Span::Lines));
                }
                if (visual.is_some() || (self.visual.is_some() && count > 1)) && t.ch(vt, b) == '\n'
                {
                    while b.y + 1 < t.total && t.blank_row(vt, b.y + 1) {
                        b = Pos::new(0, b.y + 1);
                    }
                }
                (visual.map_or(a, |v| v.anchor.min(a)), b)
            }
            '"' | '\'' | '`' => {
                t.counted_quote_object(vt, p, kind, around, count, visual.map(|v| v.anchor))?
            }
            '(' | ')' | 'b' => t.counted_bracket_object(
                vt,
                p,
                pair('(', ')'),
                around,
                count,
                visual.map(|v| v.anchor),
            )?,
            '[' | ']' => t.counted_bracket_object(
                vt,
                p,
                pair('[', ']'),
                around,
                count,
                visual.map(|v| v.anchor),
            )?,
            '{' | '}' | 'B' => t.counted_bracket_object(
                vt,
                p,
                pair('{', '}'),
                around,
                count,
                visual.map(|v| v.anchor),
            )?,
            '<' | '>' => t.counted_bracket_object(
                vt,
                p,
                pair('<', '>'),
                around,
                count,
                visual.map(|v| v.anchor),
            )?,
            'p' => {
                let (a, mut b) = t.paragraph_object(vt, p.y, around);
                for _ in 1..count {
                    if b + 1 >= t.total {
                        return None;
                    }
                    b = t.paragraph_object(vt, b + 1, around).1;
                }
                let mut a = a;
                if around && b + 1 == t.total && !t.blank_row(vt, p.y) {
                    while a > 0 && t.blank_row(vt, a - 1) {
                        a -= 1;
                    }
                }
                let a = visual.map_or(a, |v| v.anchor.y.min(a));
                return Some((Pos::new(0, a), Pos::new(0, b), Span::Lines));
            }
            'o' => return t.output_object(vt, p.y, around),
            't' => {
                let mut n = count;
                loop {
                    let (a, b) = t.tag_object(vt, p, around, n)?;
                    if self
                        .visual
                        .is_none_or(|v| a < v.anchor.min(p) || b > v.anchor.max(p))
                    {
                        break (a, b);
                    }
                    if !around {
                        let (a, b) = t.tag_object(vt, p, true, n)?;
                        if self
                            .visual
                            .is_none_or(|v| a < v.anchor.min(p) || b > v.anchor.max(p))
                        {
                            break (a, b);
                        }
                    }
                    n += 1;
                }
            }
            _ => return None,
        };
        Some((a, b, Span::Inclusive))
    }

    fn star(&mut self, vt: &mut Terminal<'_, '_>, backward: bool, count: u32) {
        let (cells, index) = self.text.line_cells(vt, self.cursor);
        let Some(&(p, _)) = cells[index..]
            .iter()
            .find(|(_, c)| self.text.keyword.contains(*c))
            .or_else(|| cells[index..].iter().find(|(_, c)| !is_blank(*c)))
        else {
            return;
        };
        let Some((a, b)) = self.text.counted_word_object(vt, p, false, false, 1) else {
            return;
        };
        let word = self.text.chars_between(vt, a, b);
        let keyword = word.chars().all(|c| self.text.keyword.contains(c));
        let Ok(regex) = fancy_regex::Regex::new(&escape(&word)) else {
            return;
        };
        self.search = Some(Search {
            pattern: word,
            matches: self.text.search_keywords(vt, &regex, keyword),
            regex,
            backward,
            whole_keyword: keyword,
        });
        if let Some(target) = self.next_match(a, backward, count) {
            self.cursor = target;
            self.want_x = target.x;
        }
    }

    /// The `count`th match strictly after (or before) `from`, wrapping.
    fn next_match(&self, from: Pos, backward: bool, count: u32) -> Option<Pos> {
        let matches = &self.search.as_ref()?.matches;
        if matches.is_empty() {
            return None;
        }
        let mut at = from;
        for _ in 0..count.max(1) {
            let i = if backward {
                let i = matches.partition_point(|(start, _)| *start < at);
                if i == 0 { matches.len() - 1 } else { i - 1 }
            } else {
                let i = matches.partition_point(|(start, _)| *start <= at);
                if i == matches.len() { 0 } else { i }
            };
            at = matches[i].0;
        }
        Some(at)
    }

    fn prompt_key(&mut self, vt: &mut Terminal<'_, '_>, input: Input) -> Effect {
        if self.prompt.as_ref().is_some_and(|p| p.flash) {
            if let Key::Char(c) = input.key
                && !input.ctrl
                && let Some((target, _, _)) =
                    self.flash_labels.iter().find(|(_, _, label)| *label == c)
            {
                return self.accept_flash(vt, *target);
            }
            if input.key == Key::Enter {
                let target = self
                    .match_at_cursor()
                    .map(|(a, _)| a)
                    .or_else(|| self.next_match(self.cursor, false, 1));
                return target.map_or(Effect::None, |p| self.accept_flash(vt, p));
            }
        }
        let Some(prompt) = self.prompt.as_mut() else {
            return Effect::None;
        };
        match (input.key, input.ctrl) {
            (Key::Escape, _) | (Key::Char('c' | '['), true) => return self.cancel_prompt(vt),
            (Key::Enter, _) => {
                let prompt = self.prompt.take().unwrap_or_else(|| unreachable!());
                if prompt.text.is_empty() {
                    // An empty search repeats the previous one, as in Vim.
                    self.search = prompt.previous;
                    if let Some(search) = self.search.as_mut() {
                        search.backward = prompt.backward;
                    }
                    if let Some(target) = self.next_match(prompt.origin, prompt.backward, 1) {
                        self.cursor = target;
                    }
                } else if self.search.is_none() {
                    self.search = prompt.previous;
                }
                self.want_x = self.cursor.x;
                self.sync(vt);
                return Effect::None;
            }
            (Key::Backspace, _) if prompt.text.is_empty() => return self.cancel_prompt(vt),
            (Key::Backspace, _) => {
                prompt.text.pop();
            }
            (Key::Char('u'), true) => prompt.text.clear(),
            (Key::Char('w'), true) => {
                let trimmed = prompt.text.trim_end().len();
                let start = prompt.text[..trimmed]
                    .rfind(|c: char| c.is_whitespace())
                    .map_or(0, |i| i + 1);
                prompt.text.truncate(start);
            }
            (Key::Up | Key::Down | Key::Tab | Key::F3, _) => {
                let previous = matches!(input.key, Key::Up) || input.shift;
                self.prompt_step(vt, previous);
                return Effect::None;
            }
            (Key::Char(c @ ('n' | 'p')), true) => {
                self.prompt_step(vt, c == 'p');
                return Effect::None;
            }
            (Key::Char(c), false) if !c.is_control() => {
                if prompt.text.len() < 4096 {
                    prompt.text.push(c);
                }
            }
            _ => return Effect::None,
        }
        self.update_prompt(vt);
        Effect::None
    }

    fn cancel_prompt(&mut self, vt: &mut Terminal<'_, '_>) -> Effect {
        self.flash_labels.clear();
        let Some(prompt) = self.prompt.take() else {
            return Effect::None;
        };
        self.search = prompt.previous;
        self.cursor = prompt.origin;
        if let Some(row) = prompt.view {
            vt.scroll_viewport(ScrollViewport::Row(row as usize));
        }
        if prompt.exit_on_cancel {
            return Effect::Exit;
        }
        self.sync(vt);
        Effect::None
    }

    /// Incremental search: match as typed, from where the prompt opened.
    fn update_prompt(&mut self, vt: &mut Terminal<'_, '_>) {
        if self.prompt.as_ref().is_some_and(|p| p.flash) {
            self.update_flash(vt);
            return;
        }
        let Some(prompt) = self.prompt.as_ref() else {
            return;
        };
        let (origin, view, backward) = (prompt.origin, prompt.view, prompt.backward);
        self.search = if prompt.text.is_empty() {
            None
        } else {
            let pattern = prompt.text.clone();
            compile(&pattern).map(|regex| Search {
                matches: self.text.search(vt, &regex),
                pattern,
                regex,
                backward,
                whole_keyword: false,
            })
        };
        if let Some(row) = view {
            vt.scroll_viewport(ScrollViewport::Row(row as usize));
        }
        self.cursor = self.next_match(origin, backward, 1).unwrap_or(origin);
        self.sync(vt);
    }

    fn prompt_step(&mut self, vt: &mut Terminal<'_, '_>, previous: bool) {
        let backward = self.prompt.as_ref().is_some_and(|p| p.backward) != previous;
        if let Some(target) = self.next_match(self.cursor, backward, 1) {
            self.cursor = target;
            self.sync(vt);
        }
    }

    fn yank_visual(&mut self, vt: &mut Terminal<'_, '_>) -> Effect {
        self.sync(vt);
        let text = self.visual.and_then(|v| self.visual_text(vt, v));
        self.leave_visual();
        match text {
            Some(text) => Effect::Copy { text, exit: true },
            None => Effect::None,
        }
    }

    fn yank_range(&mut self, vt: &mut Terminal<'_, '_>, a: Pos, b: Pos, span: Span) -> Effect {
        match self.range_text(vt, a, b, span) {
            Some(text) => Effect::Copy { text, exit: true },
            None => Effect::None,
        }
    }

    /// Select a motion's range as Vim would yank it and return its text.
    fn range_text(
        &mut self,
        vt: &mut Terminal<'_, '_>,
        a: Pos,
        b: Pos,
        span: Span,
    ) -> Option<String> {
        let (mut start, mut end) = (a.min(b), a.max(b));
        let mut span = span;
        if span == Span::Exclusive && end.y > start.y && end.x == 0 {
            // Vim's exclusive-linewise and exclusive-line rules (:h exclusive).
            end.y -= 1;
            if start <= self.text.first_non_blank(vt, start.y) {
                span = Span::Lines;
            } else {
                end = Pos::new(self.text.len(vt, end.y) as u16, end.y);
            }
        }
        match span {
            Span::Lines => {
                start = Pos::new(0, self.text.line_start(vt, start.y));
                end = Pos::new(self.text.cols - 1, self.text.line_end(vt, end.y));
            }
            Span::Exclusive => {
                if start == end {
                    return None;
                }
                end = self.text.step(vt, end, false).map_or(end, |(p, _)| p);
                end = self.text.cell_end(vt, end);
            }
            Span::Inclusive => end = self.text.cell_end(vt, end),
        }
        set_selection(vt, start, end, false);
        Some(
            self.text
                .extract(vt, start, end, false, span == Span::Exclusive),
        )
    }

    fn visual_text(&mut self, vt: &mut Terminal<'_, '_>, visual: Visual) -> Option<String> {
        let (a, b) = (
            visual.anchor.min(self.cursor),
            visual.anchor.max(self.cursor),
        );
        if visual.kind != VisualKind::Block {
            if visual.kind == VisualKind::Line {
                return self.range_text(vt, a, b, Span::Lines);
            }
            let end = self.text.cell_end(vt, b);
            return Some(self.text.extract(vt, a, end, false, true));
        }
        let left = visual.anchor.x.min(self.cursor.x);
        let right = if visual.eol {
            self.text.cols - 1
        } else {
            visual.anchor.x.max(self.cursor.x)
        };
        Some(
            self.text
                .extract(vt, Pos::new(left, a.y), Pos::new(right, b.y), true, false),
        )
    }

    /// Reveal the cursor and mirror the visual selection into the terminal.
    fn sync(&mut self, vt: &mut Terminal<'_, '_>) {
        reveal(vt, self.cursor.y);
        let Some(visual) = self.visual else {
            let _ = vt.set_selection(None);
            return;
        };
        let (a, b) = (
            visual.anchor.min(self.cursor),
            visual.anchor.max(self.cursor),
        );
        match visual.kind {
            VisualKind::Char => {
                let end = self.text.cell_end(vt, b);
                set_selection(vt, a, end, false);
            }
            VisualKind::Line => {
                let start = Pos::new(0, self.text.line_start(vt, a.y));
                let end = Pos::new(self.text.cols - 1, self.text.line_end(vt, b.y));
                set_selection(vt, start, end, false);
            }
            VisualKind::Block => {
                let (left, right) = (
                    visual.anchor.x.min(self.cursor.x),
                    visual.anchor.x.max(self.cursor.x),
                );
                let right = if visual.eol {
                    self.text.cols - 1
                } else {
                    let corner = self.text.cell_end(vt, Pos::new(right, self.cursor.y));
                    let anchor = self.text.cell_end(vt, Pos::new(right, visual.anchor.y));
                    corner.x.max(anchor.x)
                };
                set_selection(vt, Pos::new(left, a.y), Pos::new(right, b.y), true);
            }
        }
    }
}

trait EffectThen {
    fn and(self, next: impl FnOnce() -> Effect) -> Effect;
}

impl EffectThen for Effect {
    fn and(self, next: impl FnOnce() -> Effect) -> Effect {
        match self {
            Effect::None => next(),
            other => other,
        }
    }
}

fn reveal(vt: &mut Terminal<'_, '_>, row: u32) {
    if let Ok(bar) = vt.scrollbar() {
        let row = u64::from(row);
        if row < bar.offset {
            vt.scroll_viewport(ScrollViewport::Row(row as usize));
        } else if row >= bar.offset + bar.len {
            vt.scroll_viewport(ScrollViewport::Row(
                (row + 1).saturating_sub(bar.len) as usize
            ));
        }
    }
}

fn point(p: Pos) -> Point {
    Point::Screen(PointCoordinate { x: p.x, y: p.y })
}

fn set_selection(vt: &Terminal<'_, '_>, a: Pos, b: Pos, rectangle: bool) {
    // The internal newline slot may be just beyond the physical grid.
    let last = vt.cols().unwrap_or(1).saturating_sub(1);
    let a = Pos::new(a.x.min(last), a.y);
    let b = Pos::new(b.x.min(last), b.y);
    if let (Ok(a), Ok(b)) = (vt.grid_ref(point(a)), vt.grid_ref(point(b))) {
        let _ = vt.set_selection(Some(&Selection::new(a, b, rectangle)));
    }
}

fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if "\\.^$|?*+()[]{}#-&~ ".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

fn literal(query: &str, insensitive: bool) -> String {
    format!("{}{}", if insensitive { "(?i)" } else { "" }, escape(query))
}

fn literal_regex(query: &str, insensitive: bool) -> Option<fancy_regex::Regex> {
    fancy_regex::Regex::new(&literal(query, insensitive)).ok()
}

use vim_regex::compile;

fn is_blank(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | SPACER | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200b}' | '\u{2028}'..='\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}')
}

/// Vim's character classes: blank, punctuation, keyword. WORDs only split on blanks.
fn class(c: char, big: bool, keyword: &IsKeyword) -> u32 {
    if is_blank(c) {
        0
    } else if big {
        2
    } else {
        keyword.class(c)
    }
}

struct RowText {
    /// One character per cell; trailing blanks trimmed unless soft-wrapped.
    cells: Vec<char>,
    wrapped: bool,
    /// Cells holding more than one codepoint (combining marks, ZWJ sequences).
    clusters: Vec<(u16, String)>,
}

/// Rows read lazily from the frozen screen. Text runs through soft wraps; a
/// row without one ends in a newline slot one cell past its last character.
struct Text {
    cols: u16,
    total: u32,
    rows: HashMap<u32, RowText>,
    keyword: IsKeyword,
    subwords: HashMap<u32, Vec<words::Token>>,
}

impl Text {
    fn new(vt: &Terminal<'_, '_>) -> Self {
        Self {
            cols: vt.cols().unwrap_or(1).max(1),
            total: vt.total_rows().unwrap_or(1).max(1) as u32,
            rows: HashMap::new(),
            keyword: IsKeyword::default(),
            subwords: HashMap::new(),
        }
    }

    fn row(&mut self, vt: &Terminal<'_, '_>, y: u32) -> &RowText {
        let cols = self.cols;
        self.rows.entry(y).or_insert_with(|| read_row(vt, y, cols))
    }

    fn cached_char(&self, p: Pos) -> Option<char> {
        self.rows.get(&p.y)?.cells.get(p.x as usize).copied()
    }

    fn len(&mut self, vt: &Terminal<'_, '_>, y: u32) -> usize {
        self.row(vt, y).cells.len()
    }

    fn wrapped(&mut self, vt: &Terminal<'_, '_>, y: u32) -> bool {
        self.row(vt, y).wrapped
    }

    fn blank_row(&mut self, vt: &Terminal<'_, '_>, y: u32) -> bool {
        let row = self.row(vt, y);
        !row.wrapped && row.cells.iter().all(|c| is_blank(*c))
    }

    fn ch(&mut self, vt: &Terminal<'_, '_>, p: Pos) -> char {
        let row = self.row(vt, p.y);
        match row.cells.get(p.x as usize) {
            Some(c) => *c,
            None if p.x as usize == row.cells.len() && !row.wrapped => '\n',
            None => ' ',
        }
    }

    fn line_start(&mut self, vt: &Terminal<'_, '_>, mut y: u32) -> u32 {
        while y > 0 && self.wrapped(vt, y - 1) {
            y -= 1;
        }
        y
    }

    fn line_end(&mut self, vt: &Terminal<'_, '_>, mut y: u32) -> u32 {
        while y + 1 < self.total && self.wrapped(vt, y) {
            y += 1;
        }
        y
    }

    /// A character cell on row `p.y`: never past its text nor on a spacer.
    fn clamp(&mut self, vt: &Terminal<'_, '_>, p: Pos) -> Pos {
        let y = p.y.min(self.total - 1);
        let row = self.row(vt, y);
        if row.cells.is_empty() {
            return Pos::new(0, y);
        }
        let mut x = (p.x as usize).min(row.cells.len() - 1);
        while x > 0 && row.cells[x] == SPACER {
            x -= 1;
        }
        Pos::new(x as u16, y)
    }

    /// The final cell of the glyph at `p`, including a wide glyph's spacer.
    fn cell_end(&mut self, vt: &Terminal<'_, '_>, p: Pos) -> Pos {
        let next = Pos::new(p.x.saturating_add(1), p.y);
        if next.x < self.cols && self.ch(vt, next) == SPACER {
            next
        } else {
            p
        }
    }

    /// The last character of the logical line through row `y`.
    fn line_last(&mut self, vt: &Terminal<'_, '_>, y: u32) -> Pos {
        let end = self.line_end(vt, y);
        let len = self.len(vt, end) as u16;
        self.clamp(vt, Pos::new(len.saturating_sub(1), end))
    }

    fn first_non_blank(&mut self, vt: &Terminal<'_, '_>, y: u32) -> Pos {
        let start = Pos::new(0, self.line_start(vt, y));
        let c = self.ch(vt, start);
        if !is_blank(c) || c == '\n' {
            return start;
        }
        let mut p = start;
        while let Some((q, c)) = self.next(vt, p) {
            if c == '\n' {
                return self.clamp(vt, start);
            }
            p = q;
            if !is_blank(c) {
                return q;
            }
        }
        start
    }

    fn step(&mut self, vt: &Terminal<'_, '_>, p: Pos, forward: bool) -> Option<(Pos, char)> {
        if forward {
            self.next(vt, p)
        } else {
            self.prev(vt, p)
        }
    }

    fn next(&mut self, vt: &Terminal<'_, '_>, p: Pos) -> Option<(Pos, char)> {
        let (mut x, mut y) = (p.x as usize + 1, p.y);
        loop {
            let row = self.row(vt, y);
            let len = row.cells.len();
            if x < len {
                if row.cells[x] == SPACER {
                    x += 1;
                    continue;
                }
                return Some((Pos::new(x as u16, y), row.cells[x]));
            }
            if x == len && !row.wrapped {
                return Some((Pos::new(len as u16, y), '\n'));
            }
            y += 1;
            if y >= self.total {
                return None;
            }
            x = 0;
        }
    }

    fn prev(&mut self, vt: &Terminal<'_, '_>, p: Pos) -> Option<(Pos, char)> {
        let (mut x, mut y) = (p.x as isize - 1, p.y);
        loop {
            let row = self.row(vt, y);
            let len = row.cells.len() as isize;
            x = x.min(len);
            if x >= 0 {
                if x == len {
                    if !row.wrapped {
                        return Some((Pos::new(len as u16, y), '\n'));
                    }
                } else if row.cells[x as usize] != SPACER {
                    return Some((Pos::new(x as u16, y), row.cells[x as usize]));
                }
                x -= 1;
                continue;
            }
            if y == 0 {
                return None;
            }
            y -= 1;
            x = isize::MAX;
        }
    }

    /// Move while the next cell stays in `p`'s class; returns the run's last cell.
    fn run_end(&mut self, vt: &Terminal<'_, '_>, mut p: Pos, forward: bool, big: bool) -> Pos {
        let c = self.ch(vt, p);
        if c == '\n' {
            return p;
        }
        let k = class(c, big, &self.keyword);
        while let Some((q, c)) = self.step(vt, p, forward) {
            if c == '\n' || class(c, big, &self.keyword) != k {
                break;
            }
            p = q;
        }
        p
    }

    fn word_forward(&mut self, vt: &Terminal<'_, '_>, p: Pos, big: bool) -> Pos {
        let mut last = p;
        if !is_blank(self.ch(vt, p)) {
            last = self.run_end(vt, p, true, big);
        }
        // Skip blanks and line ends; an empty line counts as a word.
        while let Some((q, c)) = self.next(vt, last) {
            last = q;
            if c == '\n' {
                if q.x == 0 {
                    return q;
                }
            } else if !is_blank(c) {
                return q;
            }
        }
        last
    }

    fn word_back(&mut self, vt: &Terminal<'_, '_>, p: Pos, big: bool) -> Pos {
        let mut p = p;
        loop {
            let Some((q, c)) = self.prev(vt, p) else {
                return p;
            };
            p = q;
            if c == '\n' {
                if q.x == 0 {
                    return q;
                }
            } else if !is_blank(c) {
                break;
            }
        }
        self.run_end(vt, p, false, big)
    }

    fn word_end(&mut self, vt: &Terminal<'_, '_>, p: Pos, big: bool) -> Pos {
        let mut p = p;
        loop {
            let Some((q, c)) = self.next(vt, p) else {
                return p;
            };
            p = q;
            if !is_blank(c) {
                break;
            }
        }
        self.run_end(vt, p, true, big)
    }

    fn word_end_back(&mut self, vt: &Terminal<'_, '_>, p: Pos, big: bool) -> Pos {
        let mut p = p;
        if !is_blank(self.ch(vt, p)) {
            p = self.run_end(vt, p, false, big);
        }
        loop {
            let Some((q, c)) = self.prev(vt, p) else {
                return p;
            };
            p = q;
            if c == '\n' {
                if q.x == 0 {
                    return q;
                }
            } else if !is_blank(c) {
                return q;
            }
        }
    }

    /// `f`/`t`/`F`/`T` within the logical line, `count` times.
    fn find(
        &mut self,
        vt: &Terminal<'_, '_>,
        p: Pos,
        find: Find,
        target: char,
        count: u32,
        repeat: bool,
    ) -> Option<Pos> {
        let forward = find.forward();
        if self.ch(vt, p) == '\n' {
            return None;
        }
        let mut at = p;
        // A repeated till skips the match it stopped against.
        if repeat
            && count == 1
            && find.till()
            && let Some((q, c)) = self.step(vt, at, forward)
            && words::find_matches(target, c)
        {
            at = q;
        }
        for _ in 0..count {
            loop {
                let (q, c) = self.step(vt, at, forward)?;
                if c == '\n' {
                    return None;
                }
                at = q;
                if words::find_matches(target, c) {
                    break;
                }
            }
        }
        if find.till() {
            return self.step(vt, at, !forward).map(|(q, _)| q);
        }
        Some(at)
    }

    fn paragraph(&mut self, vt: &Terminal<'_, '_>, mut y: u32, forward: bool) -> (u32, bool) {
        let mut first = true;
        let mut content = false;
        loop {
            let blank = self.blank_row(vt, y);
            content |= !blank;
            if !first && content && blank {
                return (y, false);
            }
            if (forward && y + 1 == self.total) || (!forward && y == 0) {
                return (y, true);
            }
            y = if forward { y + 1 } else { y - 1 };
            first = false;
        }
    }

    fn bracket(&mut self, vt: &Terminal<'_, '_>, p: Pos) -> Option<Pos> {
        let mut at = p;
        let mut c = self.ch(vt, at);
        if c == '\n' {
            return None;
        }
        while !"()[]{}".contains(c) || c == '\n' {
            let (q, d) = self.next(vt, at)?;
            if d == '\n' {
                return None;
            }
            (at, c) = (q, d);
        }
        let (open, close, forward) = match c {
            '(' => ('(', ')', true),
            ')' => ('(', ')', false),
            '[' => ('[', ']', true),
            ']' => ('[', ']', false),
            '{' => ('{', '}', true),
            _ => ('{', '}', false),
        };
        let (deeper, shallower) = if forward {
            (open, close)
        } else {
            (close, open)
        };
        let mut depth = 0usize;
        for _ in 0..SCAN_LIMIT {
            let (q, d) = self.step(vt, at, forward)?;
            at = q;
            if d == deeper {
                depth += 1;
            } else if d == shallower {
                if depth == 0 {
                    return Some(at);
                }
                depth -= 1;
            }
        }
        None
    }

    fn counted_word_object(
        &mut self,
        vt: &Terminal<'_, '_>,
        p: Pos,
        big: bool,
        around: bool,
        count: u32,
    ) -> Option<(Pos, Pos)> {
        let mut a = self.run_end(vt, p, false, big);
        let mut b = self.run_end(vt, p, true, big);
        if !around {
            if self.ch(vt, p) == '\n' && count == 1 {
                if p.x == 0 && p.y + 1 == self.total && p.y > 0 {
                    let before = self.line_last(vt, p.y - 1);
                    return Some((before, p));
                }
                return Some((p, p));
            }
            for _ in 1..count {
                b = self.next(vt, b)?.0;
                if self.ch(vt, b) == '\n' && b.x > 0 {
                    // A line break joins the next run, except an empty line.
                    b = self.next(vt, b)?.0;
                }
                b = self.run_end(vt, b, true, big);
            }
            return Some((a, b));
        }
        let started_blank = is_blank(self.ch(vt, p));
        let mut trailing_allowed = !started_blank;
        let mut trailing = false;
        let mut q = p;
        for i in 0..count {
            if i > 0 {
                if q.x > 0 && self.ch(vt, q) == '\n' {
                    q = self.next(vt, q)?.0;
                }
                trailing_allowed = !is_blank(self.ch(vt, q));
            }
            if i > 0 || is_blank(self.ch(vt, q)) {
                loop {
                    if !is_blank(self.ch(vt, q)) {
                        break;
                    }
                    let empty = q.x == 0 && self.ch(vt, q) == '\n';
                    q = self.next(vt, q)?.0;
                    if empty && q.x == 0 && self.ch(vt, q) == '\n' {
                        break;
                    }
                }
            }
            b = self.run_end(vt, q, true, big);
            trailing = false;
            while let Some((q, c)) = self.next(vt, b) {
                if !trailing_allowed || !is_blank(c) || c == '\n' {
                    break;
                }
                trailing = true;
                b = q;
            }
            if i + 1 < count {
                q = self.next(vt, b)?.0;
            }
        }
        if !started_blank && !trailing {
            let mut lead = a;
            while let Some((q, c)) = self.prev(vt, lead) {
                if !is_blank(c) || c == '\n' {
                    break;
                }
                lead = q;
            }
            // Indentation is not the whitespace of a preceding word.
            if self.prev(vt, lead).is_some_and(|(_, c)| c != '\n') {
                a = lead;
            }
        }
        Some((a, b))
    }

    /// The logical line around `p` as `(cell, char)` pairs, with `p`'s index.
    fn line_cells(&mut self, vt: &Terminal<'_, '_>, p: Pos) -> (Vec<(Pos, char)>, usize) {
        let first = self.line_start(vt, p.y);
        let last = self.line_end(vt, p.y);
        let mut cells = Vec::new();
        for y in first..=last {
            let row = self.row(vt, y);
            for (x, c) in row.cells.iter().enumerate() {
                if *c != SPACER {
                    cells.push((Pos::new(x as u16, y), *c));
                }
            }
        }
        let index = cells
            .partition_point(|(q, _)| *q < p)
            .min(cells.len().saturating_sub(1));
        (cells, index)
    }

    fn counted_quote_object(
        &mut self,
        vt: &Terminal<'_, '_>,
        p: Pos,
        quote: char,
        around: bool,
        count: u32,
        anchor: Option<Pos>,
    ) -> Option<(Pos, Pos)> {
        if let Some(anchor) = anchor
            && !around
        {
            let next = self.next(vt, p)?.0;
            let (mut a, b) = self.counted_quote_object(vt, next, quote, false, 2, None)?;
            // Vim keeps an existing anchor when it already contains a quote,
            // including escaped quotes inside the selected string.
            if self
                .chars_between(vt, anchor.min(p), anchor.max(p))
                .contains(quote)
            {
                a = anchor.min(p);
            }
            return Some((a, b));
        }
        let (cells, index) = self.line_cells(vt, p);
        let mut escaped = false;
        let mut quotes = Vec::new();
        for (i, (_, c)) in cells.iter().enumerate() {
            if *c == quote && !escaped {
                quotes.push(i);
            }
            escaped = *c == '\\' && !escaped;
        }
        let (mut a, mut b) = if let Some(anchor) = anchor {
            let a = cells.partition_point(|(q, _)| *q < anchor.min(p));
            let k = quotes.partition_point(|&i| i <= index);
            let b = if cells[index].1 == quote {
                *quotes.get(k + 1).or_else(|| quotes.get(k))?
            } else {
                *quotes.get(if k % 2 == 0 { k + 1 } else { k })?
            };
            (a, b)
        } else if let Some(k) = quotes.iter().position(|&i| i == index) {
            if k % 2 == 0 {
                (index, *quotes.get(k + 1)?)
            } else {
                (quotes[k - 1], index)
            }
        } else {
            let k = quotes.partition_point(|&i| i < index);
            if k == 0 {
                (*quotes.first()?, *quotes.get(1)?)
            } else {
                (quotes[k - 1], *quotes.get(k)?)
            }
        };
        if around {
            let end = b;
            while b + 1 < cells.len() && is_blank(cells[b + 1].1) {
                b += 1;
            }
            if b == end {
                while a > 0 && is_blank(cells[a - 1].1) {
                    a -= 1;
                }
            }
        } else if count < 2 && anchor.is_none() {
            a += 1;
            b = b.checked_sub(1)?;
        }
        (a <= b).then(|| (cells[a].0, cells[b].0))
    }

    fn counted_bracket_object(
        &mut self,
        vt: &Terminal<'_, '_>,
        p: Pos,
        (open, close): (char, char),
        around: bool,
        count: u32,
        anchor: Option<Pos>,
    ) -> Option<(Pos, Pos)> {
        let scan = |t: &mut Text, from: Pos, forward: bool| -> Option<Pos> {
            let (deeper, target) = if forward {
                (open, close)
            } else {
                (close, open)
            };
            let mut depth = 0usize;
            let mut at = from;
            for _ in 0..SCAN_LIMIT {
                let (q, c) = t.step(vt, at, forward)?;
                at = q;
                if c == deeper {
                    depth += 1;
                } else if c == target {
                    if depth == 0 {
                        return Some(at);
                    }
                    depth -= 1;
                }
            }
            None
        };
        if around && let Some(anchor) = anchor {
            let first = anchor.min(p);
            if self.ch(vt, first) == open {
                if let Some(parent) = scan(self, first, false) {
                    return self.counted_bracket_object(
                        vt,
                        parent,
                        (open, close),
                        true,
                        count,
                        None,
                    );
                }
                let mut at = first;
                let mut depth = 1u32;
                for _ in 0..SCAN_LIMIT {
                    let (q, c) = self.next(vt, at)?;
                    if c == open {
                        depth += 1;
                        if depth == count + 1 {
                            return self.counted_bracket_object(
                                vt,
                                q,
                                (open, close),
                                true,
                                1,
                                None,
                            );
                        }
                    } else if c == close {
                        depth = depth.saturating_sub(1);
                    }
                    at = q;
                }
                return None;
            }
        }
        let mut start = if self.ch(vt, p) == open {
            Some(p)
        } else {
            scan(self, p, false)
        };
        let forward = start.is_none();
        if forward {
            let mut at = p;
            let mut depth = 0;
            for _ in 0..SCAN_LIMIT {
                let (q, c) = self.next(vt, at)?;
                at = q;
                if c == open {
                    depth += 1;
                    if depth == count {
                        start = Some(q);
                        break;
                    }
                } else if c == close {
                    depth = depth.saturating_sub(1);
                }
            }
        }
        let mut start = start?;
        if !forward {
            for _ in 1..count {
                start = scan(self, start, false)?;
            }
        }
        loop {
            let end = scan(self, start, true)?;
            let range = if around {
                Some((start, end))
            } else {
                let (mut a, c) = self.next(vt, start)?;
                if c == '\n' {
                    a = self.next(vt, a)?.0;
                }
                let mut b = self.prev(vt, end)?.0;
                if end.x == 0 {
                    b = self.prev(vt, b)?.0;
                }
                (a <= b && a < end).then_some((a, b))
            };
            if let Some((a, b)) = range
                && anchor.is_none_or(|v| a < v.min(p) || b > v.max(p))
            {
                return Some((a, b));
            }
            start = scan(self, start, false)?;
        }
    }

    fn paragraph_object(&mut self, vt: &Terminal<'_, '_>, y: u32, around: bool) -> (u32, u32) {
        let blank = self.blank_row(vt, y);
        let mut a = y;
        while a > 0 && self.blank_row(vt, a - 1) == blank {
            a -= 1;
        }
        let mut b = y;
        while b + 1 < self.total && self.blank_row(vt, b + 1) == blank {
            b += 1;
        }
        if around {
            if b + 1 == self.total && !blank {
                while a > 0 && self.blank_row(vt, a - 1) {
                    a -= 1;
                }
            } else {
                while b + 1 < self.total && self.blank_row(vt, b + 1) != blank {
                    b += 1;
                }
            }
        }
        (a, b)
    }

    /// A command's output (OSC 133): `io` is the output text, `ao` the whole
    /// block from its prompt.
    fn output_object(
        &mut self,
        vt: &Terminal<'_, '_>,
        y: u32,
        around: bool,
    ) -> Option<(Pos, Pos, Span)> {
        let prompts = crate::protocol::prompt_rows(vt);
        let first = *prompts.iter().rev().find(|&&r| r as u32 <= y)? as u32;
        let next = prompts.iter().find(|&&r| r as u32 > y).map(|&r| r as u32);
        let mut last = next.map_or(self.total - 1, |r| r - 1);
        while last > first && self.blank_row(vt, last) {
            last -= 1;
        }
        if around {
            return Some((Pos::new(0, first), Pos::new(0, last), Span::Lines));
        }
        let mut found: Option<(Pos, Pos)> = None;
        for row in first..=last {
            for x in 0..self.len(vt, row) as u16 {
                let output = vt
                    .grid_ref(point(Pos::new(x, row)))
                    .and_then(|r| r.cell())
                    .is_ok_and(|c| {
                        c.semantic_content().ok() == Some(CellSemanticContent::Output)
                            && c.has_text().unwrap_or(false)
                    });
                if output {
                    let at = Pos::new(x, row);
                    found = Some(found.map_or((at, at), |(a, _)| (a, at)));
                }
            }
        }
        let (a, b) = found?;
        Some((a, self.cell_end(vt, b), Span::Inclusive))
    }

    /// Copy from the frozen cells, preserving selected empty rows and clusters.
    /// A characterwise newline slot is meaningful even on the final row.
    fn extract(
        &mut self,
        vt: &Terminal<'_, '_>,
        a: Pos,
        b: Pos,
        block: bool,
        newline: bool,
    ) -> String {
        let mut out = String::new();
        let total = self.total;
        for y in a.y..=b.y {
            let row = self.row(vt, y);
            let left = if block || y == a.y { a.x as usize } else { 0 };
            let right = if block || y == b.y {
                b.x as usize + 1
            } else {
                row.cells.len()
            };
            let offset = out.len();
            for x in left..right.min(row.cells.len()) {
                if row.cells[x] == SPACER {
                    continue;
                }
                if let Some((_, cluster)) = row.clusters.iter().find(|(cx, _)| *cx as usize == x) {
                    out.push_str(cluster);
                } else {
                    out.push(row.cells[x]);
                }
            }
            if !row.wrapped || block {
                while out.len() > offset && out.ends_with(' ') {
                    out.pop();
                }
                if y < b.y || (!block && newline && y + 1 < total && right > row.cells.len()) {
                    out.push('\n');
                }
            }
        }
        out
    }

    fn chars_between(&mut self, vt: &Terminal<'_, '_>, a: Pos, b: Pos) -> String {
        let mut out = String::new();
        let mut p = a;
        loop {
            let c = self.ch(vt, p);
            if let Some((_, cluster)) = self.row(vt, p.y).clusters.iter().find(|(x, _)| *x == p.x) {
                out.push_str(cluster);
            } else {
                out.push(c);
            }
            let Some((q, _)) = self.next(vt, p).filter(|(q, _)| *q <= b) else {
                break;
            };
            p = q;
        }
        out
    }

    /// Every match of `regex` on every logical line, in order.
    fn search(&mut self, vt: &Terminal<'_, '_>, regex: &fancy_regex::Regex) -> Vec<(Pos, Pos)> {
        self.search_rows(vt, regex, 0, self.total, false)
    }

    fn search_keywords(
        &mut self,
        vt: &Terminal<'_, '_>,
        regex: &fancy_regex::Regex,
        whole: bool,
    ) -> Vec<(Pos, Pos)> {
        let mut matches = self.search(vt, regex);
        if whole {
            matches.retain(|(a, b)| {
                let before = self
                    .prev(vt, *a)
                    .is_some_and(|(_, c)| self.keyword.contains(c));
                let after = self
                    .next(vt, *b)
                    .is_some_and(|(_, c)| self.keyword.contains(c));
                !before && !after
            });
        }
        matches
    }

    fn search_rows(
        &mut self,
        vt: &Terminal<'_, '_>,
        regex: &fancy_regex::Regex,
        first: u32,
        bottom: u32,
        overlapping: bool,
    ) -> Vec<(Pos, Pos)> {
        let mut out = Vec::new();
        let mut text = String::new();
        let mut map: Vec<(usize, Pos)> = Vec::new();
        let mut y = first;
        let bottom = bottom.min(self.total);
        while y < bottom {
            text.clear();
            map.clear();
            loop {
                let row = self.row(vt, y);
                for (x, c) in row.cells.iter().enumerate() {
                    if *c == SPACER {
                        continue;
                    }
                    map.push((text.len(), Pos::new(x as u16, y)));
                    match row.clusters.iter().find(|(cx, _)| *cx as usize == x) {
                        Some((_, cluster)) => text.push_str(cluster),
                        None => text.push(*c),
                    }
                }
                let wrapped = row.wrapped;
                y += 1;
                if !wrapped || y >= bottom {
                    break;
                }
            }
            let mut offset = 0;
            while offset < text.len() {
                let Ok(Some(found)) = regex.find_from_pos(&text, offset) else {
                    break;
                };
                offset = if overlapping || found.start() == found.end() {
                    found.start()
                        + text[found.start()..]
                            .chars()
                            .next()
                            .map_or(1, char::len_utf8)
                } else {
                    found.end()
                };
                if found.start() == found.end() {
                    continue;
                }
                let at = |offset: usize| map[map.partition_point(|(b, _)| *b <= offset) - 1].1;
                let (start, end) = (at(found.start()), at(found.end() - 1));
                let end = self.cell_end(vt, end);
                out.push((start, end));
                if out.len() >= MAX_MATCHES {
                    return out;
                }
            }
        }
        out
    }
}

fn read_row(vt: &Terminal<'_, '_>, y: u32, cols: u16) -> RowText {
    let at = |x| vt.grid_ref(point(Pos::new(x, y)));
    let mut row = RowText {
        cells: Vec::with_capacity(cols as usize),
        wrapped: false,
        clusters: Vec::new(),
    };
    let flags = at(0).and_then(|r| r.row());
    row.wrapped = flags
        .as_ref()
        .is_ok_and(|r| r.is_wrapped().unwrap_or(false));
    let clusters = flags.is_ok_and(|r| r.has_grapheme_cluster().unwrap_or(false));
    let mut buf = vec!['\0'; 8];
    for x in 0..cols {
        let Ok(r) = at(x) else {
            break;
        };
        let Ok(cell) = r.cell() else {
            break;
        };
        let c = match cell.wide() {
            Ok(CellWide::SpacerTail | CellWide::SpacerHead) => SPACER,
            _ if !cell.has_text().unwrap_or(false) => ' ',
            _ => {
                if clusters {
                    let n = match r.graphemes(&mut buf) {
                        Err(libghostty_vt::Error::OutOfSpace { required }) => {
                            buf.resize(required, '\0');
                            r.graphemes(&mut buf).unwrap_or(0)
                        }
                        other => other.unwrap_or(0),
                    };
                    if n > 1 {
                        row.clusters.push((x, buf[..n].iter().collect()));
                    }
                }
                cell.codepoint()
                    .ok()
                    .and_then(char::from_u32)
                    .unwrap_or(' ')
            }
        };
        row.cells.push(c);
    }
    if !row.wrapped {
        while row.cells.last() == Some(&' ') {
            row.cells.pop();
        }
    }
    row
}

#[cfg(test)]
mod nvim_tests;

#[cfg(test)]
mod tests {
    use super::*;

    pub(super) fn terminal(cols: u16, rows: u16, text: &str) -> Terminal<'static, 'static> {
        let mut vt = crate::new_vt(cols, rows, 100_000).unwrap();
        vt.vt_write(text.as_bytes());
        vt
    }

    /// Keys in Vim notation: `<C-v>`, `<Esc>`, `<CR>`, `<BS>`, `<Up>`.
    fn press(mode: &mut CopyMode, vt: &mut Terminal<'_, '_>, keys: &str) -> Vec<Effect> {
        let mut out = Vec::new();
        let mut rest = keys;
        while let Some(c) = rest.chars().next() {
            let input = if c == '<' && rest.contains('>') {
                let end = rest.find('>').unwrap();
                let name = &rest[1..end];
                rest = &rest[end + 1..];
                match name {
                    "Esc" => Input::key(Key::Escape),
                    "CR" => Input::key(Key::Enter),
                    "BS" => Input::key(Key::Backspace),
                    "Up" => Input::key(Key::Up),
                    "Down" => Input::key(Key::Down),
                    "lt" => Input::char('<'),
                    ctrl if ctrl.starts_with("C-") => Input::ctrl(ctrl.chars().nth(2).unwrap()),
                    other => panic!("unknown key {other}"),
                }
            } else {
                rest = &rest[c.len_utf8()..];
                Input::char(c)
            };
            out.push(mode.key(vt, input));
        }
        out
    }

    fn copied(effects: Vec<Effect>) -> Option<String> {
        effects.into_iter().find_map(|e| match e {
            Effect::Copy { text, .. } => Some(text),
            _ => None,
        })
    }

    fn at(mode: &CopyMode) -> (u16, u32) {
        (mode.cursor.x, mode.cursor.y)
    }

    const PROSE: &str = "foo bar.baz  qux\r\n\r\n  indented line\r\nlast";

    #[test]
    fn iskeyword_replacement_exclusion_and_star_use_the_same_rules() {
        let mut vt = terminal(60, 4, "abc_12 abc abc-def abc");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        m.set_iskeyword(IsKeyword::parse("a-z").unwrap());
        assert_eq!(
            copied(press(&mut m, &mut vt, "yiw")).as_deref(),
            Some("abc")
        );
        press(&mut m, &mut vt, "*");
        assert_eq!(m.search.as_ref().unwrap().matches.len(), 4);
        m.set_iskeyword(IsKeyword::parse("@,48-57,_,192-255,-,^_").unwrap());
        press(&mut m, &mut vt, "0*");
        assert_eq!(
            m.search.as_ref().unwrap().matches.len(),
            3,
            "hyphen extends a keyword but excluded underscore does not"
        );
        m.refresh(&mut vt);
        assert_eq!(
            m.search.as_ref().unwrap().matches.len(),
            3,
            "refresh preserves keyword search boundaries"
        );
        press(&mut m, &mut vt, "0w");
        assert_eq!(at(&m), (3, 0));
        press(&mut m, &mut vt, "w");
        assert_eq!(at(&m), (4, 0));
        m.set_iskeyword(IsKeyword::parse("").unwrap());
        press(&mut m, &mut vt, "0 w");
        assert_eq!(
            at(&m),
            (4, 0),
            "Space motions ignore iskeyword replacements"
        );
    }

    #[test]
    fn visual_surround_copies_and_exits_with_standard_delimiters() {
        for (delimiter, expected) in [
            ('"', "\"한글\""),
            ('\'', "'한글'"),
            ('`', "`한글`"),
            (')', "(한글)"),
            ('(', "( 한글 )"),
            ('b', "(한글)"),
            (']', "[한글]"),
            ('[', "[ 한글 ]"),
            ('r', "[한글]"),
            ('}', "{한글}"),
            ('{', "{ 한글 }"),
            ('B', "{한글}"),
            ('>', "<한글>"),
            ('a', "<한글>"),
            ('/', "/한글/"),
            ('*', "*한글*"),
        ] {
            let mut vt = terminal(30, 4, "한글 text");
            let mut m = CopyMode::new(&mut vt, (0, 0));
            press(&mut m, &mut vt, "viwS");
            assert_eq!(
                m.key(&mut vt, Input::char(delimiter)),
                Effect::Copy {
                    text: expected.into(),
                    exit: true
                }
            );
        }
    }

    #[test]
    fn surround_preserves_selection_on_cancel_and_handles_multiline_and_blocks() {
        let mut vt = terminal(30, 4, "foo bar\r\nbaz qux");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert!(
            copied(press(&mut m, &mut vt, "S\"")).is_none(),
            "S is visual only"
        );
        press(&mut m, &mut vt, "viwS<Esc>");
        assert!(m.visual.is_some());
        assert_eq!(copied(press(&mut m, &mut vt, "y")).as_deref(), Some("foo"));
        press(&mut m, &mut vt, "0VjS");
        assert_eq!(
            copied(press(&mut m, &mut vt, "\"")).as_deref(),
            Some("\"\n  foo bar\n  baz qux\n\""),
            "linewise: delimiters on lines of their own, text indented"
        );
        press(&mut m, &mut vt, "gg<C-v>jlS");
        assert_eq!(
            copied(press(&mut m, &mut vt, "]")).as_deref(),
            Some("[fo]\n[ba]"),
            "blockwise: every row is surrounded"
        );
        press(&mut m, &mut vt, "ggviwSx");
        assert!(
            m.visual.is_some(),
            "unsupported delimiters leave the selection intact"
        );
    }

    #[test]
    fn vim_surround_readme_walkthrough_copies_each_step() {
        // github.com/tpope/vim-surround, one copy per step on a read-only screen.
        let steps = [
            ("\"Hello world!\"", (3, 0), "cs\"'", "'Hello world!'"),
            ("'Hello world!'", (3, 0), "cs'<lt>q>", "<q>Hello world!</q>"),
            ("<q>Hello world!</q>", (5, 0), "cst\"", "\"Hello world!\""),
            ("\"Hello world!\"", (3, 0), "ds\"", "Hello world!"),
            ("Hello world!", (1, 0), "ySiw]", "[Hello]"),
            ("[Hello] world!", (2, 0), "cs]{", "{ Hello }"),
            ("{ Hello } world!", (2, 0), "ySSb", "({ Hello } world!)"),
            ("{ Hello } world!", (2, 0), "ySs)", "({ Hello } world!)"),
            ("({ Hello } world!)", (3, 0), "ds{", "Hello"),
            ("Hello world!", (1, 0), "ySiw<lt>em>", "<em>Hello</em>"),
            (
                "<em>Hello</em> world!",
                (0, 0),
                "VS<lt>p class=\"important\">",
                "<p class=\"important\">\n  <em>Hello</em> world!\n</p>",
            ),
        ];
        for (text, cursor, keys, expected) in steps {
            let mut vt = terminal(60, 4, text);
            let mut m = CopyMode::new(&mut vt, cursor);
            assert_eq!(
                copied(press(&mut m, &mut vt, keys)).as_deref(),
                Some(expected),
                "{keys} on {text}"
            );
        }
    }

    #[test]
    fn surround_targets_replacements_and_layouts() {
        let mut vt = terminal(
            60,
            6,
            "(123+4*56)/2  ( spaced )\r\n<div class=\"x\">Yo!</div>\r\n  foo bar;\r\nnext",
        );
        let cases = [
            ((2, 0), "cs)[", "[ 123+4*56 ]"),
            ((2, 0), "cs)]", "[123+4*56]"),
            ((2, 0), "csbs", " 123+4*56"),
            ((17, 0), "ds(", "spaced"),
            ((17, 0), "ds)", " spaced "),
            ((16, 1), "cst<lt>p<CR>", "<p class=\"x\">Yo!</p>"),
            ((16, 1), "cst<lt>p>", "<p>Yo!</p>"),
            ((16, 1), "dst", "Yo!"),
            ((16, 1), "yat", "<div class=\"x\">Yo!</div>"),
            ((16, 1), "yit", "Yo!"),
            ((2, 2), "ySiwfprint<CR>", "print(foo)"),
            ((2, 2), "ySiwFf<CR>", "f( foo )"),
            ((2, 2), "yS2w\"", "\"foo bar\""),
            ((2, 2), "ySS{", "{ foo bar; }"),
            ((2, 2), "VgS)", "  (\n  foo bar;\n  )"),
            ((2, 2), "ySj)", "  (\n    foo bar;\n  next\n  )"),
            ((2, 0), "cS)}", "{\n  123+4*56\n}"),
            ((2, 2), "cswb", "(foo)"),
        ];
        for (cursor, keys, expected) in cases {
            let mut m = CopyMode::new(&mut vt, cursor);
            assert_eq!(
                copied(press(&mut m, &mut vt, keys)).as_deref(),
                Some(expected),
                "{keys}"
            );
        }
        let mut m = CopyMode::new(&mut vt, (2, 2));
        assert!(copied(press(&mut m, &mut vt, "ySiw<Esc>ySiwq")).is_none());
        assert!(copied(press(&mut m, &mut vt, "ySiw<lt>em<Esc>")).is_none());
        assert!(
            copied(press(&mut m, &mut vt, "dsw")).is_none(),
            "ds on a word removes nothing"
        );
        assert_eq!(m.status().split("  ").next(), Some("COPY"));
    }

    #[test]
    fn configurable_keywords_preserve_defaults_and_refresh() {
        let mut vt = terminal(60, 4, "foo-bar baz foo-bar-baz foo-bar");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "w");
        assert_eq!(at(&m), (3, 0), "default stops at hyphen");
        m.set_iskeyword(IsKeyword::parse("@,48-57,_,192-255,-").unwrap());
        press(&mut m, &mut vt, "0e");
        assert_eq!(at(&m), (6, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yiw")).as_deref(),
            Some("foo-bar")
        );
        press(&mut m, &mut vt, "0*");
        assert_eq!(at(&m), (24, 0), "star skips the longer keyword");
        assert_eq!(m.search.as_ref().unwrap().matches.len(), 2);
        m.refresh(&mut vt);
        press(&mut m, &mut vt, "0w");
        assert_eq!(at(&m), (8, 0));
        m.set_iskeyword(IsKeyword::default());
        press(&mut m, &mut vt, "0w");
        assert_eq!(at(&m), (3, 0), "live config can restore defaults");
    }

    #[test]
    fn fixed_wordmotion_splits_case_acronyms_digits_and_separators() {
        let mut vt = terminal(
            80,
            3,
            "CamelCaseACRONYMWords_underscore1234 foo--bar 123-456",
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        m.set_iskeyword(IsKeyword::parse("@,48-57,_,192-255,-").unwrap());
        for x in [5, 9, 16, 22, 32, 37, 42, 46, 49, 50] {
            press(&mut m, &mut vt, " w");
            assert_eq!(at(&m), (x, 0));
        }
        press(&mut m, &mut vt, "0 e");
        assert_eq!(at(&m), (4, 0));
        press(&mut m, &mut vt, " e");
        assert_eq!(at(&m), (8, 0));
        press(&mut m, &mut vt, " ge");
        assert_eq!(at(&m), (4, 0));
        press(&mut m, &mut vt, " b");
        assert_eq!(at(&m), (0, 0));
        press(&mut m, &mut vt, "4 w");
        assert_eq!(at(&m), (22, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yi w")).as_deref(),
            Some("underscore")
        );
        press(&mut m, &mut vt, "0");
        assert_eq!(
            copied(press(&mut m, &mut vt, "2y2 w")).as_deref(),
            Some("CamelCaseACRONYMWords_")
        );
        assert!(
            m.visual.is_none(),
            "Space is a prefix, not a selection toggle"
        );
    }

    #[test]
    fn wordmotion_objects_and_numeric_literals() {
        for (text, inner, around) in [
            ("foo-bar", "foo", "foo-"),
            ("foo__bar", "foo", "foo__"),
            ("#0F0F0F next", "#0F0F0F", "#0F0F0F "),
            ("0xff next", "0xff", "0xff "),
            ("0o77 next", "0o77", "0o77 "),
            ("0b101 next", "0b101", "0b101 "),
        ] {
            let mut vt = terminal(40, 3, text);
            let mut m = CopyMode::new(&mut vt, (0, 0));
            assert_eq!(
                copied(press(&mut m, &mut vt, "yi w")).as_deref(),
                Some(inner),
                "{text}"
            );
            assert_eq!(
                copied(press(&mut m, &mut vt, "ya w")).as_deref(),
                Some(around.trim_end()),
                "{text}"
            );
        }
        let mut vt = terminal(40, 3, "foo-bar BazQux");
        let mut m = CopyMode::new(&mut vt, (4, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "vi wy")).as_deref(),
            Some("bar")
        );
        press(&mut m, &mut vt, "0");
        assert_eq!(
            copied(press(&mut m, &mut vt, "y2i w")).as_deref(),
            Some("foo-")
        );
        assert_eq!(
            copied(press(&mut m, &mut vt, "y2a w")).as_deref(),
            Some("foo-bar")
        );
        press(&mut m, &mut vt, "0 W");
        assert_eq!(at(&m), (8, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yi W")).as_deref(),
            Some("BazQux")
        );
    }

    #[test]
    fn wordmotion_crosses_wraps_and_keeps_wide_glyphs_whole() {
        let mut vt = terminal(8, 6, "camelCaseWord 한글Next\r\n\r\nlast");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        for p in [(5, 0), (1, 1), (6, 1), (2, 2), (0, 3), (0, 4)] {
            press(&mut m, &mut vt, " w");
            assert_eq!(at(&m), p);
        }
        press(&mut m, &mut vt, "gg w");
        assert_eq!(
            copied(press(&mut m, &mut vt, "yi w")).as_deref(),
            Some("Case")
        );
    }

    #[test]
    fn hangul_find_till_repeat_counts_and_tense_consonants() {
        let mut vt = terminal(
            60,
            3,
            "x 가 까 r 나 다 따 라 마 바 빠 사 싸 아 자 짜 차 카 타 파 하",
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        for x in [2, 5, 8] {
            press(&mut m, &mut vt, if x == 2 { "fr" } else { ";" });
            assert_eq!(at(&m), (x, 0));
        }
        press(&mut m, &mut vt, ",");
        assert_eq!(at(&m), (5, 0));
        press(&mut m, &mut vt, "0fR");
        assert_eq!(at(&m), (5, 0));
        press(&mut m, &mut vt, "0tr");
        assert_eq!(at(&m), (1, 0));
        press(&mut m, &mut vt, ";");
        assert_eq!(at(&m), (4, 0), "t repeat skips the adjacent wide match");
        press(&mut m, &mut vt, ",");
        assert_eq!(at(&m), (4, 0), "reverse till stops after 가");
        // A forward find includes the entire double-width target.
        assert_eq!(
            copied(press(&mut m, &mut vt, "0yfR")).as_deref(),
            Some("x 가 까")
        );
        press(&mut m, &mut vt, "03fr");
        assert_eq!(at(&m), (8, 0));
        press(&mut m, &mut vt, "Fr");
        assert_eq!(at(&m), (5, 0));
    }

    #[test]
    fn every_two_set_consonant_finds_its_syllables_only() {
        let keys = "rRseEfaqQtTdwWczxvg";
        let syllables = "가까나다따라마바빠사싸아자짜차카타파하";
        for (key, syllable) in keys.chars().zip(syllables.chars()) {
            assert!(words::find_matches(key, syllable), "{key}: {syllable}");
            assert!(words::find_matches(key, key));
            assert!(!words::find_matches(key, '힣') || key == 'g');
        }
        assert!(!words::find_matches('k', '가'), "vowel keys stay literal");
        let mut vt = terminal(6, 4, "x 가 까\r\n가");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "2fr");
        assert_eq!(at(&m), (0, 1), "find crosses soft wraps");
        press(&mut m, &mut vt, ";");
        assert_eq!(at(&m), (0, 1), "find stops at a hard newline");
    }

    #[test]
    fn flash_labels_do_not_consume_query_continuations() {
        let mut vt = terminal(70, 4, "x foo food FOOT foo.bar foo+bar 한글 한글");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "sfoo");
        assert!(m.wants_text());
        assert_eq!(m.search.as_ref().unwrap().matches.len(), 5);
        assert!(m.flash_labels.iter().all(|(_, _, c)| !"dDtT".contains(*c)));
        assert_eq!(at(&m), (0, 0), "typing leaves the cursor in place");
        press(&mut m, &mut vt, ".bar");
        assert!(m.wants_text());
        assert_eq!(
            m.search.as_ref().unwrap().matches.len(),
            1,
            "literal punctuation"
        );
        let (target, _, label) = m.flash_labels[0];
        m.key(&mut vt, Input::char(label));
        assert!(!m.wants_text());
        assert_eq!(m.cursor, target);
        assert!(m.flash_labels.is_empty());
        assert!(m.search.is_none(), "flash leaves / history alone");
    }

    #[test]
    fn flash_supports_unicode_visual_yank_cancel_and_editing() {
        let mut vt = terminal(40, 5, "x 한글 foo 한글\r\nother");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "/other<CR>ggvs한글");
        let (target, _, label) = m.flash_labels[1];
        m.key(&mut vt, Input::char(label));
        assert_eq!(m.cursor, target);
        assert_eq!(m.search.as_ref().unwrap().pattern, "other");
        assert_eq!(
            copied(press(&mut m, &mut vt, "y")).as_deref(),
            Some("x 한글 foo 한")
        );
        press(&mut m, &mut vt, "gg0ys한글");
        let (_, _, label) = m.flash_labels[1];
        assert_eq!(
            m.key(&mut vt, Input::char(label)),
            Effect::Copy {
                text: "x 한글 foo".into(),
                exit: true
            }
        );
        press(&mut m, &mut vt, "gg0yr한글");
        let (_, _, label) = m.flash_labels[1];
        m.key(&mut vt, Input::char(label));
        assert_eq!(
            copied(press(&mut m, &mut vt, "iw")).as_deref(),
            Some("한글"),
            "yr jumps, then yanks the next motion from there"
        );
        press(&mut m, &mut vt, "gg0s한글<BS>");
        assert_eq!(m.prompt.as_ref().unwrap().text, "한");
        press(&mut m, &mut vt, "<C-u>");
        assert!(m.flash_labels.is_empty());
        press(&mut m, &mut vt, "없");
        assert!(
            !m.wants_text(),
            "no match immediately leaves the search prompt"
        );
        assert!(!m.flash_active());
        assert_eq!(at(&m), (0, 0));
        assert!(!m.wants_text());
        assert_eq!(m.search.as_ref().unwrap().pattern, "other");
    }

    #[test]
    fn flash_only_searches_visible_rows_and_handles_overlapping_matches() {
        let mut vt = terminal(12, 3, "aaaa\r\none\r\ntwo\r\naaaa\r\nthree\r\naaaa");
        vt.scroll_viewport(ScrollViewport::Top);
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "saa");
        assert_eq!(m.search.as_ref().unwrap().matches.len(), 3);
        assert!(
            m.search
                .as_ref()
                .unwrap()
                .matches
                .iter()
                .all(|(p, _)| p.y == 0)
        );
        press(&mut m, &mut vt, "<Esc>");
        press(&mut m, &mut vt, "Gsaa<Down><Down><Down><CR>");
        assert_eq!(m.cursor.y, 3, "Enter wraps through visible matches only");
    }

    #[test]
    fn flash_keeps_labels_stable_and_bounds_them_to_visible_cells() {
        let mut vt = terminal(12, 4, "x food foo.bar\r\n한글한글한글");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "sfoo");
        let (_, _, label) = m
            .flash_labels
            .iter()
            .find(|(p, _, _)| p.x == 7)
            .copied()
            .unwrap();
        press(&mut m, &mut vt, ".bar");
        assert_eq!(m.flash_labels.len(), 1);
        assert_eq!(
            m.flash_labels[0].2, label,
            "narrowing reuses the target's label"
        );
        assert_eq!(
            m.highlights(0, 4, 12).len(),
            2,
            "the match spans the soft wrap"
        );
        press(&mut m, &mut vt, "<Esc>s한글");
        assert_eq!(m.flash_labels.len(), 3);
        for (_, at, _) in &m.flash_labels {
            assert!(at.x < 12);
            assert_ne!(m.text.ch(&vt, *at), SPACER);
        }
        m.open_search(&mut vt, false, false);
        assert!(
            m.labels(0, 4).is_empty(),
            "opening / removes old jump labels"
        );
    }

    #[test]
    fn flash_exhausted_labels_still_allow_narrowing_and_tab() {
        let text = format!("x {}", "a ".repeat(70));
        let mut vt = terminal(40, 5, &text);
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "sa");
        assert_eq!(m.search.as_ref().unwrap().matches.len(), 70);
        assert_eq!(m.flash_labels.len(), 52);
        let labels: std::collections::HashSet<_> =
            m.flash_labels.iter().map(|(_, _, c)| *c).collect();
        assert_eq!(labels.len(), 52);
        for _ in 0..60 {
            m.key(&mut vt, Input::key(Key::Tab));
        }
        let target = m.cursor;
        press(&mut m, &mut vt, "<CR>");
        assert_eq!(m.cursor, target);
        assert!(!m.wants_text());
    }

    #[test]
    fn word_motions_follow_vim_classes() {
        let mut vt = terminal(40, 6, PROSE);
        let mut m = CopyMode::new(&mut vt, (0, 0));
        let mut trail = Vec::new();
        for _ in 0..6 {
            press(&mut m, &mut vt, "w");
            trail.push(at(&m));
        }
        assert_eq!(trail, [(4, 0), (7, 0), (8, 0), (13, 0), (0, 1), (2, 2)]);
        press(&mut m, &mut vt, "bb");
        assert_eq!(at(&m), (13, 0));
        press(&mut m, &mut vt, "B");
        assert_eq!(at(&m), (4, 0));
        press(&mut m, &mut vt, "e");
        assert_eq!(at(&m), (6, 0));
        press(&mut m, &mut vt, "E");
        assert_eq!(at(&m), (10, 0));
        press(&mut m, &mut vt, "ge");
        assert_eq!(at(&m), (7, 0));
        press(&mut m, &mut vt, "0W");
        assert_eq!(at(&m), (4, 0));
        press(&mut m, &mut vt, "3w");
        assert_eq!(at(&m), (13, 0));
    }

    #[test]
    fn line_motions_counts_and_goto() {
        let mut vt = terminal(40, 6, PROSE);
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "2j$");
        assert_eq!(at(&m), (14, 2));
        press(&mut m, &mut vt, "0");
        assert_eq!(at(&m), (0, 2));
        press(&mut m, &mut vt, "^");
        assert_eq!(at(&m), (2, 2));
        press(&mut m, &mut vt, "G");
        assert_eq!(
            at(&m),
            (2, 3),
            "G keeps the column at the last row with text"
        );
        press(&mut m, &mut vt, "gg");
        assert_eq!(at(&m), (2, 0));
        press(&mut m, &mut vt, "3G");
        assert_eq!(at(&m), (2, 2));
        press(&mut m, &mut vt, "k$jj");
        assert_eq!(at(&m), (3, 3), "$ keeps following line ends");
    }

    #[test]
    fn find_till_and_repeat() {
        let mut vt = terminal(40, 6, PROSE);
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "fa");
        assert_eq!(at(&m), (5, 0));
        press(&mut m, &mut vt, ";");
        assert_eq!(at(&m), (9, 0));
        press(&mut m, &mut vt, ",");
        assert_eq!(at(&m), (5, 0));
        press(&mut m, &mut vt, "0tb");
        assert_eq!(at(&m), (3, 0));
        press(&mut m, &mut vt, ";");
        assert_eq!(at(&m), (7, 0), "a repeated till moves on");
        press(&mut m, &mut vt, "Fo");
        assert_eq!(at(&m), (2, 0));
        press(&mut m, &mut vt, "fz");
        assert_eq!(at(&m), (10, 0));
        press(&mut m, &mut vt, "fz");
        assert_eq!(at(&m), (10, 0), "no further match stays put");
    }

    #[test]
    fn visual_modes_and_text_objects_copy() {
        let mut vt = terminal(40, 6, PROSE);
        let mut m = CopyMode::new(&mut vt, (5, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "viwy")).as_deref(),
            Some("bar")
        );
        let mut m = CopyMode::new(&mut vt, (5, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "vaWy")).as_deref(),
            Some("bar.baz")
        );
        let mut m = CopyMode::new(&mut vt, (5, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yiW")).as_deref(),
            Some("bar.baz")
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(copied(press(&mut m, &mut vt, "ve")).as_deref(), None);
        assert_eq!(copied(press(&mut m, &mut vt, "y")).as_deref(), Some("foo"));
        let mut m = CopyMode::new(&mut vt, (0, 2));
        assert_eq!(
            copied(press(&mut m, &mut vt, "Vjy")).as_deref(),
            Some("  indented line\nlast")
        );
        let mut m = CopyMode::new(&mut vt, (4, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "y$")).as_deref(),
            Some("bar.baz  qux")
        );
        let mut m = CopyMode::new(&mut vt, (4, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yy")).as_deref(),
            Some("foo bar.baz  qux")
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "y2w")).as_deref(),
            Some("foo bar")
        );
        let mut m = CopyMode::new(&mut vt, (13, 0));
        assert_eq!(copied(press(&mut m, &mut vt, "yw")).as_deref(), Some("qux"));
    }

    #[test]
    fn quote_and_bracket_objects() {
        let mut vt = terminal(60, 4, "echo \"hello world\" (a (b) c) [x]");
        let mut m = CopyMode::new(&mut vt, (8, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "vi\"y")).as_deref(),
            Some("hello world")
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "va\"y")).as_deref(),
            Some("\"hello world\""),
            "the first quoted string after the cursor"
        );
        let mut m = CopyMode::new(&mut vt, (23, 0));
        assert_eq!(copied(press(&mut m, &mut vt, "vi(y")).as_deref(), Some("b"));
        let mut m = CopyMode::new(&mut vt, (23, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "ya)")).as_deref(),
            Some("(b)")
        );
        let mut m = CopyMode::new(&mut vt, (26, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yib")).as_deref(),
            Some("a (b) c")
        );
        let mut m = CopyMode::new(&mut vt, (31, 0));
        assert_eq!(copied(press(&mut m, &mut vt, "yi[")).as_deref(), Some("x"));
    }

    #[test]
    fn block_selection_and_line_ends() {
        let mut vt = terminal(20, 5, "abc\r\ndefgh\r\nij");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "<C-v>jly")).as_deref(),
            Some("ab\nde")
        );
        let mut m = CopyMode::new(&mut vt, (1, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "<C-v>jj$y")).as_deref(),
            Some("bc\nefgh\nj")
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "vjV");
        assert_eq!(m.visual.map(|v| v.kind), Some(VisualKind::Line));
        press(&mut m, &mut vt, "V");
        assert!(m.visual.is_none(), "the same visual key leaves visual mode");
        press(&mut m, &mut vt, "gv");
        assert_eq!(m.visual.map(|v| v.kind), Some(VisualKind::Line));
        press(&mut m, &mut vt, "o");
        assert_eq!(at(&m), (0, 0));
    }

    #[test]
    fn incremental_search_navigation_and_cancel() {
        let mut vt = terminal(40, 6, "error one\r\nok\r\nError two\r\nerror three");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "/err");
        assert_eq!(
            at(&m),
            (0, 3),
            "typing moves to the next case-sensitive match"
        );
        assert_eq!(m.status(), "/err  [2/2]");
        press(&mut m, &mut vt, "<CR>");
        assert!(m.prompt.is_none());
        press(&mut m, &mut vt, "n");
        assert_eq!(at(&m), (0, 0), "n wraps");
        press(&mut m, &mut vt, "n");
        assert_eq!(at(&m), (0, 3));
        press(&mut m, &mut vt, "N");
        assert_eq!(at(&m), (0, 0));
        press(&mut m, &mut vt, "/Err<CR>");
        assert_eq!(at(&m), (0, 2), "uppercase searches are case-sensitive too");
        press(&mut m, &mut vt, "?t[wh]<CR>");
        assert_eq!(at(&m), (6, 3), "regex, backward, wrapping past the top");
        press(&mut m, &mut vt, "N");
        assert_eq!(at(&m), (6, 2), "N reverses a backward search");
        press(&mut m, &mut vt, "/nothing");
        assert_eq!(at(&m), (6, 2));
        press(&mut m, &mut vt, "<Esc>");
        assert_eq!(at(&m), (6, 2), "Escape restores the cursor");
        assert_eq!(m.search.as_ref().map(|s| s.pattern.as_str()), Some("t[wh]"));
        press(&mut m, &mut vt, "/(<CR>");
        assert!(
            m.search.as_ref().is_some_and(|s| s.matches.is_empty()),
            "unescaped parentheses are literal in Vim magic syntax"
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "/one<CR><CR>")).as_deref(),
            Some("one")
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "/t.o<CR>ygn")).as_deref(),
            Some("two")
        );
    }

    #[test]
    fn star_searches_the_word_under_the_cursor() {
        let mut vt = terminal(40, 4, "foo bar foobar foo");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "*");
        assert_eq!(at(&m), (15, 0), "whole words only");
        press(&mut m, &mut vt, "#");
        assert_eq!(at(&m), (0, 0));
    }

    #[test]
    fn soft_wrapped_lines_are_one_line() {
        let mut vt = terminal(10, 5, "0123456789abcdef ghi\r\nnext");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "$");
        assert_eq!(at(&m), (9, 1));
        press(&mut m, &mut vt, "0");
        assert_eq!(at(&m), (0, 0));
        press(&mut m, &mut vt, "w");
        assert_eq!(at(&m), (7, 1));
        let mut m = CopyMode::new(&mut vt, (2, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yiw")).as_deref(),
            Some("0123456789abcdef")
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yy")).as_deref(),
            Some("0123456789abcdef ghi")
        );
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "/9a<CR>");
        assert_eq!(at(&m), (9, 0));
        assert_eq!(m.highlights(0, 5, 10), [(0, 9, 10, true), (1, 0, 1, true)]);
    }

    #[test]
    fn visual_newline_beyond_a_full_row_stays_on_the_renderable_grid() {
        let mut vt = terminal(3, 2, "abc\r\n");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "v$");
        assert_eq!(m.cursor_viewport(&vt), Some((2, 0, false)));
        let selection = libghostty_vt::fmt::Formatter::new_selection(&vt)
            .unwrap().unwrap().format_alloc(None).unwrap();
        assert_eq!(selection.as_ref(), b"abc");
        assert_eq!(m.copy_text(&mut vt).as_deref(), Some("abc\n"));
    }

    #[test]
    fn wide_glyphs_are_single_positions() {
        let mut vt = terminal(20, 3, "한글 abc 테스트");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "l");
        assert_eq!(at(&m), (2, 0));
        press(&mut m, &mut vt, "w");
        assert_eq!(at(&m), (5, 0));
        press(&mut m, &mut vt, "w");
        assert_eq!(at(&m), (9, 0));
        press(&mut m, &mut vt, "e");
        assert_eq!(at(&m), (13, 0));
        let mut m = CopyMode::new(&mut vt, (1, 0));
        assert_eq!(at(&m), (0, 0), "a spacer is never a cursor position");
        assert_eq!(
            copied(press(&mut m, &mut vt, "yiw")).as_deref(),
            Some("한글")
        );
        let mut m = CopyMode::new(&mut vt, (9, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "v$y")).as_deref(),
            Some("테스트\n")
        );
        assert_eq!(m.cursor_viewport(&vt), Some((15, 0, false)));
    }

    #[test]
    fn prompts_and_command_output_objects() {
        let mut vt = terminal(
            30,
            10,
            concat!(
                "\x1b]133;A\x07$ \x1b]133;B\x07cmd1\r\n",
                "\x1b]133;C\x07out1\r\nout2\r\n\x1b]133;D;0\x07",
                "\x1b]133;A\x07$ \x1b]133;B\x07cmd2\r\n",
                "\x1b]133;C\x07out3\r\n\x1b]133;D;0\x07",
                "\x1b]133;A\x07$ "
            ),
        );
        let mut m = CopyMode::new(&mut vt, (0, 5));
        press(&mut m, &mut vt, "[[");
        assert_eq!(at(&m), (0, 3));
        press(&mut m, &mut vt, "[[");
        assert_eq!(at(&m), (0, 0));
        press(&mut m, &mut vt, "]]");
        assert_eq!(at(&m), (0, 3));
        let mut m = CopyMode::new(&mut vt, (1, 1));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yio")).as_deref(),
            Some("out1\nout2")
        );
        let mut m = CopyMode::new(&mut vt, (1, 1));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yao")).as_deref(),
            Some("$ cmd1\nout1\nout2")
        );
        let mut m = CopyMode::new(&mut vt, (0, 3));
        assert_eq!(
            copied(press(&mut m, &mut vt, "vioy")).as_deref(),
            Some("out3")
        );
    }

    #[test]
    fn paragraphs_and_brackets() {
        let mut vt = terminal(20, 8, "a\r\nb\r\n\r\nc (x [y] z)\r\nd");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        press(&mut m, &mut vt, "}");
        assert_eq!(at(&m), (0, 2));
        press(&mut m, &mut vt, "}");
        assert_eq!(
            at(&m),
            (0, 5),
            "the blank screen rows below end the last paragraph"
        );
        press(&mut m, &mut vt, "{");
        assert_eq!(at(&m), (0, 2));
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(
            copied(press(&mut m, &mut vt, "yip")).as_deref(),
            Some("a\nb")
        );
        let mut m = CopyMode::new(&mut vt, (0, 3));
        press(&mut m, &mut vt, "%");
        assert_eq!(at(&m), (10, 3));
        press(&mut m, &mut vt, "%");
        assert_eq!(at(&m), (2, 3));
        press(&mut m, &mut vt, "fy%");
        assert_eq!(
            at(&m),
            (5, 3),
            "the next bracket on the line, then its match"
        );
    }

    #[test]
    fn scrolling_screen_rows_and_exit_keys() {
        let lines: String = (0..100).map(|i| format!("line {i}\r\n")).collect();
        let mut vt = terminal(20, 10, &lines);
        let mut m = CopyMode::new(&mut vt, (0, 9));
        assert_eq!(at(&m).1, 100);
        press(&mut m, &mut vt, "<C-u>");
        assert_eq!(at(&m).1, 95);
        assert_eq!(vt.scrollbar().unwrap().offset, 86);
        press(&mut m, &mut vt, "H");
        assert_eq!(at(&m), (0, 86));
        press(&mut m, &mut vt, "L");
        assert_eq!(at(&m), (0, 95));
        press(&mut m, &mut vt, "gg");
        assert_eq!(vt.scrollbar().unwrap().offset, 0);
        press(&mut m, &mut vt, "50%");
        assert_eq!(at(&m).1, 50);
        press(&mut m, &mut vt, "zt");
        assert_eq!(vt.scrollbar().unwrap().offset, 50);
        assert_eq!(
            press(&mut m, &mut vt, "v<Esc>"),
            [Effect::None, Effect::None]
        );
        assert!(m.visual.is_none());
        assert_eq!(press(&mut m, &mut vt, "<Esc>"), [Effect::Exit]);
        assert_eq!(press(&mut m, &mut vt, "q"), [Effect::Exit]);
        assert_eq!(press(&mut m, &mut vt, "i"), [Effect::Exit]);
        assert_eq!(press(&mut m, &mut vt, "r"), [Effect::Refresh]);
        m.finish(&mut vt);
        let bar = vt.scrollbar().unwrap();
        assert_eq!(
            bar.offset + bar.len,
            bar.total,
            "leaving restores the live bottom"
        );
    }

    #[test]
    fn find_text_api_selects_matches_newest_first() {
        let mut vt = terminal(30, 5, "a.b one\r\naxb\r\na.b two");
        let mut m = CopyMode::new(&mut vt, (0, 0));
        assert_eq!(m.find_text(&mut vt, "a.b", false), 2, "literal");
        assert_eq!(at(&m), (0, 2));
        assert_eq!(m.copy_text(&mut vt).as_deref(), Some("a.b"));
        m.find_text(&mut vt, "a.b", true);
        assert_eq!(at(&m), (0, 0));
        assert_eq!(m.find_text(&mut vt, "A.B", false), 0, "case-sensitive");
    }
}
