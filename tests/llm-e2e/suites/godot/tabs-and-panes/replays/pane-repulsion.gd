extends "main-area-tiling.gd"
## Godot's native View menu is the equivalent of the shared Effects checkbox.
var evidence: String
var samples: Array = []

func capture_stage(label: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(evidence.path_join(label + ".png"))
	samples.append({"stage": label, "rectangles": host.workspace_view.pane_rects.duplicate()})
	FileAccess.open(evidence.path_join("motion.json"), FileAccess.WRITE).store_string(JSON.stringify(samples, "  "))

func play() -> void:
	evidence = OS.get_environment("XDG_STATE_HOME").path_join("pane-repulsion")
	DirAccess.make_dir_recursive_absolute(evidence)
	await camera_at_rest()
	host.world.fx_enabled = false
	var view: Control = host.workspace_view
	var first: String = host.pane_focus
	for i in 2:
		host.create_terminal_window(first)
		await owner_at_rest()
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	var keys: Array = Layout.keys(group.tree)
	if not check(keys.size() == 3, "Three real terminals are available"): return
	var second: String = keys.filter(func(key): return key != first)[0]
	var distant: String = keys.filter(func(key): return key != first and key != second)[0]
	group.tree["tiling"] = false
	group.tree["physics_anchor"] = first
	await view_menu("Floating Pane Physics")
	check(not view.physics_enabled(), "The View menu disables floating physics")
	var origin: Vector2 = view.content_rect().position + Vector2(400, 140)
	var size := Vector2(360, 240)
	Layout.find(group.tree, first)["rect"] = Rect2(origin, size)
	Layout.find(group.tree, second)["rect"] = Rect2(origin + Vector2(280, 0), size)
	Layout.find(group.tree, distant)["rect"] = Rect2(origin + Vector2(750, 400), size)
	view.refresh()
	await owner_at_rest()
	# Layout acknowledgements do not wait for the independent terminal-scene
	# stream. Establish the requested floating grid before measuring motion.
	for key in keys:
		var term = host.sessions[int(key.substr(1))].term
		var insets: Array = term.get_meta("server_content_insets")
		var pixels := size - Vector2(insets[0] + insets[2], insets[1] + insets[3])
		var cell: Vector2 = term.get_cell_size()
		var expected := Vector2i(floori(pixels.x / cell.x), floori(pixels.y / cell.y)).clamp(Vector2i(20, 1), Vector2i(500, 300))
		var deadline := Time.get_ticks_msec() + 10000
		while term.get_grid_size() != expected and Time.get_ticks_msec() < deadline:
			await process_frame
		if not check(term.get_grid_size() == expected, "Floating setup reaches its actual terminal grid: %s (%s)" % [key, expected]): return
	var pids := {}
	var grids := {}
	for key in keys:
		var term = host.sessions[int(key.substr(1))].term
		pids[key] = term.get_shell_pid()
		grids[key] = term.get_grid_size()
	var frozen: Dictionary = view.pane_rects.duplicate()
	await capture_stage("disabled")
	await hold(0.4)
	check(view.pane_rects == frozen, "Disabled panes remain stationary")
	await view_menu("Floating Pane Physics")
	for i in 6:
		await hold(0.2)
		await capture_stage("motion-%02d" % i)
	check(view.pane_rects[first] == frozen[first], "The latest placed anchor stays fixed")
	check(view.pane_rects[second].position.distance_to(frozen[second].position) > 20, "The overlapping neighbour visibly moves")
	check(view.pane_rects[distant] == frozen[distant], "The distant pane stays fixed")
	for key in keys:
		check(view.panes[key].position.is_equal_approx(view.pane_rects[key].position), "Header and content follow %s" % key)
		var term = host.sessions[int(key.substr(1))].term
		check(term.get_shell_pid() == pids[key] and term.get_grid_size() == grids[key], "Motion preserves the real PID and grid: %s (pid %s -> %s; grid %s -> %s)" % [key, pids[key], term.get_shell_pid(), grids[key], term.get_grid_size()])
	group.tree["physics_anchor"] = second
	Layout.find(group.tree, first)["rect"] = frozen[first]
	Layout.find(group.tree, second)["rect"] = frozen[second]
	host.focus_pane(first)
	await owner_at_rest()
	# type() deliberately pauses 0.6s for the viewer. Observe the actual key
	# before the independent 0.8s typing-pin timer expires.
	_send_key(KEY_SPACE, 32, {})
	await process_frame
	view.refresh()
	var typing_rect: Rect2 = view.pane_rects[first]
	await hold(0.2)
	check(view.physics_typing and view.pane_rects[first] == typing_rect, "Real typing temporarily pins its pane")
	await capture_stage("typing-pinned")
	await hold(1.4)
	check(not view.physics_typing and view.pane_rects[first].position.distance_to(typing_rect.position) > 1, "Repulsion resumes after typing ends")
	await capture_stage("typing-resumed")
	await toggle_tiling()
	await owner_at_rest()
	var tiled: Dictionary = view.pane_rects.duplicate()
	await hold(0.5)
	check(view.pane_rects == tiled, "Tiled leaves remain stationary")
	await capture_stage("tiled")
	await view_menu("Floating Pane Physics")
	check(not view.physics_enabled(), "The current tab stores its disabled setting")
	await open_tabs(2)
	check(view.physics_enabled(), "A new tab independently defaults to enabled")
	await select_tab(0)
	check(not view.physics_enabled(), "Returning retains the original tab setting")
	await camera_at_rest()
	await hold(2.0)
	if OS.get_name() == "Windows":
		# TrackPopupMenuEx runs a native modal loop. Capture/dismiss that owned
		# menu from a helper; the main Godot thread cannot advance this replay.
		var helper: String = get_script().resource_path.get_base_dir().path_join("../../windows/replays/native-menu.py")
		OS.create_process("python", [ProjectSettings.globalize_path(helper), str(OS.get_process_id()), evidence])
		for button in host.window_menu.get_child(0).get_children():
			if button is MenuButton and button.get_popup() == host.popup_menus.get("View"):
				await click(on(button))
				break
		var path := evidence.path_join("native-menu.json")
		if check(FileAccess.file_exists(path), "The actual native View menu was captured"):
			var native: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
			for entry in host.menu_entries:
				if entry.label == "View::Floating Pane Physics":
					check(not native.items[entry.index].checked, "The native menu shows physics unchecked for this tab")
	await capture_stage("per-tab-disabled")
