extends SceneTree
## A real owner and two native clients. Drop one client's TCP traffic without
## closing its socket, suspend its polling, then require automatic recovery.
const TestServer := preload("res://tests/support/TestServer.gd")
var directory := ""
var server_pid := -1
var server_port := 0
var relay := TCPServer.new()
var links: Array[Dictionary] = []
var clients: Array[Node] = []
var failures := 0
var offline := false

class CountedViews extends "res://scenes/remote/RemoteViewState.gd":
	var writes := 0
	func _save() -> void:
		writes += 1
		super._save()

class ErrorWatch extends Logger:
	var errors: Array[String] = []
	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _notify: bool, type: int, _traces: Array[ScriptBacktrace]) -> void:
		if type != ERROR_TYPE_WARNING:
			errors.append("%s:%d %s" % [file, line, rationale if not rationale.is_empty() else code])
	func _log_message(_message: String, _error: bool) -> void: pass

var errors := ErrorWatch.new()

func _initialize() -> void:
	OS.add_logger(errors)
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "1")
	directory = TestServer.prepare("graffitty-resume")
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, directory.path_join(kind.to_lower()))
	run.call_deferred()

func check(ok: bool, message: String) -> bool:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
	return ok

func until(predicate: Callable, seconds := 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not predicate.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.02).timeout
	return predicate.call()

func _process(_dt: float) -> bool:
	if relay.is_listening() and relay.is_connection_available():
		var upstream := StreamPeerTCP.new()
		upstream.connect_to_host("127.0.0.1", server_port)
		links.append({"client": relay.take_connection(), "server": upstream, "drop": false})
	for link in links:
		for pair in [[link.client, link.server], [link.server, link.client]]:
			var source: StreamPeerTCP = pair[0]
			var destination: StreamPeerTCP = pair[1]
			source.poll()
			destination.poll()
			if source.get_status() != StreamPeerTCP.STATUS_CONNECTED or destination.get_status() != StreamPeerTCP.STATUS_CONNECTED: continue
			var available := source.get_available_bytes()
			if available == 0: continue
			var packet := source.get_data(available)
			if packet[0] == OK and not link.drop: destination.put_data(packet[1])
	return false

func attach(url: String, password: String, terminal: Control) -> Node:
	var connection := preload("res://scenes/remote/RemoteConnection.gd").new()
	root.add_child(connection)
	clients.append(connection)
	connection.changed.connect(func():
		if not connection.topology.panes.is_empty():
			connection.subscribe([int(connection.topology.panes[0].id)]))
	connection.terminal_received.connect(func(_id, header, _data):
		if header.has("native"): terminal.remote_apply_scene(header.native))
	connection.connect_remote(url, password)
	return connection

func text(terminal: Control) -> String:
	return str(terminal.get_text(true).get("text", ""))

