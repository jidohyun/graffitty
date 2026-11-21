//! Font- and GUI-independent terminal state. The frontend alone shapes glyphs.
pub use graffitty_protocol::{Cell, Frame};
use libghostty_vt::{
    Terminal,
    render::{CellIterator, CursorVisualStyle, RenderState, RowIterator},
    screen::CellWide,
    style::{RgbColor, Underline},
    terminal::{Mode, ModeKind},
};

pub const INPUT_MODES: [u16; 13] = [
    1, 9, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 2004,
];
fn hex(c: RgbColor) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}
pub fn snapshot(
    vt: &Terminal<'_, '_>,
    columns: u16,
    rows: u16,
    exited: bool,
) -> Result<Frame, Box<dyn std::error::Error>> {
    let mut render = RenderState::new()?;
    let mut row_iter = RowIterator::new()?;
    let mut cell_iter = CellIterator::new()?;
    let view = render.update(vt)?;
    let colors = view.colors()?;
    let mut frame = Frame {
        columns,
        rows,
        foreground: hex(colors.foreground),
        background: hex(colors.background),
        title: String::from_utf8_lossy(vt.title().unwrap_or(b"")).into_owned(),
        exited,
        font_size: 18,
        cursor: vec![],
        cursor_style: match view.cursor_visual_style()? {
            CursorVisualStyle::Bar => 6,
            CursorVisualStyle::Underline => 4,
            _ => 2,
        } - u8::from(view.cursor_blinking()?),
        input_modes: INPUT_MODES
            .into_iter()
            .filter(|n| vt.mode(Mode::new(*n, ModeKind::Dec)).unwrap_or(false))
            .collect(),
        kitty_keys: vt
            .kitty_keyboard_flags()
            .map(|f| f.bits() as u32)
            .unwrap_or(0),
        lines: vec![],
    };
    if !exited
        && view.cursor_visible()?
        && let Some(pos) = view.cursor_viewport()?
    {
        frame.cursor = vec![pos.x.saturating_sub(pos.at_wide_tail as u16), pos.y];
    }
    let mut ri = row_iter.update(&view)?;
    while let Some(row) = ri.next() {
        let mut ci = cell_iter.update(row)?;
        let mut line = vec![];
        let mut column = 0;
        while let Some(cell) = ci.next() {
            let mut fg = cell.fg_color()?.unwrap_or(colors.foreground);
            let mut bg = cell.bg_color()?.unwrap_or(colors.background);
            let style = cell.style()?;
            if style.inverse {
                std::mem::swap(&mut fg, &mut bg);
            }
            let mut chars = vec!['\0'; cell.graphemes_len()? as usize];
            let text = if !chars.is_empty() && !style.invisible {
                cell.graphemes_buf(&mut chars)?;
                chars.iter().collect()
            } else {
                String::new()
            };
            let bits = style.bold as u8
                | (style.italic as u8) << 1
                | (style.faint as u8) << 2
                | ((style.underline != Underline::None) as u8) << 3
                | (style.strikethrough as u8) << 4;
            let width = if matches!(cell.raw_cell().and_then(|c| c.wide()), Ok(CellWide::Wide)) {
                2
            } else {
                1
            };
            if !text.is_empty() || hex(bg) != frame.background {
                line.push(Cell(column, width, text, hex(fg), hex(bg), bits));
            }
            column += 1;
        }
        frame.lines.push(line);
    }
    Ok(frame)
}
fn sgr(color: &str, foreground: bool) -> String {
    let rgb = u32::from_str_radix(&color[1..], 16).unwrap_or(0);
    format!(
        "{};2;{};{};{}",
        if foreground { 38 } else { 48 },
        rgb >> 16,
        (rgb >> 8) & 255,
        rgb & 255
    )
}
pub fn presentation(frame: &Frame, old: Option<&Frame>) -> (bool, Vec<u8>) {
    let reset = old.is_none_or(|f| f.columns != frame.columns || f.rows != frame.rows);
    let mut text = format!(
        "\x1b[?6l\x1b[4l\x1b[?7l\x1b[0m\x1b]10;{}\x07\x1b]11;{}\x07",
        frame.foreground, frame.background
    );
    if reset {
        text.push_str("\x1b[2J");
    }
    for (row, line) in frame.lines.iter().enumerate() {
        if !reset && old.and_then(|f| f.lines.get(row)) == Some(line) {
            continue;
        }
        text.push_str(&format!("\x1b[{};1H\x1b[0m\x1b[2K", row + 1));
        let mut next = 0;
        let mut previous = String::new();
        for Cell(col, width, glyph, fg, bg, bits) in line {
            if glyph.is_empty() && *col < next {
                continue;
            }
            let mut style = format!(
                "0;{};{}",
                if *fg == frame.foreground {
                    "39".into()
                } else {
                    sgr(fg, true)
                },
                if *bg == frame.background {
                    "49".into()
                } else {
                    sgr(bg, false)
                }
            );
            for (bit, code) in [(1, 1), (2, 3), (4, 2), (8, 4), (16, 9)] {
                if bits & bit != 0 {
                    style.push_str(&format!(";{code}"));
                }
            }
            if *col != next {
                text.push_str(&format!("\x1b[{};{}H", row + 1, col + 1));
            }
            if style != previous {
                text.push_str(&format!("\x1b[{style}m"));
            }
            text.push_str(if glyph.is_empty() { " " } else { glyph });
            previous = style;
            next = col + width;
        }
    }
    text.push_str(&format!("\x1b[0m\x1b[?7h\x1b[{} q", frame.cursor_style));
    if frame.cursor.len() == 2 {
        text.push_str(&format!(
            "\x1b[{};{}H\x1b[?25h",
            frame.cursor[1] + 1,
            frame.cursor[0] + 1
        ));
    } else {
        text.push_str("\x1b[?25l");
    }
    for mode in INPUT_MODES {
        text.push_str(&format!(
            "\x1b[?{}{}",
            mode,
            if frame.input_modes.contains(&mode) {
                'h'
            } else {
                'l'
            }
        ));
    }
    text.push_str(&format!("\x1b[={}u", frame.kitty_keys));
    (reset, text.into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cursor_only_changes_roundtrip() {
        let mut server = crate::new_vt(80, 24, 100).unwrap();
        let mut client = crate::new_vt(80, 24, 100).unwrap();
        let mut previous = None;
        for style in [6, 2, 5, 1, 4, 3] {
            server.vt_write(format!("\x1b[{style} q").as_bytes());
            let frame = snapshot(&server, 80, 24, false).unwrap();
            client.vt_write(&presentation(&frame, previous.as_ref()).1);
            assert_eq!(
                snapshot(&client, 80, 24, false).unwrap().cursor_style,
                style
            );
            client.vt_write(&crate::checkpoint::capture(&server).unwrap());
            assert_eq!(
                snapshot(&client, 80, 24, false).unwrap().cursor_style,
                style
            );
            previous = Some(frame);
        }
    }
    #[test]
    fn unicode_styles_and_delta_roundtrip() {
        let mut server = crate::new_vt(80, 24, 100).unwrap();
        let mut client = crate::new_vt(80, 24, 100).unwrap();
        server.vt_write("\x1b[31m한글 e\u{301} 🐈\x1b[0m\r\nsecond\x1b[?2004h".as_bytes());
        let first = snapshot(&server, 80, 24, false).unwrap();
        client.vt_write(&presentation(&first, None).1);
        let replay = snapshot(&client, 80, 24, false).unwrap();
        assert_eq!(
            serde_json::to_value(&first).unwrap(),
            serde_json::to_value(&replay).unwrap()
        );
        server.vt_write(b"\x1b[2;1H\x1b[2Kreplacement");
        let next = snapshot(&server, 80, 24, false).unwrap();
        let (reset, delta) = presentation(&next, Some(&first));
        assert!(!reset);
        client.vt_write(&delta);
        assert_eq!(
            serde_json::to_value(&next).unwrap(),
            serde_json::to_value(snapshot(&client, 80, 24, false).unwrap()).unwrap()
        );
    }
}
