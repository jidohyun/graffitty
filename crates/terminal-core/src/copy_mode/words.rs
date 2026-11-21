//! Fixed wordmotion rules and the two-set Korean keyboard's initial consonants.
use super::{IsKeyword, Pos, Terminal, Text, is_blank};
use std::sync::LazyLock;

fn default_keyword(c: char) -> bool {
    static KEYWORD: LazyLock<IsKeyword> = LazyLock::new(IsKeyword::default);
    KEYWORD.contains(c)
}

/// A physical consonant key also finds syllables with that initial. Unshifted
/// consonants include their tense pair, as vim-f-hangul does; shifted keys can
/// target just the tense initial. Literal Latin characters still match exactly.
pub(super) fn find_matches(key: char, c: char) -> bool {
    if key == c {
        return true;
    }
    let range = match key {
        'r' | 'ㄱ' => 0..=1,
        'R' | 'ㄲ' => 1..=1,
        's' | 'ㄴ' => 2..=2,
        'e' | 'ㄷ' => 3..=4,
        'E' | 'ㄸ' => 4..=4,
        'f' | 'ㄹ' => 5..=5,
        'a' | 'ㅁ' => 6..=6,
        'q' | 'ㅂ' => 7..=8,
        'Q' | 'ㅃ' => 8..=8,
        't' | 'ㅅ' => 9..=10,
        'T' | 'ㅆ' => 10..=10,
        'd' | 'ㅇ' => 11..=11,
        'w' | 'ㅈ' => 12..=13,
        'W' | 'ㅉ' => 13..=13,
        'c' | 'ㅊ' => 14..=14,
        'z' | 'ㅋ' => 15..=15,
        'x' | 'ㅌ' => 16..=16,
        'v' | 'ㅍ' => 17..=17,
        'g' | 'ㅎ' => 18..=18,
        _ => return false,
    };
    ('가'..='힣').contains(&c) && range.contains(&((c as u32 - '가' as u32) / 588))
}

#[derive(Clone, Copy)]
pub(super) struct Token {
    start: Pos,
    end: Pos,
    space: bool,
}

fn tokens(cells: &[(Pos, char)]) -> Vec<Token> {
    let chars: Vec<char> = cells.iter().map(|(_, c)| *c).collect();
    let mut spaces: Vec<bool> = chars.iter().map(|c| is_blank(*c)).collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '-' || c == '_' {
            let mut j = i + 1;
            while j < chars.len() && chars[j] == c {
                j += 1;
            }
            let word = |c: char| c.is_lowercase() || c.is_uppercase();
            let side = |d: char| word(d) || (c == '_' && d.is_ascii_digit());
            if i > 0 && j < chars.len() && side(chars[i - 1]) && side(chars[j]) {
                spaces[i..j].fill(true);
            }
            i = j;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::new();
    i = 0;
    while i < chars.len() {
        let c = chars[i];
        let mut end = i + 1;
        if spaces[i] {
            while end < chars.len() && spaces[end] {
                end += 1;
            }
        } else if let Some(last) = number_end(&chars, i) {
            end = last;
        } else if c.is_uppercase() {
            if end < chars.len() && chars[end].is_lowercase() {
                while end < chars.len() && chars[end].is_lowercase() {
                    end += 1;
                }
            } else {
                while end < chars.len() && chars[end].is_uppercase() {
                    end += 1;
                }
                if end > i + 1 && end < chars.len() && chars[end].is_lowercase() {
                    end -= 1;
                }
            }
        } else if c.is_lowercase() {
            while end < chars.len() && chars[end].is_lowercase() {
                end += 1;
            }
        } else if c.is_ascii_digit() {
            while end < chars.len() && chars[end].is_ascii_digit() {
                end += 1;
            }
        } else {
            while end < chars.len()
                && !spaces[end]
                && !chars[end].is_lowercase()
                && !chars[end].is_uppercase()
                && !chars[end].is_ascii_digit()
                && number_end(&chars, end).is_none()
            {
                end += 1;
            }
        }
        out.push(Token {
            start: cells[i].0,
            end: cells[end - 1].0,
            space: spaces[i],
        });
        i = end;
    }
    out
}

/// Valid color, hex, octal and binary literals stay together.
fn number_end(chars: &[char], start: usize) -> Option<usize> {
    let (digits, radix) = if chars[start] == '#' {
        (start + 1, 16)
    } else if chars[start] == '0' && (start == 0 || !default_keyword(chars[start - 1])) {
        let radix = match chars.get(start + 1)? {
            'x' | 'X' => 16,
            'o' | 'O' => 8,
            'b' | 'B' => 2,
            _ => return None,
        };
        (start + 2, radix)
    } else {
        return None;
    };
    let mut end = digits;
    while end < chars.len() && chars[end].is_digit(radix) {
        end += 1;
    }
    (end > digits && (end == chars.len() || !default_keyword(chars[end]))).then_some(end)
}

impl Text {
    fn subword_tokens(&mut self, vt: &Terminal<'_, '_>, y: u32) -> &[Token] {
        let first = self.line_start(vt, y);
        if !self.subwords.contains_key(&first) {
            let (cells, _) = self.line_cells(vt, Pos::new(0, first));
            self.subwords.insert(first, tokens(&cells));
        }
        &self.subwords[&first]
    }

    pub(super) fn subword_motion(
        &mut self,
        vt: &Terminal<'_, '_>,
        p: Pos,
        back: bool,
        end: bool,
    ) -> Pos {
        let mut y = p.y;
        loop {
            let tokens = self.subword_tokens(vt, y);
            let position = |t: &Token| if end { t.end } else { t.start };
            let valid = |t: &&Token| {
                !t.space
                    && if back {
                        position(t) < p
                    } else {
                        position(t) > p
                    }
            };
            let found = if back {
                tokens.iter().rev().find(valid)
            } else {
                tokens.iter().find(valid)
            };
            if let Some(t) = found {
                return position(t);
            }
            if y != p.y && tokens.is_empty() && (back || !end) {
                return Pos::new(0, y);
            }
            if back {
                let first = self.line_start(vt, y);
                if first == 0 {
                    return Pos::new(0, 0);
                }
                y = first - 1;
            } else {
                let last = self.line_end(vt, y);
                if last + 1 >= self.total {
                    return self.line_last(vt, y);
                }
                y = last + 1;
            }
        }
    }

    pub(super) fn subword_object(
        &mut self,
        vt: &Terminal<'_, '_>,
        p: Pos,
        around: bool,
        count: u32,
    ) -> Option<(Pos, Pos)> {
        let tokens = self.subword_tokens(vt, p.y);
        let first = tokens.iter().position(|t| t.start <= p && p <= t.end)?;
        let mut last = first;
        let mut remaining = count.max(1);
        loop {
            if !around || !tokens[last].space {
                remaining -= 1;
            }
            if remaining == 0 || last + 1 == tokens.len() {
                break;
            }
            last += 1;
        }
        let mut first = first;
        if around {
            if last + 1 < tokens.len() && tokens[last + 1].space {
                last += 1;
            } else if first > 0 && tokens[first - 1].space {
                first -= 1;
            }
        }
        Some((tokens[first].start, tokens[last].end))
    }
}
