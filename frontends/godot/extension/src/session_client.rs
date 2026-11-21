//! Godot adapter for the common client. The server owns every PTY and chromium;
//! dropping this object only detaches the graphical frontend.
use anyhow::{Context, Result, ensure};
use godot::{classes::{IRefCounted, RefCounted}, prelude::*};
use graffitty_client_core::{client::Event, server::{AttachOptions, Connection, Launch, Paths}};
use serde_json::{Value, json};
use std::{path::{Path, PathBuf}};

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct SessionClient {
    base: Base<RefCounted>,
    connection: Option<graffitty_client_core::connection_worker::Worker>,
    error: String,
}
#[godot_api]
impl IRefCounted for SessionClient {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, connection: None, error: String::new() }
    }
}

impl SessionClient {
    fn connect(&mut self, options: Value) -> Result<()> {
        let descriptor = options["descriptor"].as_str().filter(|v| !v.is_empty())
            .map(PathBuf::from).or_else(|| std::env::var_os("GRAFFITTY_SERVER_DESCRIPTOR").map(PathBuf::from));
        let descriptor = match descriptor { Some(path) => path, None => Paths::discover()?.descriptor };
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).context("Missing repository root")?;
        let binary = options["server"].as_str().filter(|v| !v.is_empty()).map(PathBuf::from)
            .or_else(|| std::env::var_os("GRAFFITTY_SERVER").map(PathBuf::from))
            .unwrap_or_else(|| {
                let name = if cfg!(windows) { "gft.exe" } else { "gft" };
                [root.join("dist/bin").join(name), root.join("target/release").join(name), root.join("target/debug").join(name)]
                    .into_iter().find(|p| p.is_file()).unwrap_or_else(|| PathBuf::from(name))
            });
        // Only an explicit launch shell overrides the server's configured default.
        let shell = options["shell"].as_str().filter(|v| !v.is_empty()).map(str::to_owned);
        let launch = Launch { binary, shell, working_directory: options["directory"].as_str().filter(|v| !v.is_empty()).map(PathBuf::from) };
        let mut attach = AttachOptions::default();
        if let Some(capabilities) = options["capabilities"].as_object() { attach.capabilities.extend(capabilities.clone()); }
        // No name and a fallback: the server picks the session a frontend showed last.
        let resume = attach.capabilities.get("workspace_fallback") == Some(&json!(true));
        if let Some(workspace) = options["workspace"].as_str().filter(|v| !v.is_empty() || resume) { attach.workspace = workspace.into(); }
        let features = attach.capabilities.entry("features").or_insert_with(|| json!([]));
        if let Some(features) = features.as_array_mut() { features.push(json!("clipboard")); }
        self.connection = Some(graffitty_client_core::connection_worker::Worker::new(Connection::connect_or_start(&descriptor, &launch, &attach)?));
        Ok(())
    }
    fn packet(packets: &mut Array<VarDictionary>, text: bool, bytes: &[u8]) {
        let mut packet = VarDictionary::new();
        packet.set("text", text);
        packet.set("data", &PackedByteArray::from(bytes));
        packets.push(&packet);
    }
    fn json_packet(packets: &mut Array<VarDictionary>, value: &Value) -> Result<()> {
        Self::packet(packets, true, &serde_json::to_vec(value)?);
        Ok(())
    }
}
#[godot_api]
impl SessionClient {
    #[func]
    fn rebase_workspace_tab(&self, input: GString) -> GString {
        let result = (|| -> Result<Value> {
            use graffitty_workspace_core::{merge::{TabPatch, rebase_settings}, state::TabSettings, tiling::TabLayout};
            let value: Value = serde_json::from_str(&input.to_string())?;
            let before: TabLayout = serde_json::from_value(value["before"]["layout"].clone())?;
            let after: TabLayout = serde_json::from_value(value["after"]["layout"].clone())?;
            let current: TabLayout = serde_json::from_value(value["current"]["layout"].clone())?;
            let layout = TabPatch::between(&before, &after)?.rebase(&current)?;
            let before_settings: TabSettings = serde_json::from_value(value["before"]["settings"].clone())?;
            let after_settings: TabSettings = serde_json::from_value(value["after"]["settings"].clone())?;
            let current_settings: TabSettings = serde_json::from_value(value["current"]["settings"].clone())?;
            Ok(json!({"layout":layout,"settings":rebase_settings(&before_settings,&after_settings,&current_settings)?}))
        })();
        match result { Ok(value) => value, Err(error) => json!({"error":format!("{error:#}")}) }.to_string().as_str().into()
    }

