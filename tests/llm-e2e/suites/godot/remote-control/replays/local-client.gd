extends "../../../../replay/replay.gd"


func android_client() -> bool:
	return false


func client_needs_window() -> bool:
	return false


func client_script() -> String:
	return "res://tests/remote_client_e2e.gd"


func play() -> void:
	await labelled_tabs(["DESKTOP", "REMOTE"])
	var desktop_tab: int = host.workspace_layout.tabs[0].id
	host.select_workspace(desktop_tab)
	await hold(.2)
	var focused: String = host.pane_focus
	var graph: Node = app.agent_api.graph
	var source := focused
	var created: Dictionary = await host.session_backend.connection.request_action("create", {"kind":"pane", "session":int(source.substr(1))})
	var target_node := "%%%d" % int(created.created)
	await owner_at_rest()
	host.focus_pane(focused)
	for key in [source, target_node]:
		await graph.dispatch(int(key.substr(1)), "agent.event", {"kind": "custom", "event": "SessionStart"})
		await graph.dispatch(int(key.substr(1)), "agent.register", {"name": "Remote graph fixture", "inputs": [{"id": "in"}], "outputs": [{"id": "out"}]})
	var linked: Dictionary = await graph.dispatch(int(source.substr(1)), "graph.connect", {"from": source, "from_port": "out", "to": target_node, "to_port": "in", "send": true})
	check(not linked.has("error"), "Create server graph connection: %s" % linked)
	var pids := { }
	for id in host.sessions:
		pids[id] = host.sessions[id].term.get_shell_pid()
		host.resource_monitor_for(id).set_interval(0.1)
	var server = load("res://scenes/remote/RemoteAccessControl.gd").new()
	app.add_child(server)
	var directory := OS.get_environment("XDG_STATE_HOME").path_join("remote-e2e-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(directory)
	var descriptor := directory.path_join("connection.json")
	var result_path := directory.path_join("result.json")
	var started := false
	for attempt in 20:
		if await server.start(
			app,
			"127.0.0.1",
			22000 + (OS.get_process_id() % 20000) + attempt,
			descriptor,
		) == OK:
			started = true
			break
	check(started, "Start opt-in remote endpoint")
	if not started:
		return
	await owner_at_rest()
	check(host.workspace_layout.active == desktop_tab and host.pane_focus == focused,
		"Desktop focus is settled before launching the remote client: tab=%d pane=%s expected=%d/%s" % [host.workspace_layout.active, host.pane_focus, desktop_tab, focused])
	var child_args: PackedStringArray = [
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--script",
		client_script(),
		"--",
		"--remote-connection=" + descriptor,
		"--result=" + result_path,
	]
	if client_needs_window() or OS.get_environment("GRAFFITTY_E2E_HEADFUL") == "1":
		child_args.erase("--headless")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--remote-movie="):
			child_args.erase("--headless")
			child_args.insert(0, "--fixed-fps")
			child_args.insert(1, "30")
			child_args.insert(2, "--write-movie")
			child_args.insert(3, arg.trim_prefix("--remote-movie="))
		if arg.begins_with("--remote-capture="):
			child_args.erase("--headless")
			child_args.append("--capture=" + arg.trim_prefix("--remote-capture="))
	if not "--headless" in child_args:
		child_args = Background.rendering_arguments() + child_args
	if android_client(): child_args.append("--touch-controls")
	var child := Background.create_godot_process(child_args)
	create_timer(2.0).timeout.connect(func():
		graph.dispatch(int(source.substr(1)), "agent.event", {"kind": "custom", "event": "UserPromptSubmit"})
	)
	check(child > 0, "Launch separate Godot client process")
	var deadline := Time.get_ticks_msec() + 65000
	while not FileAccess.file_exists(result_path) and Time.get_ticks_msec() < deadline:
		await wait(.1)
		if host.workspace_layout.active != desktop_tab or host.pane_focus != focused:
			check(false, "Remote client changed desktop tab or focus: tab=%d pane=%s expected=%d/%s" % [host.workspace_layout.active, host.pane_focus, desktop_tab, focused])
		if not failures.is_empty():
			break
	if not FileAccess.file_exists(result_path):
		check(false, "Remote client completes before timeout")
		OS.kill(child)
	else:
		var result: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(result_path))
		check(result.failures.is_empty(), "Client E2E: " + str(result.failures))
		var target := int(result.target)
		if host.sessions.has(target) and result.get("verify_terminal_commands", true):
			var owned: Array = host.session_backend.connection.topology.panes.filter(func(pane): return int(pane.id) == target)
			check(
				not owned.is_empty() and Vector2i(int(owned[0].columns), int(owned[0].rows)) == Vector2i(65, 18),
				"Server uses client's explicit shared size",
			)
			var retained := {}
			var received := func(id, text):
				if id == target: retained.text = text
			host.session_backend.connection.history_received.connect(received)
			host.session_backend.connection.send_action("history", target)
			var history_deadline := Time.get_ticks_msec() + 3000
			while not retained.has("text") and Time.get_ticks_msec() < history_deadline: await process_frame
			host.session_backend.connection.history_received.disconnect(received)
			check(
				"WHILE_DETACHED" in str(retained.get("text", "")),
				"Output remains on server after client detaches",
			)
	check(
		host.workspace_layout.active == desktop_tab and host.pane_focus == focused,
		"Remote client leaves desktop tab and focus unchanged",
	)
	for id in pids:
		check(
			host.sessions[id].term.get_shell_pid() == pids[id],
			"Remote control preserves server PTY",
		)
	await server.stop()
	server.queue_free()
