use serde_json::{Value, json};
use usage_rs::{Args, Cli, Subcommands};

/// Control Graffitty workspaces from the terminal. Launch the app with gft-gui.
#[derive(Cli)]
#[usage(bin = "gft", version = env!("GRAFFITTY_VERSION"), completion)]
pub struct App {
    #[usage(subcommand)]
    pub command: Command,
}

/// The command line: a thing, then what to do with it. Each command is one
/// `WorkspaceCommand`, which the rest of the program handles.
#[derive(Subcommands)]
pub enum Command {
    /// Launch the Graffitty GUI. Pass app options after --.
    Gui(Gui),
    /// List, create, attach, rename and end sessions.
    Session(SessionGroup),
    /// List and name this window's tabs.
    Tab(TabGroup),
    /// List, select, name, arrange and start panes.
    Pane(PaneGroup),
    /// Read a terminal's text, type into it, and send it files and images.
    Terminal(TerminalGroup),
    /// Control the opt-in terminal space with AeroSpace-style commands.
    Tiling(Tiling),
    /// Control Chromium panes owned by this workspace.
    Chromium(Chromium),
    /// Toggle the connected filetree; --focus enters it when opening.
    Filetree(Filetree),
    /// Inspect and edit terminal connections, and send messages along them.
    Graph(Graph),
    /// Run a graph node with socket delivery and a terminal display.
    Node(Node),
    /// Hold named presentation effects off while this pane is focused, or release holds.
    Effects(Effects),
    /// Save and restore checkpoints of all windows, tabs, panes, browsers, and agent conversations.
    Checkpoint(Checkpoint),
    /// Run the headless session server, or restart the running one.
    Server(Server),
    /// Plant a headless session server over SSH and open native remote views.
    Remote(Remote),
    /// Set up what Graffitty adds to other programs: agent hooks and shell completions.
    Integrate(Integration),
    /// Serve MCP over stdio using the current workspace capability.
    Mcp,
    /// Print a bundled agent skill; omit the name to list them.
    Skill(Skill),
    /// Identify the workspace capability inherited from the terminal.
    Identify,
    /// Call a versioned workspace API method with JSON parameters.
    Rpc(Rpc),
    /// Update Graffitty itself.
    #[usage(name = "self")]
    SelfManage(SelfManage),
    /// Install downloadable worlds.
    World(World),
    /// Deterministic development tools for recording and testing.
    #[usage(help_heading = "Internal")]
    Dev(Dev),
    /// Runtime helpers used by integrations and the session server.
    #[usage(help_heading = "Internal")]
    Internal(Internal),
}

#[derive(Args)]
pub struct SessionGroup {
    #[usage(subcommand)]
    command: SessionCommand,
}
#[derive(Subcommands)]
pub enum SessionCommand {
    /// List live server sessions (not saved checkpoints).
    List(ListSessions),
    /// Create a fresh session; -d leaves it detached, -s names it.
    New(NewSession),
    /// Switch this client to an existing session, or open a GUI outside Graffitty.
    Attach(SessionTarget),
    /// Kill a session and all its panes and chromium workers.
    Kill(SessionTarget),
    /// Exit successfully if the target session exists.
    Has(SessionTarget),
    /// Rename a session without changing its stable ID; empty name restores automatic naming.
    Rename(RenameSession),
}

#[derive(Args)]
pub struct TabGroup {
    #[usage(subcommand)]
    command: TabCommand,
}
#[derive(Subcommands)]
pub enum TabCommand {
    /// List this window's tabs: position, id, title, windows and shell pid.
    List,
    /// Name this tab, or another with --tab or --tab-id. No title returns it to
    /// its first pane's title.
    Rename(RenameTab),
}

#[derive(Args)]
pub struct PaneGroup {
    #[usage(subcommand)]
    command: PaneCommand,
}
#[derive(Subcommands)]
pub enum PaneCommand {
    /// List this window's panes with stable % IDs and positional targets.
    List(ListPanes),
    /// List the surfaces this caller owns: its terminals and Chromium panes.
    Surfaces,
    /// Select a pane by direction (-L/-D/-U/-R) or target (-t).
    Select(crate::navigator::SelectPane),
    /// Name this terminal pane. No title returns it to the one programs set.
    Rename(RenamePane),
    /// Arrange a pane of this tab: beside another pane, or at a position and size.
    Place(Place),
    /// Run a program or agent in a new pane of this tab; it records this terminal as its parent.
    Run(Run),
    /// Map terminal panes to root shell PIDs; optionally include sampled processes.
    Pid(Pid),
}

#[derive(Args)]
pub struct TerminalGroup {
    #[usage(subcommand)]
    command: TerminalGroupCommand,
}
#[derive(Subcommands)]
pub enum TerminalGroupCommand {
    /// Read a terminal's visible text (plain text by default).
    GetText(GetText),
    /// Type text into a terminal, one key at a time.
    Type(TypeText),
    /// Send one key: Enter, Backspace, ArrowLeft, Ctrl+c, etc.
    SendKey(SendKey),
    /// Upload a file to a terminal's machine; print its destination path.
    Put(crate::put::Options),
    /// Display images using the Kitty graphics protocol (kitten icat compatible).
    Icat(crate::icat::Options),
}

impl Command {
    pub fn into_workspace(self) -> WorkspaceCommand {
        use WorkspaceCommand as W;
        match self {
            Self::Gui(a) => W::Gui(a),
            Self::Session(group) => match group.command {
                SessionCommand::List(a) => W::ListSessions(a),
                SessionCommand::New(a) => W::NewSession(a),
                SessionCommand::Attach(a) => W::AttachSession(a),
                SessionCommand::Kill(a) => W::KillSession(a),
                SessionCommand::Has(a) => W::HasSession(a),
                SessionCommand::Rename(a) => W::RenameSession(a),
            },
            Self::Tab(group) => match group.command {
                TabCommand::List => W::ListTabs,
                TabCommand::Rename(a) => W::RenameTab(a),
            },
            Self::Pane(group) => match group.command {
                PaneCommand::List(a) => W::ListPanes(a),
                PaneCommand::Surfaces => W::Panes,
                PaneCommand::Select(a) => W::SelectPane(a),
                PaneCommand::Rename(a) => W::RenamePane(a),
                PaneCommand::Place(a) => W::Place(a),
                PaneCommand::Run(a) => W::Run(a),
                PaneCommand::Pid(a) => W::Pid(a),
            },
            Self::Terminal(group) => match group.command {
                TerminalGroupCommand::GetText(a) => W::GetText(a),
                TerminalGroupCommand::Type(a) => W::Terminal(Terminal { command: TerminalCommand::Type(a) }),
                TerminalGroupCommand::SendKey(a) => W::Terminal(Terminal { command: TerminalCommand::SendKey(a) }),
                TerminalGroupCommand::Put(a) => W::Put(a),
                TerminalGroupCommand::Icat(a) => W::Icat(a),
            },
            Self::Tiling(a) => W::Tiling(a),
            Self::Chromium(Chromium { command: ChromiumCommand::Layout(a) }) => W::Layout(a),
            Self::Chromium(a) => W::Chromium(a),
            Self::Filetree(a) => W::Filetree(a),
            Self::Graph(Graph { command: GraphCommand::Send(a) }) => W::Send(a),
            Self::Graph(a) => W::Graph(a),
            Self::Node(a) => W::Node(a),
            Self::Effects(a) => W::Effects(a),
            Self::Checkpoint(a) => W::Checkpoint(a),
            Self::Server(Server { command: Some(ServerCommand::Restart), .. }) => W::RestartServer,
            Self::Server(a) => W::Server(a.options),
            Self::Remote(a) => W::Remote(a),
            Self::Integrate(a) => W::Integrate(a),
            Self::Mcp => W::Mcp,
            Self::Skill(a) => W::Skill(a),
            Self::Identify => W::Identify,
            Self::Rpc(a) => W::Rpc(a),
            Self::SelfManage(a) => W::SelfManage(a),
            Self::World(a) => W::World(a),
            Self::Dev(a) => W::Dev(a),
            Self::Internal(a) => W::Internal(a),
        }
    }
}

