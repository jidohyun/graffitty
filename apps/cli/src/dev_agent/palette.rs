//! Provider colors from Codex's tui/style.rs and Claude Code 2.1.296's dark theme.
#[cfg(not(windows))]
use crossterm::event;
use crossterm::event::Event;
#[cfg(any(not(windows), test))]
use crossterm::event::{KeyCode, KeyModifiers};
use ratatui::style::{Color, Modifier, Style};
use std::collections::VecDeque;

#[cfg(not(windows))]
use std::{
    io::Write,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, Default, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
pub(super) struct Palette {
    pub foreground: Option<(u8, u8, u8)>,
    pub background: Option<(u8, u8, u8)>,
}

impl Palette {
    pub fn light(self) -> bool {
        self.background.is_some_and(is_light)
    }
    #[cfg(windows)]
    pub fn query() -> (Self, VecDeque<Event>) {
        use windows_sys::Win32::System::Console::{
            CONSOLE_SCREEN_BUFFER_INFOEX, GetConsoleScreenBufferInfoEx, GetStdHandle,
            STD_OUTPUT_HANDLE,
        };
        // crossterm's Windows backend maps KEY_EVENT_RECORD by virtual key.
        // ConPTY's OSC replies contain zero-VK control characters, which that
        // backend drops.
        //
        // Query the console directly instead of leaking the printable
        // remainder of a reply into the user's prompt.
        let mut info: CONSOLE_SCREEN_BUFFER_INFOEX = unsafe { std::mem::zeroed() };
        info.cbSize = std::mem::size_of_val(&info) as u32;
        if unsafe { GetConsoleScreenBufferInfoEx(GetStdHandle(STD_OUTPUT_HANDLE), &mut info) } == 0
        {
            return (Self::default(), VecDeque::new());
        }
        let rgb = |color: u32| (color as u8, (color >> 8) as u8, (color >> 16) as u8);
        (
            Self {
                foreground: Some(rgb(info.ColorTable[(info.wAttributes & 0x0f) as usize])),
                background: Some(rgb(
                    info.ColorTable[((info.wAttributes >> 4) & 0x0f) as usize]
                )),
            },
            VecDeque::new(),
        )
    }

    // Crossterm exposes OSC replies as key events. Query before drawing or reading
    // user input, remove only complete color replies, and replay all other events.
    // This avoids a second stdin reader swallowing typing during startup.
    #[cfg(not(windows))]
    pub fn query() -> (Self, VecDeque<Event>) {
        let mut palette = Self::default();
        let mut events = Vec::new();
        let mut output = std::io::stdout();
        if output
            .write_all(b"\x1b]10;?\x07\x1b]11;?\x07")
            .and_then(|_| output.flush())
            .is_err()
        {
            return (palette, events.into());
        }
        let deadline = Instant::now() + Duration::from_millis(250);
        while Instant::now() < deadline {
            if !event::poll(deadline.saturating_duration_since(Instant::now())).unwrap_or(false) {
                break;
            }
            let Ok(event) = event::read() else { break };
            events.push(event);
            palette.extract_replies(&mut events);
            if palette.foreground.is_some() && palette.background.is_some() {
                break;
            }
        }
        (palette, events.into())
    }

    #[cfg(any(not(windows), test))]
    fn extract_replies(&mut self, events: &mut Vec<Event>) {
        let Some(Event::Key(end)) = events.last() else {
            return;
        };
        if !((end.code == KeyCode::Char('g') && end.modifiers == KeyModifiers::CONTROL)
            || (end.code == KeyCode::Char('\\') && end.modifiers == KeyModifiers::ALT))
        {
            return;
        }
        let Some(start) = events.iter().rposition(|e| {
            matches!(e, Event::Key(k)
            if k.code == KeyCode::Char(']') && k.modifiers == KeyModifiers::ALT)
        }) else {
            return;
        };
        let payload: Option<String> = events[start + 1..events.len() - 1]
            .iter()
            .map(|e| match e {
                Event::Key(k)
                    if !k
                        .modifiers
                        .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT) =>
                {
                    match k.code {
                        KeyCode::Char(c) => Some(c),
                        _ => None,
                    }
                }
                _ => None,
            })
            .collect();
        let Some(payload) = payload else { return };
        let Some((which, value)) = payload.split_once(';') else {
            return;
        };
        if !matches!(which, "10" | "11") {
            return;
        }
        let Some(rgb) = parse_rgb(value) else { return };
        if which == "10" {
            self.foreground = Some(rgb)
        } else {
            self.background = Some(rgb)
        }
        events.truncate(start);
    }

    pub fn codex_background(self, history: bool) -> Color {
        let Some(bg) = self.background else {
            return Color::Reset;
        };
        let light = is_light(bg);
        let alpha = match (light, history) {
            (true, false) => 0.04,
            (true, true) => 0.02,
            (false, false) => 0.12,
            (false, true) => 0.16,
        };
        blend(if light { (0, 0, 0) } else { (255, 255, 255) }, bg, alpha)
    }

    pub fn codex_accent(self) -> Color {
        if self.background.is_some_and(is_light) {
            Color::Rgb(28, 100, 200)
        } else {
            Color::Rgb(99, 168, 248)
        }
    }

    pub fn codex_secondary(self) -> Style {
        Style::default().fg(match (self.foreground, self.background) {
            (Some(fg), Some(bg)) => blend(fg, bg, 0.6),
            _ => Color::Reset,
        })
    }
}

