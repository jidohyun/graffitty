//! Volatile pane metadata (titles, foreground apps, effect holds, filetree
//! roots) changes many times a second while agents animate their titles.
//!
//! It travels as small `pane_update` deltas; the full `topology` is re-sent
//! only when its structure changes.
//!
//! Panes the client subscribed to are refreshed at `FAST`; everything it does
//! not display waits for `SLOW`, following herdr-core's per-terminal
//! `title`/`foreground` events instead of snapshots.
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::time::{Duration, Instant};

pub const PANE_FIELDS: &[&str] = &[
    "title",
    "title_is_fallback",
    "automatic_title",
    "app",
    "effect_holds",
    "filetree",
    "filetree_open",
];
pub const TAB_FIELDS: &[&str] = &["title"];
pub const CHROMIUM_FIELDS: &[&str] = &["title", "automatic_title", "state"];
/// Coalescing interval for panes the client renders.
pub const FAST: Duration = Duration::from_millis(200);
/// Coalescing interval for hidden panes, tab strip titles and chromiums.
///
/// Deltas send only values that changed. Choose a sampling interval that
/// avoids common title spinner periods such as 800 ms and 1 s.
///
/// Sampling a 1 s spinner every 1 s always sees the same frame. The title
/// then appears frozen.
pub const SLOW: Duration = Duration::from_millis(450);

#[derive(Default)]
pub struct Tracker {
    panes: HashMap<u64, Map<String, Value>>,
    tabs: HashMap<u64, Map<String, Value>>,
    chromiums: HashMap<u64, Map<String, Value>>,
    flushed: Option<Instant>,
    slow_flushed: Option<Instant>,
}

fn volatile(item: &Value, fields: &[&str]) -> Map<String, Value> {
    let mut result = Map::new();
    if let Some(object) = item.as_object() {
        for field in fields {
            if let Some(value) = object.get(*field) {
                result.insert((*field).to_string(), value.clone());
            }
        }
    }
    result
}

fn strip(list: &mut Value, fields: &[&str]) {
    if let Some(items) = list.as_array_mut() {
        for item in items {
            if let Some(object) = item.as_object_mut() {
                for field in fields {
                    object.remove(*field);
                }
            }
        }
    }
}

/// Fields of `current` that differ from `last`, as one delta entry.
fn changed(id: u64, last: Option<&Map<String, Value>>, current: &Map<String, Value>) -> Option<Value> {
    let mut delta = Map::new();
    for (key, value) in current {
        if last.and_then(|l| l.get(key)) != Some(value) {
            delta.insert(key.clone(), value.clone());
        }
    }
    if delta.is_empty() {
        return None;
    }
    delta.insert("id".into(), json!(id));
    Some(Value::Object(delta))
}

impl Tracker {
    /// The topology with its volatile fields removed: equal strings mean the
    /// structure is unchanged and only deltas may be needed.
    pub fn structural(topology: &Value) -> String {
        let mut copy = topology.clone();
        strip(&mut copy["panes"], PANE_FIELDS);
        strip(&mut copy["tabs"], TAB_FIELDS);
        strip(&mut copy["chromiums"], CHROMIUM_FIELDS);
        copy.to_string()
    }

    /// Everything in a freshly sent full topology counts as delivered.
    pub fn reset(&mut self, topology: &Value, now: Instant) {
        self.panes.clear();
        self.tabs.clear();
        self.chromiums.clear();
        for (list, fields, store) in [
            ("panes", PANE_FIELDS, &mut self.panes),
            ("tabs", TAB_FIELDS, &mut self.tabs),
            ("chromiums", CHROMIUM_FIELDS, &mut self.chromiums),
        ] {
            for item in topology[list].as_array().into_iter().flatten() {
                if let Some(id) = item["id"].as_u64() {
                    store.insert(id, volatile(item, fields));
                }
            }
        }
        self.flushed = Some(now);
        self.slow_flushed = Some(now);
    }

    pub fn clear(&mut self) {
        *self = Self::default();
    }