/// Launch the Graffitty GUI. Pass app options after --.
#[derive(Cli)]
#[usage(bin = "gft-gui", version = env!("GRAFFITTY_VERSION"))]
pub struct GuiApp {
    /// Starting directory for the first terminal (overrides configuration).
    #[usage(long)]
    pub cwd: Option<String>,
    /// Open a new session instead of the one this computer showed last.
    #[usage(long)]
    pub new_session: bool,
    pub args: Vec<String>,
}
/// `gft gui`: the same launcher as the `gft-gui` command, which is this
/// program under that name (a link on macOS and Linux, a script on Windows).
#[derive(Args)]
pub struct Gui {
    /// Starting directory for the first terminal (overrides configuration).
    #[usage(long)]
    pub cwd: Option<String>,
    /// Open a new session instead of the one this computer showed last.
    #[usage(long)]
    pub new_session: bool,
    pub args: Vec<String>,
}
#[derive(Args)]
pub struct Node {
    #[usage(subcommand)]
    pub command: NodeCommand,
}
#[derive(Subcommands)]
pub enum NodeCommand {
    /// Configure OSC 99 system notifications with timestamped send logs.
    SystemNotification(SystemNotification),
    /// Compose multiline prompts and send them through one graph output.
    ManualPrompt(ManualPrompt),
    /// Emit once at a time, or repeat every interval from a start until a deadline.
    ScheduledTrigger(TimeTrigger),
    /// Expand the last N messages from a Codex or Claude session file.
    ReadSessionFile(ReadSessionFile),
    /// Send graph messages and media to Telegram.
    TelegramSend(Messaging),
    /// Send graph messages, Block Kit layouts, and files to Slack.
    SlackSend(Messaging),
    /// Send graph messages, embeds, and files to Discord.
    DiscordSend(Messaging),
    /// Route events using jq, optionally replacing their text or payload.
    Filter(Filter),
    /// Inspect complete incoming graph events as JSON without consuming other branches.
    PayloadInspector(PayloadInspector),
    /// Wait for every upstream branch and forward their combined messages and sessions.
    Parallel(Parallel),
    /// Route graph events using SystemOne decisions (noul, choice, or score).
    Systemone(Systemone),
}
/// One command, whatever group it is typed under. `Command` parses the command
/// line into this.
pub enum WorkspaceCommand {
    /// Select a Graffitty pane by direction (-L/-D/-U/-R) or target (-t).
    SelectPane(crate::navigator::SelectPane),
    /// Launch the Graffitty GUI. Pass app options after --.
    Gui(Gui),
    /// Run the headless session server.
    Server(graffitty_server::Options),
    /// Restart the local session server; its terminals keep running.
    RestartServer,
    /// Display images using the Kitty graphics protocol (kitten icat compatible).
    Icat(crate::icat::Options),
    /// List live server sessions (not saved checkpoints).
    ListSessions(ListSessions),
    /// Create a fresh session; -d leaves it detached, -s names it.
    NewSession(NewSession),
    /// Switch this client to an existing session, or open a GUI outside Graffitty.
    AttachSession(SessionTarget),
    /// Kill a session and all its panes and chromium workers.
    KillSession(SessionTarget),
    /// Exit successfully if the target session exists.
    HasSession(SessionTarget),
    /// Rename a session without changing its stable ID; empty name restores automatic naming.
    RenameSession(RenameSession),
    /// Plant a headless session server over SSH and open native remote views.
    Remote(Remote),
    /// Identify the workspace capability inherited from the terminal.
    Identify,
    /// Read the calling terminal's visible text (plain text by default).
    GetText(GetText),
    /// Set up what Graffitty adds to other programs: agent hooks and shell completions.
    Integrate(Integration),
    /// Inspect and edit terminal connections.
    Graph(Graph),
    /// Send a message along an allowed graph connection.
    Send(Send),
    /// Run a graph node with socket delivery and a terminal display.
    Node(Node),
    /// Control the opt-in terminal space with AeroSpace-style commands.
    Tiling(Tiling),
    /// Save and restore checkpoints of all windows, tabs, panes, browsers, and agent conversations.
    Checkpoint(Checkpoint),
    /// List workspace panes.
    Panes,
    /// List this window's panes with stable % IDs and positional targets.
    ListPanes(ListPanes),
    /// Map terminal panes to root shell PIDs; optionally include sampled processes.
    Pid(Pid),
    /// Change the terminal/chromium split.
    Layout(Layout),
    /// Call a versioned workspace API method with JSON parameters.
    Rpc(Rpc),
    /// Read terminal text or send virtual keyboard input in this workspace.
    Terminal(Terminal),
    /// Upload a file to a terminal's machine; print its destination path.
    Put(crate::put::Options),
    /// Hold named presentation effects off while this pane is focused, or release holds.
    Effects(Effects),
    /// Toggle the connected filetree; --focus enters it when opening.
    Filetree(Filetree),
    /// List this window's tabs: position, id, title, windows and shell pid.
    ListTabs,
    /// Name this tab, or another with --tab or --tab-id. No title returns it to
    /// its first pane's title.
    RenameTab(RenameTab),
    /// Name this terminal pane. No title returns it to the one programs set.
    RenamePane(RenamePane),
    /// Control Chromium panes owned by this workspace.
    Chromium(Chromium),
    /// Print a bundled agent skill; omit the name to list them.
    Skill(Skill),
    /// Run a program or agent in a new pane of this tab; it records this terminal as its parent.
    Run(Run),
    /// Arrange a pane of this tab: beside another pane, or at a position and size.
    Place(Place),
    /// Serve MCP over stdio using the current workspace capability.
    Mcp,
    /// Update Graffitty itself.
    SelfManage(SelfManage),
    /// Install downloadable worlds.
    World(World),
    /// Deterministic development tools for recording and testing.
    Dev(Dev),
    /// Runtime helpers used by integrations and the session server.
    Internal(Internal),
}

#[derive(Args)]
pub struct SelfManage {
    #[usage(subcommand)]
    pub command: SelfCommand,
}
#[derive(Subcommands)]
pub enum SelfCommand {
    /// Install the latest release (or --version) in place of this one.
    /// Terminals keep running; open windows reopen on the new version.
    Update(SelfUpdate),
}
#[derive(Args)]
pub struct SelfUpdate {
    /// Release tag to install, such as v0.2.0 (default: the latest release).
    #[usage(long)]
    pub version: Option<String>,
}

#[derive(Args)]
pub struct World {
    #[usage(subcommand)]
    pub command: WorldCommand,
}
#[derive(Subcommands)]
pub enum WorldCommand {
    /// Download a world into the worlds folder, replacing an installed copy.
    /// Restart Graffitty afterwards to see it under View > World.
    Install(WorldInstall),
}
#[derive(Args)]
pub struct WorldInstall {
    /// World to install.
    #[usage(choices("bistro"))]
    pub id: String,
    /// Release tag to install, such as v0.0.1 (default: the latest release).
    #[usage(long)]
    pub version: Option<String>,
}

#[derive(Args)]
pub struct Update {
    #[usage(subcommand)]
    pub command: UpdateCommand,
}
#[derive(Subcommands)]
pub enum UpdateCommand {
    /// Run before replacing files that a running Graffitty locks (Windows).
    /// Saves a checkpoint, closes the windows, and leaves the terminals running.
    Prepare,
    /// Run after replacing the files. Starts the new server, which takes over
    /// the running terminals, and reopens the windows.
    Finish,
}

#[derive(Args)]
pub struct Internal {
    #[usage(subcommand)]
    pub command: InternalCommand,
}
#[derive(Subcommands)]
pub enum InternalCommand {
    /// Forward a provider lifecycle event from stdin to the existing server.
    AgentHookIntegrate(IntegrationCallback),
    /// Run one native agent discovery or delivery request.
    AgentWorker(AgentWorker),
    /// Own terminal PTYs for the session server so programs outlive its restarts.
    Holder(Holder),
    /// Steps an installer runs so terminals keep running during an upgrade.
    Update(Update),
}
#[derive(Args)]
pub struct Holder {
    /// Listen for the session server on this Unix-domain socket.
    #[usage(long)]
    pub socket: std::path::PathBuf,
}

#[derive(Args)]
pub struct Dev {
    #[usage(subcommand)]
    pub command: DevCommand,
}
#[derive(Subcommands)]
pub enum DevCommand {
    /// Run a scripted Codex terminal connected to the node queue.
    CodexMock(AgentPlayback),
    /// Run a scripted Claude Code terminal connected to the node queue.
    ClaudeMock(AgentPlayback),
    /// Run the real SystemOne UI and graph routing with scripted decisions, without model calls.
    SystemoneMock(SystemoneMock),
    /// Run the Slack Send node UI and delivery log without contacting Slack.
    SlackSendDemo(Messaging),
}
#[derive(Args)]
pub struct SystemoneMock {
    #[usage(flatten)]
    pub node: Systemone,
    /// Scripted decisions JSON; separate from the node's --config settings.
    #[usage(long)]
    pub scenario: Option<String>,
}
#[derive(Args)]
pub struct AgentPlayback {
    /// JSON scenario containing defaults and prompt-specific turns.
    #[usage(long)]
    pub config: Option<String>,
    /// Default assistant reply; supports {prompt} and {turn}.
    #[usage(long)]
    pub response: Option<String>,
    /// Thinking time before the reply, in milliseconds.
    #[usage(long)]
    pub think_ms: Option<u64>,
    /// Delay per displayed character; 0 displays the whole message.
    #[usage(long)]
    pub char_ms: Option<u64>,
    /// Model label displayed in the terminal.
    #[usage(long)]
    pub model: Option<String>,
    /// Initial title; otherwise the first question supplies the title.
    #[usage(long)]
    pub title: Option<String>,
    /// Submit this prompt after startup.
    #[usage(long)]
    pub prompt: Option<String>,
    /// Exit after completing one turn.
    #[usage(long)]
    pub once: bool,
    /// Consume node messages without an interactive terminal.
    #[usage(long)]
    pub headless: bool,
    /// Execute each tool step's configured command and display its actual output.
    #[usage(long)]
    pub real_tool_calling: bool,
}

