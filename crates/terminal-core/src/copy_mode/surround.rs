//! vim-surround over a read-only screen. `yS` (vim-surround's `ys`, since `ys`
//! yanks to a flash target), `ySS`, `cs`, `cS`, `ds` and visual `S` copy the
//! text they would produce, then leave.
use super::{CopyMode, Effect, Input, Key, Pos, SPACER, Span, Terminal, Text, VisualKind, Wait};

/// An operator waiting for its motion (`yS`) or target (`ds`, `cs`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SurroundOp {
    Add,
    Delete,
    Change { lines: bool },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Layout {
    Inline,
    /// Delimiters on lines of their own; the text indented unless `gS`.
    Lines {
        indent: bool,
    },
    /// Block selections wrap every row.
    EachLine,
}

#[derive(Clone, Debug)]
pub(super) enum Source {
    Range(Pos, Pos, Span),
    Visual,
    /// `cs`: the target's contents, and its opening tag's attributes.
    Text {
        content: String,
        attributes: String,
    },
}

/// A surround waiting for its replacement.
#[derive(Clone, Debug)]
pub(super) struct Wrap {
    source: Source,
    layout: Layout,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Ask {
    Tag { lines: bool },
    Function(char),
    Latex,
}

/// A tag, function name or LaTeX environment being typed for a replacement.
#[derive(Debug)]
pub(super) struct Asking {
    wrap: Wrap,
    ask: Ask,
    text: String,
}

enum Replacement {
    Pair(String, String),
    Ask(Ask),
}

/// Choose a replacement using vim-surround's keys.
///
/// - Opening brackets (`(`, `{`, `[`) add inner spaces.
/// - Closing brackets (`)`, `}`, `]`, `>`) and `b B r a` omit inner spaces.
/// - `<` or `t` asks for a tag. `f` or `F` asks for a function.
/// - `l` or `\` asks for a LaTeX environment. `s` adds a leading space.
/// - Any other non-alphabetic character surrounds with itself.
fn replacement(c: char) -> Option<Replacement> {
    let pair = |left: &str, right: &str| Some(Replacement::Pair(left.into(), right.into()));
    match c {
        '(' => pair("( ", " )"),
        '{' => pair("{ ", " }"),
        '[' => pair("[ ", " ]"),
        ')' | 'b' => pair("(", ")"),
        '}' | 'B' => pair("{", "}"),
        ']' | 'r' => pair("[", "]"),
        '>' | 'a' => pair("<", ">"),
        's' => pair(" ", ""),
        '<' | 't' => Some(Replacement::Ask(Ask::Tag { lines: false })),
        'f' | 'F' => Some(Replacement::Ask(Ask::Function(c))),
        'l' | '\\' => Some(Replacement::Ask(Ask::Latex)),
        c if c.is_alphabetic() || c.is_control() => None,
        c => pair(&c.to_string(), &c.to_string()),
    }
}

/// Place `left` and `right` around copied `text`.
fn arrange(text: &str, left: &str, right: &str, layout: Layout) -> String {
    match layout {
        Layout::Inline => format!("{left}{text}{right}"),
        Layout::EachLine => text
            .lines()
            .map(|line| format!("{left}{line}{right}"))
            .collect::<Vec<_>>()
            .join("\n"),
        Layout::Lines { indent } => {
            // The delimiters take the first line's indentation, as in Vim.
            let lead: String = text
                .chars()
                .take_while(|c| matches!(c, ' ' | '\t'))
                .collect();
            let body = text
                .lines()
                .map(|line| {
                    if indent && !line.is_empty() {
                        format!("  {line}")
                    } else {
                        line.to_owned()
                    }
                })
                .collect::<Vec<_>>()
                .join("\n");
            let mut out = format!("{lead}{}\n{body}", left.trim_end());
            let right = right.trim_start();
            if !right.is_empty() {
                out += &format!("\n{lead}{right}");
            }
            out
        }
    }
}

impl CopyMode {
    pub(super) fn start_wrap(&mut self, source: Source, layout: Layout, keys: &str) {
        self.wrap = Some(Wrap { source, layout });
        self.wait = Wait::Replacement;
        self.keys = keys.to_owned();
    }

