use libghostty_vt::style::RgbColor;

/// Independent Kitty-compatible selection overrides. Neither set means inverse.
#[derive(Clone, Copy, Default)]
pub struct SelectionColors {
    pub background: Option<RgbColor>,
    pub foreground: Option<RgbColor>,
}

impl SelectionColors {
    /// Returns (foreground, background), after the cell's inverse style.
    pub fn resolve(
        self,
        foreground: RgbColor,
        background: Option<RgbColor>,
        default_background: RgbColor,
    ) -> (RgbColor, RgbColor) {
        let selected_foreground = self.foreground.unwrap_or_else(|| {
            if self.background.is_none() {
                background.unwrap_or(default_background)
            } else {
                foreground
            }
        });
        (selected_foreground, self.background.unwrap_or(foreground))
    }
}

/// Resolve every grid cell, including wide-character continuation cells which
/// have no graphemes but still carry inverse video and selection styling.
pub fn resolve_cell_colors(
    cell: &libghostty_vt::render::CellIteration<'_, '_>,
    default_fg: RgbColor,
    default_bg: RgbColor,
    selection: SelectionColors,
    selected: bool,
) -> libghostty_vt::error::Result<(RgbColor, Option<RgbColor>)> {
    let mut fg = cell.fg_color()?.unwrap_or(default_fg);
    let mut bg = cell.bg_color()?;
    if cell.has_styling()? && cell.style()?.inverse {
        let old_fg = fg;
        fg = bg.unwrap_or(default_bg);
        bg = Some(old_fg);
    }
    if selected {
        let (selected_fg, selected_bg) = selection.resolve(fg, bg, default_bg);
        fg = selected_fg;
        bg = Some(selected_bg);
    }
    Ok((fg, bg))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rgb(r: u8, g: u8, b: u8) -> RgbColor {
        RgbColor { r, g, b }
    }

    #[test]
    fn independent_selection_colors() {
        let red = rgb(220, 40, 60);
        let blue = rgb(20, 40, 200);
        let purple = rgb(127, 102, 153);
        let white = rgb(255, 255, 255);
        let black = rgb(0, 0, 0);
        let inverse = SelectionColors::default();
        assert_eq!(inverse.resolve(red, Some(blue), black), (blue, red));
        assert_eq!(inverse.resolve(red, None, black), (black, red));
        let preserve = SelectionColors {
            background: Some(purple),
            foreground: None,
        };
        assert_eq!(preserve.resolve(red, Some(blue), black), (red, purple));
        assert_eq!(preserve.resolve(white, None, black), (white, purple));
        let fixed = SelectionColors {
            background: Some(purple),
            foreground: Some(white),
        };
        assert_eq!(fixed.resolve(red, Some(blue), black), (white, purple));
        let foreground_only = SelectionColors {
            background: None,
            foreground: Some(white),
        };
        assert_eq!(
            foreground_only.resolve(red, Some(blue), black),
            (white, red)
        );
    }
    #[test]
    fn korean_inverse_highlight_covers_wide_continuation_cells() {
        use libghostty_vt::render::{CellIterator, RenderState, RowIterator};
        let mut vt = crate::new_vt(12, 2, 0).unwrap();
        vt.vt_write("\x1b[38;2;240;240;240m\x1b[48;2;40;40;40m\x1b[7m한글 \x1b[0m".as_bytes());
        let mut render = RenderState::new().unwrap();
        let snapshot = render.update(&vt).unwrap();
        let defaults = snapshot.colors().unwrap();
        let mut rows = RowIterator::new().unwrap();
        let mut cells = CellIterator::new().unwrap();
        let mut rows = rows.update(&snapshot).unwrap();
        let row = rows.next().unwrap();
        let mut cells = cells.update(row).unwrap();
        for col in 0..5 {
            let cell = cells.next().unwrap();
            if col == 1 || col == 3 {
                assert_eq!(cell.graphemes_len().unwrap(), 0, "Wide tail has no glyph");
            }
            let resolved = resolve_cell_colors(
                cell,
                defaults.foreground,
                defaults.background,
                SelectionColors::default(),
                false,
            )
            .unwrap();
            assert_eq!(
                resolved,
                (rgb(40, 40, 40), Some(rgb(240, 240, 240))),
                "Highlight must be continuous at column {col}"
            );
            let selected = resolve_cell_colors(
                cell,
                defaults.foreground,
                defaults.background,
                SelectionColors::default(),
                true,
            )
            .unwrap();
            assert_eq!(
                selected,
                (rgb(240, 240, 240), Some(rgb(40, 40, 40))),
                "Terminal selection applies after inverse at column {col}"
            );
        }
        let plain = cells.next().unwrap();
        assert_eq!(
            resolve_cell_colors(
                plain,
                defaults.foreground,
                defaults.background,
                SelectionColors::default(),
                false
            )
            .unwrap()
            .1,
            None
        );
    }
}
/// Encode the event clock for the pinned Ghostty 0.2.2 selection ABI. Its
/// Windows `instantFromNs` stores the value directly in a QPC timestamp,
/// while `Instant.since` converts QPC ticks to nanoseconds.
///
/// Intervals remain ordinary Durations; only absolute event timestamps need
/// this workaround.
pub fn gesture_event_time(elapsed: std::time::Duration) -> std::time::Duration {
    #[cfg(windows)]
    {
        use std::sync::OnceLock;
        #[link(name = "kernel32")]
        unsafe extern "system" { fn QueryPerformanceFrequency(value: *mut i64) -> i32; }
        static FREQUENCY: OnceLock<u64> = OnceLock::new();
        let frequency = *FREQUENCY.get_or_init(|| {
            let mut value = 0;
            assert!(unsafe { QueryPerformanceFrequency(&mut value) } != 0 && value > 0);
            value as u64
        });
        let ticks = elapsed.as_nanos().saturating_mul(u128::from(frequency)) / 1_000_000_000;
        std::time::Duration::from_nanos(ticks.min(u128::from(u64::MAX)) as u64)
    }
    #[cfg(not(windows))]
    { elapsed }
}

#[test]
fn gesture_clock_keeps_double_clicks_and_expires_late_presses() {
    use libghostty_vt::selection::gesture::{Gesture, PressEvent, ReleaseEvent};
    use libghostty_vt::terminal::{Point, PointCoordinate};
    use std::time::Duration;
    let mut terminal = crate::new_vt(20, 5, 0).unwrap();
    terminal.vt_write(b"alpha beta");
    let mut gesture = Gesture::new().unwrap();
    for (millis, count) in [(0, 1), (100, 2), (700, 1)] {
        let point = terminal.grid_ref(Point::Active(PointCoordinate { x: 2, y: 0 })).unwrap();
        let selection = PressEvent::new().unwrap()
            .set_repeat_interval(Duration::from_millis(500)).unwrap()
            .set_repeat_distance(10.).unwrap()
            .set_time(gesture_event_time(Duration::from_millis(millis))).unwrap()
            .set_position(25., 10.).unwrap()
            .apply(&mut gesture, &terminal, point).unwrap();
        terminal.set_selection(selection.as_ref()).unwrap();
        let point = terminal.grid_ref(Point::Active(PointCoordinate { x: 2, y: 0 })).unwrap();
        ReleaseEvent::new().unwrap().apply(&mut gesture, &terminal, Some(point)).unwrap();
        assert_eq!(gesture.click_count(&terminal).unwrap(), count);
    }
}
