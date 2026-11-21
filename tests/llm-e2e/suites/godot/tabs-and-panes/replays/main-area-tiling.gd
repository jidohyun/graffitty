extends "../../../../replay/replay.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")


func view_menu(item: String) -> void:
	await say("View → " + item)
	for entry in host.menu_entries:
		if entry.label == "View::" + item:
			check(entry.enabled.call(host), "View menu action is enabled")
			host._run_menu_action(entry)
			await hold(0.3)
			return
	check(false, "View menu action exists: " + item)


# Internal coverage for floating layouts; tiling has no user-facing menu toggle.
func toggle_tiling() -> void:
	host.workspace_view.toggle_tiling()
	await hold(0.3)


func pinch_overview() -> void:
	var view: Control = host.workspace_view
	await point_at(view.get_global_transform_with_canvas() * (view.size * 0.5))
	var zoom: float = view.navigation_zoom if view.overview else host.world.fx_cam_zoom * host.world.gesture_zoom
	await pinch((1.0 / 3.5) / zoom)
	await hold(0.3)


func add_window(key: String, direction := "") -> String:
	var view: Control = host.workspace_view
	if not host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		await toggle_tiling()
	var before := Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree)
	await click(await on_header(key, "split_down" if direction == "v" else "split_right"))
	await camera_at_rest()
	var after := Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree)
	for added in after:
		if added not in before:
			return added
	check(false, "The pane split button creates a window")
	return ""


func check_tiles() -> void:
	var view: Control = host.workspace_view
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	var tiled := Layout.tile_keys(tree.get("tiles", { }))
	for key in tiled:
		check(
			view.content_rect().grow(0.1).encloses(view.pane_rects[key]),
			"%s fits the window-sized main area" % key,
		)
		check(
			view.panes[key].size.is_equal_approx(view.pane_rects[key].size),
			"%s's actual control fits its tile" % key,
		)
	for i in tiled.size():
		for j in range(i + 1, tiled.size()):
			check(
				not view.pane_rects[tiled[i]].intersects(view.pane_rects[tiled[j]]),
				"Tiles do not overlap",
			)


