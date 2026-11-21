extends "res://tests/flat_2d_foreground_clip_smoke.gd"
## Render both borders through the live workspace camera, not just its math.

func capture() -> Image:
	for frame in 3:
		await process_frame
		await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Border tilt checks require a renderer; run without --headless")
		quit(1)
		return
	var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if evidence.is_empty():
		evidence = OS.get_cache_dir().path_join("graffitty-border-tilt-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(evidence)
	var host := TestHost.new()
	root.add_child(host)
	await create_timer(1.0).timeout
	var view: Control = host.workspace_view
	var world: Node = host.world
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree.tiling = false
	group.tree.physics = false
	Layout.find(group.tree, host.pane_focus).rect = Rect2(200, 180, 650, 380)
	view.refresh()
	await create_timer(0.3).timeout
	view.overview = true
	view.navigation_zoom = 0.65
	view.navigation_center = view.canvas_size() * 0.5 + Vector2(40, 15)
	view._apply_navigation()
	await create_timer(0.3).timeout
	var resting_basis: Basis = world.cam.global_basis
	var resting_corner: Vector2 = view.view_point(view.content_rect().position)
	host.active_terminal().grab_focus()
	for character in "printf BORDER_TILT":
		var event := InputEventKey.new()
		event.unicode = character.unicode_at(0)
		event.pressed = true
		root.push_input(event)
		event = event.duplicate()
		event.pressed = false
		root.push_input(event)
		await create_timer(0.05).timeout
	await create_timer(0.2).timeout
	check(world.navigation_camera_active and world.navigation_camera.tilt.length() > 0.001, "GUI typing activates tilt outside Main View")
	check(not resting_basis.is_equal_approx(world.cam.global_basis), "GUI typing tilts the rendered camera")
	check(resting_corner.distance_to(view.view_point(view.content_rect().position)) > 0.1, "Main Area corner moves with the typing camera")
	(await capture()).save_png(evidence.path_join("typing.png"))
	world.set_process(false)
	world.fx_enabled = true
	world.fx_curvature_deg = 0.0
	world.fx_mat.set_shader_parameter("curvature_rad", 0.0)
	world.ink_dof.enabled = false
	world._advance_navigation_camera(0.0, world.fx_cfg.frame("idle"), false, 0.35)
	world.navigation_camera.tilt = Vector2(0.25, -0.18)
	world._apply_camera_fx()
	world._update_ink_view()
	view.update_raster_region()
	view._sync_chromium_links()
	var shown := await capture()
	shown.save_png(evidence.path_join("tilted.png"))
	view.agent_links.editing = false
	view.agent_links.redraw()
	var without_selection := await capture()
	without_selection.save_png(evidence.path_join("without-selection.png"))
	view.boundary.hide()
	var without_borders := await capture()
	without_borders.save_png(evidence.path_join("without-borders.png"))
	var report := {"world": world.get_script().resource_path, "borders": {}}
	for kind in ["selection", "main"]:
		var rect: Rect2 = view.pane_rects[host.pane_focus] if kind == "selection" else view.content_rect()
		var corners: Array[Vector2] = [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
		var samples := []
		var hits := 0
		var a := shown if kind == "selection" else without_selection
		var b := without_selection if kind == "selection" else without_borders
		var mapping: Transform2D = view.get_viewport().get_final_transform() * view.get_global_transform_with_canvas()
		for side in 4:
			for t in [0.2, 0.35, 0.5, 0.65, 0.8]:
				var point: Vector2 = mapping * view.view_point(corners[side].lerp(corners[(side + 1) % 4], t))
				var difference := 0.0
				for y in range(roundi(point.y) - 5, roundi(point.y) + 6):
					for x in range(roundi(point.x) - 5, roundi(point.x) + 6):
						if x < 0 or y < 0 or x >= a.get_width() or y >= a.get_height(): continue
						var delta := a.get_pixel(x, y) - b.get_pixel(x, y)
						difference = maxf(difference, delta.b)
				hits += int(difference > 0.06)
				samples.append({"point": [point.x, point.y], "blue_difference": difference})
		report.borders[kind] = samples
		check(hits == 20, "%s border follows all tilted edges (%d/20)" % [kind, hits])
	check(error_watch.errors.is_empty(), "No engine/script/shader errors: " + str(error_watch.errors))
	report.failures = failures
	FileAccess.open(evidence.path_join("result.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	host.queue_free()
	await process_frame
	print("WORKSPACE_BORDER_TILT_PASS" if failures.is_empty() else "WORKSPACE_BORDER_TILT_FAIL")
	quit(0 if failures.is_empty() else 1)
