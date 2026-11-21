extends "mouse-selection.gd"

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"), FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")): return
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	var config: Config = host.world.terminal_config.copy()
	config.copy_on_select = "none"
	config.apply_live(terminal)
	if not await command("\u001b[2J\u001b[2;1Halpha-beta gamma\u001b[4;1HABCDEFGHIJKLMNOP\u001b[5;1HMNOPQRSTUVWXYZ\u001b[8;1H",Vector2i(0,7)):return
	await button_at(Vector2(4.1,3.5),true,KEY_MASK_ALT)
	await move_to(Vector2(7.9,4.5),KEY_MASK_ALT)
	await button_at(Vector2(7.9,4.5),false,KEY_MASK_ALT)
	var rectangle := copied()
	FileAccess.open(directory.path_join("rectangle.json"),FileAccess.WRITE).store_string(JSON.stringify(rectangle))
	check(rectangle.replace("\r\n","\n")=="EFGH\nQRST","Exact rectangle text: "+JSON.stringify(rectangle))
	snap("selection-rectangle")
	await hold(.6)
	await button_at(Vector2(0.1,1.5),true)
	await move_to(Vector2(4.9,1.5))
	var size: int = terminal.get_live_font_size()
	host.session_backend.connection.send_action("font_size",host.active_session_id,{"size":size+2})
	var deadline := Time.get_ticks_msec()+5000
	while terminal.get_live_font_size()==size and Time.get_ticks_msec()<deadline:await process_frame
	await hold(.5)
	DisplayServer.clipboard_set("NO_SELECTION")
	var after := copied()
	check(after=="NO_SELECTION","Selection clears after owner font commit: "+JSON.stringify(after))
	snap("selection-font-reset")
	await button_at(Vector2(4.9,1.5),false)
	await hold(.6)
	await click_cell(Vector2(2.5,1.5))
	await click_cell(Vector2(2.5,1.5))
	check(copied()=="alpha-beta","Double click works after font replacement")
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text=="","Focused selection checks emit no PTY input")
	check(terminal.get_shell_pid()==pid,"Selection followup preserves shell")
	release.call()
