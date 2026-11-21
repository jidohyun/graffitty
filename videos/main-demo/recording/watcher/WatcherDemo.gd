extends "res://videos/main-demo/recording/node-sessions/NodeSessionsDemo.gd"
## Email CLI fixture + real watcher + real GGP receipt + playable podcast.

func create_beside(key: String, down := false) -> String:
	# Setup uses the production command, independent of transient header width.
	var previous: Array = host.sessions.keys()
	host.workspace_view.split_window("v" if down else "h", key)
	if not await until(func(): return host.sessions.size() == previous.size() + 1, "Prepare adjacent node pane"): return ""
	for id in host.sessions:
		if id not in previous: return "%%%d" % id
	return ""

var watcher_prepared := {}

func prepare_extra_sessions() -> void:
	if not await demo_sessions.create("Watcher"): return
	FileAccess.open(output.path_join("launch-chapter"), FileAccess.WRITE).store_string("watcher")
	var view: Control = host.workspace_view
	DirAccess.copy_absolute(output.path_join("node.py"), output.path_join("protocol-node.py"))
	DirAccess.copy_absolute(output.path_join("watcher.py"), output.path_join("node.py"))
	graph = host.agent_api.graph
	if not view.physics_enabled(): view.toggle_physics()
	var code: String = host.pane_focus
	await hold(1)
	await pinch_overview()
	# Arrange the workspace off camera through the production split command.
	# The recorded interaction is starting and wiring the watcher, not setup.
	var previous: Array = host.sessions.keys()
	view.split_window("h", code)
	if not await until(func(): return host.sessions.size() == previous.size() + 1, "Create agent pane"): return
	var agent := ""
	for id in host.sessions:
		if id not in previous: agent = "%%%d" % id
	if agent.is_empty(): return
	await move_to(code, Vector2(0, 2400))
	await resize_pane(code, Vector2(1700, 1300), 26)
	await move_to(agent, Vector2(1950, 2400))
	await resize_pane(agent, Vector2(1500, 1300), 26)
	await host.set_pane_title(code, "Watcher")
	await host.set_pane_title(agent, "Claude")
	# Normalize the inherited font size in both directions
	# so the published minimal source does not wrap differently across takes.
	for key in [code, agent]:
		host.focus_pane(key)
		var term = host.sessions[int(key.substr(1))].term
		for step in range(20):
			if term.get_live_font_size() <= 26: break
			host.change_text_size(-1)
			await hold(.08)
	await enter(agent, "claude")
	if not await until(func(): return graph.nodes.get(agent, {}).get("provider") == "claude", "Watcher Claude registered"): return
	await enter(agent, "When a GGP message brings a new email, summarize it and make a short podcast for me.")
	if not await until(func(): return "when a GGP message arrives." in shell_text(agent) and graph.nodes.get(agent, {}).get("status") == "idle", "Claude knows how to handle incoming email"): return
	await enter(code, "bat node.py")
	await center_graph([code, agent], 1)
	await frame_nodes([code])
	await camera_at_rest()
	DirAccess.copy_absolute(output.path_join("protocol-node.py"), output.path_join("node.py"))
	watcher_prepared = {"code": code, "agent": agent}

func present_extra_sessions() -> void:
	if watcher_prepared.is_empty(): return
	var code: String = watcher_prepared.code
	var agent: String = watcher_prepared.agent
	var view: Control = host.workspace_view
	var effects := hold_full_view()
	await say("Watcher: session click")
	var switch_frame := movie_frame()
	if not await select_demo_session("Watcher"): return
	var intro_frame: int = demo_sessions.transitions[-1].click_frame
	DirAccess.copy_absolute(output.path_join("watcher.py"), output.path_join("node.py"))
	await frame_nodes([code])
	await camera_at_rest()
	await snapshot("00-code")
	await finish_narration("watcher-intro", intro_frame)
	await say("Watcher: start the email command")
	await enter(code, "uv run node.py email-cli wait")
	if not await until(func(): return graph.nodes.get(code, {}).get("manifest", {}).get("name") == "Watcher", "Real watcher registered"): return
	await frame_nodes([code, agent])
	# Approach the port before the spoken instruction, then drag immediately.
	var links: Control = view.agent_links
	await point_at(links.get_global_transform_with_canvas() * links.port_center(code + "/done", true), .25)
	await say("Watcher: connect")
	var beat := movie_frame()
	await quick_wire(code + "/done", agent + "/in")
	if not failures.is_empty(): return
	await say("Watcher: wire connected")
	var ports = preload("res://scenes/GraphPorts.gd")
	var solid := false
	for edge in graph.edges.values():
		if ports.endpoint(edge, true) == code + "/done":
			solid = view.agent_links.wire_pattern(edge) == "solid"
	check(solid, "Watcher done wire is drawn solid")
	await finish_narration("watcher-connect", beat)
	var prepared := "when a GGP message arrives." in shell_text(agent)
	var silent := not FileAccess.file_exists(output.path_join("received-email.json")) and not "A new email arrived" in shell_text(agent)
	check(prepared and silent, "Claude is prepared and waiting for a real email message")
	await snapshot("01-ready")
	await say("Watcher: result")
	beat = movie_frame()
	var released := movie_frame()
	FileAccess.open(output.path_join("new-email"), FileAccess.WRITE).store_string("arrived\n")
	if not await until(func(): return FileAccess.file_exists(output.path_join("received-email.json")), "Actual email CLI output triggers Claude's podcast tool", 30): return
	var received := movie_frame()
	# Show the transfer in the overview, then follow the response into Claude.
	await frame_nodes([agent])
	await camera_at_rest()
	if not await until(func(): return "I made a short podcast for you" in shell_text(agent) and graph.nodes.get(agent, {}).get("status") == "idle", "Claude summarizes the email and offers the podcast", 20): return
	await finish_narration("watcher-result", beat)
	await hold(.5)
	await snapshot("02-result")
	var messages := 0
	for receipt in graph.receipts:
		if receipt.get("source") == code and receipt.get("target") == agent and receipt.get("status") == "delivered": messages += 1
	check(messages == 1, "Exactly one acknowledged email message")
	var podcast := FileAccess.file_exists(output.path_join("inbox-podcast.wav"))
	check(podcast, "The demonstrated podcast is a real audio file")
	var file := FileAccess.open(output.path_join("watcher-evidence.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"command": "uv run node.py email-cli wait", "released_frame": released,
		"received_frame": received, "silent_before_email": silent, "claude_prepared": prepared,
		"podcast_created": podcast, "messages": messages, "recipient": "claude",
		"delivered": messages == 1, "prepared_sessions": demo_sessions.prepared.size(), "watcher_session": demo_sessions.prepared.Watcher.id,
		"session_click_frame": switch_frame, "continuous_after_session_click": true,
		"receipts": graph.receipts, "claude": shell_text(agent),
		"source": shell_text(code)}, "\t"))
	file.close()
	restore_full_view(effects)
