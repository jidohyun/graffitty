//! Editable Decisions API router. Credentials come from the environment or a host credential source.
use crate::node_rpc as rpc;
mod mock;
use crate::{
    agent_bridge::Result,
    node_form::{Action, Form},
    options::Systemone,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    io::{IsTerminal, Read, Write},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

const ENDPOINT: &str = "https://openrouter.ai/api/alpha/decisions";
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Output {
    id: String,
    description: String,
    #[serde(default)]
    name: String,
    #[serde(default = "color")]
    color: String,
    #[serde(default = "icon")]
    icon: Value,
}
fn color() -> String {
    "#89ddbd".into()
}
fn icon() -> Value {
    json!("⚖")
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    #[serde(skip_serializing_if = "Option::is_none")]
    credential: Option<String>,
    provider: String,
    model: String,
    name: String,
    icon: Value,
    question: String,
    mode: String,
    outputs: Vec<Output>,
    threshold: f64,
    endpoint: String,
    input: String,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            credential: None,
            provider: "openrouter".into(),
            model: "~typesafe/jev-latest".into(),
            name: "SystemOne".into(),
            icon: icon(),
            question: String::new(),
            mode: "noul".into(),
            outputs: serde_json::from_value(json!([
                {"id":"True","description":"Yes","color":"#89ddbd"},
                {"id":"False","description":"No","color":"#ff8585"}
            ]))
            .unwrap(),
            threshold: 0.5,
            endpoint: String::new(),
            input: ".".into(),
        }
    }
}
impl Settings {
    fn validate_ports(&self) -> Result<()> {
        if self.name.chars().count() > 128 {
            return Err("Name must be at most 128 characters".into());
        }
        validate_icon(&self.icon)?;
        if self.outputs.is_empty() || self.outputs.len() > 32 {
            return Err("Configure 1–32 outputs".into());
        }
        let mut seen = HashSet::new();
        for output in &self.outputs {
            if output.id.is_empty()
                || output.id.len() > 64
                || !output
                    .id
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
                || !seen.insert(&output.id)
            {
                return Err(
                    "Output IDs must be unique, with 1–64 letters, digits, underscores or hyphens"
                        .into(),
                );
            }
            if output.description.trim().is_empty() {
                return Err("Each output needs a description".into());
            }
            if output.name.chars().count() > 128 {
                return Err("Output names must be at most 128 characters".into());
            }
            if output.color.len() != 7
                || !output.color.starts_with('#')
                || !output.color[1..].bytes().all(|c| c.is_ascii_hexdigit())
            {
                return Err("Output colors must be #RRGGBB".into());
            }
            validate_icon(&output.icon)?;
        }
        Ok(())
    }
    fn validate(&self) -> Result<()> {
        self.validate_ports()?;
        if self.question.trim().is_empty() {
            return Err("Enter a question, then Ctrl+Enter to apply".into());
        }
        if self.model.trim().is_empty() {
            return Err("Model is required".into());
        }
        if !self.threshold.is_finite() || !(0.0..=1.0).contains(&self.threshold) {
            return Err("Threshold must be between 0 and 1".into());
        }
        match self.mode.as_str() {
            "noul" if self.outputs.len() == 2 => {}
            "choice" => {}
            "score" if (2..=10).contains(&self.outputs.len()) => {}
            "noul" => return Err("noul needs two outputs, ordered Yes then No".into()),
            "score" => return Err("score needs 2–10 outputs, ordered lowest to highest".into()),
            _ => return Err("Mode must be noul, choice, or score (F2 to pick)".into()),
        }
        self.url()?;
        crate::filter_node::compile(&self.input, "Input")?;
        Ok(())
    }
    fn url(&self) -> Result<String> {
        let endpoint = match self.provider.as_str() {
            "openrouter" if self.endpoint.trim().is_empty() => ENDPOINT,
            "openrouter" | "custom" => self.endpoint.trim(),
            _ => return Err("Provider must be openrouter or custom (Decisions-compatible)".into()),
        };
        let url =
            reqwest::Url::parse(endpoint).map_err(|_| "Enter a valid Decisions endpoint URL")?;
        if !matches!(url.scheme(), "http" | "https")
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
        {
            return Err("Endpoint must be HTTP(S), without credentials, query, or fragment".into());
        }
        Ok(url.to_string())
    }
    fn key(&self) -> Result<String> {
        crate::secrets::lookup("OPENROUTER_API_KEY", self.credential.as_deref())?
            .ok_or_else(|| "Set OPENROUTER_API_KEY or select a credential in secrets.toml; keys are never entered in the UI".into())
    }

