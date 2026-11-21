extends SceneTree
## Isolated live-server routing test; test_session_transfer.py owns the server.
const SessionDrag := preload("res://scenes/session/SessionPanelDrag.gd")
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	print("%s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures.append(message)

func wait_for(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()

func _initialize() -> void:
	run.call_deferred()

## A pane carried from a parked or inactive host must draw in its new host.
func renders(viewport: SubViewport) -> bool:
	return (viewport.get_meta("render_updates_enabled", true) and not viewport.has_meta("render_updates_resume_mode")
		and preload("res://scenes/TerminalViewportUpdates.gd").is_active(viewport)
		and viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED)

func run() -> void:
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "0")
	root.size = Vector2i(1280, 800)
	var wrapper: Node
	var remote_descriptor := OS.get_environment("GRAFFITTY_TEST_REMOTE_DESCRIPTOR")
	if remote_descriptor.is_empty():
		wrapper = load("res://scenes/terminal.tscn").instantiate()
		wrapper.launch_args = PackedStringArray(["--workspace=main", "--shell=/bin/sh", "--plugin=flat-2d"])
	else:
		var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(remote_descriptor))
		wrapper = load("res://scenes/remote/RemoteClient.gd").new()
		wrapper.settings = {"url": descriptor.url, "token": descriptor.token, "startup_world": "flat-2d"}
		wrapper.managed = true
	root.add_child(wrapper)
	if not await wait_for(func(): return is_instance_valid(wrapper.host)):
		check(false, "source attaches")
		quit(1)
		return
	var source: Node = wrapper.host
	var app: Node = source.application
	var original: String = wrapper.connection.workspace
	var first: int = source.active_session_id
	var created: Dictionary = await wrapper.connection.request_action("create", {"kind": "tab"})
	var tab: int = int(created.created)
	if not await wait_for(func(): return source.sessions.has(tab) and source.workspace_layout.containing("%%%d" % tab) >= 0):
		check(false, "new tab is presented")
		quit(1)
		return
	var pid: int = source.sessions[tab].term.get_shell_pid()
	var state := {"source": source, "id": tab, "kind": "tab", "session_drop": {"session": ""}}
	await SessionDrag.commit(app, state, null)
	var target: Node
	for candidate in app.session_hosts():
		if candidate != source: target = candidate
	check(is_instance_valid(target), "Panel new-session drop presents a destination")
	if not is_instance_valid(target):
		quit(1)
		return
	check(await wait_for(func(): return target.get_parent().connection.connected and target.sessions.has(tab)), "Destination attaches")
	var session: String = target.session_backend.connection.workspace
	check(target.get_window() == root, "New-session drop reuses the current window")
	check(session != original, "New-session drop allocates another server session")
	check(target.sessions[tab].term.get_shell_pid() == pid, "Transfer retains live shell PID")
	check(source.sessions.has(first) and not source.sessions.has(tab), "Unrelated source tab remains")
	# Existing-session drop retains the tab boundary, never merges sessions.
	state = {"source": target, "id": tab, "kind": "tab", "session_drop": {"session": original}}
	await SessionDrag.commit(app, state, wrapper)
	var returned := await wait_for(func(): return source.sessions.has(tab))
	check(returned, "Existing-session drop returns tab")
	if not returned:
		quit(1)
		return
	check(source.workspace_layout.tab(first).size() > 0 and source.workspace_layout.tab(tab).size() > 0, "Both tabs remain distinct")
	check(source.sessions[tab].term.get_shell_pid() == pid, "Return transfer retains PID")
	# A pane drop splits only the carried group before transferring the new tab.
	var split: Dictionary = await wrapper.connection.request_action("create", {"kind": "pane", "session": first})
	var pane: int = int(split.created)
	check(await wait_for(func(): return source.sessions.has(pane)), "Split pane is presented")
	var pane_key := "%%%d" % pane
	var pane_pid: int = source.sessions[pane].term.get_shell_pid()
	# Exercise routing before commit: the docked panel shares the source's
	# native window and must not be mistaken for ordinary pane movement.
	source.select_workspace(source.workspace_layout.containing(pane_key), true)
	var panel: Window = preload("res://scenes/mods/PanelWindow.gd").open(source, "sessions")
	app.mods._publish_sessions()
	for i in 10: await process_frame
	var row: Rect2 = panel.view.hit_rect("session-%s-%s" % [wrapper.connection.url, original])
	check(row.has_area(), "Source session has a docked drop row")
	var point := preload("res://scenes/ScreenSpace.gd").of(panel.view, row.get_center())
	app.scripted_pointer = true
	var control: Control = source.workspace_view.panes[pane_key]
	control.begin_header_drag(control.layout_rect().position + Vector2(20, 10))
	control._drag_to(point, Vector2(20, 0))
	check(app.drag.get("session_drop", {}).get("session", "") == original, "Pane drag reaches its own window's sessions sidebar")
	app.cancel_drag()
	control._cancel_drag()
	var strip: Control = source.workspace_view.tab_bar.tabs
	app.begin_drag(source, strip, source.workspace_layout.active)
	app.update_drag(point)
	check(app.drag.get("session_drop", {}).get("session", "") == original, "Tab drag reaches the sessions sidebar")
	app.cancel_drag()

	state = {"source": source, "id": source.workspace_layout.containing(pane_key), "kind": "pane", "pane": pane_key, "keys": [pane_key], "session_drop": {"session": ""}}
	await SessionDrag.commit(app, state, null)
	target = null
	for candidate in app.session_hosts():
		if candidate != source: target = candidate
	check(is_instance_valid(target) and target.sessions.has(pane), "Pane drop creates a session with the carried pane")
	if is_instance_valid(target) and target.sessions.has(pane):
		check(await wait_for(func(): return target.get_parent().connection.connected), "Pane destination attaches")
		check(target.sessions[pane].term.get_shell_pid() == pane_pid and source.sessions.has(first), "Pane transfer preserves both running processes")
		check(renders(target.sessions[pane].vp), "Pane moved into a new session renders there")
		state = {"source": target, "id": target.workspace_layout.containing(pane_key), "kind": "pane", "pane": pane_key, "session_drop": {"session": original}}
		await SessionDrag.commit(app, state, wrapper)
		check(await wait_for(func(): return source.sessions.has(pane)), "Pane can move to an existing session")
		if source.sessions.has(pane): check(renders(source.sessions[pane].vp), "Pane moved into an existing session renders there")
	# Hovering an unattached session opens only a frontend; cancelling closes
	# that preview without touching the remote session or its shell.
	var created_session: Dictionary = await wrapper.connection.request_action("session_new", {"name": "hover-target"})
	check(created_session.get("type") != "error", "Hover target session created")
	var hover_session: String = wrapper.connection.workspace
	await wrapper.connection.request_action("session_switch", {"name": original})
	await process_frame
	app.mods._publish_sessions()
	for i in 10: await process_frame
	row = panel.view.hit_rect("session-%s-%s" % [wrapper.connection.url, hover_session])
	check(row.has_area(), "Hover destination has a session row")
	point = preload("res://scenes/ScreenSpace.gd").of(panel.view, row.get_center())
	app.begin_pane_drag(source, source.workspace_view.panes[pane_key], pane_key)
	app.update_drag(point)
	app.drag.hover_ready = true
	app.update_drag(point)
	var preview: Node
	for candidate in get_nodes_in_group("shared_presentations"):
		if str(candidate.settings.get("workspace", candidate.settings.get("initial_session", ""))) == hover_session: preview = candidate
	check(is_instance_valid(preview) and not is_instance_valid(preview.host) and source in app.hosts and not app.desktop_presentation(wrapper).parked, "The current session stays on screen while the held one connects")
	check(await wait_for(func(): return is_instance_valid(preview.host)), "Holding a session can reveal its tabs")
	check(preview.get_window() == root, "Hover reveals the session in the current window")
	check(await wait_for(func(): return app.desktop_presentation(wrapper).parked) and preview.host in app.hosts, "Hover swaps to the held session and retains the source as a parked presentation")
	app.mods._publish_sessions()
	var shown: Array = []
	for group in app.mods.get_meta(&"session_groups", []):
		for listed in group.sessions:
			if listed.viewing: shown.append(listed.id)
	check(shown == [hover_session], "Only the held session is marked as on screen")
	check(not app.drag.is_empty(), "Drag remains active after revealing the destination")
	var destination_bar: Control = preview.host.workspace_view.tab_bar.tabs
	app.update_drag(preload("res://scenes/ScreenSpace.gd").of(destination_bar, destination_bar.size * .5))
	check(app.drag.get("target") == preview.host, "Carried pane can continue into the revealed session")
	app.cancel_drag()
	check(not app.desktop_presentation(wrapper).parked and source in app.hosts, "Cancelling restores the original view")
	await process_frame
	await wrapper.connection.request_action("sync")
	check(wrapper.connection.available_sessions.any(func(row): return str(row.id) == hover_session), "Cancelling preview preserves server session")
	app.mods._publish_sessions()
	var viewing := 0
	for group in app.mods.get_meta(&"session_groups", []):
		for listed in group.sessions:
			if listed.viewing: viewing += 1
	check(viewing == 1, "A session held during a drag is not left marked as on screen")
	# Dropping on a held session carries one pane out of a split tab, although
	# the hold already took the source view off screen.
	split = await wrapper.connection.request_action("create", {"kind": "pane", "session": first})
	var carried: int = int(split.created)
	var carried_key := "%%%d" % carried
	check(await wait_for(func(): return source.sessions.has(carried) and source.workspace_view.panes.has(carried_key)), "Second split pane is presented")
	var carried_pid: int = source.sessions[carried].term.get_shell_pid()
	source.select_workspace(source.workspace_layout.containing(carried_key), true)
	for i in 10: await process_frame
	row = panel.view.hit_rect("session-%s-%s" % [wrapper.connection.url, hover_session])
	point = preload("res://scenes/ScreenSpace.gd").of(panel.view, row.get_center())
	app.begin_pane_drag(source, source.workspace_view.panes[carried_key], carried_key)
	app.update_drag(point)
	app.drag.hover_ready = true
	app.update_drag(point)
	check(await wait_for(func(): return app.desktop_presentation(wrapper).parked), "Holding again reveals the retained session")
	# The preview already shows the destination, so the drop must not play a
	# tab-switch flight there. Watch every frame from release until it lands.
	var flights := [0]
	var overdrawn := [0]
	var watch := func():
		if is_instance_valid(preview) and is_instance_valid(preview.host) and is_instance_valid(preview.host.world):
			var world: Node = preview.host.world
			if is_instance_valid(world.get("_transition_out")) or is_instance_valid(world.get("_transition_in")): flights[0] += 1
		# The source the preview replaced must stay hidden behind it.
		if is_instance_valid(source) and source.layout_root.is_visible_in_tree(): overdrawn[0] += 1
	process_frame.connect(watch)
	app.finish_drag(point)
	check(await wait_for(func(): return is_instance_valid(preview) and is_instance_valid(preview.host) and preview.host.sessions.has(carried)), "Dropping on a held session moves the pane there")
	for i in 30: await process_frame
	process_frame.disconnect(watch)
	check(flights[0] == 0, "Dropping on the previewed session lands without a tab-switch flight (%d frames)" % flights[0])
	check(overdrawn[0] == 0, "The parked source never draws over the previewed destination (%d frames)" % overdrawn[0])
	if is_instance_valid(preview) and is_instance_valid(preview.host) and preview.host.sessions.has(carried):
		check(preview.host.sessions[carried].term.get_shell_pid() == carried_pid, "Held-session drop retains the live shell PID")
		check(preview.host in app.hosts and not app.desktop_presentation(preview).parked, "Held-session drop leaves the destination on screen")
		# The preview parked the source; its paused render state must not travel
		# with the pane, or the pane keeps showing stale texture memory.
		check(renders(preview.host.sessions[carried].vp), "Pane dropped on the previewed session renders there")
	check(source.sessions.has(first) and not source.sessions.has(carried), "Held-session drop leaves the rest of the split tab behind")
	for client in get_nodes_in_group("shared_presentations"):
		client.connection.disconnect_remote()
	await create_timer(.3).timeout
	print("SESSION_PANEL_TRANSFER_%s" % ("PASS" if failures.is_empty() else "FAIL"))
	quit(0 if failures.is_empty() else 1)
