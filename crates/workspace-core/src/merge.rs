//! Three-way merge of explicit client intent onto the owner's latest revision.
//! New/closed surfaces come only from the owner; a stale layout never revives one.
use crate::{state::TabSettings, tiling::TabLayout};
use anyhow::{Result, ensure};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug)]
pub struct TabPatch {
    before: TabLayout,
    after: TabLayout,
}
impl TabPatch {
    pub fn between(before: &TabLayout, after: &TabLayout) -> Result<Self> {
        before.validate()?;
        after.validate()?;
        let keys = |tab: &TabLayout| tab.windows.iter().map(|w| w.key.clone()).collect::<BTreeSet<_>>();
        ensure!(keys(before) == keys(after), "Wait for the server to confirm surface membership before editing its layout");
        Ok(Self { before: before.clone(), after: after.clone() })
    }
    pub fn is_empty(&self) -> bool { self.before == self.after }
    pub fn rebase(&self, current: &TabLayout) -> Result<TabLayout> {
        let mut result = current.clone();
        macro_rules! field {
            ($name:ident) => { result.$name = rebase_field(&self.before.$name, &self.after.$name, &current.$name, stringify!($name))?; }
        }
        field!(enabled); field!(physics); field!(physics_anchor);
        field!(axis); field!(gap); field!(focused); field!(tiles);
        result.graph_visual.routes = rebase_map(&self.before.graph_visual.routes, &self.after.graph_visual.routes, &current.graph_visual.routes)?;
        result.graph_visual.reroutes = rebase_map(&self.before.graph_visual.reroutes, &self.after.graph_visual.reroutes, &current.graph_visual.reroutes)?;
        for window in &mut result.windows {
            let (Some(before), Some(after)) = (self.before.window(&window.key), self.after.window(&window.key)) else { continue; };
            macro_rules! window_field {
                ($name:ident) => { window.$name = rebase_field(&before.$name, &after.$name, &window.$name, &format!("{} {}", window.key, stringify!($name)))?; }
            }
            window_field!(shown); window_field!(stashed);
            window_field!(graph_floating); window_field!(rect);
        }
        let keys: BTreeSet<_> = result.windows.iter().map(|w| w.key.clone()).collect();
        result.tiles = result.tiles.take().and_then(|tree| tree.prune(&keys));
        if !keys.contains(&result.focused) { result.focused = current.focused.clone(); }
        if result.physics_anchor.as_ref().is_some_and(|key| !keys.contains(key)) {
            result.physics_anchor = None;
        }
        let order = |tab: &TabLayout| tab.windows.iter().filter(|w| keys.contains(&w.key)).map(|w|w.key.clone()).collect::<Vec<_>>();
        let before = order(&self.before);
        let after = order(&self.after);
        if before != after {
            let old_keys: BTreeSet<_> = before.iter().cloned().collect();
            let current_order: Vec<_> = order(current).into_iter().filter(|k|old_keys.contains(k)).collect();
            let order = rebase_field(&before, &after, &current_order, "window stacking order")?;
            result.windows.sort_by_key(|w| order.iter().position(|key|key == &w.key).unwrap_or(order.len()));
        }
        result.validate()?;
        Ok(result)
    }
}

fn rebase_map<T: PartialEq + Clone>(before: &BTreeMap<String, T>, after: &BTreeMap<String, T>, current: &BTreeMap<String, T>) -> Result<BTreeMap<String, T>> {
    let mut result = current.clone();
    for key in before.keys().chain(after.keys()).collect::<BTreeSet<_>>() {
        let value = rebase_field(&before.get(key), &after.get(key), &current.get(key), key)?;
        if let Some(value) = value { result.insert(key.clone(), value.clone()); }
        else { result.remove(key); }
    }
    Ok(result)
}

pub fn rebase_field<T: PartialEq + Clone>(before: &T, after: &T, current: &T, label: &str) -> Result<T> {
    if after == before { return Ok(current.clone()); }
    ensure!(current == before || current == after, "Concurrent workspace edit conflicts with {label}; use the current layout and repeat the action");
    Ok(after.clone())
}
pub fn rebase_settings(before: &TabSettings, after: &TabSettings, current: &TabSettings) -> Result<TabSettings> {
    Ok(TabSettings {
        area: rebase_field(&before.area, &after.area, &current.area, "workspace area")?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tiling::Window;
    fn layout() -> TabLayout {
        TabLayout { focused: "%1".into(), windows: vec![Window::new("%1", [0.,0.,100.,80.]), Window::new("%2", [100.,0.,100.,80.])], ..Default::default() }
    }
    #[test]
    fn graph_moves_merge_by_id_and_conflicting_moves_are_rejected() {
        use crate::tiling::Reroute;
        let mut before = layout();
        for id in ["a", "b"] { before.graph_visual.reroutes.insert(id.into(), Reroute { position: [0., 0.] }); }
        before.graph_visual.routes.insert("%1/out>%2/in".into(), vec!["a".into(), "b".into()]);
        let mut ours = before.clone();
        ours.graph_visual.reroutes.get_mut("a").unwrap().position = [100., 200.];
        let mut theirs = before.clone();
        theirs.graph_visual.reroutes.get_mut("b").unwrap().position = [300., 400.];
        let patch = TabPatch::between(&before, &ours).unwrap();
        let merged = patch.rebase(&theirs).unwrap();
        assert_eq!(merged.graph_visual.reroutes["a"].position, [100., 200.]);
        assert_eq!(merged.graph_visual.reroutes["b"].position, [300., 400.]);
        theirs.graph_visual.reroutes.get_mut("a").unwrap().position = [500., 0.];
        assert!(patch.rebase(&theirs).is_err());
        let encoded = serde_json::to_string(&merged).unwrap();
        assert_eq!(serde_json::from_str::<TabLayout>(&encoded).unwrap(), merged);
    }

    #[test]
    fn two_frontends_moving_different_panes_keep_both_edits() {
        let before = layout();
        let mut ours = before.clone(); ours.windows[0].rect[0] = 500.;
        let patch = TabPatch::between(&before, &ours).unwrap();
        let mut current = before; current.windows[1].rect[1] = 700.;
        let rebased = patch.rebase(&current).unwrap();
        assert_eq!(rebased.windows[0].rect[0], 500.);
        assert_eq!(rebased.windows[1].rect[1], 700.);
    }
    #[test]
    fn overlapping_edits_conflict_and_never_silently_overwrite() {
        let before = layout();
        let mut ours = before.clone(); ours.windows[0].rect[0] = 500.;
        let patch = TabPatch::between(&before, &ours).unwrap();
        let mut current = before; current.windows[0].rect[0] = 300.;
        assert!(patch.rebase(&current).is_err());
        assert!(patch.rebase(&ours).is_ok());
    }
    #[test]
    fn a_close_or_create_during_an_edit_preserves_membership() {
        let before = layout();
        let mut ours = before.clone(); ours.windows[0].rect[0] = 500.;
        let patch = TabPatch::between(&before, &ours).unwrap();
        let mut current = before; current.remove("%1");
        current.windows.push(Window::new("%3", [50.,50.,100.,80.]));
        let result = patch.rebase(&current).unwrap();
        assert!(result.window("%1").is_none());
        assert!(result.window("%3").is_some());
        assert_eq!(result.focused, "%2");
    }
}
