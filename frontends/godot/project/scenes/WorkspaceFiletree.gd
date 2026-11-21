extends RefCounted
## The session owner launches the filetree; the view presents its link and physics.
var busy := false

func toggle(host: Node, focus_tree := false) -> void:
	if busy: return
	var id := int(host.pane_focus.substr(1))
	if host.is_chromium_pane(host.pane_focus):
		id = host.chromiums[id].tab_id
		if not host.sessions.has(id) or host.sessions[id].term.get_meta("filetree_owner", -1) < 0: return
	elif not host.is_terminal_pane(host.pane_focus): return
	busy = true
	var backend = host.session_backend
	var connection: Node = backend.connection
	if "owners" in connection: connection = connection.owners.get(id)
	var epoch: String = connection.epoch if is_instance_valid(connection) else ""
	if not await backend.flush_workspace(host, id):
		busy = false
		if is_instance_valid(host): push_error("The filetree's server did not confirm the pane layout. Check its connection and try again.")
		return
	if not is_instance_valid(host) or not is_instance_valid(connection) or not connection.connected or connection.epoch != epoch:
		busy = false
		return
	var params := {"focus": focus_tree}
	var result: Dictionary = await connection.remote_call(id, "filetree.toggle", params)
	if not is_instance_valid(host):
		busy = false
		return
	if result.has("error"):
		busy = false
		push_error(str(result.error.get("message", "Filetree could not open")))
		return
	var key := str(result.get("result", {}).get("focus", ""))
	var deadline := Time.get_ticks_msec() + 10000
	while not key.is_empty() and not host.sessions.has(int(key.substr(1))) and Time.get_ticks_msec() < deadline:
		await host.get_tree().process_frame
		if not is_instance_valid(host):
			busy = false
			return
	busy = false
	if host.sessions.has(int(key.substr(1))): host.focus_pane(key)
	if host.workspace_view != null: host.workspace_view.wake_pane_physics()
