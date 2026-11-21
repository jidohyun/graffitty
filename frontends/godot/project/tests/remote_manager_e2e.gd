extends SceneTree
## Real password rotation, recovery and persistence through the production UI.
const TestServer := preload("res://tests/support/TestServer.gd")
var directory := ""
var server_pid := -1
var listen := "127.0.0.1:0"
var failures := 0
var manager: Node
var guard := preload("res://tests/diagnostic_guard.gd").new()

func _initialize() -> void:
	directory = TestServer.prepare("graffitty-manager-e2e")
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, directory.path_join(kind.to_lower()))
	guard.install(self)
	run.call_deferred()

func expect(ok: bool, message: String) -> void:
	print("[manager e2e] %s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures += 1

func until(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await create_timer(.05).timeout
	return condition.call()

func start_server() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(directory)
	var binary := OS.get_environment("GRAFFITTY_TEST_SERVER")
	if binary.is_empty(): binary = ProjectSettings.globalize_path("res://../../../target/debug/gft")
	server_pid = OS.create_process(binary, ["server", "--listen", listen, "--connection", directory.path_join("server.json"), "--auth-file", directory.path_join("auth.json"), "--shell", "/bin/sh"])
	await until(func(): return FileAccess.file_exists(directory.path_join("server.json")))
	var settings: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("server.json")))
	listen = str(settings.url).trim_prefix("ws://")
	return settings

func stop_server() -> void:
	TestServer.stop(server_pid, directory, true)
	server_pid = -1
	await create_timer(.2).timeout
	DirAccess.remove_absolute(directory.path_join("server.json"))

func run() -> void:
	root.size = Vector2i(400, 800)
	var settings := await start_server()
	manager = preload("res://scenes/remote/RemoteManager.gd").new()
	root.add_child(manager)
	await process_frame
	expect(manager.chooser.visible and not manager.dialog.visible, "Fresh launch shows the server list without a panelal")
	manager._new_connection()
	manager.endpoint.text = settings.url
	manager.label.text = "Rotation fixture"
	manager.token.text = settings.token
	manager.remember.button_pressed = false
	manager._submit_connection()
	var key: String = manager._connection_key({"url": settings.url})
	expect(await until(func(): return manager.states[key].state == "connected" and manager.view.host != null), "Save and connect opens a real remote workspace")
	var saved: Array = manager.Authentication.saved_connections()
	expect(saved.size() == 1 and not saved[0].has("token") and not saved[0].remember, "Server is persisted without saving its password")
	manager._show_chooser()
	manager._edit_connection(key)
	manager.token.text = "unsubmitted"
	manager._cancel_editor()
	expect(manager.transports[key].connected and manager.chooser.visible, "Back from editing preserves the current session")
	await stop_server()
	settings = await start_server()
	expect(await until(func(): return manager.states[key].state == "password"), "Rotated temporary password becomes a clear password-required state")
	expect(manager.entries.size() == 1 and not manager.dialog.visible, "Password failure keeps the server and does not open surprise dialogs")
	manager._activate(key)
	expect(manager.dialog.visible and manager.token.text.is_empty() and manager.endpoint.text == settings.url, "Recovery opens the right server with an empty masked password")
	manager.token.text = settings.token
	manager.remember.button_pressed = true
	manager._submit_connection()
	expect(await until(func(): return manager.states[key].state == "connected" and manager.view.host != null), "Current temporary password recovers the connection")
	expect(manager.federation.connections.size() == 1, "Recovery does not duplicate the server")
	manager._disconnect(key)
	expect(manager.entries.size() == 1 and manager.states[key].state == "disconnected", "Disconnect preserves the saved server")
	manager.queue_free()
	await process_frame
	manager = preload("res://scenes/remote/RemoteManager.gd").new()
	root.add_child(manager)
	await process_frame
	expect(manager.entries.size() == 1 and manager.chooser.visible and not manager.dialog.visible, "App restart restores the server list")
	manager._activate(key)
	expect(await until(func(): return manager.states[key].state == "connected"), "The replacement password is remembered and reconnects after app restart")
	manager._remove_server(key)
	expect(manager.entries.is_empty() and manager.Authentication.saved_connections().is_empty(), "Remove clears the saved server after disconnecting it")
	manager.queue_free()
	await process_frame
	await stop_server()
	TestServer.stop(-1, directory, failures > 0)
	quit(0 if failures == 0 else 1)
