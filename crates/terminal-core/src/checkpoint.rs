//! Reconstruct retained VT state using libghostty's serializer.
use crate::Error;
use libghostty_vt::{
    Terminal,
    fmt::{Extras, Format, Formatter},
    selection::Selection,
    terminal::{Point, PointCoordinate},
};

pub fn capture(vt: &Terminal<'_, '_>) -> Result<Vec<u8>, Error> {
    capture_impl(vt, true)
}

/// Format physical rows, then restore soft wraps and cell hyperlinks.
///
/// The pinned formatter omits cell OSC 8 links, and its unwrapping can carry
/// erased trailing cells across a blank row into the next line.
///
/// Keeping row boundaries explicit lets us map every grapheme to its source
/// cell without that drift.
fn replay_body(vt: &Terminal<'_, '_>, body: &[u8]) -> Result<Vec<u8>, Error> {
    use libghostty_vt::screen::{CellWide, CellSemanticContent, RowSemanticPrompt};
    let point = |x, y| vt.grid_ref(Point::Screen(PointCoordinate { x, y }));
    let mut needs_replay = false;
    for y in 0..vt.total_rows()? as u32 {
        let row = point(0, y)?.row()?;
        if row.is_wrapped()? || row.has_hyperlink()? || row.semantic_prompt()? != RowSemanticPrompt::None {
            needs_replay = true;
            break;
        }
    }
    if !needs_replay {
        return Ok(body.to_vec());
    }
    let body = expand_cursor_forward(body);
    let body = body.as_slice();
    let cols = vt.cols()?;
    let (mut x, mut y, mut offset) = (0, 0, 0);
    let mut out = Vec::with_capacity(body.len());
    let mut active = Vec::new();
    let mut uri = vec![0; 512];
    let mut chars = vec!['\0'; 16];
    let mut cluster = String::new();
    let mut semantic = CellSemanticContent::Output;
    while offset < body.len() {
        match body[offset] {
            b'\x1b' => {
                // The formatter's body emits SGR escapes and, since Ghostty
                // 521cf2c, OSC 8 cell links. Links are rebuilt per cell
                // below, so drop the formatter's copy.
                //
                // Other state extras (cursor movement, margins, etc.) are
                // outside this body.
                if body[offset + 1..].starts_with(b"]8;") {
                    let rest = &body[offset..];
                    let end = rest
                        .windows(2)
                        .position(|w| w == b"\x1b\\")
                        .map(|n| n + 2)
                        .into_iter()
                        .chain(rest.iter().position(|b| *b == 0x07).map(|n| n + 1))
                        .min()
                        .ok_or("Incomplete formatter hyperlink")?;
                    offset += end;
                    continue;
                }
                if body.get(offset + 1) != Some(&b'[') {
                    return Err("Unexpected formatter body escape".into());
                }
                let end = body[offset + 2..]
                    .iter()
                    .position(|b| (0x40..=0x7e).contains(b))
                    .map(|n| offset + 3 + n)
                    .ok_or("Incomplete formatter escape")?;
                // Background-only cells arrive as an erase and a step over
                // it (`CSI n X CSI n C`): they stay empty cells carrying the
                // background, so pass both through and skip their columns.
                if body[end - 1] == b'X' {
                    let (count, step) = erased_run(&body[offset..]).ok_or("Unexpected formatter body erase")?;
                    out.extend_from_slice(&body[offset..offset + step]);
                    offset += step;
                    x += count;
                    continue;
                }
                if body[end - 1] != b'm' {
                    return Err("Unexpected formatter body CSI".into());
                }
                out.extend_from_slice(&body[offset..end]);
                offset = end;
                continue;
            }
            b'\r' => {
                if body.get(offset + 1) != Some(&b'\n') {
                    return Err("Unexpected formatter line ending".into());
                }
                if point(0, y)?.row()?.is_wrapped()? {
                    // Fill erased trailing cells so the following row wraps
                    // naturally. A wide glyph wraps from its spacer head, but
                    // the next row may since have been erased or overwritten.
                    let end = if point(cols - 1, y)?.cell()?.wide()? == CellWide::SpacerHead
                        && point(0, y + 1)?.cell()?.wide()? == CellWide::Wide
                    {
                        cols - 1
                    } else {
                        cols
                    };
                    for col in x..end {
                        write_cell_link(&point(col, y)?, &mut uri, &mut active, &mut out)?;
                        out.push(b' ');
                    }
                } else {
                    if !active.is_empty() {
                        out.extend_from_slice(b"\x1b]8;;\x1b\\");
                        active.clear();
                    }
                    // An empty continuation must consume the prior pending
                    // wrap before a hard newline advances to the next row.
                    if x == 0 && y > 0 && point(0, y - 1)?.row()?.is_wrapped()? {
                        out.push(b' ');
                    }
                    out.extend_from_slice(b"\r\n");
                }
                y += 1;
                x = 0;
                offset += 2;
                continue;
            }
            _ => {}
        }
        let grid = point(x, y)?;
        let cell = grid.cell()?;
        let content = cell.semantic_content()?;
        if content != semantic || (x == 0 && content == CellSemanticContent::Prompt) {
            out.extend_from_slice(match content {
                CellSemanticContent::Prompt if grid.row()?.semantic_prompt()? == RowSemanticPrompt::Continuation => b"\x1b]133;P;k=s\x07".as_slice(),
                CellSemanticContent::Prompt => b"\x1b]133;P;k=i\x07".as_slice(),
                CellSemanticContent::Input => b"\x1b]133;B\x07".as_slice(),
                CellSemanticContent::Output => b"\x1b]133;C\x07".as_slice(),
            });
            semantic = content;
        }
        let n = match grid.graphemes(&mut chars) {
            Err(libghostty_vt::Error::OutOfSpace { required }) => {
                chars.resize(required, '\0');
                grid.graphemes(&mut chars)?
            }
            result => result?,
        };
        cluster.clear();
        if n == 0 {
            cluster.push(' ');
        } else {
            cluster.extend(&chars[..n]);
        }
        if !body[offset..].starts_with(cluster.as_bytes()) {
            return Err("Formatter hyperlink cell mismatch".into());
        }
        write_cell_link(&grid, &mut uri, &mut active, &mut out)?;
        out.extend_from_slice(cluster.as_bytes());
        offset += cluster.len();
        x += if cell.wide()? == CellWide::Wide { 2 } else { 1 };
    }
    if !active.is_empty() {
        out.extend_from_slice(b"\x1b]8;;\x1b\\");
    }
    Ok(out)
}

