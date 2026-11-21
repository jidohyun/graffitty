extends "stash-outside-main-area.gd"


func center_stash(key: String) -> void:
	var view: Control = host.workspace_view
	var midpoint: Vector2 = view.get_global_transform_with_canvas() * (view.size * 0.5)
	var offset: Vector2 = view.window_point(view.pane_rects[key].get_center()) - midpoint
	await point_at(midpoint)
	await pan_pixels(offset)
	check(view.window_point(view.pane_rects[key].get_center()).distance_to(midpoint) < 12, "Right-drag centers the stash")


func check_close_rendered(key: String) -> void:
	var view: Control = host.workspace_view
	var rect: Rect2 = view.pane_rects[key]
	var center: Vector2 = rect.get_center()
	check(
		root.get_visible_rect().has_point(view.window_point(center)),
		"Stash center is visible in the close-up",
	)
	check(
		view.raster_region.has_point(center),
		"Close-up raster includes the visible part of the stash",
	)
	if not recording:
		var probe := ColorRect.new()
		probe.color = Color(1, 0, 0.8)
		probe.size = Vector2(80, 50)
		probe.position = rect.size * 0.5 - probe.size * 0.5
		probe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		view.panes[key].add_child(probe)
		await hold(0.2)
		var frame := await screen_image()
		# The Android pointer stays at viewport center. Sample inside the probe
		# but left of that cursor, so we measure pane pixels rather than its tip.
		var point: Vector2 = view.window_point(center - Vector2(20, 0)) * Vector2(frame.get_size()) / root \
				.get_visible_rect() \
				.size
		var color := frame.get_pixelv(
			Vector2i(point).clamp(Vector2i.ZERO, frame.get_size() - Vector2i.ONE)
		)
		check(
			color.r > 0.5 and color.b > 0.3 and color.g < 0.3,
			"Close-up pixels reach the final world image (%s)" % color,
		)
		probe.queue_free()
		await hold(0.1)


