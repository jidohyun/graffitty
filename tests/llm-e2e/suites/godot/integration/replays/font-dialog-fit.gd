extends "font-controls.gd"

func play() -> void:
	directory=OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	terminal=host.active_terminal()
	connection=host.session_backend.connection
	original_config=connection.fonts_for(host.active_session_id).config.duplicate(true)
	var pid: int=terminal.get_shell_pid()
	var ids: Array=host.sessions.keys()
	var python:=OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe:=ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"),FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	var stop_effects: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	await menu("View::Overview")
	await camera_at_rest()
	var view: Node=host.workspace_view
	var saved_center: Vector2=view.navigation_center
	var saved_zoom: float=view.navigation_zoom
	check(view.overview,"Actual View menu enters Overview")
	picture(host,"workspace-overview")
	await menu("View::Fit to Main Area")
	await camera_at_rest()
	check(view.navigation_zoom!=saved_zoom,"Actual Fit control changes projection")
	picture(host,"workspace-fit")
	await menu("View::Fit to Main Area")
	await camera_at_rest()
	check(view.navigation_center.distance_to(saved_center)<.001 and absf(view.navigation_zoom-saved_zoom)<.00001,"Repeated Fit restores exact saved Overview")
	check(host.sessions.keys()==ids and terminal.get_shell_pid()==pid,"Overview and Fit preserve original pane and shell")
	view.show_main()
	var dialog:=await open_fonts()
	dialog.advanced.button_pressed=true
	await hold(.15)
	check(dialog.editor.size.y>=350,"Complete JSON editor has a usable multiline area")
	picture(host,"font-advanced-settings")
	dialog.editor.text="{ bad JSON 한글"
	await dialog_click(dialog.get_ok_button())
	picture(host,"font-advanced-invalid-error")
	dialog.canceled.emit()
	await process_frame
	var invalid:=original_config.duplicate(true)
	invalid.paths=["D:/missing/글꼴-없는.ttf"]
	var rejected: Dictionary=await connection.request_action("font_config",{"config":invalid})
	diagnostic_guard.allow("Font settings: "+str(rejected.message),"",0)
	dialog=await open_fonts()
	dialog.advanced.button_pressed=true
	dialog.editor.text=JSON.stringify(invalid)
	await hold(.1)
	await dialog_click(dialog.get_ok_button())
	await until(func():return not dialog.busy and "글꼴-없는" in dialog.status.text,"Rejected font path remains readable")
	dialog.canceled.emit()
	await process_frame
	var panel: Node=host.diagnostic_panel
	await until(func():return panel.panel.visible,"Messages displays rejected font")
	panel.messages.grab_focus()
	panel.messages.select_all()
	await hold(.15)
	picture(host,"messages-selectable-error")
	await click(on(panel.log_button))
	await hold(.15)
	var text: TextEdit=panel.log_viewer.get_child(0)
	check(text.get_caret_line()==text.get_line_count()-1,"Internal log opens at most recent message")
	picture(host,"messages-open-log")
	panel.log_viewer.canceled.emit()
	await process_frame
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text.is_empty(),"Fit and diagnostic controls send no terminal input")
	stop_effects.call()
