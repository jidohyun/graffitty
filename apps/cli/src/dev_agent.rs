//! Scripted terminal agents. Provider identity and queue transport are independent.
mod activity;
mod animation_clock;
mod completion;
mod execution;
mod palette;
mod presentation;
mod scenario;
mod streaming;
mod ui;
use crate::{agent_bridge::Result, options::AgentPlayback};
use scenario::{Scenario, Step};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    fs::{self, File},
    io::{self, IsTerminal, Write},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Provider {
    Codex,
    Claude,
}
impl Provider {
    fn id(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        }
    }
    fn name(self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::Claude => "Claude Code",
        }
    }
    fn model(self) -> &'static str {
        match self {
            Self::Codex => "gpt-6.1 high",
            Self::Claude => "Opus 5.5 with max effort",
        }
    }
    fn version(self) -> &'static str {
        match self {
            Self::Codex => "0.162.1",
            Self::Claude => "2.1.301",
        }
    }
}
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

struct Host {
    context: Option<(String, String)>,
    provider: Provider,
    session: String,
}
impl Host {
    fn call(&self, method: &str, params: Value) -> Result<Value> {
        let Some(context) = &self.context else {
            return Ok(json!({"events":[]}));
        };
        use graffitty_graph_protocol::Rpc;
        graffitty_graph_protocol::Client::new(&context.0, &context.1)
            .with_timeout(Duration::from_secs(3)).call(method, params)
    }
    fn event(&self, event: &str, mut params: Value) -> Result<()> {
        params["provider"] = json!(self.provider.id());
        params["session_id"] = json!(self.session);
        params["event"] = json!(event);
        let result = self.call("agent.event", params)?;
        if event == "SessionStart" && self.context.is_some() && result["transport"] != "inbox" {
            return Err("The session server needs an update. Restart Graffitty's session server with this gft build to enable inbox agents.".into());
        }
        Ok(())
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.event("SessionEnd", json!({}));
    }
}

