//! Session owner implementation, run by `gft server`. No Godot or windowing.
pub mod fonts;
use graffitty_platform::process_cwd;
mod chromium_video;
mod chromium_flow;
mod video_datagram;
#[cfg(any(target_os = "macos", windows))]
mod chromium_gpu;
mod terminal_scene;
mod pane_updates;
use graffitty_remote_auth as auth;
#[cfg(not(windows))]
mod chromium_capture;
#[cfg(windows)]
#[path = "chromium_capture_windows.rs"]
mod chromium_capture;
mod chromium_control;
mod chromium;
mod connection;
mod identity;
use connection::Connection;
use graffitty_session_transport as ipc;
pub use graffitty_terminal_core::{checkpoint, images, inline_images, notification_protocol, screen, terminal_protocol, terminal_text};
use graffitty_workspace_core::graph;
mod workspace;
mod session_management;
mod session_checkpoints;
mod session_switch;
mod session_registry;
#[cfg(unix)]
mod session_jobs;
mod session_transfer;
mod frontend;
mod navigator;
mod size_claims;
pub mod session;
pub mod spawn;
mod shell_hooks;
mod terminfo;
mod shell_integration;
mod workers;
mod settings;
mod agent_completion;
mod agent_context;
mod pane_claim;
mod effects_api;
mod resources;
mod wake;
mod host_auth;
mod regroup;
mod titles;
pub mod api;
mod agent_watch;
mod terminal_api;
mod controller;
mod terminal_run;
mod graph_wiring;
mod filetree;
mod dictation;
mod terminal_input;
mod typing_guard;
use api::{DispatchError, error_details};
mod close_policy;
pub mod holder;
pub mod holder_proto;
mod holder_link;
pub use holder_link::build_id;
mod owner_state;
mod clipboard;
mod file_transfer;
use serde_json::{Value, json};
pub use session::Error;
use session::Session;
mod options;
pub use options::Options;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs::{self, OpenOptions},
    io::{Read, Write},
    net::TcpListener,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
use tungstenite::{Message, protocol::WebSocketConfig};
use graffitty_protocol::VERSION;
use spawn::Prepare as _;
struct Client {
    frontend_client: u64,
    session_switch: bool,
    last_input: HashMap<u64, Instant>,
    auth: auth::wire::Session,
    socket: Connection,
    network_generation: u64,
    api_reply: Option<mpsc::Receiver<Value>>,
    api_done: bool,
    api_stream: bool,
    rpc_pending: Vec<(Value, mpsc::Receiver<Value>)>,
    authenticated: bool,
    opened: Instant,
    workspace: String,
    workspace_incarnation: u64,
    workspace_closed: bool,
    session_catalog: Value,
    subscribed: Vec<u64>,
    revisions: HashMap<u64, u64>,
    /// Structural topology signature last delivered; volatile pane fields
    /// travel as `pane_update` deltas tracked separately.
    topology: String,
    pane_updates: pane_updates::Tracker,
    scenes: terminal_scene::Replication,
    font_pending: Option<serde_json::Value>,
    bell_events: bool,
    clipboard_events: bool,
    clipboard_generations: HashMap<u64, u64>,
    #[cfg(any(target_os = "macos", windows))]
    gpu: chromium_gpu::Channels,
    video_codecs: Option<Vec<graffitty_chromium_video::Codec>>,
    /// Codecs this client could not start a decoder for, per chromium. A device
    /// can run out of hardware decoders for one more stream while its other
    /// streams keep decoding, so a refusal counts only for the pane it came from.
    video_rejected: HashMap<u64, Vec<graffitty_chromium_video::Codec>>,
    video_quality: chromium_video::Quality,
    /// Displayed physical height tier per subscribed chromium. It selects
    /// this client's video rendition and the page's shared render scale.
    chromium_viewports: HashMap<u64,u32>,
    /// Subscribed chromiums this client paused because they are off-screen
    /// or too small to read. They keep their pane state but receive no frames.
    chromium_paused: std::collections::HashSet<u64>,
    chromium_png: bool,
    /// Congested viewers get an independent encoder until unsubscribing. This
    /// preserves their P-frame history without holding healthy viewers back.
    video_isolated: std::collections::HashSet<u64>,
    video_cursors: HashMap<u64, (chromium_video::Stream, u64, u64)>,
    chromium_flow: HashMap<u64, chromium_flow::Flow>,
    /// The login's datagram cipher until `ready` offers the side channel.
    datagram_key: Option<auth::Datagram>,
    /// Chromium video beside the WebSocket, once the client confirmed a path.
    datagram: Option<video_datagram::Peer>,
    notifications: HashMap<u64, u64>,
    input_sequences: HashMap<u64, u64>,
    resources_at: Instant,
    resources_enabled: bool,
}
fn client_video_pacing(c: &Client, id: u64) -> u64 {
    if c.video_isolated.contains(&id) { c.frontend_client } else { 0 }
}
/// The codecs this client can decode for one chromium, or `None` when it
/// negotiated no hardware video at all.
fn client_video_codecs(c: &Client, id: u64) -> Option<Vec<graffitty_chromium_video::Codec>> {
    let rejected = c.video_rejected.get(&id);
    c.video_codecs.as_ref().map(|caps| caps.iter().copied()
        .filter(|codec| rejected.is_none_or(|rejected| !rejected.contains(codec))).collect())
}
fn client_video_quality(c: &Client, id: u64) -> chromium_video::Quality {
    c.video_quality.for_viewport(id, &c.chromium_viewports)
}

struct Server {
    settings: settings::Settings,
    fonts: fonts::Fonts,
    recent_font_size: Option<u16>,
    frontend: frontend::Broker,
    size_claims: size_claims::Claims,
    local_token: String,
    remote_token: String,
    remote_listener: Option<TcpListener>,
    /// Why configured remote access is off, when its address could not be bound.
    remote_error: Option<Value>,
    /// UDP beside the remote listener, for chromium video datagrams.
    datagrams: video_datagram::Datagrams,
    pending_handshakes: Arc<connection::Handshakes>,
    network_generation: u64,
    descriptor: PathBuf,
    auth_path: PathBuf,
    auth: auth::Server,
    resources: Arc<terminal_resource_monitor::Service>,
    sessions: BTreeMap<u64, Session>,
    workspaces: session_registry::Registry,
    session_name_cache: std::cell::RefCell<HashMap<String, (Instant, Option<String>)>>,
    /// Agent titles for session descriptors, taken at turn boundaries: pane -> (status, title).
    agent_title_cache: std::cell::RefCell<HashMap<u64, (String, String)>>,
    /// `terminal.run --wire` requests waiting for their agent to register.
    pending_wires: HashMap<u64, graph_wiring::Pending>,
    started_session: bool,
    lifecycle_dirty: bool,
    workspace_incarnations: HashMap<String, u64>,
    workspace_state: workspace::Store,
    tab_titles: HashMap<u64, String>,
    retired_tabs: regroup::RetiredTabs,
    next: u64,
    shell: String,
    epoch: String,
    graphs: HashMap<String, graph::Graph>,
    chromiums: BTreeMap<u64, chromium::Chromium>,
    filetrees: filetree::Filetrees,
    dictation: dictation::Service,
    uploads: file_transfer::Store,
    chromium_ticket: u64,
    retired_chromiums: Vec<chromium::Chromium>,
    endpoint: String,
    cli: String,
    workers: workers::Workers,
    scan_at: Instant,
    app_scan_at: Instant,
    app_groups: HashMap<u64, Option<i32>>,
    foreground_apps: HashMap<u64, Value>,
    native_pending: HashMap<String, Value>,
    completions: agent_completion::Completions,
    agent_contexts: HashMap<String, mpsc::SyncSender<Value>>,
    pane_claims: pane_claim::Claims,
    checkpoint_lifecycle: session_checkpoints::Lifecycle,
    /// Where terminals run so they outlive this process (Unix); None keeps
    /// them in-process.
    holders: Option<session::Holders>,
    /// Stop by handing terminals to the next server instead of ending them.
    handover: bool,
    /// This restart is for an upgrade: holders must not start a new server.
    park: bool,
    /// What to tell local frontends when this server hands over:
    /// - `Some(true)`: reopen as the newly installed version.
    /// - `Some(false)`: close, because your files are about to be replaced.
    /// - `None`: nothing. They reconnect on their own.
    frontend_notice: Option<bool>,
    /// Process ids of the local frontends that were told to close for an upgrade.
    parked_frontends: Vec<u32>,
    /// End all local sessions, then drain acknowledgements before exiting.
    closing: bool,
    owner_runtime: PathBuf,
    saved_owner: Option<owner_state::OwnerState>,
    /// The workspace a frontend showed last: attached at startup or switched to.
    last_viewed: Option<String>,
}
struct ApiRequest {
    value: Value,
    reply: mpsc::SyncSender<Value>,
}
struct ApiWaiting {
    request: ApiRequest,
    chromium: u64,
    ticket: u64,
    started: Instant,
}

fn packet(header: &Value, payload: &[u8]) -> Vec<u8> {
    graffitty_protocol::pack(header, payload).expect("server generated a bounded wire header")
}
fn unpack(bytes: &[u8]) -> Result<(Value, &[u8]), Error> {
    Ok(graffitty_protocol::unpack(bytes, graffitty_protocol::MAX_COMMAND_PACKET)?)
}
fn queue(client: &mut Client, message: Message) -> Result<(), Error> {
    match client.socket.send(message) {
        Ok(()) => Ok(()),
        // tungstenite retains the unwritten bytes. Flush them on subsequent
        // ticks; the configured maximum write buffer still bounds memory.
        Err(tungstenite::Error::Io(error)) if error.kind() == std::io::ErrorKind::WouldBlock => {
            Ok(())
        }
        Err(error) => Err(error.into()),
    }
}
fn send(client: &mut Client, value: Value) -> Result<(), Error> {
    queue(client, Message::Text(value.to_string().into()))
}
impl Server {
    fn stops_when_empty(&self) -> bool {
        // A server meant to be reached remotely stays, also while its address is taken.
        self.remote_listener.is_none() && self.remote_error.is_none()
    }

    fn session_catalog(&self) -> Value {
        json!({
            "type": "session_list",
            "sessions": session_management::descriptions(self),
            "stops_when_empty": self.stops_when_empty(),
        })
    }

