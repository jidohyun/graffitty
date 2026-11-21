extends Node
## The application's mod host: publishes live data to JavaScript mods and runs
## what they ask for.
##
## Follows herdr-app's window `publish()` (Apache-2.0): each key is published
## whole; the engine re-renders only copies that read it. Per-window keys
## carry `@<window id>`; application-wide keys have no suffix.
const Paths := preload("res://graffitty/paths.gd")
const SessionsModel := preload("res://scenes/session/SessionsList.gd")
const Badge := preload("res://scenes/AgentStatusBadge.gd")
const HostActions := preload("res://scenes/HostActions.gd")
const Live := preload("res://scenes/session/LiveSessionMenu.gd")
## Colours the mods read through `theme()`; the same values the native chrome uses.
const THEME := {
	"background": "#202126", "chrome": "#202126", "surface": "#202126", "canvas": "#1a1b1f",
	"popover": "#24262c", "raised": "#303238", "hover": "#282a30", "selected": "#303238", "pressed": "#393c43",
	"border": "#42444d", "input": "#ffffff2e", "foreground": "#e4e4e7", "muted": "#a2a4ae", "dim": "#8b93a1",
	"accent": "#c6a0f6", "accent_foreground": "#faf5ff", "solid": "#7544a1", "solid_foreground": "#faf5ff",
	"selection": "#68408d", "working": "#ffd078", "blocked": "#ff8080", "done": "#8ab4f8", "idle": "#8b93a1",
	"unknown": "#8b93a1", "connected": "#a9b86d", "ansi1": "#ff8080", "ansi2": "#a9b86d", "ansi3": "#ffd078",
	"ansi4": "#8ab4f8", "ansi5": "#c6a0f6", "ansi6": "#89ddbd",
}
var application: Node
var host: RefCounted
var available := false
var _sessions_signature := ""
var _refresh_pending := false
var _saved_dirty := true
var _saved_connections: Array = []
var _pane_resources_pending := false


func _ready() -> void:
	set_process(false)
	if not ClassDB.class_exists("ModHost"):
		push_warning("Mods are unavailable: the extension has no ModHost")
		return
	host = ClassDB.instantiate("ModHost")
	var error: String = host.setup(Paths.stdpath("state"))
	if not error.is_empty():
		push_error("Mods failed to start: " + error)
		return
	available = true
	host.set_theme(JSON.stringify(THEME))
	_write_declarations()
	# Fixtures run without agents or a graph; the real application has both.
	if application.get("agents") != null: application.agents.changed.connect(_publish_agents)
	if application.get("agent_api") != null: application.agent_api.graph.changed.connect(_publish_agents)
	if application.get("localization") != null: application.localization.changed.connect(func(): host.invalidate())
	add_to_group(&"mod_data_views")
	_publish_agents()
	_publish_sessions()
	set_process(true)


func _process(_delta: float) -> void:
	for request in host.take_requests():
		_handle(request)


## Native model/transport notifications coalesce into one publication per batch.
func queue_refresh() -> void:
	if not available or _refresh_pending: return
	_refresh_pending = true
	_flush_refresh.call_deferred()

func _flush_refresh() -> void:
	_refresh_pending = false
	if not available: return
	for terminal_host in application.hosts:
		if not is_instance_valid(terminal_host) or terminal_host.is_queued_for_deletion(): continue
		watch_host(terminal_host)
		if terminal_host.get("workspace_layout") != null: publish_window(terminal_host)
	_publish_sessions()

func saved_connections_changed() -> void:
	_saved_dirty = true
	queue_refresh()

func _watch(source: Object, event: StringName, arguments := 0) -> void:
	if not is_instance_valid(source) or not source.has_signal(event): return
	var callback := queue_refresh if arguments == 0 else queue_refresh.unbind(arguments)
	if not source.is_connected(event, callback): source.connect(event, callback)