    fn manifest(&self) -> Value {
        // The model selects a destination; the node then emits to it
        // directly. Unlike an agent's optional Send tool call, routing needs
        // no later decision to remember to send.
        //
        // All choices therefore use solid wires. This shared manifest also
        // keeps the mock and remote clients aligned.
        let outputs: Vec<_> = self.outputs.iter().map(|o| json!({"id":o.id,"name":if o.name.is_empty() { &o.id } else { &o.name },"color":o.color,"icon":o.icon,"line_style":"solid"})).collect();
        json!({"name":self.name,"icon":self.icon,"inputs":[{"id":"evaluate","name":"Evaluate","color":"#8ecaff"}],"outputs":outputs})
    }
    fn request(&self, event: &Value) -> Result<Value> {
        let program = crate::filter_node::compile(&self.input, "Input")?;
        let state = crate::filter_node::evaluate(&program, event, "Input", false)?
            .ok_or("Input is empty")?;
        if state.is_null() {
            return Err("Input selected null or a missing field".into());
        }
        let mut question = json!({"type":self.mode,"instructions":self.question});
        question["criteria"] = match self.mode.as_str() {
            "noul" => {
                json!({"true":self.outputs[0].description,"false":self.outputs[1].description})
            }
            "choice" => Value::Object(
                self.outputs
                    .iter()
                    .map(|o| (o.id.clone(), json!(o.description)))
                    .collect(),
            ),
            "score" => json!(
                self.outputs
                    .iter()
                    .map(|o| &o.description)
                    .collect::<Vec<_>>()
            ),
            _ => return Err("Unknown mode".into()),
        };
        let request = json!({"model":self.model,"state":state,"questions":{"route":question}});
        if serde_json::to_vec(&request)?.len() > 120_000 {
            return Err("Decision request exceeds 120 KB; narrow Input with jq".into());
        }
        Ok(request)
    }
    fn route(&self, response: &Value) -> Result<String> {
        let answer = &response["answers"]["route"];
        if answer["type"] != self.mode {
            return Err("Decision response type does not match the selected mode".into());
        }
        let index = match self.mode.as_str() {
            "choice" => self
                .outputs
                .iter()
                .position(|o| answer["choice"] == o.id)
                .ok_or("Decision selected an unknown output")?,
            "noul" => {
                let value = answer["noul"]
                    .as_f64()
                    .filter(|v| v.is_finite() && (0.0..=1.0).contains(v))
                    .ok_or("Invalid noul probability")?;
                if value >= self.threshold { 0 } else { 1 }
            }
            "score" => {
                let value = answer["score"]
                    .as_f64()
                    .filter(|v| v.is_finite() && *v >= 0.0 && *v <= (self.outputs.len() - 1) as f64)
                    .ok_or("Score is outside the configured rubric")?;
                value.round() as usize
            }
            _ => return Err("Unknown mode".into()),
        };
        Ok(self.outputs[index].id.clone())
    }
    fn fields(&self) -> Result<Vec<(&'static str, String)>> {
        Ok(vec![
            ("Provider · F2", self.provider.clone()),
            ("Model", self.model.clone()),
            ("Question", self.question.clone()),
            (
                "Mode · F2",
                self.mode.clone(),
            ),
            (
                "Outputs · JSON: id, description, name, color",
                serde_json::to_string_pretty(&self.outputs.iter().map(|output| json!({"id":output.id,"description":output.description,"name":output.name,"color":output.color})).collect::<Vec<_>>())?,
            ),
            (
                "Threshold · 0–1",
                self.threshold.to_string(),
            ),
            ("Name", self.name.clone()),
            (
                "Input · jq on incoming event",
                self.input.clone(),
            ),
            ("Endpoint · blank: OpenRouter", self.endpoint.clone()),
        ])
    }
    fn from_values(values: &[String], credential: Option<String>) -> Result<Self> {
        Ok(Self {
            credential,
            provider: values[0].trim().into(),
            model: values[1].trim().into(),
            question: values[2].clone(),
            mode: values[3].trim().into(),
            outputs: serde_json::from_str(&values[4])
                .map_err(|_| "Outputs must be a JSON array of objects with id and description")?,
            threshold: values[5]
                .trim()
                .parse()
                .map_err(|_| "Threshold must be a number")?,
            name: values[6].clone(),
            icon: icon(),
            input: values[7].clone(),
            endpoint: values[8].trim().into(),
        })
    }
}
fn validate_icon(value: &Value) -> Result<()> {
    let valid = if let Some(text) = value.as_str() {
        text.chars().count() <= 32
    } else if let Some(svg) = value.get("svg") {
        svg.as_str()
            .is_some_and(|s| s.chars().count() <= 16384 && s.contains("<svg"))
    } else {
        value.as_object().is_some_and(|o| {
            o.keys().all(|k| ["text", "font"].contains(&k.as_str()))
                && o.get("text")
                    .is_some_and(|t| t.as_str().is_some_and(|t| t.chars().count() <= 32))
                && o.get("font")
                    .is_none_or(|f| f.as_str().is_some_and(|f| f.chars().count() <= 128))
        })
    };
    if valid {
        Ok(())
    } else {
        Err("Icon must be text (up to 32 characters), a text/font object, or inline SVG (up to 16384 characters)".into())
    }
}

