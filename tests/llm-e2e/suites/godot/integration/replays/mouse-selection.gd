extends "terminal-tools.gd"
const SelectionSettings = preload("res://scenes/TerminalSelectionSettings.gd")

func button_at(cell: Vector2, down: bool, modifiers := 0, button := MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.position = cell_point(cell)
	event.global_position = event.position
	event.button_index = button
	event.pressed = down
	event.ctrl_pressed = bool(modifiers & KEY_MASK_CTRL)
	event.shift_pressed = bool(modifiers & KEY_MASK_SHIFT)
	event.alt_pressed = bool(modifiers & KEY_MASK_ALT)
	root.push_input(event, true)
	await process_frame

func move_to(cell: Vector2, modifiers := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.device = REPLAY_POINTER_DEVICE
	event.position = cell_point(cell)
	event.global_position = event.position
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.alt_pressed = bool(modifiers & KEY_MASK_ALT)
	event.ctrl_pressed = bool(modifiers & KEY_MASK_CTRL)
	root.push_input(event, true)
	await process_frame

func click_cell(cell: Vector2, modifiers := 0, button := MOUSE_BUTTON_LEFT) -> void:
	await button_at(cell, true, modifiers, button)
	await button_at(cell, false, modifiers, button)

func copied() -> String:
	terminal.perform_action("copy")
	return DisplayServer.clipboard_get()

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'", "''"), probe.replace("'", "''"), directory.replace("'", "''")])
	if not check(await wait_file(directory.path_join("ready")), "Selection reader starts"): return
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	await menu("Edit::Selection Preferences…")
	var dialog: Node
	for child in host.get_children():
		if child is SelectionSettings: dialog = child
	if not check(dialog != null, "Selection preferences open through menu"): return
	dialog.bypass.text = "Ctrl+Bogus"
	dialog.get_ok_button().pressed.emit()
	check("Use Ctrl" in dialog.status.text, "Invalid bypass rejected without mutation")
	dialog.bypass.text = "Ctrl"
	dialog.copy_policy.select(0)
	dialog.get_ok_button().pressed.emit()
	await process_frame
	check(dialog.status.text == "Selection preferences applied.", "Actual selection controls apply")
	capture("selection-preferences")
	dialog.canceled.emit()
	await process_frame
	var config: Config = host.world.terminal_config.copy()
	# Remove link activation so Ctrl bypass explicitly selects text.
	config.mouse_bindings = [Config.MouseBinding.new(MOUSE_BUTTON_LEFT,"select"),Config.MouseBinding.new(MOUSE_BUTTON_LEFT,"select",KEY_MASK_ALT),Config.MouseBinding.new(MOUSE_BUTTON_MIDDLE,"ignore")]
	config.apply_live(terminal)
	if not await command("\u001b[2J\u001b[2;1Halpha-beta gamma\u001b[4;1HABCDEFGHIJKLMNOP\u001b[5;1HMNOPQRSTUVWXYZ\u001b[8;1H", Vector2i(0,7)): return
	for i in 3: await click_cell(Vector2(3.5,1.5))
	check(copied().strip_edges() == "alpha-beta gamma", "Triple click copies complete line")
	snap("selection-line")
	await hold(.6)
	await button_at(Vector2(4.1,3.5),true,KEY_MASK_ALT)
	await move_to(Vector2(7.9,4.5),KEY_MASK_ALT)
	await button_at(Vector2(7.9,4.5),false,KEY_MASK_ALT)
	check(copied().replace("\r\n","\n") == "EFGH\nQRST", "Alt rectangle copies exactly EFGH and QRST with native Windows line endings")
	snap("selection-rectangle")
	if not await command("\u001b[?1000h\u001b[?1006h\u001b[9;1H", Vector2i(0,8)): return
	await click_cell(Vector2(8.5,5.5))
	await click_cell(Vector2(8.5,5.5),KEY_MASK_SHIFT)
	await click_cell(Vector2(8.5,5.5),KEY_MASK_CTRL)
	if not await command("\u001b[?1000l\u001b[?1006l\u001b[10;1H", Vector2i(0,9)): return
	await click_cell(Vector2(8.5,5.5),0,MOUSE_BUTTON_MIDDLE)
	await hold(.6)
	await button_at(Vector2(0.1,1.5),true)
	await move_to(Vector2(4.9,1.5))
	var size: int = terminal.get_live_font_size()
	host.session_backend.connection.send_action("font_size", host.active_session_id, {"size":size+2})
	var deadline := Time.get_ticks_msec()+5000
	while terminal.get_live_font_size()==size and Time.get_ticks_msec()<deadline: await process_frame
	check(terminal.get_live_font_size()==size+2, "Owner replaces streamed font during held drag")
	await hold(.5)
	DisplayServer.clipboard_set("NO_SELECTION")
	check(copied()=="NO_SELECTION", "Font replacement clears old selection")
	await button_at(Vector2(4.9,1.5),false)
	await hold(.6)
	await click_cell(Vector2(2.5,1.5))
	await click_cell(Vector2(2.5,1.5))
	check(copied()=="alpha-beta", "Fresh double click works after replacement")
	snap("selection-after-font")
	FileAccess.open(directory.path_join("finish"), FileAccess.WRITE).store_string("")
	if check(await wait_file(directory.path_join("receipt.json")), "Selection reader completes"):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text == "\u001b[<0;9;6M\u001b[<0;9;6m\u001b[<4;9;6M\u001b[<4;9;6m", "Ordinary and Shift SGR bytes exact; Ctrl bypass and ignored middle emit nothing: "+receipt.utf8_hex)
	check(terminal.get_shell_pid()==pid, "Selection preserves shell PID")
	check(not DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD_PRIMARY), "Windows correctly advertises no primary-selection clipboard")
	release.call()
