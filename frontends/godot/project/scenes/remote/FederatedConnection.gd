extends Node
## Multiplex independently authenticated backends into the ordinary workspace.
## IDs are allocated by each transport from the application's shared allocator.
signal chromium_received(session: int, data: PackedByteArray)
signal chromium_video_received(session: int, header: Dictionary, data: PackedByteArray)
signal chromium_gpu_state_received(session: int, active: bool)
signal resources_received(session: int, data: Dictionary, interval: float)
signal changed
signal panes_updated(ids: Array)
signal session_switching
signal session_switched
signal terminal_received(session: int, frame: Dictionary, data: PackedByteArray)
signal terminal_input_received(session: int, keys: Array)
signal state_changed(message: String)
signal history_received(session: int, text: String)
signal acknowledged(message: Dictionary)
signal notification_received(session: int, event: Dictionary)
signal clipboard_received(session: int, event: Dictionary)
var connections: Array[Node] = []
var labels: Dictionary[Node, String] = { }
var owners: Dictionary[int, Node] = { }
var connected := false
var epoch := "federation"
var topology: Dictionary = { "tabs": [], "panes": [], "edges": [], "headless": true }
var frames: Dictionary = { }
var subscriptions: Array = []
var last_error := ""
var stats := { "packets": 0, "bytes": 0 }
var selected: Node


func attach(settings: Dictionary) -> Node:
	var transport := preload("res://scenes/remote/RemoteConnection.gd").new()
	transport.namespace_ids = true
	transport.stream_quality = settings.get("chromium_stream", {}).duplicate()
	transport.preferred_session = str(settings.get("preferred_session", ""))
	transport.server_alias = str(settings.get("alias", ""))
	transport.controller_identity = str(settings.get("credential_id", settings.get("url", "")))
	connections.append(transport)
	transport.display_name = preload("res://scenes/remote/ConnectionName.gd").display(settings)
	labels[transport] = transport.display_name + " / " + transport.workspace
	add_child(transport)
	transport.authenticated.connect(func():
		var identity := settings.duplicate()
		if not transport.server_hostname.is_empty(): identity.hostname = transport.server_hostname
		transport.display_name = preload("res://scenes/remote/ConnectionName.gd").display(identity)
		labels[transport] = transport.display_name + " / " + transport.workspace)
	transport.sessions_changed.connect(func(): changed.emit())
	transport.changed.connect(_merge)
	transport.panes_updated.connect(_merge_pane_update.bind(transport))
	transport.session_switching.connect(func(): session_switching.emit())
	transport.session_switched.connect(_session_switched.bind(transport))
	transport.resources_received.connect(func(id, data, interval): resources_received.emit(id, data, interval))
	transport.state_changed.connect(
		func(_message):
			connected = connections.any(
				func(c):
					return c.connected,
			)
			state_changed.emit(
				"%d/%d servers connected"
				% [
					connections.filter(
						func(c):
							return c.connected,
					).size(),
					connections.size(),
				]
			),
	)
	transport.terminal_received.connect(
		func(id, frame, bytes):
			if id not in subscriptions: return
			if frame.has("columns"):
				frames[id] = frame
			terminal_received.emit(id, frame, bytes),
	)
	transport.terminal_input_received.connect(func(id, keys): terminal_input_received.emit(id, keys))
	transport.chromium_gpu_state_received.connect(func(id, active): chromium_gpu_state_received.emit(id, active))
	transport.chromium_video_received.connect(func(id, header, bytes): chromium_video_received.emit(id, header, bytes))
	transport.chromium_received.connect(
		func(id, bytes):
			chromium_received.emit(id, bytes),
	)
	transport.history_received.connect(
		func(id, text):
			history_received.emit(id, text),
	)
	transport.acknowledged.connect(
		func(message):
			acknowledged.emit(message),
	)
	transport.notification_received.connect(
		func(id, event):
			notification_received.emit(id, event),
	)
	transport.clipboard_received.connect(func(id, event): clipboard_received.emit(id, event))
	if selected == null:
		selected = transport
	transport.connect_remote(str(settings.url), str(settings.token))
	return transport


func remove(transport: Node) -> void:
	transport.disconnect_remote()
	connections.erase(transport)
	labels.erase(transport)
	if selected == transport:
		selected = connections.front() if not connections.is_empty() else null
	transport.queue_free()
	connected = connections.any(func(connection): return connection.connected)
	_merge()


