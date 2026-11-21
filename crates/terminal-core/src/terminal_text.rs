//! Read the VT buffer without installing a selection or moving the viewport.
use libghostty_vt::{
    Terminal,
    fmt::Formatter,
    selection::Selection,
    terminal::{Point, PointCoordinate},
};

pub fn capture(vt: &Terminal<'_, '_>, cols: u16, scrollback: bool) -> Result<String, String> {
    let scroll = vt.scrollbar().map_err(|e| e.to_string())?;
    let (start, count) = if scrollback {
        (0, scroll.total)
    } else {
        (scroll.offset, scroll.len)
    };
    if cols == 0 || count == 0 {
        return Ok(String::new());
    }
    let point = |x, y| Point::Screen(PointCoordinate { x, y });
    let start = vt
        .grid_ref(point(0, start as u32))
        .map_err(|e| e.to_string())?;
    let end = vt
        .grid_ref(point(
            cols - 1,
            (if scrollback {
                scroll.total
            } else {
                scroll.offset + scroll.len
            }) as u32
                - 1,
        ))
        .map_err(|e| e.to_string())?;
    let selection = Selection::new(start, end, false);
    let mut formatter = Formatter::new(vt).map_err(|e| e.to_string())?;
    formatter.set_trim(true).map_err(|e| e.to_string())?;
    formatter.set_unwrap(false).map_err(|e| e.to_string())?;
    // SAFETY: the endpoints were resolved from this terminal's active screen above.
    unsafe { formatter.set_selection(Some(&selection)) }.map_err(|e| e.to_string())?;
    let bytes = formatter.format_alloc(None).map_err(|e| e.to_string())?;
    let text = String::from_utf8_lossy(bytes.as_ref()).into_owned();
    // Leave room for JSON escaping inside the socket's 4 MiB response limit.
    if text.len() > 512 * 1024 {
        return Err("Terminal text exceeds 512 KiB; retry without scrollback".into());
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_visual_wraps_and_empty_screen() {
        let mut vt = crate::new_vt(4, 2, 100).unwrap();
        assert!(capture(&vt, 4, false).unwrap().trim().is_empty());
        vt.vt_write(b"abcdef");
        assert_eq!(capture(&vt, 4, false).unwrap(), "abcd\nef");
    }

    #[test]
    fn reads_history_viewport_unicode_and_alternate_without_mutation() {
        let mut vt = crate::new_vt(12, 2, 100).unwrap();
        vt.vt_write("old\r\n\x1b[31m한글\x1b[0m\r\nnew".as_bytes());
        let before = vt.scrollbar().unwrap();
        let selected = Selection::new(
            vt.grid_ref(Point::Screen(PointCoordinate { x: 0, y: 0 }))
                .unwrap(),
            vt.grid_ref(Point::Screen(PointCoordinate { x: 2, y: 0 }))
                .unwrap(),
            false,
        );
        vt.set_selection(Some(&selected)).unwrap();
        let visible = capture(&vt, 12, false).unwrap();
        assert!(!visible.contains("old"));
        assert!(visible.contains("한글"));
        assert!(!visible.contains('\x1b'));
        assert!(capture(&vt, 12, true).unwrap().contains("old"));
        assert_eq!(vt.scrollbar().unwrap().offset, before.offset);
        let copied = Formatter::new_selection(&vt)
            .unwrap()
            .unwrap()
            .format_alloc(None)
            .unwrap();
        assert_eq!(copied.as_ref(), b"old");
        vt.scroll_viewport(libghostty_vt::terminal::ScrollViewport::Top);
        assert!(capture(&vt, 12, false).unwrap().contains("old"));
        vt.vt_write(b"\x1b[?1049hALT");
        let alternate = capture(&vt, 12, true).unwrap();
        assert!(alternate.contains("ALT"));
        assert!(!alternate.contains("old"));
    }
}