/// `CSI n X CSI n C` at the start of `body`: the cells erased and stepped
/// over, and the length of both sequences.
fn erased_run(body: &[u8]) -> Option<(u16, usize)> {
    let digits = |from: usize| body.get(from..).map(|rest| rest.iter().take_while(|b| b.is_ascii_digit()).count());
    let number = |from: usize, len: usize| if len == 0 { Some(1) } else { std::str::from_utf8(&body[from..from + len]).ok()?.parse::<u16>().ok() };
    if !body.starts_with(b"\x1b[") {
        return None;
    }
    let erase = digits(2)?;
    let forward_at = 2 + erase + 1;
    if body.get(2 + erase) != Some(&b'X') || !body[forward_at..].starts_with(b"\x1b[") {
        return None;
    }
    let forward = digits(forward_at + 2)?;
    let end = forward_at + 2 + forward;
    let count = number(2, erase)?.max(1);
    (body.get(end) == Some(&b'C') && number(forward_at + 2, forward)?.max(1) == count).then_some((count, end + 1))
}

/// Since Ghostty 521cf2c the formatter skips runs of blank cells with CUF
/// (`CSI n C`). Replay walks the body cell by cell, so spell them as spaces.
///
/// The step after an erase stays: those cells are not text.
fn expand_cursor_forward(body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len());
    let mut offset = 0;
    while offset < body.len() {
        if let Some((_, step)) = erased_run(&body[offset..]) {
            out.extend_from_slice(&body[offset..offset + step]);
            offset += step;
            continue;
        }
        if body[offset..].starts_with(b"\x1b[") {
            let digits = body[offset + 2..].iter().take_while(|b| b.is_ascii_digit()).count();
            if body.get(offset + 2 + digits) == Some(&b'C') {
                let n = std::str::from_utf8(&body[offset + 2..offset + 2 + digits])
                    .ok()
                    .and_then(|n| n.parse::<usize>().ok())
                    .unwrap_or(1)
                    .max(1);
                out.resize(out.len() + n, b' ');
                offset += 3 + digits;
                continue;
            }
        }
        out.push(body[offset]);
        offset += 1;
    }
    out
}

