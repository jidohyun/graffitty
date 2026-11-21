extends SceneTree
## Real frontend attachment to a private owner, run by test_shared_godot_e2e.py.
const Layout = preload("res://scenes/WorkspaceLayout.gd")
var failures: Array[String] = []
func _initialize() -> void:
	call_deferred("run")
func check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)
func run() -> void:
	root.size = Vector2i(1280, 800)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	wrapper.launch_args = OS.get_cmdline_user_args() + PackedStringArray(["--workspace=main"])
	if OS.get_environment("GRAFFITTY_TEST_PHASE") == "reconnect":
		wrapper.launch_args.append("--attach-session")
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 20000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if wrapper.host == null:
		printerr("Shared host unavailable: ", wrapper.status.text)
		quit(1)
		return
	for unused in range(10): await process_frame
	var host: Node = wrapper.host
	var id: int = host.active_session_id
	var term: Node = host.sessions[id].term
	var key := "%%%d" % id
	check(wrapper.connection.topology.get("authoritative_layout", false), "server owns canonical workspace")
	check(term.get_shell_pid() > 0, "server shell PID reaches mirror")
	var reconnect := OS.get_environment("GRAFFITTY_TEST_PHASE") == "reconnect"
	if reconnect:
		check("OWNER_FIRST_MARKER" in term.get_text(false).text, "terminal replay survives frontend exit")
		var saved: Dictionary = wrapper.connection.topology.workspace_state.layout.tabs[str(id)]
		check(not saved.enabled and not saved.physics, "layout modes survive frontend exit")
		check(saved.windows[0].rect == [123.0, 145.0, 640.0, 380.0], "canonical rectangle survives frontend exit")
	else:
		var group: Dictionary = host.workspace_layout.tab(id)
		group.tree.tiling = false
		group.tree.physics = false
		Layout.find(group.tree, key).rect = Rect2(123, 145, 640, 380)
		host.session_backend.commit_workspace(host)
		deadline = Time.get_ticks_msec() + 5000
		while Time.get_ticks_msec() < deadline:
			await process_frame
			var saved: Dictionary = wrapper.connection.topology.workspace_state.layout.tabs[str(id)]
			if not saved.enabled and saved.windows[0].rect == [123.0, 145.0, 640.0, 380.0]: break
		check(Time.get_ticks_msec() < deadline, "layout edit committed through revision checked server API")
	term.send_text("printf 'OWNER_%s_MARKER\\n'\n" % ("SECOND" if reconnect else "FIRST"))
	var marker := "OWNER_%s_MARKER" % ("SECOND" if reconnect else "FIRST")
	deadline = Time.get_ticks_msec() + 5000
	while marker not in term.get_text(false).text and Time.get_ticks_msec() < deadline: await process_frame
	check(marker in term.get_text(false).text, "terminal input reaches retained server shell")
	var report := {"phase": "reconnect" if reconnect else "first", "frontend_pid": OS.get_process_id(),
		"server_pid": wrapper.connection.socket.native.server_pid(), "session": id,
		"shell_pid": term.get_shell_pid(), "revision": wrapper.connection.topology.workspace_revision,
		"layout": wrapper.connection.topology.workspace_state, "failures": failures}
	var file := FileAccess.open(OS.get_environment("GRAFFITTY_TEST_REPORT"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	wrapper.connection.disconnect_remote()
	wrapper.queue_free()
	for unused in range(3): await process_frame
	quit(0 if failures.is_empty() else 1)