    fn remote_descriptor(&self) -> Value {
        self.remote_listener.as_ref().map(|listener| json!({
            "url":format!("ws://{}",listener.local_addr().unwrap()),
            "token":self.remote_token,"protocol":VERSION,"pid":std::process::id()
        })).unwrap_or(Value::Null)
    }
    fn publish_descriptor(&self) -> Result<(), Error> {
        let remote=self.remote_descriptor();
        // Explicit --listen callers retain the old remote connection-file contract.
        let mut value=if remote.is_null() {
            json!({"url":self.endpoint,"token":self.local_token,"protocol":VERSION,"pid":std::process::id()})
        } else { remote.clone() };
        value["local"]=json!({"url":self.endpoint,"token":self.local_token,"protocol":VERSION});
        value["remote"]=remote;
        let temporary=self.descriptor.with_extension(format!("{}.tmp",std::process::id()));
        let mut options=OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
        let mut file=options.open(&temporary)?;
        file.write_all(value.to_string().as_bytes())?;
        file.sync_all()?;
        fs::rename(temporary,&self.descriptor)?;
        Ok(())
    }
    fn create_with_spawn(
        &mut self,
        workspace: &str,
        tab: Option<u64>,
        source: Option<u64>,
        options: Option<spawn::SpawnOptions>,
    ) -> Result<u64, Error> {
        self.create_with_environment(workspace, tab, source, options, &[], SavedIdentity::default())
    }
    /// The identity a new pane or chromium takes: the saved one a restore
    /// asks for while no live pane has it, else the next unused one.
    ///
    /// A reference to `%N` then still names the same pane after its
    /// checkpoint is restored.
    fn pane_identity(&self, saved: Option<u64>) -> u64 {
        SavedIdentity::choose([saved, None], self.next, |id| {
            !self.sessions.contains_key(&id)
                && !self.chromiums.contains_key(&id)
                && !self.retired_chromiums.iter().any(|chromium| chromium.id == id)
        })
    }
    /// A new tab's identity: the saved one, else `fallback`, while no live tab
    /// has it, else the next unused one after `taken`.
    fn tab_identity(&self, saved: Option<u64>, fallback: u64, taken: u64) -> u64 {
        // The workspace layout accepts only positive tab IDs.
        SavedIdentity::choose([saved, Some(fallback)], self.next.max(taken + 1), |tab| {
            !self.sessions.values().any(|s| s.tab == tab) && !self.chromiums.values().any(|b| b.tab == tab)
        })
    }
    fn identities_taken(&mut self, ids: &[u64]) {
        for id in ids {
            self.next = self.next.max(id + 1);
        }
    }
    /// Only server-owned integrations can set managed environment identities.
    /// Public SpawnOptions still reject every GRAFFITTY_* override.
    fn create_with_environment(
        &mut self,
        workspace: &str,
        tab: Option<u64>,
        source: Option<u64>,
        options: Option<spawn::SpawnOptions>,
        managed_environment: &[(&str, String)],
        saved: SavedIdentity,
    ) -> Result<u64, Error> {
        if self.sessions.len() >= 256 {
            return Err("Server terminal limit reached".into());
        }
        // New tabs inherit the source tab's layout area; splits keep their
        // existing settings. Rendering choices belong to each frontend.
        let inherited = if tab.is_none() {
            source.and_then(|id| self.sessions.get(&id))
                .filter(|session| session.workspace == workspace)
                .and_then(|session| self.workspace_state.snapshot(workspace).tabs.get(&session.tab).cloned())
        } else { None };
        let cwd = source.and_then(|id| self.sessions.get(&id)).and_then(Session::cwd);
        let effective = self.settings.spawn_options(options.as_ref());
        let prepared = Some(effective.prepare(&self.shell, cwd.as_deref())?);
        // A pane that cannot keep its ID must not take another saved pane's.
        if let Some(through) = saved.through.filter(|id| *id < SavedIdentity::LIMIT) {
            self.identities_taken(&[through]);
        }
        let id = self.pane_identity(saved.pane);
        let new_tab = self.tab_identity(saved.tab, id, id);
        let initial_font = self.recent_font_size.unwrap_or_else(|| source.and_then(|id| self.sessions.get(&id)).map_or(self.settings.terminal.font.size, |s| s.font_size));
        let mut session = Session::new_with_font(
            id,
            tab.unwrap_or(new_tab),
            workspace,
            &self.shell,
            &self.endpoint,
            &uuid::Uuid::new_v4().simple().to_string(),
            &self.cli,
            cwd.as_deref(),
            prepared.as_ref(),
            Some((initial_font, self.fonts.metrics(initial_font), self.settings.terminal.content_insets)),
            managed_environment,
            self.holders.as_mut(),
        )?;
        if let Some(source) = source.and_then(|id| self.sessions.get(&id)) {
            session.set_terminal_theme(source.terminal_theme().clone())?;
            // A split/new tab follows the live cwd, but retains the original
            // owner-side fallback if that directory is subsequently removed.
            if options.as_ref().and_then(|v| v.cwd.as_ref()).is_none() {
                session.initial_directory.clone_from(&source.initial_directory);
            }
        }
        self.identities_taken(&[id]);
        if tab.is_none() {
            self.identities_taken(&[new_tab]);
        }
        if let Some(tab) = tab {
            let n = self
                .sessions
                .values()
                .filter(|s| s.workspace == workspace && s.tab == tab)
                .count();
            session.rect[0] += n as f64 * 64.;
            session.rect[1] += n as f64 * 64.;
        }
        self.graphs
            .entry(workspace.into())
            .or_insert_with(|| graph::Graph::with_settings(self.settings.nodes.clone()))
            .add(id, session.title());
        if let Some(pid) = session.pid() {
            self.resources.register(id, pid, Duration::from_secs(1), true);
        }
        self.sessions.insert(id, session);
        self.started_session = true;
        if self.workspaces.insert(workspace.into()) {
            self.workspace_incarnations.insert(workspace.into(), self.workspaces.info(workspace).id.0);
        }
        let inherited = if tab.is_none() { Some(inherited.unwrap_or_else(|| {
            let [width, height] = self.settings.terminal.workspace_size;
            graffitty_workspace_core::state::TabSettings { area: [0., 34., f32::from(width), f32::from(height)-34.] }
        })) } else { inherited };
        if let Some(settings) = inherited {
            let applied = (|| -> Result<(), Error> {
                workspace::sync(self, workspace)?;
                let state = self.workspace_state.snapshot(workspace);
                self.workspace_state.edit(workspace, state.revision,
                    graffitty_workspace_core::state::Edit::Tab {
                        tab: new_tab, layout: state.layout.tabs[&new_tab].clone(), settings: Some(settings),
                    })?;
                Ok(())
            })();
            if let Err(error) = applied { self.close(id); return Err(error); }
        }
        Ok(id)
    }
    fn agents(&mut self) {
        for graph in self.graphs.values_mut() {
            graph.expire();
        }
        for (key, context, result) in self.workers.poll() {
            if key.starts_with("context:") {
                agent_context::finish(self, &key, &context, &result);
            } else if key == "foreground_apps" {
                for root in context["roots"].as_array().into_iter().flatten() {
                    let Some(id) = root["id"].as_u64() else { continue };
                    let Some(session) = self.sessions.get(&id) else { continue };
                    // Ignore a worker observation of a job that has already left.
                    if json!(session.pid()) != root["pid"] || json!(session.foreground()) != root["foreground"] {
                        continue;
                    }
                    if let Some(app) = result.get(format!("%{id}")).filter(|v| v.is_object()) {
                        self.foreground_apps.insert(id, app.clone());
                    }
                }
            } else if key == "scan" {
                if let Some(found) = result.as_object() {
                    for (key, state) in found {
                        let Some(id) = key
                            .strip_prefix('%')
                            .and_then(|s| s.parse::<u64>().ok())
                        else {
                            continue;
                        };
                        let Some(session) = self.sessions.get(&id) else {
                            continue;
                        };
                        let graph = self.graphs.get_mut(&session.workspace).unwrap();
                        let Some(previous) = graph.nodes.get(key).cloned() else {
                            continue;
                        };
                        if previous["transport"] != "inbox"
                            && !graffitty_workspace_core::graph::is_custom_node(&previous) {
                            self.checkpoint_lifecycle.observe(id, state);
                        }
                        graph.observe_agent(id, state);
                        self.completions.observe(&session.workspace, id, &previous, &graph.nodes[key]);
                    }
                }
            } else if key.starts_with("completion:") {
                self.completions.finish(&key, &result, &mut self.graphs);
            } else if key.starts_with("native:") {
                if let Some(ids) = result["queued_ids"].as_array() {
                    for record in context["records"].as_array().into_iter().flatten() {
                        let id = record["event"]["event_id"].as_str().unwrap_or("");
                        if self.native_pending.get(id).is_none_or(|current| current["submission_id"] != record["submission_id"]) { continue; }
                        if !ids.contains(&record["submission_id"]) {
                            self.native_pending.remove(id);
                            if let Some(graph) = self.graphs.get_mut(record["workspace"].as_str().unwrap_or("")) {
                                graph.record_delivery(&record["event"], "started or removed in Codex", false);
                            }
                        }
                    }
                }
            } else if key.starts_with("cancel:") {
                if let Some(graph) = self.graphs.get_mut(context["workspace"].as_str().unwrap_or("")) {
                    let status = if result.get("error").is_some() {
                        format!("cancel failed: {}", result["error"]["message"].as_str().unwrap_or("queue error"))
                    } else if result["deleted"] == true { "cancelled in Codex".into() }
                    else { "already started or removed in Codex; cannot recall".into() };
                    graph.record_delivery(&context["event"], &status, false);
                }
            } else if key.starts_with("deliver:") {
                let Some(workspace) = context["workspace"].as_str() else {
                    continue;
                };
                let Some(graph) = self.graphs.get_mut(workspace) else {
                    continue;
                };
                let id = context["id"].as_u64().unwrap_or(0);
                let event_id = &context["event"]["event_id"];
                let queued = graph
                    .queues
                    .get(&format!("%{id}"))
                    .is_some_and(|q| q.iter().any(|e| e["event_id"] == *event_id));
                if !queued || !graph.allowed(&context["event"]) {
                    if let Some(submission) = result["queuedSubmission"]["id"].as_str() {
                        // Keep revoked submissions until a worker slot can
                        // cancel them; a late result must not bypass expiry.
                        let mut record = context.clone();
                        record["submission_id"] = json!(submission);
                        self.native_pending.insert(event_id.as_str().unwrap_or("").into(), record);
                    }
                    continue;
                }
                let queued = result["queuedSubmission"]["id"].as_str();
                if let Some(submission) = queued {
                    let mut record = context.clone();
                    record["submission_id"] = json!(submission);
                    self.native_pending
                        .insert(event_id.as_str().unwrap_or("").into(), record);
                }
                let status = if result.get("error").is_some() {
                    format!(
                        "failed: {}",
                        result["error"]["message"]
                            .as_str()
                            .unwrap_or("delivery failed")
                    )
                } else if queued.is_some() {
                    "queued in Codex".into()
                } else {
                    "submitted".into()
                };
                let _ = graph.dispatch(
                    id,
                    "graph.ack",
                    &json!({"event_id":event_id,"status":status}),
                );
            }
        }
        for (key, request) in self.completions.requests() {
            if self.workers.start(&self.cli, key.clone(), request, json!({})) {
                self.completions.launched(&key);
            }
        }
        self.native_pending.retain(|id, record| {
            self.graphs.get(record["workspace"].as_str().unwrap_or(""))
                .is_none_or(|g| !g.allowed(&record["event"]) || g.native_pending(id))
        });
        let revoked: Vec<_> = self
            .native_pending
            .iter()
            .filter(|(_, record)| {
                !self
                    .graphs
                    .get(record["workspace"].as_str().unwrap_or(""))
                    .is_some_and(|g| g.allowed(&record["event"]))
            })
            .map(|(id, r)| (id.clone(), r.clone()))
            .collect();
        for (id, record) in revoked {
            if self.workers.start(&self.cli,format!("cancel:{id}"),json!({"op":"codex_cancel","target":record["target"],"submission_id":record["submission_id"]}),record.clone()) {self.native_pending.remove(&id);}
        }
        let groups: HashMap<_, _> = self.sessions.values_mut().filter(|s| !s.exited)
            .map(|s| {
                let pgid = s.foreground();
                // A `process` effect hold ends with the group that printed it.
                s.effect_holds.foreground_changed(pgid);
                (s.id, pgid)
            }).collect();
        if !groups.is_empty() && !self.workers.busy("foreground_apps")
            && (groups != self.app_groups || self.app_scan_at.elapsed() >= Duration::from_millis(400))
        {
            let roots: Vec<_> = self.sessions.values().filter(|s| !s.exited).map(|s| {
                let key = format!("%{}", s.id);
                let node = &self.graphs[&s.workspace].nodes[&key];
                json!({"id":s.id,"node":key,"pid":s.pid(),"foreground":groups[&s.id],
                    "agent":{"pid":node["pid"],"provider":node["provider"],"started":node["started"],
                        "integrated":node["integrated"]}})
            }).collect();
            if self.workers.start(&self.cli, "foreground_apps".into(),
                json!({"op":"foreground_apps","roots":roots}), json!({"roots":roots})) {
                self.app_groups = groups;
                self.app_scan_at = Instant::now();
            }
        }
        self.foreground_apps.retain(|id, _| self.sessions.get(id).is_some_and(|s| !s.exited));
        if self.scan_at.elapsed() > Duration::from_secs(2) && !self.workers.busy("scan") {
            let roots:Vec<_>=self.sessions.values().map(|s|{
                let key=format!("%{}",s.id);
                let node=&self.graphs[&s.workspace].nodes[&key];
                json!({"node":key,"pid":s.pid(),"agent_pid":node["pid"],"started":node["started"],"provider_home":node["provider_home"],"launch_context":node["launch_context"]})
            }).collect();
            self.workers.start(
                &self.cli,
                "scan".into(),
                json!({"op":"scan","roots":roots}),
                json!({}),
            );
            let mut targets: HashMap<String, Vec<Value>> = HashMap::new();
            for record in self.native_pending.values() {
                targets.entry(record["event"]["target"].as_str().unwrap_or("").into()).or_default().push(record.clone());
            }
            for (target, records) in targets {
                self.workers.start(&self.cli, format!("native:{target}"),
                    json!({"op":"codex_queue_status","target":records[0]["target"]}),json!({"records":records}));
            }
            self.scan_at = Instant::now();
        }
        for (workspace, graph) in &self.graphs {
            for (key, queue) in &graph.queues {
                let Some(event) = queue.first() else {
                    continue;
                };
                if !graph.allowed(event) { continue; }
                let Some(node) = graph.nodes.get(key) else {
                    continue;
                };
                let provider = node["provider"].as_str().unwrap_or("");
                if node["transport"] == "inbox" || node["status"] == "offline" || !["codex", "claude"].contains(&provider) {
                    continue;
                }
                if provider == "codex" && self.native_pending.len() >= 1024 {
                    continue;
                }
                if provider == "claude" && node["socket_path"].as_str().unwrap_or("").is_empty() {
                    continue;
                }
                let id = key
                    .trim_start_matches('%')
                    .parse::<u64>()
                    .unwrap_or(0);
                if self.sessions.get(&id).is_none_or(|s| s.typing_guard.blocked()) { continue; }
                let text = graph.delivery_prompt(event);
                self.workers.start(&self.cli,format!("deliver:{id}"),json!({"op":if provider=="codex"{"codex_queue"}else{"claude_send"},"target":node,"text":text,"event_id":event["event_id"]}),json!({"id":id,"workspace":workspace,"target":node,"event":event,"text":text}));
            }
        }
    }
    #[cfg(target_os = "macos")]
    fn sync_chromium_windows(&mut self) {
        let roots: Vec<_> = self.chromiums.values().filter(|b|b.main_window)
            .map(|b|b.id).collect();
        for root in roots {
            let session = self.chromiums[&root].session_id;
            let windows: Vec<i64> = self.chromiums[&root].state["windows"].as_array()
                .map(|a|a.iter().filter_map(|w|w["id"].as_i64()).collect()).unwrap_or_default();
            for window in windows {
                if self.chromiums[&root].window_is_closing(window) { continue; }
                if self.chromiums.values().any(|b|b.session_id==session && b.state["windowId"]==window) { continue; }
                if self.chromiums.len() >= 32 { break; }
                let id=self.next; self.next+=1;
                match self.chromiums[&root].sibling(id,window,self.resources.clone()) {
                    Ok(chromium)=>{self.chromiums.insert(id,chromium);self.lifecycle_dirty=true;},
                    Err(error)=>eprintln!("Could not mirror Chromium window: {error}"),
                }
            }
        }
        let closed:Vec<_>=self.chromiums.values().filter(|b|b.state["closed"]==true).map(|b|b.id).collect();
        for id in closed { self.retire_chromium(id); }
    }
    fn retire_chromium(&mut self, id: u64) {
        filetree::closing(self, id);
        if let Some(chromium) = self.chromiums.remove(&id) {
            self.lifecycle_dirty = true;
            let tab = chromium.tab;
            if chromium.main_window {
                let replacement=self.chromiums.values().filter(|b|b.session_id==chromium.session_id).map(|b|b.id).min();
                if let Some(replacement)=replacement {
                    for other in self.chromiums.values_mut().filter(|b|b.session_id==chromium.session_id) {
                        other.main_window=other.id==replacement;
                        other.state["mainWindow"]=json!(other.main_window);
                        other.owner=if other.main_window {if chromium.owner==id {other.id}else{chromium.owner}} else {replacement};
                    }
                }
            }
            chromium.stop();
            self.retired_chromiums.push(chromium);
            if !self.sessions.values().any(|s|s.tab==tab) && !self.chromiums.values().any(|b|b.tab==tab) {
                self.tab_titles.remove(&tab);
            }
        }
    }
    fn close(&mut self, id: u64) {
        filetree::closing(self, id);
        // Children end with their parent unless they asked to outlive it;
        // survivors forget the parent instead of pointing at a closed pane.
        let children: Vec<(u64, bool)> = self.sessions.values()
            .filter(|s| s.spawned_by == Some(id)).map(|s| (s.id, s.dies_with_parent)).collect();
        let ending: Vec<u64> = children.iter().filter(|(_, dies)| *dies).map(|(id, _)| *id).collect();
        let surviving: Vec<u64> = children.iter().filter(|(_, dies)| !*dies).map(|(id, _)| *id).collect();
        for child in surviving {
            if let Some(session) = self.sessions.get_mut(&child) { session.spawned_by = None; }
        }
        for child in ending {
            self.close(child);
        }
        if let Some(session) = self.sessions.remove(&id) {
            self.uploads.remove(&self.owner_runtime.join("files"), id);
            self.checkpoint_lifecycle.closed(id);
            self.pending_wires.remove(&id);
            self.pending_wires.retain(|_, pending| pending.parent != id);
            self.lifecycle_dirty = true;
            self.resources.remove(id);
            if !self.sessions.values().any(|s| s.tab == session.tab) && !self.chromiums.values().any(|b| b.tab == session.tab) {
                self.tab_titles.remove(&session.tab);
            }
            if let Some(graph) = self.graphs.get_mut(&session.workspace) {
                graph.remove(id);
            }
            let ids = regroup::owned_chromium_ids(id, self.chromiums.values().map(|b|(b.id,b.owner)));
            for id in ids {
                self.retire_chromium(id);
            }
        }
    }
    fn retire_empty_workspaces(&mut self) -> Result<(), Error> {
        if !self.lifecycle_dirty { return Ok(()); }
        let empty: Vec<_> = self.workspaces.iter().filter(|name| {
            !self.sessions.values().any(|s| &s.workspace == *name)
                && !self.chromiums.values().any(|b| &b.workspace == *name)
        }).cloned().collect();
        for name in empty {
            self.workspace_state.remove(&name)?;
            self.graphs.remove(&name);
            self.workspaces.remove(&name);
            self.workspace_incarnations.remove(&name);
        }
        self.lifecycle_dirty = false;
        Ok(())
    }
    // Used before frontend routing as well as by the headless server.
    fn chromium_target_params(&mut self, caller: u64, params: &Value) -> Result<Value, Error> {
        let Some(target) = params.get("chromium") else {
            return Ok(params.clone());
        };
        let target = target.as_str().ok_or("Chromium target must be a string")?;
        let workspace = self
            .sessions
            .get(&caller)
            .map(|s| s.workspace.clone())
            .or_else(|| self.chromiums.get(&caller).map(|b| b.workspace.clone()))
            .ok_or("Unknown pane")?;
        workspace::sync(self, &workspace)?;
        let state = self.workspace_state.snapshot(&workspace);
        let key =
            terminal_api::resolve_in_workspace(&state, &workspace, target).ok_or_else(|| {
                api::error(
                    "invalid_target",
                    "Unknown chromium pane target in this session",
                )
            })?;
        let id = graffitty_workspace_core::pane_id::parse(&key).unwrap();
        if !self.chromiums.contains_key(&id) {
            return Err(api::error(
                "invalid_target",
                "Target is a terminal pane, not a Chromium pane",
            ));
        }
        let chromium = &self.chromiums[&id];
        let mut owner=chromium.owner;
        for _ in 0..self.chromiums.len() {
            let Some(parent)=self.chromiums.get(&owner) else {break};
            if parent.owner==owner {break}
            owner=parent.owner;
        }
        api::chromium_owner(
            filetree::owner(self, caller),
            filetree::owner(self, owner),
            chromium.workspace == workspace,
        )?;
        let mut params = params.clone();
        params["chromium"] = json!(key);
        Ok(params)
    }