#[derive(Args)]
pub struct ListSessions {
    /// Print structured session records.
    #[usage(long)]
    pub json: bool,
}
#[derive(Args)]
pub struct SessionTarget {
    /// Session $ID, exact name, or unambiguous name prefix from list-sessions.
    #[usage(short = 't', long)]
    pub target: String,
}
#[derive(Args)]
pub struct RenameSession {
    /// Session $ID or name.
    #[usage(short = 't', long)]
    pub target: String,
    /// New name; an empty string restores automatic naming.
    pub new_name: String,
}
#[derive(Args)]
pub struct NewSession {
    /// Session name; omitted names use the next available number.
    #[usage(short = 's', long)]
    pub session_name: Option<String>,
    /// Create without opening a GUI.
    #[usage(short = 'd', long)]
    pub detached: bool,
    /// Directory for the first shell (defaults to the calling directory).
    #[usage(short = 'c', long)]
    pub cwd: Option<String>,
}

#[derive(Args)]
pub struct Integration {
    #[usage(subcommand)]
    pub command: IntegrationCommand,
}

#[derive(Subcommands)]
pub enum IntegrationCommand {
    /// Preview one-time hook setup for an agent; use --apply to write or --status to inspect.
    Agent(Integrate),
    /// Manage shell completions for Graffitty.
    Completion(Completion),
}

#[derive(Args)]
pub struct Completion {
    #[usage(subcommand)]
    pub command: CompletionCommand,
}

#[derive(Subcommands)]
pub enum CompletionCommand {
    /// Install a completion file and print the shell setup instructions.
    Install(CompletionInstall),
}

#[derive(Args)]
pub struct CompletionInstall {
    /// Shell whose completion file should be installed.
    #[usage(choices("zsh", "bash", "fish"))]
    pub shell: String,
    /// Replace an existing completion file whose contents differ.
    #[usage(long)]
    pub force: bool,
}

#[derive(Args)]
pub struct Remote {
    #[usage(subcommand)]
    pub command: RemoteCommand,
}
#[derive(Subcommands)]
pub enum RemoteCommand {
    /// Connect to one or more SSH hosts without disconnecting the others.
    Connect(RemoteConnect),
}
#[derive(Args)]
pub struct RemoteConnect {
    /// SSH destinations or aliases from ~/.ssh/config.
    pub hosts: Vec<String>,
    /// Exact CLI server alias for targets such as build/%12 (one host only).
    #[usage(long)]
    pub alias: Option<String>,
    /// Optional session name; omitted uses the server's automatic session selection.
    #[usage(long, default = "")]
    pub workspace: String,
    /// Unified gft executable built for the remote OS and CPU; uploaded atomically.
    #[usage(long)]
    pub server_binary: Option<String>,
    /// Prepare tunnels and print a connection file without launching the GUI.
    #[usage(long)]
    pub no_gui: bool,
}

#[derive(Args)]
pub struct Tiling {
    #[usage(subcommand)]
    command: TilingCommand,
}
#[derive(Subcommands)]
pub enum TilingCommand {
    /// Inspect the calling tab's layout and panes.
    Status,
    /// Set or cycle tab layouts: tiles, floating, tiling, horizontal, vertical, h_tiles, v_tiles.
    Layout(TilingLayout),
    /// Focus the nearest tiled pane in a direction.
    Focus(Direction),
    /// Move the focused tiled pane in a direction.
    Move(Direction),
    /// Group the focused pane and its neighbor in an opposite-axis container.
    JoinWith(Direction),
    /// Choose the next split orientation (horizontal, vertical, opposite).
    Split(Split),
    /// Rebalance all sibling tiles equally.
    BalanceSizes,
    /// Show the main area or the overview including stashed panes.
    View(SpaceView),
    /// Open a terminal beside the focused pane using the selected split.
    NewWindow,
}
#[derive(Args)]
pub struct TilingLayout {
    layouts: Vec<String>,
}
#[derive(Args)]
pub struct Direction {
    #[usage(choices("left", "right", "up", "down"))]
    direction: String,
}
#[derive(Args)]
pub struct Split {
    #[usage(choices("horizontal", "vertical", "opposite"))]
    orientation: String,
}
#[derive(Args)]
pub struct Skill {
    /// `graph`: delegating to agents, running programs, wiring the graph and placement.
    /// `chromium`: driving Chromium panes, including @graffitty/playwright.
    #[usage(choices("graph", "chromium"))]
    pub name: Option<String>,
}
#[derive(Args)]
pub struct SpaceView {
    #[usage(choices("main", "overview"))]
    mode: String,
}

/// `gft server [FLAGS]` runs a server; the app, holders and headless
/// deployments start it with exactly that command line, so its flags stay at
/// this level. `gft server restart` restarts the running one.
#[derive(Args)]
pub struct Server {
    #[usage(subcommand)]
    pub command: Option<ServerCommand>,
    #[usage(flatten)]
    pub options: graffitty_server::Options,
}
#[derive(Subcommands)]
pub enum ServerCommand {
    /// Restart the local session server; its terminals keep running.
    Restart,
}
#[derive(Args)]
pub struct Checkpoint {
    #[usage(subcommand)]
    pub command: CheckpointCommand,
}
#[derive(Subcommands)]
pub enum CheckpointCommand {
    Save(CheckpointSave),
    List(CheckpointTag),
    Restore(CheckpointRestore),
}
#[derive(Args)]
pub struct CheckpointTag {
    /// Checkpoint history: manual for explicit saves, auto for server saves. Custom tags are supported.
    #[usage(long, default = "manual")]
    pub tag: String,
}
#[derive(Args)]
pub struct CheckpointSave {
    #[usage(flatten)]
    pub selection: CheckpointTag,
    /// Internal layout capture supplied by the native menu.
    #[usage(long)]
    pub input: Option<String>,
    /// The process list captured with --input, as
    /// `ps -ax -o pid=,ppid=,pgid=,tpgid=,tty=,state=,lstart=,comm=` prints it;
    /// omitted: this computer's processes.
    #[usage(long)]
    pub processes: Option<String>,
    /// Skip a save that changed nothing, and keep history entries at least
    /// this many seconds apart: a newer save replaces the newest entry until
    /// then. Automatic saves use this.
    #[usage(long)]
    pub rolling: Option<u64>,
}
#[derive(Args)]
pub struct CheckpointRestore {
    #[usage(flatten)]
    pub selection: CheckpointTag,
    /// History index (0 is newest) or a checkpoint file path.
    #[usage(long, default = "0")]
    pub checkpoint: String,
    /// Native frontend executable; omitted uses the standard Graffitty GUI.
    #[usage(long)]
    pub frontend: Option<String>,
    /// Prepare a validated restore document without launching a window.
    #[usage(long)]
    pub prepare_only: bool,
}
#[derive(Args)]
pub struct Layout {
    #[usage(long, default = "0.55", allow_negative_numbers)]
    ratio: f64,
}
#[derive(Args)]
pub struct Rpc {
    method: String,
    #[usage(long, default = "{}")]
    params: String,
}
#[derive(Args)]
pub struct Filetree {
    #[usage(long)]
    pub focus: bool,
}
#[derive(Args)]
pub struct ListPanes {
    /// Attached server alias/ or alias/session; omit for this workspace.
    #[usage(short = 't', long)]
    target: Option<String>,
}
#[derive(Args)]
pub struct Pid {
    /// Pane (%12, :2.1) or tab (@7, :2); omit for this window.
    pub target: Option<String>,
    /// Include sampled process identities, names, memory and freshness metadata.
    #[usage(long)]
    pub details: bool,
}
#[derive(Args)]
pub struct RenameTab {
    /// Stable @ tab ID or :position in this window.
    #[usage(long)]
    target: Option<String>,
    /// The tab at this position in this window, as the tab bar numbers it.
    #[usage(long)]
    tab: Option<u32>,
    /// The tab with this id, in any window (see list-tabs).
    #[usage(long)]
    tab_id: Option<i64>,
    /// The title; words are joined with spaces.
    title: Vec<String>,
}
#[derive(Args)]
pub struct RenamePane {
    /// Explicit pane target (%ID or :tab.pane, both numbered from 1); access remains scoped.
    #[usage(long)]
    target: Option<String>,
    /// The title; words are joined with spaces.
    title: Vec<String>,
}
/// Keyboard input for a terminal.
pub struct Terminal {
    command: TerminalCommand,
}
pub enum TerminalCommand {
    Type(TypeText),
    SendKey(SendKey),
}
#[derive(Args)]
pub struct Effects {
    #[usage(subcommand)]
    command: EffectsCommand,
}
#[derive(Subcommands)]
pub enum EffectsCommand {
    /// Turn effects off (and optionally keep some on) while this pane is focused.
    Hold(EffectsHold),
    /// Release one hold by id, or every hold of the pane.
    Release(EffectsRelease),
    /// List the pane's effect holds.
    List(EffectsList),
}
#[derive(Args)]
pub struct EffectsHold {
    /// Explicit pane target (%ID or :tab.pane, both numbered from 1) in this workspace.
    #[usage(long)]
    target: Option<String>,
    /// Hold id; a hold with the same id replaces the previous one.
    id: String,
    /// Comma-separated effects or groups to turn off: sparks, camera, camera.zoom, typing, all, ...
    #[usage(long, default = "")]
    off: String,
    /// Comma-separated effects to keep on even if another hold of this pane turns them off.
    #[usage(long, default = "")]
    on: String,
    /// When the hold ends by itself: with the foreground process group, with the pane, or never.
    #[usage(long, default = "process", choices("process", "pane", "clear"))]
    until: String,
    /// Print the OSC 4723 sequence for the current terminal instead of calling the server.
    #[usage(long)]
    osc: bool,
}
#[derive(Args)]
pub struct EffectsRelease {
    /// Explicit pane target (%ID or :tab.pane, both numbered from 1) in this workspace.
    #[usage(long)]
    target: Option<String>,
    /// Hold id; omit to release every hold of the pane.
    id: Option<String>,
    /// Print the OSC 4723 sequence for the current terminal instead of calling the server.
    #[usage(long)]
    osc: bool,
}
#[derive(Args)]
pub struct EffectsList {
    /// Explicit pane target (%ID or :tab.pane, both numbered from 1) in this workspace.
    #[usage(long)]
    target: Option<String>,
}

