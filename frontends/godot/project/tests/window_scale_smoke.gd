extends "../../../../tests/llm-e2e/replay/replay.gd"
## Native window width changes layout space, never font or pointer-target scale.
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")


func play() -> void:
	# The replay base fixes logical coordinates for movies; this test must
	# exercise the production desktop DPI policy instead.
	root.mode = Window.MODE_WINDOWED
	root.content_scale_size = Vector2i.ZERO
	app.configure_window_scale(root)
	await hold(.3)
	await camera_at_rest()
	var view: Control = host.workspace_view
	var pane: Control = view.panes[host.pane_focus]
	# Supply an independent expectation on a configured X11/Wayland test display.
	var display_scale := root.content_scale_factor
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--expect-ui-scale="): display_scale = float(arg.get_slice("=", 1))
	var baseline := Vector2.ZERO
	for width in [1600, 533, 800]:
		root.size = Vector2i(Vector2(width, 900) * display_scale)
		await hold(0.3)
		check(absf(root.get_visible_rect().size.x - width) <= 1.0, "Window reached %d logical pixels" % width)
		var scale := root.get_final_transform().get_scale()
		check(scale.is_equal_approx(Vector2.ONE * display_scale), "Display scale stays constant at width %d" % width)
		var tab_height: float = ScreenSpace.shown(view.tab_bar).size.y / display_scale
		var header_height: float = pane.header.size.y * scale.y / display_scale
		if baseline == Vector2.ZERO:
			baseline = Vector2(tab_height, header_height)
		check(Vector2(tab_height, header_height).is_equal_approx(baseline), "Tabs and drag headers retain their size at width %d" % width)
		check(header_height >= 30.0 and tab_height >= 30.0, "Readable controls at width %d" % width)
		check(view.size.x <= float(root.size.x) / display_scale + 1.0, "Workspace reflows to native width %d" % width)
		var backing_size := Vector2i((host.layout_root.size * scale).round())
		check(host.world_viewport.size == backing_size, "World compositor renders full backing resolution at width %d" % width)
		check(host.world_container.get_global_rect().size.is_equal_approx(host.layout_root.size), "Full-resolution world still fits logical layout at width %d" % width)
		var point := Vector2(80, 20)
		check(ScreenSpace.into(view, ScreenSpace.of(view, point)).is_equal_approx(point), "Drag coordinate conversion survives width %d" % width)
	root.size = Vector2i(Vector2(533, 900) * display_scale)
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if group.tree.get("tiling", false):
		view.toggle_tiling()
		await hold(.3)
	if view.physics_enabled(): view.toggle_physics()
	view.set_window_rect(host.pane_focus, Rect2(40, 150, 350, 280), true)
	host.session_backend.commit_workspace(host)
	view.refresh()
	await hold(0.3)
	var before: Rect2 = view.pane_rects[host.pane_focus]
	var start := on(pane.handle)
	await drag(start, start + Vector2(50, 70))
	await hold(0.2)
	var after: Rect2 = view.pane_rects[host.pane_focus]
	check(after.position.distance_to(before.position) > 30.0, "Header drag moves a pane in a narrow window")
	var secondary := Window.new()
	secondary.hide()
	secondary.force_native = true
	secondary.current_screen = root.current_screen
	root.add_child(secondary)
	secondary.show()
	app.configure_window_scale(secondary)
	check(secondary.content_scale_mode == Window.CONTENT_SCALE_MODE_DISABLED, "Detached windows use display scaling")
	await hold(0.2)
	check(is_equal_approx(secondary.content_scale_factor, display_scale), "Detached window on the same display uses the same scale")
	secondary.queue_free()
