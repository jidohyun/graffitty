extends "remote-window-return.gd"
const FontSettings = preload("res://scenes/TerminalFontSettings.gd")
var connection: Node
var original_config: Dictionary

func dialog_click(button: Control) -> void:
	await click(Vector2(button.get_window().position)+button.get_global_rect().get_center())

func open_fonts() -> Node:
	await menu("View::Fonts…")
	await hold(.1)
	for child in host.get_children():
		if child is FontSettings: return child
	return null

func apply_font(config: Dictionary) -> bool:
	var dialog := await open_fonts()
	if not check(dialog != null,"Fonts opens through actual Edit menu"):return false
	dialog.advanced.button_pressed=true
	dialog.editor.text=JSON.stringify(config,"  ")
	await hold(.1)
	var reference: WeakRef=weakref(dialog)
	await dialog_click(dialog.get_ok_button())
	if not await until(func():
		var current: Node=reference.get_ref()
		return current==null or (not current.busy and not current.status.text.is_empty()),"Font settings reply arrives",15):return false
	if not check(not is_instance_valid(dialog),"Owner accepts font settings"+(": "+dialog.status.text if is_instance_valid(dialog) else "")):return false
	if not await until(func():return connection.fonts_for(host.active_session_id).complete and connection.fonts_for(host.active_session_id).config==config,"Verified owner faces reach renderer",15):
		var fonts: RefCounted=connection.fonts_for(host.active_session_id)
		FileAccess.open(directory.path_join("font-wait-failure.json"),FileAccess.WRITE).store_string(JSON.stringify({"requested":config,"actual":fonts.config,"complete":fonts.complete,"ready":fonts.ready,"error":fonts.error,"loading":fonts.loading,"faces":fonts.faces},"  "))
		return false
	await hold(.2)
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
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	var release: Callable=host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	overlay.hide()
	var config:=original_config.duplicate(true)
	config.family="Courier New"
	config.paths=["C:/Windows/Fonts/cour.ttf","C:/Windows/Fonts/courbd.ttf","C:/Windows/Fonts/couri.ttf","C:/Windows/Fonts/courbi.ttf"]
	config.fallbacks=["Malgun Gothic","Gulim"]
	config.features={"liga":0}
	config.symbol_maps=[{"first":937,"last":937,"family":"Arial"}]
	config.cell_width=14
	config.cell_height=24
	if not await apply_font(config):return
	check(terminal.get_cell_size()==Vector2(14,24),"Owner publishes exact custom 14 by 24 cell metrics")
	var grid: Vector2i=terminal.get_grid_size()
	var dialog:=await open_fonts()
	check(float(dialog.fields.line_height.text)==100 and float(dialog.fields.column_width.text)==100,"Basic font metric controls use percentages")
	var reference: WeakRef=weakref(dialog)
	await dialog_click(dialog.get_ok_button())
	await until(func():return reference.get_ref()==null,"Unchanged basic form applies")
	check(connection.fonts_for(host.active_session_id).config==config,"Basic no-op preserves style paths, fallbacks, features, symbol maps and custom metrics")
	dialog=await open_fonts()
	dialog.advanced.button_pressed=true
	await hold(.1)
	picture(host,"font-advanced-settings")
	dialog.editor.text="{ broken font JSON 한글"
	await dialog_click(dialog.get_ok_button())
	check(dialog.visible and "JSON" in dialog.status.text and terminal.get_grid_size()==grid,"Malformed advanced JSON keeps dialog open and actual grid unchanged")
	picture(host,"font-advanced-invalid-error")
	dialog.canceled.emit()
	await process_frame
	for patch in [{"paths":["D:/missing/글꼴-없는.ttf"]},{"features":{"bad":1}},{"symbol_maps":[{"first":55296,"last":55300,"family":"Arial"}]},{"line_height":4.0},{"variations":{"wght":850}}]:
		var invalid:=config.duplicate(true)
		invalid.merge(patch,true)
		var reply: Dictionary=await connection.request_action("font_config",{"config":invalid})
		check(reply.type=="error" and connection.fonts_for(host.active_session_id).config==config and terminal.get_grid_size()==grid,"Invalid font settings rejected atomically: "+JSON.stringify(patch))
	var invalid:=config.duplicate(true)
	invalid.paths=["D:/missing/글꼴-없는.ttf"]
	var rejected: Dictionary=await connection.request_action("font_config",{"config":invalid})
	diagnostic_guard.allow("Font settings: "+str(rejected.message),"",0)
	dialog=await open_fonts()
	dialog.advanced.button_pressed=true
	dialog.editor.text=JSON.stringify(invalid)
	await hold(.1)
	await dialog_click(dialog.get_ok_button())
	await until(func():return not dialog.busy and "글꼴-없는" in dialog.status.text,"Actual font error retains Unicode path")
	dialog.canceled.emit()
	await process_frame
	var panel: Node=host.diagnostic_panel
	await until(func():return panel.panel.visible and "글꼴-없는" in panel.messages.text,"Rejected Unicode path appears in retained messages")
	panel.messages.select_all()
	panel.copy_messages()
	check(DisplayServer.clipboard_get().replace("\r\n","\n")==panel.messages.get_selected_text(),"Selectable retained messages copy exact Unicode text")
	picture(host,"messages-selectable-error")
	await click(on(panel.log_button))
	await process_frame
	check(panel.log_viewer.visible and "글꼴-없는" in panel.log_viewer.get_child(0).text,"Open log remains in app with actual rejected Unicode path")
	picture(host,"messages-open-log")
	panel.log_viewer.canceled.emit()
	panel.dismissed_revision=preload("res://graffitty/diagnostics.gd").revision
	panel.refresh()
	await process_frame
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text.is_empty(),"Fonts, messages and internal log controls leak no raw terminal input")
	check(terminal.get_shell_pid()==pid,"Original shell survives all font changes and rejections")
	FileAccess.open(directory.path_join("font-config.json"),FileAccess.WRITE).store_string(JSON.stringify(config,"  "))
	release.call()
