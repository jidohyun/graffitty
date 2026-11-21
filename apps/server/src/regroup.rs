//! Validate a complete membership change before changing any live session.
use crate::{Error, Server};
use serde_json::{Value, json};
use std::collections::VecDeque;

#[derive(Default)]
pub struct RetiredTabs(VecDeque<(u64, String, Option<String>)>);
impl RetiredTabs {
    fn remember(&mut self, tab: u64, workspace: &str, title: Option<String>) {
        self.0.retain(|entry| entry.0 != tab);
        self.0.push_back((tab, workspace.into(), title));
        while self.0.len() > 4096 {
            self.0.pop_front();
        }
    }
    fn allows(&self, tab: u64, workspace: &str) -> bool {
        self.0
            .iter()
            .any(|entry| entry.0 == tab && entry.1 == workspace)
    }
    fn revive(&mut self, tab: u64, workspace: &str) -> Option<Option<String>> {
        let index = self
            .0
            .iter()
            .position(|entry| entry.0 == tab && entry.1 == workspace)?;
        Some(self.0.remove(index)?.2)
    }
}

#[derive(Clone, Copy)]
struct Member<'a> {
    id: u64,
    tab: u64,
    workspace: &'a str,
    owner: Option<u64>,
}
#[derive(Debug, PartialEq)]
struct Plan {
    terminal: Option<u64>,
    chromiums: Vec<u64>,
    source: u64,
    destination: u64,
    allocated: bool,
}
impl Plan {
    fn source_empty(&self, terminals: &[Member<'_>], chromiums: &[Member<'_>]) -> bool {
        self.source != self.destination
            && !terminals
                .iter()
                .any(|m| m.tab == self.source && Some(m.id) != self.terminal)
            && !chromiums
                .iter()
                .any(|m| m.tab == self.source && !self.chromiums.contains(&m.id))
    }
}
pub fn owned_chromium_ids(owner: u64, chromiums: impl Iterator<Item = (u64, u64)>) -> Vec<u64> {
    let chromiums:Vec<_>=chromiums.collect();
    let mut owned=Vec::new();
    loop {
        let next:Vec<_>=chromiums.iter().filter_map(|(id,parent)|
            (*id!=owner && !owned.contains(id) && (*parent==owner || owned.contains(parent))).then_some(*id)).collect();
        if next.is_empty() {break}
        owned.extend(next);
    }
    owned
}
fn plan(
    workspace: &str,
    surface: &str,
    target: Option<u64>,
    next: u64,
    terminals: &[Member<'_>],
    chromiums: &[Member<'_>],
    restorable: bool,
) -> Result<Plan, Error> {
    let id = graffitty_workspace_core::pane_id::parse(surface).ok_or("Expected %N")?;
    let terminal = terminals.iter().find(|m| m.id == id);
    let member = terminal.or_else(|| chromiums.iter().find(|m| m.id == id))
    .filter(|m| m.workspace == workspace)
    .ok_or("Surface is not in this workspace")?;
    if member.owner.is_some_and(|owner| {
        !terminals.iter().chain(chromiums)
            .any(|m| m.id == owner && m.workspace == workspace)
    }) {
        return Err("Chromium owner is not in this workspace".into());
    }
    let destination = if let Some(target) = target {
        if !terminals
            .iter()
            .chain(chromiums)
            .any(|m| m.tab == target && m.workspace == workspace)
        {
            if !restorable || terminals.iter().chain(chromiums).any(|m| m.tab == target) {
                return Err(
                    "Destination tab is not in this workspace or is no longer restorable".into(),
                );
            }
        }
        target
    } else {
        next.checked_add(1).ok_or("Server tab identity exhausted")?;
        next
    };
    let owned = if terminal.is_none() {
        vec![id]
    } else {
        chromiums
            .iter()
            .filter(|b| b.owner == Some(id) && b.workspace == workspace && b.tab == member.tab)
            .map(|b| b.id)
            .collect()
    };
    Ok(Plan {
        terminal: (terminal.is_some()).then_some(id),
        chromiums: owned,
        source: member.tab,
        destination,
        allocated: target.is_none(),
    })
}

/// All visible relationships are undirected for membership, regardless of
/// message direction or which side owns the associated process.
pub fn connection_edges(server: &Server, workspace: &str) -> Vec<Value> {
    let mut edges: Vec<_> = server.graphs.get(workspace)
        .into_iter().flat_map(|g| g.edges.values().cloned()).collect();
    for chromium in server.chromiums.values().filter(|b| b.workspace == workspace && b.owner != b.id) {
        edges.push(json!({"from":format!("%{}", chromium.owner),"to":format!("%{}", chromium.id),"kind":"chromium"}));
    }
    for session in server.sessions.values().filter(|s| s.workspace == workspace) {
        if let Some(owner) = crate::filetree::connection_owner(server, session.id) {
            edges.push(json!({"from":format!("%{owner}"),"to":format!("%{}", session.id),"kind":"filetree"}));
        }
        if let Some(parent) = session.spawned_by.filter(|parent| server.sessions.get(parent).is_some_and(|p| p.workspace == workspace)) {
            edges.push(json!({"from":format!("%{parent}"),"to":format!("%{}", session.id),"kind":"spawned"}));
        }
    }
    edges
}

pub fn validate_association(server: &Server, from: u64, to: u64) -> Result<(), Error> {
    let membership = |id| server.sessions.get(&id).map(|s| (&s.workspace, s.tab))
        .or_else(|| server.chromiums.get(&id).map(|b| (&b.workspace, b.tab)));
    match (membership(from), membership(to)) {
        (Some(a), Some(b)) if a == b => Ok(()),
        _ => Err("Connections must stay within one tab".into()),
    }
}

pub fn validate_connection(server: &Server, workspace: &str, params: &Value) -> Result<(), Error> {
    let tab = |key: &Value| key.as_str()
        .and_then(graffitty_workspace_core::pane_id::parse)
        .and_then(|id| server.sessions.get(&id))
        .filter(|s| s.workspace == workspace).map(|s| s.tab);
    validate_tabs(tab(&params["from"]), tab(&params["to"]))
}

fn validate_tabs(from: Option<u64>, to: Option<u64>) -> Result<(), Error> {
    match (from, to) {
        (Some(a), Some(b)) if a == b => Ok(()),
        (Some(_), Some(_)) => Err("Graph connections must stay within one tab; move the connected group first".into()),
        _ => Err("Choose two live nodes in this workspace".into()),
    }
}

pub fn apply(
    server: &mut Server,
    workspace: &str,
    surface: &str,
    target: Option<u64>,
    restore: bool,
    browser_only: bool,
    saved_tab: Option<u64>,
) -> Result<Value, Error> {
    if browser_only && !server.chromiums.values().any(|b| b.workspace == workspace && surface == format!("%{}", b.id)) {
        return Err("Moving a surface alone requires a Chromium pane".into());
    }
    let terminals: Vec<_> = server
        .sessions
        .values()
        .map(|s| Member {
            id: s.id,
            tab: s.tab,
            workspace: &s.workspace,
            owner: None,
        })
        .collect();
    let chromiums: Vec<_> = server
        .chromiums
        .values()
        .map(|b| Member {
            id: b.id,
            tab: b.tab,
            workspace: &b.workspace,
            owner: (b.owner != b.id).then_some(b.owner),
        })
        .collect();
    let mut plan = plan(
        workspace,
        surface,
        target,
        server.tab_identity(saved_tab, server.next, server.next),
        &terminals,
        &chromiums,
        restore && target.is_some_and(|tab| server.retired_tabs.allows(tab, workspace)),
    )?;
    let edges = connection_edges(server, workspace);
    // An explicit browser-only move separates presentation from lifetime.
    // Ordinary drags still carry every relationship in the current tab.
    let membership = |key: &Value| key.as_str()
        .and_then(graffitty_workspace_core::pane_id::parse)
        .and_then(|id| terminals.iter().chain(&chromiums).find(|m| m.id == id))
        .map(|m| m.tab);
    let moving = graffitty_workspace_core::graph::connected_component(surface, edges.iter().filter(|edge| {
        edge["kind"] != "chromium" || (
            !(browser_only && edge["to"] == surface)
            && membership(&edge["from"]) == membership(&edge["to"])
        )
    }));
    if moving.iter().any(|key| {
        let id = graffitty_workspace_core::pane_id::parse(key);
        !terminals.iter().chain(&chromiums).any(|m| Some(m.id) == id && m.workspace == workspace && m.tab == plan.source)
    }) { return Err("Connected group spans tabs; repair its connections before moving".into()); }
    let companions: Vec<_> = terminals.iter().filter(|m| Some(m.id) != plan.terminal && moving.contains(&format!("%{}", m.id))).map(|m| m.id).collect();
    plan.chromiums = chromiums.iter().filter(|m| moving.contains(&format!("%{}", m.id))).map(|m| m.id).collect();
    let remaining: Vec<_> = terminals.iter().copied().filter(|m| !companions.contains(&m.id)).collect();
    let empty = plan.source_empty(&remaining, &chromiums);
    let preserve = moving.len() > 1;
    server.workspace_state.regroup(workspace, &moving.into_iter().collect(), plan.source, plan.destination, preserve)?;
    if plan.allocated {
        server.identities_taken(&[plan.destination]);
    }
    if let Some(id) = plan.terminal {
        server.sessions.get_mut(&id).unwrap().tab = plan.destination;
    }
    for id in &companions {
        server.sessions.get_mut(id).unwrap().tab = plan.destination;
    }
    for id in &plan.chromiums {
        server.chromiums.get_mut(id).unwrap().tab = plan.destination;
    }
    if empty {
        let title = server.tab_titles.remove(&plan.source);
        server.retired_tabs.remember(plan.source, workspace, title);
    }
    if let Some(title) = server
        .retired_tabs
        .revive(plan.destination, workspace)
        .flatten()
    {
        server.tab_titles.insert(plan.destination, title);
    }
    Ok(
        json!({"surface":surface,"tab":plan.destination,"previous_tab":plan.source,"source_empty":empty,"chromiums":plan.chromiums,"companions":companions}),
    )
}

#[cfg(test)]
mod tests {
    #[test]
    fn terminal_cleanup_includes_detached_chromium_windows() {
        let chromiums = [(10, 1), (11, 10), (12, 10), (20, 2)];
        assert_eq!(super::owned_chromium_ids(1, chromiums.into_iter()), vec![10, 11, 12]);
        assert_eq!(super::owned_chromium_ids(10, chromiums.into_iter()), vec![11, 12]);
    }
    use super::*;
    #[test]
    fn connections_require_two_live_nodes_in_the_same_tab() {
        assert!(validate_tabs(Some(1), Some(1)).is_ok());
        for (from, to) in [(Some(1), Some(2)), (Some(2), Some(1)), (None, Some(1)), (Some(1), None), (None, None)] {
            assert!(validate_tabs(from, to).is_err());
        }
    }

    #[test]
    fn regroup_is_scoped_and_does_not_reassign_chromium_ownership() {
        let terminals = [
            Member {
                id: 1,
                tab: 1,
                workspace: "main",
                owner: None,
            },
            Member {
                id: 2,
                tab: 2,
                workspace: "main",
                owner: None,
            },
            Member {
                id: 3,
                tab: 3,
                workspace: "other",
                owner: None,
            },
        ];
        let chromiums = [
            Member {
                id: 10,
                tab: 1,
                workspace: "main",
                owner: Some(1),
            },
            Member {
                id: 11,
                tab: 2,
                workspace: "main",
                owner: Some(1),
            },
        ];
        assert_eq!(
            plan(
                "main",
                "%1",
                Some(2),
                20,
                &terminals,
                &chromiums,
                false
            )
            .unwrap(),
            Plan {
                terminal: Some(1),
                chromiums: vec![10],
                source: 1,
                destination: 2,
                allocated: false
            }
        );
        assert!(
            plan(
                "main",
                "%1",
                Some(3),
                20,
                &terminals,
                &chromiums,
                false
            )
            .is_err()
        );
        assert!(
            plan(
                "other",
                "%1",
                Some(3),
                20,
                &terminals,
                &chromiums,
                false
            )
            .is_err()
        );
        assert_eq!(chromiums[0].owner, Some(1));
        let moved = plan(
            "main",
            "%1",
            Some(2),
            20,
            &terminals,
            &chromiums,
            false,
        )
        .unwrap();
        assert!(moved.source_empty(&terminals, &chromiums));
        let chromium = plan("main", "%10", None, 20, &terminals, &chromiums, false).unwrap();
        assert_eq!(
            chromium,
            Plan {
                terminal: None,
                chromiums: vec![10],
                source: 1,
                destination: 20,
                allocated: true
            }
        );
    }
    #[test]
    fn chromium_only_destination_is_valid_but_foreign_owner_is_not() {
        let terminals = [Member {
            id: 1,
            tab: 1,
            workspace: "main",
            owner: None,
        }];
        let chromiums = [
            Member {
                id: 10,
                tab: 20,
                workspace: "main",
                owner: Some(1),
            },
            Member {
                id: 11,
                tab: 30,
                workspace: "main",
                owner: Some(99),
            },
        ];
        assert!(
            plan(
                "main",
                "%1",
                Some(20),
                40,
                &terminals,
                &chromiums,
                false
            )
            .is_ok()
        );
        assert!(plan("main", "%11", None, 40, &terminals, &chromiums, false).is_err());
        let moved = plan(
            "main",
            "%10",
            Some(1),
            40,
            &terminals,
            &chromiums,
            false,
        )
        .unwrap();
        assert!(moved.source_empty(&terminals, &chromiums));
        // Ownership, rather than current tab placement, controls final cleanup.
        assert_eq!(
            owned_chromium_ids(1, chromiums.iter().map(|b| (b.id, b.owner.unwrap()))),
            vec![10]
        );
    }
    #[test]
    fn retired_tabs_restore_only_their_original_workspace_and_expire_oldest() {
        let mut retired = RetiredTabs::default();
        retired.remember(7, "main", Some("Remember me".into()));
        assert!(!retired.allows(7, "other"));
        assert!(retired.revive(7, "other").is_none());
        assert_eq!(retired.revive(7, "main"), Some(Some("Remember me".into())));
        assert!(!retired.allows(7, "main"));
        for tab in 0..4097 {
            retired.remember(tab, "main", None);
        }
        assert!(!retired.allows(0, "main"));
        assert!(retired.allows(1, "main"));
        let terminals = [Member {
            id: 1,
            tab: 1,
            workspace: "main",
            owner: None,
        }];
        assert!(plan("main", "%1", Some(8), 50, &terminals, &[], false).is_err());
        assert!(
            plan(
                "main",
                "%1",
                Some(8),
                50,
                &terminals,
                &[],
                retired.allows(8, "main")
            )
            .is_ok()
        );
        let occupied = [
            Member {
                id: 1,
                tab: 1,
                workspace: "main",
                owner: None,
            },
            Member {
                id: 8,
                tab: 8,
                workspace: "other",
                owner: None,
            },
        ];
        assert!(plan("main", "%1", Some(8), 50, &occupied, &[], true).is_err());
    }
}