pub(super) fn faint() -> Style {
    Style::default().add_modifier(Modifier::DIM)
}

fn is_light((r, g, b): (u8, u8, u8)) -> bool {
    0.299 * r as f32 + 0.587 * g as f32 + 0.114 * b as f32 > 128.0
}

pub(super) fn blend(fg: (u8, u8, u8), bg: (u8, u8, u8), alpha: f32) -> Color {
    let channel = |f, b| (f as f32 * alpha + b as f32 * (1.0 - alpha)) as u8;
    Color::Rgb(
        channel(fg.0, bg.0),
        channel(fg.1, bg.1),
        channel(fg.2, bg.2),
    )
}

#[cfg(any(not(windows), test))]
fn parse_rgb(value: &str) -> Option<(u8, u8, u8)> {
    let mut channels = value.strip_prefix("rgb:")?.split('/');
    let mut channel = || {
        let s = channels.next()?;
        if s.is_empty() || s.len() > 4 {
            return None;
        }
        Some((u32::from_str_radix(s, 16).ok()? * 255 / ((1u32 << (s.len() * 4)) - 1)) as u8)
    };
    let rgb = (channel()?, channel()?, channel()?);
    channels.next().is_none().then_some(rgb)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyEvent;

    #[test]
    fn source_shading_for_dark_light_and_unknown_terminals() {
        let mut p = Palette {
            background: Some((40, 42, 54)),
            foreground: None,
        };
        assert_eq!(p.codex_background(false), Color::Rgb(65, 67, 78));
        assert_eq!(p.codex_background(true), Color::Rgb(74, 76, 86));
        p.background = Some((255, 255, 255));
        assert_eq!(p.codex_background(false), Color::Rgb(244, 244, 244));
        assert_eq!(p.codex_background(true), Color::Rgb(249, 249, 249));
        assert_eq!(Palette::default().codex_background(false), Color::Reset);
    }

    #[test]
    fn color_replies_preserve_interleaved_typing_and_paste() {
        let mut p = Palette::default();
        let typed = Event::Paste("hello 한글".into());
        let mut events = vec![typed.clone()];
        for (which, terminator) in [
            (
                "10",
                KeyEvent::new(KeyCode::Char('g'), KeyModifiers::CONTROL),
            ),
            ("11", KeyEvent::new(KeyCode::Char('\\'), KeyModifiers::ALT)),
        ] {
            events.push(Event::Key(KeyEvent::new(
                KeyCode::Char(']'),
                KeyModifiers::ALT,
            )));
            events.extend(
                format!("{which};rgb:2828/2a2a/3636")
                    .chars()
                    .map(|c| Event::Key(KeyEvent::new(KeyCode::Char(c), KeyModifiers::NONE))),
            );
            events.push(Event::Key(terminator));
            p.extract_replies(&mut events);
        }
        assert_eq!(p.background, Some((40, 42, 54)));
        assert_eq!(p.foreground, p.background);
        assert_eq!(events, vec![typed]);
        assert_eq!(parse_rgb("rgb:f/80/ffff"), Some((255, 128, 255)));
        assert_eq!(parse_rgb("rgb:00/00/00/ff"), None);
    }
}
