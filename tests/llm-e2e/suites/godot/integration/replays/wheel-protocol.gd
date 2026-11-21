extends "input-wheel.gd"
## Raw PTY wheel bytes in alternate-screen and SGR reporting modes.

func play() -> void:
	var directory := OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	var terminal: Node = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Raw reader starts inside actual shell"):
		return
	var viewport: SubViewport = host.sessions[host.active_session_id].vp
	preload("res://scenes/TerminalViewportInput.gd").set_pointer_inside(viewport, true)
	var config := Config.new()
	config.copy_on_select = "none"
	config.apply_live(terminal)
	var expected := ""
	var phase := 0
	for font in [16, 24, 32]:
		host.world._set_terminal_font_size(font)
		await owner_at_rest()
		await hold(.3)
		if not check(terminal.get_live_font_size() == font, "Protocol pane retains font size %d" % font):
			return
		var location: Vector2 = terminal.get_global_transform() * (Vector2.ONE * float(terminal.cell_padding) + terminal.get_cell_size() * Vector2(4.5, 3.5))
		for mode in ["disabled", "alternate", "tracking"]:
			phase += 1
			var modes := "\u001b[?1049h\u001b[?1l\u001b[?1000l\u001b[?1006l\u001b[?1007l"
			if mode == "alternate":
				modes += "\u001b[?1007h"
			elif mode == "tracking":
				modes += "\u001b[?1000h\u001b[?1006h"
			FileAccess.open(directory.path_join("phase-%d.vt" % phase), FileAccess.WRITE).store_string(modes)
			var marker := "PRIVATE_PHASE_%d_READY" % phase
			var deadline := Time.get_ticks_msec() + 10000
			while marker not in str(terminal.get_text(false).text) and Time.get_ticks_msec() < deadline:
				await process_frame
			if not check(marker in str(terminal.get_text(false).text), "Font %d: real PTY enables %s mode" % [font, mode]):
				return
			await hold(.3)
			await pan(viewport, location, 7.5)
			await pan(viewport, location, 7.5)
			var event := InputEventMouseButton.new()
			event.button_index = MOUSE_BUTTON_WHEEL_DOWN
			event.factor = 1.0
			event.position = location
			for down in [true, false]:
				event.pressed = down
				viewport.push_input(event, true)
				await process_frame
			if mode == "alternate":
				expected += "\u001b[B".repeat(4)
			elif mode == "tracking":
				expected += "\u001b[<65;5;4M".repeat(4)
	await hold(.5)
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Raw program records complete mode matrix"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == expected, "Exact alternate-scroll disabled/enabled and SGR fractional/notch bytes at all three fonts: %s" % receipt.utf8_hex)
	check(terminal.get_shell_pid() == pid, "All wheel modes preserve original shell")