    pub(super) fn visual_wrap(&mut self, indent: bool) {
        let layout = match self.visual.map(|v| v.kind) {
            Some(VisualKind::Line) => Layout::Lines { indent },
            Some(VisualKind::Block) => Layout::EachLine,
            _ => Layout::Inline,
        };
        self.start_wrap(Source::Visual, layout, if indent { "S" } else { "gS" });
    }

    /// A motion or text object completed an operator: copy it, or after `ys`
    /// wait for the replacement. Linewise motions put it on lines of its own.
    pub(super) fn operator_range(
        &mut self,
        vt: &mut Terminal<'_, '_>,
        a: Pos,
        b: Pos,
        span: Span,
    ) -> Effect {
        match self.surround.take() {
            Some(SurroundOp::Add) => {
                let layout = if span == Span::Lines {
                    Layout::Lines { indent: true }
                } else {
                    Layout::Inline
                };
                self.start_wrap(Source::Range(a, b, span), layout, "yS");
                Effect::None
            }
            _ => self.yank_range(vt, a, b, span),
        }
    }

    /// `ySS` takes the line from its first non-blank, like vim-surround's `yss`.
    pub(super) fn surround_line(&mut self, vt: &Terminal<'_, '_>) {
        self.surround = None;
        self.yank = false;
        self.count = 0;
        self.yank_count = 0;
        let y = self.cursor.y;
        let (start, end) = (self.text.first_non_blank(vt, y), self.text.line_last(vt, y));
        self.start_wrap(
            Source::Range(start, end, Span::Inclusive),
            Layout::Inline,
            "ySS",
        );
    }

    /// `ds{target}` copies the contents; `cs{target}` waits for a replacement.
    pub(super) fn surround_target(
        &mut self,
        vt: &mut Terminal<'_, '_>,
        op: SurroundOp,
        target: char,
    ) -> Effect {
        let Some((content, attributes)) = self.target_contents(vt, op, target) else {
            return Effect::None;
        };
        match op {
            SurroundOp::Delete => Effect::Copy {
                text: content,
                exit: true,
            },
            SurroundOp::Change { lines } => {
                let layout = if lines {
                    Layout::Lines { indent: true }
                } else {
                    Layout::Inline
                };
                let keys = format!("{}{target}", if lines { "cS" } else { "cs" });
                self.start_wrap(
                    Source::Text {
                        content,
                        attributes,
                    },
                    layout,
                    &keys,
                );
                Effect::None
            }
            SurroundOp::Add => Effect::None,
        }
    }

    /// A target's text without its delimiters. An opening bracket also trims
    /// the whitespace inside; `w`, `W` and `p` delimit nothing (`cs` wraps them).
    fn target_contents(
        &mut self,
        vt: &mut Terminal<'_, '_>,
        op: SurroundOp,
        target: char,
    ) -> Option<(String, String)> {
        let target = match target {
            'b' => ')',
            'B' => '}',
            'r' => ']',
            'a' => '>',
            c => c,
        };
        match target {
            'w' | 'W' | 'p' if op != SurroundOp::Delete => {
                let (a, b, span) = self.object(vt, target, false, 1)?;
                Some((
                    self.range_text(vt, a, b, span).unwrap_or_default(),
                    String::new(),
                ))
            }
            't' => {
                let (a, b) = self.text.tag_object(vt, self.cursor, true, 1)?;
                let whole = self.range_text(vt, a, b, Span::Inclusive)?;
                let open = whole.find('>')? + 1;
                let close = whole.rfind("</")?;
                let name_end = whole[1..open - 1]
                    .find(|c: char| c.is_whitespace())
                    .map_or(open - 1, |i| i + 1);
                let content = whole.get(open..close.max(open))?.to_owned();
                Some((content, whole[name_end..open - 1].to_owned()))
            }
            '(' | ')' | '[' | ']' | '{' | '}' | '<' | '>' | '"' | '\'' | '`' => {
                let (a, b) = if matches!(target, '"' | '\'' | '`') {
                    self.text
                        .counted_quote_object(vt, self.cursor, target, false, 2, None)?
                } else {
                    let (a, b, _) = self.object(vt, target, true, 1)?;
                    (a, b)
                };
                let whole = self.range_text(vt, a, b, Span::Inclusive)?;
                let mut inner = whole.chars();
                inner.next();
                inner.next_back();
                let content = if "([{<".contains(target) {
                    inner.as_str().trim()
                } else {
                    inner.as_str()
                };
                Some((content.to_owned(), String::new()))
            }
            _ => None,
        }
    }

