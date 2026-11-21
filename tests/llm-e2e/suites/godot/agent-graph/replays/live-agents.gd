extends "../../../../replay/replay.gd"
## Real installed agents only. No fake registrations or synthetic lifecycle events.
var spec: Dictionary
var graph: Node
var shell_key: String
var agents: Dictionary = {}
var provider_blocker := ""

func play() -> void:
	var path := OS.get_environment("GRAFFITTY_E2E_MANIFEST")
	if path.is_empty():
		check(false, "Run through tests/agents/test_agent_e2e.py")
		return
	spec = JSON.parse_string(FileAccess.get_file_as_string(path))
	graph = app.agent_api.graph
	shell_key = "%%%d" % host.active_session_id
	if app.agent_api.socket_path.is_empty():
		check(false, "Workspace API socket must be available")
		return
	await type(spec.source_command + "{enter}")
	var source_deadline := Time.get_ticks_msec() + 10000
	while (graph.nodes.get(shell_key, {}).get("kind") != "custom" or not graph.nodes.get(shell_key, {}).has("manifest")) and Time.get_ticks_msec() < source_deadline:
		await hold(0.1)
	if not check(graph.nodes.get(shell_key, {}).get("kind") == "custom" and graph.nodes.get(shell_key, {}).get("manifest", {}).get("outputs", []).any(func(port): return port.get("id") == "send" and port.get("mode") == "send"), "Real source adapter advertises its Send port"):
		save_evidence()
		return
	var providers: Array = ["claude"] if spec.case == "claude" else ["codex"]
	if spec.case in ["cross", "codex-local"]:
		providers = ["codex", "claude"]
	for provider in providers:
		await launch(provider)
		if not failures.is_empty():
			save_evidence()
			return
	for provider in providers:
		var key: String = agents[provider].key
		var expected: String = spec[provider + "_model"]
		check(expected in transcript_models(key), provider + " uses the requested cheap model (no fallback)")
		check(not graph.nodes[key].has("launch_context"), provider + " starts without a Codex wrapper")
		if provider == "codex" and spec.case != "codex-local":
			check(graph.nodes[key].get("discovery_transport") == "codex_tui_listener", "Codex daemon is bound through its frontend PID/listener")
		var original_session: Variant = graph.nodes[key].get("session_id")
		await owner_graph(shell_key, "graph.connect", {"from": shell_key, "to": key, "send": true})
		if provider == "codex" and spec.case == "codex-local":
			var event: Dictionary = await owner_graph(shell_key, "graph.send", {"to": key, "text": "Reply exactly LOCAL_QUEUE_SHOULD_NOT_RUN"})
			await wait_receipt(event.result.event_id)
			check(receipt_status(event.result.event_id).begins_with("failed:"), "Native --no-daemon reports unavailable queue without typing a message")
			continue
		var term: Node = agents[provider].term
		term.paste_text("UNSENT_DRAFT_" + str(spec.nonce))
		await hold(0.3)
		await deliver(shell_key, key, "DELIVERED_" + provider + "_" + str(spec.nonce))
		check("UNSENT_DRAFT_" + str(spec.nonce) in str(term.get_text(false).get("text", "")), "Native delivery preserves " + provider + " input draft")
		await owner_graph(shell_key, "graph.connect", {"from": shell_key, "to": key, "send": true, "muted": true})
		check((await owner_graph(shell_key, "graph.send", {"to": key, "text": "MUTED_" + str(spec.nonce)})).has("error"), "Muted edge refuses delivery")
		await owner_graph(shell_key, "graph.disconnect", {"from": shell_key, "to": key})
		check((await owner_graph(shell_key, "graph.send", {"to": key, "text": "DISCONNECTED_" + str(spec.nonce)})).has("error"), "Disconnected edge refuses delivery")
		await owner_graph(shell_key, "graph.connect", {"from": shell_key, "to": key, "send": true})
		await deliver(shell_key, key, "RECONNECTED_" + provider + "_" + str(spec.nonce))
		check(graph.nodes[key].get("session_id") == original_session, "Reconnect preserves " + provider + " session")
		term.send_text("\u0015") # Clear only the test-owned draft, while this test agent is idle.
	if providers.size() == 2:
		var source: String = agents.codex.key
		var target: String = agents.claude.key
		await owner_graph(source, "graph.connect", {"from": source, "to": target, "send": true})
		await deliver(source, target, "CROSS_CLAUDE_" + str(spec.nonce))
		if spec.case != "codex-local":
			await owner_graph(target, "graph.connect", {"from": target, "to": source, "send": true})
			await deliver(target, source, "CROSS_CODEX_" + str(spec.nonce))
		# Only one stop edge, preventing an unintended completion loop.
		await owner_graph(source, "graph.connect", {"from": source, "to": target, "turn_completed": true})
		var marker := "STOP_SEEN_" + str(spec.nonce)
		host.focus_pane(source)
		agents.codex.term.paste_text("Reply with exactly this instruction and nothing else: Reply exactly " + marker)
		# Submit after the TUI has processed the bracketed paste. Sending Enter
		# in the same burst can be classified as part of Codex's paste input.
		await hold(0.5)
		await keys("enter")
		await expect_assistant(target, marker)
		check(assistant_text(target).count(marker) == 1, "One real completion produces one recipient reply")
		var ref: Dictionary = await owner_graph(target, "graph.read", {"node": source})
		check(ref.has("result") and ref.result.get("sessions", []).size() == 1 and ref.result.sessions[0].id == graph.nodes[source].session_id and not ref.result.has("text"), "Read permission returns the source session reference, not entire history")
	save_evidence()

