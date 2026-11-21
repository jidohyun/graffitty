//! Join the TUI-owned codex_tui TCP listener to the daemon's per-thread MCP origin.
//! No launch interception, title changes, screen parsing, or tool invocation.
#[cfg(unix)]
use std::os::unix::{fs::{FileTypeExt, MetadataExt}, net::UnixStream};
#[cfg(windows)]
use uds_windows::UnixStream;
use crate::agent_bridge::Result;
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    path::Path,
    time::{Duration, Instant},
};
#[cfg(unix)]
use std::{fs, process::Command};
use tungstenite::{Message, WebSocket};

pub struct Rpc {
    socket: WebSocket<UnixStream>,
    id: u64,
    deadline: Instant,
}
impl Rpc {
    pub fn connect(home: &Path) -> Result<Self> {
        let path = home.join("app-server-control/app-server-control.sock");
        #[cfg(unix)]
        let meta = fs::metadata(&path)?;
        #[cfg(unix)]
    if !meta.file_type().is_socket() || meta.uid() != unsafe { libc::geteuid() } {
            return Err("Invalid Codex daemon socket owner/type".into());
        }
        Self::from_stream(UnixStream::connect(path)?)
    }
    fn from_stream(stream: UnixStream) -> Result<Self> {
        stream.set_read_timeout(Some(Duration::from_secs(3)))?;
        stream.set_write_timeout(Some(Duration::from_secs(3)))?;
        let (socket, _) = tungstenite::client("ws://localhost/", stream)?;
        let mut rpc = Self {
            socket,
            id: 0,
            deadline: Instant::now() + Duration::from_secs(12),
        };
        rpc.call("initialize", json!({"clientInfo":{"name":"graffitty_discovery","version":env!("GRAFFITTY_VERSION")},"capabilities":{"experimentalApi":true}}))?;
        rpc.socket.send(Message::Text(
            json!({"method":"initialized"}).to_string().into(),
        ))?;
        Ok(rpc)
    }
    pub fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        self.id += 1;
        self.socket.send(Message::Text(
            json!({"id":self.id,"method":method,"params":params})
                .to_string()
                .into(),
        ))?;
        loop {
            if Instant::now() >= self.deadline {
                return Err("Codex discovery timed out".into());
            }
            if let Message::Text(text) = self.socket.read()? {
                let response: Value = serde_json::from_str(&text)?;
                if response["id"] == self.id {
                    if let Some(error) = response.get("error") {
                        return Err(error.to_string().into());
                    }
                    return Ok(response["result"].clone());
                }
            }
        }
    }
}

#[cfg(any(unix, test))]
fn linux_ports(tcp: &str, inodes: &HashSet<String>) -> HashSet<u16> {
    tcp.lines()
        .skip(1)
        .filter_map(|line| {
            let f: Vec<_> = line.split_whitespace().collect();
            if f.len() < 10 || f[3] != "0A" || !inodes.contains(f[9]) {
                return None;
            }
            let (address, port) = f[1].split_once(':')?;
            if address != "0100007F" {
                return None;
            }
            u16::from_str_radix(port, 16).ok()
        })
        .collect()
}
#[cfg(any(unix, test))]
fn lsof_ports(text: &str) -> HashSet<u16> {
    text.lines()
        .filter_map(|line| line.strip_prefix("n127.0.0.1:")?.parse().ok())
        .collect()
}
#[cfg(windows)]
pub fn listener_ports(pid: i64) -> HashSet<u16> { crate::platform::listener_ports(pid) }
#[cfg(unix)]
pub fn listener_ports(pid: i64) -> HashSet<u16> {
    if let Ok(entries) = fs::read_dir(format!("/proc/{pid}/fd")) {
        let inodes = entries
            .flatten()
            .filter_map(|entry| {
                let path = fs::read_link(entry.path()).ok()?;
                let text = path.to_string_lossy();
                Some(text.strip_prefix("socket:[")?.strip_suffix(']')?.to_owned())
            })
            .collect();
        return linux_ports(
            &fs::read_to_string(format!("/proc/{pid}/net/tcp")).unwrap_or_default(),
            &inodes,
        );
    }
    Command::new("lsof")
        .args([
            "-n",
            "-P",
            "-a",
            "-p",
            &pid.to_string(),
            "-iTCP",
            "-sTCP:LISTEN",
            "-Fn",
        ])
        .output()
        .ok()
        .map(|o| lsof_ports(&String::from_utf8_lossy(&o.stdout)))
        .unwrap_or_default()
}
fn origin_port(origin: &str) -> Option<u16> {
    origin.strip_prefix("http://127.0.0.1:")?.parse().ok()
}

