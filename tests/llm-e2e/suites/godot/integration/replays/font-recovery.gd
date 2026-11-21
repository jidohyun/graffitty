extends "font-controls.gd"
func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal=host.active_terminal()
	connection=host.session_backend.connection
	var pid: int=terminal.get_shell_pid()
	var python:=OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe:=ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"),FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	var stop_effects: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	if not await command("\u001b[2J\u001b[2;1Ha != b -> c === d\u001b[3;1HΩ 한글 é\u001b[10;8H",Vector2i(7,9)):return
	await drag(cell_point(Vector2(.1,1.5)),cell_point(Vector2(16.9,1.5)),.15)
	terminal.perform_action("copy")
	check(DisplayServer.clipboard_get()=="a != b -> c === d","Selection over actual ligatures copies original ASCII operators")
	snap("font-shaped-selection")
	await click(cell_point(Vector2(25,5)))
	await drag(cell_point(Vector2(.1,2.5)),cell_point(Vector2(7.9,2.5)),.15)
	terminal.perform_action("copy")
	check(DisplayServer.clipboard_get()=="Ω 한글 é","Greek, Hangul and combining accent preserve exact Unicode copy")
	snap("font-unicode-combining")
	var config: Dictionary=connection.fonts_for(host.active_session_id).config.duplicate(true)
	var invalid:=config.duplicate(true)
	invalid.paths=["D:/missing/recovery.ttf"]
	var reply: Dictionary=await connection.request_action("font_config",{"config":invalid})
	check(reply.type=="error" and terminal.get_shell_pid()==pid,"Missing font rejects explicitly without replacing shell")
	config.family="Courier New"
	config.size=20
	if not await apply_font(config):return
	await hold(.3)
	FileAccess.open(directory.path_join("grid-request-recovery"),FileAccess.WRITE).store_string("")
	if not await wait_file(directory.path_join("grid-response-recovery")):return
	var actual: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("grid-response-recovery")))
	check(terminal.get_grid_size()==Vector2i(actual.columns,actual.rows),"Changed font size matches real ConPTY dimensions")
	snap("font-family-recovered")
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if not await wait_file(directory.path_join("receipt.json")):return
	var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
	check(receipt.text.is_empty(),"Font recovery and shaped selections send no stray terminal input")
	if not await until(func():return "PRIVATE_INPUT_FINISHED" in str(terminal.get_text(false).text),"Raw reader returns control to original shell"):return
	await type("Write-Output 'FONT_RECOVERY_ALIVE_147'{enter}")
	await until(func():return Array(str(terminal.get_text(false).text).split("\n")).any(func(line):return line.strip_edges()=="FONT_RECOVERY_ALIVE_147"),"Original shell executes a new command after font recovery")
	check(terminal.get_shell_pid()==pid,"Recovery retains original shell PID")
	stop_effects.call()