func launch(provider: String) -> void:
	var existing: Array = host.sessions.keys()
	host.create_terminal_window(shell_key)
	await owner_at_rest()
	var pane_deadline := Time.get_ticks_msec() + 10000
	while host.sessions.keys() == existing and Time.get_ticks_msec() < pane_deadline:
		await process_frame
	# Creating beside an inactive pane need not steal focus from the current
	# provider. Resolve the newly acknowledged pane, never type into the old one.
	var created: Array = host.sessions.keys().filter(func(id): return id not in existing)
	if not check(created.size() == 1, "Owner creates exactly one new pane for " + provider):
		return
	var id: int = int(created[0])
	var key := "%%%d" % id
	if not check(key != shell_key, "Owner creates a distinct live pane for " + provider):
		return
	var term: Node = host.sessions[id].term
	agents[provider] = {"key": key, "term": term}
	await hold(3.0 if OS.get_name() == "Windows" else 0.5)
	var marker := "READY_" + provider + "_" + str(spec.nonce)
	var prompt := "This is an isolated integration test. Do not use tools. Reply exactly " + marker
	if OS.get_name() == "Windows":
		var command: String = spec[provider + "_command"]
		if provider == "codex": command += " --cd " + quote(spec.work)
		term.send_text("Set-Location -LiteralPath " + quote(spec.work) + "; [Environment]::CurrentDirectory = (Get-Location).Path; " + command + " " + quote(prompt) + "\r")
	else:
		term.send_text("cd " + quote(spec.work) + " && " + spec[provider + "_command"] + " " + quote(prompt) + "\r")
	await expect_assistant(key, marker)
	check(graph.nodes.get(key, {}).get("provider") == provider, provider + " discovered by its real process")
	check(not str(graph.nodes.get(key, {}).get("session_id", "")).is_empty(), provider + " has a real session ID")

func quote(value: String) -> String:
	if OS.get_name() == "Windows": return "'" + value.replace("'", "''") + "'"
	return "'" + value.replace("'", "'\\''") + "'"

func records(key: String) -> Array:
	# The owner keeps transcript paths private. Locate only this fixture's fresh
	# provider home using the real session ID reported through the shared graph.
	var node: Dictionary = graph.nodes.get(key, {})
	var provider := str(node.get("provider", ""))
	var session := str(node.get("session_id", ""))
	if provider not in ["codex", "claude"] or session.is_empty():
		return []
	var home := str(spec.work).get_base_dir().path_join(provider)
	var path := fixture_transcript(home.path_join("sessions" if provider == "codex" else "projects"), session)
	if path.is_empty() or not FileAccess.file_exists(path):
		return []
	var file := FileAccess.open(path, FileAccess.READ)
	# Test homes start empty; bound failures rather than silently scanning arbitrary history.
	if file.get_length() > 4 * 1024 * 1024:
		return []
	var values: Array = []
	while not file.eof_reached():
		var line := file.get_line()
		if line.strip_edges().is_empty(): continue
		var parser := JSON.new()
		# A provider may still be appending its last JSONL record.
		if parser.parse(line) != OK: continue
		var value: Variant = parser.data
		if value is Dictionary: values.append(value)
	return values


