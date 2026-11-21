extends "main-area-tiling.gd"


func drag_to_layout(key: String, position: Vector2) -> void:
	var view: Control = host.workspace_view
	var handle: Control = view.panes[key].handle
	var offset: Vector2 = handle.get_global_transform() * (handle.size * 0.5) - view \
			.pane_rects[key] \
			.position
	await drag(on(handle), view.window_point(position + offset), 1.3)
	await hold(0.4)


func check_rendered(key: String) -> void:
	var view: Control = host.workspace_view
	var rect: Rect2 = view.pane_rects[key]
	var point: Vector2 = view.window_point(rect.position + Vector2(rect.size.x * 0.5, 17))
	check(root.get_visible_rect().has_point(point), "Stash projects inside the Overview viewport")
	check(view.raster_region.encloses(rect), "The canvas raster includes the entire stash")
	# Also read the real frame; the recording is the visual evidence for the
	# off-wall sheet, while transform assertions catch invisible clipping.
	var frame := await screen_image()
	check(frame != null and not frame.is_empty(), "A rendered frame is available for visual review")
	frame.save_png(evidence_path("stash-overview-%d.png" % host.world.get_instance_id()))
	if not recording:
		# An unmistakable patch must reach the final 3D frame, not just the
		# offscreen canvas. This catches mesh, shader and raster clipping.
		var probe := ColorRect.new()
		probe.color = Color(1.0, 0.0, 0.8)
		probe.position = Vector2(10, 120)
		probe.size = Vector2(100, 60)
		probe.mouse_filter = Control.MOUSE_FILTER_IGNORE
		view.panes[key].add_child(probe)
		await hold(0.2)
		var marked := await screen_image()
		var at: Vector2 = view.window_point(rect.position + probe.position + probe.size * 0.5)
		at *= Vector2(marked.get_size()) / root.get_visible_rect().size
		var color := marked.get_pixelv(
			Vector2i(at).clamp(Vector2i.ZERO, marked.get_size() - Vector2i.ONE)
		)
		check(
			color.r > 0.5 and color.b > 0.3 and color.g < 0.3,
			"Off-main pane pixels reach the final world image (%s)" % color,
		)
		probe.queue_free()
		await hold(0.1)


func play() -> void:
	if not await open_bistro():
		return
	await label_tab(0, "ALPHA")
	await camera_at_rest()
	var view: Control = host.workspace_view
	var alpha: String = host.pane_focus
	await toggle_tiling()
	var beta := await add_window(alpha)
	if beta.is_empty():
		return
	await type("echo STASH_ALIVE $$ {enter}")
	await camera_at_rest()
	var id := int(beta.substr(1))
	var pid: int = host.sessions[id].term.get_shell_pid()
	await say("Overview: the border is the main area, not the world wall")
	await pinch_overview()
	await hold(0.7)
	check(view.boundary.visible, "Main-area border is visible")
	await say("Drag BETA beyond the right edge; ALPHA fills the main area")
	await drag_to_layout(beta, Vector2(view.size.x + 90, 120))
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(Layout.find(tree, beta).get("stashed", false), "Dragging outside stashes BETA")
	check(Layout.tile_keys(tree.tiles) == [alpha], "Only ALPHA remains tiled")
	check(view.pane_rects[alpha].is_equal_approx(view.content_rect().grow(-host.tiling_config.gap)), "ALPHA fills the main area")
	await check_rendered(beta)
	var stash: Rect2 = view.pane_rects[beta]
	await wait(1.2)
	await say("Return to Main; toggling tiling leaves the stash in place")
	await view_menu("Fit to Main Area")
	await toggle_tiling()
	await toggle_tiling()
	check(view.pane_rects[beta].is_equal_approx(stash), "The stash never snaps into the main area")
	var original_size: Vector2i = root.size
	if not recording:
		root.size = Vector2i(1100, 900)
		await hold(0.5)
		check(
			view.pane_rects[beta].is_equal_approx(stash),
			"Resizing leaves stash position and size untouched",
		)
		root.size = original_size
		await hold(0.5)
	await pinch_overview()
	await hold(0.5)
	await say("Retrieve BETA by dragging it back into the border")
	await drag_to_layout(beta, Vector2(view.size.x * 0.48, 130))
	tree = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(not Layout.find(tree, beta).get("stashed", true), "BETA rejoins the main area")
	check_tiles()
	await say("Stash to the left, at negative sheet coordinates")
	await drag_to_layout(beta, Vector2(-view.pane_rects[beta].size.x - 100, 100))
	tree = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(Layout.find(tree, beta).get("stashed", false), "Negative coordinates are a valid stash")
	await check_rendered(beta)
	stash = view.pane_rects[beta]
	await say("Escape cancels a drag without changing stash membership")
	await point_at(on(view.panes[beta].handle))
	await press()
	await point_at(view.window_point(view.content_rect().get_center()), 0.8)
	await keys("Escape")
	await release()
	await hold(0.3)
	tree = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(
		view.pane_rects[beta].is_equal_approx(stash) and Layout.find(tree, beta).stashed,
		"Escape restores the stash rectangle and membership",
	)
	await say("Type in the stash, then move it above the main area")
	await click(on(view.panes[beta].texture, Vector2(0.4, 0.2)))
	await type("echo STILL_STASHED {enter}")
	await hold(0.3)
	check(
		terminal_text(id).contains("STILL_STASHED"),
		"The stashed pane still accepts terminal input",
	)
	# Typing now follows the cursor even in overview. Restore the overview
	# before dragging above the sheet, so the target stays inside the window.
	await camera_at_rest()
	await pinch_overview()
	await drag_to_layout(beta, Vector2(view.size.x * 0.25, -view.pane_rects[beta].size.y - 90))
	tree = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(
		Layout.find(tree, beta).get("stashed", false) and view.pane_rects[beta].end.y < 0,
		"Stashes can sit entirely above the main area",
	)
	await check_rendered(beta)
	stash = view.pane_rects[beta]
	await say("Switch to Flat; the same stash and shell survive")
	host.switch_world("")
	_stay_awake()
	await wait_landed()
	await hold(1.0)
	check(view.pane_rects[beta].is_equal_approx(stash), "World switching preserves stash placement")
	await check_rendered(beta)
	await say("Back in Bistro (night), the same off-main windows remain")
	check(host.switch_world("bistro"), "Bistro (night) opens again")
	_stay_awake()
	await wait_landed()
	await hold(1.0)
	await check_rendered(beta)
	check(view.pane_rects[beta].is_equal_approx(stash), "Bistro (night) preserves the stash")
	check(host.sessions[id].term.get_shell_pid() == pid and pid > 0, "Stashed shell PID survives")
	check(terminal_text(id).contains("STASH_ALIVE"), "Stashed shell output survives")
	check(host.workspace_layout.tabs.size() == 1, "Stashing creates no tabs or desktop windows")
	await wait(1.0)