    fn dispatch(&mut self, id: u64, method: &str, params: &Value) -> Result<Value, Error> {
        if !params.is_object() {
            return Err(api::error("invalid_params", "Expected object params"));
        }
        let workspace = self
            .sessions
            .get(&id)
            .map(|s| s.workspace.clone())
            .or_else(|| {
                self.chromiums
                    .get(&id)
                    .filter(|b| {
                        b.owner == id
                            && method.starts_with("chromium.")
                            && method != "chromium.create"
                    })
                    .map(|b| b.workspace.clone())
            })
            .ok_or("Unknown pane")?;
        if method == "agent.delivery" {
            let event_id = params["event_id"].as_str().ok_or("Expected event_id")?;
            let ready = self.sessions.get(&id).is_some_and(|s| !s.typing_guard.blocked())
                && self.graphs.get(&workspace).is_some_and(|graph|
                    graph.queues.get(&format!("%{id}")).is_some_and(|queue|
                        queue.iter().any(|event| event["event_id"] == event_id && graph.allowed(event))));
            return Ok(json!({"ready":ready}));
        }
        let normalized;
        let params = if method.starts_with("chromium.") {
            normalized = self.chromium_target_params(id, params)?;
            &normalized
        } else {
            params
        };
        if method == "chromium.open" {
            let path = params["path"].as_str().ok_or("Expected file path")?;
            let target = params["chromium"]
                .as_str()
                .and_then(graffitty_workspace_core::pane_id::parse);
            let force_new = params
                .get("new")
                .map(|v| v.as_bool().ok_or("new must be a boolean"))
                .transpose()?
                .unwrap_or(false);
            let explicit_profile = !params["profile"].is_null() || !params["profile_template"].is_null();
            if target.is_some() && explicit_profile {
                return Err("Profile options create a chromium pane; they cannot be combined with --target".into());
            }
            let profile = chromium::Profile::select(params, &self.settings.chromium)?;
            return filetree::open_chromium_file(self, id, path, target, force_new, profile);
        }
        if method == "filetree.toggle" {
            return filetree::toggle(self, id, params);
        }
        if method == "filetree.open_file" {
            return filetree::open_file(self, id, params);
        }
        if method == "pane.send" {
            return filetree::send(self, id, params);
        }
        if method == "window.set_title" || method == "chromium.set_title" {
            return titles::set(self, id, method, params);
        }
        if method == "tab.set_title" {
            let tabs: std::collections::BTreeSet<_> = self
                .sessions
                .values()
                .filter(|s| s.workspace == workspace)
                .map(|s| s.tab)
                .chain(self.chromiums.values().filter(|b|b.workspace==workspace).map(|b|b.tab))
                .collect();
            let target = if let Some(position) = params["position"].as_u64() {
                *tabs
                    .iter()
                    .nth(position.checked_sub(1).ok_or("Tab positions start at 1")? as usize)
                    .ok_or("Unknown tab position")?
            } else if let Some(target) = params["id"].as_u64() {
                target
            } else if let Some(target) = params["target"].as_str() {
                let pane = target
                    .trim_start_matches('%')
                    .parse::<u64>()?;
                self.sessions
                    .get(&pane)
                    .filter(|s| s.workspace == workspace)
                    .ok_or("Unknown pane")?
                    .tab
            } else {
                self.sessions[&id].tab
            };
            if !tabs.contains(&target) {
                return Err("Tab is not in this workspace".into());
            }
            let title = titles::validate(&params["title"])?;
            if title.is_empty() {
                self.tab_titles.remove(&target);
            } else {
                self.tab_titles.insert(target, title.into());
            }
            return Ok(json!({"id":target,"title":title}));
        }
        if method == "agent.event" && params["event"] == "UserPromptSubmit" {
            self.native_pending
                .retain(|_, record| record["id"] != id || record["text"] != params["prompt"]);
        }
        if method == "session.capture" {
            if params["layout"] == true {
                return session_checkpoints::capture(self, &[workspace.clone()]);
            }
            let s = &self.sessions[&id];
            return Ok(json!({"text":s.history()?,"columns":s.columns,"rows":s.rows}));
        }
        if method == "chromium.create" {
            if self.chromiums.len() >= 32 {
                return Err("Server chromium limit reached".into());
            }
            if self.chromiums.values().filter(|b| b.owner == id).count() >= 8 {
                return Err("Maximum 8 chromiums per terminal".into());
            }
            let url = params["url"].as_str().unwrap_or("about:blank");
            if url != "about:blank" && !url.starts_with("https://") && !url.starts_with("http://") {
                return Err("Use http(s) or about:blank".into());
            }
            let profile = chromium::Profile::select(params, &self.settings.chromium)?;
            let template = match &profile {
                chromium::Profile::Template(path) => json!(path.to_string_lossy()),
                _ => Value::Null,
            };
            if params.get("id").is_some_and(|saved| !saved.is_u64()) {
                return Err("Expected a saved chromium ID".into());
            }
            let chromium_id = self.pane_identity(params["id"].as_u64());
            self.identities_taken(&[chromium_id]);
            let chromium = chromium::Chromium::new(
                chromium_id,
                id,
                workspace.clone(),
                self.sessions[&id].tab,
                url.into(),
                profile,
                &self.settings.chromium,
                Arc::clone(&self.resources),
            )?;
            let result = json!({"chromium":format!("%{chromium_id}"),"id":chromium_id,
                "surface":format!("%{chromium_id}"),"pane":format!("%{chromium_id}"),"tab_id":id,
                "native_visible":false,"profile":chromium.state["profile"],
                "temporary_profile":chromium.state["temporaryProfile"],"profile_template":template,"exited":false});
            self.chromiums.insert(chromium_id, chromium);
            let tab = self.sessions[&id].tab;
            if let Err(error) = workspace::place_chromium_beside_owner(self, &workspace, tab, id, chromium_id) {
                // The Chromium still opens, where a new pane would by default.
                eprintln!("[chromium] could not place %{chromium_id} beside %{id}: {error}");
            }
            return Ok(result);
        }
        if method.starts_with("chromium.") {
            let chromium_id = params["chromium"]
                .as_str()
                .and_then(graffitty_workspace_core::pane_id::parse)
                .ok_or_else(|| api::error("invalid_target", "Explicit %N required"))?;
            let chromium = self
                .chromiums
                .get_mut(&chromium_id)
                .ok_or_else(|| api::error("not_found", "Chromium no longer exists"))?;
            match method {
                "chromium.close" => {
                    self.retire_chromium(chromium_id);
                    return Ok(json!({"closed":params["chromium"]}));
                }
                "chromium.restart" => {
                    let replacement = chromium.restart(&self.settings.chromium, Arc::clone(&self.resources))?;
                    // Dropping the stopped chromium reaps its finished worker.
                    self.chromiums.insert(chromium_id, replacement);
                    return Ok(json!({"restarted":params["chromium"]}));
                }
                "chromium.input" => {
                    chromium.input(params.get("event").cloned().ok_or("Expected input event")?)?;
                    return Ok(json!({"accepted":true}));
                }
                "chromium.result" => {
                    let ticket = params["ticket"].as_u64().ok_or("Expected ticket")?;
                    return Ok(chromium.results.remove(&ticket).unwrap_or(Value::Null));
                }
                "chromium.command" => {
                    let action = params["action"].as_str().ok_or("Expected action")?;
                    self.chromium_ticket += 1;
                    chromium.command(
                        self.chromium_ticket,
                        action.into(),
                        params.get("args").cloned().unwrap_or(json!({})),
                    )?;
                    return Ok(json!({"ticket":self.chromium_ticket}));
                }
                "chromium.attach" | "chromium.detach" | "chromium.eval" | "chromium.snapshot" | "chromium.fill" | "chromium.scroll"
                | "chromium.navigate" | "chromium.click" | "chromium.press" | "chromium.wait" => {
                    self.chromium_ticket += 1;
                    chromium.command(self.chromium_ticket, method.into(), params.clone())?;
                    return Ok(json!({"_ticket":self.chromium_ticket,"_chromium":chromium_id}));
                }
                _ => return Err("Unsupported headless chromium method".into()),
            }
        }
        if method == "graph.spawn" {
            // The same launch as terminal.run --agent: the new agent records
            // this terminal as its parent and accepts the same placement.
            let mut request = params.clone();
            let provider = request.as_object_mut().unwrap().remove("provider").ok_or("Expected provider")?;
            request["agent"] = provider;
            return terminal_run::run(self, id, &request);
        }
        if method == "notification.bind" {
            let event_id = params["event_id"].as_str().ok_or("Expected event ID")?;
            let notification_id = params["notification_id"]
                .as_str()
                .ok_or("Expected notification ID")?;
            if notification_id.len() > 256 {
                return Err("Notification ID too long".into());
            }
            let graph = &self.graphs[&workspace];
            let event = graph
                .queues
                .get(&format!("%{id}"))
                .and_then(|q| q.iter().find(|e| e["event_id"] == event_id))
                .ok_or("Pending event not found")?
                .clone();
            if !graph.allowed(&event) { return Err("Pending event not found".into()); }
            let session = self.sessions.get_mut(&id).unwrap();
            session.notification_sequence += 1;
            session.notifications.push_back((session.notification_sequence,json!({"binding":{"notification_id":notification_id,"event":event,"focus_target":params.get("focus_target").cloned().unwrap_or(json!("original"))}})));
            if session.notifications.len() > 256 {
                session.notifications.pop_front();
            }
            return Ok(json!({"ok":true}));
        }
        if method == "graph.connect" {
            regroup::validate_connection(self, &workspace, params)?;
        }
        if method == "graph.read" {
            let source = params["node"].as_str().ok_or("Expected node")?;
            let graph = &self.graphs[&workspace];
            if !graph.can_read(source, &format!("%{id}")) {
                return Err(Box::new(DispatchError(graph.read_denied(source, &format!("%{id}")))));
            }
            let node = graph.nodes.get(source).ok_or("Unknown node")?;
            let path = node["transcript_path"]
                .as_str()
                .ok_or("Session transcript is not available yet")?;
            let mut file = std::fs::File::open(path)?;
            let size = file.metadata()?.len();
            let sessions = json!([{"provider":node["provider"],"id":node["session_id"],"path":path,"checkpoint":{"byte_offset":size}}]);
            if let Some(offset) = params["offset"].as_u64() {
                use std::io::{Seek, SeekFrom};
                file.seek(SeekFrom::Start(offset))?;
                let mut bytes = Vec::new();
                file.take(512 * 1024).read_to_end(&mut bytes)?;
                if !graph.can_read(source, &format!("%{id}")) {
                    return Err(Box::new(DispatchError(graph.read_denied(source, &format!("%{id}")))));
                }
                return Ok(
                    json!({"sessions":sessions,"text":String::from_utf8_lossy(&bytes),"offset":offset,"next_offset":offset+bytes.len() as u64,"size":size}),
                );
            }
            if !graph.can_read(source, &format!("%{id}")) {
                return Err(Box::new(DispatchError(graph.read_denied(source, &format!("%{id}")))));
            }
            return Ok(json!({"sessions":sessions,"size":size,"format":"jsonl"}));
        }
        let graph = self.graphs
            .get_mut(&workspace)
            .unwrap();
        let result = graph.dispatch(id, method, params)?;
        if method == "agent.event" {
            if params["event"] == "SessionStart" && let Some(pending) = self.pending_wires.remove(&id) {
                // The lead's declared wiring, now that the child advertises ports.
                let outcome = graph_wiring::apply(graph, pending.parent, id, &pending.wires);
                if let Some(failed) = outcome["failed"].as_array().filter(|f| !f.is_empty()) {
                    eprintln!("[graph] %{} wiring %{} -> {}", pending.parent, id, Value::Array(failed.clone()));
                }
            }
            self.checkpoint_lifecycle.hook(id, &params["event"], &graph.nodes[&format!("%{id}")]);
            if matches!(params["event"].as_str(), Some("SessionStart" | "SessionEnd")) {
                self.app_scan_at = Instant::now() - Duration::from_millis(400);
            }
        }
        Ok(result)
    }
    fn request(&mut self, id: u64, method: &str, params: &Value) -> Result<api::Reply, Error> {
        if method == "navigator.input" {
            let session = self.sessions.get(&id).ok_or("Unknown navigator pane")?;
            navigator::input(&self.settings.navigator, session.foreground(), params)
        } else if method == "navigator.select" {
            navigator::select(&self.settings.navigator, params).map(api::Reply::Ready)
        } else if method == "navigator.configure" {
            let algorithm = params["algorithm"].as_str().ok_or("Expected navigation algorithm")?;
            let mut config = self.settings.navigator.clone();
            config.algorithm = algorithm.into();
            config.validate()?;
            self.settings.navigator = config;
            Ok(api::Reply::Ready(json!({"result":self.settings.navigator})))
        } else if method.starts_with("dictation.") {
            self.dictation.request(&self.settings.dictation, id, method, params, None)
        } else if terminal_api::handles(method) {
            terminal_api::dispatch(self, id, method, params)
        } else if effects_api::handles(method) {
            effects_api::dispatch(self, id, method, params).map(|result| api::Reply::Ready(json!({"result":result})))
        } else if method == "terminal.run" {
            terminal_run::run(self, id, params).map(|result| api::Reply::Ready(json!({"result":result})))
        } else if method == "pane.place" {
            terminal_run::place(self, id, params).map(|result| api::Reply::Ready(json!({"result":result})))
        } else {
            self.dispatch(id, method, params).map(|result| api::Reply::Ready(json!({"result":result})))
        }
    }
    fn api(&mut self, value: Value) -> api::Reply {
        let result = (|| -> Result<api::Reply, Error> {
            if self.closing {
                return Err(api::error("server_closing", "Server is closing"));
            }
            if value["method"] == "agent.context" {
                return agent_context::start(self, &value);
            }
            if pane_claim::handles(value["method"].as_str().unwrap_or("")) {
                return pane_claim::dispatch(self, &value);
            }
            if session_management::handles(value["method"].as_str().unwrap_or("")) {
                if value["token"].as_str() != Some(self.local_token.as_str()) {
                    return Err(api::error("forbidden", "Local server capability required"));
                }
                return session_management::dispatch(self, &value).map(|result| api::Reply::Ready(json!({"result":result})));
            }
            if value["method"] == "terminal.put" && value["token"].as_str() == Some(self.local_token.as_str()) {
                return controller::dispatch(self, &json!({"version":value["version"],"method":value["method"],"params":value["params"]}));
            }
            let (id, method, params) = api::request(&value, |token| {
                self.sessions.values().find(|s| s.token == token).map(|s| s.id)
            })?;
            self.request(id, method, &params)
        })();
        let result = result.and_then(|reply| { self.save_owner_state()?; Ok(reply) });
        match result {
            Ok(reply) => reply,
            Err(error) => {
                api::Reply::Ready(json!({"error":error_details(&error)}))
            }
        }
    }
    /// The topology as one client sees it, including who sizes each tab.
    fn client_topology(&mut self, workspace: &str, client: u64) -> Value {
        let mut topology = self.topology(workspace);
        self.size_claims.annotate(&mut topology, workspace, client);
        topology
    }
    fn topology(&mut self, workspace: &str) -> Value {
        if let Err(error) = workspace::sync(self, workspace) {
            eprintln!("[workspace] {error}");
        }
        let state = self.workspace_state.snapshot(workspace);
        let sessions: Vec<_> = self.sessions.values().filter(|s| s.workspace == workspace).collect();
        let panes: Vec<_> = sessions.iter().map(|s| {
            let rect = state.layout.tabs.get(&s.tab).and_then(|t|t.window(&format!("%{}",s.id)))
                .map(|w| w.rect.map(f64::from)).unwrap_or(s.rect);
            json!({"id":s.id,"tab":s.tab,"title":s.title(),"title_is_fallback":s.pinned_title.is_empty() && s.automatic_title().is_empty(),"pinned_title":s.pinned_title,"builtin_title":s.builtin_title,"automatic_title":s.automatic_title(),"rect":rect,"columns":s.columns,"rows":s.rows,"exited":s.exited,"font_size":s.font_size,"font_metrics":self.fonts.metrics(s.font_size),"content_insets":self.settings.terminal.content_insets,"pid":s.pid(),"shell":s.shell,"app":self.foreground_apps.get(&s.id).cloned().unwrap_or(json!({})),"limits":s.limits,"spawned_by":s.spawned_by,"effect_holds":s.effect_holds.snapshot(),"filetree":filetree::checkpoint(self, s.id),"filetree_owner":filetree::connection_owner(self, s.id),"filetree_open":self.filetrees.active.values().any(|tree| tree.owner == filetree::owner(self, s.id))})
        }).collect();
        let tabs: Vec<_> = state.order.iter().map(|id| {
            let panes: Vec<_> = sessions.iter().filter(|s| s.tab == *id).collect();
            let chromium = self.chromiums.values().find(|b| b.workspace == workspace && b.tab == *id);
            let title = panes.first().map(|s|s.title()).or_else(||chromium.map(|b|b.title())).unwrap_or_else(||"Workspace".into());
            let keys: Vec<_> = panes.iter().map(|s|s.id).collect();
            json!({"id":id,"title":self.tab_titles.get(id).cloned().unwrap_or(title),"pinned":self.tab_titles.contains_key(id),"sessions":keys})
        }).collect();
        let chromiums:Vec<_>=self.chromiums.values().filter(|b|b.workspace==workspace).map(|b|json!({"id":b.id,"owner":b.owner,"tab":b.tab,"title":b.title(),"pinned_title":b.pinned_title,"automatic_title":b.automatic_title(),"state":b.state})).collect();
        json!({"type":"topology","navigator":self.settings.navigator,"terminal_font":self.fonts.manifest(),"host_os":std::env::consts::OS,"headless":true,"authoritative_layout":true,
            "workspace_revision":state.revision,"workspace_state":state,"epoch":self.epoch,"workspace":self.workspaces.id(workspace),
            "tabs":tabs,"panes":panes,"chromiums":chromiums,"edges":[],"graph":self.graphs.get(workspace).map(|g|g.snapshot())})
    }
    fn handle(&mut self, c: &mut Client, value: Value, binary: Option<&[u8]>) -> Result<(), Error> {
        let kind = value["type"].as_str().unwrap_or("");
        if self.closing {
            return send(c, json!({"type":"error", "request":value["request"], "message":"Server is closing",
                "error":{"code":"server_closing", "message":"Server is closing"}}));
        }
        if !c.authenticated {
            if binary.is_some() {
                return Err("Authentication failed".into());
            }
            // This machine presents the local capability. Every other client
            // completes the OPAQUE login, whose key encrypts all later records.
            let local = kind == "auth_local" && (c.socket.is_local() || c.socket.is_loopback());
            let result = if local {
                if value["token"].as_str() != Some(self.local_token.as_str()) || value["version"] != VERSION {
                    return Err("Invalid local capability or protocol".into());
                }
                json!({"type":"authenticated","context":value})
            } else if c.socket.is_local() {
                return Err("Private connections use the local capability".into());
            } else {
                let result = c.auth.step(&mut self.auth, &value)?;
                if let Some(channel) = c.auth.take_channel() {
                    c.socket.secure(channel)?;
                }
                if let Some(key) = c.auth.take_datagram() { c.datagram_key = Some(key); }
                result
            };
            if result["type"] != "authenticated" {
                return send(c, result);
            }
            let value = &result["context"];
            // Remote authentication grants access to this server. Selecting a
            // session is a separate authenticated request, never a login input.
            let key = if local {
            let target = value["workspace"].as_str().unwrap_or("");
            let new = local && value["new_session"] == true;
            let found = if new || target.is_empty() { None } else {
                match self.workspaces.resolve(target) {
                    Ok(key) => Some(key),
                    Err(graffitty_workspace_core::session::SessionError::NotFound(_)) => None,
                    Err(error) => return Err(error.into()),
                }
            };
            // Prefer the session a frontend showed last, then the oldest.
            let fallback = if !new && found.is_none() && (target.is_empty() || value["workspace_fallback"] == true) {
                self.last_viewed.clone().filter(|key| self.workspaces.contains(key))
                    .or_else(|| self.workspaces.iter().min_by_key(|key| self.workspaces.info(key).id).cloned())
            } else { None };
            if let Some(key) = found.or(fallback) { key } else {
                // A local frontend resuming its last session on a server with
                // none starts a fresh one rather than reviving a stale name.
                let resume = local && value["workspace_fallback"] == true;
                if !new && !resume && (value["require_workspace"] == true || target.starts_with('$') || target.starts_with('=')) {
                    return Err(format!("Session not found: {target}").into());
                }
                let name = (!new && !resume && !target.is_empty()).then_some(target);
                let spawn = if local { value.get("spawn").cloned().unwrap_or(json!({})) } else { json!({}) };
                // A restore's first pane asks for its saved identity.
                let saved = if local { value.get("saved").cloned().unwrap_or(json!({})) } else { json!({}) };
                let created = session_management::dispatch(self, &json!({"version":1,"method":"session.new","params":{"name":name,"spawn":spawn,"saved":saved}}))?;
                self.workspaces.resolve(created["id"].as_str().unwrap())?
            }
            } else { String::new() };
            let workspace = key.as_str();
            c.workspace = key.clone();
            c.workspace_incarnation = self.workspace_incarnations.get(workspace).copied().unwrap_or(0);
            c.authenticated = true;
            c.chromium_png = value["chromium_image_format"] == "png";
            c.video_quality = chromium_video::Quality::parse(&value["chromium_stream"]);
            c.video_rejected.clear();
            c.video_codecs = value.get("chromium_video").map(|caps|
                caps.as_array().map(|a| a.iter().filter_map(|v| v.as_str().and_then(graffitty_chromium_video::Codec::parse)).collect()).unwrap_or_default());
            if value["features"].as_array().is_some_and(|a| a.iter().any(|v| v == "scene-flow-v1")) { c.scenes.enable_flow(); }
            c.session_switch = value["features"].as_array().is_some_and(|a| a.iter().any(|v| v == "session-switch-v1"));
            c.bell_events = value["features"].as_array().is_some_and(|a| a.iter().any(|v| v == "bell"));
            c.clipboard_events = value["features"].as_array().is_some_and(|a| a.iter().any(|v| v == "clipboard"));
            for s in self
                .sessions
                .values()
                .filter(|s| s.workspace == c.workspace)
            {
                c.notifications.insert(s.id, s.notification_sequence);
                c.input_sequences.insert(s.id, s.input_sequence);
            }
            self.save_owner_state()?;
            let selected = if workspace.is_empty() { String::new() } else { self.workspaces.id(workspace) };
            let mut ready = json!({"type":"ready","version":VERSION,"epoch":self.epoch,"workspace":selected,"hostname":identity::hostname(),"platform":std::env::consts::OS,"username":identity::username(),"resource_subscription":true});
            // Only encrypted logins offer datagrams: their key seals them.
            if let (Some(key), Some(port), true) = (c.datagram_key.take(), self.datagrams.port(),
                value["features"].as_array().is_some_and(|a| a.iter().any(|v| v == video_datagram::FEATURE)))
            {
                let ssrc = c.frontend_client as u32;
                c.datagram = Some(video_datagram::Peer::new(key, ssrc));
                ready["video_datagram"] = json!({"port": port, "ssrc": ssrc});
            }
            return send(c, ready);
        }
        // Authentication above grants a server capability. This path never
        // runs for pane-token JSON RPC and does not switch the viewer's session.
        if kind == "controller_rpc" {
            let result = if c.rpc_pending.len() >= 32 {
                Err(api::error("busy", "Too many pending terminal requests"))
            } else { controller::dispatch(self, &value["call"]) };
            return match result {
                Ok(api::Reply::Pending(receiver)) => { c.rpc_pending.push((value["request"].clone(), receiver)); Ok(()) },
                Ok(api::Reply::Ready(reply)) => send(c, api::rpc_response(value["request"].clone(), reply)),
                Err(error) => send(c, api::rpc_response(value["request"].clone(), json!({"error":error_details(&error)}))),
            };
        }
        let server_command = matches!(kind, "session_switch" | "session_new" | "session_rename" | "session_kill"
            | "resource_subscription" | "font_path" | "font_asset" | "font_config"
            | "terminal_gpu_offer" | "terminal_gpu_confirm" | "terminal_gpu_reject" | "close_server");
        if !server_command && (c.workspace_closed || self.workspace_incarnations.get(&c.workspace) != Some(&c.workspace_incarnation)) {
            return send(c, json!({"type":"error", "request":value["request"], "message":"No session is selected"}));
        }
        if kind == "rpc" {
            let result = (|| -> Result<api::Reply, Error> {
                let id = value["session"].as_u64().ok_or("Expected session")?;
                if !self.sessions.get(&id).is_some_and(|s| s.workspace == c.workspace)
                    && !self.chromiums.get(&id).is_some_and(|b| b.owner == id && b.workspace == c.workspace) {
                    return Err(api::error("forbidden", "Session is not in this workspace"));
                }
                if c.rpc_pending.len() >= 32 { return Err(api::error("busy", "Too many pending terminal requests")); }
                let method = value["method"].as_str().ok_or("Expected method")?;
                if method.starts_with("dictation.") {
                    self.dictation.request(&self.settings.dictation, id, method, &value["params"], binary)
                } else {
                    self.request(id, method, &value["params"])
                }
            })();
            let result = result.and_then(|reply| { self.save_owner_state()?; Ok(reply) });
            return match result {
                Ok(api::Reply::Pending(receiver)) => { c.rpc_pending.push((value["request"].clone(), receiver)); Ok(()) },
                Ok(api::Reply::Ready(reply)) => send(c, api::rpc_response(value["request"].clone(), reply)),
                Err(error) => send(c, api::rpc_response(value["request"].clone(), json!({"error":error_details(&error)}))),
            };
        }
        if kind == "resource_subscription" {
            let enabled = value["enabled"].as_bool().ok_or("Expected resource subscription boolean")?;
            if enabled && !c.resources_enabled {
                c.resources_at = Instant::now() - Duration::from_secs(1);
            }
            c.resources_enabled = enabled;
            return Ok(());
        }
        if kind == "scene_ack" {
            if let Some(sequence) = value["sequence"].as_u64() { c.scenes.acknowledge(sequence); }
            return Ok(());
        }
        if kind == "font_path" {
            let path = if c.socket.is_local() { self.fonts.local_path(value["sha256"].as_str().unwrap_or("")) } else { None };
            return send(c, json!({"type":"ack","request":value["request"],"font_path":path}));
        }
        if kind == "font_asset" {
            if c.font_pending.is_some() {
                return send(c, json!({"type":"error","request":value["request"],"message":"Font request already pending"}));
            }
            c.font_pending = Some(value);
            return Ok(());
        }
        if matches!(kind, "terminal_asset_request" | "terminal_resync") {
            let id = value["session"].as_u64().ok_or("Missing terminal session")?;
            let session = self.sessions.get_mut(&id).filter(|s| s.workspace == c.workspace && c.subscribed.contains(&id)).ok_or("Terminal is not subscribed")?;
            if kind == "terminal_resync" { c.scenes.forget(id); }
            else {
                let key = terminal_scene::requested_key(&value)?;
                let _ = session.scene_graphics()?;
                if let Some(asset) = session.scene_assets.assets.get(&key) { c.scenes.request(id, asset.clone())?; }
            }
            if value.get("request").is_some() { return send(c, json!({"type":"ack","request":value["request"]})); }
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        if matches!(kind, "terminal_gpu_offer" | "terminal_gpu_confirm" | "terminal_gpu_reject") {
            return terminal_scene::gpu_command(c, &value);
        }
        #[cfg(any(target_os = "macos", windows))]
        if matches!(kind, "chromium_gpu_offer" | "chromium_gpu_confirm" | "chromium_gpu_reject") {
            return chromium_gpu::Channels::handle(self, c, &value);
        }
        if matches!(kind, "workspace_get" | "workspace_edit") {
            let result = (|| -> Result<Value, Error> {
                workspace::sync(self, &c.workspace)?;
                let state = if kind == "workspace_edit" {
                    let revision = value["expected_revision"].as_u64().ok_or("Expected workspace revision")?;
                    let edit = serde_json::from_value::<graffitty_workspace_core::state::Edit>(value["edit"].clone())?;
                    // A frontend fitting the main view to its window claims the
                    // tab's area. The latest claim wins (see size_claims).
                    let claimed = match &edit {
                        graffitty_workspace_core::state::Edit::Tab { tab, .. } if value["claim"] == true => Some(*tab),
                        _ => None,
                    };
                    let state = self.workspace_state.edit(&c.workspace, revision, edit)?;
                    if let Some(tab) = claimed { self.size_claims.claim(&c.workspace, tab, c.frontend_client); }
                    workspace::sync_terminal_geometry(self, &c.workspace)?;
                    state
                } else { self.workspace_state.snapshot(&c.workspace) };
                self.save_owner_state()?;
                Ok(json!({"type":"ack","request":value["request"],"workspace":self.workspaces.id(&c.workspace),"workspace_state":state}))
            })();
            return send(c, match result {
                Ok(reply) => reply,
                Err(error) => json!({"type":"error","request":value["request"],"message":error.to_string(),
                    "workspace":self.workspaces.id(&c.workspace),"workspace_state":self.workspace_state.snapshot(&c.workspace)}),
            });
        }
        if kind == "auth_settings" || kind == "auth_reload" {
            let result = if !c.socket.is_local() {
                Err("Host authentication is controlled locally".into())
            } else if kind == "auth_reload" {
                host_auth::reload(self, value["rotate"] == true)
            } else {
                host_auth::settings(self)
            };
            return send(c, match result {
                Ok(result) => json!({"type":"ack","request":value["request"],"result":result}),
                Err(error) => json!({"type":"error","request":value["request"],"message":error.to_string()}),
            });
        }
        if kind == "remote_access" {
            let request=value["request"].clone();
            let result=(|| -> Result<Value,Error> {
                if !c.socket.is_local() { return Err("Remote access is controlled locally".into()); }
                host_auth::remote_access(self, value["enabled"] == true, value["address"].as_str())
            })();
            return send(c,match result {
                Ok(result)=>json!({"type":"ack","request":request,"result":result}),
                Err(error)=>json!({"type":"error","request":request,"message":error.to_string()}),
            });
        }
        if matches!(kind, "frontend_register" | "frontend_unregister" | "frontend_reply") {
            let result = (|| -> Result<Value, Error> {
                if !c.socket.is_local() { return Err("Presentation ownership requires a private local connection".into()); }
                if kind == "frontend_register" {
                    let generation=value["generation"].as_u64().ok_or("Missing frontend generation")?;
                    let owner = self.frontend.register(&c.workspace,c.frontend_client,generation);
                    self.last_viewed = Some(c.workspace.clone());
                    self.save_owner_state()?;
                    return Ok(json!({"owner":owner}));
                }
                if kind == "frontend_unregister" {
                    self.frontend.disconnect(c.frontend_client);
                    return Ok(json!({}));
                }
                let ticket=value["ticket"].as_u64().ok_or("Missing frontend request ticket")?;
                self.frontend.complete(&c.workspace,c.frontend_client,ticket,&value["response"])?;
                Ok(json!({}))
            })();
            return send(c,match result {
                Ok(result)=>json!({"type":"ack","request":value["request"],"result":result}),
                Err(error)=>json!({"type":"error","request":value["request"],"message":error.to_string()}),
            });
        }
        if kind == "subscribe" {
            let ids = value["sessions"]
                .as_array()
                .ok_or("Expected session list")?;
            if ids.len() > 32 {
                return Err("Too many subscriptions".into());
            }
            c.subscribed = ids
                .iter()
                .filter_map(Value::as_u64)
                .filter(|id| {
                    self.sessions
                        .get(id)
                        .is_some_and(|s| s.workspace == c.workspace)
                        || self
                            .chromiums
                            .get(id)
                            .is_some_and(|b| b.workspace == c.workspace)
                })
                .collect();
            c.chromium_viewports.retain(|id,_| c.subscribed.contains(id));
            c.chromium_paused.retain(|id| c.subscribed.contains(id));
            c.video_isolated.retain(|id| c.subscribed.contains(id));
            for session in self.sessions.values_mut() {
                session.clipboard.subscribe(c.frontend_client, c.clipboard_events && session.workspace == c.workspace && c.subscribed.contains(&session.id));
            }
            c.chromium_flow.retain(|id, _| self.chromiums.contains_key(id));
            for (id, flow) in &mut c.chromium_flow {
                if !c.subscribed.contains(id) { flow.restart(); }
            }
            c.revisions.clear();
            c.scenes.subscribe(&c.subscribed);
            c.video_cursors.clear();
            return Ok(());
        }
        if kind == "chromium_stream" {
            let views = chromium_video::parse_viewports(&value["viewports"], |id| {
                c.subscribed.contains(&id)
                    && self.chromiums.get(&id).is_some_and(|b| b.workspace == c.workspace)
            })?;
            let changed = chromium_video::changed_viewports(c.video_quality, &c.chromium_viewports, &views.displayed);
            // A camera move can leave most panes in their current rendition.
            // Preserve their reference cursors rather than forcing keyframes.
            c.video_cursors.retain(|id, _| !changed.contains(id));
            // Frames in flight when a pane pauses are never acknowledged by a
            // decoder that stopped presenting; resume with a fresh window.
            for id in views.paused.symmetric_difference(&c.chromium_paused) {
                c.video_cursors.remove(id);
                if let Some(flow) = c.chromium_flow.get_mut(id) { flow.restart(); }
            }
            c.chromium_viewports = views.displayed;
            c.chromium_paused = views.paused;
            return Ok(());
        }
        if kind == "chromium_ack" {
            if let (Some(id), Some(frame)) = (value["session"].as_u64(), value["frame"].as_u64()) {
                // Optional: a client acknowledging on receipt held the frame for no time.
                let held = Duration::from_millis(value["held_ms"].as_u64().unwrap_or(0));
                if let Some(flow) = c.chromium_flow.get_mut(&id) { flow.acknowledge_held(frame, held); }
                if let Some(peer) = &mut c.datagram { peer.sender.acknowledge(id, frame); }
            }
            return Ok(());
        }
        if kind == "chromium_video_reset" {
            if let Some(id) = value["session"].as_u64() {
                c.video_cursors.remove(&id);
                // The client asked for a keyframe: nothing it has not yet
                // acknowledged is of use to it. Holding the window for those
                // frames would only delay the keyframe.
                if let Some(flow) = c.chromium_flow.get_mut(&id) { flow.restart(); }
            }
            return Ok(());
        }
        if kind == "chromium_video_reject" {
            if let (Some(id), Some(codec)) = (value["session"].as_u64(), value["codec"].as_str().and_then(graffitty_chromium_video::Codec::parse)) {
                if c.subscribed.contains(&id) {
                    let rejected = c.video_rejected.entry(id).or_default();
                    if !rejected.contains(&codec) { rejected.push(codec); }
                    c.video_cursors.remove(&id);
                }
            }
            return Ok(());
        }
        let request = value["request"].clone();
        let result = (|| -> Result<Value, Error> {
            let id = value["session"].as_u64().unwrap_or(u64::MAX);
            if kind == "font_config" {
                if !c.socket.is_local() { return Err("Font settings are controlled locally".into()); }
                let config: fonts::Config = serde_json::from_value(value["config"].clone())?;
                if config.paths.iter().any(|path| !path.is_empty() && !std::path::Path::new(path).is_absolute()) {
                    return Err("Live font file paths must be absolute".into());
                }
                let fonts = fonts::Fonts::load(&config, std::path::Path::new("."))?;
                let metrics = fonts.metrics(config.size);
                for session in self.sessions.values().filter(|s| !s.exited) {
                    if session.logical_extent.0 < f64::from(metrics.width)*f64::from(session::MIN_COLUMNS) || session.logical_extent.1 < f64::from(metrics.height) {
                        return Err(format!("Font does not fit pane {}: at least {} columns and one row are required", session.id, session::MIN_COLUMNS).into());
                    }
                }
                let previous: Vec<_> = self.sessions.values().filter(|s| !s.exited).map(|s| (s.id,s.font_size)).collect();
                for &(id, _) in &previous {
                    if let Err(error) = self.sessions.get_mut(&id).unwrap().configure_font(config.size, metrics) {
                        for &(id, size) in &previous {
                            self.sessions.get_mut(&id).unwrap().configure_font(size, self.fonts.metrics(size))?;
                        }
                        return Err(error);
                    }
                }
                self.fonts = fonts;
                self.settings.terminal.font = config;
                self.recent_font_size = None;
                return Ok(json!({"config":self.settings.terminal.font}));
            }
            if kind == "session_switch" {
                let name = value["name"].as_str().ok_or("Expected session name")?;
                return session_switch::apply(self, c, name);
            }
            if kind == "session_rename" {
                return session_management::dispatch(self, &json!({"version":1,"method":"session.rename",
                    "params":{"name":value["name"],"new_name":value["new_name"]}}));
            }
            if kind == "session_kill" {
                // The authenticated client targets one stable session on this
                // server without switching its current workspace or stopping it.
                return session_management::dispatch(self, &json!({"version":1,"method":"session.kill",
                    "params":{"name":value["name"]}}));
            }
            if kind == "session_new" {
                // Authenticated local and remote clients create a named session
                // through the same validation as `gft session new`.
                let created = session_management::dispatch(self, &json!({
                    "version":1, "method":"session.new", "params":{"name":value["name"]}
                }))?;
                session_switch::apply(self, c, created["id"].as_str().unwrap())?;
                return Ok(created);
            }
            if kind == "sync" {
                // Queue the authoritative workspace membership before this
                // request's ack, so a resumed frontend can drain stale backlog.
                let catalog = self.session_catalog();
                send(c, catalog.clone())?;
                c.session_catalog = catalog;
                let topology = self.client_topology(&c.workspace, c.frontend_client);
                send(c, topology)?;
                return Ok(json!({}));
            }
            if kind == "restore_graph" {
                return session_checkpoints::restore_graph(self, &c.workspace, &value);
            }
            // Empty workspaces remain attachable and can create their first tab.
            if kind == "create" && value["kind"] != "pane" {
                let options = value.get("spawn").cloned().map(serde_json::from_value::<spawn::SpawnOptions>).transpose()?;
                let source = if id == u64::MAX { None } else {
                    let session = self.sessions.get(&id).ok_or("Unknown source session")?;
                    if session.workspace != c.workspace { return Err("Source session is not in this workspace".into()); }
                    Some(id)
                };
                let saved = SavedIdentity::parse(&value)?;
                let created = self.create_with_environment(&c.workspace, None, source, options, &[], saved)?;
                return Ok(json!({"created":created,"tab":self.sessions[&created].tab}));
            }
            if kind == "regroup" {
                let surface = value["surface"].as_str().map(str::to_owned).unwrap_or_else(||format!("%{id}"));
                if !value["tab"].is_null() && !value["tab"].is_u64() { return Err("Expected destination tab ID or null".into()); }
                if value.get("browser_only").is_some_and(|v| !v.is_boolean()) { return Err("browser_only must be boolean".into()); }
                if value.get("new_tab").is_some_and(|saved| !saved.is_u64() || !value["tab"].is_null()) { return Err("new_tab names the saved ID of a tab this move creates".into()); }
                return regroup::apply(self,&c.workspace,&surface,value["tab"].as_u64(),value["restore"]==true,value["browser_only"]==true,value["new_tab"].as_u64());
            }
            if kind == "session_transfer" {
                // Like session_new/session_switch, authenticated remote clients
                // may transfer on this server. apply validates source ownership
                // and destination identity before moving any live processes.
                return session_transfer::apply(self, &c.workspace, &value);
            }
            if kind == "close_server" {
                // Even authenticated loopback WebSockets are remote clients.
                // Only the private local IPC transport may stop this server.
                if !c.socket.is_local() {
                    return Err(api::error("forbidden", "Server shutdown requires local IPC"));
                }
                session_management::close_all(self)?;
                self.closing = true;
                return Ok(json!({"server_closed":true}));
            }
            if kind == "close_status" {
                let tabs: Vec<u64> = serde_json::from_value(value["tabs"].clone())?;
                if tabs.len() > 256 { return Err("Too many tabs in close request".into()); }
                for tab in &tabs {
                    if !self.sessions.values().any(|s|s.workspace==c.workspace && s.tab==*tab)
                        && !self.chromiums.values().any(|b|b.workspace==c.workspace && b.tab==*tab) {
                        return Err("Tab is not in this workspace".into());
                    }
                }
                // A single pane's close checks only that terminal and the
                // chromiums it owns, like Godot's request_close_terminal.
                let panes: Vec<u64> = serde_json::from_value(value.get("panes").cloned().unwrap_or(json!([])))?;
                if panes.len() > 256 { return Err("Too many panes in close request".into()); }
                for pane in &panes {
                    if !self.sessions.get(pane).is_some_and(|s|s.workspace==c.workspace) {
                        return Err("Pane is not in this workspace".into());
                    }
                }
                let sessions:Vec<_>=self.sessions.values().filter(|s|s.workspace==c.workspace&&(tabs.contains(&s.tab)||panes.contains(&s.id))).collect();
                let programs:Vec<_>=sessions.iter().filter(|s|close_policy::has_running_program(s.pid(),s.exited)).map(|s|s.id).collect();
                let chromiums:Vec<_>=self.chromiums.values().filter(|b|b.workspace==c.workspace&&(tabs.contains(&b.tab)||sessions.iter().any(|s|s.id==b.owner))).map(|b|b.id).collect();
                return Ok(json!({"confirmation_required":!programs.is_empty()||!chromiums.is_empty(),"programs":programs,"chromiums":chromiums}));
            }
            if kind == "close_group" {
                let tab=value["tab"].as_u64().ok_or("Expected tab")?;
                if !self.sessions.values().any(|s|s.workspace==c.workspace && s.tab==tab)
                    && !self.chromiums.values().any(|b|b.workspace==c.workspace && b.tab==tab) {
                    return Err("Tab is not in this workspace".into());
                }
                let chromiums:Vec<_>=self.chromiums.values().filter(|b|b.workspace==c.workspace && b.tab==tab).map(|b|b.id).collect();
                for chromium in chromiums {self.retire_chromium(chromium);}
                let panes:Vec<_>=self.sessions.values().filter(|s|s.workspace==c.workspace && s.tab==tab).map(|s|s.id).collect();
                for pane in panes {self.close(pane);}
                self.tab_titles.remove(&tab);
                return Ok(json!({}));
            }
            if kind == "create" {
                let created = workspace::create_pane(self, &c.workspace, id, &value)?;
                return Ok(json!({"created":created}));
            }
            let session = self
                .sessions
                .get_mut(&id)
                .filter(|s| s.workspace == c.workspace)
                .ok_or("Session is not in this workspace")?;
            match kind {
                "terminal_theme" => {
                    if !c.subscribed.contains(&id) { return Err("Terminal is not subscribed".into()); }
                    let theme = serde_json::from_value::<graffitty_protocol::terminal_theme::Theme>(value["theme"].clone())?;
                    session.set_terminal_theme(theme)?;
                }
                "clipboard_reply" => {
                    use base64::Engine as _;
                    if !c.clipboard_events || !c.subscribed.contains(&id) { return Err("Clipboard frontend is not subscribed".into()); }
                    let encoded = value["data"].as_str().filter(|s| s.len() <= 65536).ok_or("Invalid clipboard reply data")?;
                    let bytes = base64::engine::general_purpose::STANDARD.decode(encoded)?;
                    session.clipboard.reply(c.frontend_client,
                        value["generation"].as_u64().ok_or("Missing clipboard generation")?,
                        value["ticket"].as_u64().ok_or("Missing clipboard ticket")?,
                        value["offset"].as_u64().ok_or("Missing clipboard offset")? as usize,
                        bytes.len(), value["done"].as_bool().ok_or("Missing clipboard completion")?)?;
                    if !bytes.is_empty() { session.input(bytes)?; }
                }
                "input" => session.input(binary.ok_or("Use binary input packets")?.to_vec())?,
                "text" => session.input(
                    value["text"]
                        .as_str()
                        .ok_or("Expected text")?
                        .as_bytes()
                        .to_vec(),
                )?,
                "paste" => session.paste(value["text"].as_str().ok_or("Expected text")?)?,
                "resize_pixels" => {
                    let width = value["width"].as_f64().filter(|v| v.is_finite() && *v > 0. && *v <= 100000.).ok_or("Invalid logical width")?;
                    let height = value["height"].as_f64().filter(|v| v.is_finite() && *v > 0. && *v <= 100000.).ok_or("Invalid logical height")?;
                    session.resize_pixels(width, height)?;
                }
                "resize" => {
                    let cols = value["columns"]
                        .as_u64()
                        .filter(|v| *v <= 500)
                        .ok_or("Invalid columns")?;
                    let rows = value["rows"]
                        .as_u64()
                        .filter(|v| *v <= 300)
                        .ok_or("Invalid rows")?;
                    session.resize(cols as u16, rows as u16)?;
                }
                "font_size" => {
                    let size = value["size"].as_u64()
                        .filter(|size| (1..=72).contains(size))
                        .ok_or("Font size must be between 1 and 72")? as u16;
                    session.configure_font(size, self.fonts.metrics(size))?;
                    if value["remember"].as_bool() != Some(false) { self.recent_font_size = Some(size); }
                }
                "history" => {
                    let text = session.history()?;
                    send(c, json!({"type":"history","session":id,"text":text}))?;
                }
                "close" => {
                    self.close(id);
                }
                _ => return Err("Unknown action".into()),
            }
            if matches!(kind, "input" | "text" | "paste") {
                let session = self.sessions.get_mut(&id).ok_or("Session closed")?;
                let now = Instant::now();
                c.last_input.insert(id, now);
                session.typing_guard.human(now);
                session.clipboard.interact(c.frontend_client);
            }
            Ok(json!({}))
        })();
        let result = result.and_then(|reply| {
            self.retire_empty_workspaces()?;
            if binary.is_none() { self.save_owner_state()?; }
            Ok(reply)
        });
        // Raw input has no acknowledgment; report only delivery failures.
        if binary.is_some() && result.is_ok() {
            return Ok(());
        }
        match result {
            Ok(mut reply) => {
                reply["type"] = json!("ack");
                reply["request"] = request;
                send(c, reply)
            }
            Err(error) => send(
                c,
                json!({"type":"error","request":request,"message":error.to_string(),"error":error_details(&error)}),
            ),
        }
    }
    fn broadcast(&mut self, c: &mut Client) -> Result<(), Error> {
        if !c.authenticated {
            return Ok(());
        }
        let catalog = self.session_catalog();
        if c.session_catalog != catalog {
            send(c, catalog.clone())?;
            c.session_catalog = catalog;
        }
        let current_workspace = !c.workspace_closed && self.workspace_incarnations.get(&c.workspace) == Some(&c.workspace_incarnation);
        for session in self.sessions.values_mut() {
            if !current_workspace || !c.clipboard_events || session.workspace != c.workspace || !c.subscribed.contains(&session.id) {
                session.clipboard.subscribe(c.frontend_client, false);
            }
        }
        let mut replies = Vec::new();
        c.rpc_pending.retain(|(request, receiver)| {
            if let Some(reply) = api::completed(receiver) {
                replies.push(api::rpc_response(request.clone(), reply));
                false
            } else { true }
        });
        for reply in replies { send(c, reply)?; }
        if c.workspace_closed || c.workspace.is_empty() { return Ok(()); }
        if self.workspace_incarnations.get(&c.workspace) != Some(&c.workspace_incarnation) {
            let closed = format!("${}", c.workspace_incarnation);
            c.workspace_closed = c.socket.is_local();
            self.frontend.disconnect(c.frontend_client);
            self.size_claims.release(c.frontend_client);
            c.workspace.clear();
            c.subscribed.clear();
            c.scenes.subscribe(&[]);
            return send(c, json!({"type":"session_closed", "workspace":closed}));
        }
        for event in self.frontend.events(&c.workspace, c.frontend_client) {
            send(c, event)?;
        }
        // The full topology goes out only when its structure changes. Title,
        // foreground-app and similar churn is coalesced into small deltas, so
        // an animated agent title no longer re-sends every pane to every client.
        let topology = self.client_topology(&c.workspace, c.frontend_client);
        let structural = pane_updates::Tracker::structural(&topology);
        let now = Instant::now();
        let topology_changed = c.topology != structural;
        if topology_changed {
            send(c, topology.clone())?;
            c.topology = structural;
            c.pane_updates.reset(&topology, now);
        } else if let Some(update) = c.pane_updates.delta(&topology, &c.subscribed, now) {
            send(c, update)?;
        }
        // The presentation must exist before its cached resource samples arrive.
        // Switching workspaces does not restart the server-owned sampler.
        if c.resources_enabled && (topology_changed || c.resources_at.elapsed() >= Duration::from_secs(1)) {
            c.resources_at = Instant::now();
            let samples: Vec<Value> = self.sessions.values()
                .filter(|s| s.workspace == c.workspace)
                .filter_map(|s| self.resources.snapshot(s.id).map(|sample| json!({
                    "session": s.id, "interval": 1.0, "snapshot": resources::snapshot(sample)
                }))).collect();
            if !samples.is_empty() {
                send(c, json!({"type":"resources", "samples":samples}))?;
            }
        }
        c.revisions
            .retain(|id, _| self.sessions.contains_key(id) || self.chromiums.contains_key(id));
        c.scenes.retain(&c.subscribed);
        // Hiding a tab pauses delivery, not the connection's verified native
        // capability. Dropping it on unsubscribe left frontends holding a
        // supposedly active texture while the server silently resumed video.
        #[cfg(any(target_os = "macos", windows))]
        c.gpu.retain(|id| self.chromiums.get(&id).is_some_and(|b| b.workspace == c.workspace));
        c.notifications
            .retain(|id, _| self.sessions.contains_key(id));
        c.input_sequences.retain(|id, _| self.sessions.contains_key(id));
        let workspace = c.workspace.clone();
        c.clipboard_generations.retain(|id, _| self.sessions.contains_key(id));
        if c.clipboard_events {
            for s in self.sessions.values_mut().filter(|s| s.workspace == workspace) {
                let packets = s.clipboard.take(c.frontend_client);
                let generation = s.clipboard.generation;
                if c.clipboard_generations.get(&s.id) != Some(&generation) {
                    send(c, json!({"type":"clipboard_reset","session":s.id,"generation":generation}))?;
                    c.clipboard_generations.insert(s.id, generation);
                }
                for (ticket, operation) in packets {
                    send(c, json!({"type":"clipboard","session":s.id,"generation":generation,"ticket":ticket,"operation":operation}))?;
                }
            }
        }
        for s in self.sessions.values().filter(|s| s.workspace == workspace) {
            let last_input = c.input_sequences.get(&s.id).copied().unwrap_or(0);
            if c.subscribed.contains(&s.id) {
                let keys: Vec<_> = s.input_events.iter().filter(|(sequence, _)| *sequence > last_input).map(|(_, key)| key).collect();
                if !keys.is_empty() { send(c, json!({"type":"terminal_input","session":s.id,"keys":keys}))?; }
            }
            c.input_sequences.insert(s.id, s.input_sequence);
            let last = c.notifications.get(&s.id).copied().unwrap_or(0);
            for (sequence, event) in &s.notifications {
                if *sequence > last && (event["bell"] != true || c.bell_events) {
                    let mut event = event.clone();
                    event["type"] = json!("notification");
                    event["session"] = json!(s.id);
                    send(c, event)?;
                }
            }
            c.notifications.insert(s.id, s.notification_sequence);
        }
        // One small on-demand font chunk ahead of terminal updates. Fonts gate
        // pane rendering on the client, so terminal output must not starve
        // them; the modest pending-bytes bound still keeps the queue shallow.
        if c.socket.pending_bytes() < 256 * 1024 {
            if let Some(value) = c.font_pending.take() {
                let result = self.fonts.asset(value["sha256"].as_str().unwrap_or(""), value["offset"].as_u64().unwrap_or(0) as usize, value["max_bytes"].as_u64().unwrap_or(32 * 1024).min(512 * 1024) as usize);
                send(c, match result {
                    Ok(asset) => json!({"type":"ack","request":value["request"],"font_asset":asset}),
                    Err(error) => json!({"type":"error","request":value["request"],"message":error.to_string()}),
                })?;
            }
        }
        for id in c.scenes.terminal_order(&c.subscribed) {
            if c.socket.pending_bytes() >= 4 * 1024 * 1024 { break; }
            let Some(s) = self
                .sessions
                .get_mut(&id)
                .filter(|s| s.workspace == c.workspace)
            else {
                continue;
            };
            terminal_scene::send_updates(c, s)?;
        }
        if c.socket.pending_bytes() < 256 * 1024 {
            if let Some(bytes) = c.scenes.asset(&mut self.sessions, c.socket.is_local()) { queue(c, Message::Binary(bytes.into()))?; }
        }
        for id in c.subscribed.clone() {
            // Do not build a backlog of obsolete chromium frames on a slow link.
            if c.socket.pending_bytes() > 64 * 1024 { break; }
            // The client keeps showing its last frame under a paused overlay.
            if c.chromium_paused.contains(&id) { continue; }
            let Some(chromium) = self
                .chromiums
                .get(&id)
                .filter(|b| b.workspace == c.workspace)
            else {
                continue;
            };
            #[cfg(any(target_os = "macos", windows))]
            {
                let was_active = c.gpu.active(id);
                if c.gpu.deliver(id, &chromium.video) { continue; }
                if was_active { send(c, json!({"type":"chromium_gpu_state","session":id,"active":false}))?; }
            }
            // Encoded frames and images wait for the client's acknowledgements.
            let flow = c.chromium_flow.entry(id).or_default();
            if !flow.ready() {
                if !flow.stuck() { continue; }
                // A frame the client can never acknowledge (lost beyond
                // retransmission, or an acknowledgement that went missing)
                // must not freeze the stream: restart it at a keyframe.
                flow.recover_stall();
                c.video_cursors.remove(&id);
                if *TRACE_VIDEO {
                    eprintln!("chromium {id} restarts a stalled stream at a keyframe");
                }
            }
            if let Some(caps) = &client_video_codecs(c, id) {
                if let Some(codec) = chromium.video.available(caps, client_video_quality(c, chromium.id), client_video_pacing(c, chromium.id)) {
                    let (_, epoch, sequence) = c.video_cursors.get(&id).copied().filter(|v| v.0 == codec).unwrap_or((codec, 0, 0));
                    if let Some(frame) = chromium.video.next(codec, epoch, sequence) {
                        let number = c.chromium_flow.entry(id).or_default().send(frame.bytes.len());
                        let header = graffitty_protocol::ChromiumVideoHeader {
                            session: id, format: codec.codec.name().to_owned(), frame: number,
                            epoch: frame.epoch, sequence: frame.sequence, key: frame.key,
                            width: frame.width, height: frame.height,
                            source_width: frame.source_width, source_height: frame.source_height,
                        };
                        if *TRACE_VIDEO {
                            eprintln!("chromium {id} sends epoch {} sequence {}", frame.epoch, frame.sequence);
                        }
                        let message = packet(&serde_json::to_value(header)?, &frame.bytes);
                        match c.datagram.as_mut().filter(|peer| peer.active) {
                            // A keyframe replaces everything of this pane still
                            // queued or awaiting resend on the datagram link.
                            Some(peer) if frame.key => peer.sender.send_keyframe(id, number, message, Instant::now())?,
                            Some(peer) => peer.sender.send(id, number, message, Instant::now())?,
                            None => queue(c, Message::Binary(message.into()))?,
                        }
                        c.video_cursors.insert(id, (codec, frame.epoch, frame.sequence));
                    }
                    continue;
                } else if !c.chromium_png && c.revisions.get(&id) != Some(&u64::MAX) {
                    queue(c, Message::Binary(packet(&json!({"type":"chromium","session":id,"format":"error",
                        "error":"No shared hardware video codec is available"}), &[]).into()))?;
                    c.revisions.insert(id, u64::MAX);
                }
                if !c.chromium_png { continue; }
            }
            if !c.chromium_png { continue; }
            let Some((revision, bytes)) = chromium.video.preview() else { continue; };
            if bytes.is_empty() || c.revisions.get(&id) == Some(&revision) {
                continue;
            }
            let number = c.chromium_flow.entry(id).or_default().send(bytes.len());
            queue(
                c,
                Message::Binary(
                    packet(
                        &json!({"type":"chromium","session":id,"format":"png","frame":number}),
                        &bytes,
                    )
                    .into(),
                ),
            )?;
            c.revisions.insert(id, revision);
        }
        Ok(())
    }
}
/// Opt-in delivery trace; pairs with the video pipeline's own.
static TRACE_VIDEO: std::sync::LazyLock<bool> = std::sync::LazyLock::new(|| {
    std::env::var("RUST_LOG").is_ok_and(|v| v.contains("graffitty_video"))
});
fn uses_gpu(client: &Client, id: u64) -> bool {
    #[cfg(any(target_os = "macos", windows))]
    { client.gpu.active(id) }
    #[cfg(not(any(target_os = "macos", windows)))]
    { let _ = (client, id); false }
}
/// Why a remote address could not be listened on: a sentence for logs, and the
/// parts of it for a frontend to say in the user's language.
#[derive(Debug)]
pub(crate) struct ListenError {
    message: String,
    pub(crate) detail: Value,
}
impl std::fmt::Display for ListenError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}
impl std::error::Error for ListenError {}

