//! Build the trees shown in the Agents list. Child rows sit under a parent
//! with tree lines and can be folded together. The UI follows herdr-app's
//! `defaults/mods/agents/main.js` at e77f112 (Apache-2.0).
//!
//! - Group panes in the same tab by agent graph wires, `gft pane run` parent
//!   links, Chromium ownership, and filetree ownership.
//! - Use the first agent in graph order as the parent row. If the agents
//!   form a cycle, use the leftmost agent.
//! - Omit groups without agents.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};

pub const PROVIDERS: [&str; 4] = ["pi", "claude", "codex", "opencode"];

#[derive(Clone, Debug, Deserialize)]
pub struct Node {
    pub key: String,
    /// agent, terminal, chromium or filetree.
    pub kind: String,
    #[serde(default)]
    pub provider: String,
    #[serde(default)]
    pub title: String,
    /// Foreground program identifier for terminals (`python3`, `node`).
    #[serde(default)]
    pub app: String,
    #[serde(default)]
    pub status: String,
    /// Workspace rectangle [x, y, width, height], used for left-most ties.
    #[serde(default)]
    pub rect: [f32; 4],
}
#[derive(Clone, Debug, Deserialize)]
pub struct Edge {
    pub from: String,
    pub to: String,
    /// graph, spawned, chromium or filetree; membership ignores it.
    #[serde(default)]
    pub kind: String,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Row {
    pub key: String,
    pub kind: String,
    pub provider: String,
    pub title: String,
    /// What to draw: a provider name, `terminal`, `python`, `chromium` or `filetree`.
    pub icon: String,
    pub status: String,
    pub parent: String,
    /// One mark per depth level, drawn before the row: `│`, `├`, `└` or a space.
    pub lines: Vec<String>,
}
#[derive(Clone, Debug, Serialize, PartialEq)]
pub struct Tree {
    pub root: String,
    pub rows: Vec<Row>,
}

/// The glyph for a pane, as herdr's program table names it.
pub fn icon(node: &Node) -> String {
    match node.kind.as_str() {
        "agent" => node.provider.clone(),
        "chromium" => "chromium".into(),
        "filetree" => "filetree".into(),
        _ => {
            let app = node.app.rsplit(['/', '\\']).next().unwrap_or("").trim_end_matches(".exe");
            if matches!(app, "python" | "python3" | "ipython" | "pip" | "pip3" | "uv" | "uvx")
                || app.starts_with("python3.") {
                "python".into()
            } else {
                "terminal".into()
            }
        }
    }
}

fn leftmost<'a>(nodes: &'a BTreeMap<&str, &Node>, keys: impl Iterator<Item = &'a str>) -> Option<&'a str> {
    keys.min_by(|a, b| {
        let (ra, rb) = (nodes[a].rect, nodes[b].rect);
        ra[0].total_cmp(&rb[0]).then(ra[1].total_cmp(&rb[1])).then(a.cmp(b))
    })
}

/// Everything reachable from `start` along edge direction.
fn reaches(start: &str, out: &HashMap<&str, Vec<&str>>) -> HashSet<String> {
    let mut seen = HashSet::new();
    let mut queue = VecDeque::from([start]);
    while let Some(key) = queue.pop_front() {
        for next in out.get(key).into_iter().flatten() {
            if *next != start && seen.insert((*next).to_owned()) {
                queue.push_back(next);
            }
        }
    }
    seen
}

pub fn trees(nodes: &[Node], edges: &[Edge]) -> Vec<Tree> {
    let by_key: BTreeMap<&str, &Node> = nodes.iter().map(|n| (n.key.as_str(), n)).collect();
    let mut out: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut neighbors: HashMap<&str, BTreeSet<&str>> = HashMap::new();
    for edge in edges {
        let (Some(from), Some(to)) = (by_key.get_key_value(edge.from.as_str()), by_key.get_key_value(edge.to.as_str())) else { continue };
        if from.0 == to.0 { continue; }
        out.entry(from.0).or_default().push(to.0);
        neighbors.entry(from.0).or_default().insert(to.0);
        neighbors.entry(to.0).or_default().insert(from.0);
    }
    // Connected groups, each visited once, in stable key order.
    let mut grouped: HashSet<&str> = HashSet::new();
    let mut result = Vec::new();
    for start in by_key.keys() {
        if grouped.contains(start) { continue; }
        let mut group: BTreeSet<&str> = BTreeSet::new();
        let mut queue = VecDeque::from([*start]);
        while let Some(key) = queue.pop_front() {
            if !group.insert(key) { continue; }
            for next in neighbors.get(key).into_iter().flatten() { queue.push_back(next); }
        }
        grouped.extend(group.iter().copied());
        let agents: Vec<&str> = group.iter().copied().filter(|k| by_key[k].kind == "agent").collect();
        if agents.is_empty() { continue; }
        // The first agent: no other agent reaches it. A cycle has none, so take the left-most.
        let reached: HashMap<&str, HashSet<String>> = agents.iter().map(|a| (*a, reaches(a, &out))).collect();
        let firsts: Vec<&str> = agents.iter().copied()
            .filter(|a| !agents.iter().any(|other| other != a && reached[other].contains(*a)))
            .collect();
        let root = leftmost(&by_key, if firsts.is_empty() { agents.iter().copied() } else { firsts.iter().copied() }).unwrap();
        let mut rows = Vec::new();
        let mut visited: HashSet<&str> = HashSet::from([root]);
        descend(root, &by_key, &out, &neighbors, &mut visited, &[], &mut rows);
        result.push(Tree { root: root.to_owned(), rows });
    }
    result
}

/// Children: panes this one points at first, then anything else attached to
/// it, each in reading order (left to right, then top to bottom).
fn descend<'a>(
    key: &'a str,
    nodes: &BTreeMap<&'a str, &'a Node>,
    out: &HashMap<&'a str, Vec<&'a str>>,
    neighbors: &HashMap<&'a str, BTreeSet<&'a str>>,
    visited: &mut HashSet<&'a str>,
    lead: &[String],
    rows: &mut Vec<Row>,
) {
    let mut children: Vec<&str> = Vec::new();
    let mut order = |candidates: Vec<&'a str>| {
        // A child linked twice (a `gft pane run` parent link and a graph wire) is one child.
        let mut fresh: Vec<&str> = candidates.into_iter().filter(|c| !visited.contains(c) && !children.contains(c)).collect();
        fresh.sort_unstable();
        fresh.dedup();
        fresh.sort_by(|a, b| {
            let (ra, rb) = (nodes[a].rect, nodes[b].rect);
            ra[0].total_cmp(&rb[0]).then(ra[1].total_cmp(&rb[1])).then(a.cmp(b))
        });
        children.extend(fresh);
    };
    order(out.get(key).cloned().unwrap_or_default());
    order(neighbors.get(key).map(|n| n.iter().copied().collect()).unwrap_or_default());
    for child in &children { visited.insert(child); }
    let count = children.len();
    for (index, child) in children.into_iter().enumerate() {
        let last = index + 1 == count;
        let node = nodes[child];
        let mut lines = lead.to_vec();
        lines.push(if last { "└" } else { "├" }.into());
        rows.push(Row {
            key: child.to_owned(), kind: node.kind.clone(), provider: node.provider.clone(),
            title: node.title.clone(), icon: icon(node), status: node.status.clone(),
            parent: key.to_owned(), lines,
        });
        let mut next_lead = lead.to_vec();
        next_lead.push(if last { " " } else { "│" }.into());
        descend(child, nodes, out, neighbors, visited, &next_lead, rows);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn node(key: &str, kind: &str, x: f32) -> Node {
        Node { key: key.into(), kind: kind.into(), provider: if kind == "agent" { "pi".into() } else { String::new() },
            title: key.into(), app: String::new(), status: String::new(), rect: [x, 0., 100., 100.] }
    }
    fn edge(from: &str, to: &str, kind: &str) -> Edge { Edge { from: from.into(), to: to.into(), kind: kind.into() } }

    #[test]
    fn spawned_programs_chromium_and_filetree_hang_under_their_agent() {
        let mut py = node("%2", "terminal", 300.);
        py.app = "python3".into();
        let nodes = [node("%1", "agent", 0.), py, node("%3", "chromium", 500.), node("%4", "filetree", -100.), node("%5", "terminal", 900.)];
        let edges = [edge("%1", "%2", "spawned"), edge("%1", "%3", "chromium"), edge("%1", "%4", "filetree"), edge("%2", "%5", "spawned")];
        let trees = trees(&nodes, &edges);
        assert_eq!(trees.len(), 1);
        assert_eq!(trees[0].root, "%1");
        let keys: Vec<_> = trees[0].rows.iter().map(|r| r.key.as_str()).collect();
        assert_eq!(keys, ["%4", "%2", "%5", "%3"], "children read left to right; grandchildren follow their parent");
        let icons: Vec<_> = trees[0].rows.iter().map(|r| r.icon.as_str()).collect();
        assert_eq!(icons, ["filetree", "python", "terminal", "chromium"]);
        assert_eq!(trees[0].rows[1].lines, ["├"]);
        assert_eq!(trees[0].rows[2].lines, ["│", "└"]);
        assert_eq!(trees[0].rows[3].lines, ["└"]);
    }

    #[test]
    fn the_first_agent_in_graph_order_leads_and_cycles_fall_back_to_the_leftmost() {
        let nodes = [node("%1", "agent", 800.), node("%2", "agent", 0.), node("%3", "agent", 400.)];
        // %1 → %2 → %3: %1 is first despite sitting right-most.
        let chain = [edge("%1", "%2", "graph"), edge("%2", "%3", "graph")];
        let trees_chain = trees(&nodes, &chain);
        assert_eq!(trees_chain[0].root, "%1");
        assert_eq!(trees_chain[0].rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(), ["%2", "%3"]);
        // A cycle has no first agent: the left-most one leads.
        let cycle = [edge("%1", "%2", "graph"), edge("%2", "%3", "graph"), edge("%3", "%1", "graph")];
        assert_eq!(trees(&nodes, &cycle)[0].root, "%2");
        // A plain terminal pointing at an agent is never the top row.
        let nodes = [node("%1", "terminal", 0.), node("%2", "agent", 100.)];
        let trees_shell = trees(&nodes, &[edge("%1", "%2", "graph")]);
        assert_eq!(trees_shell[0].root, "%2");
        assert_eq!(trees_shell[0].rows[0].key, "%1");
    }

    #[test]
    fn a_child_linked_by_several_edges_is_listed_once() {
        let nodes = [node("%1", "agent", 0.), node("%2", "agent", 100.), node("%3", "terminal", 200.)];
        let edges = [edge("%1", "%2", "spawned"), edge("%1", "%2", "graph"), edge("%1", "%3", "spawned"),
            edge("%1", "%3", "graph"), edge("%3", "%1", "graph")];
        let trees = trees(&nodes, &edges);
        assert_eq!(trees[0].rows.iter().map(|r| r.key.as_str()).collect::<Vec<_>>(), ["%2", "%3"]);
        assert_eq!(trees[0].rows[1].lines, ["└"]);
    }

    #[test]
    fn groups_without_agents_are_skipped_and_agents_stay_separate() {
        let nodes = [node("%1", "terminal", 0.), node("%2", "chromium", 100.), node("%3", "agent", 200.), node("%4", "agent", 300.)];
        let trees = trees(&nodes, &[edge("%1", "%2", "chromium")]);
        assert_eq!(trees.iter().map(|t| t.root.as_str()).collect::<Vec<_>>(), ["%3", "%4"]);
        assert!(trees.iter().all(|t| t.rows.is_empty()));
    }
}
