//! Apply the graph edges requested by `terminal.run --wire`.
//!
//! Each requested wire is an ordinary graph edge. Add a Send edge back
//! from the child only if the lead requests `reply`.
//!
//! A fresh pane starts as a shell node without ports. Hold the request
//! until the agent names its provider through SessionStart, then add the
//! edges. Drop the request if the pane closes first.
use crate::Error;
use graffitty_workspace_core::graph::Graph;
use serde_json::{Value, json};

/// `--wire` names, in the lead's terms. "you" is the lead, "it" the child.
pub const WIRES: [&str; 6] = ["send", "reply", "read", "turn-completed", "waiting", "error"];

/// A lead's declared wiring for a child that has not registered yet.
#[derive(Clone, Debug, PartialEq)]
pub struct Pending {
    pub parent: u64,
    pub wires: Vec<String>,
}

/// The `wire` parameter: a list of names from [`WIRES`], deduplicated in order.
pub fn parse(params: &Value) -> Result<Vec<String>, Error> {
    let list: Vec<String> = match params.get("wire") {
        None | Some(Value::Null) => return Ok(vec![]),
        Some(value) => serde_json::from_value(value.clone())
            .map_err(|_| crate::api::error("invalid_params", "wire must be a list of connection names"))?,
    };
    let mut wires: Vec<String> = Vec::new();
    for name in list {
        if !WIRES.contains(&name.as_str()) {
            return Err(crate::api::error(
                "invalid_params",
                &format!("unknown wire '{name}'; choose from {}", WIRES.join(", ")),
            ));
        }
        if !wires.contains(&name) {
            wires.push(name);
        }
    }
    Ok(wires)
}

/// Whether a node can take part in wiring: it advertises ports, which shells
/// and not-yet-registered agents do not.
pub fn wirable(node: Option<&Value>) -> bool {
    node.and_then(|value| serde_json::from_value::<graffitty_protocol::graph::Node>(value.clone()).ok())
        .is_some_and(|node| !node.ports(true).is_empty() && !node.ports(false).is_empty())
}

/// The `graph.connect` parameters for each wire, lead `parent`, child `child`.
pub fn connections(parent: &str, child: &str, wires: &[String]) -> Vec<(String, Value)> {
    wires
        .iter()
        .map(|wire| {
            let params = match wire.as_str() {
                "send" => json!({"from": parent, "to": child, "send": true}),
                "reply" => json!({"from": child, "to": parent, "send": true}),
                "read" => json!({"from": child, "to": parent, "read": true}),
                "turn-completed" => json!({"from": child, "to": parent, "turn_completed": true}),
                "waiting" => json!({"from": child, "to": parent, "from_port": "waiting"}),
                "error" => json!({"from": child, "to": parent, "from_port": "error"}),
                other => unreachable!("validated wire name {other}"),
            };
            (wire.clone(), params)
        })
        .collect()
}

/// Make the lead's declared edges in `graph`, as the lead. Returns what was
/// applied and what failed with why; a failure of one wire does not stop the rest.
pub fn apply(graph: &mut Graph, parent: u64, child: u64, wires: &[String]) -> Value {
    let (lead, node) = (format!("%{parent}"), format!("%{child}"));
    let mut applied = Vec::new();
    let mut failed = Vec::new();
    for (wire, params) in connections(&lead, &node, wires) {
        match graph.dispatch(parent, "graph.connect", &params) {
            Ok(_) => applied.push(json!(wire)),
            Err(error) => failed.push(json!({"wire": wire, "error": error.to_string()})),
        }
    }
    json!({"applied": applied, "failed": failed})
}

#[cfg(test)]
mod tests {
    use super::*;
    fn session_start(graph: &mut Graph, id: u64, provider: &str) {
        graph.add(id, format!("Terminal {id}"));
        graph
            .dispatch(id, "agent.event", &json!({"provider": provider, "event": "SessionStart", "pid": 100 + id, "session_id": format!("session-{id}")}))
            .unwrap();
    }
    fn edges(graph: &Graph) -> Vec<(String, String, String)> {
        let mut list: Vec<_> = graph
            .edges
            .values()
            .map(|e| (e["from"].as_str().unwrap().to_owned(), e["to"].as_str().unwrap().to_owned(), e["from_port"].as_str().unwrap_or("").to_owned()))
            .collect();
        list.sort();
        list
    }

    #[test]
    fn names_are_validated_and_deduplicated_in_order() {
        assert_eq!(parse(&json!({})).unwrap(), Vec::<String>::new());
        assert_eq!(parse(&json!({"wire": null})).unwrap(), Vec::<String>::new());
        assert_eq!(parse(&json!({"wire": ["send", "turn-completed", "send", "error"]})).unwrap(), ["send", "turn-completed", "error"]);
        let error = parse(&json!({"wire": ["send", "turn_completed"]})).unwrap_err().to_string();
        assert!(error.contains("unknown wire 'turn_completed'"), "{error}");
        assert!(parse(&json!({"wire": "send"})).is_err());
    }

    #[test]
    fn a_fresh_pane_cannot_be_wired_until_its_agent_registers() {
        let mut graph = Graph::default();
        session_start(&mut graph, 1, "claude");
        graph.add(2, "Terminal 2".into());
        assert!(wirable(graph.nodes.get("%1")));
        assert!(!wirable(graph.nodes.get("%2")), "a shell node has no ports");
        let early = apply(&mut graph, 1, 2, &["send".into(), "turn-completed".into()]);
        assert_eq!(early["applied"].as_array().unwrap().len(), 0);
        assert_eq!(early["failed"].as_array().unwrap().len(), 2);
        assert!(graph.edges.is_empty());
    }

    #[test]
    fn every_wire_becomes_the_edge_the_lead_could_have_connected_by_hand() {
        let mut graph = Graph::default();
        session_start(&mut graph, 1, "claude");
        session_start(&mut graph, 2, "codex");
        let wires: Vec<String> = ["send", "read", "turn-completed", "waiting", "error"].map(String::from).into();
        let result = apply(&mut graph, 1, 2, &wires);
        assert_eq!(result["failed"].as_array().unwrap().len(), 0, "{result}");
        assert_eq!(result["applied"].as_array().unwrap().len(), 5);
        assert_eq!(
            edges(&graph),
            [
                ("%1".into(), "%2".into(), "send".into()),
                ("%2".into(), "%1".into(), "error".into()),
                ("%2".into(), "%1".into(), "read".into()),
                ("%2".into(), "%1".into(), "turn_completed".into()),
                ("%2".into(), "%1".into(), "waiting".into()),
            ]
        );
        // can_read(source, target): target may read source's transcript.
        assert!(graph.can_read("%2", "%1"), "read lets the lead read the child's transcript");
        assert!(!graph.can_read("%1", "%2"), "the child was not given Read on the lead");
        // No `reply`: the child cannot message the lead. Asking for it adds exactly that edge.
        assert!(graph.dispatch(2, "graph.send", &json!({"to": "%1", "text": "hi"})).is_err());
        apply(&mut graph, 1, 2, &["reply".into()]);
        assert!(graph.dispatch(2, "graph.send", &json!({"to": "%1", "text": "hi"})).is_ok());
    }
}