pub(crate) fn network_listener(address: &str) -> Result<TcpListener, ListenError> {
    // Honor the explicitly configured interface, including wildcard addresses.
    // Parsing/binding failure must not fall back to a different interface.
    let plain = |message: String| ListenError { detail: json!({"address":address,"message":message}), message };
    let parsed: std::net::SocketAddr = address.parse().map_err(|error| plain(format!("{address}: {error}")))?;
    let listener = TcpListener::bind(parsed).map_err(|error| {
        if error.kind() != std::io::ErrorKind::AddrInUse { return plain(format!("{parsed}: {error}")); }
        // Say who holds the port: another Graffitty server and an unrelated
        // program call for different actions.
        let (holder, message, name, pid) = match graffitty_platform::port_owner::listening(parsed) {
            Some(owner) if owner.is_graffitty() =>
                ("graffitty", format!("{parsed} is in use by another Graffitty server (pid {})", owner.pid), owner.name, owner.pid),
            Some(owner) => ("program", format!("{parsed} is in use by {} (pid {})", owner.name, owner.pid), owner.name, owner.pid),
            None => ("unknown", format!("{parsed} is in use by another program"), String::new(), 0),
        };
        ListenError { detail: json!({"address":parsed.to_string(),"message":message,"holder":holder,"name":name,"pid":pid}), message }
    })?;
    listener.set_nonblocking(true).map_err(|error| plain(format!("{parsed}: {error}")))?;
    Ok(listener)
}

