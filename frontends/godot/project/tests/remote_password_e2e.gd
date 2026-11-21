extends SceneTree
## Real headless process, permanent-password reconnect and wrong-password denial.
var failures := 0
const TestServer := preload("res://tests/support/TestServer.gd")
var directory := ""
var pid := -1
var binary := ""
var client: Node


func _initialize() -> void:
	run.call_deferred()


func expect(ok: bool, message: String) -> void:
	print("[password e2e] %s %s" % ["PASS" if ok else "FAIL", message])
	if not ok:
		failures += 1


func until(check: Callable, seconds := 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not check.call() and Time.get_ticks_msec() < deadline:
		await create_timer(0.03).timeout
	return check.call()


func start_server() -> Dictionary:
	pid = OS.create_process(binary, ["server", "--listen", "127.0.0.1:0", "--connection", directory.path_join("remote.json"), "--auth-file", directory.path_join("auth.json"), "--shell", OS.get_environment("GRAFFITTY_TEST_SHELL") if OS.has_environment("GRAFFITTY_TEST_SHELL") else "/bin/sh"])
	await until(func(): return FileAccess.file_exists(directory.path_join("remote.json")))
	return JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("remote.json")))


func stop_server() -> void:
	if pid > 0:
		TestServer.stop(pid, directory, true)
		await create_timer(0.1).timeout
		pid = -1
	DirAccess.remove_absolute(directory.path_join("remote.json"))


func run() -> void:
	directory = TestServer.prepare("graffitty-password-e2e")
	binary = OS.get_environment("GRAFFITTY_TEST_SERVER")
	if binary.is_empty(): binary = ProjectSettings.globalize_path("res://../../../target/debug/gft")
	var auth: RefCounted = ClassDB.instantiate("RemoteAuth")
	var password := "test-only remote password 한글"
	var result: Dictionary = JSON.parse_string(auth.save_settings(directory.path_join("auth.json"), password, false, "", "", 6))
	expect(result.get("ok", false), "Register permanent password")
	for restart in range(2):
		var descriptor: Dictionary = await start_server()
		expect(str(descriptor.get("token", "")).is_empty(), "Descriptor contains no temporary bypass credential")
		client = preload("res://scenes/remote/RemoteConnection.gd").new()
		root.add_child(client)
		client.connect_remote(descriptor.url, "wrong password")
		expect(await until(func(): return not client.enabled), "Wrong password rejected")
		expect(not client.connected, "Rejected client receives no workspace")
		client.connect_remote(descriptor.url, password)
		expect(await until(func(): return client.connected and client.workspace.is_empty()), "Permanent password connects after server restart %d" % restart)
		expect(client.topology.panes.is_empty(), "Password authentication does not create a terminal")
		client.disconnect_remote()
		client.queue_free()
		await process_frame
		await stop_server()
	TestServer.stop(-1, directory, failures > 0)
	quit(0 if failures == 0 else 1)
