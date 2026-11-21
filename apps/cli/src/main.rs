use graffitty_platform::process_cwd;
use graffitty_graph_protocol::{Client as GraphClient, read_message, MAX_REQUEST, MAX_MESSAGE};
use graffitty_session_transport::local_json as transport;
#[cfg(any(windows, target_os = "linux", test))]
mod gpu_startup;
mod remote;
mod put;
mod navigator;
mod platform;
mod agent_bridge;
mod codex_transport;
mod codex_discovery;
mod integration;
mod integration_setup;
mod opencode;
mod pi;
mod completion;
mod options;
mod icat;
mod sessions;
mod foreground_apps;
#[cfg(any(target_os = "macos", target_os = "linux", target_os = "android"))]
mod process_inventory;
mod live_sessions;
mod installer;
mod update;
use graffitty_workspace_core::checkpoint;
mod parallel;
mod payload_inspector;
mod filter_node;
mod time_trigger;
mod node_config;
mod node_form;
mod prompt_nodes;
mod prompt_editor;
mod text_edit;
mod dev_agent;
mod systemone;
mod system_notification;
mod desktop_notification;
mod power_monitor;
mod chat_integrations;
mod secrets;

use options::{App, GuiApp, NodeCommand, WorkspaceCommand};
use serde_json::{Value, json};
use std::hash::{Hash, Hasher};
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(windows)]
use platform::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command as Process, ExitCode};
use std::time::Duration;

/// `gft skill <name>`: bundled skills for agents without skill discovery.
const SKILLS: [(&str, &str, &str); 2] = [
    ("graph", "Delegate to agents, run programs, wire the graph and place panes.", include_str!("../../../skills/graffitty/SKILL.md")),
    ("chromium", "Drive Chromium panes from the CLI or @graffitty/playwright.", include_str!("../../../skills/terminal-chromium/SKILL.md")),
];

fn error(code: &str, message: impl std::fmt::Display) -> Value {
    json!({"error": {"code": code, "message": message.to_string()}})
}

fn valid_method(method: &str) -> bool {
    let schema: Value = serde_json::from_str(include_str!("mcp-tools.json")).unwrap();
    schema["tools"][0]["inputSchema"]["properties"]["method"]["enum"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v == method)
}


fn call(method: &str, params: Value) -> Value {
    call_timeout(method, params, Duration::from_secs(60))
}

fn call_timeout(method: &str, params: Value, timeout: Duration) -> Value {
    call_context(method, params, timeout, None)
}

fn call_context(method: &str, params: Value, timeout: Duration, explicit: Option<(String, String)>) -> Value {
    if !matches!(method, "session.capture" | "session.attach" | "session.create") && !valid_method(method) {
        return error("invalid_method", "Unknown API method");
    }
    if !params.is_object() {
        return error("invalid_params", "Expected a JSON object");
    }
    // An explicit server address has its own attached-controller capability.
    // Resolve it before pane/thread discovery; never fall back to local input.
    if let Some(target) = params.get("target").and_then(Value::as_str) {
        match graffitty_protocol::controller::split_target(target) {
            Err(message) => return error("invalid_target", message),
            Ok(Some((alias, target))) => {
                let alias = alias.to_owned();
                let target = target.to_owned();
                let mut params = params;
                params["target"] = json!(target);
                return graffitty_transport::controller::state_directory()
                    .and_then(|state| graffitty_transport::controller::call(&state, &alias, method, params))
                    .unwrap_or_else(|e| error("remote_control_error", format!("{e:#}")));
            }
            Ok(None) => {},
        }
    }
    // A shared Codex daemon can lack pane variables or retain a different
    // client's variables. Exact thread discovery takes precedence over those.
    let explicit = if explicit.is_none() && method != "session.capture" {
        if let Some(thread_id) = std::env::var("CODEX_THREAD_ID").ok().filter(|s| !s.is_empty()) {
            match sessions::discover_agent_context(&thread_id) {
                Ok(context) => Some(context),
                Err(e) => return error("missing_context", e.to_string()),
            }
        } else { explicit }
    } else { explicit };
    // Inside tmux the inherited pane variables may name another pane; claim
    // the pane that displays this process instead (OSC 4723).
    let explicit = if explicit.is_none() && method != "session.capture" {
        match graffitty_graph_protocol::tmux_context() {
            Ok(context) => context,
            Err(e) => return error("missing_context", e.to_string()),
        }
    } else { explicit };
    let context = explicit.or_else(|| std::env::var("GRAFFITTY_SOCKET")
        .ok()
        .zip(std::env::var("GRAFFITTY_TOKEN").ok()));
    let context = if context.is_none() && method == "session.capture" {
        match sessions::discover_context() {
            Ok(value) => Some(value),
            Err(e) => return error("missing_context", e),
        }
    } else {
        context
    };
    let Some((endpoint, token)) = context.filter(|(a, b)| !a.is_empty() && !b.is_empty()) else {
        return error(
            "missing_context",
            "Run inside an Graffitty workspace (GRAFFITTY_SOCKET/TOKEN required)",
        );
    };
    GraphClient::new(endpoint, token).with_timeout(timeout).exchange(method, params)
        .unwrap_or_else(|e| error("transport_error", e))
}

