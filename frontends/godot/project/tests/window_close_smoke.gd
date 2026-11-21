extends "res://tests/terminal_space_smoke.gd"
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")
var app: Node

func _initialize() -> void:
	Background.install(self)
	super._initialize()

func settled(host: Node) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(host) and (not host.session_backend.connection.connected or host.session_backend.work_pending()) and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(.3).timeout

func new_window(args: PackedStringArray = []) -> Node:
	var count: int = app.hosts.size()
	app.open_local_session(args, OS.get_environment("GRAFFITTY_INITIAL_PWD"))
	var deadline := Time.get_ticks_msec() + 10000
	while app.hosts.size() == count and Time.get_ticks_msec() < deadline: await process_frame
	var host: Node = app.hosts.back()
	await settled(host)
	return host

func ask(host: Node) -> ConfirmationDialog:
	host.get_window().close_requested.emit()
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(host) and (host.close_dialog == null or not host.close_dialog.visible) and Time.get_ticks_msec() < deadline: await process_frame
	check(is_instance_valid(host) and host.close_dialog != null and host.close_dialog.visible, "Native × opens the choice")
	return host.close_dialog if is_instance_valid(host) else null

func activate(button: Button) -> void:
	# Drive the actual native dialog button through its keyboard input path.
	button.grab_focus()
	await key(button.get_window(), KEY_SPACE)

func key(prompt: Window, code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		prompt.push_input(event, true)
		await process_frame
	await create_timer(.15).timeout

func alive(pid: int) -> bool:
	if pid <= 0: return false
	# Godot's Windows process map only knows children it launched itself;
	# the private server owns these PTYs. Exact-handle shutdown assertions
	# are covered separately by test_last_session_shutdown.py.
	if OS.get_name() == "Windows":
		return OS.execute("powershell.exe", ["-NoProfile", "-Command",
			"if (Get-Process -Id %d -ErrorAction SilentlyContinue) { exit 0 }; exit 1" % pid], [], false) == 0
	return OS.execute("/bin/kill", ["-0", str(pid)], [], false) == 0

func labels(prompt: ConfirmationDialog) -> Array:
	return prompt.get_ok_button().get_parent().get_children().filter(func(button): return button is Button and button.visible).map(func(button): return button.text)

func listed(host: Node, session: String) -> bool:
	await host.session_backend.connection.request_action("sync")
	return host.session_backend.connection.available_sessions.any(func(row): return row.id == session)

func wait_closed(host) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while is_instance_valid(host) and Time.get_ticks_msec() < deadline: await process_frame
	check(not is_instance_valid(host), "Window is retired")

func run() -> void:
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if wrapper.host == null: check(false, "Startup host"); quit(1); return
	var first: Node = wrapper.host
	app = first.application
	await settled(first)
	var original: String = wrapper.connection.workspace
	var original_pid: int = first.active_terminal().get_shell_pid()
	# × never ends a session silently, even one idle pane: it always asks.
	var idle := await new_window()
	var idle_session: String = idle.session_backend.connection.workspace
	var idle_pid: int = idle.active_terminal().get_shell_pid()
	var prompt := await ask(idle)
	if prompt == null: quit(1); return
	check(labels(prompt) == ["Kill Server", "Detach", "Cancel"], "Local close offers exactly Kill Server, Detach and Cancel: " + str(labels(prompt)))
	check(prompt.ok_button_text == "Detach", "Detach is the dialog's confirm action")
	for tick in 4: await process_frame
	check(prompt.size.y <= maxf(180, prompt.get_contents_minimum_size().y) * prompt.content_scale_factor + 8, "Close dialog fits its text and actions without excess height")
	var content_rect := Rect2(Vector2.ZERO, Vector2(prompt.size) / prompt.content_scale_factor)
	for button in prompt.get_ok_button().get_parent().get_children():
		check(content_rect.grow(1).encloses(button.get_global_rect()), "Close action is fully inside the native dialog")
	check(prompt.get_label().get_global_rect().end.y <= prompt.get_ok_button().get_parent().global_position.y, "Native text stays above the action row")
	check(prompt.get_cancel_button().has_focus(), "Cancel starts focused")
	await key(prompt, KEY_ENTER)
	check(is_instance_valid(idle) and idle.close_dialog == null, "Enter cancels")
	prompt = await ask(idle)
	await activate(prompt.get_cancel_button())
	check(is_instance_valid(idle) and idle.close_dialog == null and alive(idle_pid), "Cancel keeps the window and its shell")
	prompt = await ask(idle)
	var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	# A headless engine never draws, so there is no frame to wait for or capture.
	if not evidence.is_empty() and DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		RenderingServer.force_draw(false)
		prompt.get_texture().get_image().save_png(evidence.path_join("close-dialog.png"))
	await activate(prompt.get_ok_button())
	await wait_closed(idle)
	check(await listed(first, idle_session) and alive(idle_pid), "Detaching an idle window keeps its session and shell")
	check(alive(original_pid), "Other session remains alive")
	await wrapper.connection.request_action("create", {"kind": "pane", "session": first.active_session_id})
	await wrapper.connection.request_action("sync")
	await settled(first)
	var anchor := await new_window()
	var anchor_pid: int = anchor.active_terminal().get_shell_pid()
	prompt = await ask(first)
	if prompt == null: quit(1); return
	await activate(prompt.get_ok_button())
	await wait_closed(first)
	await settled(anchor)
	check(await listed(anchor, original) and alive(original_pid), "Detach retains the numbered session and its original shell")
	check(anchor.get_window() == root, "Surviving window is promoted into the root shell")
	# Verify the promoted root's × was reconnected to this policy.
	prompt = await ask(anchor)
	if prompt == null: quit(1); return
	await activate(prompt.get_cancel_button())
	check(is_instance_valid(anchor) and alive(anchor_pid), "Promoted root's × still asks first")
	var attached := await new_window(PackedStringArray(["--workspace=" + original, "--attach-session"]))
	check(attached.sessions.size() == 2, "Detached session can be attached again with both panes")
	prompt = await ask(attached)
	if prompt == null: quit(1); return
	await activate(prompt.get_ok_button())
	await wait_closed(attached)
	check(await listed(anchor, original) and alive(original_pid), "Detaching again still keeps the session")
	check(alive(anchor_pid), "Closing other windows leaves the sibling shell unchanged")
	check(error_watch.errors.is_empty(), "No engine or script errors: " + str(error_watch.errors))
	if not failures.is_empty():
		print("WINDOW_CLOSE_FAIL")
		quit(1)
		return
	# The final window's Detach or Kill Server must quit naturally. The external
	# runner checks whether the owner survived (Detach) or stopped (Kill Server).
	prompt = await ask(anchor)
	if prompt == null: quit(1); return
	root.tree_exiting.connect(func(): print("WINDOW_CLOSE_PASS"), CONNECT_ONE_SHOT)
	if "--close-server" in OS.get_cmdline_user_args():
		var server_button: Button
		for button in prompt.get_ok_button().get_parent().get_children():
			if button is Button and button.text == "Kill Server": server_button = button
		check(server_button != null, "Kill Server is available on the local close dialog")
		if server_button == null: quit(1); return
		await activate(server_button)
	else:
		await activate(prompt.get_ok_button())
	await create_timer(5.0).timeout
	check(false, "Closing the final window quits the application")
	quit(1)
