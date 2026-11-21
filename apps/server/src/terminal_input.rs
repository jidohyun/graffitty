//! Bounded, paced input owned by a PTY session. No sleeps on the owner loop.
use crate::{Error, api};
use graffitty_terminal_core::{command_input::Stroke, vt::Terminal};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::mpsc::{self, Receiver, SyncSender, TrySendError},
    time::{Duration, Instant},
};

pub struct Input {
    strokes: VecDeque<Stroke>,
    encoded: Option<Vec<u8>>,
    interval: Duration,
    next: Instant,
    deadline: Instant,
    sent: usize,
    reply: Option<SyncSender<Value>>,
    activity: Vec<Value>,
    effects: bool,
}

impl Input {
    pub fn new(method: &str, params: &Value) -> Result<(Self, Receiver<Value>), Error> {
        let effects = params.get("effects").map_or(Ok(true), |v| {
            v.as_bool().ok_or_else(|| api::error("invalid_params", "effects must be a boolean"))
        })?;
        let interval = match params.get("interval_ms") {
            Some(v) => v
                .as_f64()
                .filter(|n| n.is_finite() && (0.0..=1000.0).contains(n))
                .ok_or_else(|| api::error("invalid_params", "interval_ms must be 0–1000"))?,
            None => 50.0,
        };
        let strokes: VecDeque<_> = if method == "terminal.type" {
            let text = params["text"]
                .as_str()
                .filter(|s| s.chars().count() <= 4096)
                .ok_or_else(|| {
                    api::error(
                        "invalid_params",
                        "text must be a string of at most 4096 characters",
                    )
                })?;
            text.chars()
                .map(|ch| match ch {
                    '\n' => Ok(Stroke::parse("Enter").unwrap()),
                    '\t' => Ok(Stroke::parse("Tab").unwrap()),
                    c if c < ' ' || c == '\x7f' => Err(api::error(
                        "invalid_params",
                        "Use terminal.press for control keys",
                    )),
                    c => Ok(Stroke::character(c)),
                })
                .collect::<Result<_, _>>()?
        } else {
            let key = params["key"]
                .as_str()
                .ok_or_else(|| api::error("invalid_params", "key must be a string"))?;
            VecDeque::from([Stroke::parse(key).map_err(|e| api::error("invalid_key", e))?])
        };
        if strokes.len() as f64 * interval > 30_000.0 {
            return Err(api::error(
                "invalid_params",
                "Input sequence must fit within 30 seconds",
            ));
        }
        let (reply, receiver) = mpsc::sync_channel(1);
        let now = Instant::now();
        Ok((
            Self {
                strokes,
                encoded: None,
                interval: Duration::from_secs_f64(interval / 1000.0),
                next: now,
                deadline: now + Duration::from_secs(31),
                sent: 0,
                reply: Some(reply),
                activity: vec![],
                effects,
            },
            receiver,
        ))
    }

    pub fn poll(
        &mut self,
        vt: &Terminal<'_, '_>,
        input: &SyncSender<Vec<u8>>,
        exited: bool,
    ) -> bool {
        if exited {
            return self.fail("workspace_closed", "Terminal has exited");
        }
        if Instant::now() >= self.deadline {
            return self.fail("input_timeout", "Terminal input timed out");
        }
        // Bound work even for interval=0; large input never monopolizes the owner.
        for _ in 0..64 {
            if Instant::now() < self.next {
                return false;
            }
            let Some(stroke) = self.strokes.front() else {
                if let Some(reply) = self.reply.take() {
                    let _ = reply.try_send(json!({"result":{"keys_sent":self.sent}}));
                }
                return true;
            };
            let bytes = match self.encoded.take() {
                Some(bytes) => bytes,
                None => match stroke.encode(vt) {
                    Ok(bytes) => bytes,
                    Err(error) => return self.fail("input_failed", &error.to_string()),
                },
            };
            if !bytes.is_empty() {
                match input.try_send(bytes) {
                    Ok(()) => {
                        if self.effects && let Some(unicode) = stroke.typing_unicode() {
                            self.activity.push(json!({"unicode":unicode, "cell":[vt.cursor_x().unwrap_or(0), vt.cursor_y().unwrap_or(0)]}));
                        }
                    }
                    Err(TrySendError::Full(bytes)) => {
                        self.encoded = Some(bytes);
                        return false;
                    }
                    Err(TrySendError::Disconnected(_)) => {
                        return self.fail("workspace_closed", "Terminal input is closed");
                    }
                }
            }
            self.strokes.pop_front();
            self.sent += 1;
            self.next += self.interval;
        }
        false
    }

    fn fail(&mut self, code: &str, message: &str) -> bool {
        if let Some(reply) = self.reply.take() {
            let _ = reply
                .try_send(json!({"error":{"code":code,"message":message,"keys_sent":self.sent}}));
        }
        true
    }
    pub fn take_activity(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.activity)
    }
}
impl Drop for Input {
    fn drop(&mut self) {
        self.fail("workspace_closed", "Terminal closed during input");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arrows_reach_the_pty_without_observational_typing_effects() {
        let vt = graffitty_terminal_core::new_vt(80, 24, 0).unwrap();
        for key in ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Ctrl+ArrowLeft", "Shift+ArrowDown"] {
            let (input, output) = mpsc::sync_channel(1);
            let (mut job, result) = Input::new("terminal.press", &json!({"key": key, "interval_ms": 0})).unwrap();
            assert!(job.poll(&vt, &input, false));
            assert!(!output.recv().unwrap().is_empty(), "{key} must still navigate");
            assert_eq!(result.recv().unwrap()["result"]["keys_sent"], 1);
            assert!(job.take_activity().is_empty(), "{key} must not emit sparks");
        }
        for (key, unicode) in [("x", 120), ("Backspace", 8), ("Delete", 127)] {
            let (input, _output) = mpsc::sync_channel(1);
            let (mut job, _result) = Input::new("terminal.press", &json!({"key": key, "interval_ms": 0})).unwrap();
            assert!(job.poll(&vt, &input, false));
            assert_eq!(job.take_activity()[0]["unicode"], unicode);
        }
    }

    #[test]
    fn full_pty_queue_retries_without_duplication_and_close_completes_request() {
        let vt = graffitty_terminal_core::new_vt(80, 24, 0).unwrap();
        let (input, output) = mpsc::sync_channel(1);
        let (mut job, result) =
            Input::new("terminal.type", &json!({"text":"ab", "interval_ms":0})).unwrap();
        assert!(!job.poll(&vt, &input, false));
        assert_eq!(output.recv().unwrap(), b"a");
        assert!(job.poll(&vt, &input, false));
        assert_eq!(output.recv().unwrap(), b"b");
        assert_eq!(result.recv().unwrap()["result"]["keys_sent"], 2);
        let (job, result) = Input::new("terminal.type", &json!({"text":"remaining"})).unwrap();
        drop(job);
        assert_eq!(result.recv().unwrap()["error"]["code"], "workspace_closed");
    }
}