fn effect_names(value: &str) -> Vec<String> {
    value.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned).collect()
}

impl Effects {
    /// The validated effects message, and whether to print it as OSC instead of calling.
    fn message(&self) -> Result<Option<(graffitty_protocol::osc::Effects, bool)>, String> {
        use graffitty_protocol::osc::{Effects as Message, Hold, Scope};
        Ok(match &self.command {
            EffectsCommand::Hold(a) => {
                let hold = Hold {
                    id: a.id.clone(),
                    off: effect_names(&a.off),
                    on: effect_names(&a.on),
                    until: Scope::parse(&a.until).ok_or("until must be process, pane or clear")?,
                };
                hold.validate()?;
                Some((Message::Hold(hold), a.osc))
            }
            EffectsCommand::Release(a) => {
                if a.id.as_deref().is_some_and(|id| !graffitty_protocol::osc::valid_id(id)) {
                    return Err("Invalid hold id".into());
                }
                Some((Message::Release(a.id.clone()), a.osc))
            }
            EffectsCommand::List(_) => None,
        })
    }
    /// With `--osc`, the terminal sequence to write to this process's tty
    /// (wrapped for tmux passthrough inside tmux).
    pub fn osc_sequence(&self) -> Result<Option<Vec<u8>>, String> {
        let Some((message, true)) = self.message()? else { return Ok(None) };
        let tmux = std::env::var_os("TMUX").is_some_and(|v| !v.is_empty());
        Ok(Some(graffitty_protocol::osc::encode_effects(&message, tmux)))
    }
}
#[derive(Args)]
pub struct GetText {
    /// Pane target; prefix with server-alias/ for an attached remote server.
    #[usage(short = 't', long)]
    target: Option<String>,
    /// Include all retained scrollback of the active screen.
    #[usage(long)]
    pub scrollback: bool,
    /// Print the API JSON response instead of plain text.
    #[usage(long)]
    pub json: bool,
}
#[derive(Args)]
pub struct Integrate {
    #[usage(choices("claude", "codex", "opencode", "pi"))]
    pub provider: String,
    /// Apply the displayed changes (default is a read-only preview).
    #[usage(long)]
    pub apply: bool,
    /// Inspect installation health without changing files; exits 1 if not ready.
    #[usage(long)]
    pub status: bool,
    /// Remove only Graffitty's hooks from the selected provider home.
    #[usage(long)]
    pub remove: bool,
}
#[derive(Args)]
pub struct IntegrationCallback {
    /// Explicit lifecycle callback, or load a bundled native extension runtime.
    #[usage(choices("session-start", "prompt-submit", "turn-end", "turn-error", "session-end", "tool-start", "permission-request", "tool-end", "runtime"))]
    pub action: String,
    #[usage(long, choices("claude", "codex", "opencode", "pi"))]
    pub provider: String,
    /// Print the bundled native plugin runtime for a thin in-process loader.
    #[usage(long, choices("main", "tui", "server"))]
    pub runtime: Option<String>,
}
#[derive(Args)]
pub struct AgentWorker {
    #[usage(long)]
    pub request: String,
}
#[derive(Args)]
pub struct Messaging {
    /// Select a named credential from the host secrets.toml.
    #[usage(long)]
    pub credential: Option<String>,

    /// Non-secret JSON settings file; otherwise GRAFFITTY_NODE_CONFIG.
    #[usage(long)]
    pub config: Option<String>,
    /// Node display name.
    #[usage(long)]
    pub name: Option<String>,
    /// Telegram chat ID (Telegram only).
    #[usage(long)]
    pub chat_id: Option<String>,
    /// Slack or Discord channel ID.
    #[usage(long)]
    pub channel_id: Option<String>,
    /// jq expression producing a message from the complete incoming event.
    #[usage(long)]
    pub message_template: Option<String>,
    /// Read the jq template from a separate file.
    #[usage(long)]
    pub message_template_file: Option<String>,
    /// Open the editable template and preview form, initially paused.
    #[usage(long)]
    pub edit: bool,
    /// Never prompt or open an interactive form.
    #[usage(long)]
    pub headless: bool,
    /// Exit after delivering one event.
    #[usage(long)]
    pub once: bool,
    /// Preview a local event JSON file and exit without credentials or network.
    #[usage(long)]
    pub preview: Option<String>,
}
#[derive(Args)]
pub struct Parallel {
    /// Display name advertised to the graph.
    #[usage(long)]
    pub name: Option<String>,
    /// Exit after forwarding one complete round.
    #[usage(long)]
    pub once: bool,
}
#[derive(Args)]
pub struct PayloadInspector {
    /// Display name advertised to the graph.
    #[usage(long)]
    pub name: Option<String>,
    /// Print compact JSON lines instead of indented JSON.
    #[usage(long)]
    pub json: bool,
    /// Exit after displaying and acknowledging the first event.
    #[usage(long)]
    pub once: bool,
}
#[derive(Args)]
pub struct ManualPrompt {
    /// Display name advertised to the graph.
    #[usage(long)]
    pub name: Option<String>,
}
#[derive(Args)]
pub struct ReadSessionFile {
    /// Session JSONL path override; default: gather all Read-connected sessions.
    #[usage(long)]
    pub path: Option<String>,
    /// Limit gathering to one read-connected source node.
    #[usage(long)]
    pub node: Option<String>,
    /// Number of conversational messages to expand (default 10).
    #[usage(long)]
    pub last: Option<usize>,
    /// Exit after the first successful expansion.
    #[usage(long)]
    pub once: bool,
}
#[derive(Args)]
pub struct TimeTrigger {
    /// JSON settings file (also GRAFFITTY_NODE_CONFIG).
    #[usage(long)]
    pub config: Option<String>,
    #[usage(long)]
    pub name: Option<String>,
    /// One-time local date-time, next HH:MM[:SS] (today or tomorrow), or RFC3339 timestamp.
    #[usage(long)]
    pub at: Option<String>,
    /// Repeat interval such as 30s, 5m, 1h, or 250ms.
    #[usage(long)]
    pub every: Option<String>,
    /// Repeating schedule start; blank starts when applied.
    #[usage(long)]
    pub from: Option<String>,
    /// Exclusive repeating schedule deadline; blank repeats indefinitely.
    #[usage(long)]
    pub until: Option<String>,
    /// Text emitted with each trigger.
    #[usage(long)]
    pub text: Option<String>,
    /// Open settings even when configured; applying arms the schedule.
    #[usage(long)]
    pub edit: bool,
    /// Run without the settings UI.
    #[usage(long)]
    pub headless: bool,
}
#[derive(Args)]
pub struct Filter {
    /// Only forward at/after this local date-time, HH:MM, or RFC3339 timestamp.
    #[usage(long)]
    pub after: Option<String>,
    /// Stop forwarding at this time; events outside the window are acknowledged and dropped.
    #[usage(long)]
    pub before: Option<String>,
    /// JSON settings file (also GRAFFITTY_NODE_CONFIG).
    #[usage(long)]
    pub config: Option<String>,
    /// Display name advertised to the graph.
    #[usage(long)]
    pub name: Option<String>,
    /// jq expression selecting one value from the complete incoming event.
    #[usage(long)]
    pub input: Option<String>,
    /// jq expression returning exactly one boolean for the selected input.
    #[usage(long)]
    pub condition: Option<String>,
    /// jq expression on the full event returning {text, payload}; empty skips.
    #[usage(long)]
    pub transform: Option<String>,
    /// Open the editable settings form even when already configured.
    #[usage(long)]
    pub edit: bool,
    /// Never open a terminal form; require valid configuration.
    #[usage(long)]
    pub headless: bool,
    /// Exit after handling one event.
    #[usage(long)]
    pub once: bool,
}
#[derive(Args)]
pub struct Systemone {
    /// Select a named credential from the host secrets.toml.
    #[usage(long)]
    pub credential: Option<String>,

