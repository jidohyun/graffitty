extends Node
## Client-local controller for the Herdr-derived Rust model. Sound playback never
## runs on the session server. One application instance owns all windows' alerts.
signal changed
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Paths := preload("res://graffitty/paths.gd")
var application: Node
var rows: Array = []
## Sub-rows per top row id: every pane connected to that agent in its tab (gft
## run children, chromiums, graph peers; excluding filetrees), as herdr lists
## sub-agents.
##
## Agents that appear under another agent leave the top level.
var trees: Dictionary = {}
var _core: RefCounted = ClassDB.instantiate("AgentsCore")
var _owners: Dictionary = {}
## Rows from sessions no window shows: id → {host, peer, session, pane}.
var _away: Dictionary = {}
var _audio: RefCounted
var audio_state := {"active": 0, "completed": 0, "error": ""}
var _pcm: Dictionary = {}
var _sounds: Dictionary = {}
var _streams: Dictionary = {}
var _saved := ""
var _path := ""
var _refresh_pending := false

func _ready() -> void:
	set_process(false)
	_path = Paths.stdpath("state").path_join("agents.json")
	if FileAccess.file_exists(_path):
		var error: String = _core.restore(FileAccess.get_file_as_string(_path))
		if not error.is_empty(): push_warning("Invalid agent list state: " + error)
	_saved = _core.save()
	_sounds = preload("res://config/UserConfig.gd").resolved(OS.get_cmdline_user_args()).settings.get("sounds", {})
	# Observe every graph transition, not just the coalesced marker repair tick.
	application.agent_api.graph.changed.connect(refresh)

## Pane titles and foreground apps change without a graph transition (they
## arrive as `pane_update` deltas), so each host's UI change also refreshes the
## rows, coalesced to one pass per frame.
func _queue_refresh() -> void:
	if _refresh_pending: return
	_refresh_pending = true
	refresh.call_deferred()

func refresh() -> void:
	var profiled_started := Time.get_ticks_usec()
	refresh_body()
	preload("res://graffitty/frame_profile.gd").add("Agents.refresh", Time.get_ticks_usec() - profiled_started)


func refresh_body() -> void:
	_refresh_pending = false
	var input: Dictionary = {}
	var remotes: Dictionary = {}
	var sessions: Dictionary = {}
	_owners.clear()
	var host_trees: Array = []
	for host in application.hosts:
		if not is_instance_valid(host) or host.is_queued_for_deletion(): continue
		if host.has_signal("ui_changed") and not host.ui_changed.is_connected(_queue_refresh): host.ui_changed.connect(_queue_refresh)
		var looking: bool = application.agent_attention.in_view.call(host)
		var ids_by_key: Dictionary = {}
		for tab in host.workspace_layout.tabs:
			var visible_keys := Layout.keys(tab.tree, true)
			for key in Layout.keys(tab.tree):
				if not host.is_terminal_pane(key): continue
				var node: Dictionary = application.agent_api.graph.nodes.get(key, {})
				if node.is_empty(): continue
				var connection: Node = application.agent_api.graph.remote_owners.get(key)
				if not is_instance_valid(connection): continue
				# Never persist client-local remapped IDs; scope pins to the server epoch.
				var id := JSON.stringify([connection.url, connection.epoch, connection.wire_id(int(key.substr(1)))])
				var shown: bool = looking and tab.id == host.workspace_layout.active and key in visible_keys
				var focused: bool = looking and key == host.pane_focus
				# Two views of the same server terminal are still one agent. Prefer
				# its focused/visible owner for seen rules and subsequent selection.
				if input.has(id) and (input[id].focused or (input[id].looking and not focused)): continue
				_owners[id] = host
				ids_by_key[key] = id
				remotes[id] = preload("res://scenes/remote/ConnectionName.gd").display({
					"name": connection.display_name if "display_name" in connection else "",
					"hostname": connection.server_hostname if "server_hostname" in connection else "",
					"url": connection.url}) if connection.url != "shared://local" else ""
				sessions[id] = session_label(connection)
				input[id] = {"id": id, "key": key, "title": host.pane_title(key),
					"provider": node.get("provider", ""), "status": node.get("status", ""),
					"program": node.get("program_status"),
					"looking": shown, "focused": focused}
		host_trees.append([host, ids_by_key])
	_add_away(input, remotes, sessions)
	var result: Dictionary = _core.observe(input.values(), int(Time.get_unix_time_from_system()))
	var next: Array = result.get("rows", [])
	for row in next:
		row["remote"] = remotes.get(row.id, "")
		row["session"] = sessions.get(row.id, "")
	var next_trees := _build_trees(host_trees, next)
	var hidden: Dictionary = {}
	for id in next_trees:
		for sub in next_trees[id]:
			if sub.kind == "agent" and sub.has("row_id"): hidden[sub.row_id] = true
	next = next.filter(func(row): return not hidden.has(row.id))
	if next != rows or next_trees != trees:
		rows = next
		trees = next_trees
		changed.emit()
	for sound in result.get("sounds", []): _play(sound)
	_save()