#[cfg(test)]
mod listener_tests {
    use super::network_listener;

    #[test]
    fn binds_requested_loopback_and_wildcard_addresses() {
        for ip in ["127.0.0.1", "0.0.0.0"] {
            let listener = network_listener(&format!("{ip}:0")).unwrap();
            assert_eq!(listener.local_addr().unwrap().ip().to_string(), ip);
            assert_ne!(listener.local_addr().unwrap().port(), 0);
        }
    }

    #[test]
    fn invalid_or_occupied_address_does_not_fall_back() {
        assert!(network_listener("not-an-address:7183").is_err());
        let listener = network_listener("127.0.0.1:0").unwrap();
        let taken = listener.local_addr().unwrap();
        let error = network_listener(&taken.to_string()).unwrap_err().to_string();
        // The holder is this test, not a Graffitty server, and is named.
        assert!(error.starts_with(&format!("{taken} is in use by ")), "{error}");
        assert!(!error.contains("Graffitty server"), "{error}");
        assert!(error.contains(&format!("(pid {})", std::process::id())), "{error}");
    }
}
fn new_client(socket: Connection, network_generation: u64) -> Client {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
    Client { frontend_client:NEXT.fetch_add(1,Ordering::Relaxed),session_switch:false,last_input:HashMap::new(),auth:Default::default(),socket,network_generation,api_reply:None,api_done:false,api_stream:false,rpc_pending:vec![],
        authenticated:false,opened:Instant::now(),workspace:String::new(),workspace_incarnation:0,workspace_closed:false,session_catalog:Value::Null,subscribed:vec![],
        revisions:HashMap::new(),topology:String::new(),pane_updates:Default::default(),scenes:Default::default(),font_pending:None,bell_events:false,clipboard_events:false,clipboard_generations:HashMap::new(),
        #[cfg(any(target_os = "macos", windows))]
        gpu: Default::default(),
        video_codecs:None, video_rejected:HashMap::new(), video_quality:chromium_video::Quality::default(), chromium_viewports:HashMap::new(), chromium_paused:Default::default(), chromium_png:false, video_isolated:Default::default(), video_cursors:HashMap::new(), chromium_flow:HashMap::new(),
        datagram_key:None, datagram:None,
        notifications:HashMap::new(),input_sequences:HashMap::new(),resources_at:Instant::now(),resources_enabled:true }
}
/// Shell command used without `--shell`, `[terminal] shell` or `SHELL`. On Windows,
/// PowerShell 7 when installed, otherwise the Windows PowerShell every system has,
/// both without the startup banner a terminal has no use for.
fn platform_shell() -> Vec<String> {
    if !cfg!(windows) {
        return vec!["/bin/sh".into()];
    }
    let path = std::env::var_os("PATH").unwrap_or_default();
    let pwsh = std::env::split_paths(&path).any(|directory| directory.join("pwsh.exe").is_file());
    vec![if pwsh { "pwsh.exe" } else { "powershell.exe" }.into(), "-NoLogo".into()]
}
/// Run a session server in this process, or perform a requested server action.
/// Where a server handing over to its successor leaves its environment
/// (see `server.restart`); the next server starts with it.
pub fn handover_environment_path(descriptor: &std::path::Path) -> PathBuf {
    descriptor.with_extension("environment.json")
}