/// All loaded root threads with their configured TUI listener origins. Metadata only.
pub fn inventory(rpc: &mut Rpc) -> Result<Vec<Value>> {
    let mut cursor = Value::Null;
    let mut records = vec![];
    let mut pages = HashSet::new();
    loop {
        let page = rpc.call("thread/loaded/list", json!({"limit":100,"cursor":cursor}))?;
        for id in page["data"].as_array().ok_or("Missing loaded thread IDs")? {
            let id = id.as_str().ok_or("Invalid loaded thread ID")?;
            uuid::Uuid::parse_str(id)?;
            let response = rpc.call("thread/read", json!({"threadId":id,"includeTurns":false}))?;
            let thread = &response["thread"];
            if thread["ephemeral"] == true
                || thread["parentThreadId"].is_string()
                || thread["source"].get("subagent").is_some()
            {
                continue;
            }
            let mcp = rpc.call(
                "mcpServerStatus/list",
                json!({"threadId":id,"serverName":"codex_tui","detail":"toolsAndAuthOnly"}),
            )?;
            for server in mcp["data"].as_array().ok_or("Missing MCP inventory")? {
                if server["name"] == "codex_tui" {
                    if let Some(port) = server["httpOrigin"].as_str().and_then(origin_port) {
                        let mut record = json!({"thread":thread,"port":port});
                        // Errors are transient rollout events. Read only the newest
                        // turn summary, whose status distinguishes failure/interruption.
                        if thread["path"].is_string() {
                            match rpc.call("thread/turns/list", json!({"threadId":id,"limit":1,"sortDirection":"desc","itemsView":"summary"})) {
                                Ok(page) => record["turn"] = page["data"].as_array().and_then(|turns| turns.first())
                                    .map(|turn| json!({"id":turn["id"],"status":turn["status"],"error":turn["error"]})).unwrap_or(Value::Null),
                                Err(error) => record["turn_error"] = json!(error.to_string()),
                            }
                        } else {
                            record["turn"] = Value::Null;
                        }
                        records.push(record);
                    }
                }
            }
        }
        cursor = page["nextCursor"].clone();
        if cursor.is_null() {
            return Ok(records);
        }
        if !pages.insert(cursor.to_string()) || pages.len() >= 10 {
            return Err("Codex inventory pagination did not finish".into());
        }
    }
}

pub fn select(records: &[Value], ports: &HashSet<u16>, home: &Path) -> Result<Value> {
    let candidates: Vec<_> = records
        .iter()
        .filter(|r| {
            r["port"]
                .as_u64()
                .is_some_and(|p| p <= 65535 && ports.contains(&(p as u16)))
        })
        .collect();
    if candidates.len() != 1 {
        return Err(format!(
            "Codex listener matches {} main threads; active thread is unresolved",
            candidates.len()
        )
        .into());
    }
    let record = candidates[0];
    let thread = &record["thread"];
    let status = match thread["status"]["type"].as_str().unwrap_or("") {
        "idle" => "idle",
        "active"
            if thread["status"]["activeFlags"]
                .as_array()
                .is_some_and(|flags| flags.iter().any(|flag| matches!(flag.as_str(), Some("waitingOnApproval" | "waitingOnUserInput")))) =>
        {
            "waiting"
        }
        "active" => "busy",
        _ => "unknown",
    };
    let mut state = json!({"session_id":thread["id"],"transcript_path":thread["path"],"provider_home":home,
        "status":status,"discovery_transport":"codex_tui_listener","listener_port":record["port"],
        "queue_error":null,"discovery_note":record["turn_error"]});
    if let Some(turn) = record.get("turn") {
        state["observed_turn"] = turn.clone();
    }
    Ok(state)
}

fn same_binding(found: &Value, target: &Value) -> bool {
    found["session_id"].is_string()
        && found["session_id"] == target["session_id"]
        // Godot's JSON round trip converts integer ports into floating numbers.
        // Every u16 port is exactly representable as f64; compare its value.
        && found["listener_port"].is_number()
        && found["listener_port"].as_f64() == target["listener_port"].as_f64()
}

