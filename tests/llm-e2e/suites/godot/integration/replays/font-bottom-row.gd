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
	var config: Dictionary=connection.fonts_for(host.active_session_id).config.duplicate(true)
	config.paths=["C:/Windows/Fonts/cour.ttf"]
	config.size=20
	config.cell_width=14
	config.cell_height=24
	if not await apply_font(config):return
	var grid: Vector2i=terminal.get_grid_size()
	var bottom:="METRIC_BOTTOM_Ω"
	if not await command("\u001b[2J\u001b[2;1HOVERVIEW_FONT_READY\u001b[%d;1HUPPER\u001b[%d;1H%s\u001b[10;8H" % [grid.y-1,grid.y,bottom],Vector2i(7,9)):return
	var view: Node=host.workspace_view
	var center: Vector2=cell_point(Vector2(5,grid.y-.5))
	var viewport_bottom: float=root.get_visible_rect().end.y
	view.pan_workspace(Vector2(0,center.y-viewport_bottom),Vector2(800,500))
	await hold(.5)
	var edge: Vector2=cell_point(Vector2(5,grid.y-.5))
	check(absf(edge.y-viewport_bottom)<2,"Actual viewport clips half of bottom row")
	await drag(cell_point(Vector2(.1,grid.y-.75)),cell_point(Vector2(bottom.length()-.1,grid.y-.75)),.15)
	terminal.perform_action("copy")
	var copied: String=DisplayServer.clipboard_get()
	check(copied==bottom,"Half-visible bottom row copies exact text: "+copied)
	snap("font-custom-bottom-selected")
	FileAccess.open(directory.path_join("partial-row.json"),FileAccess.WRITE).store_string(JSON.stringify({"copied":copied,"grid":grid,"center":edge,"visible_rect":root.get_visible_rect(),"shell_pid":pid},"  "))
	view.show_main()
	await menu("View::Overview")
	await camera_at_rest()
	await hold(1)
	picture(host,"workspace-overview-settled")
	host.sessions[host.active_session_id].vp.get_texture().get_image().save_png(directory.path_join("overview-terminal.png"))
	FileAccess.open(directory.path_join("overview-state.json"),FileAccess.WRITE).store_string(JSON.stringify({"text":terminal.get_text(false),"size":terminal.size,"grid":terminal.get_grid_size(),"raster_region":view.raster_region,"viewport_size":host.sessions[host.active_session_id].vp.size},"  "))
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text.is_empty(),"Clipped-row selection sends no shell input")
	check(terminal.get_shell_pid()==pid,"Original shell survives clipped-row selection")
	stop_effects.call()