pub fn run(options: Options) -> Result<(), Error> {
    if options.version {
        println!("gft server {} protocol={} {} {}", env!("GRAFFITTY_VERSION"), VERSION,
            std::env::consts::OS, std::env::consts::ARCH);
        return Ok(());
    }
    wake::init()?;
    let Options { config, connection, shell, listen, auth_file, set_password,
        clear_password, telegram_credential, telegram_chat_id, temporary_password_length, status, .. } = options;
    let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE"))?;
    // Without `--connection` this is the server the app looks for, so the app
    // attaches to a server started by hand instead of starting a second one.
    let descriptor = match connection {
        Some(path) => path,
        None => graffitty_protocol::default_server_descriptor().ok_or("Cannot resolve the server state directory")?,
    };
    let config_root = std::env::var("XDG_CONFIG_HOME").unwrap_or(format!("{home}/.config"));
    let explicit_config = config.is_some();
    let config_path = config.unwrap_or_else(|| PathBuf::from(format!("{config_root}/graffitty/server.toml")));
    let mut settings = settings::Settings::load(&config_path, explicit_config)?;
    // `--shell` names one executable and replaces the whole configured command.
    // Without either, `SHELL`, then the platform default.
    if let Some(shell) = &shell { settings.terminal.shell = Some(vec![shell.clone()]); }
    let default_shell = settings.terminal.shell.get_or_insert_with(|| {
        std::env::var("SHELL").map(|shell| vec![shell]).unwrap_or_else(|_| platform_shell())
    }).first().cloned().unwrap_or_default();
    settings.validate()?;
    // Beside the descriptor, where the app also keeps it.
    let auth_path = auth_file.unwrap_or_else(|| descriptor.with_file_name("auth.json"));
    let mut auth_config = auth::Config::load(&auth_path)?;
    if set_password || clear_password || telegram_credential.is_some() || telegram_chat_id.is_some() || temporary_password_length.is_some() {
        if set_password && clear_password {
            return Err("Choose set or clear password".into());
        }
        if set_password {
            let password = rpassword::prompt_password("New remote password: ")?;
            let confirmation = rpassword::prompt_password("Confirm password: ")?;
            if password != confirmation {
                return Err("Passwords do not match".into());
            }
            auth_config.set_password(&password)?;
        }
        if clear_password {
            auth_config.password = None;
        }
        if let Some(profile) = telegram_credential {
            auth_config.telegram_credential = if profile == "off" {
                None
            } else {
                if !graffitty_secrets::valid_name(&profile) { return Err("Invalid Telegram credential name".into()); }
                Some(profile)
            };
        }
        if let Some(chat) = telegram_chat_id {
            if chat.parse::<i64>().is_err() { return Err("Enter a numeric Telegram chat ID".into()); }
            auth_config.telegram_chat_id = Some(chat);
        }
        if let Some(length) = temporary_password_length {
            if ![6, 8, 10].contains(&length) {
                return Err("Temporary password length must be 6, 8, or 10".into());
            }
            auth_config.temporary_password_length = length;
        }
        auth_config.save(&auth_path)?;
        println!(
            "Remote authentication settings saved. Restart a running headless server to apply."
        );
        return Ok(());
    }
    if let Some(parent) = descriptor.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let lock = options.open(descriptor.with_extension("lock"))?;
    let locked = fs2::FileExt::try_lock_exclusive(&lock);
    if status {
        if locked.is_ok() {
            return Err("Server is not running".into());
        }
        println!("{}", fs::read_to_string(&descriptor)?);
        return Ok(());
    }
    locked.map_err(|_| "Server already running for this connection file")?;
    // Terminals a holder kept running after the previous owner left (planned
    // restart or crash). The next owner keeps that owner's identity, so the
    // programs' GRAFFITTY_SOCKET and capability tokens still reach it.
    let (holders, adopted) = {
        let restart = std::env::current_exe().map(|exe| {
            std::iter::once(graffitty_platform::install::stable_path(&exe).to_string_lossy().into_owned()).chain(std::env::args().skip(1)).collect()
        }).unwrap_or_default();
        let mut holders = holder_link::Holders::new(&descriptor, restart);
        let adopted = holders.attach_all();
        (holders, adopted)
    };
    let previous = owner_state::load(&descriptor).filter(|state| {
        adopted.iter().any(|a| state.sessions.iter().any(|s| s.id == u64::from(a.terminal.id)))
    });
    // A private IPC endpoint is always available. TCP is explicit opt-in.
    #[cfg(unix)] let runtime_base = PathBuf::from("/tmp");
    #[cfg(windows)] let runtime_base = std::env::temp_dir();
    let runtime = previous.as_ref().map(|state| state.runtime.clone())
        .unwrap_or_else(|| runtime_base.join(format!("graffitty-core-{}", uuid::Uuid::new_v4().simple())));
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)] { use std::os::unix::fs::DirBuilderExt; builder.mode(0o700); }
    if previous.is_none() || !runtime.is_dir() {
        builder.create(&runtime)?;
    }
    #[cfg(unix)] let ipc_path = runtime.join("session.sock");
    // The previous owner's endpoint, left behind by a crash.
    #[cfg(unix)] if previous.is_some() { let _ = fs::remove_file(&ipc_path); }
    // The pipe is named after the runtime directory. The next server uses the same
    // directory, so `GRAFFITTY_SOCKET` in running programs still works after a restart.
    #[cfg(windows)] let ipc_path = PathBuf::from(format!(r"\\.\pipe\{}",
        runtime.file_name().ok_or("Runtime directory has no name")?.to_string_lossy()));
    // Declared before the listener and server: on every exit path it drops
    // last, after both, and waits for chromium temporary sessions to go.
    let _chromium_cleanup = chromium::RuntimeCleanup;
    let private_listener = ipc::bind(&ipc_path)?;
    let local_token = format!("{}{}",uuid::Uuid::new_v4().simple(),uuid::Uuid::new_v4().simple());
    // `--listen` is the reason this server was started, so failing it is fatal.
    // Remote access from the configuration is an extra: when its address is
    // taken the server still runs for this computer and reports why.
    let mut remote_error = None;
    let remote_listener = if let Some(listen) = listen {
        Some(network_listener(&listen)?)
    } else if settings.remote.enabled {
        match network_listener(&std::net::SocketAddr::new(settings.remote.bind_address.parse()?, settings.remote.port).to_string()) {
            Ok(listener) => Some(listener),
            Err(error) => {
                eprintln!("[remote] Remote access is off: {error}");
                remote_error = Some(error.detail);
                None
            }
        }
    } else { None };
    let token = if auth_config.password.is_some() {
        String::new()
    } else {
        auth::temporary_password(auth_config.temporary_password_length)?
    };
    let running = Arc::new(AtomicBool::new(true));
    let stop = running.clone();
    ctrlc::set_handler(move || stop.store(false, Ordering::Relaxed))?;
    let authentication = auth::Server::new(auth_config, &token)?;
    let epoch = previous.as_ref().map(|state| state.epoch.clone()).unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let workspace_state = workspace::Store::new(&descriptor, &epoch)?;
    let resources = terminal_resource_monitor::Service::new()?;
    resources.set_cpu_scale(match settings.resource_monitor.cpu_percent_scale {
        settings::CpuPercentScale::OneCore => terminal_resource_monitor::CpuScale::OneCore,
        settings::CpuPercentScale::AllCores => terminal_resource_monitor::CpuScale::AllCores,
    });
    let mut server = Server {
        workspace_state,
        frontend: Default::default(),
        size_claims: Default::default(),
        auth: authentication,
        local_token,
        remote_token: token,
        remote_listener,
        remote_error,
        datagrams: Default::default(),
        network_generation: 0,
        pending_handshakes: Default::default(),
        descriptor: descriptor.clone(),
        auth_path: auth_path.clone(),
        resources: Arc::new(resources),
        sessions: BTreeMap::new(),
        tab_titles: HashMap::new(),
        retired_tabs: Default::default(),
        graphs: HashMap::new(),
        chromiums: BTreeMap::new(),
        filetrees: filetree::Filetrees::default(),
        dictation: dictation::Service::default(),
        uploads: Default::default(),
        chromium_ticket: 0,
        retired_chromiums: vec![],
        workers: workers::Workers::new(descriptor.parent().unwrap_or(std::path::Path::new(".")), settings.workers.clone())?,
        scan_at: Instant::now(),
        app_scan_at: Instant::now(),
        app_groups: HashMap::new(),
        foreground_apps: HashMap::new(),
        native_pending: HashMap::new(),
        completions: agent_completion::Completions::default(),
        agent_contexts: HashMap::new(),
        pane_claims: Default::default(),
        checkpoint_lifecycle: Default::default(),
        holders: Some(holders),
        handover: false,
        park: false,
        frontend_notice: None,
        parked_frontends: Vec::new(),
        closing: false,
        owner_runtime: runtime.clone(),
        saved_owner: None,
        last_viewed: None,
        endpoint: format!("ipc://{}", ipc_path.display()),
        cli: graffitty_platform::install::stable_path(&std::env::current_exe()?).to_string_lossy().into_owned(),
        workspaces: session_registry::Registry::default(),
        session_name_cache: Default::default(),
        agent_title_cache: Default::default(),
        pending_wires: HashMap::new(),
        started_session: false,
        lifecycle_dirty: false,
        workspace_incarnations: HashMap::new(),
        next: 1,
        shell: default_shell,
        recent_font_size: None,
        fonts: fonts::Fonts::load(&settings.terminal.font, config_path.parent().unwrap_or(std::path::Path::new(".")))?,
        settings,
        epoch,
    };
    owner_state_adopt(&mut server, adopted, previous);
    server.save_owner_state()?;
    server.publish_descriptor()?;
    let mut automatic_checkpoints = session_checkpoints::Automatic::new(server.settings.checkpoints.interval_seconds);
    let (tx, rx) = mpsc::sync_channel(32);
    let (api_tx, api_rx) = mpsc::sync_channel::<ApiRequest>(32);
    let handshakes = Arc::new(AtomicUsize::new(0));
    let _ = graffitty_chromium_video::encoders(&graffitty_chromium_video::Codec::PREFERENCE);
    let mut clients: Vec<Client> = vec![];
    let mut api_waiting: Vec<ApiWaiting> = vec![];
    let mut terminal_waiting: Vec<(ApiRequest, mpsc::Receiver<Value>)> = vec![];
    let mut empty_since: Option<Instant> = None;
    eprintln!(
        "[remote] {} (connection file: {})",
        server.endpoint,
        descriptor.display()
    );
    let mut agent_watches = Vec::new();
    while running.load(Ordering::Relaxed) && !server.handover {
        for _ in 0..8 {
            if clients.len() >= 64 { break; }
            let Ok(stream) = ipc::accept(&private_listener) else { break; };
            clients.push(new_client(Connection::Local(ipc::Peer::new(stream)),server.network_generation));
        }
        if let Some(listener) = &server.remote_listener
            && let Ok((stream, _)) = listener.accept()
            && clients.len() + handshakes.load(Ordering::Relaxed) < 64
        {
            let Ok(handshake_lease) = server.pending_handshakes.track(&stream) else { continue; };
            handshakes.fetch_add(1, Ordering::Relaxed);
            let count = handshakes.clone();
            let tx = tx.clone();
            let api_tx = api_tx.clone();
            let generation = server.network_generation;
            thread::spawn(move || {
                let _handshake_lease = handshake_lease;
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
                let _ = stream.set_nodelay(true);
                connection::limit_unsent(&stream);
                // Only this machine may use the plaintext API or the local
                // capability; everyone else must complete the encrypted login.
                let loopback = stream.peer_addr().is_ok_and(|a| a.ip().to_canonical().is_loopback());
                let mut first = [0];
                if stream.peek(&mut first).is_ok() && first[0] == b'{' {
                    if !loopback {
                        count.fetch_sub(1, Ordering::Relaxed);
                        return;
                    }
                    let mut stream = stream;
                    let mut bytes = Vec::new();
                    let mut buffer = [0u8; 4096];
                    while bytes.len() < 4 * 1024 * 1024 {
                        match stream.read(&mut buffer) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => bytes.extend_from_slice(&buffer[..n]),
                        }
                        if let Some(end) = bytes.iter().position(|b| *b == b'\n') {
                            if let Ok(value) = serde_json::from_slice::<Value>(&bytes[..end]) {
                                let watching = value["method"] == "graph.watch";
                                let (reply, rx) = mpsc::sync_channel(32);
                                if api_tx.try_send(ApiRequest { value, reply }).is_ok() {
                                    wake::notify();
                                    while let Ok(value) = rx.recv_timeout(Duration::from_secs(35)) {
                                        if writeln!(stream, "{value}").is_err() || !watching || value.get("error").is_some() { break; }
                                    }
                                }
                            }
                            break;
                        }
                    }
                    count.fetch_sub(1, Ordering::Relaxed);
                    return;
                }
                let limit = graffitty_protocol::MAX_COMMAND_PACKET + auth::CHANNEL_OVERHEAD;
                let config = WebSocketConfig::default()
                    .max_message_size(Some(limit))
                    .max_frame_size(Some(limit))
                    .max_write_buffer_size(8388608)
                    .write_buffer_size(0);
                if let Ok(socket) = tungstenite::accept_with_config(stream, Some(config)) {
                    let _ = socket.get_ref().set_nonblocking(true);
                    let _ = tx.try_send((connection::NetworkPeer::new(socket, loopback),generation));
                    wake::notify();
                }
                count.fetch_sub(1, Ordering::Relaxed);
            });
        }
        while let Ok((peer,generation)) = rx.try_recv() {
            if clients.len() < 32 {
                clients.push(new_client(Connection::Network(peer),generation));
            }
        }
        while let Ok(request) = api_rx.try_recv() {
            if request.value["method"] == "graph.watch" {
                agent_watch::subscribe(&mut server, &mut agent_watches, request);
                continue;
            }
            if matches!(request.value["method"].as_str(), Some("session.attach" | "session.create")) {
                let result = session_switch::from_pane(&mut server, &mut clients, &request.value)
                    .and_then(|reply| { server.save_owner_state()?; Ok(reply) });
                let response = match result {
                    Ok(value) => json!({"result":value}),
                    Err(error) => json!({"error":error_details(&error)}),
                };
                let mut response = response;
                response["id"] = request.value["id"].clone();
                response["version"] = json!(1);
                let _ = request.reply.try_send(response);
                continue;
            }
            // Existing server-only/other frontend clients retain their API behavior.
            // Invalid capabilities and request shapes still use the original auth path.
            if frontend::handles_request(&request.value)
                && request.value["version"] == 1 && request.value["params"].is_object()
                && request.value["token"].as_str().and_then(|token|server.sessions.values().find(|s|s.token==token))
                    .is_some_and(|s|server.frontend.has_owner(&s.workspace)) {
                let routed = (|| -> Result<(), Error> {
                    if request.value["version"] != 1 {
                        return Err("Unsupported API version".into());
                    }
                    if !request.value["params"].is_object() {
                        return Err("Expected params object".into());
                    }
                    let token = request.value["token"]
                        .as_str()
                        .ok_or("Missing capability")?;
                    let session = server
                        .sessions
                        .values()
                        .find(|s| s.token == token)
                        .ok_or("Invalid pane capability")?;
                    let workspace = session.workspace.clone();
                    let mut id = session.id;
                    let mut value = request.value.clone();
                    if value["method"] == "navigator.focus" {
                        if let Some(tty) = value["params"]["client_tty"].as_str() {
                            id = server.sessions.values()
                                .find(|s| s.workspace == workspace && s.tty_name() == tty)
                                .map(|s| s.id).ok_or("tmux client is not attached to this Graffitty session")?;
                        }
                    }
                    if value["method"]
                        .as_str()
                        .is_some_and(|m| m.starts_with("chromium."))
                    {
                        value["params"] = server.chromium_target_params(id, &value["params"])?;
                    }
                    server
                        .frontend
                        .enqueue(&workspace, id, &value, request.reply.clone())?;
                    Ok(())
                })();
                if let Err(error) = routed {
                    let _ = request.reply.try_send(json!({"id":request.value["id"],"version":1,
                        "error":{"code":"frontend_unavailable","message":error.to_string()}}));
                }
                continue;
            }
            let mut response = match server.api(request.value.clone()) {
                api::Reply::Ready(value) => value,
                api::Reply::Pending(receiver) => { terminal_waiting.push((request, receiver)); continue; }
            };
            response["version"] = json!(1);
            response["id"] = request.value["id"].clone();
            if let (Some(ticket), Some(chromium)) = (
                response["result"]["_ticket"].as_u64(),
                response["result"]["_chromium"].as_u64(),
            ) {
                api_waiting.push(ApiWaiting {
                    request,
                    chromium,
                    ticket,
                    started: Instant::now(),
                });
            } else {
                let _ = request.reply.try_send(response);
            }
        }
        let mut owner_changed = false;
        for s in server.sessions.values_mut() {
            s.poll();
            if std::mem::take(&mut s.program_status_changed) {
                owner_changed = true;
                let status = s.program_status.status.as_ref().map(|status| json!(status));
                if let Some(graph) = server.graphs.get_mut(&s.workspace) {
                    graph.observe_program_status(s.id, status.as_ref());
                }
            }
        }
        pane_claim::poll(&mut server);
        filetree::poll(&mut server);
        server.dictation.poll();
        server.uploads.expire();
        // Shell exit has the same lifecycle as closing a pane, even when no
        // frontend is attached to notice its final terminal frame.
        let exited: Vec<_> = server.sessions.values().filter(|s| s.exited).map(|s| s.id).collect();
        owner_changed |= !exited.is_empty();
        for id in exited { server.close(id); }
        if owner_changed { server.save_owner_state()?; }
        terminal_waiting.retain(|(request, receiver)| {
            if let Some(mut reply) = api::completed(receiver) {
                reply["version"] = json!(1);
                reply["id"] = request.value["id"].clone();
                let _ = request.reply.try_send(reply);
                false
            } else { true }
        });
        server.retire_empty_workspaces()?;
        for chromium in server.chromiums.values_mut() {
            // One shared page renders for its largest viewer. A viewer that
            // reports no displayed size keeps the page at CSS resolution.
            let (id, workspace) = (chromium.id, chromium.workspace.clone());
            let displays = |c: &Client| c.authenticated && c.workspace == workspace
                && c.subscribed.contains(&id) && !c.chromium_paused.contains(&id);
            // Paused viewers keep the last render scale; no frames reach them.
            let mut viewers = clients.iter().filter(|c| displays(c)).peekable();
            if viewers.peek().is_some() {
                chromium.render_demand(viewers.try_fold(0, |largest, c| {
                    c.chromium_viewports.get(&chromium.id).map(|&height| largest.max(height))
                }));
            }
            chromium.video.retain_pacing(&clients.iter()
                .filter(|c| displays(c))
                .map(|c| client_video_pacing(c, chromium.id)).collect());
            // Only sustained congestion splits a shared rendition. A transient
            // full window on a healthy link should not allocate another encoder.
            let candidates: Vec<_> = clients.iter()
                .filter(|c| displays(c))
                .filter(|c| !uses_gpu(c, chromium.id))
                .filter_map(|c| client_video_codecs(c, chromium.id)
                    .and_then(|caps| chromium.video.available(&caps, client_video_quality(c, chromium.id), client_video_pacing(c, chromium.id)))
                    .map(|stream| {
                        let flow = c.chromium_flow.get(&chromium.id);
                        let backlogged = c.socket.pending_bytes() > 64 * 1024;
                        (c.frontend_client, stream,
                            backlogged || flow.is_some_and(|f| f.congested()),
                            backlogged || flow.is_some_and(|f| f.saturated()),
                            !backlogged && flow.is_none_or(|f| f.ready()))
                    }))
                .collect();
            let mut consumers = Vec::new();
            for (client, mut stream, congested, saturated, ready) in candidates.iter().copied() {
                if stream.pacing == 0 && congested
                    && candidates.iter().any(|(_, other, _, _, ready)| *other == stream && *ready)
                {
                    stream.pacing = client;
                    clients.iter_mut().find(|c| c.frontend_client == client).unwrap().video_isolated.insert(chromium.id);
                }
                consumers.push((stream, saturated, ready));
            }
            // A shared rendition runs at the bitrate its most constrained
            // viewer's link carries; a congested viewer was split off above.
            let mut shares: HashMap<chromium_video::Stream, f32> = HashMap::new();
            for ((client, ..), (stream, ..)) in candidates.iter().zip(&consumers) {
                let (client, stream) = (*client, *stream);
                let share = clients.iter().find(|c| c.frontend_client == client)
                    .and_then(|c| c.chromium_flow.get(&chromium.id))
                    .map_or(1.0, chromium_flow::Flow::bitrate_share);
                let entry = shares.entry(stream).or_insert(1.0);
                *entry = entry.min(share);
            }
            // Pause while a live client is full, or while no client can take
            // a frame at all; a stalled client alone must not let it run ahead.
            let paused = consumers.iter().map(|(stream, _, _)| *stream)
                .filter(|stream| consumers.iter().any(|(s, saturated, _)| s == stream && *saturated)
                    || !consumers.iter().any(|(s, _, ready)| s == stream && *ready))
                .collect();
            chromium.video.demand(consumers.iter().map(|(stream, _, _)| *stream).collect(), paused, shares,
                clients.iter().any(|c| displays(c) && !uses_gpu(c, chromium.id) && c.chromium_png
                    && client_video_codecs(c, chromium.id).is_none_or(|caps| chromium.video.available(&caps, client_video_quality(c, chromium.id), client_video_pacing(c, chromium.id)).is_none())));
            // Capture stops once every viewer paused the pane, as for a pane
            // in a hidden workspace tab; resuming captures the current page.
            chromium.capture(clients.iter().any(|c| displays(c)));
            chromium.poll();
        }
        #[cfg(target_os = "macos")]
        server.sync_chromium_windows();
        api_waiting.retain(|waiting| {
            let result=server.chromiums.get_mut(&waiting.chromium).and_then(|b|b.results.remove(&waiting.ticket));
            let result=if result.is_none() && (!server.chromiums.contains_key(&waiting.chromium) || waiting.started.elapsed()>Duration::from_secs(32)){Some(json!({"error":{"code":"chromium_timeout","message":"Chromium closed or timed out"}}))}else{result};
            if let Some(mut result)=result {result["version"]=json!(1);result["id"]=waiting.request.value["id"].clone();let _=waiting.request.reply.try_send(result);false}else{true}
        });
        for chromium in &mut server.retired_chromiums {
            chromium.poll();
        }
        server.retired_chromiums.retain(|b| !b.finished());
        server.agents();
        server.frontend.expire(|id, workspace| server.sessions.get(&id).is_some_and(|s|s.workspace == workspace));
        agent_watch::flush(&server, &mut agent_watches);
        server.datagrams.sync(server.remote_listener.as_ref());
        server.datagrams.receive(&mut clients);
        let mut datagrams_pending = false;
        clients.retain_mut(|c| {
            let result = (|| -> Result<(), Error> {
                if !c.socket.is_local() && c.network_generation != server.network_generation {
                    return Err("Remote access disabled or changed".into());
                }
                if c.api_done {
                    match c.socket.flush() {
                        Err(tungstenite::Error::Io(e)) if e.kind()==std::io::ErrorKind::WouldBlock=>return Ok(()),
                        result=>result?,
                    }
                    return Err("API complete".into());
                }
                if let Some(reply) = &c.api_reply {
                    match reply.try_recv() {
                        Ok(value) => {
                            let finished = !c.api_stream || value.get("error").is_some();
                            send(c,value)?;
                            if finished { c.api_reply=None; c.api_done=true; }
                        }
                        Err(mpsc::TryRecvError::Disconnected) => return Err("API request failed".into()),
                        _ => {}
                    }
                    if !c.api_stream || c.api_done { return Ok(()); }
                }
                if !c.authenticated && !c.api_stream
                    && c.opened.elapsed() > Duration::from_secs(c.auth.timeout_seconds())
                {
                    return Err("Authentication timeout".into());
                }
                if !c.authenticated {
                    if let Some(message) = c.auth.poll()? {
                        send(c, message)?;
                    }
                }
                for _ in 0..64 {
                    match c.socket.read() {
                        Ok(Message::Text(text)) => {
                            let value: Value = serde_json::from_str(&text)?;
                            if c.socket.is_cli() {
                                if c.api_stream { return Err("Subscription does not accept further requests".into()); }
                                c.api_stream = value["method"] == "graph.watch";
                                let (reply, rx) = mpsc::sync_channel(32);
                                api_tx.try_send(ApiRequest { value, reply })?;
                                wake::notify();
                                c.api_reply=Some(rx);
                                break;
                            }
                            server.handle(c, value, None)?
                        }
                        Ok(Message::Binary(bytes)) => {
                            let (header, payload) = unpack(&bytes)?;
                            server.handle(c, header, Some(payload))?;
                        }
                        Ok(Message::Close(_)) => return Err("Detached".into()),
                        Ok(_) => {}
                        Err(tungstenite::Error::Io(e))
                            if e.kind() == std::io::ErrorKind::WouldBlock =>
                        {
                            break;
                        }
                        Err(e) => return Err(e.into()),
                    }
                }
                if !c.api_stream { server.broadcast(c)?; }
                datagrams_pending |= server.datagrams.send(c);
                match c.socket.flush() {
                    Ok(()) => Ok(()),
                    Err(tungstenite::Error::Io(e))
                        if e.kind() == std::io::ErrorKind::WouldBlock =>
                    {
                        Ok(())
                    }
                    Err(e) => Err(e.into()),
                }
            })();
            if let Err(error) = result {
                if c.socket.is_local() {
                    eprintln!("[local] Client disconnected: {error}");
                } else {
                    // A remote viewer dropped for a full write buffer or a
                    // protocol error used to vanish silently.
                    eprintln!("[network] Client {} disconnected: {error}", c.frontend_client);
                }
                server.frontend.disconnect(c.frontend_client);
                for session in server.sessions.values_mut() { session.clipboard.subscribe(c.frontend_client, false); }
                server.size_claims.release(c.frontend_client);
                let _ = c.socket.close(Some(connection::failure_close(c.authenticated, &error.to_string())));
                false
            } else {
                true
            }
        });
        automatic_checkpoints.poll(&mut server);
        // Remote-enabled servers remain discoverable with no sessions. A private
        // owner exits after its last session, draining acknowledgements and close
        // events first. Observers must not keep an empty private owner alive.
        if server.closing || (server.stops_when_empty() && server.started_session && server.workspaces.is_empty()) {
            let since = empty_since.get_or_insert_with(Instant::now);
            let pending = clients.iter().any(|c| c.socket.pending_bytes() > 0
                || c.api_reply.is_some() || c.api_done
                || (c.authenticated && !c.workspace_closed))
                || handshakes.load(Ordering::Relaxed) > 0 || !api_waiting.is_empty();
            if !pending || since.elapsed() >= Duration::from_secs(1) {
                server.pending_handshakes.revoke();
                break;
            }
        } else {
            empty_since = None;
        }
        #[cfg(unix)] {
            use std::os::fd::AsRawFd;
            let mut descriptors=vec![libc::pollfd { fd:ipc::listener_fd(&private_listener),events:libc::POLLIN,revents:0 }];
            if let Some(listener)=&server.remote_listener { descriptors.push(libc::pollfd {fd:listener.as_raw_fd(),events:libc::POLLIN,revents:0}); }
            if let Some(fd)=server.datagrams.raw_fd() { descriptors.push(libc::pollfd {fd,events:libc::POLLIN,revents:0}); }
            for client in &clients { descriptors.push(libc::pollfd {fd:client.socket.raw_fd(),events:libc::POLLIN | if client.socket.pending_bytes()>0 {libc::POLLOUT} else {0},revents:0}); }
            let pending=clients.iter().any(|c| c.socket.pending_bytes()<4*1024*1024 && c.scenes.pending());
            // Paced datagrams leave within a millisecond of their budget.
            wake::wait(descriptors,if pending {0} else if datagrams_pending {1} else {8});
        }
        #[cfg(windows)] {
            // Shared-GPU frames hop host -> chromium worker -> this loop ->
            // client; each hop waited a 15.6 ms tick and held local panes
            // near 21 fps, so presenting them needs precise timers too.
            let _ = datagrams_pending;
            wake::precise_timers(clients.iter().any(|c| c.authenticated
                && c.subscribed.iter().any(|id| c.chromium_flow.contains_key(id) || uses_gpu(c, *id))));
            std::thread::park_timeout(Duration::from_millis(1));
        }
    }
    let handover = server.handover;
    if handover {
        if let Some(relaunch) = server.frontend_notice {
            // Tell local frontends before this server exits:
            // - Parked: they must close. Their files are replaced next, and a frontend
            //   that stayed would start the old server again.
            // - After an upgrade: they reopen as the new version.
            server.parked_frontends = notify_update(&mut clients, relaunch);
        }
        hand_over(&mut server, &runtime);
    } else {
        // A planned restart keeps every program; any other end loses them.
        automatic_checkpoints.finish(&mut server);
    }
    let holders = server.holders.take();
    // Held sessions marked detached stay running; every other one ends here.
    drop(server);
    if let Some(mut holders) = holders.filter(|_| !handover) {
        holders.goodbye(holder_proto::Goodbye::Shutdown);
    }
    if !handover {
        owner_state::clear(&descriptor);
    }
    let _ = fs::remove_file(descriptor);
    drop(private_listener);
    // The next owner binds the same endpoint after a planned restart.
    if !handover {
        let _ = fs::remove_dir_all(runtime.join("files"));
        let _ = fs::remove_dir(runtime);
    }
    Ok(())
}