#[derive(Clone, Debug)]
enum Entry {
    User(String),
    Message(String),
    Tool {
        name: String,
        input: String,
        output: String,
        complete: bool,
        exit_code: i32,
        preview_lines: usize,
    },
    Edit {
        path: String,
        before: String,
        after: String,
        line: usize,
        preview_lines: usize,
        complete: bool,
    },
    Note(String),
    Completed(completion::Completion),
}
struct Active {
    real_tool_calling: bool,
    execution: Option<execution::Execution>,
    steps: Vec<Step>,
    streams: Vec<Option<streaming::Schedule>>,
    completion: completion::Settings,
    completion_id: String,
    claude_working_word: &'static str,
    index: usize,
    step_at: u64,
    entered: bool,
    answer: String,
    started: Instant,
}
#[derive(Debug, PartialEq)]
enum Effect {
    ToolStart,
    ToolEnd,
    ToolResult(String, String, String, i32),
    Message(String),
    Completed(String),
}
struct Playback {
    history: Vec<Entry>,
    active: Option<Active>,
    title: String,
    turn: usize,
    sequence: usize,
}
impl Playback {
    fn new(title: String) -> Self {
        Self {
            history: Vec::new(),
            active: None,
            title,
            turn: 0,
            sequence: 0,
        }
    }
    fn start(&mut self, prompt: &str, settings: &Scenario) {
        self.turn += 1;
        let (steps, title, completion) = settings.select(prompt, self.turn, &mut self.sequence);
        if let Some(title) = title {
            self.title = title;
        } else if self.turn == 1 && settings.title.is_empty() {
            self.title = scenario::title(prompt);
        }
        self.history.push(Entry::User(scenario::clean(prompt)));
        let streams = steps
            .iter()
            .enumerate()
            .map(|(index, step)| {
                if let Step::Message { text, char_ms } = step {
                    Some(streaming::Schedule::new(
                        text,
                        char_ms.unwrap_or(settings.char_ms),
                        &settings.stream,
                        self.turn,
                        index,
                    ))
                } else {
                    None
                }
            })
            .collect();
        self.active = Some(Active {
            real_tool_calling: settings.real_tool_calling,
            execution: None,
            steps,
            streams,
            completion,
            completion_id: completion::message_id(settings.stream.seed, self.turn),
            claude_working_word: activity::claude_verb(settings.stream.seed, self.turn),
            index: 0,
            step_at: 0,
            entered: false,
            answer: String::new(),
            started: Instant::now(),
        });
    }
    fn advance(&mut self, elapsed_ms: u64) -> Vec<Effect> {
        let mut effects = Vec::new();
        let Some(active) = &mut self.active else {
            return effects;
        };
        loop {
            let Some(step) = active.steps.get(active.index) else {
                effects.push(Effect::Completed(active.answer.clone()));
                self.history.push(Entry::Completed(
                    active.completion.finish(elapsed_ms, &active.completion_id),
                ));
                self.active = None;
                return effects;
            };
            if !active.entered {
                match step {
                    Step::Message { .. } => self.history.push(Entry::Message(String::new())),
                    Step::Tool {
                        name,
                        command,
                        input,
                        exit_code,
                        preview_lines,
                        ..
                    } => {
                        self.history.push(Entry::Tool {
                            name: name.clone(),
                            input: input.clone(),
                            output: String::new(),
                            complete: false,
                            exit_code: *exit_code,
                            preview_lines: *preview_lines,
                        });
                        effects.push(Effect::ToolStart);
                        if active.real_tool_calling {
                            active.execution = Some(execution::Execution::start(command));
                            active.step_at = elapsed_ms;
                        }
                    }
                    Step::Edit {
                        path,
                        before,
                        after,
                        line,
                        preview_lines,
                        ..
                    } => {
                        self.history.push(Entry::Edit {
                            path: path.clone(),
                            before: before.clone(),
                            after: after.clone(),
                            line: *line,
                            preview_lines: *preview_lines,
                            complete: false,
                        });
                        effects.push(Effect::ToolStart);
                    }
                    _ => (),
                }
                active.entered = true;
            }
            let elapsed = elapsed_ms.saturating_sub(active.step_at);
            let mut duration = match step {
                Step::Think { ms, .. }
                | Step::Wait { ms }
                | Step::Tool { ms, .. }
                | Step::Edit { ms, .. } => *ms,
                Step::Message { text, .. } => {
                    let stream = active.streams[active.index]
                        .as_ref()
                        .expect("message stream");
                    if let Some(Entry::Message(shown)) = self.history.last_mut() {
                        *shown = stream.visible(text, elapsed).into();
                    }
                    stream.duration()
                }
            };
            if let Some(execution) = &mut active.execution {
                execution.poll();
                if let Some(Entry::Tool {
                    output, exit_code, ..
                }) = self.history.last_mut()
                {
                    *output = execution.output.clone();
                    if let Some(code) = execution.exit_code {
                        *exit_code = code;
                    }
                }
                if execution.exit_code.is_none() {
                    break;
                }
                duration = duration.max(elapsed);
            }
            if elapsed < duration {
                break;
            }
            match step {
                Step::Message { text, .. } => {
                    active.answer = text.clone();
                    effects.push(Effect::Message(text.clone()));
                }
                Step::Tool {
                    name,
                    input,
                    output,
                    ..
                } => {
                    let actual = active.execution.take();
                    if let Some(Entry::Tool {
                        output: shown,
                        complete,
                        exit_code,
                        ..
                    }) = self.history.last_mut()
                    {
                        *shown = actual
                            .as_ref()
                            .map_or_else(|| output.clone(), |e| e.output.clone());
                        if let Some(execution) = &actual {
                            *exit_code = execution.exit_code.unwrap_or(1);
                        }
                        *complete = true;
                    }
                    effects.push(Effect::ToolEnd);
                    if let Some(actual) = actual {
                        let code = actual.exit_code.unwrap_or(1);
                        effects.push(Effect::ToolResult(
                            name.clone(),
                            input.clone(),
                            actual.output.clone(),
                            code,
                        ));
                        if code != 0 {
                            let message = format!("Command failed (exit {code}).");
                            self.history.push(Entry::Message(message.clone()));
                            self.history.push(Entry::Completed(
                                active.completion.finish(elapsed_ms, &active.completion_id),
                            ));
                            effects.push(Effect::Message(message.clone()));
                            effects.push(Effect::Completed(message));
                            self.active = None;
                            return effects;
                        }
                    }
                }
                Step::Edit { .. } => {
                    if let Some(Entry::Edit { complete, .. }) = self.history.last_mut() {
                        *complete = true;
                    }
                    effects.push(Effect::ToolEnd);
                }
                _ => (),
            }
            active.step_at = active.step_at.saturating_add(duration);
            active.index += 1;
            active.entered = false;
        }
        effects
    }
    fn thinking(&self, provider: Provider) -> String {
        self.active
            .as_ref()
            .and_then(|a| a.steps.get(a.index))
            .and_then(|s| match s {
                Step::Think { text, .. } if !text.is_empty() => Some(text.clone()),
                _ => None,
            })
            .unwrap_or_else(|| {
                if provider == Provider::Codex {
                    "Working"
                } else {
                    self.active
                        .as_ref()
                        .map_or("Working", |a| a.claude_working_word)
                }
                .into()
            })
    }
}