    #[func]
    fn connect_shared(&mut self, options: GString) -> bool {
        self.connection = None;
        self.error.clear();
        match serde_json::from_str(&options.to_string()).context("Invalid shared session options").and_then(|value| self.connect(value)) {
            Ok(()) => true,
            Err(error) => { self.error = format!("{error:#}"); false }
        }
    }
    #[func]
    fn is_open(&self) -> bool { self.connection.is_some() }
    #[func]
    fn last_error(&self) -> GString { self.error.as_str().into() }
    #[func]
    fn server_pid(&self) -> i64 { self.connection.as_ref().and_then(|c| c.server_pid).map_or(-1, i64::from) }
    #[func]
    fn local_peer_pid(&self) -> i64 { self.connection.as_ref().and_then(|c| c.peer_pid).map_or(-1, i64::from) }
    #[func]
    fn disconnect_private(&mut self) { self.connection = None; }
    #[func]
    fn send_packet(&mut self, bytes: PackedByteArray, text: bool) -> bool {
        let Some(connection) = &mut self.connection else { return false; };
        let result = (|| -> Result<()> {
            if text {
                let value: Value = serde_json::from_slice(bytes.as_slice())?;
                connection.send(value)?;
            } else {
                let (header, data) = graffitty_protocol::unpack(bytes.as_slice(), graffitty_session_transport::MAX_PACKET)?;
                if header["type"] == "input" {
                    let session = header["session"].as_u64().context("Missing terminal input session")?;
                    connection.input(graffitty_protocol::SessionId(session), data.to_vec())?;
                } else {
                    ensure!(header["type"] == "rpc" && matches!(header["method"].as_str(), Some("dictation.append" | "dictation.live.append")), "Unsupported binary session request");
                    connection.binary(header, data.to_vec())?;
                }
            }
            Ok(())
        })();
        match result { Ok(()) => true, Err(error) => { self.error = format!("{error:#}"); false } }
    }
    #[func]
    fn poll_packets(&mut self) -> Array<VarDictionary> {
        let mut packets = Array::new();
        let Some(connection) = &mut self.connection else { return packets; };
        let result = (|| -> Result<()> {
            for _ in 0..64 {
                let event = match connection.output.try_recv() {
                    Ok(Ok(event)) => event,
                    Ok(Err(error)) => return Err(anyhow::anyhow!(error)),
                    Err(std::sync::mpsc::TryRecvError::Empty) => break,
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => return Err(anyhow::anyhow!("Session connection closed")),
                };
                match event {
                    Event::Scene { session, commit } => packets.push(&crate::terminal_scene::TerminalSceneUpdate::packet(session.0, Some(commit), None)),
                    Event::Asset { session, pixels } => packets.push(&crate::terminal_scene::TerminalSceneUpdate::packet(session.0, None, Some(pixels))),
                    Event::Ready(value) | Event::Topology(value) | Event::Resources(value) | Event::Notification(value)
                    | Event::FrontendRequest(value) | Event::Message(value) => Self::json_packet(&mut packets, &value)?,
                    Event::Chromium { header, bytes, .. } => {
                        // The common client already decoded framing. Do not pack the
                        // entire video payload again just for Godot to unpack it.
                        let mut packet = VarDictionary::new();
                        packet.set("chromium_header", header.to_string().as_str());
                        packet.set("data", &PackedByteArray::from(bytes.as_slice()));
                        packets.push(&packet);
                    }
                    Event::Binary { header, bytes } => {
                        Self::packet(&mut packets, false, &graffitty_protocol::pack(&header, &bytes)?);
                    }
                }
            }
            Ok(())
        })();
        if let Err(error) = result { self.error = format!("{error:#}"); self.connection = None; }
        packets
    }
}