func _merge() -> void:
	var merged := { "tabs": [], "panes": [], "chromiums": [], "edges": [], "headless": true }
	owners.clear()
	for transport in connections:
		if not transport.server_fonts.ready: continue
		# A correlated reply can advance workspace membership before the full
		# topology arrives. Retire that tab and its panes together; decoding its
		# now-absent layout as empty would destroy the outgoing view too early.
		var order: Array = transport.topology.workspace_state.order.map(func(id): return int(id)) if transport.topology.get("authoritative_layout", false) else transport.topology.tabs.map(func(tab): return int(tab.id))
		for pane in transport.topology.panes:
			if int(pane.tab) not in order: continue
			owners[int(pane.id)] = transport
			var presentation: Dictionary = pane.duplicate(true)
			presentation.headless = transport.topology.get("headless", false)
			presentation.authoritative_layout = transport.topology.get("authoritative_layout", false)
			merged.panes.append(presentation)
		for chromium in transport.topology.get("chromiums", []):
			if int(chromium.get("tab", chromium.owner)) not in order: continue
			owners[int(chromium.id)] = transport
			merged.chromiums.append(chromium)
		for source in transport.topology.tabs:
			if int(source.id) not in order: continue
			var tab: Dictionary = source.duplicate(true)
			tab.title = str(labels[transport]) + " · " + str(tab.title)
			tab.headless = transport.topology.get("headless", false)
			if transport.topology.get("authoritative_layout", false):
				tab.canonical_layout = transport.topology.get("workspace_state", {}).get("layout", {}).get("tabs", {}).get(str(int(tab.id)), {})
			tab.canonical_area = transport.topology.get("workspace_state", {}).get("tabs", {}).get(str(int(tab.id)), {}).get("area", [])
			owners[int(tab.id)] = transport
			merged.tabs.append(tab)
		merged.edges.append_array(transport.topology.get("edges", []))
	for id in frames.keys():
		if not owners.has(id):
			frames.erase(id)
	topology = merged
	changed.emit()


## Volatile fields changed on panes this transport owns: copy them into the
## merged presentation without rebuilding it, then let the view patch titles.
func _merge_pane_update(ids: Array, transport: Node) -> void:
	if not transport.server_fonts.ready: return
	var source := {}
	for pane in transport.topology.get("panes", []): source[int(pane.id)] = pane
	for chromium in transport.topology.get("chromiums", []): source[int(chromium.id)] = chromium
	var changed_ids: Array = []
	for list in ["panes", "chromiums"]:
		for item in topology.get(list, []):
			var id := int(item.id)
			if id not in ids or owners.get(id) != transport or not source.has(id): continue
			var fresh: Dictionary = source[id]
			for key in fresh:
				if key in ["id", "tab", "owner"]: continue
				item[key] = fresh[key].duplicate(true) if fresh[key] is Dictionary or fresh[key] is Array else fresh[key]
			changed_ids.append(id)
	var titles := {}
	for tab in transport.topology.get("tabs", []): titles[int(tab.id)] = str(tab.title)
	for tab in topology.get("tabs", []):
		var id := int(tab.id)
		if owners.get(id) == transport and titles.has(id):
			tab.title = str(labels[transport]) + " · " + titles[id]
	panes_updated.emit(changed_ids)


func _session_switched(transport: Node) -> void:
	# The owner's new attachment has no pane subscriptions, even when its
	# session and pane IDs are unchanged after a socket reconnect.
	subscriptions = subscriptions.filter(func(id): return owners.get(int(id)) != transport)
	for id in frames.keys():
		if owners.get(int(id)) == transport: frames.erase(id)
	selected = transport
	labels[transport] = transport.display_name + " / " + transport.workspace
	session_switched.emit()


func subscribe(ids: Array) -> void:
	subscriptions = ids.duplicate()
	for id in frames.keys():
		if id not in subscriptions: frames.erase(id)
	if not ids.is_empty():
		selected = owners.get(int(ids[0]), selected)
	for transport in connections:
		var owned := ids.filter(
			func(id):
				return owners.get(int(id)) == transport,
		)
		if transport.subscriptions != owned:
			transport.subscribe(owned)


func set_terminal_theme(id: int, theme: Dictionary) -> void:
	var transport: Node = owners.get(id)
	if transport != null: transport.set_terminal_theme(id, theme)


func send_input(id: int, bytes: PackedByteArray) -> void:
	var transport: Node = owners.get(id)
	if transport != null:
		transport.send_input(id, bytes)


func send_action(kind: String, id: int, values: Dictionary = { }) -> int:
	var transport: Node = owners.get(id, selected)
	return transport.send_action(kind, id, values) if transport != null else -1


func disconnect_remote() -> void:
	for transport in connections:
		transport.disconnect_remote()
	connected = false


func remote_call(id: int, method: String, params: Dictionary) -> Dictionary:
	var transport: Node = owners.get(id, selected)
	if transport == null:
		return { "error": { "message": "No remote connection selected" } }
	return await transport.remote_call(id, method, params)


func reject_chromium_codec(id: int, codec: String) -> void:
	var transport: Node = owners.get(id)
	if transport != null:
		transport.reject_chromium_codec(id, codec)


func reset_chromium_video(id: int) -> void:
	var transport: Node = owners.get(id)
	if transport != null:
		transport.reset_chromium_video(id)

func acknowledge_chromium(id: int, frame: int, held_msec := 0) -> void:
	var transport: Node = owners.get(id)
	if transport != null:
		transport.acknowledge_chromium(id, frame, held_msec)

func fonts_ready() -> bool:
	# An empty federation needs no fonts; allow the view to release its last host.
	return connections.is_empty() or connections.any(func(c): return c.server_fonts.ready)

func fonts_revision() -> String:
	return ",".join(PackedStringArray(connections.map(func(c): return str(c.server_fonts.revision))))

func fonts_for(id: int) -> RefCounted:
	return owners[id].server_fonts

func font_default(id: int) -> int:
	return owners[id].font_default(id)

func set_chromium_viewports(sizes: Dictionary) -> void:
	for transport in connections:
		var owned := {}
		for id in sizes:
			if owners.get(int(id)) == transport: owned[id] = sizes[id]
		transport.set_chromium_viewports(owned)
