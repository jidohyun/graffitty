extends "mouse-selection.gd"

func magnify(at: Vector2,factor: float) -> void:
	var view: Control = host.workspace_view
	var event := InputEventMagnifyGesture.new()
	event.position = view.pointer.get_transform().affine_inverse()*at
	event.factor = factor
	# Duplicate delivery in one frame must apply magnification only once.
	view._forward_pointer(event,true)
	view._forward_pointer(event,true)
	await process_frame

func play() -> void:
	directory = OS.get_environment("GRAFFITTY_INPUT_EVIDENCE")
	if not await open_bistro():return
	terminal = host.active_terminal()
	var pid: int = terminal.get_shell_pid()
	var python := OS.get_environment("GRAFFITTY_INPUT_PYTHON")
	var probe := ProjectSettings.globalize_path("res://../../../tests/fixtures/windows_input_receipt.py")
	FileAccess.open(directory.path_join("quiet-phases"),FileAccess.WRITE).store_string("")
	await type("& '%s' -u '%s' '%s'{enter}" % [python.replace("'","''"),probe.replace("'","''"),directory.replace("'","''")])
	if not await wait_file(directory.path_join("ready")):return
	var release: Callable = host.effect_control.hold(preload("res://graffitty/effects.gd").NAMES)
	await hold(2.8)
	var history := ""
	for i in 80:history+="gesture history %d\r\n" % i
	if not await command(history+"\u001b[10;20H",Vector2i(19,9)):return
	var view: Control = host.workspace_view
	var anchor: Vector2 = view.size*Vector2(.37,.43)
	var canvas_anchor: Vector2 = view.canvas_point_at(anchor)
	var initial: float = view.navigation_zoom
	await magnify(anchor,1.2)
	await magnify(anchor+Vector2(120,60),1.1)
	check(absf(view.navigation_zoom/initial-1.32)<.001,"Magnification is applied exactly once: 1.2 × 1.1")
	var first_error: float = view.view_point(canvas_anchor).distance_to(anchor)
	check(first_error<2,"Zoom-only retains initial off-center anchor despite moving event cursor: %.3f px" % first_error)
	overlay.hide()
	RenderingServer.force_draw(false)
	var zoom_image := root.get_texture().get_image()
	var pan := InputEventPanGesture.new()
	pan.position = view.pointer.get_transform().affine_inverse()*(anchor+Vector2(180,90))
	pan.delta = Vector2(12,-5)
	view._forward_pointer(pan,true)
	await process_frame
	await magnify(anchor+Vector2(-100,50),1.1)
	var target := anchor+Vector2(36,-15)
	var second_error: float = view.view_point(canvas_anchor).distance_to(target)
	check(second_error<2,"Three-times pan moves remembered zoom anchor by (36,-15): %.3f px" % second_error)
	zoom_image.save_png(directory.path_join("native-zoom-only.png"))
	capture("native-zoom-and-pan")
	await hold(.45)
	var zoom: float = view.navigation_zoom
	var offset: int = terminal.get_ui_state().scroll_offset
	await click_cell(Vector2(50.5,15.5),0,MOUSE_BUTTON_WHEEL_UP)
	await process_frame
	check(is_equal_approx(view.navigation_zoom,zoom) and int(terminal.get_ui_state().scroll_offset)<offset,"After pinch inactivity normal wheel returns to terminal history")
	FileAccess.open(directory.path_join("gesture-trace.json"),FileAccess.WRITE).store_string(JSON.stringify({"zoom_only_error":first_error,"zoom_pan_error":second_error,"pan_delta":[36,-15],"pan_speed":view.pinch_pan_speed,"generic_phase_policy":"Godot phase-less gesture ends after 350ms inactivity or ordinary mouse button input"},"  "))
	FileAccess.open(directory.path_join("finish"),FileAccess.WRITE).store_string("")
	if await wait_file(directory.path_join("receipt.json")):
		var receipt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("receipt.json")))
		check(receipt.text=="","Camera gestures and history wheel leak no PTY bytes")
	check(terminal.get_shell_pid()==pid,"Gesture navigation preserves shell")
	release.call()