func run() -> void:
	var binary := OS.get_environment("GRAFFITTY_TEST_SERVER")
	if binary.is_empty(): binary = ProjectSettings.globalize_path("res://../../../target/debug/gft")
	var password := "test-only resume password"
	var auth: RefCounted = ClassDB.instantiate("RemoteAuth")
	var saved: Dictionary = JSON.parse_string(auth.save_settings(directory.path_join("auth.json"), password, false, "", "", 6))
	if not check(saved.get("ok", false), "Register isolated server password"):
		finish()
		return
	var descriptor_path := directory.path_join("connection.json")
	server_pid = OS.create_process(binary, ["server", "--listen", "127.0.0.1:0", "--connection", descriptor_path, "--auth-file", directory.path_join("auth.json"), "--shell", OS.get_environment("GRAFFITTY_TEST_SHELL") if OS.has_environment("GRAFFITTY_TEST_SHELL") else "/bin/sh"])
	if not check(await until(func(): return FileAccess.file_exists(descriptor_path)), "Isolated owner starts"):
		finish()
		return
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(descriptor_path))
	server_port = str(descriptor.url).get_slice(":", 2).to_int()
	if not check(relay.listen(0, "127.0.0.1") == OK, "Fault-injection relay starts"):
		finish()
		return
	var resumed: Control = ClassDB.instantiate("Terminal")
	var desktop: Control = ClassDB.instantiate("Terminal")
	for terminal in [resumed, desktop]:
		terminal.remote_mode = true
		terminal.size = Vector2(800, 500)
		root.add_child(terminal)
	var mobile := attach("ws://127.0.0.1:%d" % relay.get_local_port(), password, resumed)
	var observer := attach(descriptor.url, password, desktop)
	check(await until(func(): return mobile.connected and observer.connected), "Server-only sign-in succeeds with no sessions")
	await create_timer(.2).timeout
	check(mobile.workspace.is_empty() and mobile.available_sessions.is_empty() and mobile.topology.panes.is_empty(), "Connecting never creates or selects a nonexistent session")
	await check_empty_desktop(descriptor.url, password)
	var created: Dictionary = await mobile.request_action("session_new", {})
	check(created.get("type") == "ack", "Explicit New Session creates the first terminal after authentication")
	mobile.state_changed.connect(func(message):
		if message.begins_with("Offline"): offline = true)
	if not check(await until(func(): return mobile.connected and observer.connected and not mobile.topology.panes.is_empty()), "Both clients authenticate to the same live owner"):
		finish()
		return
	var pane := int(mobile.topology.panes[0].id)
	var shell_pid := int(mobile.topology.panes[0].pid)
	mobile.send_input(pane, "printf 'BEFORE_%s\\n' resume\r".to_utf8_buffer())
	if not check(await until(func(): return "BEFORE_resume" in text(resumed) and "BEFORE_resume" in text(desktop)), "Typing updates both terminal replicas"):
		finish()
		return
	mobile.send_input(pane, "sleep 1; printf 'BACKGROUND_%s\\n' ready\r".to_utf8_buffer())
	await create_timer(0.2).timeout
	var old_socket: RefCounted = mobile.socket
	links[0].drop = true
	mobile.set_process(false)
	await create_timer(6.0).timeout
	check(observer.connected and "BACKGROUND_ready" in text(desktop), "The desktop client and shell stay healthy during the mobile outage")
	check(old_socket.get_ready_state() == WebSocketPeer.STATE_OPEN and not "BACKGROUND_ready" in text(resumed), "Suspended client reproduces an open socket with frozen terminal text")
	mobile.send_input(pane, "printf 'LOST_%s\\n' input\r".to_utf8_buffer())
	mobile.set_process(true)
	if not check(await until(func(): return offline and mobile.connected and mobile.socket != old_socket and "BACKGROUND_ready" in text(resumed)), "Heartbeat reports offline, reconnects and restores the terminal snapshot"):
		finish()
		return
	check(int(mobile.topology.panes[0].pid) == shell_pid and mobile.subscriptions == [pane], "Reconnect retains the original PTY and subscriptions")
	mobile.send_input(pane, "printf 'AFTER_%s\\n' resume\r".to_utf8_buffer())
	check(await until(func(): return "AFTER_resume" in text(resumed) and "AFTER_resume" in text(desktop)), "New typing reaches the server after automatic recovery")
	check(text(resumed).count("AFTER_resume") == 1 and not "LOST_input" in text(resumed), "Recovery does not duplicate or replay uncertain input")
	await check_view_restore(descriptor.url, password)
	var closed: String = mobile.workspace
	var channel: RefCounted = mobile.socket
	var removed: Dictionary = await observer.request_action("session_kill", {"name": closed})
	check(removed.get("type") == "ack", "Closing the selected session is acknowledged")
	check(await until(func(): return mobile.workspace.is_empty() and observer.workspace.is_empty() and mobile.available_sessions.is_empty()), "Session removal clears both views and updates the server inventory")
	check(mobile.connected and observer.connected and mobile.socket == channel and OS.is_process_running(server_pid), "Last-session closure preserves the server and authenticated channels")
	var recreated: Dictionary = await observer.request_action("session_new", {})
	check(recreated.get("type") == "ack" and await until(func(): return not mobile.workspace.is_empty() and not mobile.topology.panes.is_empty()), "A connected client can create and discover a new session without signing in again")
	check(mobile.workspace != closed, "A stale view preference never revives the closed session")
	finish()

