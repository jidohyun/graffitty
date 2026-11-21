extends "fit-to-pane.gd"
## Replays the Main View regression: split above, close, then type again.


func main_corners() -> PackedVector2Array:
	var view: Control = host.workspace_view
	var rect: Rect2 = view.content_rect()
	return PackedVector2Array([view.view_point(rect.position), view.view_point(rect.end)])


func check_main_frame(before: PackedVector2Array) -> void:
	var view: Control = host.workspace_view
	check(not view.overview, "Closing within Main View keeps Main View selected")
	check(same_frame(frame(), view.main_frame()), "Idle camera retains the fitted Main View")
	var after := main_corners()
	check(after[0].distance_to(before[0]) < 1.0 and after[1].distance_to(before[1]) < 1.0,
		"Rendered Main View returns to its original framing without residual pan or zoom")
	var saved: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).navigation
	check(not saved.overview, "The tab remembers Main View after closing")


func close_pane(key: String) -> void:
	# The actual pane-menu action; native popup interaction is reviewed manually.
	var pane: Control = host.workspace_view.panes[key]
	pane.title_menu.id_pressed.emit(0)
	var deadline := Time.get_ticks_msec() + 10000
	while host.sessions.has(int(key.substr(1))) and not is_instance_valid(host.close_dialog) and Time.get_ticks_msec() < deadline:
		await process_frame
	if is_instance_valid(host.close_dialog):
		host.close_dialog.confirmed.emit()
		host.close_dialog.hide()
	await owner_at_rest()
	check(not host.sessions.has(int(key.substr(1))), "Close removes the requested pane")


func add_above(source: String) -> String:
	var view: Control = host.workspace_view
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	var before := Layout.keys(tree)
	await point_at(await on_header(source, "split_down"))
	await press(MOUSE_BUTTON_RIGHT)
	await release(MOUSE_BUTTON_RIGHT)
	await camera_at_rest()
	for key in Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree):
		if key in before: continue
		check(view.pane_rects[key].end.y < view.pane_rects[source].position.y,
			"Right-click vertical split creates a pane above the original")
		check(not view.overview, "Creating a top pane stays in Main View")
		return key
	check(false, "Vertical split creates a top pane")
	return ""


func type_and_return(before: PackedVector2Array) -> void:
	await say("Type in the surviving terminal, then watch the return to Main View")
	start_watching_camera()
	await type("echo main-view{enter}")
	await hold(.35)
	check(host.world.fx_cam_zoom > 1.3, "Typing after closing still animates the camera zoom")
	check(not host.workspace_view.overview, "Typing zoom keeps Main View as its base")
	await camera_at_rest()
	check_no_jump_cut(stop_watching_camera(), "Typing after closing and returning to Main View")
	check_main_frame(before)


func play() -> void:
	await labelled_tabs(["MAIN VIEW"])
	var source: String = host.pane_focus
	for world_path in ["", "flat-2d"]:
		await say("Run in " + ("Flat" if world_path.is_empty() else "Flat 2D"))
		host.switch_world(world_path)
		_stay_awake()
		use_config(get_script().resource_path.get_base_dir().path_join("../main-view-pane-close.conf"))
		var view: Control = host.workspace_view
		if not host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
			await toggle_tiling()
		view.show_main()
		await camera_at_rest()
		var before := main_corners()
		var source_rect: Rect2 = view.pane_rects[source]
		var pid: int = terminal(source).get_shell_pid()
		for cycle in 2:
			await say("Create a pane above Main View, then close it (cycle %d)" % (cycle + 1))
			var top := await add_above(source)
			if top.is_empty(): return
			var typed: float = host.world.fx_last_key
			await close_pane(top)
			check(host.pane_focus == source, "The original terminal receives focus")
			check(host.world.fx_last_key == typed, "Closing does not count as typing")
			check(not view.overview, "Close never enters free navigation inside Main View")
			await camera_at_rest()
			check_main_frame(before)
			check(view.pane_rects[source].is_equal_approx(source_rect), "Original pane fills the main area again")
			await type_and_return(before)
			check(terminal(source).get_shell_pid() == pid, "Original shell PID survives split and close")

		await say("Close a zoomed top pane while two other panes remain in Main View")
		var right := await add_window(source, "h")
		if right.is_empty(): return
		var right_pid: int = terminal(right).get_shell_pid()
		var rectangles: Dictionary = view.pane_rects.duplicate()
		var top := await add_above(source)
		if top.is_empty(): return
		await type("echo closing-zoom{enter}")
		await hold(.35)
		check(host.world.fx_cam_zoom > 1.3, "The top pane is closed during typing zoom")
		var typed: float = host.world.fx_last_key
		start_watching_camera()
		await hold(.12)
		await close_pane(top)
		check(host.pane_focus == source, "Nearest surviving pane receives focus")
		check(host.world.fx_last_key == typed, "Closing during zoom does not restart the typing timer (before=%s after=%s)" % [typed, host.world.fx_last_key])
		check(host.world.fx_cam_zoom > 1.3, "Closing during zoom does not snap the typing camera to idle")
		check(not view.overview, "Multiple surviving panes still use Main View")
		await camera_at_rest()
		check_no_jump_cut(stop_watching_camera(), "Close during typing zoom")
		check_main_frame(before)
		check(view.pane_rects == rectangles, "Closing restores the surviving tiles")
		await type_and_return(before)
		check(terminal(source).get_shell_pid() == pid and terminal(right).get_shell_pid() == right_pid,
			"Both surviving terminals keep their shell PIDs")
		host.focus_pane(right)
		await close_pane(right)
		await camera_at_rest()