    /// The key after `ys{motion}`, `cs{target}` or visual `S`. An unknown
    /// replacement copies nothing and leaves any selection in place.
    pub(super) fn replacement_key(&mut self, vt: &mut Terminal<'_, '_>, input: Input) -> Effect {
        let Some(wrap) = self.wrap.take() else {
            return Effect::None;
        };
        self.keys.clear();
        let found = match (input.key, input.ctrl) {
            // <C-]> and <C-t> put braces or a tag on lines of their own.
            (Key::Char(']'), true) => return self.finish_wrap(vt, wrap, "{", "}", true),
            (Key::Char('t'), true) => Some(Replacement::Ask(Ask::Tag { lines: true })),
            (Key::Char('f'), true) => Some(Replacement::Ask(Ask::Function('\u{6}'))),
            (Key::Char(c), false) => replacement(c),
            _ => None,
        };
        match found {
            Some(Replacement::Pair(left, right)) => {
                self.finish_wrap(vt, wrap, &left, &right, false)
            }
            Some(Replacement::Ask(ask)) => {
                self.asking = Some(Asking {
                    wrap,
                    ask,
                    text: String::new(),
                });
                Effect::None
            }
            None => Effect::None,
        }
    }

    /// Typing a tag (ended by `>` or Enter), function name or environment.
    pub(super) fn asking_key(&mut self, vt: &mut Terminal<'_, '_>, input: Input) -> Effect {
        let Some(asking) = self.asking.as_mut() else {
            return Effect::None;
        };
        match (input.key, input.ctrl) {
            (Key::Escape, _) | (Key::Char('c' | '['), true) => self.asking = None,
            (Key::Enter, _) => return self.finish_asking(vt, false),
            (Key::Backspace, _) => {
                if asking.text.pop().is_none() {
                    self.asking = None;
                }
            }
            (Key::Char('u'), true) => asking.text.clear(),
            (Key::Char('>'), false) if matches!(asking.ask, Ask::Tag { .. }) => {
                return self.finish_asking(vt, true);
            }
            (Key::Char(c), false) if !c.is_control() && asking.text.len() < 1024 => {
                asking.text.push(c);
            }
            _ => {}
        }
        Effect::None
    }

    /// The status line while a replacement is being typed.
    pub(super) fn asking_status(&self) -> Option<String> {
        let asking = self.asking.as_ref()?;
        Some(match asking.ask {
            Ask::Tag { .. } => format!("<{}", asking.text),
            Ask::Function(_) => format!("function: {}", asking.text),
            Ask::Latex => format!("\\begin{{{}", asking.text),
        })
    }

    fn finish_asking(&mut self, vt: &mut Terminal<'_, '_>, closed: bool) -> Effect {
        let Some(Asking { wrap, ask, text }) = self.asking.take() else {
            return Effect::None;
        };
        let (left, right, lines) = match ask {
            Ask::Tag { lines } => {
                let tag = text.trim();
                if tag.is_empty() {
                    return Effect::None;
                }
                // Enter keeps a replaced tag's attributes; a typed `>` drops them.
                let attributes = match (&wrap.source, closed) {
                    (Source::Text { attributes, .. }, false) => attributes.as_str(),
                    _ => "",
                };
                match tag.strip_suffix('/') {
                    Some(tag) => (
                        format!("<{}{attributes} />", tag.trim_end()),
                        String::new(),
                        lines,
                    ),
                    None => {
                        let name = tag.split_whitespace().next().unwrap_or(tag);
                        (format!("<{tag}{attributes}>"), format!("</{name}>"), lines)
                    }
                }
            }
            Ask::Function('F') => (format!("{text}( "), " )".into(), false),
            Ask::Function('f') => (format!("{text}("), ")".into(), false),
            Ask::Function(_) => (format!("({text} "), ")".into(), false),
            Ask::Latex => {
                let name = text.split('}').next().unwrap_or_default();
                (
                    format!("\\begin{{{text}}}"),
                    format!("\\end{{{name}}}"),
                    false,
                )
            }
        };
        self.finish_wrap(vt, wrap, &left, &right, lines)
    }

