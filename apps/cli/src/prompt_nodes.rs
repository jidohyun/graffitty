//! Human input and session expansion use the same socket lifecycle as other nodes.
use crate::node_rpc as rpc;
use crate::{
    agent_bridge::Result,
    node_form::{Action, Form},
    options::{ManualPrompt, ReadSessionFile},
    prompt_editor::{self, PromptEditor},
};
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
    Terminal,
    backend::CrosstermBackend,
    layout::{Constraint, Layout, Position, Rect},
    style::{Color, Style},
    widgets::{Block, Paragraph, Wrap},
};
use ratatui_textarea::TextArea;
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    fs::File,
    io::{self, BufRead, BufReader, IsTerminal, Read},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

fn start(name: &str, inputs: Value, line_style: Option<&str>) -> Result<crate::NodeSession> {
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let guard = crate::node_session(true)?;
    let mut output = json!({"id":"out","name":"Output","color":"#89ddbd"});
    if let Some(style) = line_style {
        output["line_style"] = json!(style);
    }
    guard.register_raw(json!({"name":name,"inputs":inputs,"outputs":[output]}),
    )?;
    Ok(guard)
}
struct Screen;
impl Drop for Screen {
    fn drop(&mut self) {
        #[cfg(unix)]
        let _ = execute!(io::stdout(), PopKeyboardEnhancementFlags);
        let _ = execute!(
            io::stdout(),
            DisableMouseCapture,
            DisableBracketedPaste,
            LeaveAlternateScreen
        );
        let _ = disable_raw_mode();
    }
}
fn screen() -> Result<(Screen, Terminal<CrosstermBackend<io::Stdout>>)> {
    enable_raw_mode()?;
    let guard = Screen;
    execute!(
        io::stdout(),
        EnterAlternateScreen,
        EnableBracketedPaste,
        EnableMouseCapture
    )?;
    #[cfg(unix)]
    execute!(
        io::stdout(),
        PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
    )?;
    Ok((guard, Terminal::new(CrosstermBackend::new(io::stdout()))?))
}
fn stamp() -> String {
    jiff::Zoned::now().strftime("%H:%M:%S %:z").to_string()
}
/// Save the unsent draft and as many recent sent prompts as fit
/// comfortably under the host's 64 KiB limit.
///
/// If the draft alone is oversized, drop it whole.
const PROMPT_STATE_BYTES: usize = 48 * 1024;
fn prompt_state(draft: &str, sent: &[(String, String)]) -> Value {
    let size = |value: &Value| serde_json::to_string(value).map_or(usize::MAX, |text| text.len());
    let mut draft = json!(draft);
    if size(&draft) > PROMPT_STATE_BYTES * 2 / 3 {
        draft = json!("");
    }
    let mut budget = PROMPT_STATE_BYTES.saturating_sub(size(&draft));
    let mut kept = Vec::new();
    for (at, text) in sent.iter().rev() {
        let entry = json!({"at":at,"text":text});
        let cost = size(&entry) + 1;
        if cost > budget {
            break;
        }
        budget -= cost;
        kept.push(entry);
    }
    kept.reverse();
    json!({"draft":draft,"sent":kept})
}
fn restored_prompts(state: &Value) -> (String, Vec<(String, String)>) {
    let sent = state["sent"].as_array().into_iter().flatten()
        .filter_map(|entry| Some((entry["at"].as_str()?.to_owned(), entry["text"].as_str()?.to_owned())))
        .collect();
    (state["draft"].as_str().unwrap_or("").to_owned(), sent)
}
fn sent_display(sent: &[(String, String)]) -> String {
    sent.iter().map(|(at, text)| format!("You · {at}\n{text}\n\n")).collect()
}
fn history_scroll(event: &Event, offset: &mut u16) {
    match event {
        Event::Mouse(m) if m.kind == MouseEventKind::ScrollUp => *offset = offset.saturating_add(3),
        Event::Mouse(m) if m.kind == MouseEventKind::ScrollDown => {
            *offset = offset.saturating_sub(3)
        }
        Event::Key(k) if k.code == KeyCode::PageUp => *offset = offset.saturating_add(10),
        Event::Key(k) if k.code == KeyCode::PageDown => *offset = offset.saturating_sub(10),
        _ => (),
    }
}
pub fn manual(args: ManualPrompt) -> Result<()> {
    let name = args.name.as_deref().unwrap_or("Manual Prompt");
    // Submitting always emits the prompt; no agent chooses whether to send.
    // Advertise this on the port so renamed nodes and every client agree.
    let mut graph_session = start(name, json!([]), Some("solid"))?;
    let (_screen, mut terminal) = screen()?;
    let mut input = TextArea::default();
    let mut editor = PromptEditor::default();
    let mut send_area = Rect::default();
    let mut sent: Vec<(String, String)> = Vec::new();
    let mut status =
        "Enter: send · Shift/Alt+Enter: newline · PgUp/PgDn/wheel: history · Ctrl+C: exit".to_owned();
    match graffitty_graph_protocol::restored_state() {
        Ok(Some(state)) => {
            let (draft, restored) = restored_prompts(&state);
            input = TextArea::from(draft.split('\n'));
            input.move_cursor(ratatui_textarea::CursorMove::Bottom);
            input.move_cursor(ratatui_textarea::CursorMove::End);
            editor.restore(restored.iter().map(|(_, text)| text.clone()).collect());
            sent = restored;
            status = format!("Restored from a checkpoint · {status}");
        }
        Ok(None) => (),
        Err(error) => status = format!("Could not restore the previous draft: {error}"),
    }
    let mut history = sent_display(&sent);
    let mut reported = (None, usize::MAX);
    let mut reported_at = std::time::Instant::now() - Duration::from_secs(1);
    let mut offset = 0u16;
    while !STOP.load(Ordering::Relaxed) {
        let draft = input.lines().join("\n");
        if reported != (Some(draft.clone()), sent.len()) && reported_at.elapsed() >= Duration::from_secs(1) {
            graph_session.report_state(prompt_state(&draft, &sent))?;
            reported = (Some(draft), sent.len());
            reported_at = std::time::Instant::now();
        }
        terminal.draw(|frame| {
            let areas = Layout::vertical([
                Constraint::Min(1),
                Constraint::Length(
                    prompt_editor::rows(&mut input, frame.area().width.saturating_sub(2), 8) + 2,
                ),
                Constraint::Length(1),
            ])
            .split(frame.area());
            let block = Block::bordered().title(name);
            let inner = block.inner(areas[0]);
            let paragraph = Paragraph::new(history.as_str()).wrap(Wrap { trim: false });
            let bottom = paragraph
                .line_count(inner.width)
                .saturating_sub(inner.height as usize)
                .min(u16::MAX as usize) as u16;
            offset = offset.min(bottom);
            frame.render_widget(
                paragraph.scroll((bottom - offset, 0)).block(block),
                areas[0],
            );
            let input_block = Block::bordered().title("Prompt");
            let input_area = input_block.inner(areas[1]);
            frame.render_widget(input_block, areas[1]);
            input.set_cursor_line_style(Style::default());
            editor.render(frame, &mut input, input_area);
            let footer = Layout::horizontal([Constraint::Min(1), Constraint::Length(10)]).split(areas[2]);
            frame.render_widget(
                Paragraph::new(status.as_str()).style(Style::default().fg(Color::DarkGray)),
                footer[0],
            );
            send_area = footer[1];
            frame.render_widget(Paragraph::new("[ Send ]").style(Style::default().fg(Color::Cyan)), send_area);
        })?;
        graph_session.heartbeat()?;
        if !event::poll(Duration::from_millis(100))? {
            continue;
        }
        let mut e = event::read()?;
        if matches!(&e, Event::Mouse(m) if m.kind == MouseEventKind::Down(MouseButton::Left)
            && send_area.contains(Position::new(m.column, m.row))) {
            e = Event::Key(crossterm::event::KeyEvent::new(KeyCode::Enter, KeyModifiers::NONE));
        }
        if matches!(&e, Event::Key(k) if k.kind == KeyEventKind::Release) {
            continue;
        }
        history_scroll(&e, &mut offset);
        match e {
            Event::Key(k)
                if k.code == KeyCode::Char('c') && k.modifiers.contains(KeyModifiers::CONTROL) =>
            {
                break;
            }
            Event::Key(k) if matches!(k.code, KeyCode::PageUp | KeyCode::PageDown) => (),
            event => {
                if !editor.input(&mut input, event) {
                    continue;
                }
                let text = input.lines().join("\n");
                if text.trim().is_empty() {
                    continue;
                }
                match rpc(
                    "graph.emit",
                    json!({"output":"out","text":text,"payload":{"text":text}}),
                ) {
                    Ok(_) => {
                        sent.push((stamp(), text));
                        history = sent_display(&sent);
                        editor.submitted(&mut input);
                        offset = 0;
                        status = "Sent · Enter: send · Shift/Alt+Enter: newline · Ctrl+C: exit".into();
                    }
                    Err(error) => status = error.to_string(),
                }
            }
        }
    }
    Ok(())
}

