//! jq routing over the common event envelope, with optional content replacement.
use crate::node_rpc as rpc;
use crate::{
    agent_bridge::Result,
    node_form::{Action, Form},
    options::Filter,
};
use jaq_core::{
    Compiler, Ctx, Vars, data,
    load::{Arena, File, Loader},
    unwrap_valr,
};
use jaq_json::Val;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::IsTerminal,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

pub(crate) type Program = jaq_core::compile::Filter<jaq_core::Native<data::JustLut<Val>>>;
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    name: String,
    icon: Value,
    input: String,
    condition: String,
    transform: String,
    after: String,
    before: String,
    output_names: BTreeMap<String, String>,
    output_colors: BTreeMap<String, String>,
    output_icons: BTreeMap<String, Value>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            name: "Filter".into(),
            icon: json!({"svg":include_str!("../assets/icons/funnel.svg").replace("currentColor", "#d8e2ef")}),
            input: ".text".into(),
            condition: String::new(),
            transform: String::new(),
            after: String::new(),
            before: String::new(),
            output_names: BTreeMap::new(),
            output_colors: BTreeMap::new(),
            output_icons: BTreeMap::new(),
        }
    }
}
impl Settings {
    fn manifest(&self) -> Value {
        let outputs: Vec<_> = [("matched", "Matched", "#89ddbd", "✓"), ("unmatched", "Unmatched", "#ffd47a", "−")].into_iter().map(|(id, name, color, icon)| json!({"id":id,"name":self.output_names.get(id).map(String::as_str).unwrap_or(name),"color":self.output_colors.get(id).map(String::as_str).unwrap_or(color),"icon":self.output_icons.get(id).cloned().unwrap_or(json!(icon))})).collect();
        json!({"name":self.name,"icon":self.icon,"inputs":[{"id":"in","name":"Evaluate","color":"#8ecaff"}],"outputs":outputs})
    }
    pub(crate) fn compile(&self) -> Result<Expressions> {
        let now = crate::time_trigger::now_ms();
        let bound = |s: &str| -> Result<Option<i64>> {
            if s.trim().is_empty() {
                Ok(None)
            } else {
                Ok(Some(crate::time_trigger::parse_time(s, now)?))
            }
        };
        let after = bound(&self.after)?;
        let before = bound(&self.before)?;
        if matches!((after, before), (Some(a), Some(b)) if a >= b) {
            return Err("Before must be later than After".into());
        }
        if self.condition.trim().is_empty() && after.is_none() && before.is_none() {
            return Err(
                "Condition is required. Enter a jq expression such as contains(\"error\").".into(),
            );
        }
        for key in self
            .output_names
            .keys()
            .chain(self.output_colors.keys())
            .chain(self.output_icons.keys())
        {
            if key != "matched" && key != "unmatched" {
                return Err(format!("Unknown output: {key}").into());
            }
        }
        Ok(Expressions {
            after,
            before,
            input: compile(&self.input, "Input")?,
            condition: compile(
                if self.condition.trim().is_empty() {
                    "true"
                } else {
                    &self.condition
                },
                "Condition",
            )?,
            transform: if self.transform.trim().is_empty() {
                None
            } else {
                Some(compile(&self.transform, "Transform")?)
            },
        })
    }
}
pub(crate) fn compile(code: &str, stage: &str) -> Result<Program> {
    let arena = Arena::default();
    let loader = Loader::new(
        jaq_core::defs()
            .chain(jaq_std::defs())
            .chain(jaq_json::defs()),
    );
    let modules = loader
        .load(&arena, File { code, path: () })
        .map_err(|e| format!("{stage}: invalid jq expression: {e:?}"))?;
    Compiler::default()
        .with_funs(
            jaq_core::funs()
                .chain(jaq_std::funs())
                .chain(jaq_json::funs()),
        )
        .compile(modules)
        .map_err(|e| format!("{stage}: jq compile error: {e:?}").into())
}
pub(crate) fn evaluate(
    program: &Program,
    input: &Value,
    stage: &str,
    allow_empty: bool,
) -> Result<Option<Value>> {
    let value: Val = serde_json::from_value(input.clone())?;
    let ctx = Ctx::<data::JustLut<Val>>::new(&program.lut, Vars::new([]));
    let mut results = program.id.run((ctx, value)).map(unwrap_valr);
    let first = match results.next() {
        Some(Ok(value)) => value,
        Some(Err(error)) => return Err(format!("{stage}: {error}").into()),
        None if allow_empty => return Ok(None),
        None => return Err(format!("{stage}: expected exactly one result, received none").into()),
    };
    if results.next().is_some() {
        return Err(format!("{stage}: expected exactly one result, received multiple").into());
    }
    Ok(Some(serde_json::from_str(&first.to_string())?))
}
struct Expressions {
    after: Option<i64>,
    before: Option<i64>,
    input: Program,
    condition: Program,
    transform: Option<Program>,
}
impl Expressions {
    fn process(&self, event: &Value) -> Result<Option<(&'static str, Value)>> {
        self.process_at(event, crate::time_trigger::now_ms())
    }
    fn process_at(&self, event: &Value, now: i64) -> Result<Option<(&'static str, Value)>> {
        if self.after.is_some_and(|a| now < a) || self.before.is_some_and(|b| now >= b) {
            return Ok(None);
        }
        let input = evaluate(&self.input, event, "Input", false)?.unwrap();
        if input.is_null() {
            return Err("Input: selected value is null or missing; choose a field or supply a jq fallback with //".into());
        }
        let decision = evaluate(&self.condition, &input, "Condition", false)?.unwrap();
        let matched = decision
            .as_bool()
            .ok_or("Condition: expected exactly one boolean (true or false)")?;
        let content = match &self.transform {
            None => json!({}),
            Some(program) => match evaluate(program, event, "Transform", true)? {
                Some(value) => value,
                None => return Ok(None),
            },
        };
        let fields = content
            .as_object()
            .ok_or("Transform: return an object containing text and/or payload")?;
        if fields
            .keys()
            .any(|k| !["text", "payload", "content", "renderings"].contains(&k.as_str()))
        {
            return Err("Transform: only text, payload, content and renderings can be changed; routing and session metadata are preserved by the host".into());
        }
        if fields.get("text").is_some_and(|text| !text.is_string()) {
            return Err("Transform: text must be a string".into());
        }
        if fields.get("content").is_some_and(|v| !v.is_array())
            || fields.get("renderings").is_some_and(|v| !v.is_object())
        {
            return Err("Transform: content must be an array and renderings an object".into());
        }
        Ok(Some((
            if matched { "matched" } else { "unmatched" },
            content,
        )))
    }
}