## Agents in every other session of every connected server, from the session
## descriptors' server-owned agent summaries. Shown views win: their rows carry
## live titles and looking/focused state.
func _add_away(input: Dictionary, remotes: Dictionary, sessions: Dictionary) -> void:
	_away.clear()
	for group in preload("res://scenes/session/SessionsList.gd").collect(application.hosts, []):
		var peer: Node = group.get("peer")
		if not group.connected or not is_instance_valid(peer) or not is_instance_valid(group.get("host")): continue
		# The peer publishes other sessions' agents through its live catalog.
		if peer.has_signal("changed") and not peer.changed.is_connected(_queue_refresh): peer.changed.connect(_queue_refresh)
		for value in peer.available_sessions:
			if not value is Dictionary: continue
			var label := preload("res://scenes/session/SessionLabel.gd").name_of(value)
			for agent in value.get("agents", []):
				var pane := int(agent.get("pane", -1))
				var id := JSON.stringify([peer.url, peer.epoch, pane])
				if pane < 0 or input.has(id): continue
				_away[id] = {"host": group.host, "peer": peer, "session": str(value.id), "pane": pane}
				remotes[id] = "" if group.local else str(group.name)
				sessions[id] = label if not label.is_empty() else str(value.id).trim_prefix("$")
				var program: Variant = agent.get("program")
				var title := str(agent.get("title", ""))
				if title.is_empty() and program is Dictionary: title = str(program.get("msg", ""))
				input[id] = {"id": id, "key": "%%%d" % pane, "title": title,
					"provider": str(agent.get("provider", "")), "status": str(agent.get("status", "")),
					"program": program, "looking": false, "focused": false}

## Server-owned session label (manual or automatic name), falling back to its ID.
static func session_label(connection: Object) -> String:
	var current := str(connection.get("workspace")) if connection.get("workspace") != null else ""
	var catalog: Variant = connection.get("available_sessions")
	if catalog is Array:
		for value in catalog:
			if value is Dictionary and str(value.get("id", "")) == current:
				var label := preload("res://scenes/session/SessionLabel.gd").name_of(value)
				return label if not label.is_empty() else current.trim_prefix("$")
	return current.trim_prefix("$")

