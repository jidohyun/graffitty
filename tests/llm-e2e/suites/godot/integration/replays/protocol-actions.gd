extends "rich-clipboard.gd"

func start_probe(path: String) -> bool:
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), path.replace("'", "''")])
	return await wait_file(path.path_join("ready"))


func link_click(cell: Vector2) -> void:
	var view: Control = host.workspace_view
	var local: Vector2 = terminal.position + Vector2.ONE * float(terminal.cell_padding) + terminal.get_cell_size() * cell
	var at: Vector2 = view.window_point(view.terminal_origin(host.pane_focus) + local * view.terminal_scale(host.pane_focus))
	await point_at(at)
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.position = at
	event.global_position = at
	event.button_index = MOUSE_BUTTON_LEFT
	event.ctrl_pressed = true
	for down in [true, false]:
		event.pressed = down
		root.push_input(event, true)
		await process_frame


func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	if OS.get_environment("GRAFFITTY_LINKS_ONLY") == "1":
		if not check(await start_probe(directory), "Raw reader starts for focused link check"): return
		await verify_links()
		return
	var original_id: int = host.active_session_id
	var original_pid: int = terminal.get_shell_pid()
	check(await host.set_pane_title("%%%d" % original_id, "OSC52 acceptance"), "Owner names the requesting terminal")
	for child in terminal.get_children():
		if child is IntegrationUI: integration = child
	terminal.set("clipboard_read", 2)
	terminal.set("clipboard_write", true)
	terminal.set("open_hyperlinks", false)
	if not check(await start_probe(directory), "Raw OSC52 reader starts in original shell"): return
	var expected_initial := int(FileAccess.get_file_as_string(directory.path_join("expected-initial-bytes")))
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(directory.path_join("received-bytes")) and int(FileAccess.get_file_as_string(directory.path_join("received-bytes"))) >= expected_initial: break
		await process_frame
	if not check(FileAccess.file_exists(directory.path_join("received-bytes")) and int(FileAccess.get_file_as_string(directory.path_join("received-bytes"))) == expected_initial, "Unicode OSC52 writes and BEL/ST queries cross the real PTY"): return
	terminal.set("clipboard_write", false)
	await phase(1)
	terminal.set("clipboard_read", 0)
	await phase(2)
	terminal.set("clipboard_read", 1)
	await phase(3)
	if not await consent(): return
	overlay.hide()
	await process_frame
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("osc52-ask-dialog.png"))
	check("OSC52 acceptance" in integration.dialog.dialog_text and is_instance_valid(integration.shade), "Consent identifies pane and dims workspace without revealing data")
	await consent_click(false)
	await phase(4)
	if not await consent(): return
	var used_id: int = integration.request_id
	await consent_click(true)
	terminal.answer_clipboard_read(used_id, true)
	await phase(5)
	if not await consent(): return
	check(integration.request_id != used_id, "Each request gets fresh consent; reused ID cannot authorize again")
	var grid: Vector2i = terminal.get_grid_size()
	terminal.remote_feed_stream(PackedByteArray(), grid.x, grid.y, true, false)
	await consent_click(true)
	await phase(6)
	if not await consent(): return
	await consent_click(true)
	var original_terminal: Node = terminal
	var original_integration: Node = integration
	host.create_terminal_window()
	deadline = Time.get_ticks_msec() + 10000
	while (host.sessions.size() < 2 or host.active_session_id == original_id) and Time.get_ticks_msec() < deadline: await process_frame
	if not check(host.sessions.size() == 2 and host.active_session_id != original_id, "Create independent pane for close-with-consent check"): return
	var closed_id: int = host.active_session_id
	terminal = host.active_terminal()
	terminal.set("clipboard_read", 1)
	for child in terminal.get_children():
		if child is IntegrationUI: integration = child
	if not check(await start_probe(directory.path_join("closed-pane")), "Second pane requests clipboard through its own PTY"): return
	if not await consent(): return
	var pending_dialog: Window = integration.dialog
	var pending_terminal: Node = terminal
	host._close_terminal_pane(closed_id)
	deadline = Time.get_ticks_msec() + 10000
	while host.sessions.has(closed_id) and Time.get_ticks_msec() < deadline: await process_frame
	await process_frame
	check(not host.sessions.has(closed_id) and not is_instance_valid(pending_dialog) and not is_instance_valid(pending_terminal), "Closing requester destroys its consent and terminal; stale buttons cannot act")
	terminal = original_terminal
	integration = original_integration
	check(terminal.get_shell_pid() == original_pid, "Unrelated original shell survives closed requester")
	await camera_at_rest()
	await verify_links()

func verify_links() -> void:
	if OS.get_environment("GRAFFITTY_LINKS_ONLY") == "1":
		await hold(.5)
	else:
		await phase(7)
	terminal.set("open_hyperlinks", false)
	check(not terminal.get("open_hyperlinks"), "External link opening is disabled before projected clicks")
	var activated: Array[String] = []
	terminal.hyperlink_activated.connect(func(uri): activated.append(uri))
	check(terminal.get_hyperlink_at(Vector2i(4, 0)) == "https://example.invalid/actual?x=4729", "OSC8 visible label differs from its actual target")
	check(terminal.get_hyperlink_at(Vector2i(5, 1)) == "https://example.invalid/plain", "Plain URL resolves to exact visible target")
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("terminal-hyperlinks.png"))
	await link_click(Vector2(4.5, .5))
	await link_click(Vector2(5.5, 1.5))
	await link_click(Vector2(4.5, 2.5))
	check(activated == ["https://example.invalid/actual?x=4729", "https://example.invalid/plain"], "Projected Ctrl-clicks activate only exact safe targets with external opening disabled")
	terminal.activate_hyperlink("javascript:alert(4729)")
	check(activated.size() == 2, "Unsupported URI schemes never activate")
	await hold(.3)
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Raw reader records complete OSC52 result"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == FileAccess.get_file_as_string(directory.path_join("expected.txt")), "Exact Unicode/BEL/ST replies; denied writes preserve value; denial, reused ID, checkpoint and links leak no bytes")
