extends SceneTree
## Authenticated server metadata, both IPC adapters, and live controls.
const Service := preload("res://config/Localization.gd")
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	print("PASS " if value else "FAIL ", message)
	if not value: failures.append(message)

func wait_ready(connection: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while (not connection.connected or connection.topology.get("panes", []).is_empty()) and Time.get_ticks_msec() < deadline:
		await process_frame
	return connection.connected and not connection.topology.get("panes", []).is_empty()

func _run() -> void:
	var service := root.get_node("Localization") as Service
	service.set_language("fr")
	var saved_before := FileAccess.get_file_as_string(service.preference_path())
	var selector := service.selector()
	root.add_child(selector)
	var label := Label.new()
	root.add_child(label)
	service.text(label, "Loading server fonts… %d%%", [42])
	var model := preload("res://scenes/TerminalSession.gd").new()
	model.builtin_title = "Filetree"
	root.add_child(model)
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_environment("GRAFFITTY_SERVER_DESCRIPTOR")))
	for shared in [false, true]:
		var connection := preload("res://scenes/remote/RemoteConnection.gd").new()
		connection.workspace = "language"
		root.add_child(connection)
		if shared:
			connection.connect_shared({"workspace": "language", "capabilities": {"require_workspace": true}})
		else:
			connection.connect_remote(str(descriptor.local.url), str(descriptor.local.token))
		check(await wait_ready(connection), "Connected using " + ("shared client" if shared else "private IPC"))
		check(not connection.topology.has("localization"), "Server does not advertise a UI language")
		check(service.choice == "fr" and service.local_choice == "fr", "Connecting preserves local language")
		check(not selector.disabled and selector.get_item_metadata(selector.selected) == "fr", "Language selector remains usable while connected")
		check(label.text == service._render("Loading server fonts… %d%%", [42]), "Formatted status uses the client locale")
		check(FileAccess.get_file_as_string(service.preference_path()) == saved_before, "Server never changes the saved local preference")
		connection._network_failed("Fixture disconnect")
		check(service.choice == "fr", "Temporary network loss retains the client locale")
		connection.retry_at = 0
		check(await wait_ready(connection), "Reconnect succeeds")
		check(service.choice == "fr", "Reconnect preserves the client locale")
		connection.disconnect_remote()
		check(service.choice == "fr" and not selector.disabled, "Explicit detach restores the local fallback")
		connection.queue_free()
		await process_frame
	# Window promotion reparents a live transport; destroying it without an
	# explicit detach must still release its language once the frame ends.
	var source := Node.new()
	root.add_child(source)
	service.set_server_language(source, "ko")
	var container := Node.new()
	root.add_child(container)
	source.reparent(container)
	await process_frame
	check(service.choice == "fr", "Reparenting never changes client language")
	container.queue_free()
	await process_frame
	await process_frame
	check(service.choice == "fr" and not selector.disabled, "Destroying a connection restores the local fallback")
	selector.queue_free()
	label.queue_free()
	model.queue_free()
	await process_frame
	print("SERVER_LOCALIZATION_PASS" if failures.is_empty() else "SERVER_LOCALIZATION_FAIL")
	quit(0 if failures.is_empty() else 1)