func play() -> void:
	await label_tab(0, "ALPHA")
	await camera_at_rest()
	# Exact placement is tested with collision responses explicitly disabled.
	if host.workspace_view.physics_enabled():
		await view_menu("Floating Pane Physics")
	var view: Control = host.workspace_view
	var alpha: String = host.pane_focus
	var pid: int = host.sessions[int(alpha.substr(1))].term.get_shell_pid()
	await say("Tile the main area; open a window beside ALPHA")
	var beta := await add_window(alpha, "h")
	if beta.is_empty():
		return
	await camera_at_rest()
	await say("Split the right-hand window vertically, like i3")
	var gamma := await add_window(beta, "v")
	if gamma.is_empty():
		return
	await camera_at_rest()
	check_tiles()
	check(
		view.pane_rects[alpha].size.y > view.pane_rects[beta].size.y * 1.9,
		"Nested split leaves ALPHA full-height",
	)
	check(
		view.pane_rects[beta].end.y < view.pane_rects[gamma].position.y,
		"BETA and GAMMA stack on the right",
	)
	var pids := { }
	for key in [alpha, beta, gamma]:
		pids[key] = host.sessions[int(key.substr(1))].term.get_shell_pid()
	await say("Drag the divider to give ALPHA more width")
	var dividers := Layout.tile_dividers(
		host.workspace_layout.tab(host.workspace_layout.active).tree.tiles,
		view.content_rect(),
	)
	var divider: Vector2 = dividers[0].rect.position + dividers[0].rect.size * Vector2(0.5, 0.25)
	var old_width: float = view.pane_rects[alpha].size.x
	await point_at(view.window_point(divider))
	check(
		view.pointer.mouse_default_cursor_shape == Control.CURSOR_HSIZE,
		"Column divider shows the horizontal resize cursor",
	)
	await drag(view.window_point(divider), view.window_point(divider + Vector2(130, 0)))
	check(view.pane_rects[alpha].size.x > old_width + 80, "Dragging the outer divider widens ALPHA")
	check_tiles()
	await camera_at_rest()
	await say("Resize the nested row without changing ALPHA")
	dividers = Layout.tile_dividers(host.workspace_layout.tab(host.workspace_layout.active).tree.tiles, view.content_rect())
	divider = dividers[1].rect.get_center()
	var alpha_rect: Rect2 = view.pane_rects[alpha]
	var old_height: float = view.pane_rects[beta].size.y
	await point_at(view.window_point(divider))
	check(
		view.pointer.mouse_default_cursor_shape == Control.CURSOR_VSIZE,
		"Row divider shows the vertical resize cursor",
	)
	await drag(view.window_point(divider), view.window_point(divider + Vector2(0, 100)))
	check(
		view.pane_rects[beta].size.y > old_height + 60,
		"Dragging the nested divider makes BETA taller",
	)
	check(
		view.pane_rects[alpha].is_equal_approx(alpha_rect),
		"Nested resize leaves ALPHA unchanged",
	)
	check_tiles()
	await camera_at_rest()
	await say("Escape cancels a divider drag")
	var sized_tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree.tiles.duplicate(
		true
	)
	dividers = Layout.tile_dividers(sized_tree, view.content_rect())
	divider = dividers[0].rect.get_center()
	await point_at(view.window_point(divider))
	await press()
	await point_at(view.window_point(divider + Vector2(-3000, 0)), 0.5)
	check(view.pane_rects[alpha].size.x >= 159.9, "Extreme drag clamps the minimum pane width")
	check_tiles()
	await keys("escape")
	await release()
	check(
		host.workspace_layout.tab(host.workspace_layout.active).tree.tiles == sized_tree,
		"Escape restores the exact pre-drag weights",
	)
	var width_ratio: float = view.pane_rects[alpha].size.x / view.pane_rects[beta].size.x
	var height_ratio: float = view.pane_rects[beta].size.y / view.pane_rects[gamma].size.y
	await say("Resize the client area from wide to tall")
	var original: Vector2i = root.size
	if recording:
		# Movie Maker fixes its output size at launch. Resize the actual client
		# controls inside that frame so the recording never crops their edges.
		host.layout_root.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		host.layout_root.position = Vector2(450, 60)
		host.layout_root.size = Vector2(700, 850)
	else:
		root.size = Vector2i(900, 1100)
	await hold(1.0)
	check_tiles()
	check(
		view
		.size
		.is_equal_approx(
			(
				Vector2(700, 850)
				if recording
				else root.get_visible_rect().size - Vector2(0, host.layout_root.offset_top)
			)
		),
		"Main canvas tracks the resized client area after window chrome",
	)
	check(
		is_equal_approx(view.pane_rects[alpha].size.x / view.pane_rects[beta].size.x, width_ratio),
		"Window resize preserves column proportions",
	)
	check(
		is_equal_approx(view.pane_rects[beta].size.y / view.pane_rects[gamma].size.y, height_ratio),
		"Window resize preserves row proportions",
	)
	await pinch_overview()
	await hold(0.5)
	check(view.boundary.visible, "Overview shows the main-area border")
	await wait(1.0)
	if recording:
		host.layout_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		host._resize_menu_content()
	else:
		root.size = original
	await hold(0.5)
	await view_menu("Fit to Main Area")
	await say("Turn tiling off and back on without replacing any shell")
	var before: Dictionary = view.pane_rects.duplicate()
	await toggle_tiling()
	for key in before:
		check(
			view.pane_rects[key].is_equal_approx(before[key]),
			"Turning tiling off preserves visible placement",
		)
	await toggle_tiling()
	check_tiles()
	for key in pids:
		check(
			host.sessions[int(key.substr(1))].term.get_shell_pid() == pids[key],
			"Layout changes preserve %s's shell" % key,
		)
	check(
		pid > 0 and host.workspace_layout.tabs.size() == 1,
		"Three live windows remain in one tab",
	)
	await wait(1.0)
	await say("Switch tabs and return; this tab keeps its own tiling")
	await open_tabs(2)
	check(
		host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false) == app.tiling_default,
		"New tabs inherit the application default independently",
	)
	await select_tab(0)
	await wait_landed()
	check(
		host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false),
		"The original tab keeps tiling enabled",
	)
	check_tiles()

	check(
		is_equal_approx(view.pane_rects[alpha].size.x / view.pane_rects[beta].size.x, width_ratio),
		"Tab round trip preserves resized columns",
	)
	check(
		is_equal_approx(view.pane_rects[beta].size.y / view.pane_rects[gamma].size.y, height_ratio),
		"Tab round trip preserves resized rows",
	)
	await say("Balance sizes restores equal siblings")
	var response := preload("res://scenes/TilingCommands.gd").dispatch(
		host,
		int(alpha.substr(1)),
		"tiling.balance-sizes",
		{ },
	)
	check(not response.has("error"), "Balance command succeeds")
	check(
		is_equal_approx(view.pane_rects[alpha].size.x, view.pane_rects[beta].size.x),
		"Balance resets column sizes",
	)
	check(
		is_equal_approx(view.pane_rects[beta].size.y, view.pane_rects[gamma].size.y),
		"Balance resets row sizes",
	)
	check_tiles()
