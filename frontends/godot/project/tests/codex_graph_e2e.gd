extends "../../../../tests/llm-e2e/replay/replay.gd"

func play() -> void:
	await camera_at_rest()
	var graph: Node = app.agent_api.graph
	var first: int = host.active_session_id
	host.create_terminal_window("%%%d" % first)
	var second: int = host.active_session_id
	await hold(2.0)
	var mode := OS.get_environment("GRAFFITTY_CODEX_TEST_MODE")
	var work := OS.get_environment("GRAFFITTY_CODEX_TEST_WORK")
	if work.is_empty():
		check(false, "Run through tests/agents/codex_hooks_e2e.py MODE --graph")
		return
	var target := "%%%d" % second
	var source := "%%%d" % first
	host.sessions[second].term.send_text("cd '%s'; cod%s 'Say OK'\r" % [work, " --no-daemon" if mode == "local" else (" -c 'default_permissions=\":danger-full-access\"'" if mode == "overrides" else "")])
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		var state: Dictionary = graph.nodes.get(target, {})
		if state.has("session_id") and state.get("status") == "idle":
			break
		await hold(0.2)
	var state: Dictionary = graph.nodes.get(target, {})
	check(state.get("provider") == "codex", "Alias launches the real Codex executable and PID detection finds it")
	check(state.has("session_id"), "PID evidence identifies the thread without hooks")
	check(not state.has("launch_context"), "No Graffitty launch context or proxy")
	if not state.has("session_id"):
		print("DISCOVERY_STATE ", state)
		print(host.sessions[second].term.get_text(false))
		return
	check(state.get("provider_home") == OS.get_environment("CODEX_HOME"), "Process-owned files identify the custom account home")
	var command: Array = []
	OS.execute("ps", ["-p", str(int(state.pid)), "-o", "args="], command)
	check(not command.is_empty() and not "--remote" in str(command[0]), "Codex launch arguments are not rewritten")
	var session_id: String = state.session_id
	# Daemon shells may have no pane variables, or stale variables from another
	# pane. Both must resolve the current Codex thread rather than the emitter.
	for context_case in ["absent", "stale", "unbound"]:
		var clear_context: bool = context_case == "absent"
		var requested_thread: String = "11111111-1111-4111-8111-111111111111" if context_case == "unbound" else session_id
		var output := work.path_join("context-%s.json" % context_case)
		var unset := "-u GRAFFITTY_SOCKET -u GRAFFITTY_TOKEN -u GRAFFITTY_BIN -u GRAFFITTY_CODEX_CONTEXT" if clear_context else "-u GRAFFITTY_CODEX_CONTEXT"
		host.sessions[first].term.send_text("env %s CODEX_THREAD_ID='%s' gft graph adjacent > '%s'\r" % [unset, requested_thread, output])
		deadline = Time.get_ticks_msec() + 30000
		var response: Variant = null
		while Time.get_ticks_msec() < deadline:
			if FileAccess.file_exists(output):
				var text := FileAccess.get_file_as_string(output)
				if not text.strip_edges().is_empty():
					response = JSON.parse_string(text)
					if response != null: break
			await hold(0.2)
		if context_case == "unbound":
			check(response is Dictionary and response.get("error", {}).get("code") == "missing_context", "Unknown threads never fall back to inherited pane credentials")
		else:
			check(response is Dictionary and response.get("result", {}).get("self") == target, "Thread routing selects the correct pane with %s environment" % ("absent" if clear_context else "another pane's"))

	await graph.dispatch(first, "agent.event", {"provider": "adapter", "event": "SessionStart"})
	await graph.dispatch(first, "agent.register", {"inputs": [], "outputs": [{"id": "send"}]})
	graph.connect_nodes({"from": source, "to": target, "send": true})
	host.sessions[second].term.paste_text("unfinished draft")
	await graph.dispatch(first, "graph.send", {"to": target, "text": "Do not inject into the terminal"})
	deadline = Time.get_ticks_msec() + 10000
	while graph.receipts.is_empty() and Time.get_ticks_msec() < deadline:
		await hold(0.2)
	check(not graph.receipts.is_empty(), "Native delivery resolves explicitly")
	if not graph.receipts.is_empty():
		if mode == "daemon":
			check(graph.receipts[-1].get("status") == "queued in Codex", "Discovered daemon accepts native queue delivery")
		else:
			check(str(graph.receipts[-1].get("status")).begins_with("failed:") and "no external queue endpoint" in str(graph.receipts[-1]), "Local delivery fails explicitly without converting Codex to remote mode")
	deadline = Time.get_ticks_msec() + 20000
	while mode == "daemon" and Time.get_ticks_msec() < deadline:
		var transcript: String = graph.nodes.get(target, {}).get("transcript_path", "")
		if not transcript.is_empty() and FileAccess.file_exists(transcript) and FileAccess.get_file_as_string(transcript).contains("Do not inject into the terminal"):
			break
		await hold(0.2)
	var transcript: String = graph.nodes.get(target, {}).get("transcript_path", "")
	check(not transcript.is_empty() and FileAccess.file_exists(transcript), "PID discovery resolves the real session file")
	var delivered := not transcript.is_empty() and FileAccess.get_file_as_string(transcript).contains("Do not inject into the terminal")
	check(delivered == (mode == "daemon"), "Only an available native queue delivers a message")
	check("unfinished draft" in host.sessions[second].term.get_text(false).get("text", ""), "Discovery and native delivery preserve the input draft")

	# Exit only the test-owned TUI and inspect its real native resume guidance.
	host.sessions[second].term.send_text(String.chr(21))
	await hold(0.3)
	host.sessions[second].term.send_text("/quit")
	await hold(0.3)
	host.sessions[second].term.send_text("\r")
	deadline = Time.get_ticks_msec() + 10000
	var screen := ""
	while Time.get_ticks_msec() < deadline:
		screen = host.sessions[second].term.get_text(false).get("text", "")
		if "codex resume " in screen: break
		await hold(0.2)
	check("codex resume " in screen and session_id in screen, "Native exit recommends the same session without a proxy socket")
	check(not "--remote" in screen and not "/tmp/codex-" in screen, "Resume guidance is portable outside Graffitty")
	if mode != "daemon":
		check(not "Disconnected from this task" in screen, "Embedded Codex keeps its normal exit semantics")
