extends RefCounted
## Desktop presentation routing only. Regroup/transfer validation and process
## ownership stay on the server.
##
## Holding over a session swaps the window to it in one frame, once it can
## draw; the view it replaces stays connected.
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")

static func hit(app: Node, point: Vector2, source: Node) -> Dictionary:
	for panel in app.get_tree().get_nodes_in_group("panel_window"):
		if panel.mod_name != "sessions" or not is_instance_valid(panel.view): continue
		var view: Control = panel.view
		if not view.is_visible_in_tree() or not ScreenSpace.shown(view).has_point(point): continue
		if DisplayServer.get_name() != "headless" and not app.scripted_pointer:
			var window_id := DisplayServer.get_window_at_screen_position(Vector2i(point))
			var carried_window: bool = app.drag.get("window_drag", false) and window_id == source.get_window().get_window_id()
			if window_id != view.get_window().get_window_id() and not carried_window: continue
		var local := ScreenSpace.into(view, point)
		var groups: Array = app.mods.get_meta(&"session_groups", [])
		for group in groups:
			for row in group.sessions:
				var key := "session-%s-%s" % [group.id, row.id]
				if view.hit_rect(key).has_point(local): return {"server": group.id, "session": row.id, "key": key}
			for key in ["server-" + group.id, "new-" + group.id, "empty-" + group.id]:
				if view.hit_rect(key).has_point(local): return {"server": group.id, "session": "", "key": key}
		# Blank list space creates on the source server, never on another server.
		if view.hit_rect("list").has_point(local):
			return {"server": source.session_backend.connection.url, "session": "", "key": "list"}
		return {"server": "", "session": "", "key": ""}
	return {}

static func update(app: Node, point: Vector2) -> bool:
	if not app.opens_windows(): return false
	var target := hit(app, point, app.drag.source)
	if target.is_empty():
		app.drag.erase("session_drop")
		app.drag.erase("session_hover")
		app.set_meta(&"session_drag_wanted", null)
		publish(app, {})
		return false
	var source: Node = app.drag.source
	var connection: Node = source.session_backend.connection
	var valid: bool = not source.get_parent().federated and target.server == connection.url
	app._clear_drop_hints()
	app._hover_tab(null, -1)
	if is_instance_valid(app.drag_preview): app.drag_preview.hide()
	if app.drag.kind == "tab": app.drag.strip.set_drag_external(true)
	app.drag.mode = app.DragMode.BLOCKED
	app.drag.target = null
	if not valid:
		app.drag.erase("session_drop")
		publish(app, {})
		return true
	if app.drag.get("window_drag", false):
		app.drag.window_drag = false
		app.drag.strip.window_drag = false
	app.drag.session_drop = target
	publish(app, target)
	var identity: String = target.server + "\n" + target.session
	if app.drag.get("session_hover", "") != identity:
		app.drag.session_hover = identity
		app.set_meta(&"session_drag_wanted", null)
		if not target.session.is_empty(): app.schedule_drag_hover()
	elif not target.session.is_empty() and app.drag.get("hover_ready", false):
		# This attaches a presentation, not a shell or a transcript process.
		var window := stage(app, source)
		var client := presentation(app, source, target.session)
		app.set_meta(&"session_drag_wanted", client)
		# A session still connecting has nothing to draw; settle() swaps it in.
		if is_instance_valid(client.host): reveal(app, window, client)
	return true

static func publish(app: Node, target: Dictionary) -> void:
	var text := JSON.stringify(target)
	if app.get_meta(&"session_drop_hint", "") == text: return
	app.set_meta(&"session_drop_hint", text)
	if app.mods != null and app.mods.host != null:
		app.mods.host.publish("sessions_drop", text)

static func presentation(app: Node, source: Node, session: String) -> Node:
	var connection: Node = source.session_backend.connection
	for candidate in app.session_hosts():
		if not is_instance_valid(candidate) or not app._compatible_shared_hosts(source, candidate): continue
		var view: RefCounted = app.desktop_presentation(candidate.get_parent())
		if not view.parked and candidate.get_window() != source.get_window(): continue
		if candidate.session_backend.connection.workspace == session: return candidate.get_parent()
	var previews: Array = app.get_meta(&"session_drag_presentations", [])
	for client in previews:
		if is_instance_valid(client) and str(client.settings.get("workspace", client.settings.get("initial_session", ""))) == session: return client
	var client: Node = load("res://scenes/remote/RemoteClient.gd").new()
	client.settings = source.get_parent().settings.duplicate(true)
	if client.settings.get("shared_local", false): client.settings.workspace = session
	else: client.settings.initial_session = session
	client.settings.get_or_add("capabilities", {}).erase("new_session")
	client.settings.capabilities.require_workspace = true
	if not client.settings.get("shared_local", false):
		client.settings.url = connection.url
		client.settings.token = connection.token
	client.managed = true
	client.local_return = source.get_parent().local_return
	client.server_epoch = connection.epoch
	client.connection.local_ids = connection.local_ids
	var window := stage(app, source)
	previews.append(client)
	app.set_meta(&"session_drag_presentations", previews)
	# Deferred: the client is still building its host when it reports one.
	client.host_ready.connect(func(): settle.call_deferred(app, window, client), CONNECT_ONE_SHOT)
	window.add_child(client)
	return client

