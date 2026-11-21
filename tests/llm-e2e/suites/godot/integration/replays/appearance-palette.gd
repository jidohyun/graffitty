extends "appearance-details.gd"

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	if not await open_bistro(): return
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Palette raw reader starts in Bistro"): return
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	host.world.terminal_config.palette_overrides[240] = Color("#cc3399")
	var dialog := await open_appearance()
	dialog.colors.background.color = Color.BLACK
	dialog.colors.foreground.color = Color.WHITE
	dialog.colors.cursor_color.color = Color.RED
	dialog.numbers.opacity.text = "1"
	dialog.palette[1].color = Color.RED
	dialog.shape.select(Appearance.SHAPES.find("beam"))
	dialog.blink.select(Appearance.BLINK.find("off"))
	dialog.numbers.cursor_beam_thickness.text = "3"
	await apply_appearance(dialog)
	if not await command("\u001b[2J\u001b[2;3HPALETTE ACCEPTANCE\u001b[3;3H\u001b[31mMMMM\u001b[4;3H\u001b[38;2;18;52;86mMMMM\u001b[5;3H\u001b[38;5;240mMMMM\u001b[6;3H\u001b[0;97;41m EXPLICIT RED \u001b[0m\u001b[10;12H", Vector2i(11,9)): return
	overlay.hide()
	await hold(.1)
	snap("appearance-palette-default")
	if not await command("\u001b]4;1;rgb:00/ff/00\u001b\\\u001b[11;12H", Vector2i(11,10)): return
	await hold(.1)
	snap("appearance-palette-osc")
	if not await command("\u001b]104;1\u001b\\\u001b[10;12H", Vector2i(11,9)): return
	await hold(.1)
	snap("appearance-palette-reset")
	snap("appearance-opaque")
	dialog = await open_appearance()
	dialog.numbers.opacity.text = ".35"
	await apply_appearance(dialog)
	snap("appearance-translucent")
	dialog = await open_appearance()
	dialog.blink.select(Appearance.BLINK.find("on"))
	dialog.numbers.cursor_blink_interval_ms.text = "180"
	await apply_appearance(dialog)
	await capture_blink("appearance-cursor")
	dialog = await open_appearance()
	capture("appearance-dialog")
	dialog.canceled.emit()
	await process_frame
	FileAccess.open(directory.path_join("appearance-metrics.json"), FileAccess.WRITE).store_string(JSON.stringify({"cell":[terminal.get_cell_size().x,terminal.get_cell_size().y],"padding":terminal.cell_padding}, "  "))
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Palette raw reader finishes"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "", "Palette/opacity controls emit no terminal input")
	check(terminal.get_shell_pid() == pid, "Palette and opacity preserve original shell PID")
	release.call()