## One graph per host: nodes for every pane in its tabs and the wires among
## them. The Rust model picks each group's leading agent and orders children.
func _build_trees(host_trees: Array, top_rows: Array) -> Dictionary:
	var by_id: Dictionary = {}
	for row in top_rows: by_id[row.id] = row
	var result: Dictionary = {}
	for pair in host_trees:
		var host: Node = pair[0]
		var ids_by_key: Dictionary = pair[1]
		var graph = application.agent_api.graph
		var nodes: Array = []
		var edges: Array = []
		var keys: Dictionary = {}
		for tab in host.workspace_layout.tabs:
			for window in Layout.windows(tab.tree):
				var key: String = window.pane
				var rect: Rect2 = window.get("rect", Rect2())
				var entry := {"key": key, "kind": "terminal", "title": host.pane_title(key), "provider": "", "app": "", "status": "",
					"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y]}
				var id := int(key.substr(1))
				if host.is_chromium_pane(key):
					entry.kind = "chromium"
					var owner_id: int = host.chromiums[id].owner_id if host.chromiums.has(id) else id
					if owner_id != id: edges.append({"from": "%%%d" % owner_id, "to": key, "kind": "chromium"})
				elif host.is_terminal_pane(key) and host.sessions.has(id):
					var node: Dictionary = graph.nodes.get(key, {})
					var term: Node = host.sessions[id].term
					var provider := str(node.get("provider", ""))
					var status := str(node.get("status", ""))
					var program: Dictionary = node.get("program_status", {}) if node.get("program_status") is Dictionary else {}
					if provider not in ["pi", "claude", "codex", "opencode"] and str(program.get("app", "")) in ["pi", "claude", "codex", "opencode"]:
						provider = str(program.app)
						status = {"working": "busy", "blocked": "waiting", "error": "waiting"}.get(str(program.get("state", "")), "idle")
					var filetree_owner: int = term.get_meta("filetree_owner", -1)
					var spawned_by: int = term.get_meta("spawned_by", -1)
					if filetree_owner >= 0:
						continue
					elif provider in ["pi", "claude", "codex", "opencode"]:
						entry.kind = "agent"
						entry.provider = provider
						entry.status = {"busy": "working", "waiting": "blocked", "error": "blocked", "offline": "offline"}.get(status, "idle")
					else:
						entry.app = str(host.sessions[id].model.foreground_app.get("id", ""))
					if spawned_by >= 0 and spawned_by != id: edges.append({"from": "%%%d" % spawned_by, "to": key, "kind": "spawned"})
				else: continue
				keys[key] = true
				nodes.append(entry)
		for edge in graph.edges.values():
			if keys.has(str(edge.get("from", ""))) and keys.has(str(edge.get("to", ""))):
				edges.append({"from": str(edge.from), "to": str(edge.to), "kind": "graph"})
		var computed: Variant = _core.tree({"nodes": nodes, "edges": edges})
		if not computed is Array: continue
		for tree in computed:
			var root_id = ids_by_key.get(str(tree.root))
			if root_id == null: continue
			var subs: Array = []
			for sub in tree.rows:
				var item: Dictionary = sub.duplicate()
				item["host_id"] = host.get_instance_id()
				if ids_by_key.has(item.key):
					item["row_id"] = ids_by_key[item.key]
					var agent: Dictionary = by_id.get(item.row_id, {})
					item.status = agent.get("status", item.status)
					item.remote = agent.get("remote", "")
					item.session = agent.get("session", "")
				subs.append(item)
			result[root_id] = subs
	return result

func focus_key(host_id: int, key: String) -> void:
	var host: Object = instance_from_id(host_id)
	if not is_instance_valid(host): return
	var window: Window = host.get_window() if host.is_inside_tree() else null
	if window != null: window.grab_focus()
	_reveal(host, key)

func _save() -> void:
	var data: String = _core.save()
	if data == _saved or _path.is_empty(): return
	DirAccess.make_dir_recursive_absolute(_path.get_base_dir())
	var file := FileAccess.open(_path + ".tmp", FileAccess.WRITE)
	if file == null: return
	file.store_string(data)
	file.close()
	if DirAccess.rename_absolute(_path + ".tmp", _path) == OK: _saved = data

func pin(id: String, pinned: bool) -> void:
	_core.pin(id, pinned)
	refresh()

## NextAgent and PreviousAgent: the focus moves one row along the list the
## Agents panel shows, wrapping at the ends.
##
## With no agent focused it starts at the first row, or the last when stepping
## back.
func step(direction: int) -> void:
	if rows.is_empty(): return
	var current := -1
	for index in rows.size():
		if rows[index].get("focused", false): current = index
	var target := posmod(current + direction, rows.size()) if current >= 0 else (0 if direction > 0 else rows.size() - 1)
	focus(str(rows[target].id))

func focus(id: String) -> void:
	if _away.has(id) and not _owners.has(id):
		_focus_away(_away[id])
		return
	var host: Node = _owners.get(id)
	if not is_instance_valid(host): return
	for row in rows:
		if row.id == id:
			host.get_window().grab_focus()
			_reveal(host, row.key)
			return

## The shared host of several servers decides whether this crosses to another
## server's session (a flight) or stays a tab switch.
func _reveal(host: Node, key: String) -> void:
	var client: Node = host.get_parent()
	if is_instance_valid(client) and client.get("federated") == true:
		client.get_parent().reveal_pane(key)
	else:
		host.reveal_pane(key)

## Switch the server's view to the agent's session, then focus its pane once
## the new topology presents it.
func _focus_away(target: Dictionary) -> void:
	var peer: Node = target.peer
	var host: Node = target.host
	if not is_instance_valid(peer) or not peer.connected or not is_instance_valid(host): return
	if peer.workspace != target.session:
		# Land the session's one flight on this agent, not on its last tab
		# followed by a second tab switch mid-transition.
		host.set_meta("session_switch_focus", target.pane)
		var result: Dictionary = await peer.request_action("session_switch", {"name": target.session})
		if result.get("type") == "error":
			if is_instance_valid(host): host.remove_meta("session_switch_focus")
			push_warning("Could not switch to session " + target.session)
			return
	var deadline := Time.get_ticks_msec() + 5000
	while is_instance_valid(host) and is_instance_valid(peer) and Time.get_ticks_msec() < deadline:
		var key := "%%%d" % (peer.local_id(target.pane) if peer.has_method("local_id") else target.pane)
		if host.workspace_layout.containing(key) >= 0:
			if host.is_inside_tree():
				host.get_window().show()
				host.get_window().grab_focus()
			host.reveal_pane(key)
			return
		await get_tree().process_frame

func open(host: Node) -> void:
	refresh()
	preload("res://scenes/AgentsDialog.gd").open(host)

func sounds_enabled() -> bool:
	return bool(_sounds.get("enabled", true))

func toggle_sounds() -> void:
	# Session-only override; never write back to the user's configuration.
	_sounds["enabled"] = not sounds_enabled()

func test_sound() -> void:
	_play("blocked")

func _play(kind: String) -> void:
	if not sounds_enabled(): return
	if not _streams.has(kind):
		var path: String = _sounds.get(kind, "")
		var stream: AudioStream
		if not path.is_empty():
			if not path.is_absolute_path(): path = Paths.config_path().get_base_dir().path_join(path)
			if FileAccess.file_exists(path):
				match path.get_extension().to_lower():
					"ogg": stream = AudioStreamOggVorbis.load_from_file(path)
					"mp3": stream = AudioStreamMP3.load_from_file(path)
					"wav": stream = AudioStreamWAV.load_from_file(path)
			if stream == null: push_warning("Could not load custom agent sound; using bundled sound")
		if stream == null: stream = load("res://scenes/sounds/agent-attention.ogg")
		_streams[kind] = stream
	if not _pcm.has(kind):
		var stream: AudioStream = _streams[kind]
		var playback := stream.instantiate_playback()
		if playback == null:
			push_error("Could not decode attention sound")
			return
		playback.start()
		var frames := PackedVector2Array()
		var remaining := int(ceil(minf(stream.get_length(), 10.0) * AudioServer.get_mix_rate()))
		while remaining > 0:
			var count := mini(remaining, 2048)
			frames.append_array(playback.mix_audio(1.0, count))
			remaining -= count
		playback.stop()
		_pcm[kind] = frames
	if _audio == null: _audio = ClassDB.instantiate("AttentionAudio")
	var error: String = _audio.play(_pcm[kind], int(AudioServer.get_mix_rate()))
	if not error.is_empty(): push_error("Attention sound: " + error)
	set_process(true)

func _process(_delta: float) -> void:
	if _audio == null: return
	audio_state = _audio.poll()
	var failure: String = audio_state.error
	if failure == "No audio output device" or failure.begins_with("Unsupported audio output format: "):
		print_verbose("Attention sound: " + failure)
	elif not failure.is_empty():
		push_error("Attention sound: " + failure)
	if audio_state.active == 0: set_process(false)