/// The identities a pane had when its checkpoint was saved, which a restore
/// asks to keep. Each is granted only while unused; see `Server::pane_identity`.
#[derive(Clone, Copy, Default)]
pub struct SavedIdentity {
    pub pane: Option<u64>,
    /// Only for a pane that opens a new tab.
    pub tab: Option<u64>,
    /// The largest ID in the checkpoint: new IDs start after it.
    pub through: Option<u64>,
}
impl SavedIdentity {
    /// Keeps one restored file from moving every later identity out of reach.
    const LIMIT: u64 = 1 << 32;
    pub fn parse(value: &Value) -> Result<Self, Error> {
        let field = |name: &str| match value.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(saved) => saved.as_u64().map(Some).ok_or_else(|| Error::from(format!("Expected a saved ID in {name}"))),
        };
        Ok(Self { pane: field("id")?, tab: field("tab")?, through: field("through")? })
    }
    /// The first wanted identity, from 1 up, that nothing live has, else
    /// the next new one.
    fn choose(wanted: [Option<u64>; 2], next: u64, unused: impl Fn(u64) -> bool) -> u64 {
        wanted.into_iter().flatten().find(|id| (1..Self::LIMIT).contains(id) && unused(*id)).unwrap_or(next)
    }
}
#[cfg(test)]
mod saved_identity_tests {
    use super::SavedIdentity;
    use serde_json::json;