func watch_host(terminal_host: Node) -> void:
	_watch(terminal_host, &"ui_changed")
	_watch(terminal_host, &"presentation_changed")
	_watch(terminal_host, &"session_added", 1)
	_watch(terminal_host, &"active_session_changed", 1)
	_watch(terminal_host.get_window(), &"focus_entered")
	_watch(terminal_host.get_window(), &"focus_exited")
	if terminal_host.get("session_backend") != null and terminal_host.session_backend.is_remote:
		var connection: Node = terminal_host.session_backend.connection
		for peer in [connection] + (connection.connections if is_instance_valid(connection) and "connections" in connection else []):
			_watch(peer, &"changed")
			_watch(peer, &"panes_updated", 1)
			_watch(peer, &"session_switched")
			_watch(peer, &"state_changed", 1)
			_watch(peer, &"video_transport_changed")
	if terminal_host.get("workspace_layout") != null:
		for tab in terminal_host.workspace_layout.tabs:
			for key in preload("res://scenes/WorkspaceLayout.gd").keys(tab.tree):
				_watch(terminal_host.resource_monitor_for(int(key.substr(1))), &"snapshot_changed", 1)


## Where the program writes `graffitty.d.ts` for editors: its own data directory.
static func declarations_path() -> String:
	return Paths.stdpath("data").path_join("mods").path_join("graffitty.d.ts")


func _write_declarations() -> void:
	var path := declarations_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var text: String = host.declarations()
	if FileAccess.file_exists(path) and FileAccess.get_file_as_string(path) == text: return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null: file.store_string(text)


## Every host uses the same Rust-resolved registry, including embedded presenters.
static func registry() -> Dictionary:
	# Registration is fixed for this frontend lifetime. Presenter redraws must not
	# hash configuration files for every pane on every frame.
	var root := (Engine.get_main_loop() as SceneTree).root
	if not root.has_meta(&"graffitty_mod_registry"):
		root.set_meta(&"graffitty_mod_registry", preload("res://config/UserConfig.gd").resolved(OS.get_cmdline_user_args()).mods)
	return root.get_meta(&"graffitty_mod_registry")

static func manifest(name: String) -> Dictionary:
	return registry().get(name, {})

static func mod_props(name: String, context: Dictionary) -> Dictionary:
	var result: Dictionary = manifest(name).get("props", {}).duplicate(true)
	result.merge(context, true) # Host context cannot be forged by configured props.
	return result

static func load_registered(view: Control, name: String, props: Dictionary) -> String:
	var spec := manifest(name)
	if spec.is_empty(): return "no registered mod named " + name
	if not spec.enabled: return "mod is disabled: " + name
	var entry: String = spec.entry
	view.set_asset_roots(PackedStringArray([entry.get_base_dir(), "res://mods/icons", "res://scenes/icons", "res://assets/icons", "res://assets/icons/lucide"]))
	var context := JSON.stringify(mod_props(name, props))
	if entry.begins_with("res://"):
		if not FileAccess.file_exists(entry): return "missing mod entry: " + entry
		return view.load_source(name, FileAccess.get_file_as_string(entry), context)
	return view.load_entry(name, entry, context)

func load_into(view: Control, name: String, props: Dictionary) -> String:
	if not available: return "mods are unavailable"
	return load_registered(view, name, props)


## Per-window keys. Called by the window's host when focus, samples or effects change.
func publish_window(terminal_host: Node) -> void:
	if not available or not is_instance_valid(terminal_host): return
	watch_host(terminal_host)
	var id := str(terminal_host.get_instance_id())
	host.publish("focused@" + id, JSON.stringify({"pane": terminal_host.pane_focus, "tab": terminal_host.workspace_layout.active}))
	host.publish("session@" + id, JSON.stringify(_session(terminal_host)))
	host.publish("effects@" + id, JSON.stringify(_effects(terminal_host)))
	host.publish("prefix@" + id, JSON.stringify(_prefix(terminal_host)))
	host.publish("window@" + id, JSON.stringify({
		"platform": {"macOS": "macos", "Windows": "windows", "Linux": "linux", "Android": "android"}.get(OS.get_name(), OS.get_name().to_lower()),
		"touch": preload("res://scenes/input/InteractionProfile.gd").touch_controls(),
		"active": terminal_host.is_inside_tree() and terminal_host.get_window().has_focus(),
	}))
	host.publish("panes@" + id, JSON.stringify(_panes(terminal_host)))
	publish_resources(terminal_host)
	queue_pane_resources()


