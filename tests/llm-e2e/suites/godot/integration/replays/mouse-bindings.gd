extends "input-routing.gd"

func play() -> void:
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	var terminal: Node = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Raw mouse reader starts inside the actual shell"):
		return
	var config := Config.new()
	config.mouse_bindings = [Config.MouseBinding.new(MOUSE_BUTTON_XBUTTON1, "send_text:BACK"),
		Config.MouseBinding.new(MOUSE_BUTTON_XBUTTON2, "send_text:FORWARD"),
		Config.MouseBinding.new(MOUSE_BUTTON_WHEEL_LEFT, "send_text:LEFT")]
	config.copy_on_select = "none"
	check(config.validate().is_empty(), "Configured mouse routes validate")
	config.apply_live(terminal)
	var viewport: SubViewport = host.sessions[host.active_session_id].vp
	preload("res://scenes/TerminalViewportInput.gd").set_pointer_inside(viewport, true)
	for button in [MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON_XBUTTON2, MOUSE_BUTTON_WHEEL_LEFT]:
		var event := InputEventMouseButton.new()
		event.button_index = button
		event.position = Vector2(60, 60)
		for down in [true, false]:
			event.pressed = down
			viewport.push_input(event, true)
			await process_frame
	await hold(.5)
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Raw program records mouse actions"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "BACKFORWARDLEFT", "Configured side buttons and horizontal wheel deliver exact bytes, with releases consumed: %s" % receipt.utf8_hex)
	check(terminal.get_shell_pid() == pid, "Mouse config preserves the original shell")