    #[test]
    fn a_saved_identity_is_kept_unless_something_live_has_it() {
        let live = [3, 7];
        let unused = |id: u64| !live.contains(&id);
        assert_eq!(SavedIdentity::choose([Some(5), None], 9, unused), 5);
        assert_eq!(SavedIdentity::choose([Some(40), None], 9, unused), 40, "IDs past the counter are kept too");
        assert_eq!(SavedIdentity::choose([Some(7), None], 9, unused), 9, "Restoring beside the original takes a new ID");
        assert_eq!(SavedIdentity::choose([None, None], 9, unused), 9);
        assert_eq!(SavedIdentity::choose([Some(u64::MAX), None], 9, unused), 9);
        assert_eq!(SavedIdentity::choose([Some(0), None], 9, unused), 9, "Pane IDs start at one");
        // A new tab prefers its saved ID, then its first pane's.
        assert_eq!(SavedIdentity::choose([Some(3), Some(5)], 9, unused), 5);
        assert_eq!(SavedIdentity::choose([Some(3), Some(7)], 9, unused), 9);
        assert_eq!(SavedIdentity::choose([Some(0), Some(0)], 9, unused), 9, "A layout tab is never zero");
    }
    #[test]
    fn saved_identities_are_optional_unsigned_numbers() {
        let saved = SavedIdentity::parse(&json!({"id":4,"tab":2,"through":9})).unwrap();
        assert_eq!((saved.pane, saved.tab, saved.through), (Some(4), Some(2), Some(9)));
        let saved = SavedIdentity::parse(&json!({"tab":null})).unwrap();
        assert_eq!((saved.pane, saved.tab), (None, None));
        assert!(SavedIdentity::parse(&json!({"id":"%4"})).is_err());
        assert!(SavedIdentity::parse(&json!({"id":-1})).is_err());
    }
}

impl Server {
    /// Commit recovery metadata before acknowledging a request or event.
    /// Skip the write when state is unchanged. Return any commit failure
    /// so success always means the pane can be recovered.
    fn save_owner_state(&mut self) -> Result<(), Error> {
        if self.holders.is_none() { return Ok(()); }
        let mut state = owner_state::OwnerState::new(&self.epoch, &self.owner_runtime, self.next, &self.tab_titles);
        state.workspaces = self.workspaces.clone();
        state.filetrees = self.filetrees.saved();
        state.last_viewed = self.last_viewed.clone();
        state.sessions = self.sessions.values().filter(|s| s.is_held() && !s.exited).map(Session::saved).collect();
        if self.saved_owner.as_ref() == Some(&state) { return Ok(()); }
        // Persist even an empty registry: deletion errors must not silently
        // leave stale metadata behind after the last pane closes.
        owner_state::save(&self.descriptor, &state)?;
        self.saved_owner = Some(state);
        Ok(())
    }
}

/// Planned restart: the holder keeps every program; we save each screen exactly.
fn hand_over(server: &mut Server, runtime: &std::path::Path) {
    if let Some(holders) = server.holders.as_mut() {
        // After the goodbye the holder sends nothing more: every output it
        // forwarded is queued for its session and lands in the saved screen.
        holders.goodbye(if server.park { holder_proto::Goodbye::Park } else { holder_proto::Goodbye::Handover });
    }
    let mut state = owner_state::OwnerState::new(&server.epoch, runtime, server.next, &server.tab_titles);
    state.workspaces = server.workspaces.clone();
    state.filetrees = server.filetrees.saved();
    state.last_viewed = server.last_viewed.clone();
    for session in server.sessions.values_mut().filter(|s| s.is_held() && !s.exited) {
        match session.handover_screen() {
            Ok(screen) => {
                if let Err(error) = owner_state::save_screen(&server.descriptor, session.id, &screen) {
                    eprintln!("[holder] cannot save screen %{}: {error}", session.id);
                }
            }
            Err(error) => eprintln!("[holder] cannot capture screen %{}: {error}", session.id),
        }
        state.sessions.push(session.saved());
        session.detached = true;
    }
    if let Err(error) = owner_state::save(&server.descriptor, &state) {
        eprintln!("[holder] cannot save owner state: {error}");
    }
    if server.park {
        let parked = json!({
            "command": server.holders.as_ref().map(|holders| holders.restart_command()),
            "terminals": state.sessions.len(),
            "frontends": server.parked_frontends,
        });
        if let Err(error) = owner_state::save_parked(&server.descriptor, &parked) {
            eprintln!("[holder] cannot record the parked server: {error}");
        }
    }
}

/// Tells every local frontend about an upgrade and waits a moment for them to
/// disconnect. Returns their process ids, on platforms that report them.
fn notify_update(clients: &mut [Client], relaunch: bool) -> Vec<u32> {
    let mut processes = Vec::new();
    for client in clients.iter_mut().filter(|c| c.authenticated && c.socket.is_local()) {
        if send(client, json!({"type":"update","relaunch":relaunch})).is_ok() {
            let _ = client.socket.flush();
        }
        if let connection::Connection::Local(peer) = &client.socket
            && let Some(pid) = peer.local_peer_pid()
        {
            processes.push(pid);
        }
    }
    // Wait while they are still connected. A frontend that only saw the
    // connection close would reconnect and start the old server again.
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut waiting: Vec<&mut Client> = clients.iter_mut().filter(|c| c.authenticated && c.socket.is_local()).collect();
    while !waiting.is_empty() && Instant::now() < deadline {
        waiting.retain_mut(|client| {
            let _ = client.socket.flush();
            loop {
                match client.socket.read() {
                    Ok(_) => {}
                    Err(tungstenite::Error::Io(error)) if error.kind() == std::io::ErrorKind::WouldBlock => return true,
                    Err(_) => return false,
                }
            }
        });
        std::thread::sleep(Duration::from_millis(5));
    }
    processes
}

/// Adopt the terminals held for the previous owner, as `create` registers new ones.
fn owner_state_adopt(server: &mut Server, adopted: Vec<holder_link::Adopted>, previous: Option<owner_state::OwnerState>) {
    let Some(previous) = previous else {
        adopted.into_iter().for_each(holder_link::Holders::discard);
        return;
    };
    server.next = server.next.max(previous.next);
    server.tab_titles = previous.tab_titles.clone();
    server.workspaces = previous.workspaces.clone();
    server.last_viewed = previous.last_viewed.clone();
    let mut workspaces = HashSet::new();
    for adopted in adopted {
        let id = u64::from(adopted.terminal.id);
        let Some(saved) = previous.sessions.iter().find(|s| s.id == id) else {
            holder_link::Holders::discard(adopted);
            continue;
        };
        let screen = (adopted.previous == "handover").then(|| owner_state::take_screen(&server.descriptor, id)).flatten();
        let session = match Session::adopt(saved, adopted, server.fonts.metrics(saved.font_size), screen) {
            Ok(session) => session,
            Err(error) => {
                eprintln!("[holder] cannot adopt terminal %{id}: {error}");
                continue;
            }
        };
        server.graphs
            .entry(session.workspace.clone())
            .or_insert_with(|| graph::Graph::with_settings(server.settings.nodes.clone()))
            .add(id, session.title());
        if let Some(pid) = session.pid() {
            server.resources.register(id, pid, Duration::from_secs(1), true);
        }
        server.workspaces.insert(session.workspace.clone());
        server.workspace_incarnations.entry(session.workspace.clone()).or_insert(server.workspaces.info(&session.workspace).id.0);
        workspaces.insert(session.workspace.clone());
        server.sessions.insert(id, session);
        server.started_session = true;
    }
    filetree::adopt(server, previous.filetrees);
    for workspace in workspaces {
        if let Err(error) = workspace::sync(server, &workspace) {
            eprintln!("[holder] cannot restore workspace {workspace}: {error}");
        }
    }
    eprintln!("[holder] adopted {} terminal(s) from the previous server", server.sessions.len());
}