    /// JSON settings file (also GRAFFITTY_NODE_CONFIG).
    #[usage(long)]
    pub config: Option<String>,
    /// Decision provider: openrouter or custom (Decisions-compatible endpoint).
    #[usage(long)]
    pub provider: Option<String>,
    #[usage(long)]
    pub name: Option<String>,
    #[usage(long)]
    pub model: Option<String>,
    #[usage(long)]
    pub question: Option<String>,
    /// noul, choice, or score.
    #[usage(long)]
    pub mode: Option<String>,
    /// JSON array of output objects: id, description, optional name/color/icon.
    #[usage(long)]
    pub outputs: Option<String>,
    #[usage(long)]
    pub threshold: Option<f64>,
    /// Custom Decisions endpoint URL.
    #[usage(long)]
    pub endpoint: Option<String>,
    /// Start paused in the settings UI.
    #[usage(long)]
    pub edit: bool,
    #[usage(long)]
    pub headless: bool,
    #[usage(long)]
    pub once: bool,
}
#[derive(Args)]
pub struct Send {
    #[usage(long)]
    to: String,
    /// Message text; `-` reads it from stdin, past command-line length limits.
    #[usage(long)]
    text: String,
    /// Optional approved/needs_changes/failed outcome for conditional edges.
    #[usage(long)]
    outcome: Option<String>,
    /// Continue an existing graph run (bounded to 10,000 messages).
    #[usage(long)]
    run_id: Option<String>,
}
#[derive(Args)]
pub struct Graph {
    #[usage(subcommand)]
    command: GraphCommand,
}
#[derive(Subcommands)]
pub enum GraphCommand {
    List,
    /// Inspect live queued messages and recent delivery history (metadata only).
    Queue,
    Adjacent,
    /// Create a terminal and launch an integrated agent beside this terminal.
    Spawn(GraphSpawn),
    Connect(Connection),
    Disconnect(ConnectionPair),
    Read(GraphRead),
    Inbox,
    /// Send a message along an allowed graph connection.
    Send(Send),
}
#[derive(Args)]
pub struct GraphSpawn {
    #[usage(long, choices("claude", "codex", "opencode", "pi"))]
    provider: String,
    #[usage(flatten)]
    placement: Placement,
}
/// Where a new or existing pane goes, in workspace coordinates.
#[derive(Args, Default)]
pub struct Placement {
    /// Put it beside another pane: left, right, above or below.
    #[usage(long, choices("left", "right", "above", "below"))]
    side: Option<String>,
    /// The pane a side refers to (%ID or :tab.pane); omitted: this terminal.
    #[usage(long)]
    of: Option<String>,
    /// Absolute position "X,Y" in workspace pixels (floating tabs only).
    #[usage(long)]
    at: Option<String>,
    /// Size "WIDTHxHEIGHT" in workspace pixels (floating tabs only).
    #[usage(long)]
    size: Option<String>,
}
impl Placement {
    fn is_empty(&self) -> bool {
        self.side.is_none() && self.of.is_none() && self.at.is_none() && self.size.is_none()
    }
    fn apply(&self, params: &mut Value) -> Result<(), String> {
        if let Some(side) = &self.side { params["side"] = json!(side); }
        if let Some(of) = &self.of { params["of"] = json!(of); }
        if let Some(at) = &self.at {
            let (x, y) = at.split_once(',').ok_or("--at takes X,Y")?;
            params["x"] = json!(x.trim().parse::<f64>().map_err(|_| "--at takes numbers X,Y")?);
            params["y"] = json!(y.trim().parse::<f64>().map_err(|_| "--at takes numbers X,Y")?);
        }
        if let Some(size) = &self.size {
            let (w, h) = size.split_once('x').ok_or("--size takes WIDTHxHEIGHT")?;
            params["width"] = json!(w.trim().parse::<f64>().map_err(|_| "--size takes numbers WIDTHxHEIGHT")?);
            params["height"] = json!(h.trim().parse::<f64>().map_err(|_| "--size takes numbers WIDTHxHEIGHT")?);
        }
        Ok(())
    }
}
#[derive(Args)]
pub struct Run {
    /// Start an integrated agent instead of a command.
    #[usage(long, choices("claude", "codex", "opencode", "pi"))]
    agent: Option<String>,
    /// Model for --agent (pass your own when a child should match you).
    #[usage(long)]
    model: Option<String>,
    /// Extra agent arguments, repeatable (for example --agent-arg=--no-daemon).
    #[usage(long = "agent-arg")]
    agent_arg: Vec<String>,
    /// Pane name shown in its title and the Agents list.
    #[usage(long)]
    name: Option<String>,
    /// Working directory; omitted: this terminal's current directory.
    #[usage(long)]
    cwd: Option<String>,
    /// Keep it when this terminal closes (by default it closes too).
    #[usage(long)]
    outlive_parent: bool,
    /// Graph wires to make once the agent registers, comma-separated or
    /// repeated: send (you may message it), reply (it may message you), read
    /// (you may read its transcript), turn-completed, waiting, error (it
    /// notifies you).
    ///
    /// Needs --agent.
    #[usage(long)]
    wire: Vec<String>,
    #[usage(flatten)]
    placement: Placement,
    /// The command line, run by the new pane's shell; omitted: a plain shell.
    command: Vec<String>,
}
#[derive(Args)]
pub struct Place {
    /// The pane to arrange (%ID or :tab.pane); omitted: this terminal.
    #[usage(long)]
    target: Option<String>,
    #[usage(flatten)]
    placement: Placement,
}
#[derive(Args)]
pub struct ConnectionPair {
    #[usage(long)]
    from: String,
    #[usage(long)]
    to: String,
    /// Advertised source output ID; omit for a default/single output.
    #[usage(long, default = "")]
    from_port: String,
    /// Advertised destination input ID; omit for a default/single input.
    #[usage(long, default = "")]
    to_port: String,
}
#[derive(Args)]
pub struct Connection {
    #[usage(flatten)]
    pair: ConnectionPair,
    #[usage(long)]
    read: bool,
    #[usage(long)]
    send: bool,
    #[usage(long)]
    turn_completed: bool,
    /// Pause the connection and cancel pending messages.
    #[usage(long)]
    muted: bool,
    /// Optional text to match in completion/message content.
    #[usage(long)]
    contains: Option<String>,
    #[usage(long, choices("approved", "needs_changes", "failed"))]
    outcome: Option<String>,
}
#[derive(Args)]
pub struct GraphRead {
    #[usage(long)]
    node: String,
    /// Return transcript content from this byte offset; omit for the session file reference only.
    #[usage(long)]
    offset: Option<u64>,
}
#[derive(Args)]
pub struct TypeText {
    /// Pane target; prefix with server-alias/ for an attached remote server.
    #[usage(short = 't', long)]
    target: Option<String>,
    #[usage(long)]
    text: String,
    #[usage(long, default = "50", allow_negative_numbers)]
    interval_ms: f64,
}
#[derive(Args)]
pub struct SendKey {
    /// Pane target; prefix with server-alias/ for an attached remote server.
    #[usage(short = 't', long)]
    target: Option<String>,
    /// Enter, Backspace, ArrowLeft, Ctrl+c, etc.
    key: String,
    /// Send the key without typing effects (camera impulses and sparks).
    #[usage(long)]
    no_effects: bool,
}
#[derive(Args)]
pub struct Chromium {
    #[usage(subcommand)]
    command: ChromiumCommand,
}
#[derive(Subcommands)]
pub enum ChromiumCommand {
    /// Change the terminal/chromium split.
    Layout(Layout),
    List,
    /// Create a new Chromium pane.
    New(Create),
    /// Open a local file in a new chromium tab, reusing an associated pane.
    Open(OpenFile),
    Navigate(Navigate),
    Snapshot(Target),
    Click(Click),
    Fill(Fill),
    Press(Press),
    Scroll(Scroll),
    Eval(Eval),
    Wait(Wait),
    Present(Present),
    Select(Target),
    Close(Target),
    /// Relaunch a Chromium whose browser stopped unexpectedly, reopening its pages.
    Restart(Target),
}
#[derive(Args)]
pub struct Target {
    /// Chromium pane: %ID, :tab.pane, @tab-id.pane, or session:tab.pane.
    #[usage(short = 't', long)]
    target: Option<String>,
}
impl Target {
    fn value(self) -> Result<String, String> {
        self.target.ok_or_else(|| "Specify -t/--target for the Chromium pane".into())
    }
}
#[derive(Args, Default)]
pub struct ProfileOptions {
    /// Persistent Chromium profile directory; omitted uses the configured default.
    #[usage(long)]
    profile: Option<String>,
    /// Copy this profile into a temporary one, keeping its logins without locking it.
    #[usage(long)]
    profile_from: Option<String>,
}
impl ProfileOptions {
    /// Explicit profile fields for a request that may create a chromium pane.
    fn params(self, params: &mut Value) -> Result<(), String> {
        if self.profile.is_some() && self.profile_from.is_some() {
            return Err("Use either --profile or --profile-from".into());
        }
        if let Some(profile) = self.profile {
            params["profile"] = json!(profile);
        }
        if let Some(template) = self.profile_from {
            params["profile_template"] = json!(template);
        }
        Ok(())
    }
}
#[derive(Args)]
pub struct OpenFile {
    /// Local file path (relative paths use the current working directory).
    path: std::path::PathBuf,
    /// Open a new tab in this chromium pane.
    #[usage(short = 't', long)]
    target: Option<String>,
    /// Always create a new Chromium pane.
    #[usage(long)]
    new: bool,
    /// Profile for a newly created pane; cannot be combined with --target.
    #[usage(flatten)]
    profile: ProfileOptions,
}
impl OpenFile {
    fn params(self) -> Result<Value, String> {
        if self.new && self.target.is_some() {
            return Err("--new cannot be combined with --target".into());
        }
        if self.target.is_some() && (self.profile.profile.is_some() || self.profile.profile_from.is_some()) {
            return Err("--profile and --profile-from cannot be combined with --target".into());
        }
        let path = self
            .path
            .canonicalize()
            .map_err(|e| format!("Cannot open {}: {e}", self.path.display()))?;
        if !path.is_file() {
            return Err("Expected a file, not a directory".into());
        }
        let path = path.to_str().ok_or("File path is not valid UTF-8")?;
        let mut params = json!({"path":path,"new":self.new});
        if let Some(target) = self.target {
            params["chromium"] = json!(target);
        }
        self.profile.params(&mut params)?;
        Ok(params)
    }
}
#[derive(Args)]
pub struct Create {
    #[usage(flatten)]
    profile: ProfileOptions,
    #[usage(long, default = "about:blank")]
    url: String,
    /// Where the new pane goes (shown); omitted: hidden until revealed.
    #[usage(flatten)]
    placement: Placement,
}

