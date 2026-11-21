//! Policy regressions migrated from the removed Godot graph executor.
use super::*;

#[path = "graph_lifecycle_tests.rs"]
mod lifecycle;

#[test]
fn provider_inbox_uses_real_ports_queue_runs_titles_and_completions() {
    let mut graph = Graph::default();
    for (id, provider) in [(1, "codex"), (2, "claude"), (3, "codex")] {
        graph.add(id, "Terminal".into());
        graph.dispatch(id, "agent.event", &json!({"provider":provider,"event":"SessionStart","transport":"inbox","pid":id,"session_id":format!("session-{id}"),"title":provider,"integrated":true})).unwrap();
    }
    graph.dispatch(1, "graph.connect", &json!({"from":"%1","to":"%2","send":true})).unwrap();
    graph.dispatch(2, "graph.connect", &json!({"from":"%2","to":"%3","turn_completed":true})).unwrap();
    for prompt in ["First question", "Second question"] {
        graph.dispatch(1, "graph.send", &json!({"to":"%2","text":prompt})).unwrap();
        let event = graph.dispatch(2, "graph.take", &json!({})).unwrap()["events"][0].clone();
        assert_eq!(event["text"], prompt);
        graph.dispatch(2, "graph.ack", &json!({"event_id":event["event_id"],"status":"delivered"})).unwrap();
        let header = format!("[Graffitty message from %1; event {}; run {}]\n{prompt}", string(&event,"event_id"), string(&event,"run_id"));
        graph.dispatch(2, "agent.event", &json!({"provider":"claude","event":"UserPromptSubmit","prompt":header,"title":"First question"})).unwrap();
        assert_eq!(graph.nodes["%2"]["status"], "busy");
        graph.observe_agent(2, &json!({"provider":"shell","status":"offline","pid":99}));
        assert_eq!(graph.nodes["%2"]["provider"], "claude");
        assert_eq!(graph.nodes["%2"]["status"], "busy");
        graph.dispatch(2, "agent.event", &json!({"provider":"claude","event":"Stop","session_id":"session-2","text":"Same reply"})).unwrap();
        let outputs = &graph.queues["%3"];
        assert_eq!(outputs.last().unwrap()["run_id"], event["run_id"]);
        assert_eq!(graph.nodes["%2"]["status"], "idle");
    }
    assert_eq!(graph.queues["%3"].len(), 2);
    let node = &graph.snapshot()["nodes"][1];
    assert_eq!(node["provider"], "claude");
    assert_eq!(node["manifest"]["name"], "First question");
    assert_eq!(node["manifest"]["outputs"].as_array().unwrap().len(), 5);
    assert!(node.get("heartbeat_at").is_none());
}

#[test]
fn heartbeat_recovers_timed_out_status_without_lifecycle_side_effects() {
    for (event, status) in [("Ready", "idle"), ("UserPromptSubmit", "busy"), ("AwaitingInput", "waiting")] {
        let mut graph = Graph::default();
        graph.add(1, "Agent".into());
        graph.dispatch(1, "agent.event", &json!({"provider":"pi","event":"SessionStart","transport":"inbox","pid":1,"session_id":"session"})).unwrap();
        graph.dispatch(1, "agent.event", &json!({"provider":"pi","event":event})).unwrap();
        for _ in 0..2 {
            let before = graph.notification_revision();
            graph.nodes.get_mut("%1").unwrap()["heartbeat_at"] = json!(now() - 16.0);
            graph.expire();
            assert_eq!(graph.nodes["%1"]["status"], "offline");
            assert_ne!(graph.notification_revision(), before);
            graph.expire(); // Repeated expiry must not overwrite the saved status.
            let offline = graph.notification_revision();
            graph.dispatch(1, "agent.heartbeat", &json!({})).unwrap();
            assert_eq!(graph.nodes["%1"]["status"], status);
            assert_ne!(graph.notification_revision(), offline);
            assert_eq!(graph.nodes["%1"]["session_id"], "session");
            assert!(graph.queues.values().all(Vec::is_empty));
            let recovered = graph.notification_revision();
            graph.dispatch(1, "agent.heartbeat", &json!({})).unwrap();
            assert_eq!(graph.notification_revision(), recovered);
        }
    }
}

#[test]
fn lifecycle_event_supersedes_heartbeat_timeout() {
    for (event, status) in [("SessionEnd", "offline"), ("Ready", "idle")] {
        let mut graph = Graph::default();
        graph.add(1, "Agent".into());
        graph.dispatch(1, "agent.event", &json!({"provider":"pi","event":"SessionStart","transport":"inbox"})).unwrap();
        graph.dispatch(1, "agent.event", &json!({"provider":"pi","event":"UserPromptSubmit"})).unwrap();
        graph.nodes.get_mut("%1").unwrap()["heartbeat_at"] = json!(now() - 16.0);
        graph.expire();
        graph.dispatch(1, "agent.event", &json!({"provider":"pi","event":event})).unwrap();
        graph.dispatch(1, "agent.heartbeat", &json!({})).unwrap();
        assert_eq!(graph.nodes["%1"]["status"], status);
        assert!(graph.timed_out_status.is_empty());
    }
}

#[test]
fn heartbeat_timeout_recovery_moves_with_pane() {
    let mut graph = Graph::default();
    let mut target = Graph::default();
    graph.add(1, "Agent".into());
    graph.dispatch(1, "agent.event", &json!({"provider":"pi","event":"SessionStart","transport":"inbox"})).unwrap();
    graph.nodes.get_mut("%1").unwrap()["heartbeat_at"] = json!(now() - 16.0);
    graph.expire();
    graph.transfer_nodes_to(&HashSet::from([1]), &mut target);
    target.dispatch(1, "agent.heartbeat", &json!({})).unwrap();
    assert_eq!(target.nodes["%1"]["status"], "idle");
    assert!(graph.timed_out_status.is_empty());
}

