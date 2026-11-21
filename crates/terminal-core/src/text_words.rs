//! Terminal word and line selection over plain text lines.
//!
//! Read-only text views select the same way as a terminal: a double click takes
//! a Ghostty word, dragging extends word by word, and a triple click takes
//! the line without its surrounding blanks.

/// Ghostty's default word boundaries: `` \t'"│`|:;,()[]{}<>$`` and NUL.
pub const DEFAULT_WORD_BOUNDARIES: &[char] = &[
    '\0', ' ', '\t', '\'', '"', '│', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$',
];

/// Blanks trimmed from a line selection.
const LINE_WHITESPACE: &[char] = &['\0', ' ', '\t'];

/// A selection end in a text view: line and character column.
pub type Position = (usize, usize);

/// The word around `column` as `start..end` columns.
///
/// A word is the longest run whose characters are all boundaries or all not,
/// as Ghostty selects it. Past the end of the line counts as a boundary, so a
/// click there takes the line's trailing blanks (possibly none).
pub fn word_range(line: &[char], column: usize, boundaries: &[char]) -> (usize, usize) {
    let is_boundary = |c: char| boundaries.contains(&c);
    if column >= line.len() {
        let start = line.iter().rposition(|&c| !is_boundary(c)).map_or(0, |i| i + 1);
        return (start, line.len());
    }
    let expect = is_boundary(line[column]);
    let start = line[..column].iter().rposition(|&c| is_boundary(c) != expect).map_or(0, |i| i + 1);
    let end = line[column..].iter().position(|&c| is_boundary(c) != expect).map_or(line.len(), |i| column + i);
    (start, end)
}

/// The line's columns without leading and trailing blanks; a blank line
/// selects nothing at its start.
pub fn line_range(line: &[char]) -> (usize, usize) {
    let Some(first) = line.iter().position(|c| !LINE_WHITESPACE.contains(c)) else {
        return (0, 0);
    };
    let last = line.iter().rposition(|c| !LINE_WHITESPACE.contains(c)).unwrap_or(first);
    (first, last + 1)
}

/// The selection while dragging from the `anchor` span to the `current` one,
/// each given as its start and end. Both spans stay wholly selected, so the
/// selection grows and shrinks a whole word (or line) at a time.
pub fn extend(anchor: (Position, Position), current: (Position, Position)) -> (Position, Position) {
    if current.0 < anchor.0 {
        (current.0, anchor.1)
    } else {
        (anchor.0, current.1.max(anchor.1))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chars(text: &str) -> Vec<char> {
        text.chars().collect()
    }

    fn word(text: &str, column: usize) -> String {
        let line = chars(text);
        let (start, end) = word_range(&line, column, DEFAULT_WORD_BOUNDARIES);
        line[start..end].iter().collect()
    }

    #[test]
    fn words_follow_ghostty_boundaries() {
        let text = "cd ~/project/godot-ghostty; echo $HOME";
        assert_eq!(word(text, 5), "~/project/godot-ghostty", "paths and hyphens stay whole");
        assert_eq!(word(text, 0), "cd");
        assert_eq!(word(text, 2), " ");
        assert_eq!(word(text, 26), "; ", "a boundary click takes the run of boundaries");
        assert_eq!(word(text, 33), " $", "adjacent boundaries form one run");
        assert_eq!(word(text, 35), "HOME");
    }

    #[test]
    fn past_the_end_takes_trailing_blanks() {
        assert_eq!(word("value  ", 20), "  ");
        assert_eq!(word("value", 9), "");
        assert_eq!(word("", 0), "");
    }

    #[test]
    fn configured_boundaries_replace_the_defaults() {
        let line = chars("a/b c");
        assert_eq!(word_range(&line, 0, &['/', ' ']), (0, 1));
    }

    #[test]
    fn unicode_columns_are_characters() {
        assert_eq!(word("정보 표시", 1), "정보");
        assert_eq!(word("a│b", 2), "b");
    }

    #[test]
    fn lines_trim_surrounding_blanks() {
        assert_eq!(line_range(&chars("  Build 42\t")), (2, 10));
        assert_eq!(line_range(&chars(" \t ")), (0, 0));
    }

    #[test]
    fn dragging_keeps_both_words_selected() {
        let anchor = ((2, 4), (2, 9));
        assert_eq!(extend(anchor, ((2, 12), (2, 15))), ((2, 4), (2, 15)), "forward");
        assert_eq!(extend(anchor, ((1, 0), (1, 3))), ((1, 0), (2, 9)), "backward keeps the anchor's end");
        assert_eq!(extend(anchor, ((2, 4), (2, 9))), anchor, "on the anchor");
        assert_eq!(extend(anchor, ((2, 6), (2, 7))), anchor, "inside the anchor");
    }
}