fn write_cell_link(
    grid: &libghostty_vt::screen::GridRef<'_>,
    uri: &mut Vec<u8>,
    active: &mut Vec<u8>,
    out: &mut Vec<u8>,
) -> Result<(), Error> {
    let len = if grid.cell()?.has_hyperlink()? {
        match grid.hyperlink_uri(uri) {
            Err(libghostty_vt::Error::OutOfSpace { required }) => {
                uri.resize(required, 0);
                grid.hyperlink_uri(uri)?
            }
            result => result?,
        }
    } else {
        0
    };
    if *active != uri[..len] {
        out.extend_from_slice(b"\x1b]8;;");
        out.extend_from_slice(&uri[..len]);
        out.extend_from_slice(b"\x1b\\");
        active.clear();
        active.extend_from_slice(&uri[..len]);
    }
    Ok(())
}

/// Capture application state without converting the host's theme defaults into
/// OSC overrides. Frontends can then apply their own theme on attach/resize.
pub fn capture_frontend(vt: &mut Terminal<'_, '_>) -> Result<Vec<u8>, Error> {
    use libghostty_vt::style::{Palette, RgbColor};
    let defaults = vt.default_color_palette()?;
    let current = vt.color_palette()?;
    let foreground = vt.default_fg_color()?;
    let background = vt.default_bg_color()?;
    let cursor = vt.default_cursor_color()?;
    // The public API doesn't expose the palette override mask. Changing only
    // defaults reveals it exactly, including an explicit override equal to the
    // old default. No VT input or callbacks run during this synchronous probe.
    let sentinel = Palette(current.0.map(|c| RgbColor {
        r: !c.r,
        g: !c.g,
        b: !c.b,
    }));
    let observed = (|| -> Result<_, Error> {
        vt.set_default_color_palette(Some(sentinel))?
            .set_default_fg_color(None)?
            .set_default_bg_color(None)?
            .set_default_cursor_color(None)?;
        Ok((
            vt.color_palette()?,
            vt.fg_color()?,
            vt.bg_color()?,
            vt.cursor_color()?,
        ))
    })();
    // Restore all defaults even if a getter/probe failed. Propagate the original
    // failure after restoration rather than leaving a live terminal recolored.
    let restore_palette = vt.set_default_color_palette(Some(defaults)).map(|_| ());
    let restore_foreground = vt.set_default_fg_color(foreground).map(|_| ());
    let restore_background = vt.set_default_bg_color(background).map(|_| ());
    let restore_cursor = vt.set_default_cursor_color(cursor).map(|_| ());
    restore_palette?;
    restore_foreground?;
    restore_background?;
    restore_cursor?;
    let (palette, foreground, background, cursor) = observed?;
    let bytes = capture_impl(vt, false)?;
    // RIS preserves some OSC colors. Clear the previous application's overrides
    // explicitly before replaying this checkpoint's sparse override set.
    let mut out = b"\x1bc\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07".to_vec();
    for (index, color) in palette.0.iter().enumerate() {
        if *color != sentinel.0[index] {
            out.extend_from_slice(
                format!(
                    "\x1b]4;{index};#{:02x}{:02x}{:02x}\x1b\\",
                    color.r, color.g, color.b
                )
                .as_bytes(),
            );
        }
    }
    for (code, color) in [(10, foreground), (11, background), (12, cursor)] {
        if let Some(color) = color {
            out.extend_from_slice(
                format!(
                    "\x1b]{code};#{:02x}{:02x}{:02x}\x1b\\",
                    color.r, color.g, color.b
                )
                .as_bytes(),
            );
        }
    }
    out.extend_from_slice(
        bytes
            .strip_prefix(b"\x1bc")
            .ok_or("Missing checkpoint reset")?,
    );
    Ok(out)
}

