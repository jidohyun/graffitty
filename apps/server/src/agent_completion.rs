//! Native providers without lifecycle hooks are observed by the owner. Transcript
//! reads run through Workers, never in the PTY actor, and retain process identity.
use graffitty_workspace_core::graph::Graph;
use serde_json::{Value, json};
use std::collections::HashMap;

#[derive(Default)]
pub struct Completions {
    pending: HashMap<String, Pending>,
}
struct Pending {
    workspace: String,
    id: u64,
    identity: Value,
    path: String,
    run_id: String,
    launched: bool,
}
fn identity(node: &Value) -> Value {
    json!([
        node["pid"],
        node["started"],
        node["session_id"],
        node["transcript_path"]
    ])
}
impl Completions {
    pub fn observe(&mut self, workspace: &str, id: u64, before: &Value, after: &Value) {
        let new_checkpoint = before["completion_checkpoint"].is_u64()
            && after["completion_checkpoint"].is_u64()
            && before["completion_checkpoint"] != after["completion_checkpoint"];
        if (before["status"] != "busy" && !new_checkpoint)
            || after["status"] != "idle"
            || matches!(after["observed_turn"]["status"].as_str(), Some("failed" | "interrupted"))
            || after["integrated"] == true
            || identity(before) != identity(after)
            || !["codex", "claude"].contains(&after["provider"].as_str().unwrap_or(""))
        {
            return;
        }
        let Some(path) = after["transcript_path"].as_str().filter(|p| !p.is_empty()) else {
            return;
        };
        if self.pending.len() >= 1024 {
            return;
        }
        self.pending.insert(
            format!("completion:{}", uuid::Uuid::new_v4().simple()),
            Pending {
                workspace: workspace.into(),
                id,
                identity: identity(after),
                path: path.into(),
                run_id: after["run_id"].as_str().unwrap_or("").into(),
                launched: false,
            },
        );
    }
    pub fn requests(&self) -> Vec<(String, Value)> {
        self.pending
            .iter()
            .filter(|(_, p)| !p.launched)
            .map(|(key, p)| (key.clone(), json!({"op":"read","path":p.path})))
            .collect()
    }
    pub fn launched(&mut self, key: &str) {
        if let Some(pending) = self.pending.get_mut(key) {
            pending.launched = true;
        }
    }
    pub fn finish(&mut self, key: &str, result: &Value, graphs: &mut HashMap<String, Graph>) {
        let Some(pending) = self.pending.remove(key) else {
            return;
        };
        if result.get("error").is_some() {
            return;
        }
        let Some(graph) = graphs.get_mut(&pending.workspace) else {
            return;
        };
        let Some(node) = graph.nodes.get(&format!("%{}", pending.id)) else {
            return;
        };
        if identity(node) != pending.identity || node["integrated"] == true {
            return;
        }
        let (Some(text), Some(size)) = (result["last_message"].as_str(), result["size"].as_u64())
        else {
            return;
        };
        let checkpoint = result["completion_checkpoint"].as_u64().unwrap_or(size);
        let _ = graph.discovered_completion(pending.id, text, &checkpoint.to_string(), &pending.run_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Completions, HashMap<String, Graph>, Value) {
        let mut graph = Graph::default();
        for id in [1, 2] {
            graph.add(id, format!("Terminal {id}"));
            graph.dispatch(id, "agent.event", &json!({"provider":"codex","event":"SessionStart","pid":100+id,"session_id":format!("session-{id}")})).unwrap();
        }
        graph
            .dispatch(
                1,
                "graph.connect",
                &json!({"from":"%1","to":"%2","turn_completed":true}),
            )
            .unwrap();
        let node = graph.nodes.get_mut("%1").unwrap();
        node["started"] = json!("stable process start");
        node["transcript_path"] = json!("/private/test/session.jsonl");
        node["status"] = json!("busy");
        let before = node.clone();
        node["status"] = json!("idle");
        (
            Completions::default(),
            HashMap::from([("main".into(), graph)]),
            before,
        )
    }
    #[test]
    fn failed_and_interrupted_discovery_do_not_emit_success_completions() {
        for status in ["failed", "interrupted"] {
            let (mut completions, mut graphs, before) = fixture();
            let node = graphs.get_mut("main").unwrap().nodes.get_mut("%1").unwrap();
            node["observed_turn"] = json!({"id":"turn","status":status});
            completions.observe("main", 1, &before, node);
            assert!(completions.requests().is_empty());
        }
    }

    #[test]
    fn idle_to_idle_checkpoint_detects_a_turn_missed_between_polls() {
        let (mut completions, mut graphs, _) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        graph.nodes.get_mut("%1").unwrap()["completion_checkpoint"] = json!(100);
        let before = graph.nodes["%1"].clone();
        graph.nodes.get_mut("%1").unwrap()["completion_checkpoint"] = json!(200);
        completions.observe("main", 1, &before, &graph.nodes["%1"]);
        let requests = completions.requests();
        assert_eq!(requests.len(), 1);
        completions.finish(&requests[0].0, &json!({"last_message":"fast answer","size":250,"completion_checkpoint":200}), &mut graphs);
        assert_eq!(graphs["main"].queues["%2"][0]["text"], "fast answer");
        let after = graphs["main"].nodes["%1"].clone();
        completions.observe("main", 1, &after, &after);
        assert!(completions.requests().is_empty());
        let mut initial = after.clone();
        initial.as_object_mut().unwrap().remove("completion_checkpoint");
        completions.observe("main", 1, &initial, &after);
        assert!(completions.requests().is_empty(), "First discovery must not replay old turns");
    }
    #[test]
    fn discovered_stop_reads_once_and_preserves_newer_busy_status() {
        let (mut completions, mut graphs, before) = fixture();
        let idle = graphs["main"].nodes["%1"].clone();
        completions.observe("main", 1, &before, &idle);
        completions.observe("main", 1, &idle, &idle);
        let requests = completions.requests();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0].1,
            json!({"op":"read","path":"/private/test/session.jsonl"})
        );
        completions.launched(&requests[0].0);
        assert!(completions.requests().is_empty());
        graphs
            .get_mut("main")
            .unwrap()
            .nodes
            .get_mut("%1")
            .unwrap()["status"] = json!("busy");
        completions.finish(
            &requests[0].0,
            &json!({"last_message":"actual assistant output","size":500}),
            &mut graphs,
        );
        assert_eq!(graphs["main"].nodes["%1"]["status"], "busy");
        assert_eq!(graphs["main"].queues["%2"].len(), 1);
        assert_eq!(
            graphs["main"].queues["%2"][0]["text"],
            "actual assistant output"
        );
        assert_eq!(
            graphs["main"].queues["%2"][0]["type"],
            "turn.completed"
        );
        completions.finish(
            &requests[0].0,
            &json!({"last_message":"actual assistant output","size":500}),
            &mut graphs,
        );
        assert_eq!(graphs["main"].queues["%2"].len(), 1);
    }
    #[test]
    fn replaced_process_or_integrated_hooks_cannot_deliver_stale_discovery() {
        for change in ["pid", "session_id", "transcript_path", "integrated"] {
            let (mut completions, mut graphs, before) = fixture();
            let idle = graphs["main"].nodes["%1"].clone();
            completions.observe("main", 1, &before, &idle);
            let key = completions.requests()[0].0.clone();
            graphs
                .get_mut("main")
                .unwrap()
                .nodes
                .get_mut("%1")
                .unwrap()[change] = if change == "integrated" {
                json!(true)
            } else {
                json!("replacement")
            };
            completions.finish(
                &key,
                &json!({"last_message":"stale","size":500}),
                &mut graphs,
            );
            assert!(
                graphs["main"].queues.values().all(Vec::is_empty),
                "{change}"
            );
        }
        let (mut completions, graphs, before) = fixture();
        let mut idle = graphs["main"].nodes["%1"].clone();
        idle["integrated"] = json!(true);
        completions.observe("main", 1, &before, &idle);
        assert!(completions.requests().is_empty());
    }
    #[test]
    fn delayed_completion_retains_its_causal_run_after_a_new_user_prompt() {
        let (mut completions, mut graphs, _) = fixture();
        let graph = graphs.get_mut("main").unwrap();
        graph
            .dispatch(
                1,
                "graph.connect",
                &json!({"from":"%1","to":"%2","send":true}),
            )
            .unwrap();
        let event = graph
            .dispatch(1, "graph.send", &json!({"to":"%2","text":"start"}))
            .unwrap();
        let run = event["run_id"].as_str().unwrap().to_owned();
        graph.queues.clear();
        graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"UserPromptSubmit","prompt":format!("[Graffitty message; run {run}]\nstart")})).unwrap();
        let before = graph.nodes["%1"].clone();
        graph.nodes.get_mut("%1").unwrap()["status"] = json!("idle");
        completions.observe("main", 1, &before, &graph.nodes["%1"]);
        let key = completions.requests()[0].0.clone();
        graph
            .dispatch(
                1,
                "agent.event",
                &json!({"provider":"codex","event":"UserPromptSubmit","prompt":"new user input"}),
            )
            .unwrap();
        assert!(graph.nodes["%1"].get("run_id").is_none());
        completions.finish(
            &key,
            &json!({"last_message":"prior turn result","size":700}),
            &mut graphs,
        );
        assert_eq!(graphs["main"].queues["%2"][0]["run_id"], run);
        assert_eq!(graphs["main"].nodes["%1"]["status"], "busy");
    }

    #[test]
    fn repeated_answer_in_a_later_checkpoint_is_a_distinct_turn() {
        let (mut completions, mut graphs, before) = fixture();
        for size in [500, 500, 800] {
            let idle = graphs["main"].nodes["%1"].clone();
            completions.observe("main", 1, &before, &idle);
            let key = completions.requests()[0].0.clone();
            completions.finish(
                &key,
                &json!({"last_message":"same answer","size":size}),
                &mut graphs,
            );
        }
        assert_eq!(graphs["main"].queues["%2"].len(), 2);
    }
}