    /// A `pane_update` with only the fields that changed since the last
    /// delivery, or `None` when nothing is due. Subscribed panes (and tabs
    /// holding one) refresh at `FAST`; the rest at `SLOW`.
    pub fn delta(&mut self, topology: &Value, subscribed: &[u64], now: Instant) -> Option<Value> {
        if self.flushed.is_some_and(|at| now.duration_since(at) < FAST) {
            return None;
        }
        let slow_due = self.slow_flushed.is_none_or(|at| now.duration_since(at) >= SLOW);
        let mut panes = vec![];
        for item in topology["panes"].as_array().into_iter().flatten() {
            let Some(id) = item["id"].as_u64() else { continue };
            if !subscribed.contains(&id) && !slow_due { continue; }
            let current = volatile(item, PANE_FIELDS);
            if let Some(entry) = changed(id, self.panes.get(&id), &current) {
                panes.push(entry);
                self.panes.insert(id, current);
            }
        }
        let mut tabs = vec![];
        for item in topology["tabs"].as_array().into_iter().flatten() {
            let Some(id) = item["id"].as_u64() else { continue };
            let shown = item["sessions"].as_array().into_iter().flatten()
                .filter_map(Value::as_u64).any(|pane| subscribed.contains(&pane));
            if !shown && !slow_due { continue; }
            let current = volatile(item, TAB_FIELDS);
            if let Some(entry) = changed(id, self.tabs.get(&id), &current) {
                tabs.push(entry);
                self.tabs.insert(id, current);
            }
        }
        let mut chromiums = vec![];
        for item in topology["chromiums"].as_array().into_iter().flatten() {
            let Some(id) = item["id"].as_u64() else { continue };
            if !subscribed.contains(&id) && !slow_due { continue; }
            let current = volatile(item, CHROMIUM_FIELDS);
            if let Some(entry) = changed(id, self.chromiums.get(&id), &current) {
                chromiums.push(entry);
                self.chromiums.insert(id, current);
            }
        }
        if slow_due {
            self.slow_flushed = Some(now);
        }
        if panes.is_empty() && tabs.is_empty() && chromiums.is_empty() {
            return None;
        }
        self.flushed = Some(now);
        Some(json!({"type":"pane_update","panes":panes,"tabs":tabs,"chromiums":chromiums}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn topology(title: &str, hidden: &str) -> Value {
        json!({"type":"topology","panes":[
            {"id":1,"tab":10,"title":title,"automatic_title":title,"title_is_fallback":false,"rect":[0,0,1,1],"app":{"id":"shell"}},
            {"id":2,"tab":11,"title":hidden,"automatic_title":hidden,"title_is_fallback":false,"rect":[0,0,1,1],"app":{}}],
            "tabs":[{"id":10,"title":title,"sessions":[1]},{"id":11,"title":hidden,"sessions":[2]}],
            "chromiums":[],"workspace_state":{"revision":3}})
    }

    #[test]
    fn title_changes_are_not_structural() {
        let a = Tracker::structural(&topology("a", "x"));
        let b = Tracker::structural(&topology("b", "y"));
        assert_eq!(a, b);
        let mut moved = topology("a", "x");
        moved["panes"][0]["rect"] = json!([1, 1, 2, 2]);
        assert_ne!(a, Tracker::structural(&moved));
        assert!(!a.contains("\"title\""), "{a}");
    }

    #[test]
    fn deltas_carry_only_changed_fields_for_subscribed_panes_first() {
        let start = Instant::now();
        let mut tracker = Tracker::default();
        tracker.reset(&topology("a", "x"), start);
        assert!(tracker.delta(&topology("a", "x"), &[1], start + FAST).is_none(), "unchanged state sends nothing");
        // Within FAST nothing goes out, even for a subscribed pane.
        assert!(tracker.delta(&topology("b", "y"), &[1], start + Duration::from_millis(50)).is_none());
        let first = tracker.delta(&topology("b", "y"), &[1], start + FAST).unwrap();
        assert_eq!(first["type"], "pane_update");
        assert_eq!(first["panes"].as_array().unwrap().len(), 1, "hidden pane waits for SLOW: {first}");
        assert_eq!(first["panes"][0]["id"], 1);
        assert_eq!(first["panes"][0]["title"], "b");
        assert!(first["panes"][0].get("app").is_none(), "unchanged fields are omitted");
        assert_eq!(first["tabs"][0], json!({"id":10,"title":"b"}));
        // The hidden pane and its tab arrive once SLOW has elapsed.
        let second = tracker.delta(&topology("b", "y"), &[1], start + SLOW).unwrap();
        assert_eq!(second["panes"][0]["id"], 2);
        assert_eq!(second["panes"][0]["title"], "y");
        assert_eq!(second["tabs"][0]["id"], 11);
        assert!(tracker.delta(&topology("b", "y"), &[1], start + SLOW + SLOW).is_none());
    }

    #[test]
    fn hidden_spinners_keep_moving_despite_sampling() {
        // A 10-frame spinner at 100 ms per frame, sampled on the slow path.
        let start = Instant::now();
        let mut tracker = Tracker::default();
        let frame = |ms: u64| json!({"panes":[{"id":2,"tab":11,"title":format!("{} work", (ms / 100) % 10)}],
            "tabs":[{"id":11,"title":"t","sessions":[2]}],"chromiums":[]});
        tracker.reset(&frame(0), start);
        let mut delivered = 0;
        for tick in 1..1000u64 {
            let ms = tick * 8;
            if tracker.delta(&frame(ms), &[], start + Duration::from_millis(ms)).is_some() { delivered += 1; }
        }
        assert!(delivered >= 12, "8 s of a hidden spinner produced only {delivered} deltas");
    }

    #[test]
    fn a_full_topology_resets_the_baseline() {
        let start = Instant::now();
        let mut tracker = Tracker::default();
        tracker.reset(&topology("a", "x"), start);
        tracker.delta(&topology("b", "x"), &[1], start + FAST).unwrap();
        tracker.reset(&topology("c", "x"), start + FAST + FAST);
        assert!(tracker.delta(&topology("c", "x"), &[1], start + SLOW + SLOW).is_none());
        tracker.clear();
        assert!(tracker.delta(&topology("c", "x"), &[1], start + SLOW * 3).is_some(), "a cleared tracker resends everything");
    }
}