// Node UIs share the graph SDK while preserving the CLI's exact-thread context resolver.
fn node_rpc(method: &str, params: Value) -> agent_bridge::Result<Value> {
    graffitty_graph_protocol::response(method, call_timeout(method, params, Duration::from_secs(5)))
}
type NodeSession = graffitty_graph_protocol::Session<fn(&str, Value) -> agent_bridge::Result<Value>>;
/// Built-in nodes opt in to checkpoint recovery as `gft` with their own
/// arguments, which never hold credentials.
///
/// Only a non-secret settings file travels in the environment; secrets
/// resolve again from their host credential source or a prompt.
fn node_session(resume_inbox: bool) -> agent_bridge::Result<NodeSession> {
    let mut command: Vec<String> = std::env::args_os().map(|arg| arg.to_string_lossy().into_owned()).collect();
    command[0] = "gft".into();
    let mut restore = graffitty_graph_protocol::Restore {
        command,
        cwd: std::env::current_dir().ok().map(|dir| dir.to_string_lossy().into_owned()),
        ..Default::default()
    };
    for name in ["GRAFFITTY_NODE_CONFIG", "GRAFFITTY_SECRETS_CONFIG"] {
        if let Ok(config) = std::env::var(name) { restore.env.insert(name.into(), config); }
    }
    graffitty_graph_protocol::Session::start_restorable(node_rpc as fn(&str, Value) -> _, None, resume_inbox, &restore)
}

fn mcp_reply(message: Value) -> Option<Value> {
    if !message.is_object() || message["jsonrpc"] != "2.0" || !message["method"].is_string() {
        return Some(
            json!({"jsonrpc":"2.0", "id":null, "error":{"code":-32600,"message":"Invalid Request"}}),
        );
    }
    let id = message.get("id")?;
    let params = &message["params"];
    let result = match message["method"].as_str().unwrap() {
        "initialize" => {
            let requested = params["protocolVersion"].as_str().unwrap_or("");
            let version = if ["2024-11-05", "2025-03-26", "2025-06-18"].contains(&requested) {
                requested
            } else {
                "2025-06-18"
            };
            json!({"protocolVersion":version,"capabilities":{"tools":{}},"serverInfo":{"name":"graffitty","version":env!("GRAFFITTY_VERSION")}})
        }
        "ping" => json!({}),
        "tools/list" => serde_json::from_str(include_str!("mcp-tools.json")).unwrap(),
        "tools/call" if params["name"] == "workspace_chromium" => {
            let args = &params["arguments"];
            let value = call(
                args["method"].as_str().unwrap_or(""),
                args.get("params").cloned().unwrap_or(json!({})),
            );
            json!({"content":[{"type":"text","text":value.to_string()}],"isError":value.get("error").is_some()})
        }
        _ => {
            return Some(
                json!({"jsonrpc":"2.0","id":id,"error":{"code":-32601,"message":"Method not found"}}),
            );
        }
    };
    Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
}