fn capture_impl(vt: &Terminal<'_, '_>, palette: bool) -> Result<Vec<u8>, Error> {
    let cols = vt.cols()?;
    let rows = vt.rows()?;
    let mut formatter = Formatter::new(vt)?;
    formatter.set_format(Format::Vt)?.set_trim(false)?.set_unwrap(false)?.set_extras(Extras::NONE)?;
    let body = formatter.format_alloc(None)?;
    let body: &[u8] = body.as_ref();
    let mut extras = Extras::MODES | Extras::SCROLLING_REGION | Extras::TABSTOPS
        | Extras::PWD | Extras::KEYBOARD | Extras::CURSOR | Extras::STYLE
        | Extras::HYPERLINK | Extras::PROTECTION | Extras::KITTY_KEYBOARD | Extras::CHARSETS;
    extras.set(Extras::PALETTE, palette);
    formatter.set_extras(extras)?;
    let bytes = formatter.format_alloc(None)?;
    let bytes: &[u8] = bytes.as_ref();
    let replay_body = replay_body(vt, body)?;
    // The serializer intentionally trims trailing blank rows. Restore those
    // before its state extras, or the history/live-screen boundary shifts.
    // This temporary parser measures serialized rows, not retention.
    //
    // A finite budget can prune the source and invent trailing blank rows.
    // The engine allocates lazily from this already-captured body only.
    let mut probe = crate::new_vt(cols, rows, usize::MAX)?;
    probe.vt_write(&replay_body);
    let missing = vt.total_rows()?.saturating_sub(probe.total_rows()?);
    let end = if body.is_empty() {
        0
    } else {
        bytes
            .windows(body.len())
            .position(|part| part == body)
            .ok_or("Formatter content mismatch")?
            + body.len()
    };
    let mut out = b"\x1bc".to_vec();
    if vt.active_screen()? == libghostty_vt::screen::Screen::Alternate {
        out.extend_from_slice(b"\x1b[?1049h");
    }
    let start = end - body.len();
    out.extend_from_slice(&bytes[..start]);
    out.extend_from_slice(&replay_body);
    if missing > 0 {
        out.extend_from_slice(format!("\x1b[{rows};1H").as_bytes());
        for _ in 0..missing {
            out.extend_from_slice(b"\r\n");
        }
    }
    out.extend_from_slice(&bytes[end..]);
    // Tabstop extras move the cursor after the cursor-position extra.
    let mut x = vt.cursor_x()?;
    if vt.is_cursor_pending_wrap()?
        && matches!(
            vt.grid_ref(Point::Active(PointCoordinate {
                x,
                y: vt.cursor_y()?.into()
            }))?
            .cell()?
            .wide()?,
            libghostty_vt::screen::CellWide::SpacerTail
        )
    {
        x = x.saturating_sub(1);
    }
    let y = vt.cursor_y()?;
    use libghostty_vt::terminal::{Mode, ModeKind};
    let origin = vt.mode(Mode::new(6, ModeKind::Dec))?;
    let margin = |terminator: char| -> u16 {
        String::from_utf8_lossy(&bytes[end..])
            .split("\x1b[")
            .filter_map(|sequence| {
                let finish = sequence.find(terminator)?;
                let params = &sequence[..finish];
                if !params.bytes().all(|b| b.is_ascii_digit() || b == b';') {
                    return None;
                }
                params.split(';').next()?.parse::<u16>().ok()
            })
            .last()
            .unwrap_or(1)
            .saturating_sub(1)
    };
    let top = if origin { margin('r') } else { 0 };
    let left = if origin && vt.mode(Mode::new(69, ModeKind::Dec))? {
        margin('s')
    } else {
        0
    };
    out.extend_from_slice(
        format!(
            "\x1b[{};{}H",
            y.saturating_sub(top) + 1,
            x.saturating_sub(left) + 1
        )
        .as_bytes(),
    );
    if vt.is_cursor_pending_wrap()? {
        let point = |x| vt.grid_ref(Point::Active(PointCoordinate { x, y: y.into() }));
        // Reprinting the last glyph restores pending wrap. Its cell link can
        // differ from the cursor's current link (for example after OSC 8 end).
        let mut uri = vec![0; 512];
        let len = match point(x)?.hyperlink_uri(&mut uri) {
            Err(libghostty_vt::Error::OutOfSpace { required }) => {
                uri.resize(required, 0);
                point(x)?.hyperlink_uri(&mut uri)?
            }
            result => result?,
        };
        out.extend_from_slice(b"\x1b]8;;");
        out.extend_from_slice(&uri[..len]);
        out.extend_from_slice(b"\x1b\\");
        let selection = Selection::new(point(x)?, point(x)?, false);
        let mut formatter = Formatter::new(vt)?;
        formatter.set_format(Format::Vt)?.set_trim(false)?.set_unwrap(false)?.set_extras(Extras::NONE)?;
        // SAFETY: both endpoints are fresh snapshots of this terminal's active screen.
        unsafe { formatter.set_selection(Some(&selection))?; }
        let glyph = formatter.format_alloc(None)?;
        formatter.set_extras(Extras::STYLE | Extras::HYPERLINK)?;
        let last = formatter.format_alloc(None)?;
        out.extend_from_slice(glyph.as_ref());
        out.extend_from_slice(b"\x1b]8;;\x1b\\");
        out.extend_from_slice(
            last.as_ref()
                .strip_prefix(glyph.as_ref())
                .ok_or("Formatter cursor glyph mismatch")?,
        );
    }
    // libghostty's cursor formatter currently restores position but omits
    // DECSCUSR. Preserve the application's caret on attach/reconnect too.
    let mut render = libghostty_vt::render::RenderState::new()?;
    let view = render.update(vt)?;
    use libghostty_vt::render::CursorVisualStyle;
    let shape = match view.cursor_visual_style()? {
        CursorVisualStyle::Bar => 6,
        CursorVisualStyle::Underline => 4,
        _ => 2,
    } - i32::from(view.cursor_blinking()?);
    out.extend_from_slice(format!("\x1b[{shape} q").as_bytes());
    // The formatter omits OSC titles. A reconnect/resize resets the mirror,
    // so preserve the current title even when the application emits no more
    // output. Filter controls to keep the title inside its OSC payload.
    let title: String = String::from_utf8_lossy(vt.title().unwrap_or(b""))
        .chars()
        .filter(|c| !c.is_control())
        .collect();
    out.extend_from_slice(format!("\x1b]2;{title}\x1b\\").as_bytes());
    Ok(out)
}
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semantic_output_survives_attach_before_and_after_first_command() {
        for before in [
            b"\x1b]133;A\x07PS> \x1b]133;B\x07".as_slice(),
            b"\x1b]133;A\x07PS> \x1b]133;B\x07echo old\r\n\x1b]133;C\x07old\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> \x1b]133;B\x07".as_slice(),
        ] {
            let mut owner = crate::new_vt(80, 24, 1024 * 1024).unwrap();
            owner.vt_write(before);
            let mut mirror = crate::new_vt(80, 24, 1024 * 1024).unwrap();
            mirror.vt_write(&capture(&owner).unwrap());
            assert_eq!(crate::protocol::prompt_rows(&mirror), crate::protocol::prompt_rows(&owner));
            let command = b"echo current\r\n\x1b]133;C\x07current\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> \x1b]133;B\x07";
            owner.vt_write(command);
            mirror.vt_write(command);
            assert!(crate::navigation::last_output(&mut mirror));
            let mut reattached = crate::new_vt(80, 24, 1024 * 1024).unwrap();
            reattached.vt_write(&capture(&owner).unwrap());
            assert!(crate::navigation::last_output(&mut reattached));
        }
    }

    /// Erased cells keep their background without becoming text. With a
    /// wrapped row, link or prompt mark present, the body is replayed cell by
    /// cell and must pass the formatter's erase through.
    #[test]
    fn background_only_cells_survive_a_replayed_checkpoint() {
        let link = "\x1b]8;;https://example.test\x1b\\link\x1b]8;;\x1b\\";
        for source in [
            format!("12345678901234567890wrapped\r\nab\x1b[44m\x1b[K\x1b[0m\r\nnext"),
            format!("{link}\r\n\x1b[41m\x1b[5X\x1b[0m\x1b[7Gtail\r\n\x1b[42m\x1b[2K\x1b[0m"),
            format!("\x1b]133;A\x07$ \x1b]133;B\x07ls\r\n\x1b]133;C\x07a\x1b[45m\x1b[3X\x1b[0m\x1b[5Gb"),
        ] {
            let mut owner = crate::new_vt(20, 6, 1024 * 1024).unwrap();
            owner.vt_write(source.as_bytes());
            let checkpoint = capture(&owner).unwrap_or_else(|error| panic!("{source:?}: {error}"));
            assert!(checkpoint.windows(3).any(|part| part == b"X\x1b["), "{source:?}: the erase is replayed, not spelled as spaces");
            let mut mirror = crate::new_vt(20, 6, 1024 * 1024).unwrap();
            mirror.vt_write(&checkpoint);
            assert_eq!(String::from_utf8_lossy(&capture(&mirror).unwrap()), String::from_utf8_lossy(&checkpoint), "{source:?}");
        }
    }

    #[test]
    fn hyperlinks_survive_history_wide_wraps_styles_and_cursor_replay() {
        let link = "\x1b]8;;file:///tmp/한%20e.txt\x1b\\";
        let end = "\x1b]8;;\x1b\\";
        let cases = [
            format!("\r\n\r\n\x1b[31m{link}한e\u{301}123456789{end}\x1b[0m rest"),
            format!("1234567{link}한글{end}\r\nnext"),
            format!("{link}12345678{end}"),
            format!("{link}12345678"),
            format!("{link}first{end} \x1b]8;;https://example.test\x1b\\second{end}"),
            format!("{link}1234567한{end}"),
            format!("{link}history\r\nsecond{end}\r\nthree\r\nfour\r\nfive"),
            format!("\x1b[?1049h{link}alternate{end}"),
            format!("{link}1234567890{end}\x1b[1;3H\x1b[K"),
            format!("{link}1234567890{end}\x1b[2;1H\x1b[K\x1b[3;1Hnext"),
            format!("{link}1234567890{end}\x1b[1;1H\x1b[K"),
            format!("{link}한글한글1234{end}\x1b[1;2Hwide"),
            // A blank wrapped row follows a short line with erased cells.
            // Unwrapping in the formatter carries those cells into "next".
            format!("{link}1234567890{end}\x1b[3;8H한\x1b[3;1Hnext"),
            // A right-margin wide spacer can outlive the glyph after erasure.
            format!("{link}1234567한글{end}\x1b[2;1H\x1b[K\x1b[3;1Hnext"),
            format!("{link}1234567한글{end}\x1b[2;1Hx\x1b[3;1Hnext"),
            // Rebuilding wraps must preserve plain text too, without OSC 8.
            "1234567890\x1b[3;8H한\x1b[3;1Hnext".into(),
        ];
        for input in cases {
            let mut source = crate::new_vt(8, 3, 1024 * 1024).unwrap();
            source.vt_write(input.as_bytes());
            for bytes in [
                capture(&source).unwrap_or_else(|error| panic!("{input:?}: {error}")),
                capture_frontend(&mut source).unwrap_or_else(|error| panic!("{input:?}: {error}")),
            ] {
                let mut client = crate::new_vt(8, 3, 1024 * 1024).unwrap();
                client.vt_write(&bytes);
                assert_eq!(
                    client.total_rows().unwrap(),
                    source.total_rows().unwrap(),
                    "{input:?}"
                );
                assert_eq!(
                    crate::terminal_text::capture(&client, 8, true).unwrap(),
                    crate::terminal_text::capture(&source, 8, true).unwrap(),
                    "{input:?}"
                );
                for y in 0..source.total_rows().unwrap() as u32 {
                    let point = Point::Screen(PointCoordinate { x: 0, y });
                    assert_eq!(
                        client
                            .grid_ref(point)
                            .unwrap()
                            .row()
                            .unwrap()
                            .is_wrapped()
                            .unwrap(),
                        source
                            .grid_ref(point)
                            .unwrap()
                            .row()
                            .unwrap()
                            .is_wrapped()
                            .unwrap(),
                        "wrap after {input:?} at row {y}"
                    );
                    for x in 0..8 {
                        let mut a = vec![0; 4096];
                        let mut b = vec![0; 4096];
                        let point = Point::Screen(PointCoordinate { x, y });
                        let n = source
                            .grid_ref(point)
                            .unwrap()
                            .hyperlink_uri(&mut a)
                            .unwrap();
                        let m = client
                            .grid_ref(point)
                            .unwrap()
                            .hyperlink_uri(&mut b)
                            .unwrap();
                        assert_eq!(&a[..n], &b[..m], "{input:?} at {x},{y}");
                    }
                }
                // State extras restore whether subsequent output is linked.
                let continuation = b"Z";
                let mut expected = crate::new_vt(8, 3, 1024 * 1024).unwrap();
                expected.vt_write(input.as_bytes());
                expected.vt_write(continuation);
                client.vt_write(continuation);
                let col = client.cursor_x().unwrap().saturating_sub(1);
                let row = u32::from(client.cursor_y().unwrap());
                assert_eq!(
                    crate::protocol::hyperlink(&client, col, row),
                    crate::protocol::hyperlink(&expected, col, row),
                    "continuation after {input:?}"
                );
            }
        }
    }

    #[test]
    fn checkpoint_restores_title_and_subsequent_clear() {
        let mut source = crate::new_vt(20, 5, 1024 * 1024).unwrap();
        let mut client = crate::new_vt(20, 5, 1024 * 1024).unwrap();
        source.vt_write("\x1b]2;build 한글\x07content".as_bytes());
        client.vt_write(&capture_frontend(&mut source).unwrap());
        assert_eq!(client.title().unwrap(), "build 한글".as_bytes());
        source.vt_write(b"\x1b]2;\x07");
        client.vt_write(&capture_frontend(&mut source).unwrap());
        assert_eq!(client.title().unwrap_or(b""), b"");
        client.vt_write(b"\x1b]2;next task\x07");
        assert_eq!(client.title().unwrap(), b"next task");
    }

    #[test]
    fn byte_budgets_evict_old_pages_and_checkpoints_preserve_long_history() {
        let text = (0..5000)
            .map(|i| format!("\x1b[31mHISTORY_{i:04}\x1b[0m\r\n"))
            .collect::<String>();
        let mut retained = Vec::new();
        for budget in [0, 64, 16 * 1024 * 1024] {
            let mut source = crate::new_vt(80, 24, budget).unwrap();
            source.vt_write(text.as_bytes());
            source.vt_write(b"\r\n\r\n");
            let before = crate::terminal_text::capture(&source, 80, true).unwrap();
            assert!(before.contains("HISTORY_4999"));
            assert_eq!(before.contains("HISTORY_0000"), budget == 16 * 1024 * 1024);
            if budget == 0 {
                assert_eq!(source.scrollback_rows().unwrap(), 0);
            }
            retained.push(source.total_rows().unwrap());
            // Reconstruct with the authoritative policy, not a guessed row cap.
            // The long-history case specifically exceeds the old 10000-byte
            // checkpoint probe and catches invented trailing blank rows.
            for bytes in [
                capture(&source).unwrap(),
                capture_frontend(&mut source).unwrap(),
            ] {
                let mut client = crate::new_vt(80, 24, budget).unwrap();
                client.vt_write(&bytes);
                assert_eq!(
                    client.total_rows().unwrap(),
                    source.total_rows().unwrap(),
                    "budget {budget}"
                );
                assert_eq!(client.cursor_x().unwrap(), source.cursor_x().unwrap());
                assert_eq!(client.cursor_y().unwrap(), source.cursor_y().unwrap());
                assert_eq!(
                    crate::terminal_text::capture(&client, 80, true).unwrap(),
                    before,
                    "budget {budget}"
                );
                client.vt_write(b"continued");
                assert!(
                    crate::terminal_text::capture(&client, 80, true)
                        .unwrap()
                        .ends_with("continued")
                );
            }
        }
        assert!(
            retained[0] < retained[1] && retained[1] < retained[2],
            "{retained:?}"
        );
    }

    #[test]
    fn frontend_checkpoint_keeps_exact_overrides_and_never_mutates_host_theme() {
        use libghostty_vt::style::{Palette, PaletteIndex, RgbColor};
        let rgb = |r, g, b| RgbColor { r, g, b };
        for alternate in [false, true] {
            let mut source = crate::new_vt(20, 4, 100).unwrap();
            let mut defaults = Palette::default();
            defaults.set(PaletteIndex(1), rgb(0x12, 0x34, 0x56));
            source
                .set_default_color_palette(Some(defaults))
                .unwrap()
                .set_default_fg_color(Some(rgb(0x12, 0x34, 0x56)))
                .unwrap()
                .set_default_bg_color(Some(rgb(0x23, 0x45, 0x67)))
                .unwrap()
                .set_default_cursor_color(Some(rgb(0x34, 0x56, 0x78)))
                .unwrap();
            if alternate {
                source.vt_write(b"\x1b[?1049h");
            }
            source.vt_write(b"\x1b]4;1;#123456\x07\x1b]10;#123456\x07\x1b]11;#234567\x07\x1b]12;#345678\x07\x1b[31mA\x1b[0mB\x1b[6 q");
            let before =
                serde_json::to_value(crate::screen::snapshot(&source, 20, 4, false).unwrap())
                    .unwrap();
            let bytes = capture_frontend(&mut source).unwrap();
            assert_eq!(
                before,
                serde_json::to_value(crate::screen::snapshot(&source, 20, 4, false).unwrap())
                    .unwrap()
            );
            assert_eq!(source.default_color_palette().unwrap().0, defaults.0);
            assert_eq!(
                source.default_fg_color().unwrap(),
                Some(rgb(0x12, 0x34, 0x56))
            );
            assert_eq!(
                source.default_bg_color().unwrap(),
                Some(rgb(0x23, 0x45, 0x67))
            );
            assert_eq!(
                source.default_cursor_color().unwrap(),
                Some(rgb(0x34, 0x56, 0x78))
            );
            let mut client = crate::new_vt(20, 4, 100).unwrap();
            client
                .set_default_color_palette(Some(Palette([rgb(42, 43, 44); 256])))
                .unwrap()
                .set_default_fg_color(Some(rgb(21, 22, 23)))
                .unwrap()
                .set_default_bg_color(Some(rgb(31, 32, 33)))
                .unwrap()
                .set_default_cursor_color(Some(rgb(41, 42, 43)))
                .unwrap();
            client.vt_write(&bytes);
            assert_eq!(
                client.active_screen().unwrap(),
                source.active_screen().unwrap()
            );
            assert_eq!(client.cursor_x().unwrap(), source.cursor_x().unwrap());
            assert_eq!(client.cursor_y().unwrap(), source.cursor_y().unwrap());
            assert_eq!(
                client.color_palette().unwrap().get(PaletteIndex(1)),
                rgb(0x12, 0x34, 0x56)
            );
            assert_eq!(
                client.color_palette().unwrap().get(PaletteIndex(2)),
                rgb(42, 43, 44)
            );
            assert_eq!(client.fg_color().unwrap(), Some(rgb(0x12, 0x34, 0x56)));
            assert_eq!(client.bg_color().unwrap(), Some(rgb(0x23, 0x45, 0x67)));
            assert_eq!(client.cursor_color().unwrap(), Some(rgb(0x34, 0x56, 0x78)));
            source.vt_write(b"\x1b]104;1\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07");
            let cleared = capture_frontend(&mut source).unwrap();
            client.vt_write(&cleared);
            assert_eq!(
                client.color_palette().unwrap().get(PaletteIndex(1)),
                rgb(42, 43, 44)
            );
            // Since Ghostty 521cf2c, OSC 110-112 remove the override instead of
            // storing the owner's configured default as one, so the frontend
            // falls back to its own defaults.
            assert_eq!(client.fg_color().unwrap(), Some(rgb(21, 22, 23)));
            assert_eq!(client.bg_color().unwrap(), Some(rgb(31, 32, 33)));
            assert_eq!(client.cursor_color().unwrap(), Some(rgb(41, 42, 43)));
            // The real session owner has no configured RGB defaults. Resetting
            // its application colors therefore removes the overrides entirely.
            source
                .set_default_fg_color(None)
                .unwrap()
                .set_default_bg_color(None)
                .unwrap()
                .set_default_cursor_color(None)
                .unwrap();
            source.vt_write(b"\x1b]110\x07\x1b]111\x07\x1b]112\x07");
            client.vt_write(&capture_frontend(&mut source).unwrap());
            assert_eq!(client.fg_color().unwrap(), Some(rgb(21, 22, 23)));
            assert_eq!(client.bg_color().unwrap(), Some(rgb(31, 32, 33)));
            assert_eq!(client.cursor_color().unwrap(), Some(rgb(41, 42, 43)));
        }
    }
    fn check(bytes: &[u8], live: &[u8]) {
        let mut source = crate::new_vt(20, 4, 1000).unwrap();
        source.vt_write(bytes);
        let mut client = crate::new_vt(20, 4, 1000).unwrap();
        client.vt_write(&capture(&source).unwrap());
        assert_eq!(
            source.scrollbar().unwrap().total,
            client.scrollbar().unwrap().total
        );
        assert_eq!(
            crate::terminal_text::capture(&source, 20, true).unwrap(),
            crate::terminal_text::capture(&client, 20, true).unwrap()
        );
        source.vt_write(live);
        client.vt_write(live);
        assert_eq!(
            crate::terminal_text::capture(&source, 20, true).unwrap(),
            crate::terminal_text::capture(&client, 20, true).unwrap()
        );
        let normalized = |terminal: &Terminal<'_, '_>| {
            let mut frame = crate::screen::snapshot(terminal, 20, 4, false).unwrap();
            for row in &mut frame.lines {
                row.retain(|cell| !(cell.2 == " " && cell.4 == frame.background && cell.5 == 0));
            }
            serde_json::to_value(frame).unwrap()
        };
        assert_eq!(
            normalized(&source),
            normalized(&client),
            "input {:?}",
            String::from_utf8_lossy(bytes)
        );
    }
    #[test]
    fn retained_scrollback_and_styles_survive_checkpoint() {
        let text = (0..100)
            .map(|i| format!("\x1b[31m행 {i:03}\x1b[0m\r\n"))
            .collect::<String>();
        check(text.as_bytes(), b"live");
        check(b"", b"start");
        check(b"\x1b[2;4r\x1b[?6hregion", b" continuation");
        check(b"primary\x1b[?1049hAlternate", b" screen");
        check(
            b"soft wraps 12345678901234567890123456789012345678901234567890",
            b"continued",
        );
        check(b"hello\r\n\r\n", b"after blanks");
        check(b"12345678901234567890", b"wrapped");
        check("123456789012345678한".as_bytes(), b"wide wrapped");
        check(b"\x1b[32m12345678901234567890\x1b[31m", b"red wrapped");
    }
}
