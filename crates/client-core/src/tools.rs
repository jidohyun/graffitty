//! Terminal navigation reuses the shipping frontend's Godot-independent helpers.
use anyhow::{Context, Result, bail, ensure};
use graffitty_terminal_core::vt::{
    Terminal,
    render::{RenderState, RowIterator},
    fmt::Formatter,
    terminal::ScrollViewport,
};
use graffitty_terminal_core::{
    copy_mode::{CopyMode, Effect as CopyEffect, Input as CopyInput, IsKeyword},
    navigation::Navigation,
    quick_select::QuickSelect,
    screen::Frame,
};
use serde_json::{Value, json};
use std::collections::BTreeSet;

mod copy;

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct QuickPreferences {
    pub patterns: Vec<String>,
    pub defaults: bool,
    pub alphabet: String,
}
impl Default for QuickPreferences {
    fn default() -> Self {
        Self {
            patterns: vec![],
            defaults: true,
            alphabet: graffitty_terminal_core::quick_select::ALPHABET.into(),
        }
    }
}
impl QuickPreferences {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.patterns.len() <= 32 && self.patterns.iter().all(|p| p.len() <= 8192),
            "Too many or oversized Quick Select patterns"
        );
        let letters: BTreeSet<_> = self.alphabet.bytes().collect();
        ensure!(
            (2..=26).contains(&letters.len())
                && letters.len() == self.alphabet.len()
                && letters.iter().all(u8::is_ascii_lowercase),
            "Quick Select alphabet needs unique lowercase ASCII letters"
        );
        self.pattern()?;
        Ok(())
    }
    fn pattern(&self) -> Result<fancy_regex::Regex> {
        let mut sources = self.patterns.clone();
        if self.defaults {
            sources.extend(
                graffitty_terminal_core::quick_select::PATTERNS
                    .iter()
                    .map(|s| s.to_string()),
            );
        }
        Ok(fancy_regex::Regex::new(&if sources.is_empty() {
            "(?!)".into()
        } else {
            format!("(?m)(?:{})", sources.join("|"))
        })
        .context("Invalid Quick Select pattern")?)
    }
}