## The named session this window shows: its server-owned id and label.
static func _session(terminal_host: Node) -> Variant:
	if not "session_backend" in terminal_host: return null
	var peer: Node = Live.transport(terminal_host)
	if peer == null or peer.get("workspace") == null: return null
	var current := str(peer.workspace)
	var name := ""
	var catalog: Variant = peer.get("available_sessions")
	if catalog is Array:
		for value in catalog:
			if value is Dictionary and str(value.get("id", "")) == current:
				name = preload("res://scenes/session/SessionLabel.gd").name_of(value)
	var url := str(peer.get("url")) if peer.get("url") != null else ""
	var video: Dictionary = peer.video_transport() if peer.has_method("video_transport") else {}
	var platform := OS.get_name().to_lower() if url == "shared://local" else str(peer.server_platform) if "server_platform" in peer else ""
	return {"id": current, "name": name, "platform": platform, "server": url, "local": url == "shared://local", "connected": bool(peer.get("connected")), "video": video}


## Host "pane": a strip the workspace sizes to its mod and places beside a
## pane. Reads `pane()` from the key published by `publish_pane`.
func create_pane_strip(terminal_host: Node, key: String) -> Control:
	var strip := VBoxContainer.new()
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_theme_constant_override("separation", 0)
	for name in registry():
		var spec := manifest(name)
		if spec.host != "pane" or not spec.enabled: continue
		if not available or not ClassDB.class_exists("ModView"): continue
		var view: Control = ClassDB.instantiate("ModView")
		view.fit_content = true
		view.mouse_filter = Control.MOUSE_FILTER_PASS
		strip.add_child(view)
		var error := load_into(view, name, {"window": terminal_host.get_instance_id(), "pane": key})
		if not error.is_empty(): push_error("Mod %s: %s" % [name, error])
		view.render_now()
	# A single presenter needs no extra container or hover boundary.
	if strip.get_child_count() == 1:
		var view: Control = strip.get_child(0)
		strip.remove_child(view)
		strip.free()
		return view
	return strip


## One pane's status, as `pane()` returns it to the strip over that pane.
func publish_pane(terminal_host: Node, key: String, status: Dictionary) -> void:
	if not available or not is_instance_valid(terminal_host): return
	host.publish("pane/%s@%d" % [key, terminal_host.get_instance_id()], JSON.stringify(status))


## What the pane strip shows for `key`: label, CPU, memory and the agent badge.
## `position` is the pane's place among its tab's panes (0 for none).
static func pane_status(terminal_host: Node, key: String, position := 0) -> Dictionary:
	var source: Node = terminal_host.resource_monitor_for(int(key.substr(1)))
	var result := pane_resources(source.snapshot() if source != null else {}, key, position)
	result["agent"] = null
	if terminal_host.is_terminal_pane(key) and terminal_host.get("agent_api") != null:
		var node: Dictionary = terminal_host.agent_api.graph.public_node(key)
		var manifest: Dictionary = node.get("manifest", {})
		var provider := str(node.get("provider", ""))
		if not manifest.is_empty() or (not provider.is_empty() and provider != "shell"):
			result["agent"] = agent_badge(provider, str(node.get("status", "unknown")), manifest, node.get("status_history", []))
	return result


## Live zero and unavailable read differently: "—" is never a measurement.
static func pane_resources(data: Dictionary, key: String, position := 0) -> Dictionary:
	var live := str(data.get("status", "starting")) == "running"
	var cpu := "%.0f%%" % float(data.cpu_percent) if live and data.get("cpu_valid", false) else "—"
	var memory := "—"
	if live and data.get("memory_current") != null and data.get("memory_valid", true):
		var mib := float(data.memory_current) / 1048576.0
		memory = "%.1fG" % (mib / 1024.0) if mib >= 1024 else "%.0fM" % mib
	return {"pane": key, "label": ".%d (%s)" % [position, key] if position > 0 else key, "cpu": cpu, "memory": memory}


