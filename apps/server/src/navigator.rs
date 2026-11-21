//! Server-owned terminal navigation policy and directional selection.
use crate::{Error, api};
use graffitty_workspace_core::navigation::{Algorithm, neighbor_with_algorithm};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub enabled: bool,
    pub filetree: bool,
    pub algorithm: String,
    pub bindings: BTreeMap<String, String>,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            enabled: false,
            filetree: true,
            algorithm: "spatial".into(),
            bindings: [
                ("ctrl+h", "left"),
                ("ctrl+j", "down"),
                ("ctrl+k", "up"),
                ("ctrl+l", "right"),
            ]
            .into_iter()
            .map(|(k, v)| (k.into(), v.into()))
            .collect(),
        }
    }
}
impl Config {
    pub fn validate(&self) -> Result<(), String> {
        if Algorithm::parse(&self.algorithm).is_none() {
            return Err("navigator.algorithm must be weighted, spatial or nearest".into());
        }
        for (key, direction) in &self.bindings {
            let parts: Vec<_> = key.split('+').collect();
            let modifiers = &parts[..parts.len() - 1];
            let ordered: Vec<_> = ["ctrl", "alt", "shift", "meta"]
                .into_iter()
                .filter(|m| modifiers.contains(m))
                .collect();
            if modifiers.is_empty()
                || modifiers != ordered
                || parts
                    .last()
                    .is_none_or(|k| k.len() != 1 || !k.as_bytes()[0].is_ascii_lowercase())
                || !["left", "down", "up", "right"].contains(&direction.as_str())
            {
                return Err("navigator.bindings requires ordered ctrl/alt/shift/meta modifiers, a lowercase letter, and left/down/up/right".into());
            }
        }
        Ok(())
    }
}

// Geometry belongs to the presentation; keys are opaque presentation pane IDs.
// The server returns a decision, never mutates focus on behalf of a stale request.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Context {
    pub origin: String,
    pub rects: BTreeMap<String, [f32; 4]>,
}
impl Context {
    pub fn parse(value: &Value) -> Result<Self, Error> {
        let context: Self = serde_json::from_value(value.clone())?;
        if context.rects.len() > 4096
            || !context.rects.contains_key(&context.origin)
            || context.rects.iter().any(|(key, r)| {
                key.len() > 128 || r.iter().any(|n| !n.is_finite()) || r[2] <= 0. || r[3] <= 0.
            })
        {
            return Err(api::error(
                "invalid_params",
                "Expected finite shown pane rectangles including the source",
            ));
        }
        Ok(context)
    }
    fn select(&self, direction: &str, config: &Config) -> Value {
        match neighbor_with_algorithm(
            &self.rects,
            &self.origin,
            direction,
            Algorithm::parse(&config.algorithm).unwrap(),
        ) {
            Some(pane) => json!({"result":{"outcome":"moved", "destination":pane}}),
            None => json!({"result":{"outcome":"edge", "destination":self.origin}}),
        }
    }
}

pub fn select(config: &Config, params: &Value) -> Result<Value, Error> {
    let direction = params["direction"]
        .as_str()
        .filter(|d| ["left", "down", "up", "right"].contains(d))
        .ok_or("Expected left, down, up or right")?;
    Ok(Context::parse(&params["context"])?.select(direction, config))
}

use std::{
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};

static INFLIGHT: AtomicUsize = AtomicUsize::new(0);

pub fn input(
    config: &Config,
    foreground: Option<i32>,
    params: &Value,
) -> Result<api::Reply, Error> {
    let direction = config.bindings.get(params["key"].as_str().unwrap_or(""));
    if !config.enabled || direction.is_none() {
        return Ok(api::Reply::Ready(
            json!({"result":{"outcome":"pass", "effects":true}}),
        ));
    }
    let context = Context::parse(&params["context"])?;
    let direction = direction.unwrap().clone();
    let config = config.clone();
    let Some(pid) = foreground else {
        return Ok(api::Reply::Ready(json!({"result":{"outcome":"pass"}})));
    };
    if INFLIGHT.fetch_add(1, Ordering::SeqCst) >= 32 {
        INFLIGHT.fetch_sub(1, Ordering::SeqCst);
        return Err(api::error("busy", "Too many navigation requests"));
    }
    let (tx, rx) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let result = if is_shell(&process_name(pid)) {
            context.select(&direction, &config)
        } else {
            json!({"result":{"outcome":"pass"}})
        };
        let _ = tx.send(result);
        INFLIGHT.fetch_sub(1, Ordering::SeqCst);
    });
    Ok(api::Reply::Pending(rx))
}

