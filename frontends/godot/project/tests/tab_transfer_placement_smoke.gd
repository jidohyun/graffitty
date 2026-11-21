extends "res://tests/tab_window_session_smoke.gd"
## A cross-session drop must preserve both the grab and the rendered proposal.

func run() -> void:
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if not check_host(wrapper): return
	var target: Node = wrapper.host
	app = target.application
	app.scripted_pointer = true
	await settled(target)
	var destination: int = target.workspace_layout.active
	var view: Control = target.workspace_view
	var tree: Dictionary = target.workspace_layout.tab(destination).tree
	tree.tiling = false
	tree.physics = false
	Layout.find(tree, target.pane_focus).rect = Rect2(40, 80, 400, 300)
	view.refresh()
	target.session_backend.commit_workspace(target)
	await settled(target)
	for kind in ["tab", "pane", "collision", "pane_collision", "tiled_stash"]:
		await target.create_native_window()
		var source: Node = app.hosts.back()
		await settled(source)
		if kind == "tiled_stash":
			target.workspace_layout.tab(destination).tree.tiling = true
			target.workspace_layout.tab(destination).tree.physics = false
			target.workspace_view.refresh()
			target.session_backend.commit_workspace(target)
			await settled(target)
		if kind.ends_with("collision"):
			target.workspace_layout.tab(destination).tree.physics = true
			target.workspace_view.wake_pane_physics()
			target.session_backend.commit_workspace(target)
			await settled(target)
		source.get_window().position = root.position + Vector2i(root.size.x + 200, 0)
		check(source != target, kind + ": separate source session exists")
		var key: String = source.pane_focus
		var id := int(key.substr(1))
		var pid: int = source.sessions[id].term.get_shell_pid()
		var original := Rect2(240, 140, 480, 320)
		var source_tree: Dictionary = source.workspace_layout.tab(source.workspace_layout.active).tree
		source_tree.tiling = false
		source_tree.physics = false
		Layout.find(source_tree, key).rect = original
		source.workspace_view.refresh()
		source.session_backend.commit_workspace(source)
		await settled(source)
		view.overview = true
		view.navigation_zoom = .6
		view.navigation_center = view.content_rect().get_center() + Vector2(100, 50)
		view._apply_navigation()
		view.save_navigation()
		await create_timer(.2).timeout
		var grab := Vector2(40, 22)
		if not kind.begins_with("pane"):
			await start_drag(source)
			grab.y = source.workspace_view.tab_bar.tabs._press_point.y
		else:
			var pane: Control = source.workspace_view.panes[key]
			pane.begin_header_drag(source.workspace_view.canvas_root.get_global_transform() * (original.position + grab))
			pane._dragging = true
			pane._transfer = true
			app.begin_pane_drag(source, pane, key)
		var point := Vector2(400, 280) if kind.ends_with("collision") else Vector2(780, 460)
		if kind == "tiled_stash": point = Vector2(view.content_rect().end.x + 100, view.content_rect().get_center().y)
		var pointer: Vector2 = app.screen_point(target.get_window(), view.window_point(point))
		pointer_position = pointer
		# Deliver captured motion/release through the native source window,
		# including panes rendered in the standalone projected SubViewport.
		move_drag(pointer)
		await create_timer(.1).timeout
		check(app.drag.get("mode") == app.DragMode.MERGE and view.layout_preview.visible, kind + ": cross-session placement preview appears")
		var expected: Dictionary = view.preview_plan.get("rectangles", {}).duplicate()
		var expected_tiling: bool = view.preview_plan.tree.get("tiling", false)
		var expected_stash: bool = Layout.find(view.preview_plan.tree, key).get("stashed", false)
		check(expected.has(key), kind + ": preview includes arriving pane")
		if not expected.has(key): quit(1); return
		var proposed: Rect2 = expected[key]
		check(proposed.size.is_equal_approx(original.size), kind + ": preview preserves pane size")
		check((point - proposed.position).is_equal_approx(grab), kind + ": preview retains the grabbed point near the header")
		var shown: Vector2 = app.screen_point(target.get_window(), view.window_point(proposed.position))
		var center: Vector2 = view.navigation_center
		var zoom: float = view.navigation_zoom
		await end_drag(pointer)
		deadline = Time.get_ticks_msec() + 10000
		while (app.hosts.size() != 1 or target.workspace_layout.containing(key) != destination) and Time.get_ticks_msec() < deadline:
			await process_frame
		await settled(target)
		# The server transaction can finish before the presentation flight lands.
		# Compare the final screen position after that animation, not its midpoint.
		deadline = Time.get_ticks_msec() + 5000
		while target.world.camera_motion.moving and Time.get_ticks_msec() < deadline: await process_frame
		await process_frame
		check(not target.world.camera_motion.moving, kind + ": transfer camera animation settles")
		check(target.workspace_layout.containing(key) == destination, kind + ": drop transfers into the destination tab")
		var committed: Dictionary = target.workspace_layout.tab(destination).tree
		check(committed.get("tiling", false) == expected_tiling, kind + ": drop preserves preview tiling mode")
		check(Layout.find(committed, key).get("stashed", false) == expected_stash, kind + ": drop preserves preview stash classification")
		for placed in expected:
			if kind.ends_with("collision") and placed != key: continue
			if not view.pane_rects.get(placed, Rect2()).is_equal_approx(expected[placed]):
				print("PLACEMENT_MISMATCH ", kind, " ", placed, " preview=", expected[placed], " actual=", view.pane_rects.get(placed, Rect2()))
			check(view.pane_rects.get(placed, Rect2()).is_equal_approx(expected[placed]), kind + ": final geometry matches preview for " + placed)
		check(view.navigation_center.is_equal_approx(center) and is_equal_approx(view.navigation_zoom, zoom), kind + ": transfer preserves the destination camera")
		var actual: Vector2 = app.screen_point(target.get_window(), view.window_point(view.pane_rects.get(key, Rect2()).position))
		check(actual.distance_to(shown) < 1.0, kind + ": pane lands at its previewed screen position (preview=%s actual=%s)" % [shown, actual])
		check(target.sessions.has(id) and target.sessions[id].term.get_shell_pid() == pid, kind + ": transfer preserves the shell")
	check(error_watch.errors.is_empty(), "No engine or script errors: " + str(error_watch.errors))
	print("TAB_TRANSFER_PLACEMENT failures=", JSON.stringify(failures))
	for live in app.hosts.duplicate():
		live.get_parent().connection.disconnect_remote()
		live.get_parent().queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
