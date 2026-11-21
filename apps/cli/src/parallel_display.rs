//! Switchable artwork and delivery log for the parallel join.
use super::Round;
use crossterm::{
    cursor::{Hide, MoveTo, Show},
    event::{
        self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers,
        MouseButton, MouseEventKind,
    },
    execute,
    terminal::{
        Clear, ClearType, EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode,
        enable_raw_mode,
    },
};
use ratatui::{
    Frame, Terminal,
    backend::CrosstermBackend,
    layout::{Position, Rect},
    style::{Color, Style},
    widgets::Paragraph,
};
use serde_json::Value;
use std::collections::VecDeque;
use std::io::{self, IsTerminal, Write};
use std::time::{Duration, Instant};
use unicode_width::UnicodeWidthChar;

const IMAGE_WIDTH: usize = 224;
const IMAGE_HEIGHT: usize = 126;
const IMAGE: &[u8; IMAGE_WIDTH * IMAGE_HEIGHT] = include_bytes!("../assets/parallel/luminance.bin");
const RAMP: &[u8] = b" .,:;irsXA253hMHGS#9B&@";
/// Seconds for the light to cross the artwork once.
const PASS_SECONDS: f64 = 4.0;

#[derive(Clone, Copy)]
struct Size {
    cols: usize,
    rows: usize,
    cell_aspect: f64,
}
impl Size {
    #[cfg(windows)]
    fn terminal() -> Self {
        let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
        Self {
            cols: cols.into(),
            rows: rows.into(),
            cell_aspect: 0.5,
        }
    }
    #[cfg(unix)]
    fn terminal() -> Self {
        let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
        if unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) } == 0
            && ws.ws_col > 0
            && ws.ws_row > 0
        {
            let aspect = if ws.ws_xpixel > 0 && ws.ws_ypixel > 0 {
                (f64::from(ws.ws_xpixel) / f64::from(ws.ws_col))
                    / (f64::from(ws.ws_ypixel) / f64::from(ws.ws_row))
            } else {
                0.5
            };
            Self {
                cols: ws.ws_col.into(),
                rows: ws.ws_row.into(),
                cell_aspect: aspect.clamp(0.25, 1.0),
            }
        } else {
            Self {
                cols: 80,
                rows: 24,
                cell_aspect: 0.5,
            }
        }
    }
}

fn clipped(text: &str, width: usize) -> String {
    let mut used = 0;
    text.chars()
        .filter(|c| !c.is_control())
        .take_while(|c| {
            used += c.width().unwrap_or(0);
            used <= width
        })
        .collect()
}

fn centered(text: &str, width: usize) -> String {
    let text = clipped(text, width);
    let used: usize = text.chars().map(|c| c.width().unwrap_or(0)).sum();
    format!("{}{text}", " ".repeat(width.saturating_sub(used) / 2))
}

/// Resample only when the fitted artwork size changes, not on animation ticks.
#[derive(Default)]
struct Art {
    width: usize,
    height: usize,
    samples: Vec<usize>,
}
impl Art {
    fn render(&mut self, width: usize, height: usize, phase: f64) -> Vec<String> {
        if (self.width, self.height) != (width, height) {
            self.width = width;
            self.height = height;
            self.samples.clear();
            for y in 0..height {
                let y0 = y * IMAGE_HEIGHT / height;
                let y1 = ((y + 1) * IMAGE_HEIGHT / height)
                    .max(y0 + 1)
                    .min(IMAGE_HEIGHT);
                for x in 0..width {
                    let x0 = x * IMAGE_WIDTH / width;
                    let x1 = ((x + 1) * IMAGE_WIDTH / width).max(x0 + 1).min(IMAGE_WIDTH);
                    let mut sum = 0usize;
                    for row in y0..y1 {
                        for col in x0..x1 {
                            sum += IMAGE[row * IMAGE_WIDTH + col] as usize;
                        }
                    }
                    self.samples.push(sum / ((x1 - x0) * (y1 - y0)));
                }
            }
        }
        let center = phase.rem_euclid(PASS_SECONDS) / PASS_SECONDS * 1.3 - 0.15;
        let glints: Vec<f64> = (0..width)
            .map(|x| {
                let along = (x as f64 + 0.5) / width as f64;
                (1.0 - (along - center).abs() / 0.1).max(0.0)
            })
            .collect();
        self.samples
            .chunks(width)
            .map(|row| {
                row.iter()
                    .enumerate()
                    .map(|(x, &sample)| {
                        let value = if sample > 18 {
                            sample + ((255 - sample) as f64 * glints[x] * 0.5) as usize
                        } else {
                            sample
                        };
                        RAMP[value * (RAMP.len() - 1) / 255] as char
                    })
                    .collect()
            })
            .collect()
    }
}