## The agent badge, as AgentStatusBadge.set_agent chooses it: a provider logo
## or a name, a node icon's glyph, the status glyph with its colour and spin,
## when the status began, and the history tooltip.
static func agent_badge(provider: String, status: String, manifest: Dictionary, history: Array) -> Dictionary:
	var logos := {"claude": "claude-code.svg", "codex": "codex.png", "opencode": "opencode.svg", "pi": "pi.svg"}
	var logo: Variant = logos.get(provider.to_lower())
	var name: String = provider.capitalize() if not provider.is_empty() else TranslationServer.translate("Node")
	var display_name := str(manifest.get("name", ""))
	if logo == null and not display_name.is_empty(): name = display_name
	var spec: Dictionary = preload("res://scenes/NodeIcon.gd").validate(manifest.get("icon", {})).get("icon", {})
	# A node's own artwork replaces the provider logo; `svg()` takes the source inline.
	if spec.has("svg") and not str(spec.svg).is_empty(): logo = str(spec.svg)
	var file := "circle-question-mark.svg"
	var tint := "#aab3c2"
	match status:
		"running", "busy": file = "loader-circle.svg"; tint = "#8ab4f8"
		"idle": file = "circle-check.svg"; tint = "#89ddbd"
		"waiting", "blocked": file = "circle-pause.svg"; tint = "#ffd078"
		"offline": file = "circle-x.svg"; tint = "#a0a0a0"
		"error", "failed": file = "circle-alert.svg"; tint = "#ff8080"
	var label := Badge.status_label(status)
	var since := Badge.status_since(history, status)
	return {"provider": provider, "logo": logo, "name": name, "symbol": str(spec.get("text", "")),
		"status": status, "status_label": label, "icon": file, "tint": tint, "spinning": status in ["running", "busy"],
		"since": since if since >= 0.0 else null, "tooltip": Badge.history_tooltip("%s · %s" % [name, label], history)}


## The workspace prefix: whether it is armed and the key that arms it.
func publish_prefix(terminal_host: Node) -> void:
	if not available or not is_instance_valid(terminal_host): return
	host.publish("prefix@" + str(terminal_host.get_instance_id()), JSON.stringify(_prefix(terminal_host)))


static func _prefix(terminal_host: Node) -> Variant:
	if not "prefix_commands" in terminal_host or terminal_host.prefix_commands == null: return null
	var prefix: Object = terminal_host.prefix_commands
	var key: int = int(prefix.settings.key) if prefix.get("settings") != null else KEY_NONE
	return {"active": bool(prefix.active), "available": key != KEY_NONE,
		"key": preload("res://scenes/WorkspacePrefix.gd").key_label(key) if key != KEY_NONE else ""}


func publish_resources(terminal_host: Node) -> void:
	if not available or not is_instance_valid(terminal_host): return
	host.publish("resources@" + str(terminal_host.get_instance_id()), JSON.stringify(_resources(terminal_host)))


func _effects(terminal_host: Node) -> Dictionary:
	var profiles := []
	for name in terminal_host.effect_profiles.names():
		profiles.append({"name": name, "label": terminal_host.tr(terminal_host.effect_profiles.label(name)) if terminal_host.effect_profiles.is_builtin(name) else name})
	var disabled: Array = terminal_host.effect_switches.keys()
	disabled.sort()
	return {"profile": terminal_host.effect_profiles.selected, "profiles": profiles, "disabled": disabled,
		"available": is_instance_valid(terminal_host.world) and terminal_host.world.get("fx_cfg") != null}


func _panes(terminal_host: Node) -> Array:
	var result := []
	for tab in terminal_host.workspace_layout.tabs:
		for key in preload("res://scenes/WorkspaceLayout.gd").keys(tab.tree):
			result.append({"key": key, "kind": "chromium" if terminal_host.is_chromium_pane(key) else "terminal",
				"title": terminal_host.pane_title(key), "focused": key == terminal_host.pane_focus})
	return result