pub fn verify(target: &Value, home: &Path, pid: i64) -> Result<Rpc> {
    let ports = listener_ports(pid);
    if ports.is_empty() {
        return Err("Codex frontend listener disappeared".into());
    }
    let mut rpc = Rpc::connect(home)?;
    let found = select(&inventory(&mut rpc)?, &ports, home)?;
    if !same_binding(&found, target) {
        return Err("Codex frontend thread binding changed".into());
    }
    let table = crate::sessions::processes();
    if table
        .get(&pid)
        .is_none_or(|p| target["started"].as_str() != Some(p.started.as_str()))
        || listener_ports(pid) != ports
    {
        return Err("Codex process changed during verification".into());
    }
    Ok(rpc)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn binding_survives_godot_json_numbers_without_accepting_changed_identity() {
        let found = json!({"session_id":"thread-a", "listener_port":50985});
        let round_trip: Value =
            serde_json::from_str(r#"{"session_id":"thread-a","listener_port":50985.0}"#).unwrap();
        assert!(same_binding(&found, &round_trip));
        assert!(same_binding(&found, &found));
        for changed in [
            json!({"session_id":"thread-b", "listener_port":50985.0}),
            json!({"session_id":"thread-a", "listener_port":50986.0}),
            json!({"session_id":"thread-a", "listener_port":50985.5}),
            json!({"session_id":"thread-a", "listener_port":"50985"}),
            json!({"session_id":"thread-a"}),
        ] {
            assert!(!same_binding(&found, &changed));
        }
    }
    #[test]
    fn unix_port_ownership_and_origin_are_exact() {
        let inodes = HashSet::from(["42".to_owned()]);
        let table = "header\n0: 0100007F:D5C6 00000000:0000 0A 0:0 0:0 0 501 0 42\n1: 0100007F:D5C7 00000000:0000 01 0:0 0:0 0 501 0 42\n2: 0100007F:D5C8 00000000:0000 0A 0:0 0:0 0 501 0 99\n";
        assert_eq!(linux_ports(table, &inodes), HashSet::from([54726]));
        assert_eq!(
            lsof_ports("p10404\nf38\nn127.0.0.1:54726\nn*:9999\n"),
            HashSet::from([54726])
        );
        assert_eq!(origin_port("http://127.0.0.1:54726"), Some(54726));
        for bad in [
            "http://evil:54726",
            "http://127.0.0.1:54726/path",
            "https://127.0.0.1:54726",
            "http://127.0.0.1:99999",
        ] {
            assert_eq!(origin_port(bad), None);
        }
    }
    #[test]
    fn origin_join_rejects_ambiguity_and_handles_waiting() {
        let record = json!({"port":54726,"thread":{"id":"main","path":"/rollout","status":{"type":"active","activeFlags":["waitingOnApproval"]}}});
        let home = Path::new("/codex");
        let ports = HashSet::from([54726]);
        assert_eq!(
            select(&[record.clone()], &ports, home).unwrap()["status"],
            "waiting"
        );
        assert!(select(&[record.clone()], &HashSet::from([54727]), home).is_err());
        assert!(select(&[record.clone(), record], &ports, home).is_err());
    }
    #[test]
    fn input_wait_is_distinct_from_active_work_and_idle() {
        let home = Path::new("/codex");
        let ports = HashSet::from([54726]);
        for (kind, flags, expected) in [
            ("active", json!(["waitingOnUserInput"]), "waiting"),
            ("active", json!(["waitingOnApproval"]), "waiting"),
            ("active", json!([]), "busy"),
            ("active", json!(["otherFlag"]), "busy"),
            ("idle", json!([]), "idle"),
        ] {
            let record = json!({"port":54726,"thread":{"id":"main","status":{"type":kind,"activeFlags":flags}}});
            assert_eq!(select(&[record], &ports, home).unwrap()["status"], expected);
        }
    }

    #[test]
    fn daemon_protocol_probe_is_metadata_only_and_skips_subagents() {
        let (client, server) = UnixStream::pair().unwrap();
        let peer = std::thread::spawn(move || {
            let mut ws = tungstenite::accept(server).unwrap();
            let main = "11111111-1111-4111-8111-111111111111";
            let child = "22222222-2222-4222-8222-222222222222";
            let exchanges = [
                ("initialize", json!({})),
                (
                    "thread/loaded/list",
                    json!({"data":[main,child],"nextCursor":null}),
                ),
                (
                    "thread/read",
                    json!({"thread":{"id":main,"path":"/fixture/rollout.jsonl","parentThreadId":null,"status":{"type":"idle"}}}),
                ),
                (
                    "mcpServerStatus/list",
                    json!({"data":[{"name":"codex_tui","httpOrigin":"http://127.0.0.1:54726"}]}),
                ),
                (
                    "thread/turns/list",
                    json!({"data":[{"id":"failed-turn","status":"failed","error":{"message":"Rate limit exceeded"},"items":[]}],"nextCursor":null}),
                ),
                (
                    "thread/read",
                    json!({"thread":{"id":child,"parentThreadId":main}}),
                ),
            ];
            for (method, result) in exchanges {
                let request: Value = loop {
                    let text = ws.read().unwrap().into_text().unwrap();
                    let request: Value = serde_json::from_str(&text).unwrap();
                    if request["method"] == "initialized" {
                        continue;
                    }
                    break request;
                };
                assert_eq!(request["method"], method);
                if method == "thread/read" {
                    assert_eq!(request["params"]["includeTurns"], false);
                }
                if method == "thread/turns/list" {
                    assert_eq!(request["params"], json!({"threadId":main,"limit":1,"sortDirection":"desc","itemsView":"summary"}));
                }
                if method == "mcpServerStatus/list" {
                    assert_eq!(request["params"]["serverName"], "codex_tui");
                }
                ws.send(Message::Text(
                    json!({"id":request["id"],"result":result})
                        .to_string()
                        .into(),
                ))
                .unwrap();
            }
        });
        let mut rpc = Rpc::from_stream(client).unwrap();
        let records = inventory(&mut rpc).unwrap();
        assert_eq!(records.len(), 1);
        let state = select(&records, &HashSet::from([54726]), Path::new("/codex")).unwrap();
        assert_eq!(state["observed_turn"]["status"], "failed");
        assert_eq!(state["observed_turn"]["error"]["message"], "Rate limit exceeded");
        assert!(state["observed_turn"].get("items").is_none());
        assert_eq!(
            select(&records, &HashSet::from([54726]), Path::new("/codex")).unwrap()["status"],
            "idle"
        );
        peer.join().unwrap();
    }
}