fn frame(
    name: &str,
    round: u64,
    state: &Round,
    status: &str,
    size: Size,
    page: usize,
    phase: f64,
    art: &mut Art,
) -> Vec<String> {
    // Leave the last column unused so drawing never triggers terminal autowrap.
    let width = size.cols.saturating_sub(1).max(1);
    let height = size.rows.max(1);
    let n = state.expected.len();
    let done = state.received.len();
    let percent = if n == 0 { 0 } else { done * 100 / n };
    let progress = format!("{done}/{n}  {percent}%");
    let mut lines = vec![String::new(); height];
    if height < 10 {
        lines[0] = clipped(&format!("{name}  {progress}"), width);
        if height > 1 {
            lines[1] = clipped(status, width);
        }
        let slots = height.saturating_sub(2);
        if slots > 0 && n > 0 {
            let page = page % n.div_ceil(slots);
            for (i, wire) in state
                .expected
                .iter()
                .skip(page * slots)
                .take(slots)
                .enumerate()
            {
                lines[i + 2] = clipped(
                    &format!(
                        "[{}] {}",
                        if state.received.contains_key(wire) {
                            "x"
                        } else {
                            " "
                        },
                        state.label(wire)
                    ),
                    width,
                );
            }
        }
        return lines;
    }
    lines[0] = centered(
        &format!("{name}  /  PARALLEL JOIN  /  ROUND {round}"),
        width,
    );
    // Bound the branch list so a large graph cannot crowd out the artwork.
    let slots = n.min((height / 5).min(6));
    let art_height = height.saturating_sub(7 + slots).max(1);
    let art_width = width.saturating_sub(2).max(1);
    let (source_width, source_height) = (IMAGE_WIDTH as f64, IMAGE_HEIGHT as f64);
    let scale = (art_width as f64 / source_width)
        .min(art_height as f64 / (source_height * size.cell_aspect));
    let draw_width = (source_width * scale).round().max(1.0) as usize;
    let draw_height = (source_height * size.cell_aspect * scale).round().max(1.0) as usize;
    let top = 2 + art_height.saturating_sub(draw_height) / 2;
    for (i, row) in art
        .render(
            draw_width.min(art_width),
            draw_height.min(art_height),
            phase,
        )
        .iter()
        .enumerate()
    {
        lines[top + i] = centered(row, width);
    }
    let footer = 3 + art_height;
    lines[footer] = centered(&progress, width);
    let bar_width = width.saturating_sub(6);
    if bar_width > 0 {
        let filled = bar_width * percent / 100;
        lines[footer + 1] = centered(
            &format!("[{}{}]", "#".repeat(filled), "-".repeat(bar_width - filled)),
            width,
        );
    }
    lines[footer + 2] = centered(status, width);
    let pages = if slots > 0 { n.div_ceil(slots) } else { 1 };
    let page = page % pages;
    for i in 0..slots {
        let Some(wire) = state.expected.get(page * slots + i) else {
            break;
        };
        let line = format!(
            "[{}] {}",
            if state.received.contains_key(wire) {
                "x"
            } else {
                " "
            },
            state.label(wire)
        );
        lines[footer + 3 + i] = centered(&line, width);
    }
    if pages > 1 {
        lines[height - 1] = centered(
            &format!(
                "Branches {}/{} (auto-page) · [x] received · [ ] waiting",
                page + 1,
                pages
            ),
            width,
        );
    }
    lines
}

