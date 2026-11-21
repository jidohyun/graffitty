//! Scripted replacement for the Decisions service, used only by `gft dev`.
use super::{Result, STOP, Settings};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    path::PathBuf,
    sync::atomic::Ordering,
    time::{Duration, Instant},
};

#[derive(Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub(super) struct Scenario {
    decisions: Vec<Rule>,
    animation_clock: Option<PathBuf>,
    #[serde(default = "default_delay")]
    delay_ms: u64,
    #[serde(skip)]
    sequence: usize,
}

fn default_delay() -> u64 {
    600
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rule {
    prompt: Option<String>,
    contains: Option<String>,
    answer: Value,
    delay_ms: Option<u64>,
}

pub(super) struct Decision {
    answer: Value,
    delay_ms: u64,
    clock: Option<PathBuf>,
}

impl Scenario {
    pub(super) fn load(path: Option<&str>) -> Result<Self> {
        let scenario: Self = match path {
            Some(path) => serde_json::from_slice(&std::fs::read(path)?)?,
            None => serde_json::from_value(json!({}))?,
        };
        if scenario.delay_ms > 60_000
            || scenario
                .decisions
                .iter()
                .any(|r| r.delay_ms.is_some_and(|v| v > 60_000))
        {
            return Err("Mock decision delays must be at most 60000 ms".into());
        }
        if scenario
            .decisions
            .iter()
            .any(|r| r.prompt.is_some() && r.contains.is_some())
        {
            return Err("A mock decision can match prompt or contains, not both".into());
        }
        if let Some(path) = &scenario.animation_clock {
            read_clock(path)?;
        }
        Ok(scenario)
    }

    pub(super) fn select(&mut self, settings: &Settings, request: &Value) -> Result<Decision> {
        let state = &request["state"];
        let prompt = state
            .as_str()
            .or_else(|| state["text"].as_str())
            .or_else(|| state["payload"]["text"].as_str())
            .unwrap_or("");
        let selected = self
            .decisions
            .iter()
            .find(|r| {
                r.prompt.as_deref().is_some_and(|s| s == prompt)
                    || r.contains.as_deref().is_some_and(|s| prompt.contains(s))
            })
            .or_else(|| {
                let rule = self
                    .decisions
                    .iter()
                    .filter(|r| r.prompt.is_none() && r.contains.is_none())
                    .nth(self.sequence);
                if rule.is_some() {
                    self.sequence += 1;
                }
                rule
            });
        let (answer, delay_ms) = if let Some(rule) = selected {
            (rule.answer.clone(), rule.delay_ms.unwrap_or(self.delay_ms))
        } else if self.decisions.is_empty() {
            // An unconfigured demo picks the first declared port in every mode.
            (
                match settings.mode.as_str() {
                    "noul" => json!({"type":"noul", "noul":1.0}),
                    "score" => json!({"type":"score", "score":0.0}),
                    _ => json!({"type":"choice", "choice":settings.outputs[0].id}),
                },
                self.delay_ms,
            )
        } else {
            return Err("No scripted decision matches this input; queued input retained".into());
        };
        Ok(Decision {
            answer,
            delay_ms,
            clock: self.animation_clock.clone(),
        })
    }
}

fn read_clock(path: &PathBuf) -> Result<u64> {
    Ok(std::fs::read_to_string(path)?.trim().parse()?)
}

impl Decision {
    pub(super) fn run(self, settings: &Settings) -> Result<(String, Value)> {
        let start = Instant::now();
        let first = self
            .clock
            .as_ref()
            .map(read_clock)
            .transpose()?
            .unwrap_or(0);
        let mut elapsed = 0;
        while elapsed < self.delay_ms {
            if STOP.load(Ordering::Relaxed) {
                return Err("Mock decision interrupted".into());
            }
            std::thread::sleep(Duration::from_millis(5));
            elapsed = if let Some(path) = &self.clock {
                // Keep video time when an atomic clock replacement is temporarily missing.
                read_clock(path)
                    .map(|now| now.saturating_sub(first))
                    .unwrap_or(elapsed)
                    .max(elapsed)
            } else {
                start.elapsed().as_millis() as u64
            };
        }
        let route = settings.route(&json!({"answers":{"route":self.answer}}))?;
        Ok((route, self.answer))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_rules_reuse_without_consuming_sequential_fallbacks() {
        let mut script: Scenario = serde_json::from_value(json!({"delay_ms":0,"decisions":[
            {"prompt":"question","answer":{"type":"noul","noul":1}},
            {"contains":"review","answer":{"type":"noul","noul":0}},
            {"answer":{"type":"noul","noul":0.8}}
        ]}))
        .unwrap();
        let settings = Settings::default();
        for (prompt, output) in [
            ("question", "True"),
            ("please review", "False"),
            ("question", "True"),
            ("other", "True"),
        ] {
            let decision = script
                .select(&settings, &json!({"state":{"text":prompt}}))
                .unwrap();
            assert_eq!(decision.run(&settings).unwrap().0, output);
        }
        assert!(
            script
                .select(&settings, &json!({"state":"unknown"}))
                .is_err()
        );
    }

    #[test]
    fn defaults_follow_first_declared_port_and_invalid_answers_use_real_validation() {
        let mut script = Scenario::load(None).unwrap();
        script.delay_ms = 0;
        let mut settings = Settings::default();
        for mode in ["noul", "choice", "score"] {
            settings.mode = mode.into();
            let decision = script.select(&settings, &json!({"state":"hello"})).unwrap();
            assert_eq!(decision.run(&settings).unwrap().0, "True");
        }
        let bad = Decision {
            answer: json!({"type":"choice","choice":"missing"}),
            delay_ms: 0,
            clock: None,
        };
        settings.mode = "choice".into();
        assert!(bad.run(&settings).is_err());
    }
}
