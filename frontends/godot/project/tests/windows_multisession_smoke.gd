extends SceneTree
## Real local startup and GUI closure; the controller retains process handles.
var directory := OS.get_environment("GRAFFITTY_MULTISESSION_EVIDENCE")
var route := OS.get_environment("GRAFFITTY_MULTISESSION_ROUTE")

func close_pane(host: Node) -> void:
	if route == "shell-exit":
		host.active_terminal().send_text("exit\r")
	elif route == "shell-eof":
		var terminal: Node=host.active_terminal()
		terminal.send_text("Set-PSReadLineKeyHandler -Chord Ctrl+d -Function DeleteCharOrExit; Write-Output ('EOF_'+'CONFIGURED')\r")
		if not await wait_for(func():return "EOF_CONFIGURED" in str(terminal.get_text(false).text)):
			fail("PowerShell EOF key was not configured")
			return
		terminal.send_text("\u0004")
	elif route == "pane-shortcut":
		var event := InputEventKey.new()
		event.keycode = KEY_W
		event.ctrl_pressed = true
		event.shift_pressed = true
		for down in [true, false]:
			event.pressed = down
			root.push_input(event, true)
			await process_frame
	else:
		for entry in host.menu_entries:
			if entry.label == "Shell::Close Pane":
				host._run_menu_action(entry)
				return

func _initialize() -> void:
	run.call_deferred()

func wait_for(condition: Callable, seconds := 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await process_frame
	return condition.call()

func fail(message: String) -> void:
	push_error(message)
	quit(1)

func run() -> void:
	root.size = Vector2i(1280, 800)
	var recording:=preload("res://tests/windows_acceptance_recording.gd").new()
	recording.directory=directory.path_join("recording-A")
	DirAccess.make_dir_recursive_absolute(recording.directory)
	root.add_child(recording)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	wrapper.launch_args = PackedStringArray(["--workspace=A", "--no-plugin"])
	root.add_child(wrapper)
	if not await wait_for(func(): return wrapper.host != null):
		fail("Local startup did not produce a host")
		return
	var host: Node = wrapper.host
	if wrapper.dialog.visible:
		fail("Local startup unexpectedly showed Connect")
		return
	host.create_terminal_window()
	if not await wait_for(func(): return host.sessions.size() == 2 and not host.session_backend.work_pending()):
		fail("The GUI did not create two panes in one tab")
		return
	if OS.get_environment("GRAFFITTY_MULTISESSION_TABS") == "1":
		host.create_session()
		if not await wait_for(func(): return host.sessions.size() == 3 and not host.session_backend.work_pending()):
			fail("The GUI did not create the additional tab")
			return
	var panes: Array = []
	for id in host.sessions:
		# Inactive tabs may pause their replicas. Visit each real pane before
		# checking its output instead of assuming background frames are streamed.
		host.focus_pane("%%%d" % id)
		var terminal: Node = host.sessions[id].term
		var marker := "MULTI_READY_%d" % id
		terminal.send_text("Write-Output ('MULTI_' + 'READY_%d')\r" % id)
		if not await wait_for(func(): return marker in str(terminal.get_text(false).text)):
			fail("A real shell did not become ready")
			return
		panes.append({"id": id, "pid": terminal.get_shell_pid(), "marker": marker})
	host.focus_pane("%%%d" % panes[0].id)
	for frame in 3:
		await process_frame
		RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("two-panes.png"))
	FileAccess.open(directory.path_join("ready.json"), FileAccess.WRITE).store_string(JSON.stringify({"panes": panes, "tab": host.workspace_layout.active}))
	if not await wait_for(func(): return FileAccess.file_exists(directory.path_join("close")), 40.0):
		fail("Controller did not retain the original processes")
		return
	# The normal tab-close action must close both idle shells and this frontend,
	# while the other detached workspace remains owned by the same server.
	if route in ["pane-menu", "pane-shortcut", "shell-exit", "shell-eof"]:
		while host.sessions.size() > 1:
			var count: int = host.sessions.size()
			await close_pane(host)
			if not await wait_for(func(): return host.sessions.size() == count - 1 and not host.session_backend.work_pending()):
				fail("Intermediate pane close did not preserve the remaining shells")
				return
		FileAccess.open(directory.path_join("intermediate.json"), FileAccess.WRITE).store_string(JSON.stringify({"id": host.active_session_id, "pid": host.active_terminal().get_shell_pid()}))
		if not await wait_for(func(): return FileAccess.file_exists(directory.path_join("continue"))):
			fail("Controller did not verify the intermediate closure")
			return
		await close_pane(host)
	elif route == "detached-exit":
		for pair in host.sessions.values():pair.term.send_text("Start-Sleep -Seconds 2; exit\r")
		quit(0)
		return
	elif route == "window-close":
		host.request_close_window()
		if await wait_for(func():return host.close_dialog!=null and host.close_dialog.visible,2):
			RenderingServer.force_draw(false)
			host.close_dialog.get_texture().get_image().save_png(directory.path_join("window-close-dialog.png"))
			host.close_dialog.get_ok_button().pressed.emit()
	elif route != "cli":
		host.request_close_tab()
	await create_timer(8.0).timeout
	fail("Frontend did not exit naturally after its final tab closed")
