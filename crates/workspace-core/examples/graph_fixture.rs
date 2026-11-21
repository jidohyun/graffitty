//! Isolated graph authority for frontend tests. No PTYs, provider workers or user state.
//! Build with: cargo build -p graffitty-workspace-core --example graph_fixture
use graffitty_workspace_core::graph::Graph;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::TcpListener,
    path::PathBuf,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let directory = PathBuf::from(
        std::env::args()
            .nth(1)
            .ok_or("Expected fixture directory")?,
    );
    let listener = TcpListener::bind("127.0.0.1:0")?;
    std::fs::write(
        directory.join("ready.json"),
        json!({"port":listener.local_addr()?.port()}).to_string(),
    )?;
    let (mut socket, _) = listener.accept()?;
    socket.set_nodelay(true)?;
    let mut graph = Graph::default();
    loop {
        let mut header = [0; 4];
        if socket.read_exact(&mut header).is_err() {
            break;
        }
        let size = u32::from_le_bytes(header) as usize;
        if size > 4 * 1024 * 1024 {
            return Err("Fixture request too large".into());
        }
        let mut bytes = vec![0; size];
        socket.read_exact(&mut bytes)?;
        let request: Value = serde_json::from_slice(&bytes)?;
        if let Some(nodes) = request["nodes"].as_object() {
            for (key, node) in nodes {
                let existing = graph.nodes.entry(key.clone()).or_insert(json!({}));
                existing
                    .as_object_mut()
                    .unwrap()
                    .extend(node.as_object().unwrap().clone());
            }
        }
        let result = if request["method"] == "fixture.record" {
            graph.record_delivery(
                &request["params"]["event"],
                request["params"]["status"].as_str().unwrap_or(""),
                request["params"]["pending"] == true,
            );
            Ok(json!({"ok":true}))
        } else {
            graph.dispatch(
                request["id"].as_u64().unwrap_or(0),
                request["method"].as_str().unwrap_or("graph.list"),
                &request["params"],
            )
        };
        let mut response = match result {
            Ok(result) => json!({"result":result}),
            Err(message) => json!({"error":{"code":"graph_error","message":message}}),
        };
        response["snapshot"] = graph.snapshot();
        let bytes = serde_json::to_vec(&response)?;
        socket.write_all(&(bytes.len() as u32).to_le_bytes())?;
        socket.write_all(&bytes)?;
    }
    Ok(())
}