## The Pane Status panel's data: the focused pane's readout as icon rows
## (`metrics`, each with its tooltip) plus the whole readout as `tooltip`.
static func _resources(terminal_host: Node) -> Dictionary:
	var h := terminal_host
	var chromium_selected: bool = h.is_chromium_pane(h.pane_focus)
	var session_id: int = int(h.pane_focus.substr(1)) if not h.pane_focus.is_empty() else h.active_session_id
	var monitor: Node = h.resource_monitor_for(session_id)
	var key: String = h.pane_focus if not h.pane_focus.is_empty() else "%%%d" % session_id
	var label := h.tr("Chromium %d") % session_id if chromium_selected else h.tr("Pane %%%d") % session_id
	var kind := "chromium" if chromium_selected else "terminal"
	var agent := {}
	if h.get("agent_api") != null and not chromium_selected:
		var node: Dictionary = h.agent_api.graph.public_node(key)
		if node.get("provider", "shell") != "shell" or not node.get("manifest", {}).is_empty():
			var status := str(node.get("status", "unknown"))
			agent = {"provider": str(node.get("provider", "")), "status": status, "name": str(node.get("manifest", {}).get("name", "")),
				"label": Badge.status_label(status), "since": Badge.status_since(node.get("status_history", []), status),
				"session_id": str(node.get("session_id", "")), "queued": int(node.get("queued", 0)),
				"detail": str(node.get("queue_error", node.get("discovery_note", "")))}
	var agent_lines: Array = []
	if not agent.is_empty():
		var session: String = agent.session_id if not str(agent.session_id).is_empty() else h.tr("discovering…")
		agent["session"] = h.tr("Session %s") % session
		agent["queued_label"] = h.tr("%d messages awaiting delivery") % int(agent.queued)
		agent_lines = ["", "%s · %s" % [agent.name if not str(agent.name).is_empty() else str(agent.provider).capitalize(), h.tr(agent.status)],
			agent.session, agent.queued_label]
		if not str(agent.detail).is_empty(): agent_lines.append(str(agent.detail))
	if monitor == null:
		var message := h.tr("Resource monitoring is unavailable for this pane.")
		return {"pane": key, "kind": kind, "label": label, "status": "unavailable", "status_label": h.tr("unavailable"), "message": message,
			"cpu": "—", "memory": "—", "metrics": [], "tooltip": "\n".join([label, message] + agent_lines), "agent": agent}
	var data: Dictionary = monitor.snapshot()
	var status := str(data.get("status", "starting"))
	var live := status == "running"
	var cpu := "%.0f%%" % float(data.get("cpu_percent", 0)) if live and data.get("cpu_valid", false) else "—"
	var memory := "%.0fM" % (float(data.memory_current) / 1048576.0) if live and data.get("memory_current") != null else "—"
	var lines: Array = ["%s · %s" % [label, h.tr(status)]]
	var metrics: Array = []
	var message := ""
	if status in ["starting", "unavailable", "disabled", "paused"]:
		message = h.tr(str(data.get("error", "")))
		lines.append(message)
	else:
		var cpu_text := "%.1f%%" % float(data.get("cpu_percent", 0)) if data.get("cpu_valid", false) else h.tr("warming up")
		if chromium_selected and not data.get("cpu_valid", false):
			cpu_text = h.tr("≥ %.1f%% (partial)") % float(data.cpu_percent_partial) if data.get("cpu_percent_partial") != null else h.tr("unavailable")
		var memory_text := "%.1f MiB" % (float(data.memory_current) / 1048576.0) if data.get("memory_current") != null else h.tr("unavailable")
		var memory_label := h.tr(str(data.get("memory_label", "Memory")))
		var peak := "%.1f MiB" % (float(data.get("memory_peak_observed", 0)) / 1048576.0)
		var processes := h.tr("%d processes · %s PID %d") % [int(data.get("process_count", 0)), h.tr("Chromium host" if chromium_selected else "Root shell"), int(data.get("root_pid", -1))]
		metrics = [
			{"id": "cpu", "icon": "cpu.svg", "value": cpu_text, "tooltip": h.tr("CPU")},
			{"id": "memory", "icon": "ram.svg", "value": memory_text, "tooltip": memory_label},
			{"id": "peak", "icon": "arrow-up.svg", "value": peak, "tooltip": h.tr("Peak observed")},
			{"id": "processes", "icon": "layers.svg", "value": str(int(data.get("process_count", 0))), "tooltip": processes},
		]
		lines += ["CPU  %s" % cpu_text, "%s  %s" % [memory_label, memory_text], h.tr("Peak observed  %.1f MiB") % (float(data.get("memory_peak_observed", 0)) / 1048576.0), processes]
	return {"pane": key, "kind": kind, "label": label, "status": status, "status_label": h.tr(status), "message": message,
		"cpu": cpu, "memory": memory, "metrics": metrics, "tooltip": "\n".join(lines + agent_lines), "agent": agent}


