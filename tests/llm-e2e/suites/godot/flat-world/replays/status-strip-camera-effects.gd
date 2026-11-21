extends "../../../../replay/replay.gd"


func edge_energy(image: Image, rect: Rect2i) -> float:
	var sum := 0.0
	var samples := 0
	for y in range(rect.position.y, rect.end.y - 1):
		for x in range(rect.position.x, rect.end.x - 1):
			var value := image.get_pixel(x, y).get_luminance()
			sum += absf(value - image.get_pixel(x + 1, y).get_luminance())
			sum += absf(value - image.get_pixel(x, y + 1).get_luminance())
			samples += 2
	return sum / maxf(samples, 1)


func exercise_camera(flat_2d: bool) -> void:
	var view: Control = host.workspace_view
	var world: Node = host.world
	var key: String = host.pane_focus
	world.fx_cfg.set_option("state.typing", "camera.zoom", 1.6)
	world.fx_cfg.set_option("state.typing", "camera.tilt_limit_deg", 16.0)
	world.fx_cfg.set_option("state.typing", "camera.drift_px", 0.0)
	world.fx_cfg.set_option("state.typing", "sheet.ripple", 0.0)
	world.fx_cfg.set_option("behavior", "idle_after", 10.0)
	world.fx_cfg.set_option("scene.camera", "dof_blur_amount", .4)
	world._fx_apply_scene()
	view.overview = true
	view.navigation_center = view.size * .5
	view.navigation_zoom = .45
	view._apply_navigation()
	await hold(.5)
	if not check(view.status_strips.has(key), "Overview creates a status strip"): return
	var strip: Control = view.status_strips[key]
	check(strip.visible and strip.get_viewport() == view.canvas, "The visible strip is painted on the workspace sheet")
	var placement := strip.get_transform()
	var revision: int = view.status_layout_updates
	var before: Rect2 = view.control_screen_rect(strip)
	await say("Typing moves and tilts the baked strip with its pane")
	await type("printf status-strip-camera")
	await hold(1.0)
	check(world.navigation_camera_active and world.navigation_camera.zoom > 1.3, "Real typing animates the navigation camera")
	check(strip.visible and strip.get_transform().is_equal_approx(placement), "Typing leaves the strip's sheet placement, size and visibility baked")
	check(view.status_layout_updates == revision, "Typing zoom, follow and tilt do not rerun status placement")
	check(not view.control_screen_rect(strip).is_equal_approx(before), "The strip moves on screen with the animated camera")
	var sheet_rect: Rect2 = view.control_canvas_rect(strip)
	check(sheet_rect.size.is_equal_approx(strip.size * strip.scale), "Transition captures retain the compensated sheet extent")
	var captured := preload("res://scenes/CellShatter.gd").capture_control(strip)
	view.canvas.add_child(captured)
	check(captured.get_child(0).scale == Vector2.ONE, "A transition capture does not magnify and crop the status text twice")
	captured.queue_free()
	if not flat_2d:
		var top: Vector2 = view.view_point(strip.position)
		var bottom: Vector2 = view.view_point(strip.position + Vector2(0, strip.size.y * strip.scale.y))
		check(world.navigation_camera.tilt.length() > .01 and absf(bottom.x - top.x) > .2, "The status strip inherits visible perspective tilt")
		if check(world.ink_dof != null, "The real 3D ink compositor is active"):
			world.set_process(false)
			var lens: Vector4 = world.ink_dof.lens
			var blurred := await screen_image()
			var footprint: Rect2 = view.control_screen_rect(strip)
			var pixels := Vector2(blurred.get_size()) / root.get_visible_rect().size
			var crop := Rect2i(Rect2((view.global_position + footprint.position) * pixels, footprint.size * pixels).grow(-4)).intersection(Rect2i(Vector2i.ZERO, blurred.get_size()))
			world.ink_dof.set_lens(lens.x, 0.0, lens.z, lens.w)
			var sharp := await screen_image()
			world.ink_dof.set_lens(lens.x, lens.y, lens.z, lens.w)
			var blurred_edges := edge_energy(blurred, crop)
			var sharp_edges := edge_energy(sharp, crop)
			check(lens.y > 1 and crop.size.x > 30 and crop.size.y > 20, "Measure visible status text with the active depth-of-field lens")
			check(sharp_edges > .002 and blurred_edges < sharp_edges * .95, "Status glyphs receive real depth-of-field blur (%.4f vs %.4f edges)" % [blurred_edges, sharp_edges])
			var directory := evidence_path("status-strip-camera-%d" % OS.get_process_id())
			DirAccess.make_dir_recursive_absolute(directory)
			blurred.save_png(directory.path_join("tilted-blurred.png"))
			sharp.save_png(directory.path_join("tilted-sharp.png"))
			print("STATUS_STRIP_CAMERA_EVIDENCE ", directory)
			world.set_process(true)
	await say("Deliberate pan and zoom update the baked layout")
	revision = view.status_layout_updates
	view.navigation_center += Vector2(90, 40)
	view.navigation_zoom = .55
	view._apply_navigation()
	await hold(.3)
	check(view.status_layout_updates > revision and not strip.scale.is_equal_approx(placement.get_scale()), "Manual framing recomputes placement and readable scale")
	check(not view.control_canvas_rect(strip).intersects(view.panes[key].get_rect()), "Status placement remains outside terminal content")
	view.show_main()
	await hold(.2)
	check(not strip.visible, "Main View hides overview status even while typing effects are active")


func play() -> void:
	await camera_at_rest()
	if host.workspace_view.physics_enabled(): host.workspace_view.toggle_physics()
	await exercise_camera(false)
	check(host.switch_world("flat-2d"), "Open Flat 2D with the same workspace")
	await camera_at_rest()
	await exercise_camera(true)
