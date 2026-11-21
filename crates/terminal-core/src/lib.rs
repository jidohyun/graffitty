//! Terminal semantics shared by native session owners and graphical frontends.
//!
//! This crate owns no PTYs, windows, native clipboard, GPU objects, or network
//! connections. A terminal remains on its owning thread. Frontends translate
//! native events and render the VT; session owners transport its bytes.
//!
//! Authoritative terminals may answer application queries and resolve local
//! image paths. Mirrors receive the resulting stream/checkpoint, must not
//! open peer-supplied paths, and must not send replay-generated replies back
//! to the application's PTY.
//!
//! Those input/reply queues remain the consumer's concern; [`images::Policy`]
//! makes the image part of this distinction explicit.

pub mod binding_core;
pub mod checkpoint;
pub mod clipboard_core;
pub mod command_input;
pub mod copy_mode;
pub mod images;
pub mod image_render;
pub mod scene;
pub mod presentation_stream;
pub mod inline_images;
pub mod key_encoding;
pub mod limits;
pub mod navigation;
pub mod notification_protocol;
pub mod effect_holds;
pub mod program_status;
pub mod progress;
pub mod protocol;
pub mod quick_select;
pub mod screen;
pub mod selection;
pub mod terminal_text;
pub mod text_words;
pub mod theme;
pub mod visible_area;

/// The pinned VT integration used by every adapter and renderer.
pub use libghostty_vt as vt;

/// A libghostty terminal whose scrollback is budgeted in bytes. `usize::MAX`
/// leaves it unbounded. The line limit stays off: Graffitty budgets bytes only.
pub fn new_vt<'alloc: 'cb, 'cb>(
    cols: u16,
    rows: u16,
    scrollback_bytes: usize,
) -> Result<vt::Terminal<'alloc, 'cb>, vt::Error> {
    let mut terminal = vt::Terminal::new(cols, rows)?;
    // None resets Ghostty's default byte budget; an explicit MAX means unlimited.
    terminal
        .set_scrollback_max_bytes(Some(scrollback_bytes))?
        .set_scrollback_max_lines(None)?;
    Ok(terminal)
}
pub use limits::TerminalLimits;
/// Compatibility name used by the session-server and existing frontends.
pub use protocol as terminal_protocol;

/// Terminal operations are synchronous and retain the existing error contract.
pub type Error = Box<dyn std::error::Error>;

#[cfg(test)]
mod tests {
    #[test]
    fn scrollback_budget_is_explicit_even_when_unlimited() {
        for budget in [0, 64, 16 * 1024 * 1024, usize::MAX] {
            let vt = super::new_vt(80, 24, budget).unwrap();
            assert_eq!(vt.scrollback_max_bytes().unwrap(), (budget != usize::MAX).then_some(budget));
            assert_eq!(vt.scrollback_max_lines().unwrap(), None);
        }
    }
}