## Republishes `pane_resources` once this frame, however many samples arrived.
func queue_pane_resources() -> void:
	if _pane_resources_pending or not available: return
	_pane_resources_pending = true
	_publish_pane_resources.call_deferred()


## The Resource Monitor's rows: every pane of every window, grouped by computer
## and session by the Rust model, which keeps unknown samples unknown.
func _publish_pane_resources() -> void:
	_pane_resources_pending = false
	if not available or application.get("hosts") == null: return
	var graph: Node = application.agent_api.graph if application.get("agent_api") != null else null
	var inputs := []
	for terminal_host in application.hosts:
		if not is_instance_valid(terminal_host) or terminal_host.is_queued_for_deletion(): continue
		# A window still starting has no layout yet.
		if terminal_host.get("workspace_layout") == null: continue
		for tab in terminal_host.workspace_layout.tabs:
			for key in preload("res://scenes/WorkspaceLayout.gd").keys(tab.tree):
				inputs.append(_pane_input(terminal_host, key, graph))
	# Resolve view-local pane keys to stable resource identities before Rust
	# combines connections. Duplicate views may expose different links.
	var identities := {}
	for entry in inputs: identities[[entry.host, entry.key]] = entry.id
	for entry in inputs:
		var connected := []
		for key in entry.connected:
			var identity = identities.get([entry.host, key])
			if identity != null and identity != entry.id: connected.append(identity)
		entry.connected = connected
	var groups: Variant = ClassDB.class_call_static("AgentsCore", "pane_resources", inputs)
	host.publish("pane_resources", JSON.stringify(groups if groups is Array else []))


## One pane for `pane_resources`: where it runs, what runs in it, its samples.
static func _pane_input(terminal_host: Node, key: String, graph: Node) -> Dictionary:
	var id := int(key.substr(1))
	# The graph knows a terminal's server; chromiums and the rest use their session's.
	var peer: Node = graph.remote_owners.get(key) if graph != null else null
	if not is_instance_valid(peer):
		peer = null
		if terminal_host.get("session_backend") != null and terminal_host.session_backend.is_remote and is_instance_valid(terminal_host.session_backend.get("connection")):
			var connection: Node = terminal_host.session_backend.connection
			peer = connection.owners.get(id, connection.selected) if "owners" in connection else connection
	var url := str(peer.get("url")) if peer != null and peer.get("url") != null else "shared://local"
	var local := url == "shared://local"
	var wire: int = peer.wire_id(id) if peer != null and peer.has_method("wire_id") else id
	var entry := {
		"id": JSON.stringify([url, str(peer.get("epoch")) if peer != null else str(terminal_host.get_instance_id()), wire]),
		"host": terminal_host.get_instance_id(), "key": key, "kind": "terminal", "provider": "", "app": "",
		"title": terminal_host.pane_title(key), "local": local, "focused": key == terminal_host.pane_focus,
		"server": "" if local else preload("res://scenes/remote/ConnectionName.gd").display({
			"name": peer.get("display_name") if peer.get("display_name") != null else "",
			"hostname": peer.get("server_hostname") if peer.get("server_hostname") != null else "", "url": url}),
		"session": preload("res://scenes/Agents.gd").session_label(peer) if peer != null else "",
		"sample": null, "connected": [],
	}
	if graph != null:
		for edge in graph.edges.values():
			if str(edge.get("from", "")) == key: entry.connected.append(str(edge.get("to", "")))
			elif str(edge.get("to", "")) == key: entry.connected.append(str(edge.get("from", "")))
	if terminal_host.is_chromium_pane(key):
		entry.kind = "chromium"
		if terminal_host.chromiums.has(id): entry.connected.append("%%%d" % terminal_host.chromiums[id].owner_id)
	elif terminal_host.is_terminal_pane(key) and terminal_host.get("sessions") is Dictionary and terminal_host.sessions.has(id):
		var pair: Dictionary = terminal_host.sessions[id]
		var node: Dictionary = graph.nodes.get(key, {}) if graph != null else {}
		var provider := str(node.get("provider", ""))
		var program: Dictionary = node.get("program_status", {}) if node.get("program_status") is Dictionary else {}
		if provider not in ["pi", "claude", "codex", "opencode"]: provider = str(program.get("app", ""))
		if pair.has("term"):
			for field in ["filetree_owner", "spawned_by"]:
				var owner := int(pair.term.get_meta(field, -1))
				if owner >= 0: entry.connected.append("%%%d" % owner)
		if pair.has("term") and int(pair.term.get_meta("filetree_owner", -1)) >= 0: entry.kind = "filetree"
		elif provider in ["pi", "claude", "codex", "opencode"]:
			entry.kind = "agent"
			entry.provider = provider
		elif pair.has("model"): entry.app = str(pair.model.foreground_app.get("id", ""))
	var monitor: Node = terminal_host.resource_monitor_for(id)
	if monitor != null:
		var data: Dictionary = monitor.snapshot()
		var sample := {}
		for field in ["status", "cpu_valid", "cpu_percent", "memory_current", "memory_valid", "process_count", "root_pid"]:
			if data.has(field): sample[field] = data[field]
		entry.sample = sample
	return entry