fn mcp() -> io::Result<()> {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    while let Some(bytes) = read_message(&mut input)? {
        let reply = match serde_json::from_slice::<Value>(&bytes) {
            Ok(value) => mcp_reply(value),
            Err(_) => Some(
                json!({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}),
            ),
        };
        if let Some(reply) = reply {
            writeln!(output, "{reply}")?;
            output.flush()?;
        }
    }
    Ok(())
}

fn log_path() -> io::Result<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| {
            std::env::var_os("HOME")
                .or_else(|| std::env::var_os("USERPROFILE"))
                .map(|home| PathBuf::from(home).join(".local/state"))
        })
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Cannot locate home for logs"))?;
    let directory = base.join("graffitty");
    std::fs::create_dir_all(&directory)?;
    let path = directory.join("graffitty.log");
    if path.is_file() {
        std::fs::copy(&path, directory.join("graffitty.log.1"))?;
    }
    Ok(path)
}

fn startup_pack(pack: PathBuf) -> io::Result<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| home.as_ref().map(|p| p.join(".config")));
    let Some(config) = config else {
        return Ok(pack);
    };
    let settings = config.join("graffitty/override.cfg");
    if !settings.is_file() {
        return Ok(pack);
    }
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| home.map(|p| p.join(".cache")))
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Cannot locate startup cache"))?;
    let pack = pack.canonicalize()?;
    let mut hash = std::collections::hash_map::DefaultHasher::new();
    pack.hash(&mut hash);
    settings.hash(&mut hash);
    let directory = cache
        .join("graffitty/startup")
        .join(format!("{:016x}", hash.finish()));
    std::fs::create_dir_all(&directory)?;
    for (name, target) in [("terminal.pck", &pack), ("override.cfg", &settings)] {
        let link = directory.join(name);
        if std::fs::read_link(&link).ok().as_ref() == Some(target) {
            continue;
        }
        // Never replace an unrelated regular file in the cache.
        if link.symlink_metadata().is_ok() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("Unexpected startup cache entry: {}", link.display()),
            ));
        }
        match platform::symlink_file(target, &link) {
            Ok(()) => (),
            Err(error)
                if error.kind() == io::ErrorKind::AlreadyExists
                    && std::fs::read_link(&link).ok().as_ref() == Some(target) =>
            {
                ()
            }
            Err(error) => return Err(error),
        }
    }
    Ok(directory.join("terminal.pck"))
}

