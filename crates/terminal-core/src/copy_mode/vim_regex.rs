//! Translate Vim's search syntax to the bounded regex executor used by copy mode.
//! The default is `magic` and case-sensitive, as in `nvim --clean`.
use fancy_regex::{Regex, RegexBuilder};

#[derive(Clone, Copy, PartialEq)]
enum Magic {
    Very,
    Normal,
    No,
    Literal,
}

pub(super) fn compile(pattern: &str) -> Option<Regex> {
    let mut source = String::new();
    let mut chars = pattern.chars().peekable();
    let mut magic = Magic::Normal;
    let mut insensitive = false;
    while let Some(c) = chars.next() {
        let escaped = c == '\\';
        let c = if escaped { chars.next()? } else { c };
        if escaped {
            match c {
                'v' => {
                    magic = Magic::Very;
                    continue;
                }
                'm' => {
                    magic = Magic::Normal;
                    continue;
                }
                'M' => {
                    magic = Magic::No;
                    continue;
                }
                'V' => {
                    magic = Magic::Literal;
                    continue;
                }
                'c' => {
                    insensitive = true;
                    continue;
                }
                'C' => {
                    insensitive = false;
                    continue;
                }
                // Vim's character classes are ASCII, unlike Rust's Unicode \d/\w.
                'd' => {
                    source.push_str("[0-9]");
                    continue;
                }
                'D' => {
                    source.push_str("[^0-9]");
                    continue;
                }
                's' => {
                    source.push_str("[ \\t]");
                    continue;
                }
                'S' => {
                    source.push_str("[^ \\t]");
                    continue;
                }
                'w' => {
                    source.push_str("[0-9A-Za-z_]");
                    continue;
                }
                'W' => {
                    source.push_str("[^0-9A-Za-z_]");
                    continue;
                }
                'h' => {
                    source.push_str("[A-Za-z_]");
                    continue;
                }
                'H' => {
                    source.push_str("[^A-Za-z_]");
                    continue;
                }
                'a' => {
                    source.push_str("[A-Za-z]");
                    continue;
                }
                'A' => {
                    source.push_str("[^A-Za-z]");
                    continue;
                }
                'l' => {
                    source.push_str("[a-z]");
                    continue;
                }
                'L' => {
                    source.push_str("[^a-z]");
                    continue;
                }
                'u' => {
                    source.push_str("[A-Z]");
                    continue;
                }
                'U' => {
                    source.push_str("[^A-Z]");
                    continue;
                }
                'x' => {
                    source.push_str("[0-9A-Fa-f]");
                    continue;
                }
                'X' => {
                    source.push_str("[^0-9A-Fa-f]");
                    continue;
                }
                'o' => {
                    source.push_str("[0-7]");
                    continue;
                }
                'O' => {
                    source.push_str("[^0-7]");
                    continue;
                }
                '<' => {
                    source.push_str("(?<!\\w)(?=\\w)");
                    continue;
                }
                '>' => {
                    source.push_str("(?<=\\w)(?!\\w)");
                    continue;
                }
                'n' | 'r' | 't' | '1'..='9' => {
                    source.push('\\');
                    source.push(c);
                    continue;
                }
                // Unsupported Vim atoms must not silently become a different search.
                '%' | '@' | '_' | 'z' => return None,
                _ => {}
            }
        }
        let special = match magic {
            Magic::Very => !escaped && !c.is_alphanumeric() && c != '_',
            Magic::Normal => {
                if escaped {
                    "()|+?={}".contains(c)
                } else {
                    ".*[^$".contains(c)
                }
            }
            Magic::No => {
                if escaped {
                    ".*[()|+?={}".contains(c)
                } else {
                    "^$".contains(c)
                }
            }
            Magic::Literal => escaped && ".*[()|+?={}^$".contains(c),
        };
        if special && c == '[' {
            source.push('[');
            let mut first = true;
            let mut closed = false;
            while let Some(c) = chars.next() {
                if c == ']' && !first {
                    source.push(']');
                    closed = true;
                    break;
                }
                if c == '\\' {
                    let c = chars.next()?;
                    if !"nrt\\]^-".contains(c) {
                        source.push(c);
                    } else {
                        source.push('\\');
                        source.push(c);
                    }
                } else {
                    source.push(c);
                }
                if c != '^' {
                    first = false;
                }
            }
            if !closed {
                return None;
            }
        } else if special && c == '{' {
            let mut bounds = String::new();
            let lazy = chars.next_if_eq(&'-').is_some();
            loop {
                match chars.next()? {
                    '}' => break,
                    c @ ('0'..='9' | ',') => bounds.push(c),
                    _ => return None,
                }
            }
            if bounds.is_empty() {
                source.push('*');
            } else {
                source.push('{');
                source.push_str(&bounds);
                source.push('}');
            }
            if lazy {
                source.push('?');
            }
        } else if special && ".*^$()|+?=".contains(c) {
            source.push(if c == '=' { '?' } else { c });
        } else {
            if "\\.^$|?*+()[]{}#-&~ ".contains(c) {
                source.push('\\');
            }
            source.push(c);
        }
    }
    if insensitive {
        source.insert_str(0, "(?i)");
    }
    RegexBuilder::new(&source)
        .backtrack_limit(100_000)
        .build()
        .ok()
}