## The window whose view a dragged-over session replaces.
static func stage(app: Node, source: Node) -> Window:
	var origin: Node = app.get_meta(&"session_drag_origin", source.get_parent())
	app.set_meta(&"session_drag_origin", origin)
	var view: RefCounted = app.desktop_presentation(origin)
	return view.window if view.parked else origin.get_window()

## A newly connected session takes the window only while it is still the one
## held; otherwise it waits off screen like every other retained session.
static func settle(app: Node, window: Window, client: Node) -> void:
	if not is_instance_valid(client) or not is_instance_valid(client.host) or not is_instance_valid(window): return
	if app.has_meta(&"session_drag_wanted") and app.get_meta(&"session_drag_wanted") == client: reveal(app, window, client)
	else: app.desktop_presentation(client).park(client, true)

static func reveal(app: Node, window: Window, client: Node) -> void:
	for candidate in app.hosts.duplicate():
		if candidate.get_parent() != client and candidate.get_window() == window:
			app.desktop_presentation(candidate.get_parent()).park(candidate.get_parent(), true)
	var view: RefCounted = app.desktop_presentation(client)
	if view.parked:
		view.restore(window)
	if app.mods != null: app.mods.queue_refresh()

static func clear(app: Node, keep: Node = null) -> void:
	publish(app, {})
	var origin: Node = app.get_meta(&"session_drag_origin") if app.has_meta(&"session_drag_origin") else null
	app.remove_meta(&"session_drag_origin")
	# Retain session presentations for subsequent switching. No server session
	# or native window is created/closed as a side effect of hovering.
	app.set_meta(&"session_drag_presentations", [])
	app.set_meta(&"session_drag_wanted", null)
	if is_instance_valid(origin) and keep == null:
		app.present_desktop_client(origin)

static func finish(app: Node) -> void:
	var state: Dictionary = app.drag.duplicate()
	var source: Node = state.source
	var destination: Dictionary = state.session_drop
	var client: Node = null
	if not destination.session.is_empty(): client = presentation(app, source, destination.session)
	clear(app, client)
	app._end_drag(client.host if is_instance_valid(client) else null)
	commit.call_deferred(app, state, client)

static func commit(app: Node, state: Dictionary, client: Node) -> void:
	var source: Node = state.source
	if not is_instance_valid(source): return
	var window := stage(app, source)
	app.remove_meta(&"session_drag_origin")
	var id: int = state.id
	var key: String = state.get("pane", "")
	var rectangles: Dictionary = state.get("rectangles", {})
	if state.session_drop.session.is_empty():
		if state.kind == "pane" and Layout.keys(source.workspace_layout.tab(id).tree).size() > state.get("keys", []).size():
			if not await app.move_pane(source, source, key, -1, "", "right", true, rectangles): return
			id = source.workspace_layout.containing(key)
		var response: Dictionary = await app._transfer_tab(source, id)
		app._finish_transfer(source.get_parent())
		if response.get("type") == "error":
			if id != state.id and is_instance_valid(source):
				await source.session_backend.connection.request_action("regroup", {"surface": key, "tab": state.id, "restore": true})
			return
		source.get_parent()._refresh()
		client = presentation(app, source, str(response.workspace))
		var ready_by := Time.get_ticks_msec() + 10000
		while is_instance_valid(client) and not is_instance_valid(client.host) and Time.get_ticks_msec() < ready_by:
			await app.get_tree().process_frame
		if is_instance_valid(client) and is_instance_valid(client.host): reveal(app, window, client)
		clear(app, client)
		return
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(client) and (not client.connection.connected or not is_instance_valid(client.host)) and Time.get_ticks_msec() < deadline:
		await app.get_tree().process_frame
	if not is_instance_valid(client) or not client.connection.connected or not is_instance_valid(client.host): return
	reveal(app, window, client)
	clear(app, client)
	var target: Node = client.host
	if state.kind == "tab":
		if source != target: await app.move_workspace(source, target, id)
	else: await app.move_pane(source, target, key, -1, "", "right", true, rectangles)
	if is_instance_valid(target): target.get_window().grab_focus()