fn launch(mut args: Vec<String>, cwd: Option<String>) -> io::Error {
    if let Some(cwd) = cwd {
        let path = match std::fs::canonicalize(&cwd) {
            Ok(path) if path.is_dir() => path,
            _ => {
                return io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("--cwd is not a directory: {cwd}"),
                );
            }
        };
        args.push(format!("--cwd={}", path.display()));
    }
    // Find the bundle from the executable's path. Development builds
    // live in `dist/bin/` and packaged builds in `tools/`.
    //
    // Follow symlinks such as `~/.local/bin/gft` into the installed bundle.
    // Keep the launch path when the executable is a regular file.
    let exe = match std::env::current_exe().and_then(|exe| {
        let linked = std::fs::symlink_metadata(&exe).map(|m| m.file_type().is_symlink()).unwrap_or(false);
        if linked { std::fs::canonicalize(&exe) } else { Ok(exe) }
    }) {
        Ok(p) => p,
        Err(e) => return e,
    };
    let parent = exe.parent().unwrap();
    let bundled = parent.file_name().is_some_and(|name| name == "MacOS")
        && parent.join("GraffittyRuntime").is_file();
    let root = if bundled {
        parent.parent().unwrap().join("Resources/graffitty")
    } else if parent.ends_with("dist/bin") {
        parent.parent().unwrap().parent().unwrap().to_path_buf()
    } else {
        parent.parent().unwrap().to_path_buf()
    };
    // Packaged shortcuts and CLI launches use the same supervised entry point.
    #[cfg(any(windows, target_os = "linux"))]
    {
        let entry = root.join(if cfg!(windows) { "Graffitty.exe" } else { "gft-gui" });
        if entry.is_file() {
            return Process::new(entry)
                .env("GRAFFITTY_INITIAL_PWD", std::env::current_dir().unwrap_or_else(|_| root.clone()))
                .arg("--").args(args).exec();
        }
    }
    // Development installs are real binaries in ~/.local/bin. Keep their
    // source checkout discoverable without changing the caller's PATH.
    let root = if !root.join("frontends/godot/project/project.godot").is_file()
        && !root.join("project.godot").is_file()
        && !root.join("terminal.pck").is_file()
        && !bundled
    {
        let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().parent().unwrap();
        if checkout.join("frontends/godot/project/project.godot").is_file() && checkout.join("mise.toml").is_file() {
            checkout.to_path_buf()
        } else { root }
    } else { root };
    let project = if root.join("frontends/godot/project/project.godot").is_file() {
        root.join("frontends/godot/project")
    } else { root.clone() };
    #[cfg(windows)]
    if project.join("project.godot").is_file() {
        let godot = std::env::var_os("GRAFFITTY_GODOT").unwrap_or_else(|| "godot.exe".into());
        return Process::new(godot).arg("--path").arg(&project).arg("res://scenes/terminal.tscn").arg("--").args(args).exec();
    }
    if project.join("project.godot").is_file() && root.join("mise.toml").is_file() {
        let mut dev = Process::new("mise");
        #[cfg(target_os = "linux")]
        graffitty_platform::process_env::sanitize_gui_loader(&mut dev);
        return dev
            .env("GRAFFITTY_INITIAL_PWD", std::env::current_dir().unwrap_or_else(|_| root.clone()))
            .arg("--cd").arg(&root).args(["run", "dev", "--"]).args(args).exec();
    }
    let pack = root.join("terminal.pck");
    if !pack.is_file() {
        return io::Error::new(
            io::ErrorKind::NotFound,
            "Cannot find a source checkout or terminal.pck; run mise run dev to install the development launcher",
        );
    }
    let godot = std::env::var_os("GRAFFITTY_GODOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            if bundled {
                parent.join("GraffittyRuntime")
            } else if root.join("../../MacOS/GraffittyRuntime").is_file() {
                root.join("../../MacOS/GraffittyRuntime")
            } else if cfg!(target_os = "macos") {
                PathBuf::from("/Applications/Godot.app/Contents/MacOS/Godot")
            } else {
                PathBuf::from("godot")
            }
        });
    let log = match log_path() {
        Ok(path) => path,
        Err(error) => return error,
    };
    let packaged_runtime = bundled || root.join("../../MacOS/GraffittyRuntime").is_file();
    let pack = match if packaged_runtime { Ok(pack) } else { startup_pack(pack) } {
        Ok(path) => path,
        Err(error) => return error,
    };
    let mut command = Process::new(godot);
    #[cfg(target_os = "linux")]
    graffitty_platform::process_env::sanitize_gui_loader(&mut command);
    let mut initial_directory = std::env::current_dir().unwrap_or_else(|_| root.clone());
    #[cfg(target_os = "macos")]
    if packaged_runtime {
        // LaunchServices starts Finder/Dock apps at / with a system-only PATH.
        // Keep a CLI caller's directory and PATH priority; explicit --cwd is
        // still passed to the frontend and takes precedence over this default.
        if bundled && initial_directory == Path::new("/") {
            if let Some(home) = std::env::var_os("HOME").map(PathBuf::from).filter(|p| p.is_dir()) {
                initial_directory = home;
            }
        }
        let mut paths: Vec<_> = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect();
        let home_bin = std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/bin"));
        for path in home_bin.into_iter().chain([PathBuf::from("/opt/homebrew/bin"), PathBuf::from("/usr/local/bin")]) {
            if !paths.contains(&path) { paths.push(path); }
        }
        if let Ok(path) = std::env::join_paths(paths) { command.env("PATH", path); }
    }
    command.env("GRAFFITTY_INITIAL_PWD", initial_directory).current_dir(&root);
    if !packaged_runtime {
        command.arg("--path").arg(&root);
    }
    command.arg("--log-file").arg(log);
    if !packaged_runtime {
        command.arg("--main-pack").arg(pack);
    }
    command
        .arg("--")
        .args(args)
        .exec()
}