#[test]
fn inbox_registration_expires_and_native_session_resets_transport() {
    let mut graph = Graph::default(); graph.add(1, "Terminal".into());
    assert!(graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"SessionStart","transport":"typo"})).is_err());
    graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"SessionStart","transport":"inbox","pid":1})).unwrap();
    graph.nodes.get_mut("%1").unwrap()["heartbeat_at"] = json!(now() - 14.0);
    graph.expire(); assert_eq!(graph.nodes["%1"]["status"], "idle");
    graph.dispatch(1,"agent.heartbeat",&json!({})).unwrap();
    assert!(graph.nodes["%1"]["heartbeat_at"].as_f64().unwrap() > now() - 1.0);
    graph.nodes.get_mut("%1").unwrap()["heartbeat_at"] = json!(now() - 16.0);
    graph.expire(); assert_eq!(graph.nodes["%1"]["status"], "offline");
    assert!(graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"Stop","transport":"native"})).is_err());
    graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"SessionStart","pid":2})).unwrap();
    assert_eq!(graph.nodes["%1"]["transport"], "native");
    assert!(graph.nodes["%1"].get("heartbeat_at").is_none());
    graph.observe_agent(1,&json!({"provider":"codex","status":"busy","pid":2}));
    assert_eq!(graph.nodes["%1"]["status"], "busy");
    graph.dispatch(1,"agent.event",&json!({"provider":"codex","event":"SessionStart","transport":"inbox","pid":3,"transcript_path":"/old/session"})).unwrap();
    graph.observe_agent(1,&json!({"provider":"claude","status":"idle","pid":4}));
    assert_eq!(graph.nodes["%1"]["provider"], "claude");
    assert!(graph.nodes["%1"].get("transport").is_none());
    assert!(graph.nodes["%1"].get("transcript_path").is_none());
}

