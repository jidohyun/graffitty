extends RefCounted
## Named server sessions, independent of the tabs inside each session.

static func transport(host: Node) -> Node:
	if not host.session_backend.is_remote or not "connection" in host.session_backend: return null
	var connection: Node = host.session_backend.connection
	if not is_instance_valid(connection): return null
	return connection.owners.get(host.active_session_id, connection.selected) if "owners" in connection else connection

static func signature(host: Node) -> String:
	var peer := transport(host)
	if peer == null: return ""
	return JSON.stringify([peer.get_instance_id(), peer.workspace, peer.connected, peer.available_sessions])

static func entries(host: Node) -> Array[Dictionary]:
	var result: Array[Dictionary] = [{"label": "Sessions::All Sessions…", "action": "AllSessions"}]
	var client: Node = host.get_parent()
	if host.server_chooser.is_valid():
		result.append({"label": "Sessions::Servers…", "action": func(h): h.server_chooser.call()})
	if client != null and "local_return" in client and client.local_return != null and is_instance_valid(client.local_return.client):
		result.append({"label": "Sessions::Return to This Computer", "action": func(h): h.application.present_desktop_client(client.local_return.client)})
	var peer := transport(host)
	if peer == null: return result
	result.append({
		"label": "Sessions::New Session",
		"action": "NewSession",
		"enabled": func(_h): return is_instance_valid(peer) and peer.connected,
	})
	result.append({"label": "Sessions::Rename Session…", "action": func(h): rename(h, peer, peer.workspace)})
	for step in [["Next Session", "NextSession", "next"], ["Previous Session", "PreviousSession", "previous"], ["Last Session", "LastSession", "last"]]:
		var which: String = step[2]
		result.append({
			"label": "Sessions::" + step[0],
			"action": step[1],
			"enabled": func(_h): return is_instance_valid(peer) and peer.connected and not peer.session_target(which).is_empty(),
		})
	for value in peer.available_sessions:
		var session := str(value.id)
		result.append({
			"label": "Sessions::Switch Session::" + preload("res://scenes/session/SessionLabel.gd").display(value),
			"literal_label": true,
			"command_line": false,
			"action": func(h): switch_to(h, peer, session),
			"checked": func(_h): return is_instance_valid(peer) and peer.workspace == session,
			"enabled": func(_h): return is_instance_valid(peer) and peer.connected,
		})
	return result

## Keep live sessions, remote connections, other commands and checkpoints in separate groups.
## User-defined actions and overrides retain their order within each group.
static func order(entries: Array[Dictionary]) -> Array[Dictionary]:
	var live: Array[Dictionary] = []
	var remote: Array[Dictionary] = []
	var other: Array[Dictionary] = []
	var checkpoints: Array[Dictionary] = []
	var result: Array[Dictionary] = []
	var index := -1
	for entry in entries:
		var label := str(entry.label)
		if not label.begins_with("Sessions::"):
			result.append(entry)
			continue
		if index < 0: index = result.size()
		if label in ["Sessions::New Session", "Sessions::Rename Session…", "Sessions::Next Session", "Sessions::Previous Session", "Sessions::Last Session"] or label.begins_with("Sessions::Switch Session::"):
			live.append(entry)
		elif label in ["Sessions::Servers…", "Sessions::Return to This Computer"] or label.begins_with("Sessions::Remote Access"):
			remote.append(entry)
		elif label in ["Sessions::Save checkpoint", "Sessions::Save checkpoint and quit"] or label.begins_with("Sessions::Resume manual checkpoint::") or label.begins_with("Sessions::Resume auto checkpoint::"):
			checkpoints.append(entry)
		else:
			other.append(entry)
	var sessions: Array[Dictionary] = []
	for group in [live, remote, other, checkpoints]:
		if group.is_empty(): continue
		if not sessions.is_empty():
			sessions.append({"label": "Sessions::Group %d" % sessions.size(), "action": "Separator"})
		sessions.append_array(group)
	if index >= 0:
		for entry in sessions:
			result.insert(index, entry)
			index += 1
	return result

static func rename(host: Node, peer: Node, target: String) -> void:
	if not is_instance_valid(peer) or not peer.connected: return
	var dialog := preload("res://scenes/session/RenameSessionDialog.gd").new()
	dialog.peer = peer
	dialog.target = target
	for session in peer.available_sessions:
		if session.id == target and session.name is String: dialog.custom_name = session.name
	host.get_window().add_child(dialog)
	dialog.popup_centered_clamped(Vector2i(420, 150), .9)
	dialog.session_name.grab_focus()

static func create(host: Node, peer: Node) -> void:
	if not is_instance_valid(peer) or not peer.connected: return
	var result: Dictionary = await peer.request_action("session_new", {})
	if result.get("type") == "error" and is_instance_valid(host):
		var dialog := AcceptDialog.new()
		dialog.dialog_text = host.tr("Could not create session")
		host.get_window().add_child(dialog)
		dialog.confirmed.connect(dialog.queue_free)
		dialog.canceled.connect(dialog.queue_free)
		dialog.popup_centered()

## NewSession: create on the server that owns the active session.
static func create_for(host: Node) -> void:
	create(host, transport(host))

## Resolve relative, previously viewed, and numbered destinations on the active peer.
static func step(host: Node, which: String) -> void:
	var peer := transport(host)
	if peer == null or not peer.connected: return
	var target: String = peer.session_target(which)
	if not target.is_empty(): switch_to(host, peer, target)

static func switch_to(host: Node, peer: Node, session: String) -> void:
	if not is_instance_valid(peer) or not peer.connected or peer.workspace == session: return
	var result: Dictionary = await peer.request_action("session_switch", {"name": session})
	if result.get("type") != "error" or not is_instance_valid(host): return
	var dialog := AcceptDialog.new()
	dialog.title = host.tr("Could not switch session")
	dialog.dialog_text = host.tr("The session owner did not respond.")
	host.add_child(dialog)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	dialog.popup_centered()