pub fn run(args: Filter) -> Result<()> {
    let mut config = crate::node_config::load(
        serde_json::to_value(Settings::default())?,
        args.config.as_deref(),
    )?;
    for (key, value) in [
        ("name", args.name),
        ("input", args.input),
        ("condition", args.condition),
        ("transform", args.transform),
        ("after", args.after),
        ("before", args.before),
    ] {
        if let Some(value) = value {
            config[key] = json!(value);
        }
    }
    let mut settings: Settings = serde_json::from_value(config)?;
    if args.edit && args.headless {
        return Err("Choose either --edit or --headless".into());
    }
    let interactive = !args.headless
        && (args.edit
            || (settings.condition.trim().is_empty()
                && settings.after.trim().is_empty()
                && settings.before.trim().is_empty()));
    if interactive && !(std::io::stdin().is_terminal() && std::io::stdout().is_terminal()) {
        return Err("A condition is required without a terminal. Use --condition, --config, or GRAFFITTY_NODE_CONFIG.".into());
    }
    let mut expressions = if interactive {
        None
    } else {
        Some(settings.compile()?)
    };
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let mut graph_session = crate::node_session(true)?;
    graph_session.register_raw(settings.manifest())?;
    let mut form = if interactive {
        Some(Form::new(vec![
            ("Name", settings.name.clone()),
            ("Input · jq on complete event", settings.input.clone()),
            (
                "Condition · jq on selected input",
                settings.condition.clone(),
            ),
            (
                "Transform · jq on complete event; blank forwards original",
                settings.transform.clone(),
            ),
            (
                "After · inclusive; local time or timestamp",
                settings.after.clone(),
            ),
            (
                "Before · exclusive; outside window stops here",
                settings.before.clone(),
            ),
        ])?)
    } else {
        None
    };
    let mut status = "Paused · enter a condition or time window, then Ctrl+Enter to apply.".to_owned();
    let mut sample = "Common fields: .text, .payload, .kind, .sessions (each with .checkpoint), .source\nNo incoming event yet.".to_owned();
    let mut last_poll = Instant::now() - Duration::from_secs(1);
    while !STOP.load(Ordering::Relaxed) {
        graph_session.heartbeat()?;
        if let Some(form) = &mut form {
            form.set_running(expressions.is_some());
            match form.tick(&status, &sample)? {
                Action::Quit => break,
                Action::Pause => {
                    expressions = None;
                    status = "Paused · Start resumes delivery. Queued input is retained.".into();
                }
                Action::Edit => {
                    expressions = None;
                    status = "Paused · Ctrl+Enter to validate and apply changes.".into();
                }
                Action::Apply => {
                    let values = form.values();
                    settings.name = values[0].clone();
                    settings.input = values[1].clone();
                    settings.condition = values[2].clone();
                    settings.transform = values[3].clone();
                    settings.after = values[4].clone();
                    settings.before = values[5].clone();
                    match settings.compile().and_then(|compiled| {
                        graph_session.register_raw(settings.manifest())?;
                        Ok(compiled)
                    }) {
                        Ok(compiled) => {
                            expressions = Some(compiled);
                            status = "Running · waiting for events.".into();
                        }
                        Err(error) => {
                            expressions = None;
                            status = error.to_string();
                        }
                    }
                }
                Action::None | Action::Preview | Action::Save => {}
            }
        } else {
            std::thread::sleep(Duration::from_millis(100));
        }
        if last_poll.elapsed() < Duration::from_millis(300) {
            continue;
        }
        last_poll = Instant::now();
        let batch = graph_session.take_raw()?;
        let Some(event) = batch.first()
        else {
            continue;
        };
        sample = serde_json::to_string_pretty(event)?;
        let Some(compiled) = &expressions else {
            continue;
        };
        let result = compiled.process(event).and_then(|decision| {
            if let Some((output, content)) = decision {
                let result = graph_session.forward_raw(event["event_id"].as_str().ok_or("Host event has no ID")?, &output, content)?;
                if result["status"] != "queued" {
                    return Err("Output was not queued; input retained".into());
                }
                graph_session.ack(event["event_id"].as_str().ok_or("Host event has no ID")?)?;
                Ok(format!("{} → {output}", event["event_id"]))
            } else {
                graph_session.ack_with_status(event["event_id"].as_str().ok_or("Host event has no ID")?, "skipped")?;
                Ok(format!(
                    "{} → skipped (outside time window or transform returned empty)",
                    event["event_id"]
                ))
            }
        });
        match result {
            Ok(message) => {
                status = message;
                if form.is_none() {
                    println!("{status}");
                }
                if args.once {
                    return Ok(());
                }
            }
            Err(error) => {
                status = format!(
                    "Failed · {error}\nInput retained. Fix the expression or wiring, then Ctrl+Enter to retry."
                );
                let _ = rpc(
                    "graph.progress",
                    json!({"event_id":event["event_id"],"message":status,"status":"failed","details":{"error":error.to_string(),"node":"filter"}}),
                );
                if form.is_none() {
                    return Err(error);
                }
                expressions = None;
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn settings(condition: &str, transform: &str) -> Settings {
        Settings {
            condition: condition.into(),
            transform: transform.into(),
            ..Settings::default()
        }
    }
    #[test]
    fn time_window_is_inclusive_exclusive_and_preserves_content() {
        let mut s = settings("", "");
        s.after = "2026-10-02T09:00:00+09:00".into();
        s.before = "2026-10-02T10:00:00+09:00".into();
        let expressions = s.compile().unwrap();
        let start = expressions.after.unwrap();
        let end = expressions.before.unwrap();
        let event = json!({"text":"continue", "payload":{"iteration":7}});
        assert!(expressions.process_at(&event, start - 1).unwrap().is_none());
        assert_eq!(
            expressions.process_at(&event, start).unwrap().unwrap(),
            ("matched", json!({}))
        );
        assert!(expressions.process_at(&event, end - 1).unwrap().is_some());
        assert!(expressions.process_at(&event, end).unwrap().is_none());
        s.before = s.after.clone();
        assert!(s.compile().is_err());
        s.before = "bad time".into();
        assert!(s.compile().is_err());
        let template = settings(
            "true",
            r#"if now < ("2000-01-01T00:00:00Z" | fromdateiso8601) then {} else empty end"#,
        );
        assert!(
            template
                .compile()
                .unwrap()
                .process(&event)
                .unwrap()
                .is_none()
        );
    }
    #[test]
    fn jq_routes_and_transforms_without_losing_payload() {
        let event = json!({"text":"an error", "payload":{"score":0.2}});
        let expressions = settings(
            "contains(\"error\")",
            "{text: (\"Fix: \" + .text), payload: .payload}",
        )
        .compile()
        .unwrap();
        let (output, content) = expressions.process(&event).unwrap().unwrap();
        assert_eq!(output, "matched");
        assert_eq!(content["text"], "Fix: an error");
        assert_eq!(content["payload"], event["payload"]);
        assert_eq!(
            settings("false", "")
                .compile()
                .unwrap()
                .process(&event)
                .unwrap()
                .unwrap(),
            ("unmatched", json!({}))
        );
    }
    #[test]
    fn jq_errors_are_not_false_and_empty_transform_is_skip() {
        let event = json!({"text":"test"});
        assert!(
            settings("contains(\"error\")", "")
                .compile()
                .unwrap()
                .process(&json!({"text":null}))
                .is_err()
        );
        for condition in ["error(\"bad input\")", "empty", "true,false", "42"] {
            assert!(
                settings(condition, "")
                    .compile()
                    .unwrap()
                    .process(&event)
                    .is_err()
            );
        }
        assert!(settings("(", "").compile().is_err());
        assert!(
            settings("true", "empty")
                .compile()
                .unwrap()
                .process(&event)
                .unwrap()
                .is_none()
        );
        assert!(
            settings("true", "{event_id: \"forged\"}")
                .compile()
                .unwrap()
                .process(&event)
                .is_err()
        );
    }
}