#[derive(Default)]
pub struct Controller {
    pub quick_preferences: QuickPreferences,
    navigation: Navigation,
    quick: Option<QuickSelect>,
    /// Godot's Vim copy mode; the mirror holds output while it is open.
    copy: Option<CopyMode>,
    /// Configured `iskeyword` rules and their parsed form.
    iskeyword: (Option<String>, IsKeyword),
    /// The last text copy mode put on the clipboard (Godot's `copied`) and
    /// how many copies it made, so automation can tell repeated texts apart.
    copied: Option<String>,
    copies: u64,
    /// Copy mode asked for the output held since it froze the screen.
    refresh: bool,
    /// Output is waiting behind copy mode; its status line says so.
    pub held_output: bool,
    /// Copy-mode overlay state at the last operation, for automation.
    view: Value,
    held: BTreeSet<String>,
}
#[derive(Default)]
pub struct Effect {
    pub copy: Option<String>,
    pub paste: bool,
}
impl Controller {
    pub fn mode(&self) -> Option<&'static str> {
        if self.quick.is_some() {
            Some("quick_select")
        } else if let Some(copy) = &self.copy {
            Some(if copy.wants_text() { "search" } else { "copy_mode" })
        } else if self.navigation.active {
            Some("search")
        } else {
            None
        }
    }
    pub fn modal_action(&mut self, vt: &mut Terminal<'_, '_>, action: &str) -> Result<Effect> {
        let mut result = Effect::default();
        match action {
            "cancel" => self.cancel(),
            "ignore" => {}
            "copy" | "accept" => {
                result.copy = Some(selected(vt)?);
                if action == "accept" {
                    self.cancel();
                }
            }
            "clear" | "backspace" => {
                if let Some(q) = self.quick.as_mut() {
                    if action == "clear" {
                        q.input.clear();
                    } else {
                        q.input.pop();
                    }
                } else if let Some(mut query) = self.navigation.query.clone() {
                    if action == "clear" {
                        query.clear();
                    } else {
                        query.pop();
                    }
                    self.navigation.search(vt, &query);
                }
            }
            "next" | "previous" if self.quick.is_some() => {
                let q = self.quick.as_mut().unwrap();
                if !q.matches.is_empty() {
                    let delta = if action == "next" { 1 } else { -1 };
                    let next = (q.current.unwrap_or(0) as isize + delta)
                        .rem_euclid(q.matches.len() as isize)
                        as usize;
                    q.current = Some(next);
                    if let Some((p, _)) = q.matches[next].bounds() {
                        vt.scroll_viewport(ScrollViewport::Row(p.y as usize));
                    }
                }
            }
            "next" | "previous" => self.navigation.step(if action == "next" { 1 } else { -1 }),
            "page_up" | "page_down" if self.quick.is_some() => {
                vt.scroll_viewport(ScrollViewport::Delta(if action == "page_up" {
                    -(vt.rows()? as isize)
                } else {
                    vt.rows()? as isize
                }));
            }
            // Cursor actions belong to copy mode, which routes them itself.
            _ => {}
        }
        if self.navigation.active {
            self.navigation.select(vt);
        }
        Ok(result)
    }
    pub fn active(&self) -> bool {
        self.navigation.active || self.quick.is_some() || self.copy.is_some()
    }
    /// Copy mode reads a still screen, as tmux copy mode does.
    pub fn frozen(&self) -> bool {
        self.copy.is_some()
    }
    /// Apply configured Neovim `iskeyword` rules (comma-joined) to copy mode.
    pub fn set_iskeyword(&mut self, rules: &str) {
        if self.iskeyword.0.as_deref() == Some(rules) {
            return;
        }
        if let Ok(keyword) = IsKeyword::parse(rules) {
            if let Some(copy) = self.copy.as_mut() {
                copy.set_iskeyword(keyword.clone());
            }
            self.iskeyword = (Some(rules.into()), keyword);
        }
    }
    /// Whether copy mode asked to apply held output (its `r` key).
    pub fn take_refresh(&mut self) -> bool {
        std::mem::take(&mut self.refresh)
    }
    /// After held output was applied: copy mode re-reads the screen it started
    /// on, or closes when the application switched screens meanwhile.
    pub fn refresh_copy(&mut self, vt: &mut Terminal<'_, '_>) {
        match self.copy.as_mut() {
            Some(copy) if copy.screen() == vt.active_screen().ok() => copy.refresh(vt),
            Some(_) => self.end_copy(vt),
            None => {}
        }
        self.sync_view(vt);
    }
    /// A pointer press moves the copy cursor to a viewport cell.
    pub fn copy_place(&mut self, vt: &mut Terminal<'_, '_>, column: u16, row: u16) -> bool {
        let Some(copy) = self.copy.as_mut() else {
            return false;
        };
        copy.place(vt, column, row);
        self.sync_view(vt);
        true
    }
    /// The wheel scrolls the frozen screen and keeps the copy cursor visible.
    pub fn copy_scroll(&mut self, vt: &mut Terminal<'_, '_>, lines: i64) -> bool {
        let Some(copy) = self.copy.as_mut() else {
            return false;
        };
        copy.scroll_view(vt, lines);
        self.sync_view(vt);
        true
    }
    fn copy_status(&self) -> Option<String> {
        let copy = self.copy.as_ref()?;
        let mut status = copy.status();
        if self.held_output {
            status.push_str(if copy.wants_text() {
                "  [frozen: new output]"
            } else {
                "  [frozen: new output, r refreshes]"
            });
        }
        Some(status)
    }
    fn end_copy(&mut self, vt: &mut Terminal<'_, '_>) {
        if let Some(copy) = self.copy.take() {
            copy.finish(vt);
        }
        self.view = Value::Null;
    }
    fn sync_view(&mut self, vt: &Terminal<'_, '_>) {
        self.view = match &self.copy {
            Some(copy) => copy::view(copy, vt, vt.rows().unwrap_or(1), vt.cols().unwrap_or(1)),
            None => Value::Null,
        };
    }
    fn copy_effect(&mut self, vt: &mut Terminal<'_, '_>, effect: CopyEffect) -> Effect {
        let mut result = Effect::default();
        match effect {
            CopyEffect::None => {}
            CopyEffect::Exit => self.end_copy(vt),
            CopyEffect::Copy { text, exit } => {
                self.copied = Some(text.clone());
                self.copies += 1;
                result.copy = Some(text);
                if exit {
                    self.end_copy(vt);
                }
            }
            CopyEffect::Refresh => self.refresh = true,
        }
        self.sync_view(vt);
        result
    }
    /// Copy mode takes Vim keys directly; a configured modal binding overrides
    /// one key with a named action, as in Godot's `modal_key`.
    fn copy_key(&mut self, vt: &mut Terminal<'_, '_>, value: &Value) -> Effect {
        let Some(copy) = self.copy.as_mut() else {
            return Effect::default();
        };
        let text = copy.wants_text();
        let action = match value["modal_action"].as_str() {
            Some("unbound") => None,
            Some(action) => Some(action.to_owned()),
            None if copy::copy_chord(value) => Some(if text { "copy" } else { "accept" }.into()),
            None => None,
        };
        let effect = match action.as_deref() {
            Some("ignore") => CopyEffect::None,
            Some(action) => copy.action(vt, action),
            None => copy::input(value, text, true).map_or(CopyEffect::None, |input| copy.key(vt, input)),
        };
        self.copy_effect(vt, effect)
    }
    /// Typed text without key codes (input methods, multi-character events).
    fn copy_text(&mut self, vt: &mut Terminal<'_, '_>, text: &str) -> Effect {
        let mut result = Effect::default();
        for c in text.chars().filter(|c| !c.is_control()) {
            let Some(copy) = self.copy.as_mut() else {
                break;
            };
            let effect = copy.key(vt, CopyInput::char(c));
            let effect = self.copy_effect(vt, effect);
            if effect.copy.is_some() {
                result.copy = effect.copy;
            }
        }
        result
    }
    /// Paint copy mode into the viewport snapshot (rows from the VT viewport).
    pub fn decorate(&self, vt: &Terminal<'_, '_>, frame: &mut Frame, rows: u16) {
        if let Some(copy) = &self.copy {
            let selection = selection_rows(vt).unwrap_or_default();
            copy::decorate(copy, vt, frame, rows, &selection, &self.copy_status().unwrap_or_default());
        }
    }
    pub fn status(&self) -> String {
        if let Some(q) = &self.quick {
            format!(
                "Quick select: {} · type a label to copy; uppercase pastes · Esc closes",
                q.input
            )
        } else if let Some(status) = self.copy_status() {
            status
        } else if self.navigation.active {
            format!("{} · Esc closes", self.navigation.status())
        } else {
            String::new()
        }
    }
    pub fn snapshot(&self) -> Value {
        let mut copy = self.view.clone();
        if let Some(fields) = copy.as_object_mut() {
            fields.insert("status".into(), json!(self.copy_status()));
            fields.insert("held_output".into(), json!(self.held_output));
        }
        json!({"active":self.active(),"mode":self.mode(),"copy":copy,"copied":self.copied,"copies":self.copies,"status":self.status(),"query":self.navigation.query,"matches":self.navigation.matches.len(),"current":self.navigation.current,"quick":self.quick.as_ref().map(|q|q.matches.iter().map(|m|json!({"text":m.text,"label":m.label,"bounds":m.bounds().map(|(a,b)|[[a.x as u32,a.y],[b.x as u32,b.y]])})).collect::<Vec<_>>())})
    }
    pub fn holds(&self, key: &str) -> bool {
        self.held.contains(&key.to_ascii_lowercase())
    }
    /// Drop every mode without touching the VT (it is being replaced).
    pub fn cancel(&mut self) {
        self.navigation = Navigation::default();
        self.quick = None;
        self.copy = None;
        self.refresh = false;
        self.view = Value::Null;
    }
    /// A pointer press closes search and Quick Select; copy mode owns the
    /// pointer in its own pane and stays open, as in Godot.
    pub fn cancel_transient(&mut self) {
        self.navigation = Navigation::default();
        self.quick = None;
    }
    pub fn start(
        &mut self,
        vt: &mut Terminal<'_, '_>,
        command: &str,
        query: &str,
    ) -> Result<Effect> {
        if command == "copy_mode" {
            // Godot start_copy: reopening keeps the current copy mode.
            self.cancel_transient();
            if self.copy.is_none() {
                let cursor = (vt.cursor_x()?, vt.cursor_y()?);
                self.copy = Some(CopyMode::new(vt, cursor));
            }
            if let Some(copy) = self.copy.as_mut() {
                copy.set_iskeyword(self.iskeyword.1.clone());
            }
            self.sync_view(vt);
            return Ok(Effect::default());
        }
        self.end_copy(vt);
        self.cancel();
        let mut result = Effect::default();
        match command {
            "search" => self.navigation.search(vt, query),
            "quick_select" => {
                self.quick = Some(QuickSelect::find(
                    vt,
                    &self.quick_preferences.pattern()?,
                    false,
                    &self.quick_preferences.alphabet,
                )?);
                vt.set_selection(None)?;
            }
            "copy_last_output" => {
                if graffitty_terminal_core::navigation::last_output(vt) {
                    result.copy = Some(selected(vt)?);
                }
            }
            "previous_prompt" | "next_prompt" => {
                graffitty_terminal_core::protocol::jump_prompt(
                    vt,
                    if command == "previous_prompt" { -1 } else { 1 },
                );
            }
            "scroll_page_up" => vt.scroll_viewport(ScrollViewport::Delta(-(vt.rows()? as isize))),
            "scroll_page_down" => vt.scroll_viewport(ScrollViewport::Delta(vt.rows()? as isize)),
            "scroll_top" => vt.scroll_viewport(ScrollViewport::Top),
            "scroll_bottom" => vt.scroll_viewport(ScrollViewport::Bottom),
            "cancel" => {}
            _ => bail!("Unknown terminal tool {command}"),
        }
        if self.navigation.active {
            self.navigation.select(vt);
        }
        Ok(result)
    }
    fn screen_changed(&self, vt: &Terminal<'_, '_>) -> bool {
        let screen = vt.active_screen().ok();
        self.copy.as_ref().is_some_and(|c| c.screen() != screen)
            || self.navigation.active && self.navigation.screen != screen
            || self
                .quick
                .as_ref()
                .is_some_and(|q| Some(q.screen) != screen)
    }
    pub fn text(&mut self, vt: &mut Terminal<'_, '_>, text: &str) -> Result<Effect> {
        let mut result = Effect::default();
        if self.screen_changed(vt) {
            self.cancel();
            return Ok(result);
        }
        if self.copy.is_some() {
            return Ok(self.copy_text(vt, text));
        }

        if let Some(mut query) = self
            .navigation
            .query
            .clone()
            .filter(|_| self.navigation.active)
        {
            ensure!(query.len() + text.len() <= 4096, "Search query is too long");
            query.extend(text.chars().filter(|c| !c.is_control()));
            self.navigation.search(vt, &query);
            self.navigation.select(vt);
        } else if let Some(q) = self.quick.as_mut() {
            if q.input.len() < 64 {
                q.input.extend(text.chars().filter(|c| !c.is_control()));
            }
            if let Some((index, paste)) = q.selected() {
                result.copy = q.matches[index].select_text(vt);
                result.paste = paste;
                self.quick = None;
            }
        }
        Ok(result)
    }
    pub fn key(&mut self, vt: &mut Terminal<'_, '_>, value: &Value) -> Result<(bool, Effect)> {
        let key = value["key"].as_str().context("Missing key")?;
        let lower = key.to_ascii_lowercase();
        let released = value["action"] == "key_release";
        // A screen switch invalidates the modal target. The event that discovers
        // that switch still belongs to the mode, so never forward it to the PTY.
        if self.screen_changed(vt) {
            self.cancel();
            if released {
                self.held.remove(&lower);
            } else {
                self.held.insert(lower);
            }
            return Ok((true, Effect::default()));
        }
        if released {
            return Ok((self.held.remove(&lower) || self.active(), Effect::default()));
        }
        let ctrl = value["ctrl"] == true;
        let alt = value["alt"] == true;
        let meta = value["meta"] == true;
        let shift = value["shift"] == true;
        if !self.active() {
            let command = if ctrl && shift && !alt && !meta {
                match lower.as_str() {
                    "f" => Some("search"),
                    "x" => Some("copy_mode"),
                    "o" => Some("copy_last_output"),
                    " " | "space" => Some("quick_select"),
                    _ => None,
                }
            } else {
                None
            };
            let Some(command) = command else {
                return Ok((false, Effect::default()));
            };
            self.held.insert(lower);
            return Ok((true, self.start(vt, command, "")?));
        }
        self.held.insert(lower.clone());
        if self.copy.is_some() {
            return Ok((true, self.copy_key(vt, value)));
        }
        if let Some(action) = value["modal_action"].as_str() {
            if action == "unbound" {
                return Ok((
                    true,
                    if !ctrl && !alt && !meta && key.chars().count() == 1 {
                        self.text(vt, key)?
                    } else {
                        Effect::default()
                    },
                ));
            }
            return Ok((true, self.modal_action(vt, action)?));
        }
        let mut result = Effect::default();
        if key == "Escape" {
            self.cancel();
            return Ok((true, result));
        }
        if let Some(q) = self.quick.as_mut() {
            match key {
                "Backspace" => {
                    q.input.pop();
                }
                _ if ctrl && lower == "u" => q.input.clear(),
                "ArrowUp" | "ArrowDown" | "Enter" | "PageUp" | "PageDown" => {
                    if let Some(current) = q.current.filter(|_| !q.matches.is_empty()) {
                        let direction = if matches!(key, "ArrowUp" | "Enter" | "PageUp") {
                            -1
                        } else {
                            1
                        };
                        let next = (current as isize + direction)
                            .rem_euclid(q.matches.len() as isize)
                            as usize;
                        q.current = Some(next);
                        if let Some((p, _)) = q.matches[next].bounds() {
                            vt.scroll_viewport(ScrollViewport::Row(p.y as usize));
                        }
                    }
                }
                _ if !ctrl && !alt && !meta && key.chars().count() == 1 => {
                    result = self.text(vt, key)?
                }
                _ => {}
            }
        } else if let Some(mut query) = self.navigation.query.clone() {
            match key {
                "Enter" | "F3" | "ArrowUp" | "ArrowDown" => self
                    .navigation
                    .step(if shift || key == "ArrowUp" { -1 } else { 1 }),
                _ if lower == "c" && (meta || ctrl && shift) => result.copy = Some(selected(vt)?),
                "Backspace" => {
                    query.pop();
                    self.navigation.search(vt, &query);
                }
                _ if ctrl && lower == "u" => self.navigation.search(vt, ""),
                _ if !ctrl && !alt && !meta && key.chars().count() == 1 => {
                    result = self.text(vt, key)?;
                }
                _ => {}
            }
        }
        if self.navigation.active {
            self.navigation.select(vt);
        }
        Ok((true, result))
    }
}
pub fn selected(vt: &Terminal<'_, '_>) -> Result<String> {
    let Some(mut formatter) = Formatter::new_selection(vt)? else { return Ok(String::new()) };
    formatter.set_unwrap(true)?.set_trim(true)?;
    let bytes = formatter.format_alloc(None)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}
