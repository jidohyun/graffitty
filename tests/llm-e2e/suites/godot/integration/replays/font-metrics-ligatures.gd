extends "font-raster.gd"

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal=host.active_terminal()
	connection=host.session_backend.connection
	original_config=connection.fonts_for(host.active_session_id).config.duplicate(true)
	var original: int=host.active_session_id
	var pid: int=terminal.get_shell_pid()
	var python:=OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe:=ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"),FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s' --timeout 120{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	var stop_effects: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	var config:=original_config.duplicate(true)
	config.size=20
	config.cell_width=14
	config.cell_height=28
	config.features={"liga":1,"calt":1}
	if not await sample(config,"font-ligatures-on"):return
	config.ligatures=false
	if not await sample(config,"font-ligatures-off"):return
	config.paths=["C:/Windows/Fonts/cour.ttf"]
	config.cell_height=24
	config.features={}
	config.ligatures=true
	if not await apply_font(config):return
	FileAccess.open(directory.path_join("grid-request-custom"),FileAccess.WRITE).store_string("")
	if not await wait_file(directory.path_join("grid-response-custom")):return
	var actual: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("grid-response-custom")))
	var grid: Vector2i=terminal.get_grid_size()
	check(Vector2i(actual.columns,actual.rows)==grid and terminal.get_cell_size()==Vector2(14,24),"Actual ConPTY grid agrees with custom 14 by 24 renderer cells")
	var bottom:="METRIC_BOTTOM_Ω"
	var text:="\u001b[2J\u001b[2;1Hfi -> !== === Ω 한글\u001b[%d;1HUPPER\u001b[%d;1H%s\u001b[6;5H\u001b_Ga=T,f=32,s=1,v=1,i=4729,c=4,r=2,q=2;/wD//w==\u001b\\\u001b[10;8H" % [grid.y-1,grid.y,bottom]
	if not await command(text,Vector2i(7,9)):return
	if not await until(func():return terminal.image_placements().size()==1,"Kitty image arrives through actual owner"):return
	var placement: Dictionary=terminal.image_placements()[0]
	check(placement.pixel_width==56 and placement.pixel_height==48 and placement.cols==4 and placement.rows==2,"Kitty placement uses four by two custom cells")
	await hold(.2)
	snap("font-custom-kitty")
	await drag(cell_point(Vector2(.1,1.5)),cell_point(Vector2(19.9,1.5)),.15)
	terminal.perform_action("copy")
	check(DisplayServer.clipboard_get()=="fi -> !== === Ω 한글","Shaped Unicode text copies exact logical cell content")
	await click(cell_point(Vector2(30,4)))
	var view: Node=host.workspace_view
	var center: Vector2=cell_point(Vector2(5,grid.y-.5))
	var viewport_bottom: float=root.get_visible_rect().end.y
	view.pan_workspace(Vector2(0,center.y-viewport_bottom),Vector2(800,500))
	await hold(.5)
	var edge: Vector2=cell_point(Vector2(5,grid.y-.5))
	check(absf(edge.y-viewport_bottom)<2,"Bottom row is half clipped by actual viewport edge")
	await drag(cell_point(Vector2(.1,grid.y-.75)),cell_point(Vector2(bottom.length()-.1,grid.y-.75)),.15)
	terminal.perform_action("copy")
	check(DisplayServer.clipboard_get()==bottom,"Half visible bottom row copies METRIC_BOTTOM_Ω, never UPPER")
	snap("font-custom-bottom-selected")
	view.show_main()
	for count in [2,3]:
		view.split_window("h")
		if not await until(func():return host.sessions.size()==count,"Narrow pane fixture creates live split"):return
		await camera_at_rest()
	var before: Dictionary={}
	for id in host.sessions: before[id]=host.sessions[id].term.get_grid_size()
	var invalid:=config.duplicate(true)
	# The largest valid cell cannot fit the minimum grid in a third-width pane.
	invalid.cell_width=512
	var reply: Dictionary=await connection.request_action("font_config",{"config":invalid})
	check(reply.type=="error" and "at least 2 columns" in str(reply.get("message","")),"Valid cell width rejected when minimum grid cannot fit narrow pane")
	for id in before:check(host.sessions[id].term.get_grid_size()==before[id],"Narrow rejection preserves pane %d grid" % id)
	check(connection.fonts_for(original).config==config and terminal.get_shell_pid()==pid,"Narrow rejection preserves font and original shell")
	FileAccess.open(directory.path_join("metrics.json"),FileAccess.WRITE).store_string(JSON.stringify({"grid":actual,"placement":placement,"partial_row_center":edge,"config":config},"  "))
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text.is_empty(),"Font metrics and selection controls leak no raw shell input")
	stop_effects.call()
