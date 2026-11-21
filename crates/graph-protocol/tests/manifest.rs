use graffitty_graph_protocol::{Icon, InputPort, Manifest, Output, OutputPort, PortMode, Session};
use graffitty_protocol::graph::normalize_manifest;
use graffitty_workspace_core::graph::Graph;
use serde_json::{Value, json};
use std::{cell::RefCell, rc::Rc};

fn fixtures() -> Value {
    serde_json::from_str(include_str!("../../../tests/fixtures/graph-manifests.json")).unwrap()
}

#[test]
fn manifests_preserve_every_host_field_and_share_validation() {
    let fixtures = fixtures();
    for case in fixtures["valid"].as_array().unwrap() {
        let wire = &case["manifest"];
        let manifest: Manifest = serde_json::from_value(wire.clone()).unwrap();
        manifest.validate().unwrap();
        let round_trip = serde_json::to_value(manifest).unwrap();
        assert_eq!(
            normalize_manifest(&round_trip),
            normalize_manifest(wire),
            "{}",
            case["case"]
        );
    }
    for case in fixtures["invalid"].as_array().unwrap() {
        let wire = &case["manifest"];
        assert!(normalize_manifest(wire).is_err(), "{}", case["case"]);
        let result = serde_json::from_value::<Manifest>(wire.clone())
            .map_err(|e| e.to_string())
            .and_then(|m| m.validate().map_err(|e| e.to_string()));
        assert!(result.is_err(), "{}", case["case"]);
    }
}

#[test]
fn port_and_icon_boundaries_match_the_host() {
    let mut manifest = Manifest::new("x".repeat(128));
    manifest.inputs = (0..32).map(|i| InputPort::new(format!("p{i}"))).collect();
    manifest.outputs = (0..32).map(|i| OutputPort::new(format!("p{i}"))).collect();
    let svg = format!("<svg>{}</svg>", "가".repeat(16373));
    manifest.icon = Some(Icon::Svg { svg: svg.clone() });
    manifest.validate().unwrap();
    manifest.icon = Some(Icon::Svg { svg: svg + "x" });
    assert!(manifest.validate().is_err());
    manifest.icon = None;
    manifest.inputs.push(InputPort::new("overflow"));
    assert!(manifest.validate().is_err());
    manifest.inputs.pop();
    manifest.outputs.push(OutputPort::new("overflow"));
    assert!(manifest.validate().is_err());
}

#[test]
fn real_graph_registers_icons_routes_modes_and_preserves_wires_on_metadata_changes() {
    let graph = Rc::new(RefCell::new(Graph::default()));
    for id in 1..=2 {
        graph.borrow_mut().add(id, format!("Node {id}"));
    }
    let rpc = |id| {
        let graph = graph.clone();
        move |method: &str, params: Value| -> graffitty_graph_protocol::Result<Value> {
            Ok(graph.borrow_mut().dispatch(id, method, &params)?)
        }
    };
    let source = Session::start(rpc(1), true).unwrap();
    let receiver = Session::start(rpc(2), true).unwrap();
    let mut manifest: Manifest =
        serde_json::from_value(fixtures()["valid"][1]["manifest"].clone()).unwrap();
    source.register(&manifest).unwrap();
    let mut target = Manifest::new("Receiver");
    target.inputs.push(InputPort::new("in"));
    receiver.register(&target).unwrap();
    for (port, read, send, completed) in [
        ("send", false, true, false),
        ("read", true, false, false),
        ("done", true, false, true),
    ] {
        let edge = source
            .call(
                "graph.connect",
                json!({"from":"%1","to":"%2","from_port":port,"to_port":"in"}),
            )
            .unwrap();
        assert_eq!(
            (
                edge["read"].as_bool(),
                edge["send"].as_bool(),
                edge["turn_completed"].as_bool()
            ),
            (Some(read), Some(send), Some(completed))
        );
    }
    assert!(graph.borrow().can_read("%1", "%2"));
    assert_eq!(graph.borrow().nodes["%1"]["transport"], "inbox");
    assert!(graph.borrow().nodes["%1"]["heartbeat_at"].is_number());
    source
        .emit(
            &Output::text("send", "hello").with_payload(json!({"ok":true})),
            None,
            None,
        )
        .unwrap();
    let events = receiver.take().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].payload, json!({"ok":true}));
    receiver.ack(&events[0].event_id).unwrap();
    source
        .event("Stop", json!({"text":"finished","completion_id":"1"}))
        .unwrap();
    let events = receiver.take().unwrap();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].source_port, "done");
    assert_eq!(events[0].event_type, "turn.completed");
    receiver.ack(&events[0].event_id).unwrap();
    let edges = graph.borrow().snapshot()["edges"].clone();
    manifest.name = "Renamed".into();
    manifest.outputs[0].port.icon = Some("✅".into());
    source.register(&manifest).unwrap();
    assert_eq!(graph.borrow().snapshot()["edges"], edges);
    manifest.outputs.retain(|p| p.mode == PortMode::Send);
    source.register(&manifest).unwrap();
    assert_eq!(
        graph.borrow().snapshot()["edges"].as_array().unwrap().len(),
        1
    );
    assert!(!graph.borrow().can_read("%1", "%2"));
    drop(source);
    assert_eq!(graph.borrow().nodes["%1"]["status"], "offline");
}