/// Selected cells per viewport row: `[row, start, inclusive end]`.
fn selection_rows(vt: &Terminal<'_, '_>) -> Result<Vec<[u16; 3]>> {
    let mut render = RenderState::new()?;
    let view = render.update(vt)?;
    let mut iterator = RowIterator::new()?;
    let mut rows = iterator.update(&view)?;
    let mut spans = vec![];
    let mut y = 0;
    while let Some(row) = rows.next() {
        if let Some(range) = row.selection()? {
            spans.push([y, range.start_x, range.end_x]);
        }
        y += 1;
    }
    Ok(spans)
}
pub fn viewport_decorations(
    vt: &mut Terminal<'_, '_>,
    tools: &Controller,
    visible_rows: u16,
    columns: u16,
    extra_row: bool,
) -> Result<(Vec<[u16; 3]>, Vec<(u16, u16, u16, String)>)> {
    let offset = vt.scrollbar()?.offset;
    let copy = tools
        .copy
        .as_ref()
        .map(|copy| (copy.flash_active(), copy.cursor_viewport(vt)));
    let mut spans = selection_rows(vt)?;
    if extra_row {
        vt.scroll_viewport(ScrollViewport::Delta(1));
        for [row, start, end] in selection_rows(vt)? {
            if row == visible_rows.saturating_sub(1) {
                spans.push([visible_rows, start, end]);
            }
        }
    }
    if let Some((flash, cursor)) = copy {
        copy::mask_spans(flash, cursor, visible_rows.saturating_sub(1), &mut spans);
    }
    // Pins remain safe after output/reflow, but labels from the other screen
    // must never decorate unrelated current content. Input closes that mode.
    let labels = if tools.screen_changed(vt) {
        vec![]
    } else {
        tools
            .quick
            .as_ref()
            .map(|q| {
                q.segments(
                    offset,
                    visible_rows.saturating_add(u16::from(extra_row)),
                    columns,
                )
            })
            .unwrap_or_default()
    };
    Ok((spans, labels))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn custom_quick_patterns_and_alphabet_drive_real_vt_matches() {
        let mut vt = vt();
        vt.vt_write(b"ISSUE-421 ISSUE-783 https://example.test/ignored");
        let preferences = QuickPreferences {
            patterns: vec![r"ISSUE-(\d+)".into()],
            defaults: false,
            alphabet: "xy".into(),
        };
        preferences.validate().unwrap();
        let mut controller = Controller {
            quick_preferences: preferences.clone(),
            ..Default::default()
        };
        controller.start(&mut vt, "quick_select", "").unwrap();
        let matches = &controller.quick.as_ref().unwrap().matches;
        assert_eq!(
            matches.iter().map(|m| m.text.as_str()).collect::<Vec<_>>(),
            ["421", "783"]
        );
        assert!(
            matches
                .iter()
                .all(|m| m.label.chars().all(|c| c == 'x' || c == 'y'))
        );
        let label = matches[0].label.to_uppercase();
        let effect = controller.text(&mut vt, &label).unwrap();
        assert_eq!(effect.copy.as_deref(), Some("421"));
        assert!(effect.paste);
        let mut invalid = preferences;
        invalid.alphabet = "aa".into();
        assert!(invalid.validate().is_err());
        invalid.alphabet = "ab".into();
        invalid.patterns = vec!["[".into()];
        assert!(invalid.validate().is_err());
    }
    fn vt() -> Terminal<'static, 'static> {
        graffitty_terminal_core::new_vt(24, 4, 100).unwrap()
    }
    #[test]
    fn remapped_modal_actions_change_selection_without_typing() {
        let mut vt = vt();
        vt.vt_write(b"abcd\r\nword");
        let mut controller = Controller::default();
        controller.start(&mut vt, "copy_mode", "").unwrap();
        controller.copy_place(&mut vt, 3, 0);
        let (_, effect) = controller
            .key(
                &mut vt,
                &json!({"action":"key","key":"q","modal_action":"left"}),
            )
            .unwrap();
        assert_eq!(controller.view["cursor"], json!([2, 0, false]));
        assert!(effect.copy.is_none() && controller.mode() == Some("copy_mode"));
        assert!(
            controller
                .key(&mut vt, &json!({"action":"key_release","key":"q"}))
                .unwrap()
                .0
        );
        controller.start(&mut vt, "search", "word").unwrap();
        controller
            .key(
                &mut vt,
                &json!({"action":"key","key":"x","modal_action":"clear"}),
            )
            .unwrap();
        assert_eq!(controller.navigation.query.as_deref(), Some(""));
        controller
            .key(
                &mut vt,
                &json!({"action":"key","key":"a","modal_action":"unbound"}),
            )
            .unwrap();
        assert_eq!(controller.navigation.query.as_deref(), Some("a"));
    }

    #[test]
    fn search_and_copy_mode_never_encode_modal_keys() {
        let mut vt = vt();
        vt.vt_write(b"needle first\r\nneedle second\r\n");
        let mut c = Controller::default();
        c.start(&mut vt, "search", "needle").unwrap();
        assert_eq!(c.navigation.matches.len(), 2);
        assert_eq!(selected(&vt).unwrap(), "needle");
        let (handled, _) = c
            .key(&mut vt, &json!({"action":"key","key":"ArrowUp"}))
            .unwrap();
        assert!(handled);
        assert_eq!(c.navigation.current, 0);
        c.key(&mut vt, &json!({"action":"key","key":"Escape"}))
            .unwrap();
        assert!(!c.active());
        assert!(
            c.key(&mut vt, &json!({"action":"key_release","key":"Escape"}))
                .unwrap()
                .0
        );
        c.start(&mut vt, "copy_mode", "").unwrap();
        assert!(c.active());
        let mut e = Effect::default();
        for key in ["k", "k", "0", "v", "e", "y"] {
            (_, e) = c.key(&mut vt, &json!({"action":"key","key":key})).unwrap();
        }
        assert_eq!(e.copy.as_deref(), Some("needle"));
        assert!(!c.active());
    }
    #[test]
    fn terminal_reset_retires_modal_pins_and_preserves_consumed_releases() {
        let mut old = vt();
        old.vt_write(b"https://example.test\r\n");
        let mut c = Controller::default();
        c.start(&mut old, "quick_select", "").unwrap();
        c.key(&mut old, &json!({"action":"key","key":"Backspace"}))
            .unwrap();
        // The reset hook runs before replacing the VT, dropping all tracked refs.
        c.cancel();
        let mut replacement = vt();
        drop(old);
        assert!(!c.active());
        assert!(c.quick.is_none());
        assert!(c.navigation.matches.is_empty());
        assert!(
            c.key(
                &mut replacement,
                &json!({"action":"key_release","key":"Backspace"})
            )
            .unwrap()
            .0
        );
    }
    #[test]
    fn screen_transition_consumes_modal_key_release_and_ime_text() {
        let mut vt = vt();
        vt.vt_write(b"needle");
        let mut c = Controller::default();
        c.start(&mut vt, "search", "needle").unwrap();
        vt.vt_write(b"\x1b[?1049h");
        assert!(
            c.key(&mut vt, &json!({"action":"key","key":"x"}))
                .unwrap()
                .0
        );
        assert!(!c.active());
        assert!(
            c.key(&mut vt, &json!({"action":"key_release","key":"x"}))
                .unwrap()
                .0
        );
        c.start(&mut vt, "quick_select", "").unwrap();
        vt.vt_write(b"\x1b[?1049l");
        let effect = c.text(&mut vt, "IMEmustnotpaste").unwrap();
        assert!(!c.active());
        assert!(effect.copy.is_none() && !effect.paste);
    }
    #[test]
    fn copy_mode_starts_inside_the_selected_history_viewport() {
        let mut vt = vt();
        for _ in 0..10 {
            vt.vt_write(b"history\r\n");
        }
        vt.scroll_viewport(ScrollViewport::Top);
        let top = vt.scrollbar().unwrap().offset;
        let mut c = Controller::default();
        c.start(&mut vt, "copy_mode", "").unwrap();
        assert_eq!(vt.scrollbar().unwrap().offset, top);
        assert!(c.view["cursor"][1].as_u64().is_some_and(|row| row < 4));
    }
    #[test]
    fn fractional_bottom_row_keeps_selection_and_quick_label() {
        use graffitty_terminal_core::vt::{
            selection::Selection,
            terminal::{Point, PointCoordinate},
        };
        let mut vt = vt();
        for _ in 0..7 {
            vt.vt_write(b"earlier\r\n");
        }
        vt.vt_write(b"https://example.test");
        let mut c = Controller::default();
        c.start(&mut vt, "quick_select", "").unwrap();
        vt.scroll_viewport(ScrollViewport::Bottom);
        vt.scroll_viewport(ScrollViewport::Delta(-1));
        let y = vt.scrollbar().unwrap().offset as u32 + 4;
        let a = vt
            .grid_ref(Point::Screen(PointCoordinate { x: 0, y }))
            .unwrap();
        let b = vt
            .grid_ref(Point::Screen(PointCoordinate { x: 3, y }))
            .unwrap();
        vt.set_selection(Some(&Selection::new(a, b, false)))
            .unwrap();
        let (spans, labels) = viewport_decorations(&mut vt, &c, 4, 24, true).unwrap();
        assert!(spans.contains(&[4, 0, 3]), "{spans:?}");
        assert!(labels.iter().any(|(row, _, _, _)| *row == 4), "{labels:?}");
    }
    #[test]
    fn quick_select_reuses_labels_and_uppercase_paste() {
        let mut vt = vt();
        vt.vt_write(b"https://example.test\r\n");
        let mut c = Controller::default();
        c.start(&mut vt, "quick_select", "").unwrap();
        let label = c.quick.as_ref().unwrap().matches[0].label.to_uppercase();
        let e = c.text(&mut vt, &label).unwrap();
        assert_eq!(e.copy.as_deref(), Some("https://example.test"));
        assert!(e.paste);
        assert!(!c.active());
    }
    fn keys(c: &mut Controller, vt: &mut Terminal<'_, '_>, keys: &str) -> Effect {
        let mut last = Effect::default();
        for key in keys.chars() {
            let (_, effect) = c
                .key(vt, &json!({"action":"key","key":key.to_string()}))
                .unwrap();
            if effect.copy.is_some() {
                last = effect;
            }
        }
        last
    }
    #[test]
    fn godot_copy_mode_motions_objects_search_and_flash() {
        let mut vt = graffitty_terminal_core::new_vt(40, 6, 100).unwrap();
        vt.vt_write(b"alpha beta.gamma\r\nsecond line\r\n");
        let mut c = Controller::default();
        c.start(&mut vt, "copy_mode", "").unwrap();
        assert_eq!(c.mode(), Some("copy_mode"));
        assert!(c.frozen());
        assert_eq!(keys(&mut c, &mut vt, "ggwviwy").copy.as_deref(), Some("beta"));
        assert!(!c.active() && c.copied.as_deref() == Some("beta"));
        c.start(&mut vt, "copy_mode", "").unwrap();
        keys(&mut c, &mut vt, "gg");
        c.key(&mut vt, &json!({"action":"key","key":"v","ctrl":true})).unwrap();
        assert_eq!(keys(&mut c, &mut vt, "jly").copy.as_deref(), Some("al\nse"));
        c.start(&mut vt, "copy_mode", "").unwrap();
        keys(&mut c, &mut vt, "/line");
        assert_eq!(c.mode(), Some("search"));
        assert!(c.status().starts_with("/line  [1/1]"), "{}", c.status());
        c.key(&mut vt, &json!({"action":"key","key":"Enter"})).unwrap();
        assert_eq!(c.mode(), Some("copy_mode"));
        assert_eq!(keys(&mut c, &mut vt, "ygn").copy.as_deref(), Some("line"));
        c.start(&mut vt, "copy_mode", "").unwrap();
        keys(&mut c, &mut vt, "ggs");
        assert!(c.view["flash_active"] == true);
        keys(&mut c, &mut vt, "sec");
        let labels = c.view["labels"].as_array().unwrap().clone();
        assert_eq!(labels.len(), 1, "{labels:?}");
        let label = labels[0]["label"].as_str().unwrap().to_owned();
        c.text(&mut vt, &label).unwrap();
        assert_eq!(c.mode(), Some("copy_mode"));
        assert_eq!(keys(&mut c, &mut vt, "yiw").copy.as_deref(), Some("second"));
        c.start(&mut vt, "copy_mode", "").unwrap();
        c.set_iskeyword("@,48-57,_,192-255,.");
        assert_eq!(keys(&mut c, &mut vt, "ggwyiw").copy.as_deref(), Some("beta.gamma"));
        c.start(&mut vt, "copy_mode", "").unwrap();
        keys(&mut c, &mut vt, "ggviw");
        let (_, effect) = c
            .key(&mut vt, &json!({"action":"key","key":"c","meta":true}))
            .unwrap();
        assert_eq!(effect.copy.as_deref(), Some("alpha"), "Cmd+C accepts like Godot");
        assert!(!c.active());
    }
    #[test]
    fn copy_mode_paints_godot_overlay_into_the_frame() {
        let mut vt = vt();
        vt.vt_write(b"needle one\r\nhay\r\nneedle two");
        let mut c = Controller::default();
        c.start(&mut vt, "copy_mode", "").unwrap();
        keys(&mut c, &mut vt, "gg0w");
        let mut frame =
            graffitty_terminal_core::screen::snapshot(&vt, 24, 4, false).unwrap();
        c.decorate(&vt, &mut frame, 4);
        assert!(frame.cursor.is_empty(), "The terminal cursor hides");
        let cell = |frame: &Frame, row: usize, column: u16| {
            frame.lines[row].iter().find(|cell| cell.0 == column).cloned()
        };
        let cursor = cell(&frame, 0, 7).unwrap();
        assert_eq!((cursor.3.as_str(), cursor.4.as_str()), ("#000000", "#40c8e0"));
        let status: String = frame.lines[3].iter().map(|cell| cell.2.as_str()).collect();
        assert!(status.starts_with("COPY  1/"), "{status}");
        assert!(frame.lines[3].iter().all(|cell| cell.4 == "#0d0d0d"));
        keys(&mut c, &mut vt, "gg0*");
        let mut frame =
            graffitty_terminal_core::screen::snapshot(&vt, 24, 4, false).unwrap();
        c.decorate(&vt, &mut frame, 4);
        assert_eq!(cell(&frame, 0, 0).unwrap().4, "#e5c07b", "Other matches are gold");
        assert_eq!(cell(&frame, 2, 1).unwrap().4, "#ff9e3b", "The current match is orange");
        assert_eq!(cell(&frame, 2, 0).unwrap().4, "#40c8e0", "The cursor paints over it");
        keys(&mut c, &mut vt, "gg0s");
        keys(&mut c, &mut vt, "need");
        let mut frame =
            graffitty_terminal_core::screen::snapshot(&vt, 24, 4, false).unwrap();
        c.decorate(&vt, &mut frame, 4);
        let hay = cell(&frame, 1, 0).unwrap();
        assert!(hay.5 & 4 != 0 && hay.3 != frame.foreground, "Flash dims other text");
        let matched = cell(&frame, 0, 0).unwrap();
        assert_eq!(matched.4, "#12161e", "A light match keeps a dark backing");
        let labels = c.view["labels"].as_array().unwrap();
        let label = &labels[0];
        let at = cell(&frame, label["row"].as_u64().unwrap() as usize,
            label["column"].as_u64().unwrap() as u16).unwrap();
        assert_eq!((at.2.as_str(), at.4.as_str()), (label["label"].as_str().unwrap(), "#ffcc33"));
    }
}