#[derive(Default)]
struct LogView {
    visible: bool,
    entries: VecDeque<String>,
    text: String,
    scroll: u16,
    follow: bool,
    toggle_area: Rect,
    log_area: Rect,
}
impl LogView {
    fn append(&mut self, label: &str, payload: &Value) {
        self.entries.push_back(format!(
            "[{}] {}\n{}",
            jiff::Zoned::now().strftime("%Y-%m-%d %H:%M:%S %:z"),
            clipped(label, usize::MAX),
            serde_json::to_string_pretty(payload).expect("JSON value is serializable"),
        ));
        if self.entries.len() > 100 {
            self.entries.pop_front();
            self.scroll = 0;
        }
        if self.entries.len() == 1 {
            self.follow = true;
        }
        self.text = self
            .entries
            .iter()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .join("\n\n");
    }

    /// Returns true for Ctrl+C. View controls never affect graph delivery.
    fn input(&mut self, event: Event) -> bool {
        let scroll_by = match event {
            Event::Key(key) if key.kind != KeyEventKind::Release => {
                if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
                    return true;
                }
                match key.code {
                    KeyCode::Char('l' | 'L') | KeyCode::Tab => {
                        self.visible = !self.visible;
                        0
                    }
                    KeyCode::Up if self.visible => -1,
                    KeyCode::Down if self.visible => 1,
                    KeyCode::PageUp if self.visible => {
                        -(self.log_area.height.saturating_sub(2).max(1) as i32)
                    }
                    KeyCode::PageDown if self.visible => {
                        self.log_area.height.saturating_sub(2).max(1) as i32
                    }
                    KeyCode::Home if self.visible => {
                        self.scroll = 0;
                        self.follow = false;
                        0
                    }
                    KeyCode::End if self.visible => {
                        self.follow = true;
                        0
                    }
                    _ => 0,
                }
            }
            Event::Mouse(mouse) => {
                let point = Position::new(mouse.column, mouse.row);
                if mouse.kind == MouseEventKind::Down(MouseButton::Left)
                    && self.toggle_area.contains(point)
                {
                    self.visible = !self.visible;
                }
                if self.visible && self.log_area.contains(point) {
                    match mouse.kind {
                        MouseEventKind::ScrollUp => -3,
                        MouseEventKind::ScrollDown => 3,
                        _ => 0,
                    }
                } else {
                    0
                }
            }
            _ => 0,
        };
        if scroll_by != 0 {
            self.follow = false;
            self.scroll = (self.scroll as i32 + scroll_by).clamp(0, u16::MAX as i32) as u16;
        }
        false
    }

    fn draw_toggle(&mut self, frame: &mut Frame<'_>, interactive: bool) {
        let area = frame.area();
        let label = if self.visible {
            "[ Show image ]"
        } else {
            "[ Show log ]"
        };
        self.toggle_area = Rect::new(
            area.x,
            area.y,
            area.width.min(label.len() as u16),
            area.height.min(1),
        );
        if interactive {
            frame.render_widget(
                Paragraph::new(label).style(Style::default().fg(Color::Cyan)),
                self.toggle_area,
            );
            let help = Rect::new(
                self.toggle_area.right(),
                area.y,
                area.width.saturating_sub(self.toggle_area.width),
                area.height.min(1),
            );
            frame.render_widget(Paragraph::new("  L: toggle · Ctrl+C: exit"), help);
        }
    }

    fn draw_log(
        &mut self,
        frame: &mut Frame<'_>,
        name: &str,
        round: u64,
        state: &Round,
        status: &str,
    ) {
        let area = frame.area();
        let header = Rect::new(
            area.x,
            area.y.saturating_add(1),
            area.width,
            area.height.saturating_sub(1).min(2),
        );
        frame.render_widget(
            Paragraph::new(format!(
                "{} / round {round} / {}/{} received\n{status}",
                clipped(name, usize::MAX),
                state.received.len(),
                state.expected.len(),
            )),
            header,
        );
        self.log_area = Rect::new(
            area.x,
            area.y.saturating_add(3),
            area.width,
            area.height.saturating_sub(4),
        );
        // The shared renderer consumes its follow request; retain our follow-tail
        // preference so new entries keep scrolling until the user scrolls back.
        let mut follow = self.follow;
        crate::node_form::scrollable_text(
            frame,
            if self.text.is_empty() {
                "Waiting for input…"
            } else {
                &self.text
            },
            self.log_area,
            "Delivery log · local time · IN / OUT",
            &mut self.scroll,
            &mut follow,
        );
        if area.height > 3 {
            frame.render_widget(
                Paragraph::new("↑/↓ / PgUp/PgDn / Wheel: scroll · Home: first · End: latest"),
                Rect::new(area.x, area.bottom() - 1, area.width, 1),
            );
        }
    }
}

