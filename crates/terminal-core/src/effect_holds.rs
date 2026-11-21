//! Effect holds a program asked for through OSC 4723 (or the `effects.*`
//! RPC), kept per terminal exactly as requested. A hold with an id that
//! already exists replaces it.
//!
//! Each hold carries the scope that ends it: the foreground process group
//! that printed it, the pane, or only an explicit release.
//!
//! Clients turn the named effects off while this pane is focused; see
//! `docs/developers/automation-and-extensions/effect-holds.md`.
use graffitty_protocol::osc::{Effects, Hold, Scope};
use serde::Serialize;
use std::collections::BTreeMap;

/// Holds one pane can carry at once; the oldest id is dropped past this.
pub const MAX_HOLDS: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Record {
    #[serde(flatten)]
    pub hold: Hold,
    /// The foreground process group when a `process` hold was placed.
    #[serde(skip)]
    pub pgid: Option<i32>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct EffectHolds {
    records: BTreeMap<String, Record>,
    order: Vec<String>,
}

impl EffectHolds {
    /// Apply what a program said. `pgid` is the pane's foreground process
    /// group now, which bounds a `process` hold. Returns true when the set
    /// changed.
    pub fn apply(&mut self, message: &Effects, pgid: Option<i32>) -> bool {
        match message {
            Effects::Hold(hold) => {
                if hold.validate().is_err() { return false; }
                let record = Record { hold: hold.clone(), pgid: (hold.until == Scope::Process).then_some(pgid).flatten() };
                if self.records.get(&hold.id) == Some(&record) { return false; }
                if self.records.insert(hold.id.clone(), record).is_none() {
                    self.order.push(hold.id.clone());
                    if self.order.len() > MAX_HOLDS {
                        let oldest = self.order.remove(0);
                        self.records.remove(&oldest);
                    }
                }
                true
            }
            Effects::Release(Some(id)) => self.remove(id),
            Effects::Release(None) => self.clear(),
        }
    }

    /// The pane's foreground process group is now `pgid`: `process` holds
    /// placed under a different group end.
    pub fn foreground_changed(&mut self, pgid: Option<i32>) -> bool {
        self.retain(|r| r.hold.until != Scope::Process || r.pgid == pgid)
    }

    /// The terminal was reset or its program tree restarted: only `clear`
    /// holds survive.
    pub fn reset(&mut self) -> bool {
        self.retain(|r| r.hold.until == Scope::Clear)
    }

    /// Remove every hold, whatever its scope.
    pub fn clear(&mut self) -> bool {
        let changed = !self.records.is_empty();
        self.records.clear();
        self.order.clear();
        changed
    }

    pub fn remove(&mut self, id: &str) -> bool {
        let removed = self.records.remove(id).is_some();
        self.order.retain(|known| known != id);
        removed
    }

    pub fn is_empty(&self) -> bool { self.records.is_empty() }

    /// Holds in the order they were placed, for the pane's published state.
    pub fn snapshot(&self) -> Vec<&Record> {
        self.order.iter().filter_map(|id| self.records.get(id)).collect()
    }

    fn retain(&mut self, keep: impl Fn(&Record) -> bool) -> bool {
        let before = self.records.len();
        self.records.retain(|_, r| keep(r));
        self.order.retain(|id| self.records.contains_key(id));
        self.records.len() != before
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hold(id: &str, off: &[&str], until: Scope) -> Effects {
        Effects::Hold(Hold { id: id.into(), off: off.iter().map(|s| s.to_string()).collect(), on: vec![], until })
    }

    #[test]
    fn scopes_end_holds_at_different_moments() {
        let mut holds = EffectHolds::default();
        assert!(holds.apply(&hold("nvim", &["typing"], Scope::Process), Some(10)));
        assert!(holds.apply(&hold("script", &["sparks"], Scope::Pane), Some(10)));
        assert!(holds.apply(&hold("user", &["tab_switch"], Scope::Clear), Some(10)));
        assert!(!holds.apply(&hold("nvim", &["typing"], Scope::Process), Some(10)), "identical report is no change");
        assert_eq!(holds.snapshot().iter().map(|r| r.hold.id.as_str()).collect::<Vec<_>>(), ["nvim", "script", "user"]);
        assert!(!holds.foreground_changed(Some(10)));
        assert!(holds.foreground_changed(Some(11)), "a new foreground group ends process holds");
        assert_eq!(holds.snapshot().len(), 2);
        assert!(holds.reset());
        assert_eq!(holds.snapshot()[0].hold.id, "user");
        assert!(!holds.apply(&Effects::Release(Some("missing".into())), None));
        assert!(holds.apply(&Effects::Release(None), None));
        assert!(holds.is_empty());
    }

    #[test]
    fn replacing_a_hold_keeps_its_place_and_the_set_is_bounded() {
        let mut holds = EffectHolds::default();
        holds.apply(&hold("a", &["sparks"], Scope::Pane), None);
        holds.apply(&hold("b", &["sparks"], Scope::Pane), None);
        assert!(holds.apply(&hold("a", &["camera"], Scope::Pane), None));
        let ids: Vec<_> = holds.snapshot().iter().map(|r| r.hold.id.clone()).collect();
        assert_eq!(ids, ["a", "b"]);
        assert_eq!(holds.snapshot()[0].hold.off, ["camera"]);
        for i in 0..MAX_HOLDS {
            holds.apply(&hold(&format!("h{i}"), &["sparks"], Scope::Pane), None);
        }
        assert_eq!(holds.snapshot().len(), MAX_HOLDS);
        assert!(holds.snapshot().iter().all(|r| r.hold.id != "a" && r.hold.id != "b"));
        assert!(!holds.apply(&hold("bad", &["glitter"], Scope::Pane), None));
        assert!(!holds.apply(&hold("none", &[], Scope::Pane), None));
    }

    #[test]
    fn a_process_hold_without_a_known_group_ends_on_the_first_known_group() {
        let mut holds = EffectHolds::default();
        holds.apply(&hold("x", &["sparks"], Scope::Process), None);
        assert!(!holds.foreground_changed(None));
        assert!(holds.foreground_changed(Some(3)));
    }

    #[test]
    fn snapshot_serializes_the_hold_as_requested() {
        let mut holds = EffectHolds::default();
        holds.apply(&Effects::Hold(Hold { id: "p".into(), off: vec!["sparks".into()], on: vec!["tab_switch".into()], until: Scope::Pane }), Some(1));
        let json = serde_json::to_value(holds.snapshot()).unwrap();
        assert_eq!(json, serde_json::json!([{"id":"p","off":["sparks"],"on":["tab_switch"],"until":"pane"}]));
    }
}
