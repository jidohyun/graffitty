extends "res://tests/flat_2d_foreground_clip_smoke.gd"
## Compare actual projected foreground with its backdrop, including the 3D
## fallback used during camera flights. No framebuffer readback in production.

func run() -> void:
	var host := TestHost.new()
	root.add_child(host)
	await create_timer(0.5).timeout
	for path in ["", "bistro"]:
		check(host.switch_world(path), "World loads: " + path)
		await create_timer(0.5).timeout
		var world: Node = host.world
		world.fx_enabled = false
		world._settle_camera_at_rest()
		world._apply_camera_fx()
		world.set_process(false)
		world.scenery_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var view: Control = host.workspace_view
		var marker := ColorRect.new()
		marker.color = Color(0.9, 0.15, 0.4)
		marker.size = view.canvas_size()
		marker.z_index = 100
		view.canvas_root.add_child(marker)
		var viewport: SubViewport = host.world_viewport
		var wall: MeshInstance3D = world.walls[world.surfaces[world.active].id]
		for opacity in ([1.0, 0.35] if path.is_empty() else [1.0]):
			if path.is_empty():
				viewport.transparent_bg = opacity < 1.0
				world.scenery_vp.transparent_bg = true
				RenderingServer.set_default_clear_color(Color.TRANSPARENT)
				world.backdrop_color.a = opacity
				world._configure_backdrop(world.scenery_material)
				world._configure_backdrop(world.ink_overlay.material)
			for ink in [true, false]:
				world._set_ink_active(ink)
				world.set_workspace_clip_top(0.0)
				wall.show()
				var full := await snapshot(viewport)
				wall.hide()
				var background := await snapshot(viewport)
				wall.show()
				world.set_workspace_clip_top(0.25)
				var clipped := await snapshot(viewport)
				var width := clipped.get_width()
				var height := clipped.get_height()
				var top := Rect2i(0, 0, width, height / 4 - 2)
				var bottom := Rect2i(0, height / 4 + 2, width, height - height / 4 - 2)
				var label := "%s opacity=%s ink=%s" % [path, opacity, ink]
				check(region_error(full, background, top) > 0.1, "Foreground reaches tab area: " + label)
				check(region_error(clipped, background, top) < 0.015, "Tab area retains background pixels and alpha: " + label)
				check(region_error(clipped, full, bottom) < 0.015, "Clipping preserves content below tabs: " + label)
		if path.is_empty():
			wall.hide()
			world._set_ink_active(false)
			world.cam.position = Vector3(150, -90, 40)
			world.cam.rotation = Vector3(0.8, -1.1, 0.4)
			world.cam.fov = 100.0
			var moved := await snapshot(viewport)
			var fill: Color = world.backdrop_color
			var expected: Color = (fill.srgb_to_linear() * fill.a).linear_to_srgb()
			expected.a = fill.a
			var error := 0.0
			for y in [0, moved.get_height() / 2, moved.get_height() - 1]:
				for x in [0, moved.get_width() / 2, moved.get_width() - 1]:
					var actual := moved.get_pixel(x, y)
					error = maxf(error, maxf(absf(actual.a - expected.a), maxf(absf(actual.r - expected.r), maxf(absf(actual.g - expected.g), absf(actual.b - expected.b)))))
			check(error < 0.012, "Extreme camera pan/tilt/FOV leaves every background edge filled: %s" % error)
			check(world.get_node_or_null("Backdrop") == null, "Background needs no 3D geometry")
		marker.queue_free()
	check(error_watch.errors.is_empty(), "No engine/script/shader errors: " + str(error_watch.errors))
	host.queue_free()
	await process_frame
	print("WORLD_FOREGROUND_CLIP_PASS" if failures.is_empty() else "WORLD_FOREGROUND_CLIP_FAIL")
	quit(0 if failures.is_empty() else 1)