fn decide(settings: &Settings, request: Value, key: String) -> Result<(String, Value)> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(45))
        .redirect(reqwest::redirect::Policy::none())
        .build()?;
    let response = client
        .post(settings.url()?)
        .bearer_auth(&key)
        .json(&request)
        .send()
        .map_err(|_| "Decision request failed or timed out")?;
    if !response.status().is_success() {
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        let _ = response.take(16_384).read_to_end(&mut bytes);
        return Err(decision_error(status, &bytes, &key).into());
    }
    let mut bytes = Vec::new();
    response
        .take(1_048_577)
        .read_to_end(&mut bytes)
        .map_err(|_| "Could not read decision response")?;
    if bytes.len() > 1_048_576 {
        return Err("Decision response exceeds 1 MiB".into());
    }
    let response: Value =
        serde_json::from_slice(&bytes).map_err(|_| "Invalid decision response JSON")?;
    Ok((
        settings.route(&response)?,
        response["answers"]["route"].clone(),
    ))
}
fn decision_error(status: u16, bytes: &[u8], key: &str) -> String {
    // Never dump response metadata, headers, or HTML into the terminal. Keep
    // only the provider's message, remove control characters and redact auth.
    let body: Value = serde_json::from_slice(bytes).unwrap_or(Value::Null);
    let message = body
        .pointer("/error/message")
        .and_then(Value::as_str)
        .unwrap_or("");
    let message = if key.is_empty() {
        message.to_owned()
    } else {
        message.replace(key, "[redacted]")
    };
    let message: String = message
        .chars()
        .filter(|c| !c.is_control())
        .take(400)
        .collect();
    if message.is_empty() {
        format!("Decision HTTP {status}")
    } else {
        format!("Decision HTTP {status}: {message}")
    }
}
fn save(settings: &Settings, path: Option<&str>) -> Result<()> {
    use crate::platform::OpenOptionsExt;
    let path =
        std::path::Path::new(path.ok_or("Use --config PATH or GRAFFITTY_NODE_CONFIG to save")?);
    let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(serde_json::to_string_pretty(settings)?.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(temp);
    }
    result
}
fn log(entries: &mut Vec<String>, interactive: bool, message: &str) {
    let entry = format!(
        "{} · {message}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
    );
    if !interactive {
        eprintln!("{entry}");
    }
    entries.push(entry);
    if entries.len() > 200 {
        entries.remove(0);
    }
}
type DecisionResult = std::result::Result<(String, Value), String>;

pub fn run(args: Systemone) -> Result<()> {
    run_with(args, None)
}

pub fn run_mock(args: crate::options::SystemoneMock) -> Result<()> {
    run_with(args.node, Some(mock::Scenario::load(args.scenario.as_deref())?))
}

