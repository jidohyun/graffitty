//! Search and keyboard selection use screen coordinates, including scrollback.
use crate::quick_select::Match;
use libghostty_vt::{
    Terminal,
    screen::{CellSemanticContent, Screen},
    selection::Selection,
    terminal::{Point, PointCoordinate, ScrollViewport},
};
#[derive(Default)]
pub struct Navigation {
    pub active: bool,
    pub query: Option<String>,
    pub matches: Vec<Match>,
    pub current: usize,
    pub cursor: (u16, u32),
    pub anchor: Option<(u16, u32)>,
    pub screen: Option<Screen>,
}
impl Navigation {
    pub fn search(&mut self, vt: &Terminal<'_, '_>, query: &str) {
        self.active = true;
        self.screen = vt.active_screen().ok();
        self.query = Some(query.into());
        self.matches = crate::quick_select::QuickSelect::search(vt, query)
            .map(|q| q.matches)
            .unwrap_or_default();
        self.current = self.matches.len().saturating_sub(1);
    }
    pub fn select(&mut self, vt: &mut Terminal<'_, '_>) {
        if self.query.is_some() {
            if let Some(m) = self.matches.get(self.current) {
                if m.select_text(vt).is_some() {
                    if let Some((start, _)) = m.bounds() {
                        reveal(vt, start.y);
                    }
                }
            } else {
                let _ = vt.set_selection(None);
            }
        } else {
            let anchor = self.anchor.unwrap_or(self.cursor);
            select(vt, anchor, self.cursor);
            reveal(vt, self.cursor.1);
        }
    }
    pub fn step(&mut self, direction: i32) {
        if !self.matches.is_empty() {
            self.current =
                (self.current as i32 + direction).rem_euclid(self.matches.len() as i32) as usize;
        }
    }
    pub fn status(&self) -> String {
        if let Some(query) = &self.query {
            format!(
                "Search: {query}  [{}/{}]",
                if self.matches.is_empty() {
                    0
                } else {
                    self.current + 1
                },
                self.matches.len()
            )
        } else {
            format!(
                "Copy mode: {}:{}{}",
                self.cursor.1 + 1,
                self.cursor.0 + 1,
                if self.anchor.is_some() {
                    " selecting"
                } else {
                    ""
                }
            )
        }
    }
}
fn reveal(vt: &mut Terminal<'_, '_>, row: u32) {
    if let Ok(s) = vt.scrollbar() {
        if (row as u64) < s.offset {
            vt.scroll_viewport(ScrollViewport::Row(row as usize));
        } else if row as u64 >= s.offset + s.len {
            vt.scroll_viewport(ScrollViewport::Row(
                (row as u64 + 1).saturating_sub(s.len) as usize
            ));
        }
    }
}
fn select(vt: &Terminal<'_, '_>, start: (u16, u32), end: (u16, u32)) -> bool {
    let point = |(x, y)| Point::Screen(PointCoordinate { x, y });
    if let (Ok(a), Ok(b)) = (vt.grid_ref(point(start)), vt.grid_ref(point(end))) {
        vt.set_selection(Some(&Selection::new(a, b, false))).is_ok()
    } else {
        false
    }
}
pub fn last_output(vt: &mut Terminal<'_, '_>) -> bool {
    if vt.active_screen().ok() == Some(Screen::Alternate) {
        return false;
    }
    let rows = crate::protocol::prompt_rows(vt);
    if rows.len() < 2 {
        return false;
    }
    let start = rows[rows.len() - 2];
    let end = rows[rows.len() - 1];
    let mut first = None;
    let mut last = None;
    for y in start..end {
        for x in 0..vt.cols().unwrap_or(0) {
            let Ok(cell) = vt
                .grid_ref(Point::Screen(PointCoordinate { x, y: y as u32 }))
                .and_then(|r| r.cell())
            else {
                continue;
            };
            if cell.semantic_content().ok() == Some(CellSemanticContent::Output)
                && cell.has_text().unwrap_or(false)
            {
                first.get_or_insert((x, y as u32));
                last = Some((x, y as u32));
            }
        }
    }
    if let (Some(a), Some(b)) = (first, last) {
        let ok = select(vt, a, b);
        reveal(vt, a.1);
        ok
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn literal_wrapped_search_and_output_selection() {
        let mut vt = crate::new_vt(12, 3, 100).unwrap();
        vt.vt_write(b"\x1b]133;A\x07$ \x1b]133;B\x07test\r\n\x1b]133;C\x07a.b-long-output\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ \x1b]133;B\x07");
        let mut nav = Navigation::default();
        nav.search(&vt, "b-long-output");
        assert_eq!(nav.matches.len(), 1);
        assert_eq!(
            nav.matches[0].select_text(&vt).as_deref(),
            Some("b-long-output")
        );
        nav.search(&vt, "a.b");
        assert_eq!(nav.matches.len(), 1);
        nav.search(&vt, "axb");
        assert!(nav.matches.is_empty());
        assert!(last_output(&mut vt));
        let mut formatter = libghostty_vt::fmt::Formatter::new_selection(&vt).unwrap().unwrap();
        formatter.set_trim(true).unwrap().set_unwrap(true).unwrap();
        let text = formatter.format_alloc(None).unwrap();
        assert_eq!(String::from_utf8(text.to_vec()).unwrap(), "a.b-long-output");
    }
}
