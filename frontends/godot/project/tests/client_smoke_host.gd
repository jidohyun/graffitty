extends "../../../../tests/llm-e2e/replay/replay.gd"
## Runs the shared CLI/MCP fixtures in real owner-backed PTYs.

func quote_shell(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"

func wait_result(path: String, seconds := 90) -> Dictionary:
	var deadline := Time.get_ticks_msec() + seconds * 1000
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(path):
			var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if value is Dictionary: return value
		await process_frame
	return {"ok": false, "error": "PTY fixture did not finish"}

func play() -> void:
	await camera_at_rest()
	var directory := OS.get_environment("GRAFFITTY_CLIENT_TEST_DIR")
	var repo := OS.get_environment("GRAFFITTY_CLIENT_TEST_REPO")
	var source: int = host.active_session_id
	var original_workspace: int = host.workspace_layout.active
	var created: Dictionary = await host.session_backend.connection.request_action("create", {"kind": "tab"})
	if not check(created.get("type") == "ack", "Owner creates a foreign authorization fixture"): return
	var foreign_id := int(created.created)
	var deadline := Time.get_ticks_msec() + 10000
	while (not host.sessions.has(foreign_id) or host.active_session_id != foreign_id) and Time.get_ticks_msec() < deadline:
		await process_frame
	var foreign: Node = await host.create_chromium_session("about:blank")
	if not check(foreign != null, "Foreign chromium belongs to another real owner session"): return
	for index in host.get_tabs().size():
		if int(host.get_tabs()[index].id) == original_workspace:
			await select_tab(index)
			break
	await camera_at_rest()
	var agent_result := directory.path_join("agent.json")
	host.sessions[source].term.send_text("python3 %s %s %s\r" % [
		quote_shell(repo.path_join("tests/fixtures/agent_client_smoke.py")), quote_shell(agent_result),
		quote_shell("%%%d" % foreign.session_id)])
	var result: Dictionary = await wait_result(agent_result)
	check(result.get("ok", false), "Agent CLI/MCP fixture passes: " + str(result))
	# Chromium creation intentionally reveals that chromium. The next independent
	# fixture exercises physical terminal input, which requires its pane selected.
	host.focus_pane("%%%d" % source)
	await process_frame
	var terminal_result := directory.path_join("terminal.json")
	host.sessions[source].term.send_text("python3 %s %s\r" % [
		quote_shell(repo.path_join("tests/fixtures/terminal_client_smoke.py")), quote_shell(terminal_result)])
	result = await wait_result(terminal_result)
	check(result.get("ok", false), "Terminal CLI fixture passes: " + str(result))
	deadline = Time.get_ticks_msec() + 10000
	while "TERMINAL_CLIENT_OK" not in host.sessions[source].term.get_text(false).text and Time.get_ticks_msec() < deadline:
		await process_frame
	check("TERMINAL_CLIENT_OK" in host.sessions[source].term.get_text(false).text, "CLI text and key delivery executes in the same retained shell")
	# Drain chromium mirrors and decoder work before the scene tree tears down.
	for id in host.chromiums.keys():
		host.close_chromium_session(int(id))
	deadline = Time.get_ticks_msec() + 10000
	while not host.chromiums.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	check(host.chromiums.is_empty(), "Private chromiums close before frontend teardown")
