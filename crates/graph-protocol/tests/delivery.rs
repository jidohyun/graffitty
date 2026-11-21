use graffitty_graph_protocol::{
    Event, InputPort, Manifest, Node, Output, OutputPort, PortMode, Session,
};
use serde_json::{Value, json};
use std::{cell::RefCell, rc::Rc};

fn event() -> Event {
    serde_json::from_value(
        json!({"type":"message","event_id":"event-1","run_id":"run-1",
        "source":"%1","target":"%2","source_port":"out","target_port":"in","text":"hello",
        "sessions":[{"provider":"codex","id":"session-1"}],"future_field":{"keep":true}}),
    )
    .unwrap()
}

#[test]
fn forward_precedes_ack_and_session_ends_on_drop() {
    let calls = Rc::new(RefCell::new(Vec::new()));
    let captured = calls.clone();
    let session = Session::start(
        move |method: &str, params: Value| {
            captured.borrow_mut().push((method.to_owned(), params));
            Ok(if method == "graph.forward" {
                json!({"status":"queued"})
            } else {
                json!({"ok":true})
            })
        },
        true,
    )
    .unwrap();
    let mut node = Node::new("Uppercase").input("in").output("out");
    node.on("in", |event| {
        Ok(Output::text("out", event.text.to_uppercase()))
    })
    .unwrap();
    node.process(&session, &event()).unwrap();
    drop(session);
    let calls = calls.borrow();
    assert_eq!(
        calls.iter().map(|(m, _)| m.as_str()).collect::<Vec<_>>(),
        ["agent.event", "graph.forward", "graph.ack", "agent.event"]
    );
    assert_eq!(
        calls[1].1,
        json!({"event_id":"event-1","output":"out","content":{"text":"HELLO"}})
    );
    assert_eq!(calls[0].1["resume_inbox"], true);
    assert_eq!(calls[0].1["kind"], "custom");
    assert!(calls[0].1.get("provider").is_none());
    assert!(calls[0].1.get("session_id").is_none());
    assert_eq!(calls[3].1["event"], "SessionEnd");
}

#[test]
fn failed_forward_retains_input_and_reports_failed_progress() {
    let calls = Rc::new(RefCell::new(Vec::new()));
    let captured = calls.clone();
    let session = Session::start(
        move |method: &str, params: Value| {
            captured.borrow_mut().push((method.to_owned(), params));
            if method == "graph.forward" {
                Err("Connection removed".into())
            } else {
                Ok(json!({"ok":true}))
            }
        },
        true,
    )
    .unwrap();
    let mut node = Node::new("Fail").input("in").output("out");
    node.on("in", |_| Ok(Output::new("out"))).unwrap();
    assert!(node.process(&session, &event()).is_err());
    let calls = calls.borrow();
    assert!(!calls.iter().any(|(m, _)| m == "graph.ack"));
    assert_eq!(calls.last().unwrap().1["status"], "failed");
}

#[test]
fn validates_all_branches_before_any_forward() {
    let calls = Rc::new(RefCell::new(Vec::new()));
    let captured = calls.clone();
    let session = Session::start(
        move |method: &str, _: Value| {
            captured.borrow_mut().push(method.to_owned());
            Ok(json!({"ok":true}))
        },
        true,
    )
    .unwrap();
    let mut node = Node::new("Fanout").input("in").output("out");
    node.on("in", |_| Ok(vec![Output::new("out"), Output::new("typo")]))
        .unwrap();
    assert!(node.process(&session, &event()).is_err());
    assert!(
        !calls
            .borrow()
            .iter()
            .any(|m| m == "graph.forward" || m == "graph.ack")
    );
}

#[test]
fn non_send_outputs_and_invalid_rich_content_fail_before_any_branch_is_sent() {
    for mode in [PortMode::Read, PortMode::TurnCompleted] {
        let calls = Rc::new(RefCell::new(Vec::new()));
        let captured = calls.clone();
        let session = Session::start(
            move |method: &str, _: Value| {
                captured.borrow_mut().push(method.to_owned());
                Ok(json!({"ok":true}))
            },
            true,
        )
        .unwrap();
        let mut node = Node::new("Mixed")
            .icon("⚖")
            .input(InputPort::new("in").icon("📥"))
            .output("send")
            .output(OutputPort::new("other").mode(mode).icon("✓"));
        node.on("in", |_| {
            Ok(vec![Output::new("send"), Output::new("other")])
        })
        .unwrap();
        assert!(node.process(&session, &event()).is_err());
        assert!(
            !calls
                .borrow()
                .iter()
                .any(|m| m == "graph.forward" || m == "graph.ack")
        );
    }
    for (field, value) in [
        ("content", json!(["invalid block"])),
        ("renderings", json!([])),
    ] {
        let mut output = Output::new("out");
        output.content.insert(field.into(), value);
        assert!(output.validate().is_err());
    }
}

#[test]
fn rejects_duplicate_ports_and_keeps_optional_session_access() {
    let reference: graffitty_graph_protocol::SessionReference =
        serde_json::from_value(json!({"id":"conversation","path":"/tmp/session.jsonl"})).unwrap();
    assert!(reference.provider.is_none());
    assert!(
        serde_json::to_value(reference)
            .unwrap()
            .get("provider")
            .is_none()
    );
    use graffitty_graph_protocol::Checkpoint;
    assert_eq!(
        serde_json::from_value::<Checkpoint>(json!({"byte_offset":57.0}))
            .unwrap()
            .byte_offset,
        57
    );
    for offset in [
        json!(true),
        json!(-1),
        json!(1.5),
        json!(9_007_199_254_740_992.0),
    ] {
        assert!(serde_json::from_value::<Checkpoint>(json!({"byte_offset":offset})).is_err());
    }
    let mut manifest = Manifest::new("test");
    manifest.inputs = vec![InputPort::new("in"), InputPort::new("in")];
    assert!(manifest.validate().is_err());
    let event = event();
    assert!(event.sessions[0].path.is_none());
    assert_eq!(
        serde_json::to_value(event).unwrap()["future_field"]["keep"],
        true
    );
}

#[test]
fn restorable_session_declares_its_relaunch_and_reports_state() {
    let calls = Rc::new(RefCell::new(Vec::new()));
    let captured = calls.clone();
    let mut restore = graffitty_graph_protocol::Restore {
        command: vec!["/usr/local/bin/judge".into(), "--strict".into()],
        cwd: Some("/work".into()),
        ..Default::default()
    };
    restore.env.insert("MODE".into(), "strict".into());
    let session = Session::start_restorable(
        move |method: &str, params: Value| {
            captured.borrow_mut().push((method.to_owned(), params));
            Ok(json!({"ok":true}))
        },
        None,
        true,
        &restore,
    )
    .unwrap();
    session.report_state(json!({"cursor":3})).unwrap();
    drop(session);
    let calls = calls.borrow();
    assert_eq!(calls[0].1["restore"], json!({"command":["/usr/local/bin/judge","--strict"],"cwd":"/work","env":{"MODE":"strict"}}));
    assert_eq!(calls[1], ("agent.checkpoint".to_owned(), json!({"state":{"cursor":3}})));
    // The host's own validator accepts what the SDK declares.
    graffitty_workspace_core::checkpoint::node_restore(&calls[0].1["restore"]).unwrap();
    let own = graffitty_graph_protocol::Restore::current_process().unwrap();
    assert!(std::path::Path::new(&own.command[0]).is_absolute() && own.cwd.is_some());
}