func fixture_transcript(directory: String, session: String) -> String:
	if not DirAccess.dir_exists_absolute(directory):
		return ""
	for file in DirAccess.get_files_at(directory):
		if file.ends_with(".jsonl") and session in file:
			return directory.path_join(file)
	for child in DirAccess.get_directories_at(directory):
		if child.begins_with("."):
			continue
		var found := fixture_transcript(directory.path_join(child), session)
		if not found.is_empty():
			return found
	return ""

func assistant_text(key: String) -> String:
	var text := ""
	for record in records(key):
		var message: Dictionary = record.get("payload", {}) if record.get("type") == "response_item" else record.get("message", {})
		if message.get("role") != "assistant": continue
		for part in message.get("content", []):
			if part is Dictionary and part.get("type") in ["text", "output_text"]:
				text += str(part.get("text", "")) + "\n"
	return text

func transcript_models(key: String) -> Array:
	var models: Array = []
	for record in records(key):
		var model: Variant = record.get("payload", {}).get("model") if record.get("type") == "turn_context" else record.get("message", {}).get("model")
		if model != null and not model in models: models.append(model)
	return models

func expect_assistant(key: String, marker: String) -> void:
	var deadline := Time.get_ticks_msec() + int(spec.timeout) * 1000
	while Time.get_ticks_msec() < deadline:
		if agents.has("claude") and agents.claude.key == key:
			for record in records(key):
				if record.get("error") == "authentication_failed":
					provider_blocker = "Claude authentication failed in the isolated test home; refresh the Claude login before rerunning"
					check(false, provider_blocker)
					return
			var screen := str(agents.claude.term.get_text(false).get("text", ""))
			if "You've hit your session limit" in screen:
				provider_blocker = "Claude account session limit; see terminal evidence for reset time"
				check(false, provider_blocker)
				return
		if marker in assistant_text(key) and graph.nodes.get(key, {}).get("status") == "idle":
			check(true, "Real assistant completed " + marker)
			return
		await hold(0.25)
	check(false, "Timed out waiting for assistant-only output and idle: " + marker)

func owner_graph(source: String, method: String, params: Dictionary) -> Dictionary:
	return await app.agent_api.dispatch(int(source.substr(1)), method, params)


func deliver(source: String, target: String, marker: String) -> void:
	var event: Dictionary = await app.agent_api.dispatch(int(source.substr(1)), "graph.send", {"to": target, "text": "Do not use tools or send a graph reply. Reply exactly " + marker})
	check(event.has("result"), "Graph accepts " + marker + (": " + str(event.error) if event.has("error") else ""))
	if not event.has("result"): return
	await wait_receipt(event.result.event_id)
	var status := receipt_status(event.result.event_id)
	check(status in ["submitted", "queued in Codex"], "Native transport accepts " + marker + ": " + status)
	if status in ["submitted", "queued in Codex"]:
		await expect_assistant(target, marker)

func receipt_status(id: String) -> String:
	for receipt in graph.receipts:
		if receipt.get("event_id") == id: return str(receipt.get("status", ""))
	return "missing"

func wait_receipt(id: String) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	while receipt_status(id) == "missing" and Time.get_ticks_msec() < deadline:
		await hold(0.1)

func save_evidence() -> void:
	var nodes: Array = []
	var source_tail := ""
	if not failures.is_empty() and host.sessions.has(int(shell_key.substr(1))):
		source_tail = str(host.sessions[int(shell_key.substr(1))].term.get_text(false).get("text", "")).right(3000)
	for provider in agents:
		var key: String = agents[provider].key
		var item: Dictionary = graph.public_node(key)
		item["discovery_note"] = graph.nodes.get(key, {}).get("discovery_note")
		item["queue_error"] = graph.nodes.get(key, {}).get("queue_error")
		item["observed_models"] = transcript_models(key)
		if not failures.is_empty():
			item["terminal_tail"] = str(agents[provider].term.get_text(false).get("text", "")).right(3000)
		nodes.append(item)
	var file := FileAccess.open(spec.evidence, FileAccess.WRITE)
	file.store_string(JSON.stringify({"case": spec.case, "nodes": nodes, "receipts": graph.receipts, "failures": failures, "provider_blocker": provider_blocker, "source_terminal_tail": source_tail, "source": graph.public_node(shell_key)}, "\t"))
