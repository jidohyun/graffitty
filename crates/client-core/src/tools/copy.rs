//! Native adapter for the shared Vim copy mode (`terminal_core::copy_mode`),
//! matching the Godot terminal: key translation, the painted overlay (search
//! matches, flash backdrop and labels, copy cursor, status line) and state.
use graffitty_terminal_core::{
    copy_mode::{CopyMode, Input, Key},
    screen::{Cell, Frame},
    vt::Terminal,
};
use serde_json::{Value, json};

/// Godot `copy_input`: named keys keep modifiers; letters follow the physical
/// key (a Korean layout's jamo map back to QWERTY) except in a text prompt.
pub(super) fn input(value: &Value, text: bool, physical: bool) -> Option<Input> {
    if value["meta"] == true {
        return None;
    }
    let key = value["key"].as_str()?;
    let (ctrl, shift, alt) = (value["ctrl"] == true, value["shift"] == true, value["alt"] == true);
    let named = match key {
        "Escape" | "Esc" => Some(Key::Escape),
        "Enter" | "Return" => Some(Key::Enter),
        "Backspace" => Some(Key::Backspace),
        "Tab" => Some(Key::Tab),
        "ArrowUp" | "Up" => Some(Key::Up),
        "ArrowDown" | "Down" => Some(Key::Down),
        "ArrowLeft" | "Left" => Some(Key::Left),
        "ArrowRight" | "Right" => Some(Key::Right),
        "PageUp" => Some(Key::PageUp),
        "PageDown" => Some(Key::PageDown),
        "Home" => Some(Key::Home),
        "End" => Some(Key::End),
        "F3" => Some(Key::F3),
        _ => None,
    };
    if let Some(key) = named {
        return Some(Input { key, ctrl, shift });
    }
    let mut chars = key.chars();
    let first = chars.next()?;
    let c = if chars.next().is_some() {
        if !key.eq_ignore_ascii_case("space") {
            return None;
        }
        ' '
    } else if ctrl && ('\u{1}'..='\u{1a}').contains(&first) {
        // Some platforms report Ctrl+letter as its control character.
        char::from(b'a' + first as u8 - 1)
    } else {
        first
    };
    if c.is_control() {
        return None;
    }
    if text && !ctrl {
        return Some(Input { key: Key::Char(c), ctrl, shift });
    }
    if alt {
        return None;
    }
    let c = if physical { qwerty(c) } else { c };
    let c = if c.is_ascii_lowercase() && shift { c.to_ascii_uppercase() } else { c };
    Some(Input { key: Key::Char(c), ctrl, shift })
}

/// Dubeolsik jamo to the QWERTY letter on the same physical key, as Godot
/// reads Vim keys from keycodes while a Hangul input method is active.
fn qwerty(c: char) -> char {
    const MAP: [(char, char); 33] = [
        ('ㅂ', 'q'), ('ㅈ', 'w'), ('ㄷ', 'e'), ('ㄱ', 'r'), ('ㅅ', 't'), ('ㅛ', 'y'),
        ('ㅕ', 'u'), ('ㅑ', 'i'), ('ㅐ', 'o'), ('ㅔ', 'p'), ('ㅁ', 'a'), ('ㄴ', 's'),
        ('ㅇ', 'd'), ('ㄹ', 'f'), ('ㅎ', 'g'), ('ㅗ', 'h'), ('ㅓ', 'j'), ('ㅏ', 'k'),
        ('ㅣ', 'l'), ('ㅋ', 'z'), ('ㅌ', 'x'), ('ㅊ', 'c'), ('ㅍ', 'v'), ('ㅠ', 'b'),
        ('ㅜ', 'n'), ('ㅡ', 'm'), ('ㅃ', 'Q'), ('ㅉ', 'W'), ('ㄸ', 'E'), ('ㄲ', 'R'),
        ('ㅆ', 'T'), ('ㅒ', 'O'), ('ㅖ', 'P'),
    ];
    MAP.iter().find(|(jamo, _)| *jamo == c).map_or(c, |(_, key)| *key)
}

/// Godot's default modal binding: Cmd+C on macOS, Ctrl+Shift+C elsewhere.
pub(super) fn copy_chord(value: &Value) -> bool {
    let key = value["key"].as_str().unwrap_or("");
    let (ctrl, shift, alt, meta) = (
        value["ctrl"] == true,
        value["shift"] == true,
        value["alt"] == true,
        value["meta"] == true,
    );
    key.eq_ignore_ascii_case("c") && !alt && (meta && !ctrl || ctrl && shift && !meta)
}

fn top(vt: &Terminal<'_, '_>) -> u64 {
    vt.scrollbar().map_or(0, |s| s.offset)
}