fn installer_exit(command: &str, result: Result<(), Box<dyn std::error::Error>>) -> ExitCode {
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{command}: {error}");
            ExitCode::FAILURE
        }
    }
}

fn main() -> ExitCode {
    let argv: Vec<_> = std::env::args_os().collect();
    #[cfg(any(windows, target_os = "linux"))]
    if argv.get(1).is_some_and(|arg| arg == "internal") && argv.get(2).is_some_and(|arg| arg == "gpu-start") {
        let result = std::env::current_exe().and_then(|exe| {
            let root = exe.parent().and_then(Path::parent).ok_or_else(|| io::Error::other("Missing bundle directory"))?;
            gpu_startup::launch(root, &argv[3..])
        });
        match result {
            Ok(status) => std::process::exit(status.code().unwrap_or(1)),
            Err(error) => { eprintln!("GPU startup: {error}"); return ExitCode::FAILURE; }
        }
    }
    if argv.get(1).is_some_and(|arg| arg == "--power-state" || arg == "--power-monitor") {
        return integration::exit(power_monitor::run(argv[1] == "--power-monitor"));
    }
    if argv.get(1).is_some_and(|arg| arg == "--desktop-notification") {
        return integration::exit(desktop_notification::run());
    }
    if argv.get(1).is_some_and(|arg| arg == "--desktop-bell") {
        return integration::exit(desktop_notification::bell());
    }
    let name = std::path::Path::new(&argv[0]).file_stem().and_then(|s| s.to_str()).unwrap_or("");
    if matches!(name, "gft-gui" | "Graffitty") {
        let mut app = GuiApp::parse();
        if app.new_session { app.args.push("--new-session".into()); }
        eprintln!("gft-gui: {}", launch(app.args, app.cwd));
        return ExitCode::FAILURE;
    }
    if argv.len() == 1 {
        let mut command = Process::new(std::env::current_exe().unwrap());
        command.arg("--help");
        eprintln!("gft: {}", command.exec());
        return ExitCode::FAILURE;
    }
    let app = App::parse();
    match app.command.into_workspace() {
        WorkspaceCommand::Put(args) => integration::exit(put::run(args)),
        WorkspaceCommand::SelectPane(args) => {
            let response = navigator::select_pane(args);
            println!("{response}");
            if response.get("error").is_some() { ExitCode::FAILURE } else { ExitCode::SUCCESS }
        },
        WorkspaceCommand::Gui(mut app) => {
            // `gft-gui --version` reaches here on Windows, where gft-gui is a script.
            if app.args.first().is_some_and(|arg| arg == "--version" || arg == "-V") {
                println!("gft-gui {}", env!("GRAFFITTY_VERSION"));
                return ExitCode::SUCCESS;
            }
            if app.new_session { app.args.push("--new-session".into()); }
            eprintln!("gft gui: {}", launch(app.args, app.cwd));
            ExitCode::FAILURE
        },
        WorkspaceCommand::Server(options) => match graffitty_server::run(options) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("gft server: {error}");
                ExitCode::FAILURE
            }
        },
        WorkspaceCommand::Icat(args) => match icat::run(args) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("gft terminal icat: {error}");
                ExitCode::FAILURE
            }
        },
        WorkspaceCommand::ListSessions(args) => integration::exit(live_sessions::list(args.json)),
        WorkspaceCommand::NewSession(args) => integration::exit(live_sessions::new(args)),
        WorkspaceCommand::AttachSession(args) => integration::exit(live_sessions::attach(&args.target)),
        WorkspaceCommand::KillSession(args) => integration::exit(live_sessions::target("session.kill", &args.target)),
        WorkspaceCommand::RestartServer => integration::exit(live_sessions::restart_server(false)),
        WorkspaceCommand::HasSession(args) => integration::exit(live_sessions::target("session.has", &args.target)),
        WorkspaceCommand::RenameSession(args) => integration::exit(live_sessions::rename(&args.target, &args.new_name)),
        WorkspaceCommand::Remote(args) => match remote::run(args.command) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {eprintln!("gft remote: {error}"); ExitCode::FAILURE}
        },
        WorkspaceCommand::Integrate(args) => match args.command {
            options::IntegrationCommand::Agent(args) => integration::exit(integration_setup::install(args)),
            options::IntegrationCommand::Completion(args) => match completion::run(args.command) {
                Ok(()) => ExitCode::SUCCESS,
                Err(error) => {
                    eprintln!("gft integrate completion: {error}");
                    ExitCode::FAILURE
                }
            },
        },
        WorkspaceCommand::Internal(args) => match args.command {
            options::InternalCommand::AgentHookIntegrate(args) => integration::exit(integration::event(args)),
            options::InternalCommand::AgentWorker(args) => match agent_bridge::worker(&args.request) {
                Ok(value) => { println!("{value}"); ExitCode::SUCCESS }
                Err(e) => { println!("{}", error("agent_error", e)); ExitCode::FAILURE }
            },
            options::InternalCommand::Update(args) => integration::exit(match args.command {
                options::UpdateCommand::Prepare => update::prepare(),
                options::UpdateCommand::Finish => update::finish(),
            }),
            options::InternalCommand::Holder(args) => match graffitty_server::holder::run(args.socket) {
                Ok(()) => ExitCode::SUCCESS,
                Err(e) => { eprintln!("holder: {e}"); ExitCode::FAILURE }
            },
        },
        WorkspaceCommand::Dev(args) => match args.command {
            options::DevCommand::CodexMock(args) => integration::exit(dev_agent::run(dev_agent::Provider::Codex, args)),
            options::DevCommand::ClaudeMock(args) => integration::exit(dev_agent::run(dev_agent::Provider::Claude, args)),
            options::DevCommand::SystemoneMock(args) => integration::exit(systemone::run_mock(args)),
            options::DevCommand::SlackSendDemo(args) => integration::exit(chat_integrations::run_slack_demo(args)),
        },
        WorkspaceCommand::Node(args) => match args.command {
            NodeCommand::ManualPrompt(args) => integration::exit(prompt_nodes::manual(args)),
            NodeCommand::ReadSessionFile(args) => integration::exit(prompt_nodes::reader(args)),
            NodeCommand::TelegramSend(args) => integration::exit(chat_integrations::run(chat_integrations::Service::Telegram, args)),
            NodeCommand::DiscordSend(args) => integration::exit(chat_integrations::run(chat_integrations::Service::Discord, args)),
            NodeCommand::SlackSend(args) => integration::exit(chat_integrations::run(chat_integrations::Service::Slack, args)),
            NodeCommand::Filter(args) => integration::exit(filter_node::run(args)),
            NodeCommand::ScheduledTrigger(args) => integration::exit(time_trigger::run(args)),
            NodeCommand::SystemNotification(args) => integration::exit(system_notification::run(args)),
            NodeCommand::Systemone(args) => integration::exit(systemone::run(args)),
            NodeCommand::PayloadInspector(args) => integration::exit(payload_inspector::run(args)),
            NodeCommand::Parallel(args) => integration::exit(parallel::run(args)),
        },
        WorkspaceCommand::Checkpoint(args) => match sessions::run(args.command) {
            Ok(value) => {
                println!("{value}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("gft checkpoint: {e}");
                ExitCode::FAILURE
            }
        },
        WorkspaceCommand::Skill(skill) => match skill.name.as_deref() {
            None => {
                for (name, summary, _) in SKILLS {
                    println!("{name:<10}{summary}");
                }
                println!("\nPrint one with `gft skill <name>`.");
                ExitCode::SUCCESS
            }
            Some(name) => match SKILLS.iter().find(|(skill, ..)| *skill == name) {
                Some((.., text)) => {
                    print!("{text}");
                    ExitCode::SUCCESS
                }
                None => {
                    eprintln!("gft skill: unknown skill {name:?}; run `gft skill` to list them");
                    ExitCode::FAILURE
                }
            },
        },
        WorkspaceCommand::SelfManage(args) => match args.command {
            options::SelfCommand::Update(args) => installer_exit("gft self update", installer::self_update(args.version.as_deref())),
        },
        WorkspaceCommand::World(args) => match args.command {
            options::WorldCommand::Install(args) => {
                installer_exit("gft world install", installer::world_install(&args.id, args.version.as_deref()))
            }
        },
        WorkspaceCommand::Mcp => match mcp() {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("gft mcp: {e}");
                ExitCode::FAILURE
            }
        },
        // `--osc` writes the sequence for the terminal this process runs in; no server call.
        WorkspaceCommand::Effects(ref effects) if matches!(effects.osc_sequence(), Ok(Some(_))) => {
            use std::io::Write;
            let sequence = effects.osc_sequence().unwrap().unwrap();
            let mut out = std::io::stdout().lock();
            if out.write_all(&sequence).and_then(|()| out.flush()).is_err() {
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        command => {
            let plain_text = command.plain_text();
            let placement = command.placement_after_create();
            // request() validates placement too, so nothing is created on bad input.
            let mut value = match command.request() {
                Ok((method, params)) => call(&method, params),
                Err(e) => error("invalid_params", e),
            };
            if let Some((method, params)) = placement.and_then(Result::ok).and_then(|p| options::place_created(&p, &value)) {
                let placed = call(&method, params);
                if let Some(error) = placed.get("error") {
                    // Keep the created handle so the caller can still use or close it.
                    value["error"] = error.clone();
                } else if let (Some(result), Some(rect)) = (value.get_mut("result"), placed.pointer("/result/rect")) {
                    result["rect"] = rect.clone();
                }
            }
            if plain_text {
                if let Some(text) = value.pointer("/result/text").and_then(Value::as_str) {
                    print!("{text}");
                } else {
                    eprintln!("{value}");
                    return ExitCode::FAILURE;
                }
            } else {
                println!("{value}");
            }
            if value.get("error").is_some() {
                ExitCode::FAILURE
            } else {
                ExitCode::SUCCESS
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chromium_title_request_reaches_transport_validation() {
        let response = call_context("chromium.set_title", json!({"chromium":"%7","title":"Pinned"}), Duration::from_millis(10), Some(("/nonexistent/graffitty/api.sock".into(),"token".into())));
        assert_ne!(response["error"]["code"], "invalid_method");
        assert!(response.get("error").is_some());
    }
    #[test]
    fn oversized_request_explains_the_socket_limit_before_connecting() {
        let value = call_context(
            "graph.send",
            json!({"to": "%2", "text": "x".repeat(MAX_REQUEST)}),
            Duration::from_secs(1),
            Some(("/nonexistent/graffitty/api.sock".into(), "token".into())),
        );
        let message = value["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains(&format!("accepts at most {MAX_REQUEST}")), "{message}");
    }
}

#[cfg(unix)]
fn grow_send_buffer(stream: &std::os::unix::net::UnixStream, bytes: usize) {
    use std::os::fd::AsRawFd;
    let size = bytes.min(i32::MAX as usize) as libc::c_int;
    unsafe { libc::setsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_SNDBUF, (&size as *const libc::c_int).cast(), std::mem::size_of_val(&size) as libc::socklen_t); }
}
