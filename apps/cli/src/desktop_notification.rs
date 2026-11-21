//! One native notification per helper, with explicit close/expiry and action results.
use crate::agent_bridge::Result;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    io::{BufRead, Write},
    sync::mpsc,
    time::{Duration, Instant},
};

#[derive(Deserialize, Default)]
#[serde(default)]
pub(super) struct Request {
    pub title: String,
    pub body: String,
    pub native_id: String,
    pub buttons: Vec<String>,
    pub sound: String,
    pub urgency: u8,
    pub timeout: i64,
    pub icon_path: String,
    pub icon_names: Vec<String>,
    pub app_name: String,
    pub types: Vec<String>,
}

fn xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

pub fn run() -> Result<()> {
    let response = deliver().unwrap_or_else(|e| json!({"error":e.to_string()}));
    writeln!(std::io::stdout().lock(), "{response}")?;
    Ok(())
}
/// Explicit native frontend request. Offscreen replay never launches this mode.
pub fn bell() -> Result<()> {
    #[cfg(target_os="macos")] {
        #[link(name="AppKit",kind="framework")]
        unsafe extern "C" {fn NSBeep();}
        unsafe {NSBeep();}
    }
    #[cfg(windows)] unsafe {
        windows_sys::Win32::System::Diagnostics::Debug::MessageBeep(0);
    }
    #[cfg(all(unix,not(target_os="macos")))] {
        let status=std::process::Command::new("canberra-gtk-play").args(["--id=bell","--description=Graffitty terminal bell"]).status()?;
        if !status.success(){return Err("System bell playback failed".into());}
    }
    Ok(())
}
fn deliver() -> Result<Value> {
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    if line.len() > 1024 * 1024 {
        return Err("Notification request too large".into());
    }
    let request: Request = serde_json::from_str(&line)?;
    if request.title.is_empty() {
        return Err("Notification title is empty".into());
    }
    let (close_tx, close_rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if serde_json::from_str::<Value>(&line).is_ok_and(|v| v["close"] == true) {
                break;
            }
        }
        let _ = close_tx.send(());
    });
    platform::deliver(request, close_rx)
}
fn should_close(close: &mpsc::Receiver<()>, start: Instant, timeout: i64) -> bool {
    close.try_recv().is_ok() || (timeout > 0 && start.elapsed().as_millis() >= timeout as u128)
}

#[cfg(target_os = "macos")]
#[path = "desktop_notification_macos.rs"]
mod platform;
#[cfg(target_os = "windows")]
#[path = "desktop_notification_windows.rs"]
mod platform;

#[cfg(all(unix, not(target_os = "macos")))]
mod platform {
    use super::*;
    use notify_rust::{Hint, Notification, NotificationResponse, Timeout, Urgency};
    pub fn deliver(r: Request, close: mpsc::Receiver<()>) -> Result<Value> {
        let mut n = Notification::new();
        n.appname(if r.app_name.is_empty() {
            "Graffitty"
        } else {
            &r.app_name
        })
        .summary(&r.title)
        .body(&xml(&r.body))
        .action("default", "Show pane")
        .urgency(match r.urgency {
            0 => Urgency::Low,
            2 => Urgency::Critical,
            _ => Urgency::Normal,
        })
        .timeout(if r.timeout == 0 {
            Timeout::Never
        } else {
            Timeout::Default
        });
        for (i, label) in r.buttons.iter().enumerate() {
            n.action(&(i + 1).to_string(), label);
        }
        if !r.icon_path.is_empty() {
            n.icon(&r.icon_path);
        }
        if let Some(category) = r.types.first() {
            n.hint(Hint::Category(category.clone()));
        }
        if r.sound == "silent" {
            n.hint(Hint::SuppressSound(true));
        } else if !r.sound.is_empty() && r.sound != "system" {
            let sound = match r.sound.as_str() {
                "error" => "dialog-error",
                "warn" | "warning" => "dialog-warning",
                "info" => "dialog-information",
                "question" => "dialog-question",
                other => other,
            };
            n.hint(Hint::SoundName(sound.to_owned()));
        }
        let handle = n.show()?;
        let native_id = handle.id();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let result = handle.wait_for_response(|response: &NotificationResponse| {
                let value = match response {
                    NotificationResponse::Default => json!({"clicked":true,"button":0}),
                    NotificationResponse::Action(key) => {
                        json!({"clicked":true,"button":key.parse::<u32>().unwrap_or(0)})
                    }
                    _ => json!({"clicked":false}),
                };
                let _ = tx.send(value);
            });
            if let Err(e) = result {
                let _ = tx.send(json!({"error":e.to_string()}));
            }
        });
        let start = Instant::now();
        loop {
            if let Ok(result) = rx.try_recv() {
                return Ok(result);
            }
            if should_close(&close, start, r.timeout) {
                let connection = zbus::blocking::Connection::session()?;
                let proxy = zbus::blocking::Proxy::new(
                    &connection,
                    "org.freedesktop.Notifications",
                    "/org/freedesktop/Notifications",
                    "org.freedesktop.Notifications",
                )?;
                let _: () = proxy.call("CloseNotification", &(native_id,))?;
                return Ok(json!({"clicked":false}));
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}