/// Automation state: what Godot's get_ui_state reports, plus the painted cells.
pub(super) fn view(copy: &CopyMode, vt: &Terminal<'_, '_>, rows: u16, columns: u16) -> Value {
    let top = top(vt);
    json!({
        "flash_active": copy.flash_active(),
        "wants_text": copy.wants_text(),
        "top": top,
        "cursor": copy.cursor_viewport(vt).map(|(x, y, wide)| json!([x, y, wide])),
        "labels": copy.labels(top, rows).into_iter().map(|(row, column, label)|
            json!({"row": row, "column": column, "label": label.to_string()})).collect::<Vec<_>>(),
        "highlights": copy.highlights(top, rows, columns).into_iter().map(|(row, from, to, current)|
            json!([row, from, to, current])).collect::<Vec<_>>(),
        "selection": super::selected(vt).unwrap_or_default(),
    })
}

/// The selection overlay yields to copy mode: Flash hides it, and the cursor
/// and status line paint over it as Godot's canvas layers do.
pub(super) fn mask_spans(
    flash: bool,
    cursor: Option<(u16, u16, bool)>,
    status_row: u16,
    spans: &mut Vec<[u16; 3]>,
) {
    if flash {
        spans.clear();
        return;
    }
    spans.retain(|[row, _, _]| *row != status_row);
    let Some((x, y, wide)) = cursor else {
        return;
    };
    let last = x + u16::from(wide);
    let mut out = Vec::with_capacity(spans.len() + 1);
    for &[row, start, end] in spans.iter() {
        if row != y || end < x || start > last {
            out.push([row, start, end]);
            continue;
        }
        if start < x {
            out.push([row, start, x - 1]);
        }
        if end > last {
            out.push([row, last + 1, end]);
        }
    }
    *spans = out;
}

fn hex(rgb: [u8; 3]) -> String {
    format!("#{:02x}{:02x}{:02x}", rgb[0], rgb[1], rgb[2])
}

fn rgb(text: &str) -> [u8; 3] {
    let value = u32::from_str_radix(text.trim_start_matches('#'), 16).unwrap_or(0);
    [(value >> 16) as u8, (value >> 8) as u8, value as u8]
}

/// Keep the original match ink legible, including dark ANSI colors.
fn flash_match_background(fg: [u8; 3]) -> [u8; 3] {
    let linear = |c: u8| {
        let c = f32::from(c) / 255.;
        if c <= 0.04045 { c / 12.92 } else { ((c + 0.055) / 1.055).powf(2.4) }
    };
    let luminance = 0.2126 * linear(fg[0]) + 0.7152 * linear(fg[1]) + 0.0722 * linear(fg[2]);
    if luminance > 0.18 { [18, 22, 30] } else { [230, 235, 245] }
}

/// East Asian wide and emoji codepoints take two cells on the status line.
fn wide(c: char) -> bool {
    matches!(c as u32,
        0x1100..=0x115f | 0x2e80..=0x303e | 0x3041..=0x33ff | 0x3400..=0x4dbf
        | 0x4e00..=0x9fff | 0xa000..=0xa4cf | 0xac00..=0xd7a3 | 0xf900..=0xfaff
        | 0xfe30..=0xfe4f | 0xff00..=0xff60 | 0xffe0..=0xffe6 | 0x1f300..=0x1f64f
        | 0x1f900..=0x1f9ff | 0x20000..=0x3fffd)
}

/// One row as a column-indexed cell table.
struct Row(Vec<Option<Cell>>);

impl Row {
    fn new(cells: Vec<Cell>, columns: u16) -> Self {
        let mut row = vec![None; usize::from(columns)];
        for cell in cells {
            if let Some(slot) = row.get_mut(usize::from(cell.0)) {
                *slot = Some(cell);
            }
        }
        Self(row)
    }
    fn cell(&mut self, column: u16, default_fg: &str, default_bg: &str) -> Option<&mut Cell> {
        let slot = self.0.get_mut(usize::from(column))?;
        Some(slot.get_or_insert_with(|| Cell(column, 1, String::new(), default_fg.into(), default_bg.into(), 0)))
    }
    fn finish(self) -> Vec<Cell> {
        self.0.into_iter().flatten().collect()
    }
}