fn is_shell(name: &str) -> bool {
    matches!(
        name.trim_start_matches('-'),
        "sh" | "bash" | "zsh" | "fish" | "dash" | "ksh" | "nu"
    )
}

fn process_name(pid: i32) -> String {
    let Ok(mut child) = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "comm="])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return String::new();
    };
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => {
                return child
                    .wait_with_output()
                    .ok()
                    .map(|o| {
                        String::from_utf8_lossy(&o.stdout)
                            .trim()
                            .rsplit('/')
                            .next()
                            .unwrap_or("")
                            .to_owned()
                    })
                    .unwrap_or_default();
            }
            Ok(None) if started.elapsed() < Duration::from_millis(500) => {
                std::thread::sleep(Duration::from_millis(2))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return String::new();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn context() -> Value {
        json!({"origin":"%1", "rects":{"%1":[0,0,100,100],"large":[410,140,400,200],"aligned":[470,-100,200,100],"close":[250,320,100,100]}})
    }
    #[test]
    fn server_selects_neighbors_using_configured_algorithm() {
        for (algorithm, target) in [
            ("weighted", "large"),
            ("spatial", "aligned"),
            ("nearest", "close"),
        ] {
            let config = Config {
                algorithm: algorithm.into(),
                ..Config::default()
            };
            let result =
                select(&config, &json!({"direction":"right", "context":context()})).unwrap();
            assert_eq!(result["result"]["destination"], target);
            assert_eq!(
                select(&config, &json!({"direction":"left", "context":context()})).unwrap()["result"]
                    ["outcome"],
                "edge"
            );
        }
    }
    #[test]
    fn disabled_or_unbound_input_does_not_inspect_process_or_geometry() {
        for config in [
            Config::default(),
            Config {
                enabled: true,
                bindings: BTreeMap::new(),
                ..Config::default()
            },
        ] {
            let api::Reply::Ready(value) =
                input(&config, Some(999999), &json!({"key":"ctrl+h"})).unwrap()
            else {
                panic!("Should not start process worker")
            };
            assert_eq!(value["result"]["outcome"], "pass");
            assert_eq!(value["result"]["effects"], true);
        }
    }
    #[test]
    fn invalid_geometry_and_directions_are_rejected() {
        for geometry in [
            json!({"origin":"missing","rects":{}}),
            json!({"origin":"%1","rects":{"%1":[0,0,-1,100]}}),
        ] {
            assert!(
                select(
                    &Config::default(),
                    &json!({"direction":"right","context":geometry})
                )
                .is_err()
            );
        }
        assert!(
            select(
                &Config::default(),
                &json!({"direction":"bottom","context":context()})
            )
            .is_err()
        );
    }
    #[test]
    fn navigator_settings_are_validated() {
        Config::default().validate().unwrap();
        assert!(
            Config {
                algorithm: "bad".into(),
                ..Config::default()
            }
            .validate()
            .is_err()
        );
        for key in ["h", "ctrl+ctrl+h", "shift+ctrl+h", "super+h", "ctrl+"] {
            assert!(
                Config {
                    bindings: [(key.into(), "left".into())].into(),
                    ..Config::default()
                }
                .validate()
                .is_err(),
                "{key}"
            );
        }
    }
    #[test]
    fn only_shells_allow_outer_navigation() {
        for name in ["sh", "bash", "-zsh", "fish", "dash", "ksh", "nu"] {
            assert!(is_shell(name));
        }
        for name in [
            "",
            "nvim",
            "vim",
            "tmux",
            "tmux: client",
            "ssh",
            "fzf",
            "less",
            "python",
        ] {
            assert!(!is_shell(name), "{name} must receive its original keys");
        }
    }
    #[test]
    fn unknown_foreground_passes_through() {
        let api::Reply::Ready(value) = input(
            &Config {
                enabled: true,
                ..Config::default()
            },
            None,
            &json!({"key":"ctrl+h", "context":{"origin":"%1","rects":{"%1":[0,0,100,100]}}}),
        )
        .unwrap() else {
            panic!("Unknown foreground should not start a worker")
        };
        assert_eq!(value["result"]["outcome"], "pass");
    }
}
