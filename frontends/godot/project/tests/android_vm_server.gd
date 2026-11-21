extends "../../../../tests/llm-e2e/replay/replay.gd"
## Isolated desktop fixture shared by the actual APK scenarios. Loopback only.
func play() -> void:
	var directory := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fixture="): directory = arg.trim_prefix("--fixture=")
	if not check(not directory.is_empty(), "Fixture directory supplied"): return
	await labelled_tabs(["DESKTOP", "REMOTE"])
	# A focused pane supplies an unpinned tab title. Pin these fixture names
	# so adding/focusing the graph peer does not change the tab-name contract.
	for index in 2:
		var tab_id := int(host.workspace_layout.tabs[index].id)
		await app.agent_api.dispatch(tab_id, "tab.set_title", {"id": tab_id, "title": ["DESKTOP", "REMOTE"][index]})
	await owner_at_rest()
	host.select_workspace(int(host.workspace_layout.tabs[0].id))
	await hold(.2)
	# Graph edges stay within a tab. Keep the independent REMOTE tab for
	# focus-isolation checks, and connect two panes inside DESKTOP.
	var before: Array = host.sessions.keys()
	host.create_terminal_window(host.pane_focus, "h")
	await owner_at_rest()
	var target := ""
	for id in host.sessions:
		if id not in before: target = "%%%d" % id
	if not check(not target.is_empty(), "Graph fixture creates a same-tab peer"): return
	var active: int = host.workspace_layout.active
	var focused: String = host.pane_focus
	var graph: Node = app.agent_api.graph
	var source := "%%%d" % int(host.workspace_layout.tabs[0].id)
	for key in [source, target]:
		var id := int(key.substr(1))
		await graph.dispatch(id, "agent.event", {"kind": "custom", "event": "SessionStart"})
		await graph.dispatch(id, "agent.register", {"name": "Android fixture", "inputs": [{"id": "in"}], "outputs": [{"id": "send", "mode": "send"}]})
	var connected: Dictionary = await graph.dispatch(int(source.substr(1)), "graph.connect", {"from": source, "to": target, "from_port": "send", "to_port": "in"})
	check(not connected.has("error"), "Graph fixture connected: " + str(connected.get("error", "ok")))
	var pids := {}
	for id in host.sessions:
		pids[id] = host.sessions[id].term.get_shell_pid()
		host.resource_monitor_for(id).set_interval(.1)
	for id in host.sessions:
		host.sessions[id].term.send_text("printf '\\033[2J\\033[H\\033_Ga=T,f=32,s=2,v=1,i=9001,p=1,c=4,r=2,q=2;/wAA/wD/AP8=\\033\\\\'\r")
	await hold(.3)
	var server = load("res://scenes/remote/RemoteAccessControl.gd").new()
	app.add_child(server)
	var started := false
	for attempt in 20:
		if await server.start(app, "127.0.0.1", 22000 + OS.get_process_id() % 20000 + attempt, directory.path_join("connection.json")) == OK:
			started = true
			break
	if not check(started, "Loopback remote fixture started"): return
	create_timer(2.0).timeout.connect(func():
		graph.dispatch(int(source.substr(1)), "agent.event", {"kind": "custom", "event": "UserPromptSubmit"}))
	var deadline := Time.get_ticks_msec() + 240000
	while not FileAccess.file_exists(directory.path_join("stop")) and Time.get_ticks_msec() < deadline:
		await wait(.1)
		if host.workspace_layout.active != active or host.pane_focus != focused:
			check(false, "Android changed server tab or focus")
			break
	check(FileAccess.file_exists(directory.path_join("stop")), "Client completed within fixture deadline")
	for id in pids:
		check(host.sessions.has(id) and host.sessions[id].term.get_shell_pid() == pids[id], "Server PTY survives Android control")
	failures.append_array(diagnostic_guard.failures)
	failures.append_array(_errors.errors)
	FileAccess.open(directory.path_join("server-result.json"), FileAccess.WRITE).store_string(JSON.stringify({"failures": failures}))
	await server.stop()
	server.queue_free()