/// Paint copy mode into the viewport snapshot the same way Godot repaints its
/// canvas: matches (current orange), the copy cursor, the Flash backdrop,
/// Flash labels and the status line on the bottom row.
pub(super) fn decorate(
    copy: &CopyMode,
    vt: &Terminal<'_, '_>,
    frame: &mut Frame,
    rows: u16,
    selection: &[[u16; 3]],
    status: &str,
) {
    let columns = frame.columns;
    if columns == 0 {
        return;
    }
    let rows = rows.min(frame.lines.len() as u16);
    let top = top(vt);
    // The terminal's own cursor hides while copy mode owns the screen.
    frame.cursor.clear();
    let flash = copy.flash_active();
    let mut marks = vec![0u8; usize::from(columns) * usize::from(rows)];
    for (row, from, to, current) in copy.highlights(top, rows, columns) {
        for column in from..to.min(columns) {
            let mark = &mut marks[usize::from(row) * usize::from(columns) + usize::from(column)];
            *mark = (*mark).max(if current { 2 } else { 1 });
        }
    }
    let cursor = copy.cursor_viewport(vt);
    let selected = |row: u16, column: u16| {
        selection.iter().any(|[r, start, end]| *r == row && (*start..=*end).contains(&column))
    };
    let background = rgb(&frame.background);
    let gray = if background.iter().map(|c| u16::from(*c)).sum::<u16>() > 384 { 160 } else { 100 };
    let gray = hex([gray; 3]);
    let foreground = frame.foreground.clone();
    for (y, line) in frame.lines.iter_mut().enumerate().take(usize::from(rows)) {
        let y = y as u16;
        let marked = |column: u16| marks[usize::from(y) * usize::from(columns) + usize::from(column)];
        let has_cursor = !flash && cursor.is_some_and(|(_, row, _)| row == y);
        if !flash && !has_cursor && (0..columns).all(|column| marked(column) == 0) {
            continue;
        }
        let mut row = Row::new(std::mem::take(line), columns);
        for column in 0..columns {
            let mark = marked(column);
            if flash {
                if mark == 0 {
                    // Flash backdrop: quiet gray ink without colors or selection.
                    if let Some(Some(cell)) = row.0.get_mut(usize::from(column)) {
                        cell.3 = gray.clone();
                        cell.4 = frame.background.clone();
                        cell.5 |= 4;
                    }
                } else if let Some(cell) = row.cell(column, &foreground, &frame.background) {
                    cell.4 = hex(flash_match_background(rgb(&cell.3)));
                    cell.5 &= !4;
                }
                continue;
            }
            if mark > 0 && !selected(y, column) {
                if let Some(cell) = row.cell(column, &foreground, &frame.background) {
                    cell.3 = "#000000".into();
                    cell.4 = hex(if mark == 2 { [255, 158, 59] } else { [229, 192, 123] });
                    cell.5 &= !4;
                }
            }
        }
        if let Some((x, _, wide)) = cursor.filter(|_| has_cursor) {
            for column in x..=x + u16::from(wide) {
                if let Some(cell) = row.cell(column, &foreground, &frame.background) {
                    cell.3 = "#000000".into();
                    cell.4 = hex([64, 200, 224]);
                    cell.5 &= !4;
                }
            }
        }
        *line = row.finish();
    }
    // Status line, then jump labels above it, as Godot's overlay layer.
    if let Some(line) = rows.checked_sub(1).and_then(|row| frame.lines.get_mut(usize::from(row))) {
        let (ink, shade) = ("#ffffff".to_owned(), hex([13, 13, 13]));
        let mut cells = Vec::with_capacity(usize::from(columns));
        let mut column = 0;
        for c in status.chars() {
            let span = if wide(c) { 2 } else { 1 };
            if column + span > columns {
                break;
            }
            cells.push(Cell(column, span, c.to_string(), ink.clone(), shade.clone(), 0));
            column += span;
        }
        while column < columns {
            cells.push(Cell(column, 1, String::new(), ink.clone(), shade.clone(), 0));
            column += 1;
        }
        *line = cells;
    }
    for (row, column, label) in copy.labels(top, rows) {
        let Some(line) = frame.lines.get_mut(usize::from(row)) else { continue };
        let mut cells = Row::new(std::mem::take(line), columns);
        if let Some(cell) = cells.cell(column, &foreground, &frame.background) {
            *cell = Cell(column, 1, label.to_string(), "#000000".into(), hex([255, 204, 51]), 0);
        }
        *line = cells.finish();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_follow_godot_copy_input() {
        let key = |value: Value| input(&value, false, true).map(|i| (i.key, i.ctrl, i.shift));
        assert_eq!(key(json!({"key":"v","ctrl":true})), Some((Key::Char('v'), true, false)));
        assert_eq!(key(json!({"key":"V","ctrl":true})), Some((Key::Char('V'), true, false)));
        assert_eq!(key(json!({"key":"\u{16}","ctrl":true})), Some((Key::Char('v'), true, false)));
        assert_eq!(key(json!({"key":"ㅏ"})), Some((Key::Char('k'), false, false)));
        assert_eq!(key(json!({"key":"ㄲ"})), Some((Key::Char('R'), false, false)));
        assert_eq!(key(json!({"key":"g","shift":true})), Some((Key::Char('G'), false, true)));
        assert_eq!(key(json!({"key":"F3","shift":true})), Some((Key::F3, false, true)));
        assert_eq!(key(json!({"key":"Space"})), Some((Key::Char(' '), false, false)));
        assert_eq!(key(json!({"key":"c","meta":true})), None);
        let typed = input(&json!({"key":"ㅏ"}), true, true).unwrap();
        assert_eq!(typed.key, Key::Char('ㅏ'), "A text prompt keeps typed text");
        assert!(copy_chord(&json!({"key":"C","ctrl":true,"shift":true})));
        assert!(copy_chord(&json!({"key":"c","meta":true})));
        assert!(!copy_chord(&json!({"key":"c","ctrl":true})));
    }

    #[test]
    fn cursor_and_status_row_cut_the_selection_overlay() {
        let mut spans = vec![[1, 0, 9], [3, 0, 4]];
        mask_spans(false, Some((4, 1, true)), 3, &mut spans);
        assert_eq!(spans, vec![[1, 0, 3], [1, 6, 9]]);
        mask_spans(true, None, 3, &mut spans);
        assert!(spans.is_empty());
    }
}
