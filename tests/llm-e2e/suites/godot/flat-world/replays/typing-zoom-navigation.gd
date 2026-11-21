extends "../../../../replay/replay.gd"

func play() -> void:
	await labelled_tabs(["ZOOM"])
	for path in ["", "flat-2d"]:
		host.switch_world(path)
		await hold(.2)
		var world: Node = host.world
		var view: Control = host.workspace_view
		world.fx_enabled = true
		world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.rest_state), "camera.zoom", 1.0)
		var destination: Dictionary = world.fx_cfg.frame(str(world.fx_cfg.behavior.active_state))
		destination["camera.zoom"] = 1.15
		destination["camera.drift_px"] = 0.0
		var sheet: Vector2 = world._sheet_size()
		view.overview = true
		for base_zoom in [.1, .5, 1.8]:
			view.navigation_zoom = base_zoom
			view.navigation_center = sheet * .5
			world.navigation_camera_active = false
			world._update_camera_follow_bounds()
			for frame in 180: world._advance_navigation_camera(1.0 / 60.0, destination, true, .8)
			check(absf(world._navigation_camera_zoom() - base_zoom * 1.15) < .0001, "Typing zoom multiplies current view in " + path)
			check(view.navigation_zoom == base_zoom, "Typing never overwrites saved navigation")
			var rest := destination.duplicate()
			rest["camera.zoom"] = 1.0
			for frame in 360: world._advance_navigation_camera(1.0 / 60.0, rest, false, 2.5)
			check(world._navigation_camera_center().distance_to(view.navigation_center) < .1, "Idle restores saved view centre")
		view.navigation_zoom = .5
		view.navigation_center = sheet * .5 + Vector2(6000, 4000)
		world.navigation_camera_active = false
		for frame in 180: world._advance_navigation_camera(1.0 / 60.0, destination, true, .8)
		world._apply_camera_fx()
		var cursor: Vector2 = world._camera_cursor_uv() * sheet
		var screen: Vector2 = (cursor - world._navigation_camera_center()) * world._navigation_camera_zoom() + sheet * .5
		check(Rect2(Vector2.ZERO, sheet).has_point(screen), "Typing reveals cursor outside a panned, zoomed-out view")
		var actual: Vector2 = world.sheet_window_fraction(cursor)
		check(Rect2(0, 0, 1, 1).has_point(actual), "Rendered camera includes cursor in " + path)
		var bounds: Rect2 = world.fx_camera.follow_rect
		var top: float = (bounds.position.y - world._navigation_camera_center().y) * world._navigation_camera_zoom() + sheet.y * .5
		check(top >= world.fx_camera.follow_top_inset - .1, "Pane title stays visible when it fits with cursor")
		world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.active_state), "camera.zoom", 1.15)
		world.navigation_camera_active = false
		view.navigation_center = sheet * .5
		world.fx_idle_after = 10.0
		world.fx_last_key = world.fx_time
		world.fx_enabled = false
		world._apply_camera_fx()
		view._update_compact_headers()
		var title: Label = view.pane_titles[host.pane_focus]
		var title_scale := title.scale
		var rest_height: float = view.title_screen_rect(title).size.y
		world.fx_enabled = true
		await hold(1.2)
		check(world.navigation_camera_active and absf(world._navigation_camera_zoom() - .575) < .005, "Live frame loop applies relative typing zoom")
		check(title.get_viewport() == view.canvas, "Titles share the world sheet and its effects")
		check(title.scale.is_equal_approx(title_scale), "Typing does not cancel its own zoom through title compensation")
		check(view.title_screen_rect(title).size.y > rest_height * 1.08, "Typing magnifies the title with the pane in " + path)
		var started := Time.get_ticks_usec()
		for sample in 200: view._update_compact_headers()
		print("[profile] %s one-pane header update average: %.3f ms" % [path, (Time.get_ticks_usec() - started) / 200000.0])
