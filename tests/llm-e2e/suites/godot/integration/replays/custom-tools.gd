extends "mouse-selection.gd"
var only_labels := false

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var original_size: int = terminal.get_live_font_size()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Custom tools reader starts"): return
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	var argv: Array = []
	var config = host.world.terminal_config.copy()
	config.quick_select_defaults = false
	config.quick_select_alphabet = "xy"
	config.quick_select_patterns = PackedStringArray([r"ISSUE-(\d+)"])
	config.hyperlink_patterns = PackedStringArray([r"https://allowed\.test/[^\s]+"])
	config.hyperlink_handler = func(uri): argv.append(["handler", "literal space $value `tick`;", uri])
	config.apply_live(terminal)
	if not await command("\u001b[2J\u001b[2;1HISSUE-123 ISSUE-456\u001b[4;1Hhttps://allowed.test/a;$x`y\u001b[5;1Hhttps://ignored.test/no\u001b[8;1H", Vector2i(0,7)): return
	terminal.perform_action("quick_select")
	await process_frame
	var state: Dictionary = terminal.get_quick_select_state()
	if not check(state.matches.size()==2, "Only configured ISSUE captures match"): return
	var labels := {}
	for item in state.matches: labels[item.text] = item.label
	check(labels=={"123":"y","456":"x"}, "Capture groups use configured x/y labels, newest match first")
	snap("custom-quick-select-labels")
	await letters(labels["123"])
	check(DisplayServer.clipboard_get()=="123", "Configured lowercase label copies captured digits")
	terminal.perform_action("quick_select")
	await process_frame
	await letters(str(labels["456"]).to_upper())
	if only_labels:
		FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
		if check(await wait_file(directory.path_join("receipt.json")), "Focused label reader completes"):
			var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
			check(receipt.text=="456","Only deliberate uppercase capture reaches PTY: "+receipt.utf8_hex)
		check(terminal.get_shell_pid()==pid,"Configured labels preserve shell PID")
		release.call()
		return
	await click_cell(Vector2(5.5,3.5),KEY_MASK_CTRL)
	await click_cell(Vector2(5.5,4.5),KEY_MASK_CTRL)
	await process_frame
	check(argv == [["handler","literal space $value `tick`;","https://allowed.test/a;$x`y"]], "Only configured link resolves and callable preserves literal argument text")
	FileAccess.open(directory.path_join("handler-argv.json"),FileAccess.WRITE).store_string(JSON.stringify(argv))
	var sizes: Array = []
	for size in [1,4,7,original_size]:
		host.session_backend.connection.send_action("font_size",host.active_session_id,{"size":size,"remember":false})
		var deadline := Time.get_ticks_msec()+5000
		while terminal.get_live_font_size()!=size and Time.get_ticks_msec()<deadline: await process_frame
		await hold(.4)
		FileAccess.open(directory.path_join("grid-request-%d" % size),FileAccess.WRITE).store_string("")
		if not check(await wait_file(directory.path_join("grid-response-%d" % size)), "Real PTY grid available at font %d" % size): return
		var grid: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("grid-response-%d" % size)))
		check(terminal.get_live_font_size()==size and terminal.get_grid_size()==Vector2i(grid.columns,grid.rows), "Font %d native grid matches real ConPTY dimensions" % size)
		sizes.append({"font_size":size,"columns":grid.columns,"rows":grid.rows,"pid":grid.pid})
	FileAccess.open(directory.path_join("grids.json"),FileAccess.WRITE).store_string(JSON.stringify(sizes,"  "))
	if not await command("\u001b[2J\u001b[2;1HCUSTOM TOOLS RESTORED\u001b[4;1HISSUE-123 ISSUE-456\u001b[6;1H",Vector2i(0,5)):return
	snap("custom-tools-restored")
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Custom tools reader completes"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text=="456","Only deliberate uppercase capture reaches PTY: "+receipt.utf8_hex)
	check(terminal.get_shell_pid()==pid,"Tiny fonts and custom tools preserve shell PID")
	release.call()
