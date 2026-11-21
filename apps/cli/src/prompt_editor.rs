//! Shared prompt editing; callers own submission, history display and lifecycle.
use crossterm::event::{Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton, MouseEventKind};
use ratatui::{
    Frame,
    buffer::Buffer,
    layout::{Position, Rect},
    style::{Modifier, Style},
    widgets::Widget,
};
use ratatui_textarea::{CursorMove, TextArea, WrapMode};

#[derive(Default)]
pub(crate) struct PromptEditor {
    prompts: Vec<String>,
    recalled: Option<usize>,
    saved_draft: Option<TextArea<'static>>,
    area: Rect,
    top: usize,
    dragging: bool,
}

pub(crate) fn rows(draft: &mut TextArea<'_>, width: u16, maximum: u16) -> u16 {
    draft.set_wrap_mode(WrapMode::WordOrGlyph);
    let mut measure = draft.clone();
    measure.cancel_selection();
    measure.remove_block();
    measure.move_cursor(CursorMove::Bottom);
    measure.move_cursor(CursorMove::End);
    let area = Rect::new(0, 0, width.max(1), 1);
    (&measure).render(area, &mut Buffer::empty(area));
    (measure.screen_cursor().row + 1).min(maximum as usize) as u16
}

impl PromptEditor {
    /// Draw and retain the actual wrapped viewport for mouse hit testing.
    pub fn render(&mut self, frame: &mut Frame<'_>, draft: &mut TextArea<'_>, area: Rect) {
        self.area = area;
        if area.is_empty() {
            return;
        }
        draft.set_wrap_mode(WrapMode::WordOrGlyph);
        draft.set_cursor_style(Style::default().add_modifier(Modifier::REVERSED));
        frame.render_widget(&*draft, area);
        for y in area.y..area.bottom() {
            for x in area.x..area.right() {
                let cell = &mut frame.buffer_mut()[(x, y)];
                if cell.modifier.contains(Modifier::REVERSED) {
                    cell.modifier.remove(Modifier::REVERSED);
                    self.top = draft
                        .screen_cursor()
                        .row
                        .saturating_sub((y - area.y) as usize);
                    frame.set_cursor_position((x, y));
                    return;
                }
            }
        }
    }

    /// Prompts sent before a checkpoint relaunch, so Up recalls them again.
    pub fn restore(&mut self, prompts: Vec<String>) {
        self.prompts = prompts;
        self.recalled = None;
    }

    /// Only call after a successful send, so failures preserve the draft.
    pub fn submitted(&mut self, draft: &mut TextArea<'static>) {
        self.prompts.push(draft.lines().join("\n"));
        self.recalled = None;
        self.saved_draft = None;
        self.dragging = false;
        *draft = TextArea::default();
    }

    fn recall(&mut self, draft: &mut TextArea<'static>, previous: bool) {
        let index = if previous {
            match self.recalled {
                Some(index) => index.saturating_sub(1),
                None => {
                    self.saved_draft = Some(draft.clone());
                    self.prompts.len() - 1
                }
            }
        } else {
            self.recalled.unwrap() + 1
        };
        if let Some(text) = self.prompts.get(index) {
            *draft = TextArea::from(text.split('\n'));
            draft.move_cursor(CursorMove::Bottom);
            draft.move_cursor(CursorMove::End);
            self.recalled = Some(index);
        } else {
            *draft = self.saved_draft.take().unwrap_or_default();
            self.recalled = None;
        }
        draft.set_wrap_mode(WrapMode::WordOrGlyph);
        self.dragging = false;
    }

    fn point(&self, draft: &mut TextArea<'_>, point: Position) {
        if self.area.is_empty() {
            return;
        }
        let row = self.top
            + point
                .y
                .saturating_sub(self.area.y)
                .min(self.area.height - 1) as usize;
        let col = point.x.saturating_sub(self.area.x).min(self.area.width - 1) as usize;
        // Query the editor's own mapping instead of reimplementing word wrap,
        // tabs and wide/combining characters. Find the last cursor at/before the cell.
        let mut probe = draft.clone();
        probe.cancel_selection();
        let mut low = 0;
        let mut high = draft.lines().len().min(u16::MAX as usize + 1);
        while low + 1 < high {
            let mid = (low + high) / 2;
            probe.move_cursor(CursorMove::Jump(mid as u16, 0));
            if probe.screen_cursor().row <= row {
                low = mid;
            } else {
                high = mid;
            }
        }
        let line = low;
        low = 0;
        high = draft.lines()[line].chars().count().min(u16::MAX as usize) + 1;
        while low + 1 < high {
            let mid = (low + high) / 2;
            probe.move_cursor(CursorMove::Jump(line as u16, mid as u16));
            let cursor = probe.screen_cursor();
            if (cursor.row, cursor.col) <= (row, col) {
                low = mid;
            } else {
                high = mid;
            }
        }
        draft.move_cursor(CursorMove::Jump(line as u16, low as u16));
    }