/// Sweep the light across the artwork once each time the combined output is
/// passed on. Arriving inputs and waiting leave the artwork still.
struct Activity {
    phase: f64,
    sampled: Instant,
    until: Instant,
}
impl Activity {
    fn new(now: Instant) -> Self {
        Self {
            phase: 0.0,
            sampled: now,
            until: now,
        }
    }
    fn sample(&mut self, now: Instant) -> f64 {
        self.phase += now
            .min(self.until)
            .saturating_duration_since(self.sampled)
            .as_secs_f64();
        self.sampled = now;
        self.phase
    }
    fn pulse(&mut self, now: Instant) {
        // Phase zero starts the light just off the left edge; one full pass
        // carries it past the right edge, where the artwork is still again.
        self.phase = 0.0;
        self.sampled = now;
        self.until = now + Duration::from_secs_f64(PASS_SECONDS);
    }
    fn active(&self, now: Instant) -> bool {
        now < self.until
    }
}

pub(super) struct Display {
    terminal: Option<Terminal<CrosstermBackend<io::Stdout>>>,
    alternate: bool,
    interactive: bool,
    last: String,
    dirty: bool,
    started: Instant,
    art: Art,
    activity: Activity,
    log: LogView,
}
impl Display {
    pub(super) fn new() -> io::Result<Self> {
        let mut display = Self {
            terminal: None,
            alternate: false,
            interactive: false,
            last: String::new(),
            dirty: true,
            started: Instant::now(),
            art: Art::default(),
            activity: Activity::new(Instant::now()),
            log: LogView::default(),
        };
        if io::stdout().is_terminal() {
            if io::stdin().is_terminal() {
                enable_raw_mode()?;
                display.interactive = true;
                execute!(io::stdout(), EnableMouseCapture)?;
            }
            display.alternate = true;
            // A fresh alternate screen has no cursor to preserve. Clear directly
            // so stdout-only displays do not need to answer a cursor query.
            execute!(
                io::stdout(),
                EnterAlternateScreen,
                Hide,
                Clear(ClearType::All),
                MoveTo(0, 0)
            )?;
            display.terminal = Some(Terminal::new(CrosstermBackend::new(io::stdout()))?);
        }
        Ok(display)
    }
    pub(super) fn log(&mut self, label: &str, payload: &Value) {
        if self.terminal.is_some() {
            self.log.append(label, payload);
            self.dirty = true;
        }
    }
    /// Log the queued combined output; only this animates the artwork.
    pub(super) fn output(&mut self, label: &str, payload: &Value) {
        self.activity.pulse(Instant::now());
        self.log(label, payload);
    }
    /// Whether the light is crossing the artwork, which needs smooth redraws.
    pub(super) fn animating(&self) -> bool {
        self.activity.active(Instant::now())
    }
    pub(super) fn poll_input(&mut self) -> io::Result<bool> {
        if self.interactive {
            // Bound work per tick even when a key is held down.
            for _ in 0..128 {
                if !event::poll(Duration::ZERO)? {
                    break;
                }
                self.dirty = true;
                if self.log.input(event::read()?) {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }
    pub(super) fn draw(
        &mut self,
        name: &str,
        round: u64,
        state: &Round,
        status: &str,
    ) -> io::Result<()> {
        if let Some(terminal) = &mut self.terminal {
            let size = Size::terminal();
            let phase = self.activity.sample(Instant::now());
            let snapshot = format!(
                "{name}\n{round}\n{}/{}\n{status}\n{}x{}",
                state.received.len(),
                state.expected.len(),
                size.cols,
                size.rows
            );
            if self.log.visible && !self.dirty && self.last == snapshot {
                return Ok(());
            }
            terminal.draw(|surface| {
                self.log.draw_toggle(surface, self.interactive);
                if self.log.visible {
                    self.log.draw_log(surface, name, round, state, status);
                } else {
                    let area = surface.area();
                    let top = u16::from(self.interactive);
                    if area.height > top {
                        let lines = frame(
                            name,
                            round,
                            state,
                            status,
                            Size {
                                cols: area.width.into(),
                                rows: (area.height - top).into(),
                                ..size
                            },
                            (self.started.elapsed().as_secs() / 5) as usize,
                            phase,
                            &mut self.art,
                        );
                        surface.render_widget(
                            Paragraph::new(lines.join("\n")),
                            Rect::new(area.x, area.y + top, area.width, area.height - top),
                        );
                    }
                }
            })?;
            self.last = snapshot;
            self.dirty = false;
        } else {
            let n = state.expected.len();
            let done = state.received.len();
            let percent = if n == 0 { 0 } else { done * 100 / n };
            let mut text = format!(
                "{} / round {round} / {done}/{n}  {percent}%\n{status}\n",
                clipped(name, usize::MAX)
            );
            for wire in &state.expected {
                text.push_str(&format!(
                    "[{}] {}\n",
                    if state.received.contains_key(wire) {
                        "x"
                    } else {
                        " "
                    },
                    state.label(wire)
                ));
            }
            if text != self.last {
                print!("{text}");
                io::stdout().flush()?;
                self.last = text;
            }
        }
        Ok(())
    }
}
impl Drop for Display {
    fn drop(&mut self) {
        if self.interactive {
            let _ = execute!(io::stdout(), DisableMouseCapture);
            let _ = disable_raw_mode();
        }
        if self.alternate {
            let _ = execute!(io::stdout(), Show, LeaveAlternateScreen);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::{KeyEvent, MouseEvent};
    use ratatui::backend::TestBackend;
    use serde_json::json;

    #[test]
    fn log_preserves_full_payloads_escapes_controls_and_bounds_history() {
        let mut log = LogView::default();
        let payload = json!({"payload":{"nested":[true,null,"한글\n\u{1b}[2J"]},"sessions":[{"path":"/tmp/session.jsonl","checkpoint":{"byte_offset":42}}]});
        log.append("IN · round 1\u{1b}", &payload);
        let (header, body) = log.text.split_once('\n').unwrap();
        assert!(header.starts_with('[') && header.ends_with("] IN · round 1"));
        assert!(!log.text.contains('\u{1b}'));
        assert_eq!(serde_json::from_str::<Value>(body).unwrap(), payload);
        for round in 2..=102 {
            log.append(&format!("OUT · round {round}"), &json!({"round":round}));
        }
        assert_eq!(log.entries.len(), 100);
        assert!(log.entries.front().unwrap().contains("] OUT · round 3\n"));
        assert!(log.entries.back().unwrap().contains("] OUT · round 102\n"));
    }

    #[test]
    fn log_toggle_scroll_follow_and_resize() {
        let mut terminal = Terminal::new(TestBackend::new(90, 16)).unwrap();
        let mut log = LogView::default();
        let draw = |terminal: &mut Terminal<TestBackend>, log: &mut LogView| {
            terminal
                .draw(|frame| {
                    log.draw_toggle(frame, true);
                    if log.visible {
                        log.draw_log(frame, "Review join", 2, &Round::default(), "Waiting");
                    }
                })
                .unwrap();
        };
        draw(&mut terminal, &mut log);
        log.input(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 3,
            row: 0,
            modifiers: KeyModifiers::NONE,
        }));
        assert!(log.visible);
        for i in 0..10 {
            log.append("IN · round 1", &json!({"text":format!("payload {i}")}));
        }
        draw(&mut terminal, &mut log);
        assert!(log.scroll > 0);
        log.input(Event::Key(KeyEvent::new(KeyCode::Home, KeyModifiers::NONE)));
        draw(&mut terminal, &mut log);
        assert_eq!(log.scroll, 0);
        log.append("OUT · round 1 · queued", &json!({"text":"combined"}));
        draw(&mut terminal, &mut log);
        assert_eq!(
            log.scroll, 0,
            "Reading earlier entries must not jump on arrival"
        );
        log.input(Event::Key(KeyEvent::new(KeyCode::End, KeyModifiers::NONE)));
        draw(&mut terminal, &mut log);
        assert!(log.scroll > 0 && log.follow);
        log.input(Event::Key(KeyEvent::new(
            KeyCode::Char('l'),
            KeyModifiers::NONE,
        )));
        assert!(!log.visible);
        log.input(Event::Key(KeyEvent::new(
            KeyCode::Char('l'),
            KeyModifiers::NONE,
        )));
        assert!(log.visible);
        for (width, height) in [(1, 1), (8, 4), (40, 12), (120, 80)] {
            terminal.backend_mut().resize(width, height);
            terminal.resize(Rect::new(0, 0, width, height)).unwrap();
            draw(&mut terminal, &mut log);
        }
        assert!(log.input(Event::Key(KeyEvent::new(
            KeyCode::Char('c'),
            KeyModifiers::CONTROL
        ))));
    }

    #[test]
    fn tall_panes_keep_the_same_left_to_right_artwork() {
        let expected: Vec<_> = Art::default()
            .render(57, 16, 0.0)
            .iter()
            .map(|line| centered(line, 59))
            .collect();
        for rows in [30, 80] {
            let lines = frame(
                "Parallel",
                1,
                &Round::default(),
                "Waiting",
                Size {
                    cols: 60,
                    rows,
                    cell_aspect: 0.5,
                },
                0,
                0.0,
                &mut Art::default(),
            );
            assert!(
                lines
                    .windows(expected.len())
                    .any(|window| window == expected)
            );
        }
    }
    #[test]
    fn only_the_combined_output_starts_the_shimmer() {
        let start = Instant::now();
        let mut display = Display {
            terminal: None,
            alternate: false,
            interactive: false,
            last: String::new(),
            dirty: true,
            started: start,
            art: Art::default(),
            activity: Activity::new(start),
            log: LogView::default(),
        };
        display.log("IN · round 1 · Worker → Join", &json!({"text":"done"}));
        assert_eq!(display.activity.until, start);
        display.output("OUT · round 1 · Combined · queued", &json!({"text":"combined"}));
        assert!(display.activity.until > start);
    }
    #[test]
    fn artwork_is_still_except_for_output_pulses() {
        let start = Instant::now();
        let at = |seconds: f64| start + Duration::from_secs_f64(seconds);
        let mut activity = Activity::new(start);
        let mut art = Art::default();
        let initial = art.render(80, 30, activity.sample(start));
        assert_eq!(initial, art.render(80, 30, activity.sample(at(10.0))));
        activity.pulse(at(10.0));
        let moving = art.render(80, 30, activity.sample(at(10.0 + PASS_SECONDS / 2.0)));
        assert_ne!(initial, moving);
        let settled = art.render(80, 30, activity.sample(at(10.0 + PASS_SECONDS)));
        assert_eq!(settled, initial);
        assert_eq!(settled, art.render(80, 30, activity.sample(at(30.0))));
        activity.pulse(at(30.0));
        assert_ne!(settled, art.render(80, 30, activity.sample(at(30.0 + PASS_SECONDS / 2.0))));
    }

    #[test]
    fn each_output_plays_one_complete_light_pass() {
        let start = Instant::now();
        let at = |fraction: f64| start + Duration::from_secs_f64(PASS_SECONDS * fraction);
        let mut activity = Activity::new(start);
        let mut art = Art::default();
        let still = art.render(80, 30, activity.sample(start));
        activity.pulse(start);
        // The light crosses the left half, then the right half, then leaves.
        let early = art.render(80, 30, activity.sample(at(0.3)));
        let late = art.render(80, 30, activity.sample(at(0.75)));
        assert!(early != still && late != still && early != late);
        assert!(activity.active(at(0.99)));
        assert!(!activity.active(at(1.0)));
        assert_eq!(art.render(80, 30, activity.sample(at(1.0))), still);
    }

    #[test]
    fn animation_changes_only_the_metal_shading() {
        {
            let mut art = Art::default();
            let first = art.render(80, 30, 0.0);
            let later = art.render(80, 30, 2.0);
            assert_ne!(first, later);
            for (before, after) in first.iter().zip(&later) {
                for (a, b) in before.chars().zip(after.chars()) {
                    if a == ' ' {
                        assert_eq!(b, ' ');
                    }
                }
            }
        }
    }
    #[test]
    fn fits_small_wide_and_tall_terminals() {
        for (cols, rows) in [(1, 1), (8, 8), (40, 12), (80, 24), (160, 48), (60, 80)] {
            let lines = frame(
                "Parallel 界\x1b\n",
                1,
                &Round::default(),
                "Connect branches",
                Size {
                    cols,
                    rows,
                    cell_aspect: 0.5,
                },
                0,
                0.0,
                &mut Art::default(),
            );
            assert_eq!(lines.len(), rows);
            for line in lines {
                assert!(
                    line.chars().map(|c| c.width().unwrap_or(0)).sum::<usize>()
                        <= cols.saturating_sub(1).max(1)
                );
                assert!(!line.chars().any(char::is_control));
            }
        }
    }

    #[test]
    fn pages_every_branch_by_title_including_small_terminals() {
        let mut state = Round::default();
        for i in 0..20 {
            let wire = super::super::Wire {
                source: format!("%{i}"),
                output: "done".into(),
                input: "join".into(),
                revision: "1".into(),
            };
            state.titles.insert(wire.clone(), format!("Worker {i:02}"));
            if i % 2 == 0 {
                state.received.insert(wire.clone(), serde_json::json!({}));
            }
            state.expected.push(wire);
        }
        for rows in [8, 24, 60] {
            let mut seen = String::new();
            for page in 0..20 {
                let lines = frame(
                    "Parallel",
                    1,
                    &state,
                    "Waiting",
                    Size {
                        cols: 80,
                        rows,
                        cell_aspect: 0.5,
                    },
                    page,
                    0.0,
                    &mut Art::default(),
                );
                assert_eq!(lines.len(), rows);
                seen.push_str(&lines.join("\n"));
            }
            for i in 0..20 {
                assert!(seen.contains(&format!(
                    "[{}] Worker {i:02}",
                    if i % 2 == 0 { "x" } else { " " }
                )));
            }
            assert!(!seen.contains("terminal:"));
        }
    }
}
