extends "font-controls.gd"
var samples: Dictionary = {}
var skip_styles := false

func sample(config: Dictionary, name: String) -> bool:
	if not await apply_font(config):return false
	var text: String="\u001b[2J\u001b[H\u001b[0mMMMM minimum -> != === Ω 한글 가나다 😀🚀\r\n\u001b[1mMMMM minimum -> != === Ω 한글 가나다 😀🚀\r\n\u001b[0;3mMMMM minimum -> != === Ω 한글 가나다 😀🚀\r\n\u001b[1;3mMMMM minimum -> != === Ω 한글 가나다 😀🚀\u001b[0m\u001b[10;1H\u001b[?25l"
	text += "\u001b[?25h\u001b[10;%dH" % (sequence+2)
	if not await command(text,Vector2i(sequence+1,9)):return false
	await hold(.25)
	snap(name)
	samples[name]={"config":config.duplicate(true),"cell":[terminal.get_cell_size().x,terminal.get_cell_size().y],"grid":[terminal.get_grid_size().x,terminal.get_grid_size().y],"padding":terminal.cell_padding,"faces":connection.topology.terminal_font.faces}
	FileAccess.open(directory.path_join("samples.json"),FileAccess.WRITE).store_string(JSON.stringify(samples,"  "))
	return true

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal=host.active_terminal()
	connection=host.session_backend.connection
	original_config=connection.fonts_for(host.active_session_id).config.duplicate(true)
	var pid: int=terminal.get_shell_pid()
	var python:=OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe:=ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"),FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s' --timeout 120{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	var release: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	var config:=original_config.duplicate(true)
	config.size=20
	config.cell_width=14
	config.cell_height=28
	config.paths=["C:/Windows/Fonts/cour.ttf","C:/Windows/Fonts/cour.ttf","C:/Windows/Fonts/cour.ttf","C:/Windows/Fonts/cour.ttf"]
	config.fallbacks=["Malgun Gothic","Gulim"]
	if not skip_styles:
		if not await sample(config,"font-style-control"):return
		for style in [[1,"courbd.ttf","bold"],[2,"couri.ttf","italic"],[3,"courbi.ttf","bold-italic"]]:
			var changed:=config.duplicate(true)
			changed.paths[int(style[0])]="C:/Windows/Fonts/"+style[1]
			if not await sample(changed,"font-style-"+style[2]):return
	config.paths=["C:/Windows/Fonts/SegUIVar.ttf"]
	config.variations={"wght":350.0}
	if not await sample(config,"font-variable350"):return
	config.variations={"wght":650.0}
	if not await sample(config,"font-variable650"):return
	config.paths=[]
	config.family=""
	config.variations={}
	config.features={"liga":1,"calt":1}
	config.ligatures=true
	if not await sample(config,"font-ligatures-on"):return
	config.features={"liga":0,"calt":0}
	if not await sample(config,"font-features-off"):return
	config.features={"liga":1,"calt":1}
	config.ligatures=false
	if not await sample(config,"font-ligatures-off"):return
	config.paths=["C:/Windows/Fonts/cour.ttf"]
	config.features={}
	config.ligatures=true
	if not await sample(config,"font-symbol-control"):return
	config.symbol_maps=[{"first":937,"last":937,"family":"Arial"}]
	if not await sample(config,"font-symbol-omega"):return
	config.symbol_maps=[]
	config.fallbacks=["Gulim","Malgun Gothic"]
	if not await sample(config,"font-fallback-gulim"):return
	FileAccess.open(directory.path_join("samples.json"),FileAccess.WRITE).store_string(JSON.stringify(samples,"  "))
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text.is_empty(),"Font raster controls send no raw shell input")
	check(terminal.get_shell_pid()==pid,"All font raster cases preserve original shell")
	release.call()
