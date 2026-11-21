extends SceneTree
## Launch through the real frontend connect-or-start path, without a test owner.
var directory := OS.get_environment("GRAFFITTY_RELAUNCH_EVIDENCE")

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1280, 800)
	var recording:=preload("res://tests/windows_acceptance_recording.gd").new()
	recording.directory=directory.path_join("recording")
	DirAccess.make_dir_recursive_absolute(recording.directory)
	root.add_child(recording)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 20000
	var dialog_seen := false
	while wrapper.host == null and Time.get_ticks_msec() < deadline:
		dialog_seen = dialog_seen or wrapper.dialog.visible
		await process_frame
	if wrapper.host == null or dialog_seen:
		push_error("Normal local startup failed or showed a Connect form")
		quit(1)
		return
	var host: Node = wrapper.host
	var terminal: Node = host.active_terminal()
	var marker := "RELAUNCH_READY_" + OS.get_environment("GRAFFITTY_RELAUNCH_CYCLE")
	terminal.send_text("Write-Output ('RELAUNCH_' + 'READY_" + OS.get_environment("GRAFFITTY_RELAUNCH_CYCLE") + "')\r")
	deadline = Time.get_ticks_msec() + 10000
	while marker not in str(terminal.get_text(false).text) and Time.get_ticks_msec() < deadline:
		await process_frame
	if marker not in str(terminal.get_text(false).text) or host.sessions.size() != 1:
		push_error("Fresh launch must have exactly one usable shell")
		quit(1)
		return
	await create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join("ready.png"))
	var report := {"shell_pid": terminal.get_shell_pid(), "terminal_id": host.active_session_id,
		"session": wrapper.settings.workspace, "marker": marker, "pane_count": host.sessions.size(),
		"connect_form_seen": dialog_seen}
	FileAccess.open(directory.path_join("ready.json"), FileAccess.WRITE).store_string(JSON.stringify(report))
	deadline = Time.get_ticks_msec() + 15000
	while not FileAccess.file_exists(directory.path_join("close")) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not FileAccess.file_exists(directory.path_join("close")):
		push_error("Controller did not retain process identities before closure")
		quit(1)
		return
	terminal.send_text("exit\r")
	# The production frontend must quit itself on last-session closure.
	await create_timer(8.0).timeout
	push_error("Frontend did not quit after the last shell exited")
	quit(1)
