extends "input-routing.gd"

func play() -> void:
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("start.vt"), FileAccess.WRITE).store_string("\u001b[?1000h\u001b[?1006h")
	var terminal: Node = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Raw mouse reader starts"):
		return
	var deadline := Time.get_ticks_msec() + 10000
	while "PRIVATE_MODES_READY" not in str(terminal.get_text(false).text) and Time.get_ticks_msec() < deadline:
		await process_frame
	check("PRIVATE_MODES_READY" in str(terminal.get_text(false).text), "Real PTY enables SGR mouse tracking before input")
	var config := Config.new()
	config.copy_on_select = "none"
	config.mouse_bypass_modifiers = KEY_MASK_ALT
	config.mouse_bindings = [Config.MouseBinding.new(MOUSE_BUTTON_XBUTTON1, "send_text:LOCAL"),
		Config.MouseBinding.new(MOUSE_BUTTON_XBUTTON2, "activate_key_table:once")]
	var table := Config.KeyTable.new()
	table.bindings = [Config.KeyBinding.new(KEY_R, "send_text:TABLE")]
	config.key_tables["once"] = table
	check(config.validate().is_empty(), "Mouse bypass and one-shot table config validates")
	config.apply_live(terminal)
	var viewport: SubViewport = host.sessions[host.active_session_id].vp
	preload("res://scenes/TerminalViewportInput.gd").set_pointer_inside(viewport, true)
	var cell: Vector2 = terminal.get_cell_size()
	# push_input takes viewport coordinates; the terminal has its own pane inset.
	var location: Vector2 = terminal.get_global_transform() * (Vector2(terminal.cell_padding, terminal.cell_padding) + cell * Vector2(4.5, 3.5))
	var buttons := [MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON_XBUTTON2, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT, MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON_XBUTTON2]
	for index in buttons.size():
		var event := InputEventMouseButton.new()
		event.button_index = buttons[index]
		event.position = location
		# The first four use application reporting; the final two bypass it.
		event.alt_pressed = index >= 4
		for down in [true, false]:
			event.pressed = down
			viewport.push_input(event, true)
			await process_frame
	await press_key(KEY_R, 114)
	await press_key(KEY_R, 114)
	await hold(.5)
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Raw application records mouse reporting and bypass"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		var expected := "\u001b[<128;5;4M\u001b[<128;5;4m\u001b[<129;5;4M\u001b[<129;5;4m\u001b[<66;5;4M\u001b[<67;5;4MLOCALTABLEr"
		check(receipt.text == expected, "Exact SGR side-button releases, horizontal wheels, local bypass and one-shot table: %s" % receipt.utf8_hex)
	check(terminal.get_shell_pid() == pid, "Mouse protocol controls retain the original shell")
