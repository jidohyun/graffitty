//! Authoritative workspace state, independent of a presentation engine or PTY owner.
//!
//! A frontend may preview edits locally, but commits against a revision. Membership
//! is supplied by the session owner and cannot be changed by a layout replacement.
use crate::tiling::{Rect, TabLayout, Window, Workspace};
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub const SCHEMA_VERSION: u32 = 1;
const HISTORY_LIMIT: usize = 64;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TabSettings {
    pub area: Rect,
}
impl Default for TabSettings {
    fn default() -> Self {
        Self { area: [0., 34., 1280., 766.] }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Snapshot {
    pub schema: u32,
    pub revision: u64,
    pub layout: Workspace,
    #[serde(deserialize_with = "crate::tiling::deserialize_tab_map")]
    pub tabs: BTreeMap<u64, TabSettings>,
    pub order: Vec<u64>,
    pub active: Option<u64>,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            schema: SCHEMA_VERSION, revision: 0, layout: Workspace::default(),
            tabs: BTreeMap::new(), order: vec![], active: None,
        }
    }
}
impl Snapshot {
    pub fn validate(&self) -> Result<()> {
        ensure!(self.schema == SCHEMA_VERSION, "Unsupported workspace schema");
        self.layout.validate()?;
        let ids: BTreeSet<_> = self.layout.tabs.keys().copied().collect();
        ensure!(self.tabs.keys().copied().collect::<BTreeSet<_>>() == ids, "Tab metadata differs from layout");
        ensure!(self.order.len() == ids.len() && self.order.iter().copied().collect::<BTreeSet<_>>() == ids, "Invalid tab order");
        ensure!(self.active.is_none_or(|id| ids.contains(&id)), "Unknown active tab");
        for settings in self.tabs.values() {
            ensure!(settings.area.iter().all(|n| n.is_finite() && n.abs() <= 1_000_000.)
                && settings.area[2] > 0. && settings.area[3] > 0., "Invalid workspace area");
        }
        Ok(())
    }

    fn membership(&self) -> BTreeMap<String, u64> {
        self.layout.tabs.iter().flat_map(|(id, tab)| tab.windows.iter().map(move |w| (w.key.clone(), *id))).collect()
    }