#[derive(Args)]
pub struct Navigate {
    #[usage(flatten)]
    target: Target,
    #[usage(long)]
    url: String,
}

#[derive(Args)]
pub struct Click {
    #[usage(flatten)]
    target: Target,
    #[usage(long = "ref")]
    reference: String,
}

#[derive(Args)]
pub struct Fill {
    #[usage(flatten)]
    target: Target,
    #[usage(long = "ref")]
    reference: String,
    #[usage(long)]
    text: String,
}

#[derive(Args)]
pub struct Press {
    #[usage(flatten)]
    target: Target,
    #[usage(long)]
    key: String,
}

#[derive(Args)]
pub struct Scroll {
    #[usage(flatten)]
    target: Target,
    #[usage(long, default = "0", allow_negative_numbers)]
    x: f64,
    #[usage(long, default = "500", allow_negative_numbers)]
    y: f64,
}

#[derive(Args)]
pub struct Eval {
    #[usage(flatten)]
    target: Target,
    #[usage(long)]
    expression: String,
}

#[derive(Args)]
pub struct Wait {
    #[usage(flatten)]
    target: Target,
    #[usage(long)]
    selector: Option<String>,
    #[usage(long)]
    text: Option<String>,
    #[usage(long, default = "10000")]
    timeout_ms: u32,
}

#[derive(Args)]
pub struct Present {
    #[usage(flatten)]
    target: Target,
    #[usage(long, choices("native", "embedded"))]
    mode: String,
}