#[test]
fn status_history_records_hook_transitions_with_offsets_and_survives_snapshots() {
    for provider in ["claude", "codex", "opencode", "pi"] {
        let mut graph = Graph::default();
        graph.add(1, "Agent".into());
        let before = chrono::Utc::now();
        for event in [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "AwaitingInput",
            "PostToolUse",
            "Stop",
            "Stop",
            "SessionEnd",
        ] {
            graph
                .dispatch(
                    1,
                    "agent.event",
                    &json!({"provider":provider,"event":event,"session_id":"test"}),
                )
                .unwrap();
        }
        let snapshot = graph.snapshot();
        let history = snapshot["nodes"][0]["status_history"].as_array().unwrap();
        assert_eq!(
            history
                .iter()
                .map(|entry| entry["status"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["idle", "busy", "waiting", "busy", "waiting", "busy", "idle", "offline"]
        );
        for entry in history {
            assert_eq!(entry["provider"], provider);
            let at = entry["at"].as_str().unwrap();
            assert!(at.ends_with("+00:00"));
            let at = chrono::DateTime::parse_from_rfc3339(at).unwrap();
            assert!(at.timestamp_millis() >= before.timestamp_millis());
            assert!(at <= chrono::Utc::now());
        }
        assert_eq!(
            graph.snapshot()["nodes"][0]["status_history"],
            snapshot["nodes"][0]["status_history"]
        );
    }
}

#[test]
fn status_history_discovery_respects_hooks_and_bounds_retention() {
    let mut graph = Graph::default();
    graph.add(1, "Agent".into());
    graph
        .dispatch(
            1,
            "agent.event",
            &json!({"provider":"claude","event":"SessionStart","pid":1,"integrated":true}),
        )
        .unwrap();
    graph
        .dispatch(
            1,
            "agent.event",
            &json!({"provider":"claude","event":"UserPromptSubmit"}),
        )
        .unwrap();
    graph.observe_agent(1, &json!({"provider":"claude","pid":1,"status":"idle"}));
    assert_eq!(graph.nodes["%1"]["status"], "busy");
    assert_eq!(
        graph.nodes["%1"]["status_history"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    graph.observe_agent(1, &json!({"status":"offline"}));
    graph.observe_agent(1, &json!({"status":"offline"}));
    assert_eq!(
        graph.nodes["%1"]["status_history"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    // A replacement process can report its own state, even at the same pane.
    for index in 0..STATUS_HISTORY_LIMIT + 5 {
        graph.observe_agent(
            1,
            &json!({"provider":"codex","pid":2,"status":if index % 2 == 0 {"busy"} else {"idle"}}),
        );
    }
    let history = graph.nodes["%1"]["status_history"]
        .as_array()
        .unwrap();
    assert_eq!(history.len(), STATUS_HISTORY_LIMIT);
    assert!(history.iter().all(|entry| entry["provider"] == "codex"));
    assert_eq!(
        history.last().unwrap()["status"],
        graph.nodes["%1"]["status"]
    );
    graph.remove(1);
    graph.add(1, "New pane".into());
    assert!(graph.nodes["%1"].get("status_history").is_none());
}

fn graph() -> Graph {
    let mut g = Graph::default();
    for id in 1..=3 {
        g.add(id, format!("Node {id}"));
        g.dispatch(
            id,
            "agent.event",
            &json!({"provider":"adapter","event":"SessionStart","pid":id}),
        )
        .unwrap();
        g.dispatch(
            id,
            "agent.register",
            &json!({"inputs":[{"id":"in"}],"outputs":[{"id":"out"}]}),
        )
        .unwrap();
    }
    for id in 2..=3 {
        g.dispatch(1,"graph.connect",&json!({"from":"%1","to":format!("%{id}"),"from_port":"out","to_port":"in"})).unwrap();
    }
    g
}
fn send(g: &mut Graph, run: &str) -> Result<Value> {
    g.dispatch(
        1,
        "graph.send",
        &json!({"to":"%2","text":"private","run_id":run}),
    )
}

#[test]
fn providerless_nodes_register_resume_and_forward_without_inventing_sessions() {
    let mut g = graph();
    // Older adapter registrations normalize to the same providerless kind.
    assert_eq!(g.nodes["%1"]["kind"], "custom");
    assert!(g.nodes["%1"].get("provider").is_none());
    g.dispatch(1, "agent.event", &json!({"kind":"custom","event":"SessionStart","pid":20})).unwrap();
    g.dispatch(1, "agent.register", &json!({"name":"Manual Prompt","inputs":[],"outputs":[{"id":"out"}]})).unwrap();
    g.observe_agent(1, &json!({"provider":"shell","status":"offline"}));
    assert_eq!(g.nodes["%1"]["status"], "idle");
    g.dispatch(1, "graph.emit", &json!({"output":"out","text":"hello","payload":null})).unwrap();
    let event = g.queues["%2"][0].clone();
    assert_eq!(event["sessions"], json!([]));
    g.dispatch(2, "agent.event", &json!({"kind":"custom","event":"SessionStart","pid":99,"resume_inbox":true})).unwrap();
    assert_eq!(g.queues["%2"][0], event);
    g.dispatch(2, "graph.connect", &json!({"from":"%2","to":"%3","from_port":"out","to_port":"in"})).unwrap();
    g.dispatch(2, "graph.forward", &json!({"event_id":event["event_id"],"output":"out","content":{"text":"HELLO"}})).unwrap();
    let forwarded = g.queues["%3"].last().unwrap();
    assert_eq!(forwarded["sessions"], json!([]));
    assert_eq!(forwarded["origin"]["source"], "%1");
    assert_eq!(forwarded["run_id"], event["run_id"]);
    g.dispatch(2, "agent.event", &json!({"event":"SessionEnd"})).unwrap();
    assert_eq!(g.nodes["%2"]["status"], "offline");
}

#[test]
fn generic_node_cannot_inherit_the_previous_agents_conversation() {
    let mut g = graph();
    g.dispatch(1, "agent.event", &json!({"provider":"claude","event":"SessionStart","session_id":"old-conversation","transcript_path":"/old/session.jsonl"})).unwrap();
    g.dispatch(1, "agent.event", &json!({"event":"SessionStart","pid":200})).unwrap();
    assert_eq!(g.nodes["%1"]["kind"], "custom");
    for field in ["provider", "session_id", "transcript_path"] {
        assert!(g.nodes["%1"].get(field).is_none(), "stale {field}");
    }
    g.dispatch(1, "agent.register", &json!({"inputs":[],"outputs":[{"id":"out"}]})).unwrap();
    g.dispatch(1, "graph.connect", &json!({"from":"%1","to":"%2","from_port":"out","to_port":"in"})).unwrap();
    g.dispatch(1, "graph.emit", &json!({"output":"out","text":"new prompt","payload":null})).unwrap();
    assert_eq!(g.queues["%2"][0]["sessions"], json!([]));
}

#[test]
fn provider_is_optional_metadata_but_node_kind_controls_custom_ports() {
    let mut g = graph();
    g.dispatch(1, "agent.event", &json!({"kind":"custom","provider":"my-integration","event":"SessionStart"})).unwrap();
    g.dispatch(1, "agent.register", &json!({"inputs":[],"outputs":[]})).unwrap();
    assert_eq!(g.nodes["%1"]["provider"], "my-integration");
    g.dispatch(1, "agent.event", &json!({"event":"SessionEnd"})).unwrap();
    assert_eq!(g.nodes["%1"]["provider"], "my-integration");
    for params in [json!({"kind":"agent"}), json!({"kind":"invalid"}), json!({"provider":42})] {
        let mut start = params;
        start["event"] = json!("SessionStart");
        assert!(g.dispatch(1, "agent.event", &start).is_err());
    }
    g.dispatch(1, "agent.event", &json!({"provider":"codex","event":"SessionStart"})).unwrap();
    assert!(g.dispatch(1, "agent.register", &json!({"inputs":[],"outputs":[]})).is_err());
}

#[test]
fn run_defaults_are_captured_and_limits_are_enforced_by_the_owner() {
    let mut g = graph();
    send(&mut g, "existing").unwrap();
    let result = g
        .dispatch(1, "graph.run.default", &json!({"limit":2}))
        .unwrap();
    assert_eq!(result["limits"]["pending_per_node"], 10_000);
    assert_eq!(result["limits"]["run_messages"], 2);
    assert_eq!(g.run_limit("existing"), 10_000);
    send(&mut g, "new").unwrap();
    g.dispatch(1, "graph.run.default", &json!({"limit":3}))
        .unwrap();
    send(&mut g, "new").unwrap();
    assert_eq!(
        send(&mut g, "new").unwrap_err(),
        "Graph run message limit reached"
    );
    assert_eq!(g.run_limit("new"), 2);
    g.dispatch(1, "graph.run.limit", &json!({"run_id":"new","limit":4}))
        .unwrap();
    send(&mut g, "new").unwrap();
    g.dispatch(1, "graph.run.limit", &json!({"run_id":"new","limit":1}))
        .unwrap();
    assert!(send(&mut g, "new").is_err());
    assert_eq!(g.runs["new"], 3);
    for invalid in [
        json!(0),
        json!(-1),
        json!(true),
        json!(1.5),
        json!("3"),
        json!(u64::MAX),
    ] {
        assert!(
            g.dispatch(1, "graph.run.default", &json!({"limit":invalid}))
                .is_err()
        );
    }
    for method in ["graph.run.limit", "graph.run.reset"] {
        assert!(
            g.dispatch(1, method, &json!({"run_id":"missing","limit":3}))
                .is_err()
        );
    }
    assert!(
        g.dispatch(99, "graph.run.default", &json!({"limit":1}))
            .is_err()
    );
}

#[test]
fn run_reset_preserves_queues_history_and_other_runs() {
    let mut g = graph();
    let event = send(&mut g, "reset").unwrap();
    g.dispatch(
        2,
        "graph.ack",
        &json!({"event_id":event["event_id"],"status":"delivered"}),
    )
    .unwrap();
    send(&mut g, "reset").unwrap();
    send(&mut g, "other").unwrap();
    g.dispatch(1, "graph.run.limit", &json!({"run_id":"reset","limit":2}))
        .unwrap();
    let before = g.snapshot();
    let result = g
        .dispatch(1, "graph.run.reset", &json!({"run_id":"reset"}))
        .unwrap();
    assert_eq!(result["runs"]["reset"]["count"], 0);
    assert_eq!(result["runs"]["reset"]["limit"], 2);
    let after = g.snapshot();
    for field in ["queues", "journal", "receipts", "edges", "limits"] {
        assert_eq!(before[field], after[field]);
    }
    assert_eq!(g.runs["other"], 1);
    send(&mut g, "reset").unwrap();
}

#[test]
fn fanout_checks_custom_and_default_budgets_before_accepting_any_recipient() {
    let mut g = graph();
    g.dispatch(1, "graph.run.default", &json!({"limit":1}))
        .unwrap();
    let params = json!({"output":"out","payload":"fanout","run_id":"new"});
    let before = g.snapshot();
    assert!(g.dispatch(1, "graph.emit", &params).is_err());
    assert_eq!(g.snapshot(), before);
    g.dispatch(1, "graph.run.default", &json!({"limit":2}))
        .unwrap();
    g.dispatch(1, "graph.emit", &params).unwrap();
    g.dispatch(1, "graph.run.limit", &json!({"run_id":"new","limit":3}))
        .unwrap();
    let before = g.snapshot();
    assert!(g.dispatch(1, "graph.emit", &params).is_err());
    assert_eq!(g.snapshot(), before);
    g.dispatch(1, "graph.run.limit", &json!({"run_id":"new","limit":4}))
        .unwrap();
    g.dispatch(1, "graph.emit", &params).unwrap();
    assert_eq!(g.runs["new"], 4);
}

#[test]
fn retained_run_limits_are_evicted_with_their_counts() {
    let mut g = graph();
    for i in 0..4096 {
        g.runs.insert(i.to_string(), 1);
        g.run_limits.insert(i.to_string(), 17);
    }
    send(&mut g, "new").unwrap();
    assert_eq!(g.runs.len(), 4096);
    assert_eq!(g.run_limits.len(), 4096);
    assert!(g.run_limits.keys().all(|id| g.runs.contains_key(id)));
}

#[test]
fn progress_is_receiver_scoped_and_acknowledgment_is_final() {
    let mut g = graph();
    let sent = send(&mut g, "run").unwrap();
    let params = json!({"event_id":sent["event_id"],"message":"Waiting for review","details":{"custom":[1,2]}});
    assert!(g.dispatch(3, "graph.progress", &params).is_err());
    g.dispatch(2, "graph.progress", &params).unwrap();
    g.dispatch(2, "graph.progress", &params).unwrap();
    assert_eq!(g.queues["%2"].len(), 1);
    assert_eq!(
        g.queues["%2"][0]["progress"]["details"],
        params["details"]
    );
    assert_eq!(g.receipts.len(), 1);
    g.dispatch(
        2,
        "graph.ack",
        &json!({"event_id":sent["event_id"],"status":"delivered"}),
    )
    .unwrap();
    assert!(g.queues["%2"].is_empty());
    assert!(g.dispatch(2, "graph.progress", &params).is_err());
    let journal = g.dispatch(1, "graph.queue", &json!({})).unwrap();
    assert_eq!(
        journal["events"][0]["transitions"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
    assert_eq!(journal["events"][0]["status"], "sent to receiver");
    assert!(!journal.to_string().contains("private"));
}

#[test]
fn receiver_restart_records_cancellation_unless_adapter_explicitly_resumes() {
    for resume in [false, true] {
        let mut g = graph();
        send(&mut g, "run").unwrap();
        g.dispatch(
            2,
            "agent.event",
            &json!({"provider":"adapter","event":"SessionStart","pid":100,"resume_inbox":resume}),
        )
        .unwrap();
        let pending = g.queues.get("%2").map_or(0, Vec::len);
        assert_eq!(pending, usize::from(resume));
        assert_eq!(g.journal.snapshot("")["pending"], pending);
    }
}

#[test]
fn manifest_changes_and_disconnects_preserve_only_valid_port_deliveries() {
    let mut g = graph();
    let manifest = json!({"inputs":[{"id":"a"},{"id":"b"}],"outputs":[]});
    g.dispatch(2, "agent.register", &manifest).unwrap();
    for input in ["a", "b"] {
        g.dispatch(
            1,
            "graph.connect",
            &json!({"from":"%1","to":"%2","from_port":"out","to_port":input}),
        )
        .unwrap();
    }
    g.dispatch(
        1,
        "graph.emit",
        &json!({"output":"out","payload":{"nested":[1,2]},"run_id":"run"}),
    )
    .unwrap();
    assert_eq!(g.queues["%2"].len(), 2);
    let mut cosmetic = manifest.clone();
    cosmetic["name"] = json!("Renamed");
    g.dispatch(2, "agent.register", &cosmetic).unwrap();
    assert_eq!(g.queues["%2"].len(), 2);
    g.dispatch(
        1,
        "graph.disconnect",
        &json!({"from":"%1","to":"%2","from_port":"out","to_port":"a"}),
    )
    .unwrap();
    assert_eq!(g.queues["%2"].len(), 1);
    assert_eq!(g.queues["%2"][0]["target_port"], "b");
    for bad in [
        json!({"inputs":[],"outputs":[{"id":"same"},{"id":"same"}]}),
        json!({"inputs":[],"outputs":[{"id":"bad/id"}]}),
    ] {
        assert!(g.dispatch(2, "agent.register", &bad).is_err());
        assert_eq!(g.nodes["%2"]["manifest"]["name"], "Renamed");
    }
}

#[test]
fn forwarding_preserves_rich_content_and_original_sender() {
    let mut g = graph();
    g.dispatch(
        2,
        "graph.connect",
        &json!({"from":"%2","to":"%3","from_port":"out","to_port":"in"}),
    )
    .unwrap();
    let sent = g.dispatch(1,"graph.emit",&json!({"output":"out","payload":{"private":true},"content":[{"type":"image","path":"/result.png"}],"renderings":{"slack":{"blocks":[]}}})).unwrap();
    let id = sent["events"][0]["event_id"].clone();
    let input = g.queues["%2"][0].clone();
    g.dispatch(
        2,
        "graph.forward",
        &json!({"event_id":id,"output":"out","content":{"text":"Approved"}}),
    )
    .unwrap();
    let output = g.queues["%3"].last().unwrap();
    for field in ["content", "renderings", "payload", "run_id"] {
        assert_eq!(input[field], output[field]);
    }
    assert_eq!(output["text"], "Approved");
    assert_eq!(output["origin"]["source"], "%1");
    assert!(
        g.dispatch(
            2,
            "graph.forward",
            &json!({"event_id":id,"output":"out","content":{"sessions":[]}})
        )
        .is_err()
    );
}

#[test]
fn journal_retention_never_discards_pending_work_or_exposes_payloads() {
    let mut g = graph();
    let live = send(&mut g, "live").unwrap();
    for _ in 0..205 {
        let sent = send(&mut g, "history").unwrap();
        g.dispatch(
            2,
            "graph.ack",
            &json!({"event_id":sent["event_id"],"status":"delivered"}),
        )
        .unwrap();
    }
    let snapshot = g.journal.snapshot("");
    assert_eq!(snapshot["pending"], 1);
    assert_eq!(snapshot["events"].as_array().unwrap().len(), 201);
    assert!(
        snapshot["events"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["event_id"] == live["event_id"])
    );
    assert!(!snapshot.to_string().contains("private"));
    for i in 0..25 {
        g.dispatch(
            2,
            "graph.progress",
            &json!({"event_id":live["event_id"],"status":"pending","message":format!("Step {i}")}),
        )
        .unwrap();
    }
    let snapshot = g.journal.snapshot("%1/out>%2/in");
    let row = snapshot["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["event_id"] == live["event_id"])
        .unwrap();
    assert_eq!(row["transitions"].as_array().unwrap().len(), 20);
    assert_eq!(
        g.journal.snapshot("%1/out>%3/in")["events"],
        json!([])
    );
}

#[test]
fn native_prompt_start_is_receiver_scoped_and_wins_a_late_queue_ack() {
    let mut g = graph();
    let sent = send(&mut g, "run").unwrap();
    let prompt = format!(
        "[Graffitty message from %1; event {}; run run]\nhello",
        sent["event_id"].as_str().unwrap()
    );
    g.dispatch(
        3,
        "agent.event",
        &json!({"provider":"adapter","event":"UserPromptSubmit","prompt":prompt}),
    )
    .unwrap();
    assert_eq!(
        g.journal.snapshot("")["events"][0]["status"],
        "queued in Graffitty"
    );
    g.dispatch(
        2,
        "agent.event",
        &json!({"provider":"adapter","event":"UserPromptSubmit","prompt":prompt}),
    )
    .unwrap();
    g.dispatch(
        2,
        "graph.ack",
        &json!({"event_id":sent["event_id"],"status":"queued in Codex"}),
    )
    .unwrap();
    assert_eq!(
        g.journal.snapshot("")["events"][0]["status"],
        "sent to receiver"
    );
    assert_eq!(g.journal.snapshot("")["pending"], 0);
    assert!(!g.native_pending(sent["event_id"].as_str().unwrap()));
}

#[test]
fn queue_acceptance_remains_pending_until_the_receiver_starts() {
    let mut g = graph();
    let sent = send(&mut g, "run").unwrap();
    g.dispatch(
        2,
        "graph.ack",
        &json!({"event_id":sent["event_id"],"status":"queued in Codex"}),
    )
    .unwrap();
    assert!(g.native_pending(sent["event_id"].as_str().unwrap()));
    assert!(g.queues["%2"].is_empty());
    assert_eq!(g.journal.snapshot("")["pending"], 1);
    let row = g.journal.snapshot("")["events"][0].clone();
    g.record_delivery(&row, "started or removed in Codex", false);
    assert!(!g.native_pending(sent["event_id"].as_str().unwrap()));
    assert_eq!(g.journal.snapshot("")["pending"], 0);
}

#[test]
fn automatic_session_references_follow_current_read_permission() {
    let mut g = graph();
    g.nodes.get_mut("%1").unwrap()["session_id"] = json!("source-session");
    g.nodes.get_mut("%1").unwrap()["transcript_path"] = json!("/private/transcript.jsonl");
    g.dispatch(
        1,
        "agent.register",
        &json!({"inputs":[],"outputs":[{"id":"out"},{"id":"read","mode":"read"}]}),
    )
    .unwrap();
    let read_edge =
        json!({"from":"%1","from_port":"read","to":"%2","to_port":"in"});
    g.dispatch(1, "graph.connect", &read_edge).unwrap();
    g.dispatch(
        1,
        "graph.emit",
        &json!({"output":"out","payload":"private","run_id":"run"}),
    )
    .unwrap();
    assert_eq!(
        g.dispatch(2, "graph.take", &json!({})).unwrap()["events"][0]["sessions"][0]["path"],
        "/private/transcript.jsonl"
    );
    g.dispatch(1, "graph.disconnect", &read_edge).unwrap();
    let event = g.dispatch(2, "graph.take", &json!({})).unwrap()["events"][0].clone();
    assert_eq!(event["sessions"][0]["id"], "source-session");
    assert!(event["sessions"][0].get("path").is_none());
    g.dispatch(
        2,
        "graph.connect",
        &json!({"from":"%2","from_port":"out","to":"%3","to_port":"in"}),
    )
    .unwrap();
    g.dispatch(
        2,
        "graph.forward",
        &json!({"event_id":event["event_id"],"output":"out"}),
    )
    .unwrap();
    assert!(
        g.queues["%3"].last().unwrap()["sessions"][0]
            .get("path")
            .is_none()
    );
    assert_eq!(
        g.adjacent("%2")["incoming"][0]["from_title"],
        "Node 1"
    );
}

#[test]
fn a_rejected_completion_is_visible_in_delivery_history() {
    let mut g = graph();
    g.dispatch(
        1,
        "agent.register",
        &json!({"inputs":[],"outputs":[{"id":"out","mode":"turn_completed"}]}),
    )
    .unwrap();
    g.dispatch(
        1,
        "graph.connect",
        &json!({"from":"%1","from_port":"out","to":"%2","to_port":"in"}),
    )
    .unwrap();
    g.default_run_limit = 1;
    let params = json!({"run_id":"limited","text":"done"});
    g.enqueue_completion("%1", &params, "first".into())
        .unwrap();
    assert_eq!(g.queues["%2"][0]["kind"], "turn.completed");
    assert!(
        g.enqueue_completion("%1", &params, "second".into())
            .is_err()
    );
    assert_eq!(
        g.receipts.last().unwrap()["status"],
        "failed: Graph run message limit reached"
    );
    assert_eq!(
        g.journal.snapshot("")["events"].as_array().unwrap().len(),
        2
    );
}

#[test]
fn configured_node_budgets_and_history_are_used() {
    let settings = NodeSettings { pending_per_node: 1, run_messages: 2, status_history: 2,
        receipts: 2, delivery_history: 1, delivery_transitions: 2, ..Default::default() };
    let mut graph = Graph::with_settings(settings);
    for id in [1, 2] {
        graph.add(id, format!("Agent {id}"));
        graph.dispatch(id, "agent.event", &json!({"provider":"claude","event":"SessionStart","pid":id})).unwrap();
    }
    graph.dispatch(1,"graph.connect",&json!({"from":"%1","to":"%2","send":true})).unwrap();
    graph.dispatch(1,"graph.send",&json!({"to":"%2","text":"one"})).unwrap();
    assert!(graph.dispatch(1,"graph.send",&json!({"to":"%2","text":"two"})).is_err());
    for event in ["UserPromptSubmit", "PermissionRequest", "SessionEnd"] {
        graph.dispatch(1,"agent.event",&json!({"provider":"claude","event":event})).unwrap();
    }
    assert_eq!(graph.nodes["%1"]["status_history"].as_array().unwrap().len(),2);
    let snapshot = graph.snapshot();
    assert_eq!(snapshot["limits"]["pending_per_node"],1);
    assert_eq!(snapshot["limits"]["run_messages"],2);
    for id in 0..4 {
        graph.record_delivery(&json!({"event_id":format!("custom-{id}"),"source":"%1","target":"%2"}), "delivered", false);
    }
    assert_eq!(graph.receipts.len(),2);
}

#[test]
fn native_and_inbox_prompts_preserve_the_same_complete_visible_event() {
    let mut g = Graph::default();
    for id in [1, 2] { g.add(id, format!("%{id}")); }
    g.dispatch(1, "agent.event", &json!({"provider":"codex","event":"SessionStart","session_id":"source-session","transcript_path":"/home/demo/session.jsonl"})).unwrap();
    g.dispatch(2, "agent.event", &json!({"provider":"claude","event":"SessionStart","session_id":"receiver-session"})).unwrap();
    g.dispatch(1, "graph.connect", &json!({"from":"%1","to":"%2","turn_completed":true})).unwrap();
    g.dispatch(1, "agent.event", &json!({"provider":"codex","event":"Stop","session_id":"source-session","text":"Ready","payload":{"review":true},"content":[{"type":"text","text":"Details"}],"renderings":{"slack":{"text":"Review"}}})).unwrap();
    let raw = g.queues["%2"][0].clone();
    let inbox = g.dispatch(2, "graph.take", &json!({})).unwrap();
    let prompt = message_prompt(&inbox["events"][0]);
    assert_eq!(g.delivery_prompt(&raw), prompt);
    let envelope: Value = serde_json::from_str(prompt.split_once("\nPayload (JSON): ").unwrap().1).unwrap();
    assert_eq!(envelope, inbox["events"][0]);
    assert_eq!(envelope["sessions"][0]["path"], "/home/demo/session.jsonl");
    assert_eq!(envelope["payload"]["review"], true);
    assert_eq!(envelope["content"][0]["text"], "Details");
    assert_eq!(envelope["renderings"]["slack"]["text"], "Review");
    // Formatting cannot bypass the same session-path visibility check as take.
    g.edges.clear();
    assert!(!g.delivery_prompt(&raw).contains("/home/demo/session.jsonl"));
}

#[test]
fn opencode_home_screen_reports_idle_until_its_process_exits() {
    let mut graph = Graph::default();
    graph.add(1, "OpenCode".into());
    let detected = json!({"provider":"opencode","pid":123,"status":"unknown"});
    graph.observe_agent(1, &detected);
    graph.dispatch(1, "agent.event", &json!({"kind":"agent","provider":"opencode",
        "event":"SessionStart","transport":"native","integrated":true,"pid":123})).unwrap();
    graph.observe_agent(1, &detected);
    assert_eq!(graph.nodes["%1"]["status"], "idle");
    assert!(graph.nodes["%1"].get("session_id").is_none());
    assert!(graph.nodes["%1"].get("transcript_path").is_none());
    graph.observe_agent(1, &json!({"status":"offline"}));
    assert_eq!(graph.nodes["%1"]["status"], "offline");
}

#[test]
fn opencode_has_native_ports_and_switching_sessions_revokes_old_queue() {
    let mut graph = Graph::default();
    for (id, provider) in [(1, "claude"), (2, "opencode")] {
        graph.add(id, provider.into());
        graph.dispatch(id,"agent.event",&json!({"provider":provider,"event":"SessionStart","transport":"inbox","pid":id,"session_id":"ses_first"})).unwrap();
    }
    assert_eq!(ports(&graph.nodes["%2"],true).iter().map(|p|string(p,"id")).collect::<Vec<_>>(), vec!["read","send","turn_completed","waiting","error"]);
    graph.dispatch(1,"graph.connect",&json!({"from":"%1","to":"%2","send":true})).unwrap();
    graph.dispatch(1,"graph.connect",&json!({"from":"%1","to":"%2","read":true})).unwrap();
    graph.dispatch(1,"graph.send",&json!({"to":"%2","text":"old session input"})).unwrap();
    assert!(graph.can_read("%1","%2"));
    graph.dispatch(2,"graph.connect",&json!({"from":"%2","to":"%1","turn_completed":true})).unwrap();
    graph.dispatch(2,"agent.event",&json!({"provider":"opencode","event":"Stop","session_id":"ses_first","completion_id":"msg_idle1","text":"done","outcome":"succeeded"})).unwrap();
    assert_eq!(graph.queues["%1"][0]["sessions"][0]["provider"], "opencode");
    assert_eq!(graph.queues["%1"][0]["text"], "done");
    assert!(graph.can_read("%2","%1"));
    graph.dispatch(2,"agent.event",&json!({"provider":"opencode","event":"SessionStart","transport":"inbox","pid":2,"session_id":"ses_second"})).unwrap();
    assert!(graph.dispatch(2,"graph.take",&json!({})).unwrap()["events"].as_array().unwrap().is_empty());
}

#[test]
fn pi_has_native_ports_and_switching_sessions_revokes_old_queue() {
    let mut graph = Graph::default();
    for (id, provider) in [(1, "claude"), (2, "pi")] {
        graph.add(id, provider.into());
        graph.dispatch(id,"agent.event",&json!({"provider":provider,"event":"SessionStart","transport":"inbox","pid":id,"session_id":"ses_first"})).unwrap();
    }
    assert_eq!(ports(&graph.nodes["%2"],true).iter().map(|p|string(p,"id")).collect::<Vec<_>>(), vec!["read","send","turn_completed","waiting","error"]);
    graph.dispatch(1,"graph.connect",&json!({"from":"%1","to":"%2","send":true})).unwrap();
    graph.dispatch(1,"graph.connect",&json!({"from":"%1","to":"%2","read":true})).unwrap();
    graph.dispatch(1,"graph.send",&json!({"to":"%2","text":"old session input"})).unwrap();
    assert!(graph.can_read("%1","%2"));
    graph.dispatch(2,"graph.connect",&json!({"from":"%2","to":"%1","turn_completed":true})).unwrap();
    graph.dispatch(2,"agent.event",&json!({"provider":"pi","event":"Stop","session_id":"ses_first","completion_id":"msg_idle1","text":"done","outcome":"succeeded"})).unwrap();
    assert_eq!(graph.queues["%1"][0]["sessions"][0]["provider"], "pi");
    assert_eq!(graph.queues["%1"][0]["text"], "done");
    assert!(graph.can_read("%2","%1"));
    graph.dispatch(2,"agent.event",&json!({"provider":"pi","event":"SessionStart","transport":"inbox","pid":2,"session_id":"ses_second"})).unwrap();
    assert!(graph.dispatch(2,"graph.take",&json!({})).unwrap()["events"].as_array().unwrap().is_empty());
}

#[test]
fn nodes_opt_in_to_checkpoint_recovery_with_private_command_and_state() {
    let mut graph = Graph::default(); graph.add(1, "Terminal".into());
    let restore = json!({"command":["/usr/bin/python3","judge.py","--strict"],"cwd":"/work","env":{"GRAFFITTY_NODE_CONFIG":"/work/node.json"}});
    let start = |restore: Value| json!({"kind":"custom","event":"SessionStart","pid":7,"transport":"inbox","restore":restore});
    // State needs a declared relaunch to come back to.
    graph.dispatch(1,"agent.event",&json!({"kind":"custom","event":"SessionStart","pid":6,"transport":"inbox"})).unwrap();
    assert!(graph.dispatch(1,"agent.checkpoint",&json!({"state":{"cursor":1}})).is_err());
    for invalid in [json!({"command":[]}), json!({"command":[""]}), json!({"command":["x"],"cwd":"relative"}),
                    json!({"command":["x"],"env":{"DYLD_INSERT_LIBRARIES":"/tmp/x"}}), json!({"command":["x"],"env":{"GRAFFITTY_TOKEN":"t"}}),
                    json!({"command":["x"],"shell":true})] {
        assert!(graph.dispatch(1,"agent.event",&start(invalid.clone())).is_err(), "{invalid}");
    }
    assert!(graph.dispatch(1,"agent.event",&json!({"kind":"custom","event":"Stop","restore":restore})).is_err(), "only at SessionStart");
    graph.dispatch(1,"agent.event",&start(restore.clone())).unwrap();
    graph.dispatch(1,"agent.checkpoint",&json!({"state":{"cursor":41}})).unwrap();
    assert!(graph.dispatch(1,"agent.checkpoint",&json!({"state":"x".repeat(64 * 1024)})).is_err());
    assert_eq!(graph.nodes["%1"]["restore"], restore);
    assert_eq!(graph.nodes["%1"]["checkpoint_state"], json!({"cursor":41}));
    // Peers never see how a node relaunches or what it keeps.
    let listed = &graph.snapshot()["nodes"][0];
    assert!(listed.get("restore").is_none() && listed.get("checkpoint_state").is_none());
    graph.dispatch(1,"agent.checkpoint",&json!({"state":null})).unwrap();
    assert!(graph.nodes["%1"].get("checkpoint_state").is_none());
    // A new process starts over: an old relaunch or state is not inherited.
    graph.dispatch(1,"agent.checkpoint",&json!({"state":{"cursor":42}})).unwrap();
    graph.dispatch(1,"agent.event",&json!({"kind":"custom","event":"SessionStart","pid":8,"transport":"inbox"})).unwrap();
    assert!(graph.nodes["%1"].get("restore").is_none() && graph.nodes["%1"].get("checkpoint_state").is_none());
}

#[test]
fn osc_7501_status_drives_nodes_without_hooks_but_never_overrides_hooks() {
    let mut g = Graph::default();
    g.add(1, "Terminal".into());
    g.add(2, "Terminal".into());
    let working = json!({"state":"working","app":"cargo"});
    g.observe_program_status(1, Some(&working));
    assert_eq!(g.nodes["%1"]["status"], "busy");
    assert_eq!(g.nodes["%1"]["program_status"]["app"], "cargo");
    // Discovery cannot read cargo, so its "unknown" leaves the report's status.
    g.observe_agent(1, &json!({"provider":"cargo","pid":7,"status":"unknown"}));
    assert_eq!(g.nodes["%1"]["status"], "busy");
    g.observe_program_status(1, Some(&json!({"state":"blocked","kind":"permission"})));
    assert_eq!(g.nodes["%1"]["status"], "waiting");
    g.observe_program_status(1, Some(&json!({"state":"done"})));
    assert_eq!(g.nodes["%1"]["status"], "idle");
    g.observe_program_status(1, None);
    assert_eq!(g.nodes["%1"]["status"], "unintegrated");
    assert!(g.nodes["%1"].get("program_status").is_none());
    // A hook-integrated agent keeps hook status; the record is still kept.
    g.dispatch(2, "agent.event", &json!({"provider":"claude","event":"UserPromptSubmit","prompt":"go"})).unwrap();
    g.observe_program_status(2, Some(&json!({"state":"idle","app":"claude-code"})));
    assert_eq!(g.nodes["%2"]["status"], "busy");
    assert_eq!(g.nodes["%2"]["program_status"]["state"], "idle");
    // Lifecycle hooks take status over from an earlier report.
    g.observe_program_status(1, Some(&working));
    g.dispatch(1, "agent.event", &json!({"provider":"codex","event":"Stop"})).unwrap();
    assert_eq!(g.nodes["%1"]["status"], "idle");
    g.observe_program_status(1, Some(&working));
    assert_eq!(g.nodes["%1"]["status"], "idle");
}

#[test]
fn discovery_unknown_never_replaces_lifecycle_status_after_a_restart() {
    // A restarted server rediscovers a running pi pane as a plain process.
    let mut g = Graph::default();
    g.add(1, "Terminal".into());
    let scan = json!({"provider":"pi","pid":7,"status":"unknown"});
    g.observe_agent(1, &scan);
    assert_eq!(g.nodes["%1"]["status"], "unknown");
    // Its extension keeps sending lifecycle events without a new SessionStart.
    g.dispatch(1, "agent.event", &json!({"kind":"agent","provider":"pi","event":"Stop","text":"done"})).unwrap();
    assert_eq!(g.nodes["%1"]["status"], "idle");
    g.observe_agent(1, &scan);
    assert_eq!(g.nodes["%1"]["status"], "idle");
    g.dispatch(1, "agent.event", &json!({"kind":"agent","provider":"pi","event":"PreToolUse"})).unwrap();
    g.observe_agent(1, &scan);
    assert_eq!(g.nodes["%1"]["status"], "busy");
    // The heartbeat reply tells the extension its registration is gone.
    assert!(g.dispatch(1, "agent.heartbeat", &json!({})).unwrap()["transport"].is_null());
    g.dispatch(1, "agent.event", &json!({"kind":"agent","provider":"pi","event":"SessionStart","transport":"inbox","integrated":true,"pid":7})).unwrap();
    assert_eq!(g.dispatch(1, "agent.heartbeat", &json!({})).unwrap()["transport"], "inbox");
    // A real discovered status, a new process, or an exit still takes over.
    g.observe_agent(1, &json!({"provider":"pi","pid":8,"status":"unknown"}));
    assert_eq!(g.nodes["%1"]["status"], "unknown");
    g.dispatch(1, "agent.event", &json!({"kind":"agent","provider":"pi","event":"Stop"})).unwrap();
    g.observe_agent(1, &json!({"provider":"claude","pid":8,"status":"busy"}));
    assert_eq!(g.nodes["%1"]["status"], "busy");
    g.observe_agent(1, &json!({"status":"offline"}));
    assert_eq!(g.nodes["%1"]["status"], "offline");
    g.observe_agent(1, &json!({"provider":"pi","pid":8,"status":"unknown"}));
    assert_eq!(g.nodes["%1"]["status"], "unknown");
}
