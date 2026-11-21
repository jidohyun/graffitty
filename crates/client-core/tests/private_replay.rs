//! Real private IPC exercises auth, interleaved stream replay and cancellation.
use graffitty_client_core::{
    client::{Client, Event},
    mirror::Mirror,
    server::{AttachOptions, Connection, Launch, Paths},
    transport::ClientTransport,
};
use graffitty_protocol::SessionId;
use graffitty_transport::ipc::{self as ipc, Packet, Peer};
use serde_json::{Value, json};
use std::{
    io,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

fn read(peer: &mut Peer) -> Packet {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match peer.read() {
            Ok(packet) => return packet,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(1))
            }
            Err(e) => panic!("{e}"),
        }
    }
}
fn text(peer: &mut Peer) -> Value {
    let Packet::Text(bytes) = read(peer) else {
        panic!("Expected request, not a replay-generated VT reply");
    };
    serde_json::from_slice(&bytes).unwrap()
}
fn send(peer: &mut Peer, value: Value) {
    peer.send(Packet::Text(serde_json::to_vec(&value).unwrap()))
        .unwrap();
}

#[test]
fn idle_window_wakes_for_output_without_consuming_it_and_coalesces_bursts() {
    let directory = tempfile::tempdir().unwrap();
    let paths = Paths::in_directory(directory.path().into()).unwrap();
    let socket = paths.directory.join("w");
    let listener = ipc::bind(&socket).unwrap();
    let mut client = Client::new(ClientTransport::Local(Peer::new(
        ipc::connect(&format!("ipc://{}", socket.display())).unwrap(),
    )));
    let mut server = Peer::new(ipc::accept(&listener).unwrap());
    assert!(client.poll().unwrap().is_empty());
    let wakeup = client.wakeup().unwrap();
    assert!(!wakeup.is_ready());
    let (send_wake, wakes) = mpsc::channel();
    let subscription = wakeup.subscribe(move || { let _ = send_wake.send(()); }).unwrap();
    assert!(wakes.recv_timeout(Duration::from_millis(80)).is_err(), "Idle must not request frames");
    for n in 0..4 { send(&mut server, json!({"type":"test_wakeup","n":n})); }
    wakes.recv_timeout(Duration::from_secs(3)).expect("Output wakes an idle window");
    assert!(wakes.recv_timeout(Duration::from_millis(40)).is_err(), "One pending repaint per burst");
    let events = client.poll().unwrap();
    assert_eq!(events.len(), 4, "Readiness must not steal stream bytes");
    assert!(matches!(&events[3], Event::Message(v) if v["n"] == 3));
    assert!(!wakeup.is_ready());
    subscription.rearm();
    // Acknowledging a completed frame must not wake this same window again
    // merely because its own poll advanced the shared revision.
    assert!(wakes.recv_timeout(Duration::from_millis(80)).is_err());
    drop(server);
    wakes.recv_timeout(Duration::from_secs(3)).expect("EOF wakes the session owner");
    assert!(client.poll().is_err());
    drop(subscription);
}

#[test]
fn draining_one_window_keeps_sibling_windows_and_late_arrivals_awake() {
    let directory = tempfile::tempdir().unwrap();
    let paths = Paths::in_directory(directory.path().into()).unwrap();
    let socket = paths.directory.join("windows");
    let listener = ipc::bind(&socket).unwrap();
    let mut client = Client::new(ClientTransport::Local(Peer::new(
        ipc::connect(&format!("ipc://{}", socket.display())).unwrap(),
    )));
    let mut server = Peer::new(ipc::accept(&listener).unwrap());
    let wakeup = client.wakeup().unwrap();
    let (first_send, first_wakes) = mpsc::channel();
    let first = wakeup.subscribe(move || { let _ = first_send.send(()); }).unwrap();
    let (sibling_send, sibling_wakes) = mpsc::channel();
    let sibling = wakeup.subscribe(move || { let _ = sibling_send.send(()); }).unwrap();
    // The sibling is between frames when the first window drains shared input.
    sibling.rearm_after(Duration::from_millis(250));
    send(&mut server, json!({"type":"first_window_output"}));
    first_wakes.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(client.poll().unwrap().len(), 1);
    assert!(!wakeup.is_ready());
    first.rearm();
    sibling_wakes.recv_timeout(Duration::from_secs(3))
        .expect("A sibling must observe changes even after the stream was drained");
    assert!(first_wakes.recv_timeout(Duration::from_millis(80)).is_err(),
        "The draining window must not receive a redundant revision wake");
    // Rearming must preserve bytes which arrive after the last frame's poll.
    first.rearm_after(Duration::from_millis(250));
    send(&mut server, json!({"type":"late_output"}));
    first.rearm();
    first_wakes.recv_timeout(Duration::from_secs(3))
        .expect("Late unread input must survive revision acknowledgement");
    assert!(matches!(&client.poll().unwrap()[0], Event::Message(v) if v["type"] == "late_output"));
}