func check_empty_desktop(url: String, password: String) -> void:
	var first := preload("res://scenes/remote/RemoteClient.gd").new()
	first.managed = true
	first.settings = {"url": url, "token": password, "transient": true, "startup_world": "flat-2d"}
	root.add_child(first)
	check(await until(func(): return first.connection.connected), "Desktop connects to a server with no sessions")
	check(first.host == null, "An empty server has no invented workspace")
	var app: Node = root.get_node("TerminalApplication")
	var second: Node = app.open_remote_server(first, first.settings)
	check(await until(func(): return second.connection.connected), "Desktop can open another connection after an empty server")
	check(first.connection.connected and app.desktop_presentation(first).parked, "Parking an empty server preserves its authentication")
	app.present_desktop_client(first)
	check(first.connection.connected and second.connection.connected and app.desktop_presentation(second).parked, "Returning to the empty server keeps both connections alive")
	for item in [first, second]:
		app.desktop_presentations.erase(app.desktop_presentation(item))
		item.connection.disconnect_remote()
		item.queue_free()
	await process_frame

func check_view_restore(url: String, password: String) -> void:
	var manager := preload("res://scenes/remote/RemoteManager.gd").new()
	manager.view_state = CountedViews.new()
	root.add_child(manager)
	manager.view.settings.startup_world = "flat-2d"
	var settings := {"url": url, "token": password, "transient": true}
	var key: String = manager._connection_key(settings)
	manager.open_when_ready = key
	var transport: Node = manager.open_connection(settings)
	if not check(await until(func(): return manager.view.host != null and not manager.chooser.visible), "Production server chooser opens the connected workspace"):
		manager.free()
		return
	var reply: Dictionary = await transport.request_action("create", {"kind": "tab"})
	var target := int(reply.get("created", -1))
	if not check(target >= 0 and await until(func(): return manager.view.host.workspace_layout.active == target), "Client selects a second tab"):
		manager.free()
		return
	var wire: int = transport.wire_id(target)
	var host: Node = manager.view.host
	var view: Control = host.workspace_view
	await check_action_saves(manager, transport)
	view.overview = true
	view.navigation_center = Vector2(-250, 1200)
	view.navigation_zoom = 0.63
	view._apply_navigation()
	manager._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var saved_path: String = manager.view_state.path
	check(FileAccess.file_exists(saved_path), "Android pause persists client navigation before process eviction")
	manager._show_chooser()
	manager._open_workspace(key)
	check(host.workspace_layout.active == target and view.overview and view.navigation_center == Vector2(-250, 1200) and is_equal_approx(view.navigation_zoom, 0.63), "Returning through the chooser preserves the second tab and camera")
	manager.keybar.show()
	manager._disconnect(key)
	manager.open_when_ready = key
	transport = manager.open_connection(settings)
	if not check(await until(func(): return manager.view.host != null and not manager.chooser.visible), "Explicit reconnect rebuilds the client workspace"):
		manager.free()
		return
	host = manager.view.host
	view = host.workspace_view
	check(manager.get_children().filter(func(child): return child.get_script() == preload("res://scenes/input/TouchKeyBar.gd")).size() == 1, "Reconnect replaces the old keyboard controls instead of leaving a displaced, unresponsive bar")
	check(transport.wire_id(host.workspace_layout.active) == wire and host.workspace_layout.active == target, "Reconnect restores the selected owner tab with stable client IDs")
	check(view.overview and view.navigation_center == Vector2(-250, 1200) and is_equal_approx(view.navigation_zoom, 0.63), "Rebuilt host restores the saved pan and zoom")
	manager._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	manager._disconnect(key)
	manager.free()
	await process_frame
	# A fresh manager and preference object exercise the same disk path used by
	# a new Android process, without copying any in-memory navigation state.
	root.get_node("TerminalApplication").remote_identity_maps.clear()
	manager = preload("res://scenes/remote/RemoteManager.gd").new()
	root.add_child(manager)
	manager.view.settings.startup_world = "flat-2d"
	manager.open_when_ready = key
	transport = manager.open_connection(settings)
	if check(await until(func(): return manager.view.host != null and not manager.chooser.visible), "Fresh manager reconnects using persisted view state"):
		host = manager.view.host
		view = host.workspace_view
		check(transport.wire_id(host.workspace_layout.active) == wire and host.workspace_layout.active != target and view.overview and view.navigation_center == Vector2(-250, 1200) and is_equal_approx(view.navigation_zoom, 0.63), "Disk restore retains the selected tab and exact browsing view")
	manager._disconnect(key)
	manager.free()
	await process_frame

