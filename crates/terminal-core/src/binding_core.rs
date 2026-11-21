//! Framework-independent key sequence, leader and transient-table state.
use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

#[derive(Clone)]
pub struct Binding {
    pub keys: Vec<i64>,
    pub action: String,
}
#[derive(Clone)]
pub struct Table {
    pub bindings: Vec<Binding>,
    pub one_shot: bool,
    pub timeout: Duration,
}
pub enum Decision {
    Pass,
    Consume,
    Action(String),
}
#[derive(Default)]
pub struct Keyboard {
    sequences: Vec<Binding>,
    tables: HashMap<String, Table>,
    leader: Option<i64>,
    timeout: Duration,
    stack: Vec<(String, Instant)>,
    pending: Vec<i64>,
    deadline: Option<Instant>,
    held: HashSet<i32>,
}
impl Keyboard {
    pub fn pending(&self) -> bool {
        !self.pending.is_empty() || !self.stack.is_empty()
    }
    pub fn configure(
        &mut self,
        sequences: Vec<Binding>,
        tables: HashMap<String, Table>,
        leader: Option<i64>,
        timeout: Duration,
    ) {
        self.sequences = sequences;
        self.tables = tables;
        self.leader = leader;
        self.timeout = timeout;
        self.reset();
    }
    pub fn hold(&mut self, physical: i32) {
        self.held.insert(physical);
    }
    pub fn cancel(&mut self) {
        self.reset();
        self.held.clear();
    }
    pub fn reset(&mut self) {
        self.stack.clear();
        self.pending.clear();
        self.deadline = None;
    }
    pub fn release(&mut self, key: i32) -> bool {
        self.held.remove(&key)
    }
    pub fn action(&mut self, action: &str) -> bool {
        if action == "pop_key_table" {
            self.stack.pop();
            self.pending.clear();
            return true;
        }
        if let Some(name) = action.strip_prefix("activate_key_table:") {
            if let Some(table) = self.tables.get(name) {
                if self.stack.len() == 16 {
                    self.stack.remove(0);
                }
                self.stack
                    .push((name.to_owned(), Instant::now() + table.timeout));
                self.pending.clear();
                return true;
            }
        }
        false
    }
    pub fn press(&mut self, code: i64, physical: i32, echo: bool) -> Decision {
        if echo && self.held.contains(&physical) {
            return Decision::Consume;
        }
        let now = Instant::now();
        while self.stack.last().is_some_and(|(_, until)| *until <= now) {
            self.stack.pop();
            self.pending.clear();
        }
        if self.deadline.is_some_and(|until| until <= now) {
            self.pending.clear();
            self.deadline = None;
        }
        if self.pending.is_empty() && self.stack.is_empty() && self.leader == Some(code) {
            self.pending.push(-1);
            self.deadline = Some(now + self.timeout);
            self.held.insert(physical);
            return Decision::Consume;
        }
        let table = self
            .stack
            .last()
            .and_then(|(name, _)| self.tables.get(name));
        let bindings = table.map_or(&self.sequences, |t| &t.bindings);
        let had_prefix = !self.pending.is_empty();
        self.pending.push(code);
        let exact = bindings
            .iter()
            .find(|b| b.keys == self.pending)
            .map(|b| b.action.clone());
        let prefix = bindings.iter().any(|b| b.keys.starts_with(&self.pending));
        if let Some(action) = exact {
            let one_shot = table.is_some_and(|t| t.one_shot);
            self.pending.clear();
            self.deadline = None;
            self.held.insert(physical);
            if one_shot {
                self.stack.pop();
            }
            return Decision::Action(action);
        }
        if prefix {
            self.deadline = Some(now + self.timeout);
            self.held.insert(physical);
            return Decision::Consume;
        }
        self.pending.clear();
        self.deadline = None;
        if had_prefix || table.is_some() {
            self.held.insert(physical);
            if table.is_some_and(|t| t.one_shot) {
                self.stack.pop();
            }
            Decision::Consume
        } else {
            Decision::Pass
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn keyboard() -> Keyboard {
        Keyboard {
            timeout: Duration::from_secs(1),
            leader: Some(10),
            sequences: vec![
                Binding {
                    keys: vec![-1, 20],
                    action: "search".into(),
                },
                Binding {
                    keys: vec![30, 40],
                    action: "copy".into(),
                },
            ],
            ..Default::default()
        }
    }
    #[test]
    fn leader_sequences_and_releases() {
        let mut k = keyboard();
        assert!(matches!(k.press(10, 10, false), Decision::Consume));
        assert!(k.release(10));
        assert!(matches!(k.press(20,20,false),Decision::Action(a) if a=="search"));
        assert!(matches!(k.press(20, 20, true), Decision::Consume));
        assert!(k.release(20));
        assert!(matches!(k.press(30, 30, false), Decision::Consume));
        assert!(matches!(k.press(99, 99, false), Decision::Consume));
        assert!(matches!(k.press(50, 50, false), Decision::Pass));
    }
    #[test]
    fn timeout_focus_and_tables() {
        let mut k = keyboard();
        k.press(10, 10, false);
        k.deadline = Some(Instant::now());
        assert!(matches!(k.press(20, 20, false), Decision::Pass));
        k.tables.insert(
            "navigation".into(),
            Table {
                bindings: vec![Binding {
                    keys: vec![1],
                    action: "next_prompt".into(),
                }],
                one_shot: true,
                timeout: Duration::from_secs(1),
            },
        );
        assert!(k.action("activate_key_table:navigation"));
        assert!(matches!(k.press(1,1,false),Decision::Action(a) if a=="next_prompt"));
        assert!(k.stack.is_empty());
        k.action("activate_key_table:navigation");
        k.reset();
        assert!(matches!(k.press(1, 1, false), Decision::Pass));
    }
}