struct Transcript {
    file: File,
    provider: Provider,
}
impl Transcript {
    fn tool(&mut self, name: &str, input: &str, output: &str, exit_code: i32) -> Result<()> {
        let id = uuid::Uuid::new_v4().to_string();
        let input = if self.provider == Provider::Codex {
            json!({"cmd": input})
        } else {
            json!({"command": input})
        };
        let records = if self.provider == Provider::Codex {
            vec![
                json!({"type":"response_item","payload":{"type":"function_call","call_id":id,"name":name,"arguments":input.to_string()}}),
                json!({"type":"response_item","payload":{"type":"function_call_output","call_id":id,"output":output,"exit_code":exit_code}}),
            ]
        } else {
            vec![
                json!({"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":id,"name":name,"input":input}]}}),
                json!({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":id,"content":output,"is_error":exit_code != 0}]}}),
            ]
        };
        for record in records {
            writeln!(self.file, "{record}")?;
        }
        self.file.flush()?;
        Ok(())
    }
    fn message(&mut self, role: &str, text: &str) -> Result<()> {
        let value = if self.provider == Provider::Codex {
            json!({"type":"response_item","payload":{"type":"message","role":role,"content":[{"type":if role=="user"{"input_text"}else{"output_text"},"text":text}]}})
        } else {
            json!({"type":role,"message":{"role":role,"content":[{"type":"text","text":text}]}})
        };
        writeln!(self.file, "{value}")?;
        self.file.flush()?;
        Ok(())
    }
}
fn set_title(title: &str) -> Result<()> {
    // OSC uses the normal terminal title path, including pane/tab titles.
    write!(io::stdout(), "\x1b]2;{}\x07", scenario::title(title))?;
    io::stdout().flush()?;
    Ok(())
}
fn begin(
    host: &Host,
    transcript: &mut Transcript,
    playback: &mut Playback,
    settings: &Scenario,
    prompt: &str,
    event: Option<&Value>,
    interactive: bool,
) -> Result<()> {
    let hook_prompt = if let Some(event) = event {
        // Claim only the currently live queued event; revocation wins before acknowledgement.
        if let Err(error) = host.call(
            "graph.ack",
            json!({"event_id":event["event_id"],"status":"delivered"}),
        ) {
            let inbox = host.call("graph.take", json!({}))?;
            if inbox["events"]
                .as_array()
                .is_some_and(|events| !events.iter().any(|e| e["event_id"] == event["event_id"]))
            {
                return Ok(()); // The wire was revoked between take and ack.
            }
            return Err(error);
        }
        graffitty_workspace_core::graph::message_prompt(event)
    } else {
        prompt.into()
    };
    playback.start(prompt, settings);
    // Scenario matching and the short title use event.text; the actual user
    // message retains the same envelope the native provider receives.
    if let Some(Entry::User(text)) = playback.history.last_mut() {
        *text = scenario::clean(&hook_prompt);
    }
    host.event(
        "UserPromptSubmit",
        json!({"prompt":hook_prompt,"title":playback.title}),
    )?;
    transcript.message("user", &hook_prompt)?;
    if interactive {
        set_title(&playback.title)?;
    } else {
        println!(
            "{} {hook_prompt}",
            if host.provider == Provider::Codex {
                "›"
            } else {
                "❯"
            }
        );
    }
    Ok(())
}