    fn reconcile(&mut self, live: &[(u64, Window)]) {
        let ids: BTreeSet<_> = live.iter().map(|(id, _)| *id).collect();
        // Choose in the previous visual order before removing dead tabs.
        let neighbor = self.active.and_then(|active| self.order.iter().position(|id| *id == active))
            .and_then(|index| self.order[..index].iter().rev()
                .chain(self.order[index + 1..].iter()).find(|id| ids.contains(*id)).copied());
        // Membership reconciliation must not overwrite server-owned floating
        // rectangles with an old PTY geometry or a reconnecting client's cache.
        let live: Vec<_> = live.iter().map(|(id, incoming)| {
            let saved = self.layout.tabs.values().find_map(|tab| tab.window(&incoming.key));
            (*id, saved.cloned().unwrap_or_else(|| incoming.clone()))
        }).collect();
        self.layout.reconcile(&live, &ids.iter().copied().collect::<Vec<_>>());
        self.tabs.retain(|id, _| ids.contains(id));
        self.order.retain(|id| ids.contains(id));
        for id in ids {
            self.tabs.entry(id).or_default();
            if !self.order.contains(&id) { self.order.push(id); }
        }
        if self.active.is_none_or(|id| !self.tabs.contains_key(&id)) {
            self.active = neighbor.or_else(|| self.order.first().copied());
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Edit {
    Replace { state: Snapshot },
    Tab { tab: u64, layout: TabLayout, settings: Option<TabSettings> },
    Defaults { enabled: bool },
    Activate { tab: u64 },
    Reorder { tabs: Vec<u64> },
    Undo,
    Redo,
}

#[derive(Clone, Default)]
pub struct Authority {
    state: Snapshot,
    undo: VecDeque<Snapshot>,
    redo: VecDeque<Snapshot>,
}
impl Authority {
    pub fn from_snapshot(state: Snapshot) -> Result<Self> {
        state.validate()?;
        Ok(Self { state, ..Self::default() })
    }
    pub fn snapshot(&self) -> &Snapshot { &self.state }

    /// Session creation, close and regroup are the only way to change membership.
    pub fn reconcile(&mut self, live: &[(u64, Window)]) -> Result<bool> {
        let mut next = self.state.clone();
        next.reconcile(live);
        next.validate()?;
        if next == self.state { return Ok(false); }
        next.revision = self.next_revision()?;
        self.state = next;
        Ok(true)
    }

    /// Membership transaction: move a group with its arranged geometry intact.
    pub fn regroup(&mut self, keys: &BTreeSet<String>, source: u64, destination: u64, preserve: bool) -> Result<()> {
        if source == destination { return Ok(()); }
        let mut next = self.state.clone();
        let from = next.layout.tabs.get_mut(&source).ok_or_else(|| anyhow::anyhow!("Unknown source tab"))?;
        ensure!(keys.iter().all(|key| from.window(key).is_some()), "Moved group must belong to one tab");
        let rectangles = from.arrange(next.tabs[&source].area);
        let mut moved = Vec::new();
        for key in keys {
            let mut window = from.remove(key).unwrap();
            if preserve {
                window.rect = rectangles[key];
                window.graph_floating = true;
                window.stashed = false;
            }
            moved.push(window);
        }
        let enabled = next.layout.default_enabled;
        let to = next.layout.tabs.entry(destination).or_insert_with(|| TabLayout { enabled, ..Default::default() });
        to.windows.extend(moved);
        if preserve { to.physics_anchor = keys.first().cloned(); }
        let live: Vec<_> = next.layout.tabs.iter().flat_map(|(id, tab)| tab.windows.iter().cloned().map(move |w| (*id, w))).collect();
        next.reconcile(&live);
        next.validate()?;
        next.revision = self.next_revision()?;
        self.state = next;
        Ok(())
    }

    pub fn apply(&mut self, expected_revision: u64, edit: Edit) -> Result<&Snapshot> {
        ensure!(expected_revision == self.state.revision, "Workspace revision conflict: expected {}, current {}", expected_revision, self.state.revision);
        let membership = self.state.membership();
        let live: Vec<_> = self.state.layout.tabs.iter().flat_map(|(id, tab)| tab.windows.iter().cloned().map(move |w| (*id, w))).collect();
        let history = matches!(edit, Edit::Undo | Edit::Redo);
        let mut next = match &edit {
            Edit::Replace { state } => state.clone(),
            Edit::Undo => self.undo.back().cloned().ok_or_else(|| anyhow::anyhow!("Nothing to undo"))?,
            Edit::Redo => self.redo.back().cloned().ok_or_else(|| anyhow::anyhow!("Nothing to redo"))?,
            _ => self.state.clone(),
        };
        match &edit {
            Edit::Defaults { enabled } => { next.layout.default_enabled = *enabled; }
            Edit::Tab { tab, layout, settings } => {
                ensure!(next.layout.tabs.contains_key(tab), "Unknown workspace tab");
                next.layout.tabs.insert(*tab, layout.clone());
                if let Some(settings) = settings { next.tabs.insert(*tab, settings.clone()); }
            }
            Edit::Activate { tab } => { next.active = Some(*tab); }
            Edit::Reorder { tabs } => { next.order = tabs.clone(); }
            _ => (),
        }
        if history { next.reconcile(&live); }
        next.validate()?;
        ensure!(next.membership() == membership, "Layout edit cannot create, close or regroup a surface");
        next.revision = self.state.revision;
        if next == self.state {
            // Closing a pane can make a saved edit irrelevant. Consume those
            // history entries so they cannot permanently hide an older edit.
            match edit {
                Edit::Undo => {
                    self.undo.pop_back();
                    if !self.undo.is_empty() { return self.apply(expected_revision, Edit::Undo); }
                }
                Edit::Redo => {
                    self.redo.pop_back();
                    if !self.redo.is_empty() { return self.apply(expected_revision, Edit::Redo); }
                }
                _ => (),
            }
            return Ok(&self.state);
        }
        next.revision = self.next_revision()?;
        match edit {
            Edit::Undo => { self.undo.pop_back(); push_history(&mut self.redo, self.state.clone()); }
            Edit::Redo => { self.redo.pop_back(); push_history(&mut self.undo, self.state.clone()); }
            _ => { push_history(&mut self.undo, self.state.clone()); self.redo.clear(); }
        }
        self.state = next;
        Ok(&self.state)
    }

    fn next_revision(&self) -> Result<u64> {
        self.state.revision.checked_add(1).ok_or_else(|| anyhow::anyhow!("Workspace revision exhausted"))
    }
}
fn push_history(history: &mut VecDeque<Snapshot>, state: Snapshot) {
    if history.len() == HISTORY_LIMIT { history.pop_front(); }
    history.push_back(state);
}

#[cfg(test)]
mod tests {
    use super::*;
    fn live(ids: &[u64]) -> Vec<(u64, Window)> {
        ids.iter().map(|id| (1, Window::new(format!("%{id}"), [24., 60., 800., 500.]))).collect()
    }
    fn move_pane(owner: &mut Authority, x: f32) {
        let mut state = owner.snapshot().clone();
        state.layout.tabs.get_mut(&1).unwrap().windows[0].rect[0] = x;
        owner.apply(state.revision, Edit::Replace { state }).unwrap();
    }
    #[test]
    fn regroup_preserves_group_geometry_into_tiled_tab_and_is_atomic() {
        let mut owner = Authority::default();
        owner.reconcile(&[(1, Window::new("%1", [50., 60., 400., 300.])),
            (1, Window::new("%2", [700., 200., 500., 400.])),
            (1, Window::new("%3", [10., 900., 400., 300.])),
            (2, Window::new("%4", [0., 0., 600., 500.]))]).unwrap();
        let mut state = owner.snapshot().clone();
        state.layout.tabs.get_mut(&2).unwrap().enabled = true;
        owner.apply(state.revision, Edit::Replace { state }).unwrap();
        let before = owner.snapshot().clone();
        let keys = BTreeSet::from(["%1".into(), "%2".into()]);
        owner.regroup(&keys, 1, 2, true).unwrap();
        let after = owner.snapshot();
        let rectangles = after.layout.tabs[&2].clone().arrange(after.tabs[&2].area);
        let originals = before.layout.tabs[&1].clone().arrange(before.tabs[&1].area);
        for key in &keys {
            assert_eq!(rectangles[key], originals[key]);
            assert!(after.layout.tabs[&2].window(key).unwrap().graph_floating);
        }
        assert_eq!(after.layout.tabs[&1].windows.len(), 1);
        let before = owner.snapshot().clone();
        assert!(owner.regroup(&BTreeSet::from(["%1".into(), "%3".into()]), 1, 3, true).is_err());
        assert_eq!(*owner.snapshot(), before);
        owner.regroup(&keys, 2, 3, true).unwrap();
        assert_eq!(owner.snapshot().layout.tabs[&3].clone().arrange(owner.snapshot().tabs[&3].area)["%1"], originals["%1"]);
    }

    #[test]
    fn closing_tabs_selects_a_surviving_neighbor_in_visual_order() {
        let tabs = |ids: &[u64]| ids.iter().map(|id|
            (*id, Window::new(format!("%{id}"), [24., 60., 800., 500.]))
        ).collect::<Vec<_>>();
        for (active, remaining, expected) in [
            (13, vec![8, 4, 2], Some(4)),
            (2, vec![8, 4, 13], Some(13)),
            (8, vec![4, 13, 2], Some(4)),
            (13, vec![8, 2], Some(8)),
            (13, vec![2], Some(2)),
            (13, vec![4, 13, 2], Some(13)),
            (13, vec![], None),
        ] {
            let mut owner = Authority::default();
            owner.reconcile(&tabs(&[8, 4, 13, 2])).unwrap();
            owner.apply(owner.snapshot().revision, Edit::Reorder { tabs: vec![8, 4, 13, 2] }).unwrap();
            owner.apply(owner.snapshot().revision, Edit::Activate { tab: active }).unwrap();
            owner.reconcile(&tabs(&remaining)).unwrap();
            assert_eq!(owner.snapshot().active, expected, "Closed {active}; remaining {remaining:?}");
            assert_eq!(owner.snapshot().order, remaining);
        }
    }

    #[test]
    fn concurrent_frontends_cannot_overwrite_newer_layout() {
        let mut owner = Authority::default();
        owner.reconcile(&live(&[1, 2])).unwrap();
        let old = owner.snapshot().clone();
        move_pane(&mut owner, 400.);
        assert!(owner.apply(old.revision, Edit::Replace { state: old }).is_err());
        assert_eq!(owner.snapshot().layout.tabs[&1].windows[0].rect[0], 400.);
    }

    #[test]
    fn tagged_wire_edits_roundtrip_numeric_tab_maps() {
        let mut owner = Authority::default();
        owner.reconcile(&live(&[1, 2])).unwrap();
        let mut state = owner.snapshot().clone();
        state.layout.tabs.get_mut(&1).unwrap().windows[0].rect[0] = 425.;
        let wire = serde_json::to_value(Edit::Replace { state }).unwrap();
        let edit: Edit = serde_json::from_value(wire).unwrap();
        owner.apply(owner.snapshot().revision, edit).unwrap();
        assert_eq!(owner.snapshot().layout.tabs[&1].windows[0].rect[0], 425.);
    }
    #[test]
    fn reconnect_and_roundtrip_preserve_floating_placement() {
        let mut owner = Authority::default();
        owner.reconcile(&live(&[1])).unwrap();
        let mut state = owner.snapshot().clone();
        state.layout.tabs.get_mut(&1).unwrap().enabled = false;
        owner.apply(state.revision, Edit::Replace { state }).unwrap();
        move_pane(&mut owner, 350.);
        let bytes = serde_json::to_vec(owner.snapshot()).unwrap();
        let mut restored = Authority::from_snapshot(serde_json::from_slice(&bytes).unwrap()).unwrap();
        assert!(!restored.reconcile(&live(&[1])).unwrap());
        assert_eq!(restored.snapshot(), owner.snapshot());
    }
    #[test]
    fn layout_cannot_import_another_workspaces_surface() {
        let mut owner = Authority::default();
        owner.reconcile(&live(&[1])).unwrap();
        let mut state = owner.snapshot().clone();
        state.layout.tabs.get_mut(&1).unwrap().windows.push(Window::new("%99", [0., 0., 80., 50.]));
        assert!(owner.apply(state.revision, Edit::Replace { state }).is_err());
        assert_eq!(owner.snapshot().layout.tabs[&1].windows.len(), 1);
    }
    #[test]
    fn undo_after_close_never_resurrects_a_session() {
        let mut owner = Authority::default();
        owner.reconcile(&live(&[1, 2])).unwrap();
        move_pane(&mut owner, 350.);
        owner.reconcile(&live(&[1])).unwrap();
        let revision = owner.snapshot().revision;
        owner.apply(revision, Edit::Undo).unwrap();
        assert_eq!(owner.snapshot().layout.tabs[&1].windows.len(), 1);
        assert_eq!(owner.snapshot().layout.tabs[&1].windows[0].rect[0], 24.);
        owner.apply(owner.snapshot().revision, Edit::Redo).unwrap();
        assert_eq!(owner.snapshot().layout.tabs[&1].windows[0].rect[0], 350.);
    }
    #[test]
    fn invalid_order_is_atomic_and_noop_does_not_consume_undo() {
        let mut owner = Authority::default();
        owner.reconcile(&live(&[1])).unwrap();
        let revision = owner.snapshot().revision;
        assert!(owner.apply(revision, Edit::Reorder { tabs: vec![1, 1] }).is_err());
        assert_eq!(owner.snapshot().revision, revision);
        owner.apply(revision, Edit::Activate { tab: 1 }).unwrap();
        assert_eq!(owner.snapshot().revision, revision);
        assert!(owner.apply(revision, Edit::Undo).is_err());
    }

    #[test]
    fn defaults_apply_only_to_future_tabs_and_can_be_undone() {
        let mut owner = Authority::default();
        owner.reconcile(&live(&[1])).unwrap();
        owner.apply(owner.snapshot().revision, Edit::Defaults { enabled: false }).unwrap();
        assert!(owner.snapshot().layout.tabs[&1].enabled);
        let mut panes = live(&[1]);
        panes.push((2, Window::new("%2", [24., 60., 800., 500.])));
        owner.reconcile(&panes).unwrap();
        assert!(!owner.snapshot().layout.tabs[&2].enabled);
        owner.apply(owner.snapshot().revision, Edit::Undo).unwrap();
        assert!(owner.snapshot().layout.default_enabled);
        assert!(owner.snapshot().layout.tabs.contains_key(&2));
    }

    #[test]
    fn undo_skips_edits_to_closed_panes() {
        let mut owner = Authority::default();
        owner.reconcile(&live(&[1, 2])).unwrap();
        move_pane(&mut owner, 350.);
        let mut state = owner.snapshot().clone();
        state.layout.tabs.get_mut(&1).unwrap().windows[1].rect[0] = 700.;
        owner.apply(state.revision, Edit::Replace { state }).unwrap();
        owner.reconcile(&live(&[1])).unwrap();
        owner.apply(owner.snapshot().revision, Edit::Undo).unwrap();
        assert_eq!(owner.snapshot().layout.tabs[&1].windows[0].rect[0], 24.);
    }
}