    fn finish_wrap(
        &mut self,
        vt: &mut Terminal<'_, '_>,
        wrap: Wrap,
        left: &str,
        right: &str,
        lines: bool,
    ) -> Effect {
        let layout = match wrap.layout {
            Layout::Inline if lines => Layout::Lines { indent: true },
            layout => layout,
        };
        let content = match wrap.source {
            Source::Range(a, b, span) => self.range_text(vt, a, b, span).unwrap_or_default(),
            Source::Visual => match self.yank_visual(vt) {
                Effect::Copy { text, .. } => text,
                _ => String::new(),
            },
            Source::Text { content, .. } => content,
        };
        Effect::Copy {
            text: arrange(&content, left, right, layout),
            exit: true,
        }
    }
}

impl Text {
    /// `it`/`at`: the innermost tag pair around `p` (or the `count`th one
    /// outward), searched within a few hundred rows. Comments, declarations
    /// and self-closing tags do not pair; mismatched closers are skipped.
    pub(super) fn tag_object(
        &mut self,
        vt: &Terminal<'_, '_>,
        p: Pos,
        around: bool,
        count: u32,
    ) -> Option<(Pos, Pos)> {
        const ROWS: u32 = 200;
        let first = self.line_start(vt, p.y.saturating_sub(ROWS));
        let last = self.line_end(vt, (p.y + ROWS).min(self.total - 1));
        let mut cells: Vec<(Pos, char)> = Vec::new();
        for y in first..=last {
            let row = self.row(vt, y);
            cells.extend(
                row.cells
                    .iter()
                    .enumerate()
                    .filter(|(_, c)| **c != SPACER)
                    .map(|(x, c)| (Pos::new(x as u16, y), *c)),
            );
            if !row.wrapped {
                cells.push((Pos::new(row.cells.len() as u16, y), '\n'));
            }
        }
        let at = cells.partition_point(|(q, _)| *q < p);
        // (start, end, name, closing) for every `<name …>` and `</name>`.
        let mut tags: Vec<(usize, usize, String, bool)> = Vec::new();
        let mut i = 0;
        while i < cells.len() {
            if cells[i].1 != '<' {
                i += 1;
                continue;
            }
            let Some(len) = cells[i + 1..]
                .iter()
                .take(1024)
                .position(|(_, c)| matches!(c, '<' | '>'))
            else {
                break;
            };
            let end = i + 1 + len;
            if cells[end].1 == '<' {
                i = end;
                continue;
            }
            let body: String = cells[i + 1..end].iter().map(|(_, c)| *c).collect();
            let closing = body.starts_with('/');
            let name: String = body
                .trim_start_matches('/')
                .chars()
                .take_while(|c| !c.is_whitespace() && *c != '/')
                .collect();
            if name.starts_with(|c: char| c.is_alphabetic()) && !body.ends_with('/') {
                tags.push((i, end, name, closing));
            }
            i = end + 1;
        }
        let mut open: Vec<usize> = Vec::new();
        let mut pairs: Vec<(usize, usize)> = Vec::new();
        for (k, (_, _, name, closing)) in tags.iter().enumerate() {
            if !closing {
                open.push(k);
            } else if let Some(depth) = open.iter().rposition(|&o| tags[o].2 == *name) {
                pairs.push((open[depth], k));
                open.truncate(depth);
            }
        }
        pairs.retain(|&(o, c)| tags[o].0 <= at && at <= tags[c].1);
        pairs.sort_by_key(|&(o, c)| tags[c].1 - tags[o].0);
        let &(o, c) = pairs.get(count.max(1) as usize - 1)?;
        if around {
            return Some((cells[tags[o].0].0, cells[tags[c].1].0));
        }
        let (mut a, mut b) = (tags[o].1 + 1, tags[c].0.checked_sub(1)?);
        while a < b && cells[a].1 == '\n' {
            a += 1;
        }
        while b > a && cells[b].1 == '\n' {
            b -= 1;
        }
        (a <= b && cells[a].1 != '\n').then(|| (cells[a].0, cells[b].0))
    }
}
