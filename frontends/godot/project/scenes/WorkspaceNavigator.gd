extends RefCounted
## Presentation adapter: the server owns bindings, routing, and neighbor selection.
var host: Node
var held: Dictionary = {}
var queue: Array[Dictionary] = []
var busy := false
var literal_next := false
var epoch := 0

func focus_lost() -> void:
	epoch += 1
	held.clear()
	queue.clear()
	literal_next = false

func focus_changed() -> void:
	epoch += 1
	queue.clear()

func send_literal() -> void:
	literal_next = true

func content_has_focus() -> bool:
	if not host.is_terminal_pane(host.pane_focus): return false
	if host.command_line_open(): return false
	if is_instance_valid(host.dictation_preview) and host.dictation_preview.visible: return false
	var pair: Dictionary = host.sessions.get(int(host.pane_focus.substr(1)), {})
	if not pair.is_empty() and pair.term.has_method("get_ui_state") and not str(pair.term.get_ui_state().get("modal", "")).is_empty(): return false
	if is_instance_valid(host.close_dialog) and host.close_dialog.visible: return false
	var window: Window = host.get_window()
	for child in window.find_children("*", "Window", true, false):
		if child.visible and (child.exclusive or child is Popup): return false
	for viewport in [host.get_viewport(), host.workspace_view.canvas]:
		var control: Control = viewport.gui_get_focus_owner()
		if is_instance_valid(control) and control.is_visible_in_tree() and (control is LineEdit or control is TextEdit or control is RichTextLabel): return false
	return true

func connection_for(pane: String) -> Node:
	if not pane.begins_with("%") or not pane.substr(1).is_valid_int(): return null
	# A backend without a session connection (fixtures, early startup) navigates locally.
	if not "connection" in host.session_backend: return null
	var connection: Node = host.session_backend.connection
	if "owners" in connection:
		connection = connection.owners.get(int(pane.substr(1)), connection.owners.get(host.workspace_layout.containing(pane)))
	return connection

func request_id(pane: String, connection: Node) -> int:
	var id := int(pane.substr(1))
	for chromium in connection.topology.get("chromiums", []):
		if int(chromium.id) == id: return int(chromium.owner)
	return id

func configuration() -> Dictionary:
	var connection := connection_for(host.pane_focus)
	return connection.topology.get("navigator", {}) if is_instance_valid(connection) else {}

func key_name(event: InputEventKey) -> String:
	var parts := PackedStringArray()
	if event.ctrl_pressed: parts.append("ctrl")
	if event.alt_pressed: parts.append("alt")
	if event.shift_pressed: parts.append("shift")
	if event.meta_pressed: parts.append("meta")
	parts.append(OS.get_keycode_string(event.keycode).to_lower())
	return "+".join(parts)

func context(source: String) -> Dictionary:
	var view = host.workspace_view
	var group_id: int = host.workspace_layout.containing(source)
	var group: Dictionary = host.workspace_layout.tab(group_id)
	var rects: Dictionary = view.pane_rects.duplicate()
	if group_id != host.workspace_layout.active:
		rects.clear()
		preload("res://scenes/WorkspaceLayout.gd").rectangles(group.get("tree", {}), view.content_rect(), rects)
	var shown := {}
	for key in rects:
		var item := preload("res://scenes/WorkspaceLayout.gd").find(group.get("tree", {}), key)
		if item.get("shown", true):
			var rect: Rect2 = rects[key]
			shown[key] = [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
	return {"origin": source, "rects": shown}

func handle(event: InputEvent) -> bool:
	if not event is InputEventKey: return false
	if not event.pressed and held.has(event.keycode):
		held.erase(event.keycode)
		return true
	if not content_has_focus(): return false
	var config := configuration()
	if not config.get("enabled", false) or not config.get("bindings", {}).has(key_name(event)): return false
	if not event.pressed: return false
	held[event.keycode] = true
	var item := {"pane": host.pane_focus, "epoch": epoch, "literal": literal_next, "event": event.duplicate()}
	literal_next = false
	if queue.size() < 16: queue.append(item)
	if not busy: _drain()
	return true

func _forward_key(pane: String, original: InputEventKey, effects := false) -> void:
	if not host.sessions.has(int(pane.substr(1))): return
	var event := original.duplicate() as InputEventKey
	for pressed in [true, false]:
		event.pressed = pressed
		event.echo = original.echo and pressed
		host.sessions[int(pane.substr(1))].term.send_key(event, effects)

func apply_result(result: Dictionary) -> void:
	if result.get("outcome") != "moved": return
	var pane: String = result.get("destination", "")
	if pane.is_empty() or host.workspace_layout.containing(pane) < 0: return
	if not context(pane).rects.has(pane): return
	host.focus_pane(pane)
	host.workspace_view.reveal_navigation_target(pane)

func _drain() -> void:
	busy = true
	while not queue.is_empty():
		var item: Dictionary = queue.pop_front()
		if item.epoch != epoch or item.pane != host.pane_focus: continue
		if item.literal:
			_forward_key(item.pane, item.event, true)
			continue
		var connection := connection_for(item.pane)
		if not is_instance_valid(connection):
			_forward_key(item.pane, item.event)
			continue
		var response: Dictionary = await connection.remote_call(int(str(item.pane).substr(1)), "navigator.input",
			{"key": key_name(item.event), "context": context(item.pane)})
		if not is_instance_valid(host): return
		if item.epoch != epoch or item.pane != host.pane_focus: continue
		# This RPC only returns a decision; it cannot have moved focus on timeout.
		var result: Dictionary = response.get("result", {"outcome": "pass"})
		if result.get("outcome") == "pass": _forward_key(item.pane, item.event, result.get("effects", false))
		else: apply_result(result)
	busy = false

func focus_direction(direction: String, source := "") -> void:
	if source.is_empty(): source = host.pane_focus
	var connection := connection_for(source)
	if not is_instance_valid(connection): return
	var before: String = host.pane_focus
	var generation := epoch
	var response: Dictionary = await connection.remote_call(request_id(source, connection), "navigator.select",
		{"direction": direction, "context": context(source)})
	if not is_instance_valid(host) or epoch != generation or host.pane_focus != before: return
	apply_result(response.get("result", {}))

func set_algorithm(algorithm: String) -> void:
	var connection := connection_for(host.pane_focus)
	if not is_instance_valid(connection): return
	var response: Dictionary = await connection.remote_call(request_id(host.pane_focus, connection), "navigator.configure", {"algorithm": algorithm})
	if response.has("result"):
		connection.topology.navigator = response.result
		host._update_menu()

func menu_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for algorithm in ["weighted", "spatial", "nearest"]:
		entries.append({
			"label": "View::Navigation::" + algorithm.capitalize(),
			"action": func(h): h.navigator.set_algorithm(algorithm),
			"checked": func(h): return h.navigator.configuration().get("algorithm", "") == algorithm,
		})
	return entries
