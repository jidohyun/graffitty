//! Reusable terminal fields; graph events continue to use the host socket.
use crate::{agent_bridge::Result, text_edit::input as edit_field};
#[cfg(test)]
use crossterm::event::KeyEvent;
#[cfg(unix)]
use crossterm::event::{
    KeyboardEnhancementFlags, PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use crossterm::{
    event::{
        self, DisableBracketedPaste, DisableMouseCapture, EnableBracketedPaste, EnableMouseCapture,
        Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton, MouseEventKind,
    },
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use ratatui::{
    Frame, Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Layout, Position, Rect},
    style::{Color, Style},
    widgets::{
        Block, Borders, Clear, Paragraph, Scrollbar, ScrollbarOrientation, ScrollbarState, Wrap,
    },
};
use ratatui_textarea::{CursorMove, TextArea};
use std::{io, time::Duration};
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

pub enum Action {
    None,
    Apply,
    Pause,
    Preview,
    Save,
    Edit,
    Quit,
}
#[derive(Debug)]
struct Dropdown {
    field: usize,
    selected: usize,
    offset: usize,
    area: Rect,
}
impl Dropdown {
    fn move_by(&mut self, delta: isize, count: usize) {
        self.selected = self
            .selected
            .saturating_add_signed(delta)
            .min(count.saturating_sub(1));
    }
}
pub struct Form {
    terminal: Terminal<CrosstermBackend<io::Stdout>>,
    fields: Vec<(&'static str, TextArea<'static>)>,
    focus: usize,
    field_areas: Vec<Rect>,
    field_offsets: Vec<(usize, usize)>,
    sample_area: Rect,
    dragging: Option<usize>,
    sample_scroll: u16,
    dirty: bool,
    last_status: String,
    last_sample: String,
    title: String,
    preview: Option<String>,
    action_areas: Vec<Rect>,
    log: String,
    log_area: Rect,
    log_scroll: u16,
    log_follow: bool,
    configuration: bool,
    session_reader: bool,
    choices: Vec<(usize, Vec<&'static str>)>,
    settings_rows: Vec<(Vec<usize>, u16)>,
    settings_area: Rect,
    settings_scroll: u16,
    settings_follow: bool,
    settings_summary: Option<String>,
    running: Option<bool>,
    run_area: Rect,
    dropdown: Option<Dropdown>,
}
impl Form {
    pub fn new(fields: Vec<(&'static str, String)>) -> Result<Self> {
        enable_raw_mode()?;
        if let Err(error) = execute!(
            io::stdout(),
            EnterAlternateScreen,
            EnableBracketedPaste,
            EnableMouseCapture
        ) {
            let _ = execute!(
                io::stdout(),
                DisableMouseCapture,
                DisableBracketedPaste,
                LeaveAlternateScreen
            );
            let _ = disable_raw_mode();
            return Err(error.into());
        }
        let terminal = match Terminal::new(CrosstermBackend::new(io::stdout())) {
            Ok(terminal) => terminal,
            Err(error) => {
                let _ = disable_raw_mode();
                let _ = execute!(
                    io::stdout(),
                    LeaveAlternateScreen,
                    DisableBracketedPaste,
                    DisableMouseCapture
                );
                return Err(error.into());
            }
        };
        let count = fields.len();
        // Distinguish Ctrl+Enter from plain Enter in terminals using CSI-u.
        #[cfg(unix)]
        if let Err(error) = execute!(
            io::stdout(),
            PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
        ) {
            let _ = execute!(
                io::stdout(),
                PopKeyboardEnhancementFlags,
                DisableMouseCapture,
                DisableBracketedPaste,
                LeaveAlternateScreen
            );
            let _ = disable_raw_mode();
            return Err(error.into());
        }
        Ok(Self {
            terminal,
            fields: fields
                .into_iter()
                .map(|(label, value)| (label, TextArea::from(value.lines())))
                .collect(),
            focus: 0,
            field_areas: vec![Rect::default(); count],
            field_offsets: vec![(0, 0); count],
            sample_area: Rect::default(),
            dragging: None,
            sample_scroll: 0,
            dirty: true,
            last_status: String::new(),
            last_sample: String::new(),
            title: "Filter".into(),
            preview: None,
            action_areas: Vec::new(),
            log: String::new(),
            log_area: Rect::default(),
            log_scroll: 0,
            log_follow: true,
            configuration: false,
            session_reader: false,
            choices: Vec::new(),
            settings_rows: Vec::new(),
            settings_area: Rect::default(),
            settings_scroll: 0,
            settings_follow: true,
            settings_summary: None,
            running: None,
            run_area: Rect::default(),
            dropdown: None,
        })
    }
    pub fn session_reader(fields: Vec<(&'static str, String)>) -> Result<Self> {
        let mut form = Self::new(fields)?;
        form.session_reader = true;
        form.title = "Read Session File".into();
        Ok(form)
    }
    pub fn chat(title: &str, fields: Vec<(&'static str, String)>) -> Result<Self> {
        let mut form = Self::new(fields)?;
        form.title = format!(
            "{title} Send · Tab: field · Click/drag: select · Wheel: scroll · Ctrl+C: exit"
        );
        form.preview = Some(String::new());
        Ok(form)
    }
    pub fn settings(
        title: &str,
        fields: Vec<(&'static str, String)>,
        choices: Vec<(usize, Vec<&'static str>)>,
        rows: Vec<(Vec<usize>, u16)>,
    ) -> Result<Self> {
        let mut form = Self::new(fields)?;
        form.title = title.into();
        form.configuration = true;
        form.choices = choices;
        form.settings_rows = rows;
        Ok(form)
    }
    /// Change visible settings without discarding field contents or undo history.
    pub fn set_settings_rows(&mut self, rows: Vec<(Vec<usize>, u16)>) {
        if self.settings_rows == rows {
            return;
        }
        if !rows.iter().any(|(fields, _)| fields.contains(&self.focus)) {
            self.focus = rows
                .iter()
                .flat_map(|(fields, _)| fields)
                .copied()
                .next()
                .unwrap_or(0);
        }
        self.settings_rows = rows;
        self.dropdown = None;
        self.dragging = None;
        self.field_areas.fill(Rect::default());
        self.settings_scroll = 0;
        self.settings_follow = true;
        self.dirty = true;
    }
    pub fn set_log(&mut self, log: &str) {
        if self.log != log {
            self.log = log.to_owned();
            self.log_follow = true;
            self.dirty = true;
        }
    }
    pub fn set_running(&mut self, running: bool) {
        if self.running != Some(running) {
            self.running = Some(running);
            self.dirty = true;
        }
    }
    pub fn set_settings_summary(&mut self, text: &str) {
        if self.settings_summary.as_deref() != Some(text) {
            self.settings_summary = Some(text.to_owned());
            self.dirty = true;
        }
    }
    pub fn set_preview(&mut self, preview: &str) {
        if self.preview.as_deref() != Some(preview) {
            self.preview = Some(preview.to_owned());
            self.dirty = true;
        }
    }
    pub fn values(&self) -> Vec<String> {
        self.fields
            .iter()
            .map(|(_, field)| field.lines().join("\n"))
            .collect()
    }
    fn options(&self, field: usize) -> Option<&[&'static str]> {
        self.choices
            .iter()
            .find(|(index, values)| *index == field && !values.is_empty())
            .map(|(_, values)| values.as_slice())
    }
    fn open_dropdown(&mut self) {
        if let Some(options) = self.options(self.focus) {
            let current = self.fields[self.focus].1.lines().join("\n");
            let selected = options
                .iter()
                .position(|value| *value == current)
                .unwrap_or(0);
            self.dropdown = Some(Dropdown {
                field: self.focus,
                selected,
                offset: 0,
                area: Rect::default(),
            });
            self.dragging = None;
            self.dirty = true;
        }
    }
    fn choose_dropdown(&mut self) -> Action {
        let Some(menu) = self.dropdown.take() else {
            return Action::None;
        };
        let value = self.options(menu.field).unwrap()[menu.selected];
        self.dirty = true;
        if self.fields[menu.field].1.lines().join("\n") == value {
            return Action::None;
        }
        self.fields[menu.field].1 = TextArea::from([value]);
        Action::Edit
    }
    fn dropdown_event(&mut self, event: &Event) -> Option<Action> {
        let menu = self.dropdown.as_ref()?;
        let options = self.options(menu.field).unwrap().to_vec();
        self.dirty = true;
        match event {
            Event::Key(key) if key.kind != KeyEventKind::Release => {
                if key.modifiers.contains(KeyModifiers::CONTROL)
                    && matches!(key.code, KeyCode::Char('c' | 'r' | 's'))
                {
                    self.dropdown = None;
                    return None;
                }
                match key.code {
                    KeyCode::Esc => self.dropdown = None,
                    KeyCode::Enter | KeyCode::Char(' ') => return Some(self.choose_dropdown()),
                    KeyCode::Up => self.dropdown.as_mut().unwrap().move_by(-1, options.len()),
                    KeyCode::Down => self.dropdown.as_mut().unwrap().move_by(1, options.len()),
                    KeyCode::PageUp => self.dropdown.as_mut().unwrap().move_by(-5, options.len()),
                    KeyCode::PageDown => self.dropdown.as_mut().unwrap().move_by(5, options.len()),
                    KeyCode::Home => self.dropdown.as_mut().unwrap().selected = 0,
                    KeyCode::End => self.dropdown.as_mut().unwrap().selected = options.len() - 1,
                    KeyCode::Tab | KeyCode::BackTab => {
                        self.dropdown = None;
                        self.next_field(key.code == KeyCode::BackTab);
                    }
                    KeyCode::Char(c)
                        if key.modifiers.is_empty() || key.modifiers == KeyModifiers::SHIFT =>
                    {
                        let menu = self.dropdown.as_mut().unwrap();
                        if let Some(next) = (1..=options.len())
                            .map(|n| (menu.selected + n) % options.len())
                            .find(|i| {
                                options[*i]
                                    .to_lowercase()
                                    .starts_with(c.to_lowercase().to_string().as_str())
                            })
                        {
                            menu.selected = next;
                        }
                    }
                    _ => {}
                }
            }
            Event::Mouse(mouse) => {
                let menu = self.dropdown.as_mut().unwrap();
                let point = Position::new(mouse.column, mouse.row);
                let inner = Block::bordered().inner(menu.area);
                match mouse.kind {
                    MouseEventKind::Down(MouseButton::Left) => {
                        if inner.contains(point) {
                            menu.selected =
                                (menu.offset + (point.y - inner.y) as usize).min(options.len() - 1);
                            return Some(self.choose_dropdown());
                        }
                        if !menu.area.contains(point) {
                            self.dropdown = None;
                        }
                    }
                    MouseEventKind::ScrollDown => menu.move_by(1, options.len()),
                    MouseEventKind::ScrollUp => menu.move_by(-1, options.len()),
                    _ => {}
                }
            }
            Event::Resize(_, _) => {
                self.dropdown = None;
                return None;
            }
            _ => {}
        }
        Some(Action::None)
    }
    fn point_cursor(&mut self, index: usize, point: Position) {
        point_field_cursor(
            &mut self.fields[index].1,
            self.field_areas[index],
            self.field_offsets[index],
            point,
        );
    }

    pub fn tick(&mut self, status: &str, sample: &str) -> Result<Action> {
        if sample != self.last_sample {
            self.sample_scroll = 0;
        }
        if self.dirty || status != self.last_status || sample != self.last_sample {
            let focus = self.focus;
            for (i, (label, field)) in self.fields.iter_mut().enumerate() {
                field.set_block(
                    Block::default()
                        .borders(Borders::ALL)
                        .title(*label)
                        .border_style(Style::default().fg(if i == focus {
                            Color::Cyan
                        } else {
                            Color::DarkGray
                        })),
                );
                // Use the terminal cursor, so terminal-owned effects and IME
                // follow the caret rather than the last repainted widget.
                field.set_cursor_style(Style::default());
            }
            self.terminal.draw(|frame| {
            if self.session_reader {
                let areas = Layout::vertical([Constraint::Length(3), Constraint::Length(3), Constraint::Length(3), Constraint::Length(3), Constraint::Length(3), Constraint::Min(3)]).split(frame.area());
                frame.render_widget(Paragraph::new("Read Session File · Tab / Shift+Tab: field · Ctrl+C: exit\nClick / drag: edit · Wheel / PgUp / PgDn: scroll · Editing pauses delivery"), areas[0]);
                let actions = Rect::new(areas[0].x, areas[0].y + 2, areas[0].width, 1);
                self.action_areas = Layout::horizontal([Constraint::Length(20), Constraint::Min(20)]).split(actions).to_vec();
                for (i, title) in ["[ Preview · F5 ]", "[ Read now · Ctrl+Enter ]"].iter().enumerate() {
                    frame.render_widget(Paragraph::new(*title).style(Style::default().fg(Color::Cyan)), self.action_areas[i]);
                }
                for (i, (_, field)) in self.fields.iter().enumerate() {
                    self.field_areas[i] = areas[i + 1];
                    render_field(frame, field, areas[i + 1], &mut self.field_offsets[i], i == focus);
                }
                frame.render_widget(Paragraph::new(status).wrap(Wrap { trim: false }).block(Block::bordered().title("Status")), areas[4]);
                self.run_area = render_run_control(frame, areas[4], self.running);
                self.sample_area = areas[5];
                scrollable_text(frame, sample, self.sample_area, "Expanded messages", &mut self.sample_scroll, &mut false);
                return;
            }
            if self.configuration {
                let sections = Layout::vertical([Constraint::Length(3), Constraint::Min(1)]).split(frame.area());
                frame.render_widget(Paragraph::new(format!("{} · Tab / Shift+Tab: field · Enter / F2: dropdown · Ctrl+Enter: apply · Ctrl+S: save · Ctrl+C: exit\nF6: select all · Ctrl+Z / Alt+Z: undo/redo\nWheel: scroll · Long fields accept multiple lines · Editing pauses routing", self.title)), sections[0]);
                let wide = frame.area().width >= 90;
                let panes = if wide {
                    Layout::horizontal([Constraint::Percentage(62), Constraint::Percentage(38)]).split(sections[1])
                } else {
                    Layout::vertical([Constraint::Percentage(65), Constraint::Percentage(35)]).split(sections[1])
                };
                self.settings_area = panes[0];
                let visible = settings_layout(self.settings_area, &self.settings_rows, focus, &mut self.settings_scroll, self.settings_follow);
                self.settings_follow = false;
                self.field_areas.fill(Rect::default());
                for (i, area) in visible {
                    self.field_areas[i] = area;
                    if self.choices.iter().any(|(index, values)| *index == i && !values.is_empty()) {
                        frame.render_widget(Paragraph::new(format!("{}  ▾", self.fields[i].1.lines().join(""))).block(
                            Block::bordered().title(self.fields[i].0).border_style(Style::default().fg(if i == focus {Color::Cyan} else {Color::DarkGray}))
                        ), area);
                    } else {
                        render_field(frame, &self.fields[i].1, area, &mut self.field_offsets[i], i == focus);
                    }
                }
                let total = self.settings_rows.iter().map(|(_, height)| *height as usize).sum();
                draw_scrollbar(frame, self.settings_area, total, self.settings_scroll);
                let info = Layout::vertical([Constraint::Length(if wide { if self.settings_summary.is_some() { 7 } else { 5 } } else { 3 }), Constraint::Length(if self.settings_summary.is_some() { if wide { 9 } else { 4 } } else { 0 }), Constraint::Min(1)]).split(panes[1]);
                frame.render_widget(Paragraph::new(status).wrap(Wrap { trim: false }).block(Block::bordered().title("Status")), info[0]);
                self.run_area = render_run_control(frame, info[0], self.running);
                if let Some(summary) = &self.settings_summary {
                    frame.render_widget(Paragraph::new(summary.as_str()).wrap(Wrap { trim: false }).block(Block::bordered().title("Schedule")), info[1]);
                }
                self.log_area = info[2];
                scrollable_text(frame, &self.log, self.log_area, "Log", &mut self.log_scroll, &mut self.log_follow);
                if let Some(menu) = &mut self.dropdown {
                    let options = &self.choices.iter().find(|(i,_)| *i == menu.field).unwrap().1;
                    render_dropdown(frame, menu, self.field_areas[menu.field], options);
                }
                return;
            }
            let mut sizes = vec![Constraint::Length(2)];
            sizes.extend(self.fields.iter().map(|(label, _)| Constraint::Length(if self.preview.is_some() && label.starts_with("Message template") { 7 } else { 3 })));
            sizes.extend([Constraint::Length(4), Constraint::Min(3)]);
            if self.preview.is_some() { sizes.push(Constraint::Length(8)); }
            let areas = Layout::vertical(sizes).split(frame.area());
            if self.preview.is_some() {
                frame.render_widget(Paragraph::new(self.title.as_str()), Rect::new(areas[0].x, areas[0].y, areas[0].width, 1));
                let actions = Rect::new(areas[0].x, areas[0].y + 1, areas[0].width, 1);
                self.action_areas = Layout::horizontal([Constraint::Length(18), Constraint::Length(22), Constraint::Min(18)]).split(actions).to_vec();
                for (i, title) in ["[ Preview · F5 ]", "[ Apply · Ctrl+Enter ]", "[ Save · Ctrl+S ]"].iter().enumerate() {
                    frame.render_widget(Paragraph::new(*title).style(Style::default().fg(Color::Cyan)), self.action_areas[i]);
                }
            } else {
                frame.render_widget(Paragraph::new("Filter · Tab / Shift+Tab: field · Ctrl+Enter: apply & retry · Ctrl+C: exit\nClick / drag: edit · Wheel: scroll · PgUp/PgDn: inspect · Editing pauses delivery."), areas[0]);
            }
            for (i, (_, field)) in self.fields.iter().enumerate() {
                let area = areas[i+1];
                self.field_areas[i] = area;
                render_field(frame, field, area, &mut self.field_offsets[i], i == focus);
            }
            self.sample_area = areas[self.fields.len()+2];
            if self.preview.is_some() {
                self.log_area = areas[self.fields.len()+3];
                scrollable_text(frame, &self.log, self.log_area, "Delivery log · local time", &mut self.log_scroll, &mut self.log_follow);
            }
            frame.render_widget(Paragraph::new(status).wrap(Wrap{trim:false}).block(Block::bordered().title("Status")), areas[self.fields.len()+1]);
                self.run_area = render_run_control(frame, areas[self.fields.len()+1], self.running);
            if let Some(preview) = &self.preview {
                let panes = Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).split(self.sample_area);
                scrollable_text(frame, sample, panes[0], "Incoming event", &mut self.sample_scroll.clone(), &mut false);
                scrollable_text(frame, preview, panes[1], "Preview · never sends", &mut self.sample_scroll.clone(), &mut false);
            } else {
                scrollable_text(frame, sample, self.sample_area, "Latest incoming event · inspect custom fields here", &mut self.sample_scroll, &mut false);
            }
        })?;
            self.dirty = false;
            self.last_status = status.to_owned();
            self.last_sample = sample.to_owned();
        }
        if !event::poll(Duration::from_millis(100))? {
            return Ok(Action::None);
        }
        let event = event::read()?;
        if let Some(action) = self.dropdown_event(&event) {
            return Ok(action);
        }
        match event {
            Event::Key(key) if key.kind != KeyEventKind::Release => {
                if key.modifiers.contains(KeyModifiers::CONTROL) {
                    match key.code {
                        KeyCode::Char('c') => return Ok(Action::Quit),
                        KeyCode::Enter => return Ok(Action::Apply),
                        KeyCode::Char('s') if self.preview.is_some() || self.configuration => {
                            return Ok(Action::Save);
                        }
                        _ => {}
                    }
                }
                self.dirty = true;
                self.settings_follow = true;
                match key.code {
                    KeyCode::Enter
                    | KeyCode::Char(' ')
                    | KeyCode::F(2)
                    | KeyCode::Down
                    | KeyCode::Up
                        if self.options(self.focus).is_some() =>
                    {
                        self.open_dropdown()
                    }
                    KeyCode::F(5) if self.preview.is_some() || self.session_reader => {
                        return Ok(Action::Preview);
                    }
                    KeyCode::PageDown => self.sample_scroll = self.sample_scroll.saturating_add(5),
                    KeyCode::PageUp => self.sample_scroll = self.sample_scroll.saturating_sub(5),
                    KeyCode::Tab => self.next_field(false),
                    KeyCode::BackTab => self.next_field(true),
                    _ => {
                        if self.options(self.focus).is_none()
                            && edit_field(&mut self.fields[self.focus].1, key)
                        {
                            return Ok(Action::Edit);
                        }
                    }
                }
            }
            Event::Mouse(mouse) => {
                let point = Position::new(mouse.column, mouse.row);
                let hovered = self
                    .field_areas
                    .iter()
                    .position(|area| area.contains(point));
                match mouse.kind {
                    MouseEventKind::Down(MouseButton::Left) => {
                        if self.run_area.contains(point) {
                            return Ok(if self.running == Some(true) { Action::Pause } else { Action::Apply });
                        }
                        if let Some(index) = self
                            .action_areas
                            .iter()
                            .position(|area| area.contains(point))
                        {
                            return Ok(match index {
                                0 => Action::Preview,
                                1 => Action::Apply,
                                _ => Action::Save,
                            });
                        }
                        if let Some(index) = hovered {
                            self.focus = index;
                            if self.options(index).is_some() {
                                self.open_dropdown();
                                return Ok(Action::None);
                            }
                            self.fields[index].1.cancel_selection();
                            self.point_cursor(index, point);
                            self.fields[index].1.start_selection();
                            self.dragging = Some(index);
                            self.dirty = true;
                        }
                    }
                    MouseEventKind::Drag(MouseButton::Left) => {
                        if let Some(index) = self.dragging {
                            self.point_cursor(index, point);
                            self.dirty = true;
                        }
                    }
                    MouseEventKind::Up(MouseButton::Left) => self.dragging = None,
                    MouseEventKind::ScrollDown | MouseEventKind::ScrollUp => {
                        let down = mouse.kind == MouseEventKind::ScrollDown;
                        if self.log_area.contains(point) {
                            self.log_follow = false;
                            self.log_scroll = if down {
                                self.log_scroll.saturating_add(3)
                            } else {
                                self.log_scroll.saturating_sub(3)
                            };
                            self.dirty = true;
                        } else if self.configuration
                            && self.settings_area.contains(point)
                            && hovered.is_none_or(|i| {
                                self.fields[i].1.lines().len()
                                    <= self.field_areas[i].height.saturating_sub(2) as usize
                            })
                        {
                            self.settings_scroll = if down {
                                self.settings_scroll.saturating_add(3)
                            } else {
                                self.settings_scroll.saturating_sub(3)
                            };
                            self.settings_follow = false;
                            self.dirty = true;
                        } else if self.sample_area.contains(point) {
                            self.sample_scroll = if down {
                                self.sample_scroll.saturating_add(3)
                            } else {
                                self.sample_scroll.saturating_sub(3)
                            };
                            self.dirty = true;
                        } else if let Some(index) = hovered {
                            for _ in 0..3 {
                                self.fields[index].1.move_cursor(if down {
                                    CursorMove::Down
                                } else {
                                    CursorMove::Up
                                });
                            }
                            self.dirty = true;
                        }
                    }
                    _ => {}
                }
            }
            Event::Resize(_, _) => {
                self.dragging = None;
                self.dirty = true;
                self.settings_follow = true;
                self.log_follow = true;
            }
            Event::Paste(text) => {
                if self.options(self.focus).is_some() {
                    return Ok(Action::None);
                }
                self.dirty = true;
                self.settings_follow = true;
                self.fields[self.focus].1.insert_str(text);
                return Ok(Action::Edit);
            }
            _ => {}
        }
        Ok(Action::None)
    }
    fn next_field(&mut self, backwards: bool) {
        let order: Vec<usize> = if self.configuration {
            self.settings_rows
                .iter()
                .flat_map(|(fields, _)| fields.iter().copied())
                .collect()
        } else {
            (0..self.fields.len()).collect()
        };
        let index = order.iter().position(|i| *i == self.focus).unwrap_or(0);
        self.focus = order[(index + if backwards { order.len() - 1 } else { 1 }) % order.len()];
    }
}
fn render_run_control(frame: &mut Frame<'_>, status: Rect, running: Option<bool>) -> Rect {
    let Some(running) = running else { return Rect::default() };
    if status.width < 20 || status.height == 0 { return Rect::default(); }
    let area = Rect::new(status.right() - 12, status.y, 11, 1);
    frame.render_widget(
        Paragraph::new(if running { "[ Pause ]" } else { "[ Start ]" })
            .style(Style::default().fg(Color::Cyan)), area);
    area
}
fn render_dropdown(frame: &mut Frame<'_>, menu: &mut Dropdown, anchor: Rect, options: &[&str]) {
    let bounds = frame.area();
    let height = (options.len() as u16 + 2).min(bounds.height);
    let width = anchor
        .width
        .max(
            options
                .iter()
                .map(|s| s.width() as u16 + 4)
                .max()
                .unwrap_or(4),
        )
        .min(bounds.width);
    let y = if bounds.bottom().saturating_sub(anchor.bottom()) >= height {
        anchor.bottom()
    } else if anchor.y.saturating_sub(bounds.y) >= height {
        anchor.y - height
    } else {
        bounds.bottom().saturating_sub(height)
    };
    menu.area = Rect::new(
        anchor
            .x
            .min(bounds.right().saturating_sub(width))
            .max(bounds.x),
        y,
        width,
        height,
    );
    let rows = height.saturating_sub(2) as usize;
    menu.offset = menu.offset.min(menu.selected);
    if menu.selected >= menu.offset + rows {
        menu.offset = (menu.selected + 1).saturating_sub(rows);
    }
    frame.render_widget(Clear, menu.area);
    frame.render_widget(
        Block::bordered().border_style(Style::default().fg(Color::Cyan)),
        menu.area,
    );
    let inner = Block::bordered().inner(menu.area);
    for (row, (index, value)) in options
        .iter()
        .enumerate()
        .skip(menu.offset)
        .take(rows)
        .enumerate()
    {
        let style = if index == menu.selected {
            Style::default().fg(Color::Black).bg(Color::Cyan)
        } else {
            Style::default()
        };
        frame.render_widget(
            Paragraph::new(format!(" {}", value)).style(style),
            Rect::new(inner.x, inner.y + row as u16, inner.width, 1),
        );
    }
}
impl Drop for Form {
    fn drop(&mut self) {
        #[cfg(unix)]
        let _ = execute!(self.terminal.backend_mut(), PopKeyboardEnhancementFlags);
        let _ = disable_raw_mode();
        let _ = execute!(
            self.terminal.backend_mut(),
            LeaveAlternateScreen,
            DisableBracketedPaste,
            DisableMouseCapture
        );
        let _ = self.terminal.show_cursor();
    }
}

pub(super) fn point_field_cursor(
    field: &mut TextArea<'_>,
    area: Rect,
    offset: (usize, usize),
    point: Position,
) {
    let inner = Block::bordered().inner(area);
    if inner.is_empty() {
        return;
    }
    let (top, left) = offset;
    let row = top + point.y.saturating_sub(inner.y).min(inner.height - 1) as usize;
    let column = left + point.x.saturating_sub(inner.x).min(inner.width - 1) as usize;
    let row = row.min(field.lines().len() - 1);
    let mut width = 0;
    let mut character = 0;
    for ch in field.lines()[row].chars() {
        let cells = if ch == '\t' {
            field.tab_length() as usize - width % field.tab_length().max(1) as usize
        } else {
            ch.width().unwrap_or(0)
        };
        if width + cells > column {
            break;
        }
        width += cells;
        character += 1;
    }
    field.move_cursor(CursorMove::Jump(
        row.min(u16::MAX as usize) as u16,
        character.min(u16::MAX as usize) as u16,
    ));
}

// Match the textarea's cursor-following viewport, so hit testing remains correct
// for long expressions and multiline values. Fields use the default no-wrap mode.
pub(super) fn render_field(
    frame: &mut Frame<'_>,
    field: &TextArea<'_>,
    area: Rect,
    offset: &mut (usize, usize),
    focused: bool,
) {
    let inner = Block::bordered().inner(area);
    if inner.is_empty() {
        if let Some(block) = field.block() {
            frame.render_widget(block, area);
        }
        return;
    }
    frame.render_widget(field, area);
    let cursor = field.screen_cursor();
    offset.0 = visible_start(offset.0, cursor.row, inner.height as usize);
    offset.1 = visible_start(offset.1, cursor.col, inner.width as usize);
    if field.lines().len() > inner.height as usize {
        draw_scrollbar(
            frame,
            Rect::new(area.right() - 1, inner.y, 1, inner.height),
            field.lines().len(),
            offset.0 as u16,
        );
    }
    if focused {
        frame.set_cursor_position(Position::new(
            inner.x + (cursor.col - offset.1) as u16,
            inner.y + (cursor.row - offset.0) as u16,
        ));
    }
}

fn settings_layout(
    area: Rect,
    rows: &[(Vec<usize>, u16)],
    focus: usize,
    scroll: &mut u16,
    follow: bool,
) -> Vec<(usize, Rect)> {
    let total: u16 = rows.iter().map(|(_, height)| *height).sum();
    if follow {
        let mut top = 0;
        for (fields, height) in rows {
            if fields.contains(&focus) {
                if top < *scroll {
                    *scroll = top;
                } else if top + height > scroll.saturating_add(area.height) {
                    *scroll = (top + height).saturating_sub(area.height);
                }
                break;
            }
            top += height;
        }
    }
    *scroll = (*scroll).min(total.saturating_sub(area.height));
    let mut visible = Vec::new();
    let mut top = 0_i32;
    for (fields, height) in rows {
        let start = (top - *scroll as i32).max(0);
        let end = (top + *height as i32 - *scroll as i32).min(area.height as i32);
        if end > start {
            let row = Rect::new(
                area.x,
                area.y + start as u16,
                area.width.saturating_sub(1),
                (end - start) as u16,
            );
            let columns = Layout::horizontal(vec![Constraint::Fill(1); fields.len()]).split(row);
            visible.extend(
                fields
                    .iter()
                    .zip(columns.iter())
                    .map(|(index, area)| (*index, *area)),
            );
        }
        top += *height as i32;
    }
    visible
}

fn draw_scrollbar(frame: &mut Frame<'_>, area: Rect, total: usize, position: u16) {
    if area.is_empty() {
        return;
    }
    let mut state = ScrollbarState::new(total.max(area.height as usize))
        .position(position as usize)
        .viewport_content_length(area.height as usize);
    frame.render_stateful_widget(
        Scrollbar::new(ScrollbarOrientation::VerticalRight)
            .thumb_symbol("█")
            .track_symbol(Some("│"))
            .begin_symbol(Some("↑"))
            .end_symbol(Some("↓"))
            .thumb_style(Style::default().fg(Color::Cyan))
            .track_style(Style::default().fg(Color::DarkGray)),
        area,
        &mut state,
    );
}

pub(crate) fn scrollable_text(
    frame: &mut Frame<'_>,
    text: &str,
    area: Rect,
    title: &str,
    scroll: &mut u16,
    follow: &mut bool,
) {
    let block = Block::bordered().title(title);
    let inner = block.inner(area);
    frame.render_widget(block, area);
    if inner.is_empty() {
        return;
    }
    let content = Rect::new(
        inner.x,
        inner.y,
        inner.width.saturating_sub(1),
        inner.height,
    );
    let paragraph = Paragraph::new(text).wrap(Wrap { trim: false });
    let total = paragraph.line_count(content.width);
    let maximum = total
        .saturating_sub(content.height as usize)
        .min(u16::MAX as usize) as u16;
    *scroll = if *follow {
        maximum
    } else {
        (*scroll).min(maximum)
    };
    *follow = false;
    frame.render_widget(paragraph.scroll((*scroll, 0)), content);
    draw_scrollbar(frame, inner, total, *scroll);
}

fn visible_start(previous: usize, cursor: usize, length: usize) -> usize {
    if cursor < previous {
        cursor
    } else if cursor >= previous + length {
        cursor + 1 - length
    } else {
        previous
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratatui::backend::TestBackend;

    #[test]
    fn compact_settings_share_rows_and_scroll_to_focused_fields() {
        let rows = vec![
            (vec![0, 1], 3),
            (vec![6, 3, 5], 3),
            (vec![2], 5),
            (vec![4], 7),
            (vec![7], 3),
            (vec![8], 3),
        ];
        let mut scroll = 0;
        let full = settings_layout(Rect::new(0, 3, 68, 29), &rows, 0, &mut scroll, true);
        assert_eq!(full.len(), 9);
        assert_eq!(full[0].1.y, full[1].1.y);
        assert!(full[0].1.right() <= full[1].1.x);
        assert_eq!(scroll, 0);
        let small = Rect::new(0, 3, 50, 12);
        for focus in 0..9 {
            let visible = settings_layout(small, &rows, focus, &mut scroll, true);
            let focused = visible.iter().find(|(index, _)| *index == focus).unwrap().1;
            assert!(focused.height >= 3);
            assert!(small.contains(focused.as_position()));
            assert!(focused.bottom() <= small.bottom());
        }
        assert!(scroll > 0);
    }

    #[test]
    fn log_scrollbar_tracks_tail_and_clamps_manual_scroll() {
        let mut terminal = Terminal::new(TestBackend::new(20, 8)).unwrap();
        let text = (0..50)
            .map(|i| format!("line {i}"))
            .collect::<Vec<_>>()
            .join("\n");
        let mut scroll = 0;
        let mut follow = true;
        terminal
            .draw(|frame| {
                scrollable_text(frame, &text, frame.area(), "Log", &mut scroll, &mut follow)
            })
            .unwrap();
        assert_eq!(scroll, 44);
        assert!(!follow);
        let buffer = terminal.backend().buffer();
        assert_eq!(buffer[(18, 1)].symbol(), "↑");
        assert_eq!(buffer[(18, 6)].symbol(), "↓");
        scroll = 3;
        terminal
            .draw(|frame| {
                scrollable_text(frame, &text, frame.area(), "Log", &mut scroll, &mut follow)
            })
            .unwrap();
        assert_eq!(scroll, 3);
        scroll = 999;
        terminal
            .draw(|frame| {
                scrollable_text(frame, &text, frame.area(), "Log", &mut scroll, &mut follow)
            })
            .unwrap();
        assert_eq!(scroll, 44);
    }

    #[test]
    fn readline_bindings_edit_unicode_without_crossing_line_start() {
        let mut field = TextArea::from(["first", "한글 hello world"]);
        let ctrl = |c| KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL);
        edit_field(
            &mut field,
            KeyEvent::new(KeyCode::End, KeyModifiers::CONTROL),
        );
        assert!(!edit_field(&mut field, ctrl('a')));
        assert!(!edit_field(&mut field, ctrl('u')));
        assert_eq!(field.lines(), ["first", "한글 hello world"]);
        edit_field(&mut field, ctrl('e'));
        assert!(edit_field(&mut field, ctrl('w')));
        assert_eq!(field.lines(), ["first", "한글 hello "]);
        assert!(edit_field(&mut field, ctrl('u')));
        assert_eq!(field.lines(), ["first", ""]);
        assert!(edit_field(&mut field, ctrl('y')));
        assert_eq!(field.lines(), ["first", "한글 hello "]);
        assert!(edit_field(&mut field, ctrl('z')));
        assert_eq!(field.lines(), ["first", ""]);
        assert!(edit_field(
            &mut field,
            KeyEvent::new(KeyCode::Char('z'), KeyModifiers::ALT)
        ));
        assert_eq!(field.lines(), ["first", "한글 hello "]);
        edit_field(&mut field, ctrl('a'));
        assert!(edit_field(&mut field, ctrl('k')));
        assert_eq!(field.lines(), ["first", ""]);
        assert!(edit_field(&mut field, ctrl('j')));
        assert_eq!(field.lines(), ["first", "", ""]);
        assert!(!edit_field(
            &mut field,
            KeyEvent::new(KeyCode::F(6), KeyModifiers::NONE)
        ));
        field.insert_str("replacement");
        assert_eq!(field.lines(), ["replacement"]);
    }

    #[test]
    fn clicking_fields_maps_cells_to_unicode_and_scrolled_lines() {
        let area = Rect::new(10, 5, 12, 4);
        let mut field = TextArea::from(["header", "a한글\tZ", "last"]);
        field.set_tab_length(4);
        // The second cell of 한 belongs to that character, not the next one.
        point_field_cursor(&mut field, area, (1, 0), Position::new(13, 6));
        assert_eq!(field.cursor(), (1, 1));
        field.insert_char('!');
        assert_eq!(field.lines()[1], "a!한글\tZ");
        // Horizontal scroll uses displayed cells, not byte/character indices.
        point_field_cursor(&mut field, area, (1, 4), Position::new(11, 6));
        assert_eq!(field.cursor(), (1, 3));
        point_field_cursor(&mut field, area, (1, 0), Position::new(19, 6));
        assert_eq!(field.cursor(), (1, 5));
        point_field_cursor(&mut field, area, (1, 0), Position::new(99, 99));
        assert_eq!(field.cursor(), (2, 4));
    }

    #[test]
    fn terminal_cursor_follows_wide_text_scrolling_and_focus() {
        let mut terminal = Terminal::new(TestBackend::new(40, 20)).unwrap();
        let mut field = TextArea::from(["한글a"]);
        field.set_block(Block::bordered());
        field.move_cursor(CursorMove::End);
        let other = TextArea::from(["Unfocused"]);
        let mut offset = (0, 0);
        let mut other_offset = (0, 0);
        let area = Rect::new(3, 2, 10, 4);
        let mut draw = |field: &TextArea<'_>, offset: &mut (usize, usize), expected: (u16, u16)| {
            terminal
                .draw(|frame| {
                    render_field(frame, field, area, offset, true);
                    // Repainting later widgets must not steal the terminal cursor.
                    render_field(
                        frame,
                        &other,
                        Rect::new(3, 8, 20, 3),
                        &mut other_offset,
                        false,
                    );
                    frame.render_widget(
                        Paragraph::new("Status / log updated"),
                        Rect::new(0, 15, 40, 2),
                    );
                })
                .unwrap();
            terminal.backend_mut().assert_cursor_position(expected);
        };
        draw(&field, &mut offset, (9, 3)); // two wide glyphs, then one ASCII cell
        field.insert_str("bcdef");
        draw(&field, &mut offset, (11, 3)); // horizontally scrolled to the last cell
        field.insert_str("\nrow2\nrow3\n끝");
        draw(&field, &mut offset, (4, 4)); // both axes have scrolled
        field.move_cursor(CursorMove::Top);
        field.move_cursor(CursorMove::Head);
        draw(&field, &mut offset, (4, 3));
    }
}