// Only the decision service changes. Both entry points use this form, validation,
// manifest, queue, revision checks, delivery, acknowledgement, and lifecycle.
fn run_with(args: Systemone, mut mock: Option<mock::Scenario>) -> Result<()> {
    if args.edit && args.headless {
        return Err("Choose either --edit or --headless".into());
    }
    let path = args
        .config
        .or_else(|| std::env::var("GRAFFITTY_NODE_CONFIG").ok());
    // Keep absence distinct from the displayed default: an unspecified provider opens setup.
    let mut config = crate::node_config::load(json!({}), path.as_deref())?;
    let provider_supplied = args.provider.is_some()
        || config
            .get("provider")
            .and_then(Value::as_str)
            .is_some_and(|p| !p.trim().is_empty());
    for (key, value) in [
        ("credential", args.credential),
        ("provider", args.provider),
        ("model", args.model),
        ("name", args.name),
        ("question", args.question),
        ("mode", args.mode),
        ("endpoint", args.endpoint),
    ] {
        if let Some(value) = value {
            config[key] = json!(value);
        }
    }
    if !provider_supplied {
        config["provider"] = json!("openrouter");
    }
    if let Some(outputs) = args.outputs {
        config["outputs"] = serde_json::from_str(&outputs)?;
    }
    if let Some(threshold) = args.threshold {
        config["threshold"] = json!(threshold);
    }
    let mut defaults = serde_json::to_value(Settings::default())?;
    crate::node_config::merge(&mut defaults, config)?;
    let mut settings: Settings = serde_json::from_value(defaults)?;
    let interactive =
        !args.headless && std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    if args.edit && !interactive {
        return Err("--edit requires an interactive terminal".into());
    }
    let validation = settings
        .validate()
        .and_then(|_| credential(&settings, mock.is_some()).map(|_| ()));
    if !interactive {
        if let Err(error) = validation {
            return Err(error);
        }
    }
    let mut active = !args.edit
        && (!interactive || provider_supplied)
        && settings
            .validate()
            .and_then(|_| credential(&settings, mock.is_some()).map(|_| ()))
            .is_ok();
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let mut graph_session = crate::node_session(true)?;
    if settings.validate_ports().is_ok() {
        graph_session.register_raw(settings.manifest())?;
    } else {
        graph_session.register_raw(json!({"name":"SystemOne setup","inputs":[{"id":"evaluate","name":"Evaluate"}],"outputs":[]}),
        )?;
    }
    let mut form = if interactive {
        Some(Form::settings(
            "SystemOne",
            settings.fields()?,
            vec![
                (0, vec!["openrouter", "custom"]),
                (3, vec!["noul", "choice", "score"]),
            ],
            vec![
                (vec![0, 1], 3),    // provider / model
                (vec![6, 3, 5], 3), // name / mode / threshold
                (vec![2], 5),       // question
                (vec![4], 7),       // outputs
                (vec![7], 3),       // input
                (vec![8], 3),       // endpoint
            ],
        )?)
    } else {
        None
    };
    let mut status = if active { "Running · waiting for events." } else { "Setup paused · choose provider, question, mode and outputs. Ctrl+Enter applies settings and updates graph ports." }.to_owned();
    let mut entries = Vec::new();
    if mock.is_some() {
        log(&mut entries, interactive, "Scripted decisions · no model API calls or credentials.");
    }
    log(&mut entries, interactive, &status);
    let mut poll = Instant::now() - Duration::from_secs(1);
    let mut revision = 0_u64;
    let mut worker: Option<(String, u64, mpsc::Receiver<DecisionResult>)> = None;
    let mut forwarded = HashSet::new();
    while !STOP.load(Ordering::Relaxed) {
        graph_session.heartbeat()?;
        if let Some(form) = &mut form {
            form.set_log(&entries.join("\n"));
            form.set_running(active);
            match form.tick(&status, "")? {
                Action::Quit => break,
                Action::Pause => {
                    active = false;
                    revision += 1;
                    status = "Paused · Start resumes processing. Input is retained.".into();
                }
                Action::Edit => {
                    active = false;
                    revision += 1;
                    status =
                        "Paused · Ctrl+Enter validates settings, updates ports and resumes.".into();
                }
                action @ (Action::Apply | Action::Save) => {
                    let result = (|| -> Result<()> {
                        let candidate = Settings::from_values(&form.values(), settings.credential.clone())?;
                        candidate.validate()?;
                        if matches!(action, Action::Save) {
                            save(&candidate, path.as_deref())?;
                            status = "Settings saved (no credentials). Ctrl+Enter to apply.".into();
                        } else {
                            credential(&candidate, mock.is_some())?;
                            graph_session.register_raw(candidate.manifest())?;
                            settings = candidate;
                            revision += 1;
                            active = true;
                            status = "Running · settings applied and graph ports updated.".into();
                        }
                        Ok(())
                    })();
                    if let Err(error) = result {
                        active = false;
                        revision += 1;
                        status = error.to_string();
                    }
                    log(&mut entries, interactive, &status);
                }
                _ => {}
            }
        } else {
            std::thread::sleep(Duration::from_millis(50));
        }
        if let Some((id, generation, receiver)) = &worker {
            let received = match receiver.try_recv() {
                Ok(result) => Some(result),
                Err(mpsc::TryRecvError::Disconnected) => {
                    Some(Err("Decision worker stopped".into()))
                }
                Err(mpsc::TryRecvError::Empty) => None,
            };
            if let Some(result) = received {
                let id = id.clone();
                let stale = *generation != revision || !active;
                worker = None;
                if stale {
                    log(
                        &mut entries,
                        interactive,
                        "Discarded decision from previous settings; input retained.",
                    );
                    continue;
                }
                let delivered = (|| -> Result<()> {
                    let (output, answer) =
                        result.map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;
                    let response = graph_session.forward_raw(&id, &output, json!({}))?;
                    if response["status"] != "queued" {
                        return Err("Output was not queued; input retained".into());
                    }
                    forwarded.insert(id.clone());
                    graph_session.ack(&id)?;
                    forwarded.remove(&id);
                    status = format!("{id} → {output} · {answer}");
                    Ok(())
                })();
                if let Err(error) = delivered {
                    active = false;
                    status = format!("Failed · {error}. Input retained; Ctrl+Enter retries.");
                    let _ = rpc(
                        "graph.progress",
                        json!({"event_id":id,"status":"failed","message":status}),
                    );
                    log(&mut entries, interactive, &status);
                    if !interactive {
                        return Err(error);
                    }
                } else {
                    log(&mut entries, interactive, &status);
                    if args.once {
                        break;
                    }
                }
            }
        }
        if !active || worker.is_some() || poll.elapsed() < Duration::from_millis(300) {
            continue;
        }
        poll = Instant::now();
        let batch = graph_session.take_raw()?;
        let Some(event) = batch.first() else {
            continue;
        };
        let id = event["event_id"]
            .as_str()
            .ok_or("Host event has no ID")?
            .to_owned();
        if forwarded.contains(&id) {
            graph_session.ack(&id)?;
            forwarded.remove(&id);
            if args.once {
                break;
            }
            continue;
        }
        let prepared = settings
            .request(event)
            .and_then(|request| {
                let key = credential(&settings, mock.is_some())?;
                let scripted = mock.as_mut().map(|scenario| scenario.select(&settings, &request)).transpose()?;
                Ok((request, key, scripted))
            });
        let (request, key, scripted) = match prepared {
            Ok(value) => value,
            Err(error) => {
                active = false;
                status = format!("Failed · {error}. Input retained; Ctrl+Enter retries.");
                log(&mut entries, interactive, &status);
                let _ = rpc(
                    "graph.progress",
                    json!({"event_id":id,"status":"failed","message":status}),
                );
                if !interactive {
                    return Err(error);
                }
                continue;
            }
        };
        status = format!(
            "Evaluating {id} · {} / {} / {}",
            settings.provider, settings.model, settings.mode
        );
        log(&mut entries, interactive, &status);
        rpc(
            "graph.progress",
            json!({"event_id":id,"status":"pending","message":status}),
        )?;
        let snapshot = settings.clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let result = match scripted {
                Some(decision) => decision.run(&snapshot),
                None => decide(&snapshot, request, key.expect("Live decisions require a key")),
            }.map_err(|e| e.to_string());
            let _ = tx.send(result);
        });
        worker = Some((id, revision, rx));
    }
    drop(form);
    if interactive {
        for entry in entries {
            eprintln!("{entry}");
        }
    }
    Ok(())
}

