extends "input-settings.gd"

func pointer_button(button: int, factor := 1.0, control := false) -> void:
	var terminal: Node = host.active_terminal()
	var view: Control = host.workspace_view
	var local: Vector2 = terminal.position + Vector2.ONE * float(terminal.cell_padding) + terminal.get_cell_size() * Vector2(8.5, 5.5)
	var at: Vector2 = view.window_point(view.terminal_origin(host.pane_focus) + local * view.terminal_scale(host.pane_focus))
	await point_at(at)
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.position = at
	event.global_position = at
	event.button_index = button
	event.factor = factor
	event.ctrl_pressed = control
	for down in [true, false]:
		event.pressed = down
		root.push_input(event, true)
		await process_frame

func play() -> void:
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	var terminal: Node = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	await type("1..160 | ForEach-Object { 'history {0:D3} needle' -f $_ }{enter}")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Raw reader starts after real numbered history"):
		return
	await camera_at_rest()
	var config: Config = host.world.terminal_config.copy()
	config.copy_on_select = "none"
	config.mouse_bindings = [Config.MouseBinding.new(MOUSE_BUTTON_WHEEL_LEFT, "scroll_up"),
		Config.MouseBinding.new(MOUSE_BUTTON_WHEEL_DOWN, "send_text:MOD", KEY_MASK_CTRL),
		Config.MouseBinding.new(MOUSE_BUTTON_XBUTTON1, "search"), Config.MouseBinding.new(MOUSE_BUTTON_XBUTTON2, "send_text:REMOVED")]
	host.world.terminal_config = config
	config.apply_live(terminal)
	terminal.scroll_to_row(20)
	await process_frame
	var before: int = terminal.get_ui_state().scroll_offset
	await pointer_button(MOUSE_BUTTON_WHEEL_LEFT, 1.0 / 6.0)
	check(terminal.get_ui_state().scroll_offset == before, "First partial horizontal wheel is accumulated")
	await pointer_button(MOUSE_BUTTON_WHEEL_LEFT, 1.0 / 6.0)
	check(terminal.get_ui_state().scroll_offset == before - 1, "Second partial horizontal wheel scrolls history exactly once")
	var zoom: float = host.world.gesture_zoom
	var anchors := [Vector2.ZERO, Vector2(800, 500), Vector2(1600, 1000)]
	var before_projection: Array[Vector2] = []
	for anchor in anchors:
		before_projection.append(host.workspace_view.window_point(anchor))
	await pointer_button(MOUSE_BUTTON_WHEEL_DOWN, 1.0, true)
	var drift := 0.0
	for index in anchors.size():
		drift = maxf(drift, before_projection[index].distance_to(host.workspace_view.window_point(anchors[index])))
	# camera_at_rest permits subpixel spring settling; compare displayed pixels,
	# not exact floating-point camera matrices between animation frames.
	check(is_equal_approx(host.world.gesture_zoom, zoom) and drift < .5, "Explicit modifier-wheel binding preserves camera (%.3f px drift)" % drift)
	var dialog := await open_settings()
	if not check(dialog != null, "Mouse bindings are editable in the real Input dialog"):
		return
	var back_row: HBoxContainer
	for row in dialog.mouse_rows.get_children():
		if row.get_child(0).get_selected_id() == MOUSE_BUTTON_XBUTTON1:
			back_row = row
		if row.get_child(0).get_selected_id() == MOUSE_BUTTON_XBUTTON2:
			row.get_child(3).pressed.emit()
	back_row.get_child(2).text = "activate_key_table:missing"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check("Invalid mouse action" in dialog.status.text, "Invalid mouse table reference rejects Apply")
	check(config.mouse_bindings.size() == 4, "Rejected mouse edit preserves all live bindings")
	back_row.get_child(2).text = "search"
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check(dialog.status.text == "Input settings applied.", "Removing a mouse binding applies")
	dialog.canceled.emit()
	await process_frame
	await pointer_button(MOUSE_BUTTON_XBUTTON2)
	await pointer_button(MOUSE_BUTTON_XBUTTON1)
	check(terminal.get_ui_state().modal == "search", "Projected Back event opens local search")
	for character in "needle":
		await press_key(character.to_upper().unicode_at(0), character.unicode_at(0))
	overlay.hide()
	await hold(.2)
	RenderingServer.force_draw(false)
	root.get_texture().get_image().save_png(directory.path_join("mouse-binding-search.png"))
	host.sessions[host.active_session_id].vp.get_texture().get_image().save_png(directory.path_join("mouse-search-terminal.png"))
	await press_key(KEY_ESCAPE)
	await hold(.5)
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Raw reader records projected mouse controls"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "MOD", "Only explicit modifier action reaches the PTY; unbound button and search keys do not: %s" % receipt.utf8_hex)
	check(terminal.get_shell_pid() == pid, "Mouse settings retain original shell")