func check_action_saves(manager: Control, transport: Node) -> void:
	var host: Node = manager.view.host
	var view: Control = host.workspace_view
	# Headless windows are hidden: run gesture deadlines and navigation tweens
	# for this interaction fixture even though presentation is suspended.
	var previous_mode: int = view.process_mode
	view.process_mode = Node.PROCESS_MODE_ALWAYS
	await create_timer(0.8).timeout
	var before: int = manager.view_state.writes
	view._navigation_drag = true
	for step in 8:
		view.pan_workspace(Vector2(5, 2), view.size * 0.5)
		await create_timer(0.08).timeout
	check(manager.view_state.writes == before, "Continuous panning never writes on input or animation frames")
	await create_timer(0.6).timeout
	check(manager.view_state.writes == before, "Pausing while holding a drag does not save mid-action")
	view._cancel_navigation_drag()
	check(await until(func(): return manager.view_state.writes == before + 1, 2.0), "Ending a pan saves once without leaving the workspace")
	var saved := preload("res://scenes/remote/RemoteViewState.gd").new(manager.view_state.path)
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).duplicate(true)
	var navigation: Dictionary = group.navigation.duplicate(true)
	group.erase("navigation")
	saved.restore_tab(transport, group)
	check(group.get("navigation") == navigation, "Action save contains the final pan position on disk")
	for step in 3:
		view.save_navigation()
		host.ui_changed.emit()
		await create_timer(0.1).timeout
	await create_timer(0.6).timeout
	check(manager.view_state.writes == before + 1, "Unchanged navigation and UI refreshes do not rewrite disk")
	before = manager.view_state.writes
	var gestures: RefCounted = view.mobile_pointer.gestures
	var touch := InputEventScreenTouch.new()
	touch.pressed = true
	touch.position = Vector2(200, 250)
	gestures.handle(touch, Time.get_ticks_msec())
	touch.index = 1
	touch.position = Vector2(400, 250)
	gestures.handle(touch, Time.get_ticks_msec())
	var motion := InputEventScreenDrag.new()
	motion.index = 1
	motion.position = Vector2(500, 300)
	gestures.handle(motion, Time.get_ticks_msec())
	await create_timer(0.6).timeout
	check(manager.view_state.writes == before, "Stationary pinch contacts keep the navigation action open")
	touch.pressed = false
	gestures.handle(touch, Time.get_ticks_msec())
	await create_timer(0.5).timeout
	check(manager.view_state.writes == before, "Lifting one pinch finger cannot save before the survivor finishes")
	touch.index = 0
	gestures.handle(touch, Time.get_ticks_msec())
	check(await until(func(): return manager.view_state.writes == before + 1, 2.0), "Releasing the last pinch finger saves the completed view once")
	before = manager.view_state.writes
	view._animate_inspection(view.navigation_center + Vector2(80, 40), 0.7, false)
	await create_timer(0.15).timeout
	check(manager.view_state.writes == before, "Fit animation does not save intermediate frames")
	check(await until(func(): return manager.view_state.writes == before + 1, 2.0), "Completed fit animation saves once")
	before = manager.view_state.writes
	view.zoom_workspace(0.9, view.size * 0.5)
	manager._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(manager.view_state.writes == before + 1, "Backgrounding flushes a pending action save immediately")
	await create_timer(0.6).timeout
	check(manager.view_state.writes == before + 1 and manager._view_save_timer.is_stopped(), "Lifecycle flush cancels the delayed write")
	view.process_mode = previous_mode

func finish() -> void:
	for client in clients:
		client.disconnect_remote()
		client.free()
	clients.clear()
	for link in links:
		link.client.disconnect_from_host()
		link.server.disconnect_from_host()
	links.clear()
	relay.stop()
	for error in errors.errors: check(false, error)
	TestServer.stop(server_pid, directory, failures > 0)
	print("REMOTE_RESUME_PASS" if failures == 0 else "REMOTE_RESUME_FAIL: " + directory)
	quit.call_deferred(0 if failures == 0 else 1)