fn message(value: &Value) -> Option<Value> {
    let body = if value["type"] == "response_item" && value["payload"]["type"] == "message" {
        &value["payload"]
    } else if value["type"] == "user" || value["type"] == "assistant" {
        &value["message"]
    } else {
        return None;
    };
    let role = body["role"].as_str().or_else(|| value["type"].as_str())?;
    if !["user", "assistant"].contains(&role) {
        return None;
    }
    let text = if let Some(s) = body["content"].as_str() {
        s.to_owned()
    } else {
        body["content"]
            .as_array()?
            .iter()
            .filter_map(|part| match part["type"].as_str() {
                Some("text" | "input_text" | "output_text") => part["text"].as_str(),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n")
    };
    if text.is_empty() {
        return None;
    }
    Some(json!({"role":role,"text":text,"timestamp":value["timestamp"]}))
}
fn expand(path: &str, limit: Option<u64>, last: usize) -> Result<Vec<Value>> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file.take(limit.unwrap_or(u64::MAX)));
    let mut messages = VecDeque::new();
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            break;
        }
        let value: Value = match serde_json::from_str(&line) {
            Ok(value) => value,
            // A session can still be writing its last record.
            Err(_) if !line.ends_with('\n') => break,
            Err(error) => return Err(format!("Invalid session record in {path}: {error}").into()),
        };
        if let Some(value) = message(&value) {
            messages.push_back(value);
            if messages.len() > last {
                messages.pop_front();
            }
        }
    }
    Ok(messages.into_iter().collect())
}
fn expand_refs(refs: &Value, last: usize) -> Result<Value> {
    let refs = refs.as_array().ok_or("No session references supplied")?;
    if refs.is_empty() {
        return Err("No session references supplied".into());
    }
    let mut messages = Vec::new();
    for reference in refs {
        let path = reference["path"]
            .as_str()
            .ok_or("Session path unavailable; connect Read or Turn completed")?;
        messages.extend(expand(
            path,
            reference["checkpoint"]["byte_offset"].as_u64(),
            last,
        )?);
    }
    let text = messages
        .iter()
        .map(|m| {
            format!(
                "{} · {}\n{}",
                m["role"].as_str().unwrap_or(""),
                m["timestamp"].as_str().unwrap_or(""),
                m["text"].as_str().unwrap_or("")
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n");
    Ok(json!({"text":text,"payload":{"messages":messages}}))
}
// Resolve permissions on every trigger; a Send-only source is never read.
fn gather_sessions(
    args: &ReadSessionFile,
    incoming: Option<&Value>,
    last: usize,
    mut call: impl FnMut(&str, Value) -> Result<Value>,
) -> Result<Value> {
    let mut sources = Vec::new();
    if let Some(path) = &args.path {
        sources.push((String::new(), path.clone(), json!([{"path":path}])));
    } else {
        let adjacent = call("graph.adjacent", json!({}))?;
        let edges = adjacent["incoming"]
            .as_array()
            .ok_or("Invalid graph adjacency response")?;
        let mut seen = std::collections::BTreeSet::new();
        for edge in edges {
            if edge["muted"] == true || !(edge["read"] == true || edge["turn_completed"] == true) {
                continue;
            }
            let source = edge["from"]
                .as_str()
                .ok_or("Read connection has no source")?;
            if args.node.as_deref().is_some_and(|node| node != source)
                || !seen.insert(source.to_owned())
            {
                continue;
            }
            let title = edge["from_title"].as_str().filter(|title| !title.is_empty()).map(str::to_owned).unwrap_or_else(|| crate::integration::pane_label(source));
            // graph.read checks current permission, including changes since graph.adjacent.
            let read = call("graph.read", json!({"node":source}))?;
            sources.push((source.to_owned(), title, read["sessions"].clone()));
        }
    }
    if sources.is_empty() {
        return Err("No readable sessions connected. Connect Claude or Codex Read outputs, then click Read now.".into());
    }
    let mut history = Vec::new();
    let mut messages = Vec::new();
    let mut rendered = Vec::new();
    for (source, title, refs) in sources {
        let refs = refs.as_array().ok_or("Invalid session references")?;
        if refs.is_empty() {
            return Err(format!("{title}: no session available yet").into());
        }
        let mut paths = std::collections::BTreeSet::new();
        for current in refs {
            let path = current["path"].as_str().ok_or("Session path unavailable")?;
            if !paths.insert(path.to_owned()) {
                continue;
            }
            let mut reference = current.clone();
            // A completion reads its source at that event's checkpoint; other sources
            // use the snapshot returned by graph.read for this trigger.
            if let Some(event) = incoming.filter(|e| args.path.is_some() || e["source"] == source) {
                if let Some(old) = event["sessions"].as_array().and_then(|refs| {
                    refs.iter().find(|r| {
                        r["path"] == current["path"]
                            && (current["id"].is_null() || r["id"] == current["id"])
                    })
                }) {
                    if let Some(offset) = old["checkpoint"]["byte_offset"].as_u64() {
                        let limit = current["checkpoint"]["byte_offset"]
                            .as_u64()
                            .unwrap_or(offset)
                            .min(offset);
                        reference["checkpoint"] = json!({"byte_offset":limit});
                    }
                }
            }
            let expanded = expand_refs(&json!([reference]), last)?;
            let session_messages = expanded["payload"]["messages"].clone();
            rendered.push(format!(
                "{} ({})\n{}",
                title,
                if source.is_empty() { "file".into() } else { crate::integration::pane_label(&source) },
                expanded["text"].as_str().unwrap_or("")
            ));
            messages.extend(session_messages.as_array().unwrap().iter().cloned());
            history.push(json!({"source":source,"title":title,"provider":current["provider"],"session_id":current["id"],"messages":session_messages}));
        }
    }
    let history_text = rendered.join("\n\n");
    let mut payload = incoming
        .and_then(|e| e["payload"].as_object())
        .cloned()
        .unwrap_or_default();
    if let Some(event) = incoming {
        if !event["payload"].is_object() {
            payload.insert("input_payload".into(), event["payload"].clone());
        }
    }
    payload.insert("history".into(), json!(history));
    payload.insert("messages".into(), json!(messages));
    let text = incoming
        .map(|e| e["text"].as_str().unwrap_or("").to_owned())
        .unwrap_or_else(|| history_text.clone());
    Ok(json!({"text":text,"payload":payload,"history_text":history_text}))
}
fn gathered_display(content: &Value) -> String {
    let text = content["text"].as_str().unwrap_or("");
    let history = content["history_text"].as_str().unwrap_or("");
    if text.is_empty() || text == history {
        history.into()
    } else {
        format!("Current prompt\n{text}\n\n{history}")
    }
}
fn gathered_content(gathered: &Value) -> Value {
    json!({"text":gathered["text"],"payload":gathered["payload"]})
}

fn reader_fields(values: &[String]) -> Result<(Option<String>, Option<String>, usize)> {
    let path = values[0].trim();
    let node = values[1].trim();
    let last: usize = values[2]
        .trim()
        .parse()
        .map_err(|_| "Last N messages must be a positive integer")?;
    if last == 0 {
        return Err("Last N messages must be greater than zero".into());
    }
    if !path.is_empty() && !node.is_empty() {
        return Err("Choose a session path or a source node, not both".into());
    }
    Ok((
        (!path.is_empty()).then(|| path.to_owned()),
        (!node.is_empty()).then(|| node.to_owned()),
        last,
    ))
}

pub fn reader(mut args: ReadSessionFile) -> Result<()> {
    let mut last = args.last.unwrap_or(10);
    if last == 0 {
        return Err("--last must be greater than zero".into());
    }
    if args.path.is_some() && args.node.is_some() {
        return Err("Choose --path or --node".into());
    }
    let mut graph_session = start(
        "Read Session File",
        json!([{"id":"in","name":"Trigger / Read","color":"#8ecaff"}]),
        None,
    )?;
    let mut ui = if io::stdin().is_terminal() && io::stdout().is_terminal() && !args.once {
        Some(Form::session_reader(vec![
            (
                "Session path override (blank: all Read connections)",
                args.path.clone().unwrap_or_default(),
            ),
            (
                "Source node filter (blank: all permitted sources)",
                args.node.clone().unwrap_or_default(),
            ),
            ("Last N messages per session", last.to_string()),
        ])?)
    } else {
        None
    };
    let mut display = String::new();
    let mut refresh = args.once && (args.path.is_some() || args.node.is_some());
    let mut status =
        "All Read-connected sessions are gathered on incoming messages or Read now.".to_owned();
    let mut active = true;
    let mut preview = false;
    let mut printed = String::new();
    while !STOP.load(Ordering::Relaxed) {
        graph_session.heartbeat()?;
        if let Some(form) = &mut ui {
            form.set_running(active);
            match form.tick(&status, &display)? {
                Action::Quit => break,
                Action::Pause => {
                    active = false;
                    refresh = false;
                    status = "Paused · Start reads now and resumes delivery.".into();
                }
                Action::Edit => {
                    active = false;
                    refresh = false;
                    status = "Editing · F5 previews; Ctrl+Enter applies and resumes delivery.".into();
                }
                action @ (Action::Apply | Action::Preview) => match reader_fields(&form.values()) {
                    Ok((path, node, count)) => {
                        args.path = path;
                        args.node = node;
                        last = count;
                        preview = matches!(action, Action::Preview);
                        active = !preview;
                        refresh = true;
                        status = "Reading permitted sessions...".into();
                    }
                    Err(error) => {
                        active = false;
                        refresh = false;
                        status = error.to_string();
                    }
                },
                _ => (),
            }
        }
        if refresh {
            refresh = false;
            let result = (|| -> Result<Value> {
                let content = gather_sessions(&args, None, last, rpc)?;
                display = gathered_display(&content);
                if !preview {
                    rpc(
                        "graph.emit",
                        json!({"output":"out","text":content["text"],"payload":content["payload"]}),
                    )?;
                }
                Ok(content)
            })();
            match result {
                Ok(content) => {
                    display = gathered_display(&content);
                    status = if preview {
                        "Preview only · Ctrl+Enter or Read now to gather and send."
                    } else {
                        "Expanded messages sent · waiting for events."
                    }
                    .into();
                    if args.once {
                        println!("{}", content);
                        return Ok(());
                    }
                }
                Err(error) => {
                    if args.once {
                        return Err(error);
                    }
                    status = error.to_string();
                }
            }
        }
        if !active {
            continue;
        }
        let batch = graph_session.take_raw()?;
        for incoming in &batch {
            let result = (|| -> Result<Value> {
                let content = gather_sessions(&args, Some(incoming), last, rpc)?;
                display = gathered_display(&content);
                graph_session.forward_raw(incoming["event_id"].as_str().ok_or("Host event has no ID")?, "out", gathered_content(&content))?;
                graph_session.ack(incoming["event_id"].as_str().ok_or("Host event has no ID")?)?;
                Ok(content)
            })();
            match result {
                Ok(content) => {
                    display = gathered_display(&content);
                    status = if preview {
                        "Preview only · Ctrl+Enter or Read now to gather and send."
                    } else {
                        "Expanded messages sent · waiting for events."
                    }
                    .into();
                    if args.once {
                        println!("{}", content);
                        return Ok(());
                    }
                }
                Err(error) => {
                    status = error.to_string();
                    rpc(
                        "graph.progress",
                        json!({"event_id":incoming["event_id"],"status":"failed","message":status}),
                    )?;
                    if args.once {
                        return Err(error);
                    }
                }
            }
        }
        if ui.is_none() {
            if printed != display.clone() + &status {
                // JSON escaping keeps session text safe in terminal scrollback.
                println!("{}", json!({"text":display,"status":status}));
                printed = display.clone() + &status;
            }
            std::thread::sleep(Duration::from_millis(300));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manual_prompt_state_keeps_the_draft_and_the_newest_prompts_that_fit() {
        let sent: Vec<_> = (0..2000).map(|n| ("12:00:00 +09:00".to_owned(), format!("prompt {n} {}", "x".repeat(40)))).collect();
        let state = prompt_state("unsent\nsecond line", &sent);
        assert!(serde_json::to_vec(&state).unwrap().len() <= PROMPT_STATE_BYTES + 64);
        let (draft, kept) = restored_prompts(&state);
        assert_eq!(draft, "unsent\nsecond line");
        assert_eq!(kept.last(), sent.last());
        assert!(!kept.is_empty() && kept.len() < sent.len());
        assert_eq!(sent_display(&kept[kept.len() - 1..]), format!("You · 12:00:00 +09:00\n{}\n\n", sent[1999].1));
        // A draft too large to keep is dropped whole, never cut.
        let (draft, kept) = restored_prompts(&prompt_state(&"y".repeat(40 * 1024), &sent));
        assert!(draft.is_empty() && !kept.is_empty());
    }
    fn reader_args() -> ReadSessionFile {
        ReadSessionFile {
            path: None,
            node: None,
            last: Some(1),
            once: false,
        }
    }
    #[test]
    fn gathers_all_read_sources_and_preserves_trigger_without_reading_it() {
        let path = std::env::temp_dir().join(format!("gather-{}.jsonl", uuid::Uuid::new_v4()));
        let record = |text| {
            format!(
                "{}\n",
                json!({"type":"user","message":{"role":"user","content":text}})
            )
        };
        let first = record("old");
        std::fs::write(&path, first.clone() + &record("latest")).unwrap();
        let adjacent = json!({"incoming":[
            {"from":"prompt","send":true},
            {"from":"sonnet","from_title":"Sonnet","read":true},
            {"from":"sonnet","read":true,"turn_completed":true},
            {"from":"opus","from_title":"Opus","read":true},
            {"from":"muted","read":true,"muted":true}
        ]});
        let event = json!({"source":"prompt","text":"Solve this","payload":{"text":"Solve this","extra":42}});
        let mut reads = Vec::new();
        let mut call = |method: &str, params: Value| -> Result<Value> {
            if method == "graph.adjacent" {
                return Ok(adjacent.clone());
            }
            assert_eq!(method, "graph.read");
            reads.push(params["node"].as_str().unwrap().to_owned());
            Ok(json!({"sessions":[{"path":path,"id":params["node"],"provider":"claude"}]}))
        };
        let gathered = gather_sessions(&reader_args(), Some(&event), 1, &mut call).unwrap();
        assert_eq!(reads, vec!["sonnet", "opus"]);
        assert_eq!(gathered["text"], "Solve this");
        assert_eq!(gathered["payload"]["extra"], 42);
        let history = gathered["payload"]["history"].as_array().unwrap();
        assert_eq!(history.len(), 2);
        assert_eq!(history[0]["source"], "sonnet");
        assert_eq!(history[1]["title"], "Opus");
        assert_eq!(history[0]["messages"].as_array().unwrap().len(), 1);
        assert_eq!(history[0]["messages"][0]["text"], "latest");
        // Clicking Read now uses the same gathering operation, without a prompt.
        let manual = gather_sessions(&reader_args(), None, 1, |method, _| {
            if method == "graph.adjacent" {
                Ok(adjacent.clone())
            } else {
                Ok(json!({"sessions":[{"path":path}]}))
            }
        })
        .unwrap();
        assert!(manual["text"].as_str().unwrap().contains("Sonnet (sonnet)"));
        assert!(manual["text"].as_str().unwrap().contains("Opus (opus)"));
        assert!(!manual["text"].as_str().unwrap().contains("Solve this"));
        assert!(gathered_content(&manual).get("history_text").is_none());
        // A completion bounds only its own session, while other sources stay current.
        let completion = json!({"source":"sonnet","text":"Done","sessions":[{"path":path,"id":"sonnet","checkpoint":{"byte_offset":first.len()}}]});
        let bounded = gather_sessions(&reader_args(), Some(&completion), 1, |method, params| {
            if method == "graph.adjacent" {
                Ok(adjacent.clone())
            } else {
                Ok(json!({"sessions":[{"path":path,"id":params["node"]}]}))
            }
        })
        .unwrap();
        assert_eq!(
            bounded["payload"]["history"][0]["messages"][0]["text"],
            "old"
        );
        assert_eq!(
            bounded["payload"]["history"][1]["messages"][0]["text"],
            "latest"
        );
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn gather_does_not_emit_partial_history_or_read_without_permission() {
        assert!(
            gather_sessions(&reader_args(), None, 10, |method, _| {
                assert_eq!(method, "graph.adjacent");
                Ok(json!({"incoming":[{"from":"prompt","send":true}]}))
            })
            .is_err()
        );
        let mut called = false;
        assert!(
            gather_sessions(&reader_args(), None, 10, |method, _| {
                if method == "graph.adjacent" {
                    return Ok(json!({"incoming":[{"from":"claude","read":true}]}));
                }
                called = true;
                Err("Read permission revoked".into())
            })
            .is_err()
        );
        assert!(called);
    }
    #[test]
    fn reader_form_validates_sources_and_message_count() {
        let fields =
            |path: &str, node: &str, last: &str| vec![path.into(), node.into(), last.into()];
        assert_eq!(
            reader_fields(&fields("", "", "10")).unwrap(),
            (None, None, 10)
        );
        assert_eq!(
            reader_fields(&fields(" /tmp/session.jsonl ", "", " 3 ")).unwrap(),
            (Some("/tmp/session.jsonl".into()), None, 3)
        );
        assert_eq!(
            reader_fields(&fields("", "%1", "5")).unwrap(),
            (None, Some("%1".into()), 5)
        );
        assert!(reader_fields(&fields("file", "%1", "5")).is_err());
        for invalid in ["0", "-1", "abc", "", "1.5"] {
            assert!(reader_fields(&fields("", "", invalid)).is_err());
        }
    }
    #[test]
    fn unavailable_references_fail_without_guessing_a_path() {
        assert!(expand_refs(&json!([]), 10).is_err());
        assert!(expand_refs(&json!([{"provider":"codex","id":"private"}]), 10).is_err());
    }
    #[test]
    fn expansion_preserves_roles_timestamps_and_text_blocks() {
        let path = std::env::temp_dir().join(format!("session-{}.jsonl", uuid::Uuid::new_v4()));
        let record = json!({"type":"assistant","timestamp":"2026-10-01T12:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"first"},{"type":"tool_use","name":"read"},{"type":"text","text":"second"}]}});
        std::fs::write(&path, format!("{record}\n")).unwrap();
        let output = expand_refs(&json!([{"path":path}]), 10).unwrap();
        assert_eq!(output["payload"]["messages"][0]["text"], "first\nsecond");
        assert_eq!(
            output["text"],
            "assistant · 2026-10-01T12:00:00Z\nfirst\nsecond"
        );
        std::fs::write(&path, "not json\n").unwrap();
        assert!(expand(path.to_str().unwrap(), None, 10).is_err());
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn provider_messages_skip_tools_and_duplicate_events() {
        assert_eq!(message(&json!({"type":"response_item","timestamp":"now","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"hello"}]}})).unwrap()["text"], "hello");
        assert_eq!(
            message(&json!({"type":"user","message":{"role":"user","content":"hi"}})).unwrap()["text"],
            "hi"
        );
        assert!(message(&json!({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"read"}]}})).is_none());
        assert!(message(&json!({"type":"event_msg","payload":{"type":"agent_message","message":"duplicate"}})).is_none());
    }
    #[test]
    fn tail_respects_checkpoint_and_incomplete_record() {
        let path = std::env::temp_dir().join(format!("session-{}.jsonl", uuid::Uuid::new_v4()));
        let record = |text| {
            format!(
                "{}\n",
                json!({"type":"user","message":{"role":"user","content":text}})
            )
        };
        let prefix = record("first") + &record("second");
        std::fs::write(&path, prefix.clone() + &record("later") + "{\"type\":").unwrap();
        let messages = expand(path.to_str().unwrap(), Some(prefix.len() as u64), 1).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0]["text"], "second");
        assert_eq!(
            expand(path.to_str().unwrap(), None, 1).unwrap()[0]["text"],
            "later"
        );
        std::fs::remove_file(path).unwrap();
    }
}
