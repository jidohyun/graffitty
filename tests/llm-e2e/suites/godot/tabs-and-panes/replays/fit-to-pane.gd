extends "main-area-tiling.gd"

func terminal(key: String) -> Control:
	return host.sessions[int(key.substr(1))].term

func frame() -> Dictionary:
	var view: Control = host.workspace_view
	if not view.uses_navigation_camera():
		return {"center": view.canvas_point_at(view.size * 0.5), "zoom": host.world.fx_cam_zoom * host.world.gesture_zoom}
	return {"center": view.navigation_center, "zoom": view.navigation_zoom}

func same_frame(a: Dictionary, b: Dictionary) -> bool:
	return a.center.distance_to(b.center) < 1.0 and absf(a.zoom - b.zoom) < 0.001

func press_fit() -> void:
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.meta_pressed = OS.get_name() == "macOS"
	key.ctrl_pressed = OS.get_name() != "macOS"
	key.shift_pressed = OS.get_name() != "macOS"
	key.pressed = true
	root.push_input(key, true)
	key = key.duplicate()
	key.pressed = false
	root.push_input(key, true)

func double_title(key: String) -> void:
	var view: Control = host.workspace_view
	var point: Vector2 = on(view.pane_titles[key])
	await point_at(point)
	await press()
	await release()
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.pressed = true
	event.double_click = true
	event.position = point
	event.global_position = point
	var before := frame()
	root.push_input(event, true)
	check(same_frame(frame(), before), "Title toggle starts without snapping")
	# Sample the animation from its input edge, without recording-only pacing.
	await release(MOUSE_BUTTON_LEFT, 0.0)

func animated_press(label: String, title_key := "") -> void:
	var before := frame()
	if title_key.is_empty(): press_fit()
	else: await double_title(title_key)
	if title_key.is_empty(): check(same_frame(frame(), before), label + " starts without snapping")
	await hold(0.12)
	var middle := frame()
	check(not same_frame(middle, before), label + " advances through an intermediate frame")
	await hold(0.25)
	check(not same_frame(frame(), middle), label + " continues to its destination")

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var alpha: String = host.pane_focus
	await say("First launch: no saved view uses a centered 30% fallback")
	var startup := frame()
	var startup_rectangles: Dictionary = view.pane_rects.duplicate()
	await animated_press("First-launch zoom out")
	var rect: Rect2 = view.pane_rects[alpha]
	var shown: Vector2 = view.view_point(rect.end) - view.view_point(rect.position)
	var fraction: Vector2 = shown / view.viewport_content_rect().size
	check(absf(maxf(fraction.x, fraction.y) - 0.3) < 0.01,
		"No-history fallback fits the pane within 30% of viewport width and height")
	check(view.view_point(rect.get_center()).distance_to(view.viewport_content_rect().get_center()) < 3.0,
		"No-history fallback centers the pane below the toolbar")
	check(view.pane_rects == startup_rectangles, "Fallback changes the camera, not pane geometry")
	await animated_press("Title double-click restores the startup view", alpha)
	check(same_frame(frame(), startup), "Keyboard and title share one return view")
	await say("A single pane fits and restores the previous overview")
	await pinch_overview()
	await pan_pixels(Vector2(80, -45))
	var initial := frame()
	await animated_press("Single-pane fit")
	check(not view.overview, "Full-span pane fits Main View")
	await animated_press("Single-pane restore")
	check(same_frame(frame(), initial), "Single pane returns to the exact previous framing")
	view.show_main()
	await hold(0.3)
	var beta := await add_window(alpha, "h")
	if beta.is_empty(): return
	var gamma := await add_window(beta, "v")
	if gamma.is_empty(): return
	await camera_at_rest()
	host.focus_pane(beta)
	var pid: int = terminal(beta).get_shell_pid()
	if OS.get_name() == "Windows":
		await type("Write-Output ('FIT_' + 'READY'){enter}")
		var deadline := Time.get_ticks_msec() + 15000
		while not "FIT_READY" in str(terminal(beta).get_text(false)) and Time.get_ticks_msec() < deadline:
			await process_frame
		check("FIT_READY" in str(terminal(beta).get_text(false)), "PowerShell finishes startup before the no-input baseline")
		await camera_at_rest()
	var original_text: String = terminal(beta).get_text(false).get("text", "")
	var rectangles: Dictionary = view.pane_rects.duplicate()
	await say("Fit BETA, then animate back to its previous pan and zoom")
	await pinch_overview()
	await pan_pixels(Vector2(95, -50))
	initial = frame()
	await animated_press("Fit BETA")
	var fitted := frame()
	check(view.view_point(view.pane_rects[beta].get_center()).distance_to(view.viewport_content_rect().get_center()) < 3.0,
		"The focused smaller pane is centered in the usable window")
	await point_at(content(Vector2(0.6, 0.6)))
	await animated_press("Restore BETA")
	check(same_frame(frame(), initial), "Pointer motion preserves the saved return view")
	await animated_press("Title fits BETA", beta)
	check(same_frame(frame(), fitted), "Title and keyboard use identical fit framing")
	await animated_press("Keyboard restores title's saved view")
	check(same_frame(frame(), initial), "Keyboard restores the view saved by a title double-click")
	await animated_press("Title fits BETA again", beta)
	await animated_press("Title restores BETA", beta)
	check(same_frame(frame(), initial), "Repeated title double-click restores exact pan and zoom")
	for navigation in ["pan", "zoom"]:
		await say("Manual " + navigation + " starts a fresh fit/restore pair")
		press_fit()
		await hold(0.4)
		if navigation == "pan":
			await pan_pixels(Vector2(100, 55))
		else:
			await point_at(content())
			await pinch(0.7)
		var manual := frame()
		await animated_press("Refit after " + navigation)
		check(same_frame(frame(), fitted), "Manual " + navigation + " invalidates the old return destination")
		await animated_press("Restore after " + navigation)
		check(same_frame(frame(), manual), "Restore returns to the new " + navigation + " framing")
	await say("A second press reverses an in-progress fit")
	initial = frame()
	press_fit()
	await hold(0.1)
	var intermediate := frame()
	press_fit()
	check(same_frame(frame(), intermediate), "Interrupted fit reverses without a snap")
	await hold(0.12)
	check(not same_frame(frame(), intermediate), "Restore animates from the interrupted frame")
	await hold(0.5)
	check(same_frame(frame(), initial), "Interrupted fit returns without a late jump")
	check(host.pane_focus == beta, "Shortcut preserves the focused terminal")
	check(view.pane_rects == rectangles and view.panes.has(gamma), "Fit and restore preserve the layout")
	check(terminal(beta).get_shell_pid() == pid, "Fit and restore preserve the shell PID")
	var final_text: String = terminal(beta).get_text(false).get("text", "")
	if not check(final_text == original_text, "Fit shortcut never inserts a newline into the terminal"):
		print("FIT_TEXT_BEFORE ", JSON.stringify(original_text))
		print("FIT_TEXT_AFTER ", JSON.stringify(final_text))
