use graffitty_graph_protocol::{Client, MAX_REQUEST, Rpc, read_message};
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, Cursor, Write},
    net::TcpListener,
};

#[test]
fn authenticated_loopback_exchange_and_host_errors() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let client = Client::new(
        format!("tcp://{}", listener.local_addr().unwrap()),
        "secret-token",
    );
    assert!(!format!("{client:?}").contains("secret-token"));
    let thread = std::thread::spawn(move || {
        for fail in [false, true, false] {
            let (mut socket, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(&socket).read_line(&mut line).unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["token"], "secret-token");
            let reply = if fail {
                json!({"id":request["id"],"error":{"code":"denied","message":"Permission denied"}})
            } else if request["method"] == "wrong.id" {
                json!({"id":"wrong","result":{}})
            } else {
                json!({"id":request["id"],"result":{"ok":true}})
            };
            writeln!(socket, "{reply}").unwrap();
        }
    });
    assert_eq!(
        client.call("agent.heartbeat", json!({})).unwrap()["ok"],
        true
    );
    assert!(
        client
            .call("graph.forward", json!({}))
            .unwrap_err()
            .to_string()
            .contains("Permission denied")
    );
    assert!(
        client
            .call("wrong.id", json!({}))
            .unwrap_err()
            .to_string()
            .contains("response ID")
    );
    thread.join().unwrap();
}

#[test]
fn rejects_incomplete_lines_and_oversized_requests_before_connecting() {
    assert!(read_message(&mut Cursor::new(b"{}".to_vec())).is_err());
    assert!(
        read_message(&mut Cursor::new(Vec::<u8>::new()))
            .unwrap()
            .is_none()
    );
    let client = Client::new("/nonexistent/api.sock", "test");
    assert!(
        client
            .call("graph.emit", json!({"text":"x".repeat(MAX_REQUEST)}))
            .unwrap_err()
            .to_string()
            .contains("accepts at most")
    );
}
