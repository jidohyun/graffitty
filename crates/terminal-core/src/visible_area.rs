//! Content bounds of one presented terminal viewport, in cell coordinates.
//! Not semantic input-box detection, damage tracking, or scrollback bounds.
//! Build alongside the renderer's cell walk, then publish only a complete frame.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bounds {
    pub left: u16,
    pub top: u16,
    /// Exclusive edges.
    pub right: u16,
    pub bottom: u16,
}

impl Bounds {
    fn union(self, other: Self) -> Self {
        Self {
            left: self.left.min(other.left),
            top: self.top.min(other.top),
            right: self.right.max(other.right),
            bottom: self.bottom.max(other.bottom),
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VisibleArea {
    pub columns: u16,
    pub rows: u16,
    /// Printable ink and persistent decorations; excludes plain whitespace.
    pub text: Option<Bounds>,
    /// Includes non-default backgrounds, even on blank cells.
    pub content: Option<Bounds>,
    /// Independent of cursor blink/visibility (TUIs hide the hardware cursor).
    pub cursor: Option<Bounds>,
    /// Graphics require conservative framing until their pixel bounds are supplied.
    pub graphics_present: bool,
}

impl VisibleArea {
    pub fn new(columns: u16, rows: u16, cursor: Option<(u16, u16)>) -> Self {
        let mut area = Self {
            columns,
            rows,
            ..Self::default()
        };
        area.cursor = cursor.and_then(|(x, y)| area.clip(x, y, 1));
        area
    }

    fn clip(&self, column: u16, row: u16, width: u16) -> Option<Bounds> {
        (column < self.columns && row < self.rows && width > 0).then(|| Bounds {
            left: column,
            top: row,
            right: column.saturating_add(width).min(self.columns),
            bottom: row + 1,
        })
    }

    /// Call once per cell, using underlying terminal styling, not selection,
    /// search highlights, hover, or the current text-blink phase.
    pub fn observe(&mut self, column: u16, row: u16, width: u16, ink: bool, background: bool) {
        let Some(bounds) = self.clip(column, row, width) else {
            return;
        };
        if ink {
            merge(&mut self.text, bounds);
        }
        if ink || background {
            merge(&mut self.content, bounds);
        }
    }

    /// Safe framing target. A blank terminal still has a cursor target.
    pub fn framing_bounds(&self) -> Option<Bounds> {
        if self.graphics_present && self.columns > 0 && self.rows > 0 {
            return Some(Bounds {
                left: 0,
                top: 0,
                right: self.columns,
                bottom: self.rows,
            });
        }
        let mut bounds = self.content;
        if let Some(cursor) = self.cursor {
            merge(&mut bounds, cursor);
        }
        bounds
    }
}

fn merge(target: &mut Option<Bounds>, bounds: Bounds) {
    *target = Some(target.map_or(bounds, |old| old.union(bounds)));
}

/// Latest complete presentation. Generation changes only when bounds change,
/// not for cursor blink, identical repaint, or equal-footprint text replacement.
#[derive(Default)]
pub struct Tracker {
    pub generation: u64,
    pub area: VisibleArea,
    pub ready: bool,
}
impl Tracker {
    pub fn publish(&mut self, area: VisibleArea) {
        if !self.ready || self.area != area {
            self.generation = self.generation.wrapping_add(1);
            self.area = area;
        }
        self.ready = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sparse_wide_text_background_and_cursor_are_separate() {
        let mut a = VisibleArea::new(80, 24, Some((0, 20)));
        a.observe(4, 2, 2, true, false);
        a.observe(79, 5, 2, true, false);
        a.observe(0, 23, 80, false, true);
        assert_eq!(
            a.text,
            Some(Bounds {
                left: 4,
                top: 2,
                right: 80,
                bottom: 6
            })
        );
        assert_eq!(a.content.unwrap().bottom, 24);
        assert_eq!(a.cursor.unwrap().top, 20);
        assert_eq!(a.framing_bounds().unwrap().left, 0);
        a.observe(0, 24, 80, true, true);
        assert_eq!(a.content.unwrap().bottom, 24);
    }

    #[test]
    fn clear_resize_and_identical_repaint_do_not_leave_stale_bounds() {
        let mut t = Tracker::default();
        let mut full = VisibleArea::new(80, 24, None);
        full.observe(0, 23, 80, true, false);
        t.publish(full.clone());
        t.publish(full);
        assert_eq!(t.generation, 1);
        t.publish(VisibleArea::new(20, 10, Some((1, 1))));
        assert_eq!(t.generation, 2);
        assert_eq!(t.area.content, None);
        assert_eq!(t.area.framing_bounds().unwrap().right, 2);
    }

    #[test]
    fn graphics_never_masquerade_as_empty_text() {
        let mut a = VisibleArea::new(80, 24, None);
        assert_eq!(a.framing_bounds(), None);
        a.graphics_present = true;
        assert_eq!(
            a.framing_bounds(),
            Some(Bounds {
                left: 0,
                top: 0,
                right: 80,
                bottom: 24
            })
        );
    }
}
