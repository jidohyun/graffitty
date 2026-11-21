extends SceneTree
## Real CLI -> private capability -> OPAQUE connection -> two isolated owners.
var failures := 0
var connections: Array[Node] = []
var binary := ""

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()

func cli(args: PackedStringArray, success := true) -> Dictionary:
	# Keep the production connection polling while the child awaits its reply.
	var worker := Thread.new()
	worker.start(func():
		var output := []
		var code := OS.execute(binary, args, output, true)
		return {"code": code, "text": "\n".join(PackedStringArray(output))})
	while worker.is_alive(): await process_frame
	var result: Dictionary = worker.wait_to_finish()
	check((result.code == 0) == success, "CLI exit: " + str(args) + " " + (str(result.text) if (result.code == 0) != success else ""))
	var value: Variant = JSON.parse_string(result.text)
	return value if value is Dictionary else {}

func run() -> void:
	binary = OS.get_environment("GRAFFITTY_TEST_CLI")
	var fixtures: Array = JSON.parse_string(OS.get_environment("GRAFFITTY_TEST_CONTROLLERS"))
	for settings in fixtures:
		var connection := preload("res://scenes/remote/RemoteConnection.gd").new()
		connection.namespace_ids = true
		connection.server_alias = settings.alias
		connection.preferred_session = ""
		root.add_child(connection)
		connections.append(connection)
		preload("res://scenes/remote/ClientAuthentication.gd").bind(root, connection, settings.merged({"name":""}), false)
		connection.connect_remote(settings.url, settings.token)
		if not await until(func(): return connection.connected and not connection.topology.panes.is_empty()):
			check(false, "Authenticated attachment: " + str(settings.alias))
			finish()
			return
	var alpha: Node = connections[0]
	var beta: Node = connections[1]
	var alias_a: String = alpha.server_alias
	var alias_b: String = beta.server_alias
	check(not alias_a.is_empty() and not alias_b.is_empty(), "Authenticated app connections have CLI aliases")
	if str(fixtures[0].alias).is_empty():
		check(alpha.server_hostname == beta.server_hostname, "Fixture servers report the same hostname")
		check(alias_b == alias_a.left(62) + "-2", "Duplicate hostname receives a distinct suffix")
		var saved: Array = preload("res://scenes/remote/ClientAuthentication.gd").saved_connections()
		check(saved.size() == 2 and saved[0].alias == alias_a and saved[1].alias == alias_b, "Generated aliases persist in saved connections")
	var id: int = alpha.wire_id(int(alpha.topology.panes[0].id))
	check(id == beta.wire_id(int(beta.topology.panes[0].id)), "Two servers deliberately have the same pane ID")
	check(alpha.topology.panes[0].id != beta.topology.panes[0].id, "Viewer remaps those pane IDs into distinct local IDs")
	# Explicit targets must not depend on inherited agent or pane discovery.
	OS.set_environment("CODEX_THREAD_ID", "not-a-live-thread")
	var typed := await cli(["terminal", "type", "-t", "%s/%%%d" % [alias_a, id], "--text", "printf 'ALPHA_MARKER\\n'\n", "--interval-ms", "0"])
	check(typed.get("result", {}).get("keys_sent", 0) > 0, "Remote text was acknowledged")
	await cli(["terminal", "send-key", "-t", "%s/%%%d" % [alias_b, id], "Ctrl+u"])
	var a := await cli(["terminal", "get-text", "-t", "%s/%%%d" % [alias_a, id], "--json"])
	var b := await cli(["terminal", "get-text", "-t", "%s/%%%d" % [alias_b, id], "--json"])
	check("ALPHA_MARKER" in str(a.get("result", {}).get("text", "")), "Text reaches selected server")
	check("ALPHA_MARKER" not in str(b.get("result", {}).get("text", "")), "Identical pane ID on other server is untouched")
	var listing := await cli(["pane", "list", "-t", alias_a + "/"])
	check(listing.get("result", {}).get("panes", [{}])[0].get("target") == "%s/%%%d" % [alias_a, id], "Listing returns a copyable qualified target")
	var original: String = alpha.workspace
	var created: Dictionary = await alpha.request_action("session_new", {"name":"project"})
	check(not created.has("error"), "Create a second session")
	await alpha.request_action("session_switch", {"name":original})
	var target := await cli(["terminal", "type", "-t", alias_a + "/project:1.1", "--text", "printf 'PROJECT_MARKER\\n'\n", "--interval-ms", "0"])
	check(target.has("result") and alpha.workspace == original, "Named target reaches hidden session without switching the viewer")
	var captured := await cli(["terminal", "get-text", "-t", alias_a + "/project:1.1", "--json"])
	check("PROJECT_MARKER" in str(captured.get("result", {}).get("text", "")), "Hidden session receives text")
	await cli(["terminal", "type", "-t", "alph/%1", "--text", "denied"], false)
	await cli(["terminal", "type", "-t", alias_a + "/:1.1", "--text", "denied"], false)
	alpha.disconnect_remote()
	await cli(["terminal", "type", "-t", alias_a + "/%1", "--text", "denied"], false)
	# Another attached server remains usable after alpha disconnects.
	await cli(["terminal", "send-key", "-t", "%s/%%%d" % [alias_b, id], "Enter"])
	# A new frontend with blank settings picks up the saved address, not -3.
	var reconnected := preload("res://scenes/remote/RemoteConnection.gd").new()
	reconnected.preferred_session = original
	root.add_child(reconnected)
	connections.append(reconnected)
	preload("res://scenes/remote/ClientAuthentication.gd").bind(root, reconnected, fixtures[0].merged({"name":""}), false)
	reconnected.connect_remote(fixtures[0].url, fixtures[0].token)
	check(await until(func(): return reconnected.connected and not reconnected.server_alias.is_empty()), "Reconnect with blank alias settings")
	check(reconnected.server_alias == alias_a, "Reconnect reuses saved alias")
	await cli(["terminal", "get-text", "-t", "%s/%%%d" % [alias_a, id], "--json"])
	finish()

func finish() -> void:
	for connection in connections:
		connection.disconnect_remote()
		connection.queue_free()
	print("REMOTE_CONTROLLER_PASS" if failures == 0 else "REMOTE_CONTROLLER_FAIL")
	quit(0 if failures == 0 else 1)