#[test]
fn final_reply_and_session_closed_are_delivered_before_eof() {
    for with_event in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let paths = Paths::in_directory(directory.path().into()).unwrap();
        let socket = paths.directory.join("s");
        let listener = ipc::bind(&socket).unwrap();
        let mut client = Client::new(ClientTransport::Local(Peer::new(
            ipc::connect(&format!("ipc://{}", socket.display())).unwrap(),
        )));
        let mut server = Peer::new(ipc::accept(&listener).unwrap());
        let request = client
            .request_async(json!({"type":"close_group","tab":1}))
            .unwrap();
        assert_eq!(text(&mut server)["request"], request);
        send(&mut server, json!({"type":"ack","request":request}));
        if with_event {
            send(
                &mut server,
                json!({"type":"session_closed","workspace":"test"}),
            );
        }
        drop(server);
        let events = client.poll().unwrap();
        assert_eq!(
            events
                .iter()
                .any(|e| matches!(e, Event::Message(v) if v["type"] == "session_closed")),
            with_event
        );
        assert!(client.take_reply(request).unwrap().is_ok());
        assert!(client.poll().is_err());
    }
}

#[test]
fn requiring_existing_session_never_launches_an_owner() {
    let directory = tempfile::tempdir().unwrap();
    let paths = Paths::in_directory(directory.path().into()).unwrap();
    let launch = Launch {
        binary: directory.path().join("must-not-launch"),
        shell: Some("/bin/sh".into()),
        working_directory: None,
    };
    let mut options = AttachOptions::default();
    options
        .capabilities
        .insert("require_workspace".into(), json!(true));
    let error = Connection::connect_or_start(&paths.descriptor, &launch, &options)
        .err()
        .unwrap();
    assert!(
        !error.to_string().contains("server binary"),
        "Attach must not attempt startup: {error:#}"
    );
    assert!(!paths.descriptor.exists());
}

#[test]
fn attachment_and_requests_preserve_interleaved_vt_replay() {
    let directory = tempfile::Builder::new()
        .prefix("gr-core-")
        .tempdir_in(std::env::temp_dir())
        .unwrap();
    let paths = Paths::in_directory(directory.path().into()).unwrap();
    let socket = directory.path().join("s");
    let listener = ipc::bind(&socket).unwrap();
    std::fs::write(&paths.descriptor, serde_json::to_vec(&json!({
        "pid":std::process::id(), "local":{"url":format!("ipc://{}",socket.display()),"token":"private-fixture"}
    })).unwrap()).unwrap();
    let (sent, received) = mpsc::channel();
    let (done, stop) = mpsc::channel();
    let worker = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match ipc::accept(&listener) {
                Ok(stream) => break stream,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(1))
                }
                Err(e) => panic!("{e}"),
            }
        };
        let mut peer = Peer::new(stream);
        let auth = text(&mut peer);
        assert_eq!(auth["type"], "auth_local");
        assert_eq!(auth["token"], "private-fixture");
        assert_eq!(auth["workspace"], "test");
        send(&mut peer, json!({"type":"ready","version":graffitty_protocol::VERSION}));
        send(&mut peer, json!({"type":"topology","sessions":[{"id":41}]}));
        let request = text(&mut peer);
        // Snapshot replay must not emit application queries. A live delta may
        // be folded into the pending snapshot before UI delivery; neither path
        // may write protocol replies to the owner PTY.
        for (revision, snapshot, bytes) in [
            (1, true, "한글 output\x1b[c\x1b]52;c;?\x07".as_bytes()),
            (2, false, b"\x1b[c\x1b]52;c;?\x07 delta done".as_slice()),
        ] {
            let header = json!({"type":"terminal","session":41,"columns":24,"rows":4,
                "limits":{"kitty_image_storage_mb":0},"exited":false,
                "scene":{"revision":revision,"base":revision-1,"snapshot":snapshot,"replace":false,
                    "offset":0,"total":bytes.len(),"graphics_bytes":0,"commit":true}});
            peer.send(Packet::Binary(graffitty_protocol::pack(&header, bytes).unwrap())).unwrap();
        }
        send(
            &mut peer,
            json!({"type":"notification","session":41,"title":"Interleaved"}),
        );
        send(
            &mut peer,
            json!({"type":"ack","request":request["request"],"ok":true}),
        );
        let conflict = text(&mut peer);
        send(
            &mut peer,
            json!({"type":"error","request":conflict["request"],
            "message":"Workspace changed","code":"conflict","workspace_state":{"revision":9}}),
        );
        let canceled = text(&mut peer);
        send(
            &mut peer,
            json!({"type":"ack","request":canceled["request"]}),
        );
        send(
            &mut peer,
            json!({"type":"notification","title":"After cancel"}),
        );
        sent.send(()).unwrap();
        let Packet::Binary(bytes) = read(&mut peer) else {
            panic!("Expected explicit user input");
        };
        let (header, bytes) = graffitty_protocol::unpack(&bytes, ipc::MAX_PACKET).unwrap();
        assert_eq!(header["session"], 41);
        assert_eq!(bytes, b"user input");
        stop.recv_timeout(Duration::from_secs(5)).unwrap();
    });
    let options = AttachOptions {
        workspace: "test".into(),
        ..Default::default()
    };
    let mut connection = Connection::attach(&paths.descriptor, &options).unwrap();
    assert_eq!(connection.server_pid, Some(std::process::id()));
    let mut mirror = Mirror::new(24, 4, (10, 22), Default::default()).unwrap();
    let mut topology = false;
    let mut notified = false;
    let reply = connection
        .client
        .request(
            json!({"type":"snapshot"}),
            Duration::from_secs(5),
            |event| match event {
                Event::Topology(_) => topology = true,
                Event::Notification(_) => notified = true,
                Event::Scene {
                    session,
                    commit,
                } => {
                    assert_eq!(session, SessionId(41));
                    mirror.apply_scene(commit).unwrap();
                }
                _ => {}
            },
        )
        .unwrap();
    assert_eq!(reply["ok"], true);
    assert!(topology && notified);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !mirror.text(true).unwrap().contains("delta done") {
        for event in connection.client.poll().unwrap() {
            if let Event::Scene { session, commit } = event {
                assert_eq!(session, SessionId(41));
                mirror.apply_scene(commit).unwrap();
            }
        }
        assert!(Instant::now() < deadline, "Scene did not finish preparing");
        thread::sleep(Duration::from_millis(1));
    }
    assert!(mirror.text(true).unwrap().contains("한글 output"));
    assert_eq!(mirror.limits.kitty_image_storage_mb, 0);
    // If the delta was materialized in the mailbox it has no callbacks. If
    // the UI consumed the snapshot first, the live mirror sees its query.
    //
    // Real notification events above are delivered independently in either
    // case.
    assert!(mirror.events.drain().len() <= 1);
    let conflict = connection
        .client
        .request_async(json!({"type":"workspace_edit"}))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        connection.client.poll().unwrap();
        if let Some(reply) = connection.client.take_reply_message(conflict) {
            assert_eq!(reply["workspace_state"]["revision"], 9);
            assert_eq!(reply["code"], "conflict");
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    let canceled = connection
        .client
        .request_async(json!({"type":"cancel_fixture"}))
        .unwrap();
    connection.client.cancel_request(canceled);
    received.recv_timeout(Duration::from_secs(5)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if connection
            .client
            .poll()
            .unwrap()
            .into_iter()
            .any(|e| matches!(e, Event::Notification(_)))
        {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(1));
    }
    assert!(connection.client.take_reply(canceled).is_none());
    connection
        .client
        .input(SessionId(41), b"user input")
        .unwrap();
    done.send(()).unwrap();
    worker.join().unwrap();
    // Dropping an attachment owns no process and never terminates the peer.
    drop(connection);
}

