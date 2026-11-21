//! What the host publishes to mods and what mods ask of the host.
//!
//! Ported from herdr-app `src/mods.rs` (Apache-2.0, Herdr): snapshots with a
//! revision per key, `LiveReads` that record which keys a copy read, the
//! shared store, and the request queue.
//!
//! The window publishes; mods read synchronously and re-render only when a
//! key they read changed. Nothing polls.
use std::collections::HashMap;
use std::path::PathBuf;

use serde_json::{Map, Value};

/// Snapshots the frontend publishes, by key (`sessions`, `agents`, …).
#[derive(Default)]
pub struct Snapshot {
    values: HashMap<String, Value>,
    revisions: HashMap<String, u64>,
}

impl Snapshot {
    /// Replaces one part of the snapshot; returns whether it changed.
    pub fn publish(&mut self, key: &str, value: Value) -> bool {
        if self.values.get(key) == Some(&value) {
            return false;
        }
        self.values.insert(key.to_owned(), value);
        *self.revisions.entry(key.to_owned()).or_default() += 1;
        true
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.values.get(key)
    }

    pub fn revision(&self, key: &str) -> u64 {
        self.revisions.get(key).copied().unwrap_or(0)
    }

    pub fn revisions(&self) -> &HashMap<String, u64> {
        &self.revisions
    }
}

/// Which snapshot keys one copy read, and at which revision.
#[derive(Default, Debug)]
pub struct LiveReads(HashMap<String, u64>);

impl LiveReads {
    pub fn record(&mut self, key: &str, snapshot: &Snapshot) {
        if !self.0.contains_key(key) {
            self.0.insert(key.to_owned(), snapshot.revision(key));
        }
    }

    /// Whether any read key moved on; remembers the new revisions.
    pub fn changed(&mut self, snapshot: &Snapshot) -> bool {
        let mut changed = false;
        for (key, seen) in &mut self.0 {
            let revision = snapshot.revision(key);
            changed |= *seen != revision;
            *seen = revision;
        }
        changed
    }

    pub fn keys(&self) -> impl Iterator<Item = &str> {
        self.0.keys().map(String::as_str)
    }
}

/// Values every mod can read (persisted as JSON); setting one re-renders all.
pub struct SharedStore {
    values: Map<String, Value>,
    path: Option<PathBuf>,
}

impl SharedStore {
    pub fn load(path: Option<PathBuf>) -> Self {
        let values = path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice::<Map<String, Value>>(&bytes).ok())
            .unwrap_or_default();
        Self { values, path }
    }

    pub fn get(&self, key: &str) -> Option<&Value> {
        self.values.get(key)
    }

    /// Returns whether the value changed.
    pub fn set(&mut self, key: String, value: Value) -> bool {
        if self.values.get(&key) == Some(&value) {
            return false;
        }
        self.values.insert(key, value);
        if let Some(path) = &self.path {
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = write_atomic(path, &serde_json::to_vec(&self.values).unwrap_or_default());
        }
        true
    }
}

/// A per-copy `localStorage`, kept as one JSON file.
pub struct Storage {
    values: Map<String, Value>,
    path: Option<PathBuf>,
}

impl Storage {
    pub fn load(path: Option<PathBuf>) -> Self {
        let values = path
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice::<Map<String, Value>>(&bytes).ok())
            .unwrap_or_default();
        Self { values, path }
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.get(key).and_then(Value::as_str)
    }

    pub fn set(&mut self, key: &str, value: Option<String>) {
        let changed = match value {
            Some(text) => self.values.insert(key.to_owned(), Value::String(text)).is_none_or(|old| old.as_str() != self.values[key].as_str()),
            None => self.values.remove(key).is_some(),
        };
        if changed && let Some(path) = &self.path {
            if let Some(dir) = path.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = write_atomic(path, &serde_json::to_vec(&self.values).unwrap_or_default());
        }
    }
}

fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(tmp, path)
}

/// What a mod asked the host to do. Drained by the frontend each frame.
#[derive(Clone, Debug, PartialEq)]
pub enum Request {
    /// `run(action, args)`: a PascalCase action from the client-config registry.
    Run { copy: u64, name: String, args: Value },
    OpenOverlay { copy: u64, id: String, spec: Value },
    CloseOverlay { copy: u64, id: String },
    Notify { copy: u64, spec: Value },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_change_only_for_keys_a_copy_read() {
        let mut snapshot = Snapshot::default();
        snapshot.publish("agents", serde_json::json!([]));
        let mut reads = LiveReads::default();
        reads.record("agents", &snapshot);
        assert!(!reads.changed(&snapshot));
        assert!(snapshot.publish("sessions", serde_json::json!([1])));
        assert!(!reads.changed(&snapshot), "an unread key must not wake the copy");
        assert!(!snapshot.publish("agents", serde_json::json!([])), "same value, no revision bump");
        assert!(snapshot.publish("agents", serde_json::json!([{"id": 1}])));
        assert!(reads.changed(&snapshot));
        assert!(!reads.changed(&snapshot), "a change is reported once");
    }

    #[test]
    fn shared_store_persists_and_dedupes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("shared.json");
        let mut store = SharedStore::load(Some(path.clone()));
        assert!(store.set("a".into(), serde_json::json!(1)));
        assert!(!store.set("a".into(), serde_json::json!(1)));
        let again = SharedStore::load(Some(path));
        assert_eq!(again.get("a"), Some(&serde_json::json!(1)));
    }
}