func play() -> void:
	await label_tab(0, "ALPHA")
	await camera_at_rest()
	var view: Control = host.workspace_view
	var alpha: String = host.pane_focus
	var beta := await add_window(alpha, "h")
	if beta.is_empty():
		return
	var id := int(beta.substr(1))
	var pid: int = host.sessions[id].term.get_shell_pid()
	await type("echo NAV_STASH $$ {enter}")
	await camera_at_rest()
	var body_size: Vector2 = view.panes[beta].body.size
	await pinch_overview()
	await hold(0.5)
	var compact: Label = view.pane_titles[beta]
	check(compact.get_viewport() == view.canvas and compact.is_visible_in_tree(), "Overview keeps the readable title on the world sheet")
	check(compact.get_theme_font_size("font_size") == 20, "Overview preserves the title's natural font size")
	var beta_header: Control = await hover_header(beta)
	var beta_actions: Array = ["filetree", "chromium", "split_right", "split_down"].filter(func(part): return beta_header.has_part(part))
	check(beta_header.modulate.a == 1 and view.panes[beta].compact_header and beta_actions.is_empty()
		and not view.panes[beta].secondary_split_at(beta_header.get_global_transform() * (beta_header.size * Vector2(0.6, 0.5))),
		"Only action icons are hidden and cannot be clicked invisibly (%s)" % [beta_actions])
	check(
		view.panes[beta].body.size == body_size,
		"Compact chrome does not resize the terminal grid",
	)
	await say("Readable overview titles remain draggable")
	var grab: Vector2 = view.title_screen_rect(compact).get_center()
	var grab_sheet: Vector2 = view.canvas_point_at(grab)
	var grab_offset: Vector2 = grab_sheet - view.pane_rects[beta].position
	await drag(
		view.get_global_transform_with_canvas() * grab,
		view.window_point(Vector2(view.size.x + 120, 140) + grab_offset),
	)
	await hold(0.4)
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	var stash: Rect2 = view.pane_rects[beta]
	check(Layout.find(tree, beta).get("stashed", false), "BETA is stashed outside the main area")
	var saved: Dictionary = tree.duplicate(true)
	await say("Pinch over the stash to inspect it up close")
	var at: Vector2 = view.window_point(stash.get_center())
	await point_at(at)
	var local: Vector2 = view.get_global_transform_with_canvas().affine_inverse() * at
	var anchor: Vector2 = view.canvas_point_at(local)
	await pinch(4.5)
	await hold(0.3)
	check(
		view.overview and view.navigation_zoom > 1.0,
		"Pinching past the old limit stays at the stash",
	)
	check(
		view.canvas_point_at(local).distance_to(anchor) < 8,
		"Pinch preserves the point under the pointer",
	)
	check(
		not view.panes[beta].compact_header and view.panes[beta].header.modulate.a == 1,
		"Full action icons return when zoomed in",
	)
	await say("Right-button drag centers the stashed terminal")
	await center_stash(beta)
	await check_close_rendered(beta)
	# Keep this explicit read so the runner selects a rendered window for the suite.
	var frame := await screen_image()
	check(frame != null and not frame.is_empty(), "The close-up is rendered")
	var corner: Vector2 = view.window_point(stash.position)
	var other: Vector2 = view.window_point(stash.end)
	check(
		other.distance_to(corner) > stash.size.length() * 0.9,
		"Stashed terminal is rendered at readable scale",
	)
	await click(on(view.panes[beta].texture, Vector2(0.3, 0.2)))
	var center_before: Vector2 = view.navigation_center
	await type("echo NAV_CLOSEUP {enter}")
	await hold(0.3)
	check(terminal_text(id).contains("NAV_CLOSEUP"), "Typing reaches the original stashed shell")
	check(
		view.navigation_center.is_equal_approx(center_before),
		"Typing does not pull the camera back to main",
	)
	var scroll := InputEventPanGesture.new()
	scroll.position = _to_window(overlay.pointer)
	scroll.delta = Vector2(0.6, 0.6)
	Input.parse_input_event(scroll)
	await hold(0.2)
	check(
		view.navigation_center.is_equal_approx(center_before),
		"Unmodified scrolling does not pan the workspace",
	)
	await pinch(0.7)
	await pinch(1.0 / 0.7)
	check(tree == saved, "Pan, zoom, and typing preserve pane geometry and tiling")
	await say("Main area resets the view; Right-drag can return directly")
	await view_menu("Fit to Main Area")
	await camera_at_rest()
	check(
		not view.overview and is_equal_approx(view.navigation_zoom, view.main_frame().zoom)
		and view.navigation_center.distance_to(view.main_frame().center) < 1.0,
		"Main area resets pan and zoom",
	)
	await center_stash(beta)
	check(view.overview, "Right-drag starts navigation directly from Main")
	for path in ["bistro"]:
		await say("Inspect the same stash in " + path.get_file())
		check(host.switch_world(path), "World opens: " + path)
		_stay_awake()
		await wait_landed()
		await hold(0.5)
		await center_stash(beta)
		await check_close_rendered(beta)
		check(
			view.pane_rects[beta].is_equal_approx(stash),
			"World switching preserves stash geometry",
		)
	check(
		host.sessions[id].term.get_shell_pid() == pid and pid > 0,
		"Navigation preserves the shell PID",
	)
	await say("Double-click an overview title to inspect its pane")
	await pinch_overview()
	await hold(0.3)
	var title_point: Vector2 = on(view.pane_titles[beta])
	await click(title_point)
	var double := InputEventMouseButton.new()
	double.device = REPLAY_POINTER_DEVICE
	double.button_index = MOUSE_BUTTON_LEFT
	double.button_mask = MOUSE_BUTTON_MASK_LEFT
	double.pressed = true
	double.double_click = true
	double.position = title_point
	double.global_position = title_point
	root.push_input(double, true)
	await process_frame
	await release()
	await hold(0.3)
	check(
		view.navigation_zoom >= 0.8 and not view.panes[beta].compact_header,
		"Double-click restores a readable pane and its full controls",
	)
	check(
		view.pane_rects[beta].is_equal_approx(stash),
		"Inspecting a compact title never moves or unstashes its pane",
	)
	await view_menu("Fit to Main Area")
	check(
		not view.overview and Layout.find(tree, beta).get("stashed", false),
		"Return home leaves the pane stashed",
	)