func _publish_agents() -> void:
	if not available or application.get("agents") == null: return
	var rows := []
	for row in application.agents.rows:
		var copy: Dictionary = row.duplicate()
		copy["subs"] = application.agents.trees.get(row.id, [])
		rows.append(copy)
	host.publish("agents", JSON.stringify(rows))
	queue_refresh()


func _publish_sessions() -> void:
	if not available or application.get("hosts") == null: return
	if _saved_dirty:
		_saved_connections = preload("res://scenes/remote/ClientAuthentication.gd").read_connections().get("connections", [])
		_saved_dirty = false
	var saved := _saved_connections
	var saved_urls := saved.map(func(entry): return str(entry.get("url", "")))
	var listed: Array = application.session_hosts()
	var groups := SessionsModel.collect(listed, saved, application.opens_windows(), listed.filter(func(candidate): return candidate not in application.hosts))
	# Each window's list marks only the session that window shows (`sessions@<window>`);
	# the plain key, for views without a window, marks every shown session.
	var texts := {"sessions": JSON.stringify(SessionsModel.rows(groups, saved_urls, null))}
	for window in application.hosts:
		if is_instance_valid(window): texts["sessions@" + str(window.get_instance_id())] = JSON.stringify(SessionsModel.rows(groups, saved_urls, window))
	# Refresh action owners even when the public rows have identical labels.
	set_meta(&"session_groups", groups)
	var signature := JSON.stringify(texts)
	if signature == _sessions_signature: return
	_sessions_signature = signature
	for key in texts: host.publish(key, texts[key])


func _host_for(window_id: int) -> Node:
	for candidate in application.hosts:
		if is_instance_valid(candidate) and candidate.get_instance_id() == window_id: return candidate
	return null


func _handle(request: Dictionary) -> void:
	if str(request.kind) == "run" and str(request.name) == "PaneHeaderAction":
		var header: Node = get_tree().get_first_node_in_group(&"pane_header_%d" % int(request.copy))
		var args = JSON.parse_string(str(request.args)) if request.args is String else {}
		if is_instance_valid(header) and args is Dictionary: header.activate(str(args.get("action", "")))
		return
	var window: Node = get_tree().get_first_node_in_group(&"panel_window_%d" % int(request.copy))
	var terminal_host: Node = window.source if window != null and "source" in window else null
	if not is_instance_valid(terminal_host) and not application.hosts.is_empty(): terminal_host = application.hosts[0]
	match str(request.kind):
		"run": run(terminal_host, str(request.name), JSON.parse_string(str(request.args)) if request.args is String else {}, window)
		"open", "close": pass # Overlays are not routed yet; the shipped mods open none.
		"notify":
			var spec = JSON.parse_string(str(request.spec))
			if spec is Dictionary and is_instance_valid(terminal_host) and terminal_host.notification_overlay != null:
				terminal_host.notification_overlay.post(str(spec.get("title", "")), str(spec.get("body", "")))