#[test]
fn graph_reception_is_typed_and_atomic_for_every_frontend() {
    let directory = tempfile::tempdir().unwrap();
    let paths = Paths::in_directory(directory.path().into()).unwrap();
    let socket = paths.directory.join("graph");
    let listener = ipc::bind(&socket).unwrap();
    let mut client = Client::new(ClientTransport::Local(Peer::new(
        ipc::connect(&format!("ipc://{}", socket.display())).unwrap(),
    )));
    let mut server = Peer::new(ipc::accept(&listener).unwrap());
    send(&mut server,json!({"type":"topology","graph":{"nodes":[{"node":"%1","kind":"custom","manifest":{
        "name":"Manual Prompt","inputs":[],"outputs":[{"id":"out","line_style":"solid"}]}}]}}));
    let events = client.poll().unwrap();
    assert!(matches!(&events[0],Event::Topology(_)));
    let graph=client.graph().unwrap().clone();
    assert_eq!(graph.nodes[0].kind,Some(graffitty_protocol::graph::NodeKind::Custom));
    assert!(graph.nodes[0].provider.is_none() && graph.nodes[0].session_id.is_none());
    send(&mut server,json!({"type":"topology","graph":{"nodes":[{"node":"%1","provider":false}]}}));
    assert!(client.poll().is_err());
    assert_eq!(client.graph(),Some(&graph));
    send(&mut server,json!({"type":"session_switched","workspace":"next"}));
    client.poll().unwrap();
    assert!(client.graph().is_none());
}

#[test]
fn terminal_packets_require_a_scene_transaction() {
    for stream in [false, true] {
        let directory = tempfile::tempdir().unwrap();
        let paths = Paths::in_directory(directory.path().into()).unwrap();
        let socket = paths.directory.join("s");
        let listener = ipc::bind(&socket).unwrap();
        let mut client = Client::new(ClientTransport::Local(Peer::new(
            ipc::connect(&format!("ipc://{}", socket.display())).unwrap(),
        )));
        let mut server = Peer::new(ipc::accept(&listener).unwrap());
        let header = json!({"type":"terminal","session":1,"columns":24,"rows":4,
            "limits":{},"reset":true,"exited":false,"stream":stream});
        server.send(Packet::Binary(graffitty_protocol::pack(&header, b"old packet").unwrap())).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match client.poll() {
                Err(_) => break,
                Ok(events) => assert!(events.is_empty(), "Obsolete terminal packet was accepted"),
            }
            assert!(Instant::now() < deadline, "Obsolete terminal packet was not rejected");
            thread::sleep(Duration::from_millis(1));
        }
    }
}