impl WorkspaceCommand {
    pub fn plain_text(&self) -> bool {
        match self {
            Self::GetText(a) => !a.json,
            _ => false,
        }
    }
    pub fn request(self) -> Result<(String, Value), String> {
        let (method, mut params) = match self {
            Self::SelectPane(a) => ("navigator.focus".into(), a.params()?),
            Self::Send(a) => {
                let text = if a.text == "-" {
                    use std::io::Read;
                    let mut bytes = Vec::new();
                    std::io::stdin()
                        .take(crate::MAX_REQUEST as u64 + 1)
                        .read_to_end(&mut bytes)
                        .map_err(|e| e.to_string())?;
                    if bytes.len() > crate::MAX_REQUEST {
                        return Err(format!(
                            "Message exceeds {} bytes; save it to a file and send its path",
                            crate::MAX_REQUEST
                        ));
                    }
                    String::from_utf8(bytes).map_err(|e| e.to_string())?
                } else {
                    a.text
                };
                (
                    "graph.send".into(),
                    json!({"to":a.to,"text":text,"outcome":a.outcome,"run_id":a.run_id}),
                )
            }
            Self::Run(a) => {
                let mut params = json!({});
                if let Some(agent) = &a.agent { params["agent"] = json!(agent); }
                else if !a.command.is_empty() { params["command"] = json!(a.command.join(" ")); }
                if a.agent.is_none() && (a.model.is_some() || !a.agent_arg.is_empty()) {
                    return Err("--model and --agent-arg need --agent".into());
                }
                if a.agent.is_some() && !a.command.is_empty() {
                    return Err("--agent starts the agent; pass extra arguments with --agent-arg".into());
                }
                if let Some(model) = &a.model { params["model"] = json!(model); }
                if !a.agent_arg.is_empty() { params["agent_args"] = json!(a.agent_arg); }
                if let Some(name) = &a.name { params["name"] = json!(name); }
                if let Some(cwd) = &a.cwd {
                    let path = std::path::Path::new(cwd);
                    let absolute = if path.is_absolute() { path.to_path_buf() } else {
                        std::env::current_dir().map_err(|e| e.to_string())?.join(path)
                    };
                    params["cwd"] = json!(absolute.display().to_string());
                }
                if a.outlive_parent { params["outlive_parent"] = json!(true); }
                let wires: Vec<String> = a.wire.iter().flat_map(|w| w.split(',')).map(str::trim).filter(|w| !w.is_empty()).map(String::from).collect();
                if !wires.is_empty() {
                    if a.agent.is_none() {
                        return Err("--wire needs --agent".into());
                    }
                    const WIRES: [&str; 6] = ["send", "reply", "read", "turn-completed", "waiting", "error"];
                    if let Some(unknown) = wires.iter().find(|w| !WIRES.contains(&w.as_str())) {
                        return Err(format!("unknown --wire '{unknown}'; choose from {}", WIRES.join(", ")));
                    }
                    params["wire"] = json!(wires);
                }
                a.placement.apply(&mut params)?;
                ("terminal.run".into(), params)
            }
            Self::Place(a) => {
                let mut params = json!({});
                if let Some(target) = &a.target { params["target"] = json!(target); }
                a.placement.apply(&mut params)?;
                ("pane.place".into(), params)
            }
            Self::Graph(a) => match a.command {
                // `Command::into_workspace` hands these two to `Self::Send` and `Self::Layout`.
                GraphCommand::Send(a) => return Self::Send(a).request(),
                GraphCommand::Spawn(a) => {
                    let mut params = json!({"provider":a.provider});
                    a.placement.apply(&mut params)?;
                    ("graph.spawn".into(), params)
                }
                GraphCommand::List => ("graph.list".into(), json!({})),
                GraphCommand::Queue => ("graph.queue".into(), json!({})),
                GraphCommand::Adjacent => ("graph.adjacent".into(), json!({})),
                GraphCommand::Inbox => ("graph.inbox".into(), json!({})),
                GraphCommand::Read(a) => {
                    let mut params = json!({"node":a.node});
                    if let Some(offset) = a.offset {
                        params["offset"] = json!(offset);
                    }
                    ("graph.read".into(), params)
                }
                GraphCommand::Connect(a) => (
                    "graph.connect".into(),
                    json!({"from":a.pair.from,"to":a.pair.to,"from_port":a.pair.from_port,"to_port":a.pair.to_port,"read":a.read,"send":a.send,"turn_completed":a.turn_completed,"muted":a.muted,"contains":a.contains,"outcome":a.outcome}),
                ),
                GraphCommand::Disconnect(a) => (
                    "graph.disconnect".into(),
                    json!({"from":a.from,"to":a.to,"from_port":a.from_port,"to_port":a.to_port}),
                ),
            },
            Self::Tiling(a) => {
                let (verb, params) = match a.command {
                    TilingCommand::Status => ("status", json!({})),
                    TilingCommand::Layout(a) => {
                        let allowed = [
                            "tiles",
                            "tiling",
                            "floating",
                            "horizontal",
                            "vertical",
                            "h_tiles",
                            "v_tiles",
                        ];
                        if a.layouts.is_empty()
                            || a.layouts.iter().any(|v| !allowed.contains(&v.as_str()))
                        {
                            return Err("layout requires tiles, tiling, floating, horizontal, vertical, h_tiles or v_tiles".into());
                        }
                        ("layout", json!({"layouts":a.layouts}))
                    }
                    TilingCommand::Focus(a) => ("focus", json!({"direction":a.direction})),
                    TilingCommand::Move(a) => ("move", json!({"direction":a.direction})),
                    TilingCommand::JoinWith(a) => ("join-with", json!({"direction":a.direction})),
                    TilingCommand::Split(a) => ("split", json!({"orientation":a.orientation})),
                    TilingCommand::BalanceSizes => ("balance-sizes", json!({})),
                    TilingCommand::View(a) => ("view", json!({"mode":a.mode})),
                    TilingCommand::NewWindow => ("new-window", json!({})),
                };
                (format!("tiling.{verb}"), params)
            }
            Self::Identify => ("identify".into(), json!({})),
            Self::GetText(a) => (
                "terminal.get_text".into(),
                json!({"scrollback":a.scrollback,"target":a.target}),
            ),
            Self::Pid(a) => ("terminal.pid".into(), json!({"target":a.target,"details":a.details})),
            Self::ListPanes(a) => ("pane.list".into(), json!({"target":a.target})),
            Self::Effects(a) => {
                let message = a.message()?;
                let target = match &a.command {
                    EffectsCommand::Hold(h) => &h.target,
                    EffectsCommand::Release(r) => &r.target,
                    EffectsCommand::List(l) => &l.target,
                };
                let mut params = json!({});
                if let Some(target) = target { params["target"] = json!(target); }
                match message {
                    Some((graffitty_protocol::osc::Effects::Hold(hold), _)) => {
                        params["id"] = json!(hold.id);
                        params["off"] = json!(hold.off);
                        if !hold.on.is_empty() { params["on"] = json!(hold.on); }
                        params["until"] = json!(hold.until.name());
                        ("effects.hold".into(), params)
                    }
                    Some((graffitty_protocol::osc::Effects::Release(id), _)) => {
                        if let Some(id) = id { params["id"] = json!(id); }
                        ("effects.release".into(), params)
                    }
                    None => ("effects.list".into(), params),
                }
            }
            Self::Filetree(a) => ("filetree.toggle".into(), json!({"focus":a.focus})),
            Self::Panes => ("surface.list".into(), json!({})),
            Self::Layout(a) => {
                if !a.ratio.is_finite() || !(0.25..=0.75).contains(&a.ratio) {
                    return Err("ratio must be between 0.25 and 0.75".into());
                }
                ("workspace.layout".into(), json!({"ratio":a.ratio}))
            }
            Self::Rpc(a) => {
                return Ok((
                    a.method,
                    serde_json::from_str(&a.params).map_err(|e| e.to_string())?,
                ));
            }
            Self::ListTabs => ("tab.list".into(), json!({})),
            Self::RenameTab(a) => {
                if [a.tab.is_some(), a.tab_id.is_some(), a.target.is_some()].into_iter().filter(|v| *v).count() > 1 {
                    return Err("use only one of --tab, --tab-id or --target".into());
                }
                if a.tab == Some(0) {
                    return Err("tab positions start at 1".into());
                }
                (
                    "tab.set_title".into(),
                    json!({"title":a.title.join(" "),"position":a.tab,"id":a.tab_id,"target":a.target}),
                )
            }
            Self::RenamePane(a) => (
                "window.set_title".into(),
                json!({"title":a.title.join(" "),"target":a.target}),
            ),
            Self::Terminal(a) => match a.command {
                TerminalCommand::Type(a) => {
                    if !a.interval_ms.is_finite() || !(0.0..=1000.0).contains(&a.interval_ms) {
                        return Err("interval-ms must be between 0 and 1000".into());
                    }
                    (
                        "terminal.type".into(),
                        json!({"text":a.text,"interval_ms":a.interval_ms,"target":a.target}),
                    )
                }
                TerminalCommand::SendKey(a) => {
                    let mut params = json!({"key":a.key,"target":a.target});
                    if a.no_effects { params["effects"] = json!(false); }
                    ("terminal.press".into(), params)
                },
            },
            Self::Chromium(a) => {
                let (verb, params) = match a.command {
                    ChromiumCommand::Layout(a) => return Self::Layout(a).request(),
                    ChromiumCommand::Open(a) => ("open", a.params()?),
                    ChromiumCommand::List => ("list", json!({})),
                    ChromiumCommand::New(a) => {
                        // Validate placement before creating anything.
                        a.placement.apply(&mut json!({}))?;
                        let mut params = json!({"url":a.url});
                        a.profile.params(&mut params)?;
                        ("create", params)
                    }
                    ChromiumCommand::Navigate(a) => {
                        ("navigate", json!({"chromium":a.target.value()?,"url":a.url}))
                    }
                    ChromiumCommand::Snapshot(a) => ("snapshot", json!({"chromium":a.value()?})),
                    ChromiumCommand::Click(a) => (
                        "click",
                        json!({"chromium":a.target.value()?,"ref":a.reference}),
                    ),
                    ChromiumCommand::Fill(a) => (
                        "fill",
                        json!({"chromium":a.target.value()?,"ref":a.reference,"text":a.text}),
                    ),
                    ChromiumCommand::Press(a) => {
                        ("press", json!({"chromium":a.target.value()?,"key":a.key}))
                    }
                    ChromiumCommand::Scroll(a) => {
                        if !a.x.is_finite() || !a.y.is_finite() {
                            return Err("Scroll coordinates must be finite".into());
                        }
                        (
                            "scroll",
                            json!({"chromium":a.target.value()?,"x":a.x,"y":a.y}),
                        )
                    }
                    ChromiumCommand::Eval(a) => (
                        "eval",
                        json!({"chromium":a.target.value()?,"expression":a.expression}),
                    ),
                    ChromiumCommand::Wait(a) => {
                        if !(1..=30000).contains(&a.timeout_ms) {
                            return Err("timeout-ms must be between 1 and 30000".into());
                        }
                        (
                            "wait",
                            json!({"chromium":a.target.value()?,"selector":a.selector,"text":a.text,"timeout_ms":a.timeout_ms}),
                        )
                    }
                    ChromiumCommand::Present(a) => (
                        "present",
                        json!({"chromium":a.target.value()?,"mode":a.mode}),
                    ),
                    ChromiumCommand::Select(a) => ("select", json!({"chromium":a.value()?})),
                    ChromiumCommand::Close(a) => ("close", json!({"chromium":a.value()?})),
                    ChromiumCommand::Restart(a) => ("restart", json!({"chromium":a.value()?})),
                };
                (format!("chromium.{verb}"), params)
            }
            Self::Skill(_)
            | Self::Put(_)
            | Self::Server(_)
            | Self::Gui(_)
            | Self::RestartServer
            | Self::Icat(_)
            | Self::ListSessions(_)
            | Self::NewSession(_)
            | Self::AttachSession(_)
            | Self::KillSession(_)
            | Self::HasSession(_)
            | Self::RenameSession(_)
            | Self::Mcp
            | Self::SelfManage(_)
            | Self::World(_)
            | Self::Remote(_)
            | Self::Checkpoint(_)
            | Self::Integrate(_)
            | Self::Node(_)
            | Self::Internal(_)
            | Self::Dev(_) => unreachable!(),
        };
        params
            .as_object_mut()
            .unwrap()
            .retain(|_, value| !value.is_null());
        Ok((method, params))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(agent: Option<&str>, wire: &[&str]) -> Run {
        Run {
            agent: agent.map(String::from), model: None, agent_arg: vec![], name: None, cwd: None, outlive_parent: false,
            wire: wire.iter().map(|w| w.to_string()).collect(),
            placement: Placement { side: None, of: None, at: None, size: None }, command: vec![],
        }
    }

    #[test]
    fn run_wire_is_split_validated_and_needs_an_agent() {
        let (method, params) = WorkspaceCommand::Run(run(Some("codex"), &["send,turn-completed", "error"])).request().unwrap();
        assert_eq!(method, "terminal.run");
        assert_eq!(params["wire"], json!(["send", "turn-completed", "error"]));
        let (_, params) = WorkspaceCommand::Run(run(Some("codex"), &[])).request().unwrap();
        assert!(params.get("wire").is_none(), "no wires, no parameter: {params}");
        assert_eq!(WorkspaceCommand::Run(run(None, &["send"])).request().unwrap_err(), "--wire needs --agent");
        let error = WorkspaceCommand::Run(run(Some("pi"), &["send,turn_completed"])).request().unwrap_err();
        assert!(error.contains("unknown --wire 'turn_completed'"), "{error}");
    }

    #[test]
    fn pane_title_request_renames_and_resets() {
        for (words, expected) in [(vec!["API".into(), "server".into()], "API server"), (vec![], "")] {
            let (method, params) = WorkspaceCommand::RenamePane(RenamePane { title: words, target: None }).request().unwrap();
            assert_eq!(method, "window.set_title");
            assert_eq!(params, json!({"title": expected}));
        }
    }

    #[test]
    fn chromium_open_validates_files_and_creation_options() {
        let root = std::env::temp_dir().join(format!("gft-open-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let file = root.join("a # % 한.pdf");
        std::fs::write(&file, b"fixture").unwrap();
        let params = OpenFile {
            path: file.clone(),
            target: Some("main:1.2".into()),
            new: false,
            profile: Default::default(),
        }
        .params()
        .unwrap();
        assert_eq!(
            params["path"],
            file.canonicalize().unwrap().to_str().unwrap()
        );
        assert_eq!(params["chromium"], "main:1.2");
        for new in [false, true] {
            let params = OpenFile { path: file.clone(), target: None, new, profile: Default::default() }.params().unwrap();
            assert!(params.get("chromium").is_none(), "An omitted target must stay absent on the wire");
            assert_eq!(params["new"], new);
        }
        assert!(
            OpenFile {
                path: file.clone(),
                target: Some("%3".into()),
                new: true,
                profile: Default::default(),
            }
            .params()
            .is_err()
        );
        assert!(
            OpenFile {
                path: root.clone(),
                target: None,
                new: false,
                profile: Default::default(),
            }
            .params()
            .is_err()
        );
        assert!(
            OpenFile {
                path: root.join("missing"),
                target: None,
                new: false,
                profile: Default::default(),
            }
            .params()
            .is_err()
        );
        assert!(
            Target {
                target: None
            }
            .value()
            .is_err()
        );
        let open = |target: Option<&str>, profile: ProfileOptions| OpenFile {
            path: file.clone(), target: target.map(Into::into), new: false, profile,
        }.params();
        let template = ProfileOptions { profile: None, profile_from: Some("/profiles/work".into()) };
        assert_eq!(open(None, template).unwrap()["profile_template"], "/profiles/work");
        let empty = ProfileOptions { profile: Some(String::new()), profile_from: None };
        assert_eq!(open(None, empty).unwrap()["profile"], "");
        assert!(open(None, Default::default()).unwrap().get("profile").is_none());
        let template = ProfileOptions { profile: None, profile_from: Some("/profiles/work".into()) };
        assert!(open(Some("%3"), template).is_err());
        let both = ProfileOptions { profile: Some("/a".into()), profile_from: Some("/b".into()) };
        assert!(open(None, both).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn chromium_profile_request_preserves_explicit_empty_override() {
        for profile in [None, Some("/profiles/work".into()), Some(String::new())] {
            let expected = profile.clone();
            let (method, params) = WorkspaceCommand::Chromium(Chromium {
                command: ChromiumCommand::New(Create {
                    profile: ProfileOptions { profile, profile_from: None },
                    url: "about:blank".into(),
                    placement: Placement::default(),
                }),
            })
            .request()
            .unwrap();
            assert_eq!(method, "chromium.create");
            assert_eq!(
                params.get("profile").and_then(Value::as_str),
                expected.as_deref()
            );
        }
        let create = |profile: Option<&str>| WorkspaceCommand::Chromium(Chromium {
            command: ChromiumCommand::New(Create {
                profile: ProfileOptions { profile: profile.map(Into::into), profile_from: Some("/profiles/work".into()) },
                url: "about:blank".into(),
                placement: Placement::default(),
            }),
        }).request();
        assert_eq!(create(None).unwrap().1["profile_template"], "/profiles/work");
        assert!(create(Some("/profiles/own")).is_err());
    }

    #[test]
    fn chromium_new_placement_follows_creation() {
        let new = |placement: Placement| WorkspaceCommand::Chromium(Chromium {
            command: ChromiumCommand::New(Create {
                profile: ProfileOptions { profile: None, profile_from: None },
                url: "about:blank".into(),
                placement,
            }),
        });
        let created = json!({"result": {"chromium": "%9"}});
        assert!(new(Placement::default()).placement_after_create().is_none(), "no placement: hidden as before");
        let beside = new(Placement { side: Some("left".into()), of: Some("%2".into()), ..Placement::default() })
            .placement_after_create().unwrap().unwrap();
        let (method, params) = place_created(&beside, &created).unwrap();
        assert_eq!(method, "pane.place");
        assert_eq!(params, json!({"target": "%9", "side": "left", "of": "%2"}));
        let floating = new(Placement { at: Some("10,20".into()), size: Some("640x480".into()), ..Placement::default() })
            .placement_after_create().unwrap().unwrap();
        assert_eq!(place_created(&floating, &created).unwrap().1,
            json!({"target": "%9", "x": 10.0, "y": 20.0, "width": 640.0, "height": 480.0}));
        assert!(place_created(&beside, &json!({"error": {"code": "x"}})).is_none(), "failed creation is not placed");
        let bad = new(Placement { size: Some("big".into()), ..Placement::default() });
        assert!(bad.request().is_err(), "bad placement is rejected before creating a pane");
    }
}

impl WorkspaceCommand {
    /// `chromium new` with placement: the `pane.place` parameters to send once
    /// creation succeeded, before `request()` consumes the command.
    pub fn placement_after_create(&self) -> Option<Result<Value, String>> {
        let Self::Chromium(Chromium { command: ChromiumCommand::New(create) }) = self else { return None };
        if create.placement.is_empty() { return None; }
        let mut params = json!({});
        Some(create.placement.apply(&mut params).map(|()| params))
    }
}

/// The `pane.place` request for a created chromium, if creation succeeded.
pub fn place_created(placement: &Value, created: &Value) -> Option<(String, Value)> {
    let chromium = created.pointer("/result/chromium").and_then(Value::as_str)?;
    let mut params = placement.clone();
    params["target"] = json!(chromium);
    Some(("pane.place".into(), params))
}

#[derive(Args)]
pub struct SystemNotification {
    /// JSON settings file; Ctrl+S saves changes here.
    #[usage(long)]
    pub config: Option<String>,
    /// Run without the interactive settings and notification log.
    #[usage(long)]
    pub headless: bool,
    /// Start paused in the settings form.
    #[usage(long)]
    pub edit: bool,

    /// Display name advertised to the graph.
    #[usage(long)]
    pub name: Option<String>,
    /// Default notification title (payload.title overrides it).
    #[usage(long)]
    pub title: Option<String>,
    /// Exit after emitting and acknowledging the first notification.
    #[usage(long)]
    pub once: bool,
}
