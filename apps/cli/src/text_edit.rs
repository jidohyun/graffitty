//! Keyboard policy for every Graffitty textarea. Keep application actions in callers.
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use ratatui_textarea::{CursorMove, TextArea};

// TextArea defaults Ctrl+U to undo and Ctrl+J to backward deletion. Terminal
// users expect line killing and a newline instead; keep these consistent in
// every node. Ctrl+Enter remains the form's Apply shortcut.
pub(crate) fn input(field: &mut TextArea<'_>, key: KeyEvent) -> bool {
    if key.kind == KeyEventKind::Release {
        return false;
    }
    match (key.code, key.modifiers) {
        (KeyCode::Char('u'), KeyModifiers::CONTROL) => {
            // At column zero this is a no-op, not a join with the previous line.
            if field
                .selection_range()
                .is_some_and(|(start, end)| start != end)
                || field.cursor().1 > 0
            {
                field.delete_line_by_head()
            } else {
                false
            }
        }
        (KeyCode::Char('k'), KeyModifiers::CONTROL) => field.delete_line_by_end(),
        (KeyCode::Char('w'), KeyModifiers::CONTROL) => field.delete_word(),
        (KeyCode::Char('j'), KeyModifiers::CONTROL) => {
            field.insert_newline();
            true
        }
        (KeyCode::Char('z'), KeyModifiers::CONTROL) => field.undo(),
        (KeyCode::Char('z'), KeyModifiers::ALT) => field.redo(),
        (KeyCode::F(6), KeyModifiers::NONE) => {
            field.select_all();
            false
        }
        (KeyCode::Home, KeyModifiers::CONTROL) => {
            field.move_cursor(CursorMove::Top);
            field.move_cursor(CursorMove::Head);
            false
        }
        (KeyCode::End, KeyModifiers::CONTROL) => {
            field.move_cursor(CursorMove::Bottom);
            field.move_cursor(CursorMove::End);
            false
        }
        _ => field.input(key),
    }
}
