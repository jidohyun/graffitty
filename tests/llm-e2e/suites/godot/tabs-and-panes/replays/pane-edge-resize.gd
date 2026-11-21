extends "main-area-tiling.gd"


# Owner tile weights are f32; Godot gesture math uses f64. Compare exact tree
# structure and weights at their wire precision, including after an ACK.
func wire_tiles(tiles: Dictionary) -> Dictionary:
	var result := tiles.duplicate(true)
	if result.has("weight"):
		result.weight = PackedFloat32Array([float(result.weight)])[0]
	if result.has("children"):
		result.children = result.children.map(wire_tiles)
	return result


func play() -> void:
	await label_tab(0, "ALPHA")
	await camera_at_rest()
	# Exact placement is tested with collision responses explicitly disabled.
	if host.workspace_view.physics_enabled():
		await view_menu("Floating Pane Physics")
	var view: Control = host.workspace_view
	var alpha: String = host.pane_focus
	await say("One tiled pane fills the usable main area")
	await toggle_tiling()
	var area: Rect2 = view.content_rect()
	check(view.pane_rects[alpha].is_equal_approx(area.grow(-host.tiling_config.gap)),
		"The first tiled pane fills the main area with the configured edge gap")
	var header: Control = await hover_header(alpha)
	check(
		header.has_part("chromium") and header.action_at(header.get_global_transform() * header.part_rect("chromium").get_center()) == "chromium",
		"Chromium is an icon action in the hovered header",
	)
	var beta := await add_window(alpha, "h")
	var gamma := await add_window(alpha, "v")
	if beta.is_empty() or gamma.is_empty():
		return
	await camera_at_rest()
	var pids := { }
	for key in [alpha, beta, gamma]:
		pids[key] = host.sessions[int(key.substr(1))].term.get_shell_pid()
	await say("Grab the right pane's LEFT EDGE, not the gap")
	var before: Dictionary = view.pane_rects.duplicate()
	var edge: Vector2 = before[beta].position + Vector2(2, before[beta].size.y * 0.25)
	await point_at(view.window_point(edge))
	check(
		view.pointer.mouse_default_cursor_shape == Control.CURSOR_HSIZE,
		"Left pane border shows a horizontal resize cursor",
	)
	await drag(view.window_point(edge), view.window_point(edge + Vector2(-100, 0)))
	check(
		view.pane_rects[beta].size.x > before[beta].size.x + 60,
		"Dragging BETA's left edge grows BETA",
	)
	check(
		view.pane_rects[alpha].size.x < before[alpha].size.x - 60,
		"Both left tiles shrink to make room",
	)
	check(
		is_equal_approx(view.pane_rects[alpha].size.x, view.pane_rects[gamma].size.x),
		"Left branch stays aligned",
	)
	check_tiles()
	await camera_at_rest()
	await say("Drag ALPHA's bottom-right corner diagonally")
	before = view.pane_rects.duplicate()
	var corner: Vector2 = before[alpha].end - Vector2(10, 10)
	await point_at(view.window_point(corner))
	check(
		view.pointer.mouse_default_cursor_shape == Control.CURSOR_FDIAGSIZE,
		"Shared bottom-right corner shows a diagonal cursor",
	)
	await drag(view.window_point(corner), view.window_point(corner + Vector2(90, 60)))
	check(
		view.pane_rects[alpha].size.x > before[alpha].size.x + 50
		and view.pane_rects[alpha].size.y > before[alpha].size.y + 30,
		"Diagonal tiled drag grows both dimensions",
	)
	check(
		view.pane_rects[beta].size.x < before[beta].size.x - 50
		and view.pane_rects[gamma].size.y < before[gamma].size.y - 30,
		"Both neighboring branches shrink",
	)
	check_tiles()
	await camera_at_rest()
	await owner_at_rest()
	var saved: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree.tiles.duplicate(true)
	corner = view.pane_rects[alpha].end - Vector2(10, 10)
	await point_at(view.window_point(corner))
	await press()
	await point_at(view.window_point(corner - Vector2(70, 50)), 0.5)
	await keys("escape")
	await release()
	await owner_at_rest()
	# ACKs replace the mirrored tree; inspect the live model after the gesture.
	check(wire_tiles(host.workspace_layout.tab(host.workspace_layout.active).tree.tiles) == wire_tiles(saved), "Escape restores both divider weights")
	await say("Floating bottom-right grip resizes width AND height")
	await toggle_tiling()
	await camera_at_rest()
	before = view.pane_rects.duplicate()
	corner = before[alpha].end - Vector2(10, 10)
	await point_at(view.window_point(corner))
	check(
		view.pointer.mouse_default_cursor_shape == Control.CURSOR_FDIAGSIZE,
		"Full floating corner grip has a diagonal cursor",
	)
	await drag(view.window_point(corner), view.window_point(corner + Vector2(70, 50)))
	check(
		view.pane_rects[alpha].size.x > before[alpha].size.x + 40
		and view.pane_rects[alpha].size.y > before[alpha].size.y + 25,
		"Floating corner grows width and height",
	)
	check(
		view.pane_rects[beta].is_equal_approx(before[beta])
		and view.pane_rects[gamma].is_equal_approx(before[gamma]),
		"Floating resize leaves neighbors unchanged",
	)
	await toggle_tiling()
	await owner_at_rest()
	check(wire_tiles(host.workspace_layout.tab(host.workspace_layout.active).tree.tiles) == wire_tiles(saved), "Tiling restores the saved proportions")
	check_tiles()
	for key in pids:
		check(
			host.sessions[int(key.substr(1))].term.get_shell_pid() == pids[key],
			"Resizing preserves %s's shell" % key,
		)
