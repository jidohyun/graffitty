extends SceneTree
## Real CLI and menu switches through local IPC and Android's remote manager.
var failures: Array[String] = []
var client: Node
var peer: Node
var cli := OS.get_environment("GRAFFITTY_BIN")

func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	print("[session switch] %s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures.append(message)
func until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 12000
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()
func record(id: String) -> Dictionary:
	for item in peer.available_sessions:
		if item.id == id: return item
	return {}
func current_name() -> String:
	return str(record(peer.workspace).get("name", ""))
func menu_names(host: Node) -> Array:
	return host.menu_entries.filter(func(e): return str(e.label).begins_with("Sessions::Switch Session::")).map(func(e): return str(e.label).get_slice("::", 2).get_slice("  $", 0))

func navigate(host: Node, center: Vector2, zoom: float) -> void:
	host.workspace_view.overview = true
	host.workspace_view.navigation_zoom = zoom
	host.workspace_view.navigation_center = center + host.workspace_view.inset_shift / zoom
	host.workspace_view._apply_navigation()

func at_view(host: Node, center: Vector2, zoom: float) -> bool:
	var view: Control = host.workspace_view
	return view.overview and is_equal_approx(view.navigation_zoom, zoom) and (
		view.navigation_center - view.inset_shift / zoom).distance_to(center) < 0.01

func run() -> void:
	root.size = Vector2i(500, 850)
	var manager: Node
	if OS.get_cmdline_user_args().has("--touch-controls"):
		manager = preload("res://scenes/remote/RemoteManager.gd").new()
		root.add_child(manager)
		var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_SERVER_DESCRIPTOR")))
		var settings: Dictionary = descriptor.remote.duplicate()
		settings.initial_session = "$1"
		manager.view.settings.startup_world = "flat-2d"
		settings.name = "Switch fixture"
		peer = manager.open_connection(settings)
		client = manager.view
	else:
		client = preload("res://scenes/SharedWorkspace.gd").new()
		client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session", "--plugin=flat-2d"])
		root.add_child(client)
		peer = client.connection
	if not await until(func(): return client.host != null and client.host.sessions.size() > 0):
		printerr("Session attachment failed")
		quit(1)
		return
	var host: Node = client.host
	if manager != null: manager._return_to_workspace()
	var window := host.get_window()
	var keybar: Node = host.touch_keybar
	var initial_tab: int = host.workspace_layout.active
	host.create_session()
	check(await until(func(): return host.get_tabs().size() == 2 and host.workspace_layout.active != initial_tab), "original session selects its second tab")
	var alpha: int = host.active_session_id
	var alpha_id: String = peer.workspace
	var alpha_pid: int = host.sessions[alpha].term.get_shell_pid()
	check(await until(func(): return menu_names(host) == ["alpha", "beta"]), "menu lists named sessions with IDs")
	var alpha_center := Vector2(-230, 415)
	var beta_center := Vector2(740, -125)
	navigate(host, alpha_center, 0.63)
	var command := "'%s' session attach -t beta; printf 'ATTACH_DONE_%%s\\n' OK\n" % cli.replace("'", "'\\''")
	if OS.get_name() == "Windows": command = "& '%s' session attach -t beta; Write-Output ('ATTACH_DONE_' + 'OK')\r" % cli.replace("'", "''")
	peer.send_input(alpha, command.to_utf8_buffer())
	check(await until(func(): return current_name() == "beta" and not host.sessions.has(alpha)), "CLI attach resolves a name and switches in place")
	check(client.host == host and host.get_window() == window, "host and window survive switch")
	check(manager == null or host.touch_keybar == keybar, "Android keyboard bar survives switch")
	var beta: int = host.active_session_id
	check(beta != alpha and host.sessions.has(beta), "target session gets focus")
	check(not host.workspace_view.overview, "first visit to another session starts at Main View")
	navigate(host, beta_center, 1.37)
	var failed: Dictionary = await peer.request_action("session_switch", {"name": "missing"})
	check(failed.type == "error" and current_name() == "beta", "missing session leaves the presentation intact")
	check(at_view(host, beta_center, 1.37), "failed switch preserves the current viewport")
	await peer.request_action("session_switch", {"name": alpha_id})
	check(await until(func(): return peer.workspace == alpha_id and host.active_session_id == alpha), "stable ID selects original session")
	check(at_view(host, alpha_center, 0.63), "returning restores the original session's pan and zoom")
	check(host.workspace_layout.active != initial_tab, "returning restores the second tab instead of resetting to tab one")
	check(host.sessions[alpha].term.get_shell_pid() == alpha_pid, "original PTY survives switches")
	check(await until(func(): return "ATTACH_DONE_OK" in str(host.sessions[alpha].term.get_text(false).get("text", ""))), "CLI completes in original shell")
	for entry in host.menu_entries:
		if entry.label == "Sessions::New Session":
			host._run_menu_action(entry)
			break
	check(await until(func(): return peer.workspace != alpha_id), "New Session creates immediately with no naming dialog")
	var new_id: String = peer.workspace
	check(await until(func(): return record(new_id).has("name") and peer.topology.get("workspace") == new_id and not peer.topology.tabs.is_empty() and host.active_session_id == int(peer.topology.tabs[0].id)), "new session has metadata and its view is ready")
	check(not host.workspace_view.overview, "new session does not inherit the previous viewport")
	check(record(new_id).name == null, "new session starts with an automatic name")
	var renamed: Dictionary = await peer.request_action("session_rename", {"name":new_id, "new_name":"from-menu"})
	check(renamed.get("type") != "error", "rename accepted")
	check(await until(func(): return current_name() == "from-menu"), "renamed label reaches the client")
	check(peer.workspace == new_id, "renaming preserves session identity")
	await peer.request_action("session_rename", {"name":new_id, "new_name":""})
	check(await until(func(): return record(new_id).get("name") == null), "clearing custom name restores automatic naming")
	await peer.request_action("session_switch", {"name":alpha_id})
	check(await until(func(): return host.sessions.has(alpha) and host.active_session_id == alpha), "original session remains attachable")
	check(at_view(host, alpha_center, 0.63), "viewport survives creating and leaving a third session")
	check(host.sessions[alpha].term.get_shell_pid() == alpha_pid, "creation and rename preserve original PTY")
	var output := []
	# OS.execute uses shell quoting on Unix; use the exact numeric default
	# name here so a dollar ID is not interpreted as a shell parameter.
	check(OS.execute(cli, ["session", "kill", "-t", "=" + new_id.substr(1)], output, true) == 0, "remove temporary unnamed session: " + str(output))
	host.prefix_commands.toggle()
	var selector := InputEventKey.new()
	selector.pressed = true
	selector.keycode = KEY_DOLLAR
	selector.unicode = 36
	check(host.prefix_commands.handle(selector) and host.command_line_open(), "prefix dollar opens session navigation")
	host.command_line.line.text = "$beta"
	host.command_line.line.text_changed.emit("$beta")
	host.command_line._accept()
	check(await until(func(): return current_name() == "beta" and host.active_session_id == beta), "session selector finds a name but targets its ID")
	check(at_view(host, beta_center, 1.37), "session selector restores the other session's distinct viewport")
	var report := OS.get_environment("GRAFFITTY_TEST_REPORT")
	if not report.is_empty():
		var file := FileAccess.open(report, FileAccess.WRITE)
		file.store_string(JSON.stringify({"failures": failures}))
	print("LIVE_SESSION_SWITCH_PASS" if failures.is_empty() else "LIVE_SESSION_SWITCH_FAIL")
	quit(0 if failures.is_empty() else 1)
