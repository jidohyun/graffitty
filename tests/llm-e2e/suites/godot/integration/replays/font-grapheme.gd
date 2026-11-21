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
	if not await command("\u001b[2J\u001b[2;1Hé\u001b[3;1Hé\u001b[5;1HΩ 한글 é 👩‍💻\u001b[10;8H\u001b[?25l",Vector2i(-1,-1)):return
	await hold(.25)
	snap("font-grapheme-composition")
	await drag(cell_point(Vector2(.1,1.5)),cell_point(Vector2(.9,1.5)),.15)
	terminal.perform_action("copy")
	check(DisplayServer.clipboard_get()=="é","Shaped grapheme preserves decomposed clipboard bytes")
	await click(cell_point(Vector2(20,5)))
	if not await command("\u001b[2 q\u001b[?25h\u001b[2;1H",Vector2i(0,1)):return
	await hold(.15)
	snap("font-grapheme-cursor-decomposed")
	if not await command("\u001b[3;1H",Vector2i(0,2)):return
	await hold(.15)
	snap("font-grapheme-cursor-composed")
	var vp: SubViewport=host.sessions[host.active_session_id].vp
	FileAccess.open(directory.path_join("grapheme-geometry.json"),FileAccess.WRITE).store_string(JSON.stringify({"cell":[terminal.get_cell_size().x,terminal.get_cell_size().y],"position":[terminal.position.x,terminal.position.y],"padding":terminal.cell_padding,"scale":[float(vp.size.x)/vp.size_2d_override.x,float(vp.size.y)/vp.size_2d_override.y]},"  "))
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text.is_empty(),"Grapheme selection and cursor rendering send no shell input")
	check(terminal.get_shell_pid()==pid,"Grapheme rendering preserves shell")
	stop_effects.call()
