//! Graph events become OSC 99; the terminal owns native delivery and emitter focus.
use crate::node_rpc as rpc;
use crate::node_form::{Action, Form};
use crate::{agent_bridge::Result, options::SystemNotification};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{IsTerminal, Write};
use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration},
};

static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}


fn content(event: &Value, title: &str) -> (String, String, String) {
    let source = event["origin"]["source"]
        .as_str()
        .or(event["source"].as_str())
        .unwrap_or("");
    let heading = event["payload"]["title"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or(title);
    let body = event["text"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or(event["payload"]["body"].as_str())
        .or(event["payload"]["message"].as_str())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            if event["payload"].is_null() {
                format!("New event from {}", crate::integration::pane_label(source))
            } else {
                event["payload"].to_string()
            }
        });
    (
        heading.chars().take(128).collect(),
        body.chars().take(2048).collect(),
        source.to_owned(),
    )
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
struct Settings {
    name: String,
    title: String,
    urgency: String,
    sound: String,
    occasion: String,
    focus: String,
    timeout: String,
    icon: String,
    buttons: String,
    replace_id: String,
    focus_target: String,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            name: "System Notification".into(),
            title: "Graffitty".into(),
            urgency: "normal".into(),
            sound: "system".into(),
            occasion: "always".into(),
            focus: "yes".into(),
            timeout: "3000".into(),
            icon: "".into(),
            buttons: "".into(),
            replace_id: "".into(),
            focus_target: "original_sender".into(),
        }
    }
}
impl Settings {
    fn fields(&self) -> Vec<(&'static str, String)> {
        vec![
            ("Name", self.name.clone()),
            ("Default title", self.title.clone()),
            ("Urgency", self.urgency.clone()),
            ("Sound", self.sound.clone()),
            ("When", self.occasion.clone()),
            ("Click fits pane", self.focus.clone()),
            (
                "Expiry ms · OS may hide banner sooner",
                self.timeout.clone(),
            ),
            ("Icon name", self.icon.clone()),
            ("Buttons · one per line", self.buttons.clone()),
            ("Replace ID · blank creates new", self.replace_id.clone()),
            ("Focus target", self.focus_target.clone()),
        ]
    }
    fn from_values(v: Vec<String>) -> Self {
        Self {
            name: v[0].clone(),
            title: v[1].clone(),
            urgency: v[2].clone(),
            sound: v[3].clone(),
            occasion: v[4].clone(),
            focus: v[5].clone(),
            timeout: v[6].clone(),
            icon: v[7].clone(),
            buttons: v[8].clone(),
            replace_id: v[9].clone(),
            focus_target: v[10].clone(),
        }
    }
    fn validate(&self) -> Result<()> {
        if !["original_sender", "previous_sender", "this_pane"]
            .contains(&self.focus_target.as_str())
        {
            return Err("Choose original_sender, previous_sender, or this_pane".into());
        }
        if self.name.trim().is_empty() || self.title.trim().is_empty() {
            return Err("Name and default title are required".into());
        }
        if !["low", "normal", "critical"].contains(&self.urgency.as_str()) {
            return Err("Urgency must be low, normal, or critical".into());
        }
        if !["always", "unfocused", "invisible"].contains(&self.occasion.as_str()) {
            return Err("When must be always, unfocused, or invisible".into());
        }
        if !["yes", "no"].contains(&self.focus.as_str()) {
            return Err("Click fits pane must be yes or no".into());
        }
        if self.timeout.parse::<i64>().map_or(true, |n| n < -1) {
            return Err("Expiry must be -1, 0, or positive milliseconds".into());
        }
        if self.replace_id.len() > 256
            || !self
                .replace_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"_+.-".contains(&b))
        {
            return Err("Replace ID accepts letters, digits, _ + . - (up to 256 bytes)".into());
        }
        if self.buttons.lines().count() > 16 {
            return Err("At most 16 buttons are supported".into());
        }
        if self.sound.len() > 256 || self.icon.len() > 256 {
            return Err("Sound and icon names must be at most 256 bytes".into());
        }
        Ok(())
    }
}
fn register(graph_session: &crate::NodeSession, s: &Settings) -> Result<()> {
    graph_session.register_raw(json!({"name":s.name,"icon":"🔔",
        "inputs":[{"id":"notify","name":"Notify","color":"#ffd47a"}],"outputs":[]}),
    )
}
fn log(history: &mut std::collections::VecDeque<String>, message: String, interactive: bool) {
    let message: String = message
        .chars()
        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
        .collect();
    let line = format!(
        "[{}] {message}",
        jiff::Zoned::now().strftime("%Y-%m-%d %H:%M:%S %:z")
    );
    if !interactive {
        eprintln!("{line}");
    }
    history.push_back(line);
    while history.len() > 100 {
        history.pop_front();
    }
}
pub fn run(args: SystemNotification) -> Result<()> {
    let interactive =
        !args.headless && std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    if args.edit && !interactive {
        return Err("--edit requires an interactive terminal".into());
    }
    let mut value = crate::node_config::load(
        serde_json::to_value(Settings::default())?,
        args.config.as_deref(),
    )?;
    if let Some(name) = args.name {
        value["name"] = json!(name);
    }
    if let Some(title) = args.title {
        value["title"] = json!(title);
    }
    let mut settings: Settings = serde_json::from_value(value)?;
    settings.validate()?;
    let mut form = if interactive {
        Some(Form::settings(
            "System Notification · Ctrl+Enter apply · editing pauses · Ctrl+S save · Ctrl+C exit",
            settings.fields(),
            vec![
                (2, vec!["low", "normal", "critical"]),
                (
                    3,
                    vec!["system", "silent", "error", "warning", "info", "question"],
                ),
                (4, vec!["always", "unfocused", "invisible"]),
                (5, vec!["yes", "no"]),
                (10, vec!["original_sender", "previous_sender", "this_pane"]),
            ],
            vec![
                (vec![0, 1], 3),
                (vec![2, 3], 3),
                (vec![4, 5], 3),
                (vec![6, 7], 3),
                (vec![8, 9], 4),
                (vec![10], 3),
            ],
        )?)
    } else {
        None
    };
    let mut graph_session = crate::node_session(true)?;
    register(&graph_session, &settings)?;
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
    }
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let mut paused = args.edit;
    let mut history = std::collections::VecDeque::new();
    let mut status = if paused { "Paused · Ctrl+Enter to apply." } else { "Listening · connect an output to Notify. Sent means OSC 99 written; OS delivery follows terminal settings." }.to_owned();
    while !STOP.load(Ordering::Relaxed) {
        graph_session.heartbeat()?;
        if let Some(form) = &mut form {
            form.set_log(&history.iter().cloned().collect::<Vec<_>>().join("\n\n"));
            form.set_running(!paused);
            match form.tick(&status, "")? {
                Action::Quit => break,
                Action::Pause => {
                    paused = true;
                    status = "Paused · Start resumes notifications. Queued input is retained.".into();
                }
                Action::Edit => {
                    paused = true;
                    status = "Paused · Ctrl+Enter to apply.".into();
                }
                Action::Apply => {
                    let next = Settings::from_values(form.values());
                    match next.validate().and_then(|()| register(&graph_session, &next).map(|_| ())) {
                        Ok(()) => {
                            settings = next;
                            paused = false;
                            status = "Listening · changes applied.".into();
                        }
                        Err(e) => {
                            paused = true;
                            status = format!("Paused · {e}");
                            log(&mut history, format!("ERROR {e}"), interactive);
                        }
                    }
                }
                Action::Save => {
                    let next = Settings::from_values(form.values());
                    let path = args
                        .config
                        .clone()
                        .or_else(|| std::env::var("GRAFFITTY_NODE_CONFIG").ok());
                    let result = next.validate().and_then(|()| {
                        let path = path.ok_or("Use --config <path> to select a settings file")?;
                        std::fs::write(&path, serde_json::to_string_pretty(&next)? + "\n")?;
                        Ok(path)
                    });
                    status = match result {
                        Ok(path) => format!("Saved {path}. Ctrl+Enter to apply."),
                        Err(e) => format!("Save failed: {e}"),
                    };
                }
                _ => {}
            }
        } else {
            std::thread::sleep(Duration::from_millis(100));
        }
        if paused {
            continue;
        }
        let batch = graph_session.take_raw()?;
        for event in &batch {
            let id = event["event_id"].as_str().ok_or("Missing event ID")?;
            let (title, body, _) = content(event, &settings.title);
            let notification_id = if settings.replace_id.is_empty() {
                uuid::Uuid::new_v4().to_string()
            } else {
                settings.replace_id.clone()
            };
            rpc(
                "notification.bind",
                json!({"notification_id":notification_id,"event_id":id,"focus_target":settings.focus_target}),
            )?;
            let packet = osc99(&title, &body, &settings, &notification_id);
            let sent = (|| -> std::io::Result<()> {
                let mut stdout = std::io::stdout().lock();
                stdout.write_all(packet.as_bytes())?;
                stdout.flush()
            })();
            if let Err(e) = sent {
                log(
                    &mut history,
                    format!("ERROR sending {title}: {e}"),
                    interactive,
                );
                return Err(e.into());
            }
            log(
                &mut history,
                format!(
                    "Sent · {title}\nFrom {} via {}\n{body}",
                    crate::integration::pane_label(event["origin"]["source"]
                        .as_str()
                        .or(event["source"].as_str())
                        .unwrap_or("unknown")),
                    crate::integration::pane_label(event["source"].as_str().unwrap_or("unknown"))
                ),
                interactive,
            );
            graph_session.ack(&id)?;
            if args.once {
                return Ok(());
            }
        }
    }
    Ok(())
}
fn osc99(title: &str, body: &str, settings: &Settings, id: &str) -> String {
    let urgency = match settings.urgency.as_str() {
        "low" => 0,
        "critical" => 2,
        _ => 1,
    };
    let meta = format!(
        "i={id}:a={}:u={urgency}:s={}:o={}:w={}:f={}:n={}",
        if settings.focus == "yes" {
            "focus"
        } else {
            "-focus"
        },
        STANDARD.encode(&settings.sound),
        settings.occasion,
        settings.timeout,
        STANDARD.encode("Graffitty"),
        STANDARD.encode(&settings.icon)
    );
    let mut out = String::new();
    for (kind, text) in [
        ("title", title.to_owned()),
        ("body", body.to_owned()),
        (
            "buttons",
            settings
                .buttons
                .lines()
                .collect::<Vec<_>>()
                .join("\u{2028}"),
        ),
    ] {
        for chunk in text.as_bytes().chunks(1536) {
            out.push_str(&format!(
                "\x1b]99;{meta}:p={kind}:e=1:d=0;{}\x1b\\",
                STANDARD.encode(chunk)
            ));
        }
    }
    out.push_str(&format!("\x1b]99;i={id}:d=1;\x1b\\"));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn osc99_chunks_are_safe_and_round_trip_unicode() {
        let title = "Ready";
        let body = "한\x07\x1b[31m\n".repeat(700);
        let packet = osc99(title, &body, &Settings::default(), "test");
        let mut decoded = Vec::new();
        for chunk in packet.split("\x1b]99;").skip(1) {
            let chunk = chunk.strip_suffix("\x1b\\").unwrap();
            let (meta, data) = chunk.split_once(';').unwrap();
            assert!(data.len() <= 2048);
            assert!(!data.chars().any(char::is_control));
            if meta.contains("p=body") {
                decoded.extend(STANDARD.decode(data).unwrap());
            }
        }
        assert_eq!(String::from_utf8(decoded).unwrap(), body);
    }
    #[test]
    fn settings_reject_metadata_injection_and_invalid_expiry() {
        let mut s = Settings::default();
        s.replace_id = "x:a=report".into();
        assert!(s.validate().is_err());
        s.replace_id.clear();
        s.timeout = "-2".into();
        assert!(s.validate().is_err());
    }
    #[test]
    fn original_source_survives_forwarding_and_unicode_is_bounded() {
        let event = json!({"source":"%2","origin":{"source":"%1"},
            "text":"한".repeat(3000),"payload":{"title":"Done"}});
        let (title, body, source) = content(&event, "Graffitty");
        assert_eq!(title, "Done");
        assert_eq!(source, "%1");
        assert_eq!(body.chars().count(), 2048);
    }
    #[test]
    fn body_fallbacks_do_not_open_session_files() {
        assert_eq!(
            content(
                &json!({"source":"%1","payload":{"body":"Ready"}}),
                "G"
            )
            .1,
            "Ready"
        );
        assert_eq!(
            content(
                &json!({"source":"%1","sessions":[{"path":"/private"}]}),
                "G"
            )
            .1,
            "New event from pane %1"
        );
    }
}