    /// Returns true for submit; the caller decides whether to accept it.
    pub fn input(&mut self, draft: &mut TextArea<'static>, event: Event) -> bool {
        match event {
            Event::Key(key) if key.kind != KeyEventKind::Release => match key.code {
                KeyCode::Enter
                    if key
                        .modifiers
                        .intersects(KeyModifiers::SHIFT | KeyModifiers::ALT) =>
                {
                    draft.insert_newline();
                }
                KeyCode::Enter => return true,
                KeyCode::Up
                    if key.modifiers.is_empty()
                        && draft.screen_cursor().row == 0
                        && !self.prompts.is_empty() =>
                {
                    self.recall(draft, true);
                }
                KeyCode::Down if key.modifiers.is_empty() && self.recalled.is_some() => {
                    let mut end = draft.clone();
                    end.cancel_selection();
                    end.move_cursor(CursorMove::Bottom);
                    end.move_cursor(CursorMove::End);
                    if draft.screen_cursor().row == end.screen_cursor().row {
                        self.recall(draft, false);
                    } else {
                        crate::text_edit::input(draft, key);
                    }
                }
                _ => {
                    crate::text_edit::input(draft, key);
                }
            },
            Event::Paste(text) => {
                draft.insert_str(text);
            }
            Event::Mouse(mouse) => {
                let point = Position::new(mouse.column, mouse.row);
                match mouse.kind {
                    MouseEventKind::Down(MouseButton::Left) if self.area.contains(point) => {
                        draft.cancel_selection();
                        self.point(draft, point);
                        draft.start_selection();
                        self.dragging = true;
                    }
                    MouseEventKind::Drag(MouseButton::Left) if self.dragging => {
                        self.point(draft, point)
                    }
                    MouseEventKind::Up(MouseButton::Left) => self.dragging = false,
                    _ => (),
                }
            }
            _ => (),
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{KeyEvent, MouseEvent};
    use ratatui::{Terminal, backend::TestBackend};

    fn key(
        editor: &mut PromptEditor,
        draft: &mut TextArea<'static>,
        code: KeyCode,
        modifiers: KeyModifiers,
    ) -> bool {
        editor.input(draft, Event::Key(KeyEvent::new(code, modifiers)))
    }

    fn draw(editor: &mut PromptEditor, draft: &mut TextArea<'static>, width: u16, height: u16) {
        let mut terminal = Terminal::new(TestBackend::new(width, height)).unwrap();
        terminal
            .draw(|frame| editor.render(frame, draft, frame.area()))
            .unwrap();
    }

    fn mouse(
        editor: &mut PromptEditor,
        draft: &mut TextArea<'static>,
        kind: MouseEventKind,
        x: u16,
        y: u16,
    ) {
        editor.input(
            draft,
            Event::Mouse(MouseEvent {
                kind,
                column: x,
                row: y,
                modifiers: KeyModifiers::NONE,
            }),
        );
    }

    #[test]
    fn deletion_keys_preserve_suffixes_and_unicode_and_support_undo() {
        let mut editor = PromptEditor::default();
        let mut draft = TextArea::from(["keep", "one 한글 tail"]);
        draft.move_cursor(CursorMove::Jump(1, 6));
        key(
            &mut editor,
            &mut draft,
            KeyCode::Char('w'),
            KeyModifiers::CONTROL,
        );
        assert_eq!(draft.lines(), ["keep", "one  tail"]);
        key(
            &mut editor,
            &mut draft,
            KeyCode::Char('u'),
            KeyModifiers::CONTROL,
        );
        assert_eq!(draft.lines(), ["keep", " tail"]);
        key(
            &mut editor,
            &mut draft,
            KeyCode::Char('u'),
            KeyModifiers::CONTROL,
        );
        assert_eq!(
            draft.lines(),
            ["keep", " tail"],
            "Ctrl+U at line start must not join lines"
        );
        key(
            &mut editor,
            &mut draft,
            KeyCode::Char('k'),
            KeyModifiers::CONTROL,
        );
        assert_eq!(draft.lines(), ["keep", ""]);
        key(
            &mut editor,
            &mut draft,
            KeyCode::Char('z'),
            KeyModifiers::CONTROL,
        );
        assert_eq!(draft.lines(), ["keep", " tail"]);
        key(
            &mut editor,
            &mut draft,
            KeyCode::Char('z'),
            KeyModifiers::ALT,
        );
        assert_eq!(draft.lines(), ["keep", ""]);
    }

    #[test]
    fn newlines_paste_and_submission_do_not_discard_unsent_text() {
        let mut editor = PromptEditor::default();
        let mut draft = TextArea::default();
        editor.input(&mut draft, Event::Paste("first\nsecond".into()));
        for modifiers in [KeyModifiers::SHIFT, KeyModifiers::ALT] {
            assert!(!key(&mut editor, &mut draft, KeyCode::Enter, modifiers));
            draft.insert_str("next");
        }
        assert_eq!(draft.lines(), ["first", "second", "next", "next"]);
        assert!(key(
            &mut editor,
            &mut draft,
            KeyCode::Enter,
            KeyModifiers::NONE
        ));
        assert_eq!(draft.lines(), ["first", "second", "next", "next"]);
        assert!(
            editor.prompts.is_empty(),
            "A failed send cannot enter recall history"
        );
        editor.submitted(&mut draft);
        assert!(draft.is_empty());
        assert_eq!(editor.prompts, ["first\nsecond\nnext\nnext"]);
    }

    #[test]
    fn recall_preserves_multiline_prompts_trailing_newlines_and_the_draft_cursor() {
        let mut editor = PromptEditor::default();
        let mut draft = TextArea::default();
        for text in ["first\nlast\n", "second"] {
            draft.insert_str(text);
            editor.submitted(&mut draft);
        }
        draft.insert_str("unfinished\n한글");
        draft.move_cursor(CursorMove::Jump(0, 3));
        key(&mut editor, &mut draft, KeyCode::Up, KeyModifiers::NONE);
        assert_eq!(draft.lines(), ["second"]);
        key(&mut editor, &mut draft, KeyCode::Up, KeyModifiers::NONE);
        assert_eq!(draft.lines(), ["first", "last", ""]);
        key(&mut editor, &mut draft, KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(draft.lines(), ["second"]);
        key(&mut editor, &mut draft, KeyCode::Down, KeyModifiers::NONE);
        assert_eq!(draft.lines(), ["unfinished", "한글"]);
        assert_eq!(draft.cursor(), (0, 3));
    }

    #[test]
    fn arrows_move_within_wrapped_text_before_recalling_prompts() {
        let mut editor = PromptEditor::default();
        let mut draft = TextArea::from(["old"]);
        editor.submitted(&mut draft);
        draft.insert_str("alpha beta gamma delta");
        assert!(rows(&mut draft, 10, 8) > 1);
        draw(&mut editor, &mut draft, 10, 4);
        let last_row = draft.screen_cursor().row;
        key(&mut editor, &mut draft, KeyCode::Up, KeyModifiers::NONE);
        assert!(draft.screen_cursor().row < last_row);
        assert_eq!(draft.lines(), ["alpha beta gamma delta"]);
        while draft.screen_cursor().row > 0 {
            key(&mut editor, &mut draft, KeyCode::Up, KeyModifiers::NONE);
        }
        key(&mut editor, &mut draft, KeyCode::Up, KeyModifiers::NONE);
        assert_eq!(draft.lines(), ["old"]);
    }

    #[test]
    fn mouse_maps_wrapped_scrolled_wide_characters_and_replaces_a_selection() {
        let mut editor = PromptEditor::default();
        let mut draft = TextArea::from(["12345678한글xy"]);
        draft.move_cursor(CursorMove::End);
        draw(&mut editor, &mut draft, 8, 1);
        assert_eq!(editor.top, 1);
        mouse(
            &mut editor,
            &mut draft,
            MouseEventKind::Down(MouseButton::Left),
            1,
            0,
        );
        assert_eq!(
            draft.cursor(),
            (0, 8),
            "Both cells of 한 must point before the character"
        );
        mouse(
            &mut editor,
            &mut draft,
            MouseEventKind::Drag(MouseButton::Left),
            4,
            0,
        );
        mouse(
            &mut editor,
            &mut draft,
            MouseEventKind::Up(MouseButton::Left),
            4,
            0,
        );
        assert_eq!(draft.selection_range(), Some(((0, 8), (0, 10))));
        draft.insert_str("X");
        assert_eq!(draft.lines(), ["12345678Xxy"]);
        draw(&mut editor, &mut draft, 20, 4);
        assert_eq!(editor.top, 0);
        mouse(
            &mut editor,
            &mut draft,
            MouseEventKind::Down(MouseButton::Left),
            2,
            0,
        );
        assert_eq!(draft.cursor(), (0, 2));
    }

    #[test]
    fn mouse_uses_word_wrap_and_tab_cells_without_changing_newlines() {
        let mut editor = PromptEditor::default();
        let mut draft = TextArea::from(["hello world", "a\t한글"]);
        draft.set_tab_length(4);
        draw(&mut editor, &mut draft, 8, 5);
        mouse(
            &mut editor,
            &mut draft,
            MouseEventKind::Down(MouseButton::Left),
            1,
            1,
        );
        assert_eq!(draft.cursor(), (0, 7));
        mouse(
            &mut editor,
            &mut draft,
            MouseEventKind::Down(MouseButton::Left),
            2,
            2,
        );
        assert_eq!(draft.cursor(), (1, 1));
        mouse(
            &mut editor,
            &mut draft,
            MouseEventKind::Down(MouseButton::Left),
            5,
            2,
        );
        assert_eq!(draft.cursor(), (1, 2));
        assert_eq!(draft.lines(), ["hello world", "a\t한글"]);
        mouse(
            &mut editor,
            &mut draft,
            MouseEventKind::Down(MouseButton::Left),
            0,
            2,
        );
        key(
            &mut editor,
            &mut draft,
            KeyCode::Char('u'),
            KeyModifiers::CONTROL,
        );
        assert_eq!(
            draft.lines(),
            ["hello world", "a\t한글"],
            "A click at line start is not a selection to delete"
        );
    }
}