## Actions mods may run: the registry's, plus the mod actions the shipped
## mods replaced native controls with.
func run(terminal_host: Node, name: String, args: Variant, origin: Node = null) -> void:
	var params: Dictionary = args if args is Dictionary else {}
	# The key binding's NewSession acts on the window's own server. A panel
	# naming a `server` creates the session there, further down.
	if name in HostActions.names() and not (name == "NewSession" and params.has("server")):
		if is_instance_valid(terminal_host): HostActions.run(terminal_host, name, params)
		return
	var groups: Array = get_meta(&"session_groups", [])
	var group := {}
	for candidate in groups:
		if candidate.id == str(params.get("server", "")): group = candidate
	match name:
		"SessionContextMenu":
			if not is_instance_valid(terminal_host): return
			for row in group.get("sessions", []):
				if row.id != str(params.get("session", "")): continue
				# Docked panel content belongs to the workspace viewport; its
				# hidden floating Window is not a valid popup sizing/placement owner.
				var owner: Node = terminal_host.get_window()
				var panel_view: Control
				if is_instance_valid(origin) and "view" in origin and is_instance_valid(origin.view):
					panel_view = origin.view
					owner = panel_view.get_window()
				preload("res://scenes/session/SessionContextMenu.gd").open(owner, terminal_host, row.get("peer", group.peer), row.id, row.name, panel_view, "session-%s-%s" % [group.id, row.id])
				break
		"SelectSession":
			for row in group.get("sessions", []):
				if row.id == str(params.get("session", "")): _select_session(row, group)
		"NewSession":
			if group.get("local", false) and not group.get("connected", false):
				application.open_local_session(PackedStringArray(["--new-session"]), "")
			elif group.get("connected", false) and is_instance_valid(group.get("peer")):
				_focus_session(group.host, group.peer)
				Live.create(group.host, group.peer)
		"RenameSession":
			if is_instance_valid(group.get("peer")): Live.rename(group.host, group.peer, str(params.get("session", "")))
		"ConnectServer":
			# Connect with the saved password; the manager opens only when the
			# server needs one or the attempt fails.
			if not is_instance_valid(terminal_host): return
			var client: Node = terminal_host.get_parent()
			var url := str(params.get("server", ""))
			if "federated" in client and client.federated: client.get_parent().connect_server(url)
			else: application.connect_server(client, url)
		"OpenServers":
			if is_instance_valid(terminal_host) and terminal_host.server_chooser.is_valid(): terminal_host.server_chooser.call()
		"MoveServer":
			var error := preload("res://scenes/remote/ClientAuthentication.gd").reorder_servers(str(params.get("server", "")), str(params.get("target", "")), bool(params.get("before", true)))
			if not error.is_empty(): host.publish("sessions_error", JSON.stringify(tr("Could not reorder servers.")))
		"FocusAgent": application.agents.focus(str(params.get("id", "")))
		"PinAgent": application.agents.pin(str(params.get("id", "")), bool(params.get("pinned", true)))
		"FocusPane":
			var owner: Object = instance_from_id(int(params.get("host", 0)))
			if is_instance_valid(owner):
				if owner.is_inside_tree(): owner.get_window().grab_focus()
				owner.focus_pane(str(params.get("key", "")))
		_: push_warning("Unknown mod action: " + name)


func _select_session(row: Dictionary, group: Dictionary) -> void:
	var peer: Node = row.get("peer", group.peer)
	var terminal_host: Node = row.get("host", group.host)
	if not is_instance_valid(peer) or not peer.connected or not is_instance_valid(terminal_host): return
	host.publish("sessions_status", JSON.stringify(tr("Opening %s…") % (row.id if row.name.is_empty() else row.name)))
	if peer.workspace != row.id:
		var result: Dictionary = await peer.request_action("session_switch", {"name": row.id})
		if result.get("type") == "error":
			host.publish("sessions_status", JSON.stringify(tr("Could not switch session")))
			return
	if is_instance_valid(terminal_host) and is_instance_valid(peer):
		_focus_session(terminal_host, peer)
	host.publish("sessions_status", JSON.stringify(""))
	_sessions_signature = ""
	_publish_sessions()


## Restore the selected computer's presentation while retaining every connection.
func _focus_session(terminal_host: Node, peer: Node) -> void:
	var client: Node = terminal_host.get_parent()
	if application.opens_windows() and not client.federated:
		application.present_desktop_client(client)
	if "federated" in client and client.federated:
		var manager: Node = client.get_parent()
		for key in manager.transports:
			if manager.transports[key] == peer:
				manager._open_workspace(key)
				break
	terminal_host.get_window().show()
	terminal_host.get_window().grab_focus()
	if terminal_host.active_terminal() != null: terminal_host.active_terminal().grab_focus()