fn credential(settings: &Settings, scripted: bool) -> Result<Option<String>> {
    if scripted { Ok(None) } else { settings.key().map(Some) }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn http_errors_explain_rejections_without_dumping_credentials_or_metadata() {
        let body = json!({"error":{"message":"Unknown model\n secret-key", "metadata":{"authorization":"secret-key"}}});
        assert_eq!(
            decision_error(400, &serde_json::to_vec(&body).unwrap(), "secret-key"),
            "Decision HTTP 400: Unknown model [redacted]"
        );
        assert_eq!(
            decision_error(502, b"<html>Bad gateway</html>", "key"),
            "Decision HTTP 502"
        );
        assert!(
            decision_error(
                400,
                &serde_json::to_vec(&json!({"error":{"message":"x".repeat(500)}})).unwrap(),
                "key"
            )
            .len()
                < 430
        );
    }
    fn settings(mode: &str) -> Settings {
        Settings {
            question: "Route this event".into(),
            mode: mode.into(),
            ..Settings::default()
        }
    }
    #[test]
    fn all_modes_build_criteria_and_route_strict_answers() {
        let mut s = settings("noul");
        s.validate().unwrap();
        let event = json!({"text":"test","payload":{"custom":[1,2]}});
        assert_eq!(s.request(&event).unwrap()["state"], event);
        assert_eq!(
            s.request(&event).unwrap()["questions"]["route"]["criteria"],
            json!({"true":"Yes","false":"No"})
        );
        for (p, output) in [
            (0.0, "False"),
            (0.499, "False"),
            (0.5, "True"),
            (1.0, "True"),
        ] {
            assert_eq!(
                s.route(&json!({"answers":{"route":{"type":"noul","noul":p}}}))
                    .unwrap(),
                output
            );
        }
        for answer in [
            json!({"type":"noul","noul":1.1}),
            json!({"type":"noul","noul":"0.8"}),
            json!({"type":"choice","choice":"True"}),
            json!({}),
        ] {
            assert!(s.route(&json!({"answers":{"route":answer}})).is_err());
        }
        s.mode = "choice".into();
        assert_eq!(
            s.request(&event).unwrap()["questions"]["route"]["criteria"]["True"],
            "Yes"
        );
        assert_eq!(
            s.route(&json!({"answers":{"route":{"type":"choice","choice":"False"}}}))
                .unwrap(),
            "False"
        );
        assert!(
            s.route(&json!({"answers":{"route":{"type":"choice","choice":"unknown"}}}))
                .is_err()
        );
        s.mode = "score".into();
        assert_eq!(
            s.request(&event).unwrap()["questions"]["route"]["criteria"],
            json!(["Yes", "No"])
        );
        assert_eq!(
            s.route(&json!({"answers":{"route":{"type":"score","score":0.5}}}))
                .unwrap(),
            "False"
        );
        assert!(
            s.route(&json!({"answers":{"route":{"type":"score","score":-0.1}}}))
                .is_err()
        );
        s.input = ".payload".into();
        assert_eq!(s.request(&event).unwrap()["state"], event["payload"]);
        s.input = ".missing".into();
        assert!(s.request(&event).is_err());
    }
    #[test]
    fn form_roundtrip_and_stable_ports() {
        let mut s = settings("choice");
        s.credential = Some("work".into());
        let values: Vec<_> = s
            .fields()
            .unwrap()
            .into_iter()
            .map(|(_, value)| value)
            .collect();
        let roundtrip = Settings::from_values(&values, Some("work".into())).unwrap();
        assert_eq!(roundtrip.credential.as_deref(), Some("work"));
        assert_eq!(
            serde_json::to_value(&s).unwrap(),
            serde_json::to_value(roundtrip).unwrap()
        );
        let old = s.manifest();
        assert!(
            old["outputs"]
                .as_array()
                .unwrap()
                .iter()
                .all(|port| port["line_style"] == "solid")
        );
        s.outputs[0].name = "Approved".into();
        s.outputs[0].color = "#aabbcc".into();
        s.validate().unwrap();
        assert_eq!(s.manifest()["outputs"][0]["id"], old["outputs"][0]["id"]);
        assert_eq!(s.manifest()["outputs"][0]["line_style"], "solid");
        s.outputs[1].id = s.outputs[0].id.clone();
        assert!(s.validate().is_err());
    }
    #[test]
    fn rejects_invalid_config_and_never_serializes_keys() {
        let mut s = settings("noul");
        s.threshold = f64::NAN;
        assert!(s.validate().is_err());
        s.threshold = 0.5;
        s.outputs.pop();
        assert!(s.validate().is_err());
        s.mode = "score".into();
        assert!(s.validate().is_err());
        s = settings("choice");
        s.provider = "custom".into();
        assert!(s.validate().is_err());
        s.endpoint = "http://localhost:1234/decisions".into();
        s.validate().unwrap();
        s.endpoint = "https://user:secret@example.com/decisions".into();
        assert!(s.validate().is_err());
        let mut value = serde_json::to_value(settings("choice")).unwrap();
        value["api_key"] = json!("must not be accepted");
        assert!(serde_json::from_value::<Settings>(value).is_err());
        let path = std::env::temp_dir().join(format!("systemone-{}.json", uuid::Uuid::new_v4()));
        save(&settings("choice"), path.to_str()).unwrap();
        let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert!(saved.get("api_key").is_none());
        assert!(saved.get("api_key_env").is_none());
        std::fs::remove_file(path).unwrap();
    }
}