pub fn run(provider: Provider, args: AgentPlayback) -> Result<()> {
    let settings = Scenario::load(&args, provider)?;
    let interactive = !args.headless && io::stdin().is_terminal() && io::stdout().is_terminal();
    let endpoint = std::env::var("GRAFFITTY_SOCKET")
        .ok()
        .filter(|s| !s.is_empty());
    let token = std::env::var("GRAFFITTY_TOKEN")
        .ok()
        .filter(|s| !s.is_empty());
    if endpoint.is_some() != token.is_some() {
        return Err("GRAFFITTY_SOCKET and GRAFFITTY_TOKEN must both be set".into());
    }
    if !interactive && endpoint.is_none() && args.prompt.is_none() {
        return Err("Provide --prompt or run in a Graffitty terminal".into());
    }
    let session = uuid::Uuid::new_v4().to_string();
    let folder = std::env::var_os("XDG_STATE_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|p| std::path::PathBuf::from(p).join(".local/state"))
        })
        .unwrap_or_else(std::env::temp_dir)
        .join("graffitty/recording-sessions");
    fs::create_dir_all(&folder)?;
    let path = folder.join(format!("{session}.jsonl"));
    let mut transcript = Transcript {
        file: File::create(&path)?,
        provider,
    };
    let host = Host {
        context: endpoint.zip(token),
        provider,
        session,
    };
    let title = if settings.title.is_empty() {
        provider.name().into()
    } else {
        scenario::title(&settings.title)
    };
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
        #[cfg(unix)]
        libc::signal(libc::SIGHUP, stop as *const () as libc::sighandler_t);
    }
    let mut screen = if interactive {
        set_title(&title)?;
        Some(ui::Screen::new(settings.palette)?)
    } else {
        None
    };
    let mut playback = Playback::new(title.clone());
    // Complete the terminal color probe and first frame before advertising that
    // the agent is ready to receive messages from the graph.
    if let Some(screen) = &mut screen {
        screen.draw(&playback, &settings, provider, 0, 0)?;
    }
    host.event("SessionStart", json!({"transport":"inbox","integrated":true,"pid":std::process::id(),"transcript_path":path,"title":title}))?;
    let mut local = VecDeque::new();
    if let Some(prompt) = args.prompt {
        local.push_back(prompt);
    }
    let mut scenario_clock =
        animation_clock::AnimationClock::new(settings.scenario_clock.clone());
    let mut animation_clock =
        animation_clock::AnimationClock::new(settings.animation_clock.clone());
    let mut heartbeat = Instant::now();
    let mut poll = Instant::now() - Duration::from_secs(1);
    while !STOP.load(Ordering::Relaxed) {
        if heartbeat.elapsed() >= Duration::from_secs(3) {
            host.call("agent.heartbeat", json!({}))?;
            heartbeat = Instant::now();
        }
        if playback.active.is_none() {
            if let Some(prompt) = local.pop_front() {
                begin(
                    &host,
                    &mut transcript,
                    &mut playback,
                    &settings,
                    &prompt,
                    None,
                    interactive,
                )?;
            } else if poll.elapsed() >= Duration::from_millis(150) {
                let inbox = host.call("graph.take", json!({}))?;
                if let Some(event) = inbox["events"].as_array().and_then(|a| a.first()) {
                    let prompt = event["text"].as_str().unwrap_or("");
                    begin(
                        &host,
                        &mut transcript,
                        &mut playback,
                        &settings,
                        prompt,
                        Some(event),
                        interactive,
                    )?;
                }
                poll = Instant::now();
            }
        }
        let elapsed = playback
            .active
            .as_ref()
            .map_or(0, |a| a.started.elapsed().as_millis() as u64);
        // Work can follow capture time independently of decorative animation.
        let scenario_elapsed =
            scenario_clock.elapsed(playback.active.as_ref().map(|a| a.started), elapsed);
        let mut finished = false;
        for effect in playback.advance(scenario_elapsed) {
            match effect {
                Effect::ToolStart => host.event("PreToolUse", json!({}))?,
                Effect::ToolEnd => host.event("PostToolUse", json!({}))?,
                Effect::ToolResult(name, input, output, code) => {
                    transcript.tool(&name, &input, &output, code)?;
                    if !interactive {
                        println!("{name}({input})\n{output}\nExit code: {code}");
                    }
                }
                Effect::Message(text) => {
                    transcript.message("assistant", &text)?;
                    if !interactive {
                        println!(
                            "{} {text}",
                            if provider == Provider::Codex {
                                "•"
                            } else {
                                "●"
                            }
                        );
                    }
                }
                Effect::Completed(text) => {
                    host.event("Stop", json!({"text":text}))?;
                    finished = true;
                }
            }
        }
        if let Some(screen) = &mut screen {
            let animation_elapsed =
                animation_clock.elapsed(playback.active.as_ref().map(|a| a.started), elapsed);
            screen.draw(
                &playback,
                &settings,
                provider,
                animation_elapsed,
                local.len(),
            )?;
            if finished && args.once {
                break;
            }
            match screen.input()? {
                ui::Action::Submit(prompt) => {
                    local.push_back(prompt);
                }
                ui::Action::Cancel if playback.active.is_some() => {
                    playback.active = None;
                    playback
                        .history
                        .push(Entry::Note("Conversation interrupted".into()));
                    host.event("Ready", json!({}))?;
                }
                ui::Action::Exit => break,
                _ => (),
            }
        } else {
            if finished && args.once {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn claude_working_word_persists_across_phases_and_respects_explicit_text() {
        let settings: Scenario = serde_json::from_value(json!({
            "char_ms": 0,
            "turns":[{"steps":[
                {"type":"think","ms":100},
                {"type":"tool","name":"Read","input":"app.rs","ms":100},
                {"type":"think","ms":100,"text":"Reviewing the changes"},
                {"type":"wait","ms":100},
                {"type":"message","text":"Done","char_ms":100}
            ]}]
        }))
        .unwrap();
        let mut p = Playback::new("Claude Code".into());
        p.start("Review", &settings);
        let word = p.thinking(Provider::Claude);
        assert_eq!(word, activity::claude_verb(1, 1));
        assert_eq!(p.thinking(Provider::Codex), "Working");
        p.advance(100);
        assert_eq!(p.thinking(Provider::Claude), word);
        p.advance(200);
        assert_eq!(p.thinking(Provider::Claude), "Reviewing the changes");
        p.advance(300);
        assert_eq!(p.thinking(Provider::Claude), word);
        p.advance(400);
        assert_eq!(p.thinking(Provider::Claude), word);
        p.advance(2000);
        p.start("Review again", &settings);
        assert_eq!(p.thinking(Provider::Claude), activity::claude_verb(1, 2));
        assert_ne!(p.thinking(Provider::Claude), word);
    }
    #[test]
    fn completion_is_frozen_once_and_does_not_change_the_answer_or_waits() {
        let settings: Scenario = serde_json::from_value(json!({
            "char_ms":0, "think_ms":100, "response":"Done",
            "completion":{"elapsed_ms":1_120_000,"completed_at":"11:13 PM"},
            "turns":[{"completion":{"completed_at":"3:03 PM","verb":"Cooked"}}]
        }))
        .unwrap();
        let mut p = Playback::new("Codex".into());
        p.start("First", &settings);
        assert!(p.advance(99).is_empty());
        assert_eq!(
            p.advance(100),
            [
                Effect::Message("Done".into()),
                Effect::Completed("Done".into())
            ]
        );
        let Some(Entry::Completed(c)) = p.history.last() else {
            panic!("missing completion")
        };
        assert_eq!(c.elapsed_ms, 1_120_000);
        assert_eq!(c.completed_at, "3:03 PM");
        assert_eq!(c.verb, "Cooked");
        assert!(p.advance(5000).is_empty());
        assert_eq!(
            p.history
                .iter()
                .filter(|e| matches!(e, Entry::Completed(_)))
                .count(),
            1
        );
        p.start("Second", &settings);
        p.advance(100);
        let Some(Entry::Completed(c)) = p.history.last() else {
            panic!("missing completion")
        };
        assert_eq!(c.completed_at, "11:13 PM");
    }

    #[test]
    fn edits_use_the_tool_lifecycle_and_complete_with_the_scripted_answer() {
        let settings: Scenario = serde_json::from_value(json!({"char_ms":0,"turns":[{"steps":[
            {"type":"edit","path":"app.py","before":"a = 1\n","after":"a = 2\n","line":10,"ms":200}],
            "response":"Done"}]})).unwrap();
        let mut p = Playback::new("Codex".into());
        p.start("Fix the app", &settings);
        assert_eq!(p.advance(0), [Effect::ToolStart]);
        assert!(matches!(
            p.history.last(),
            Some(Entry::Edit {
                complete: false,
                line: 10,
                ..
            })
        ));
        assert!(p.advance(199).is_empty());
        assert_eq!(
            p.advance(200),
            [
                Effect::ToolEnd,
                Effect::Message("Done".into()),
                Effect::Completed("Done".into())
            ]
        );
        assert!(matches!(
            p.history.get(1),
            Some(Entry::Edit { complete: true, .. })
        ));
    }
    #[test]
    fn playback_obeys_pauses_streaming_and_tool_lifecycle_without_sleeping() {
        let settings: Scenario = serde_json::from_value(json!({"char_ms":10,"stream":{"mode":"characters","jitter_percent":0},"turns":[{"steps":[
            {"type":"think","ms":100}, {"type":"tool","name":"Read","input":"app.rs","output":"hello","ms":200},
            {"type":"message","text":"한글!"}]}]})).unwrap();
        let mut p = Playback::new("Codex".into());
        p.start("Fix the app", &settings);
        assert_eq!(p.title, "Fix the app");
        assert!(p.advance(99).is_empty());
        assert_eq!(p.advance(100), [Effect::ToolStart]);
        assert!(p.advance(299).is_empty());
        assert_eq!(p.advance(310), [Effect::ToolEnd]);
        assert!(matches!(p.history.last(), Some(Entry::Message(s)) if s == "한"));
        assert_eq!(
            p.advance(330),
            [
                Effect::Message("한글!".into()),
                Effect::Completed("한글!".into())
            ]
        );
        assert!(p.advance(400).is_empty());
        p.start("Second prompt", &settings);
        assert_eq!(p.title, "Fix the app");
    }
}
