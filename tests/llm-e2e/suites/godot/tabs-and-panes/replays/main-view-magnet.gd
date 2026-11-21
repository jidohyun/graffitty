extends "main-area-tiling.gd"

func check_main(label: String) -> void:
	var view: Control = host.workspace_view
	check(not view.overview and is_equal_approx(view.navigation_zoom, view.main_frame().zoom), label + ": exact main zoom")
	check(view.navigation_center.distance_to(view.main_frame().center) < 0.1, label + ": exact main center")
	var saved: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).navigation
	check(not saved.overview and is_equal_approx(saved.zoom, view.main_frame().zoom), label + ": saved view matches")
	check(Vector2(saved.center[0], saved.center[1]).distance_to(view.main_frame().center) < 0.1, label + ": saved center matches")

func magnify(factor: float, previous: Vector2, center: Vector2) -> void:
	var view: Control = host.workspace_view
	var gesture := InputEventMagnifyGesture.new()
	gesture.position = overlay.pointer
	gesture.factor = factor
	var physical := root.get_final_transform() * view.get_global_transform_with_canvas()
	gesture.set_meta("pinch_previous", physical * previous)
	gesture.set_meta("pinch_center", physical * center)
	gesture.set_meta("pinch_pan", physical.basis_xform(center - previous))
	root.push_input(gesture, true)
	await process_frame

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var key: String = host.pane_focus
	var pid: int = host.sessions[int(key.substr(1))].term.get_shell_pid()
	var rectangles: Dictionary = view.pane_rects.duplicate()
	for world in ["", "flat-2d"]:
		host.switch_world(world)
		await camera_at_rest()
		await check_gestures()
	check(view.pane_rects == rectangles, "Gestures preserve pane layout")
	check(host.sessions[int(key.substr(1))].term.get_shell_pid() == pid, "Gestures preserve shell PID")

func check_gestures() -> void:
	var view: Control = host.workspace_view
	view.show_main()
	var center: Vector2 = view.size * 0.5
	await point_at(view.get_global_transform_with_canvas() * center)
	await say("Pinch back near Main to snap into place")
	await pinch(0.8, 0.3)
	await hold(0.5)
	check(view.overview and view.navigation_zoom < float(view.main_frame().zoom) * 0.9, "A different scale is not pulled to Main")
	await pinch(float(view.main_frame().zoom) * 0.98 / view.navigation_zoom, 0.3)
	check_main("Pinch snaps to Main while fingers are moving")
	await say("Continue pinching to pull away from Main")
	var expected: float = float(view.main_frame().zoom) * 0.98
	for i in 15:
		expected *= 1.015
		await magnify(1.015, center, center)
		if i == 0: check_main("Small continued movement stays in the magnet")
	check(view.overview and is_equal_approx(view.navigation_zoom, expected), "Small pinch updates accumulate and escape the magnet")
	var stopped_zoom: float = view.navigation_zoom
	await hold(0.5)
	check(is_equal_approx(view.navigation_zoom, stopped_zoom), "Stopping the pinch causes no delayed correction")

	# Both scale and position must be near Main. Away from it, keep the exact
	# sheet point under a moving centroid, including simultaneous pan and zoom.
	view.show_main()
	await process_frame
	await magnify(0.8, center, center + Vector2(200, 0))
	var previous := center + Vector2(200, 0)
	var moved := previous + Vector2(12, -8)
	var anchor: Vector2 = view.canvas_point_at(previous)
	await magnify(float(view.main_frame().zoom) * 0.98 / view.navigation_zoom, previous, moved)
	check(view.overview and is_equal_approx(view.navigation_zoom, float(view.main_frame().zoom) * 0.98), "An off-center pinch near Main scale does not snap")
	check(view.view_point(anchor).distance_to(moved) < 2.0, "Combined zoom and pan preserve the moving anchor away from Main")

	view.show_main()
	await process_frame
	await magnify(0.8, center, center)
	await magnify(float(view.main_frame().zoom) * 0.98 / view.navigation_zoom, center, center + Vector2(6, 4))
	check_main("Combined zoom and pan snap near Main")
	previous = center + Vector2(6, 4)
	for i in 20:
		moved = previous + Vector2(5, 0)
		await magnify(1.0, previous, moved)
		previous = moved
	check(view.overview and view.navigation_center.distance_to(view.main_frame().center) > 50, "Pan-only updates within a pinch can escape the magnet")

	# The existing pan path must continue to snap as well.
	view.show_main()
	await process_frame
	var units := 0.03 if OS.get_name() == "macOS" else 1.0
	view.pan_workspace(Vector2(100, 0) * units, center)
	await process_frame
	check(view.overview, "A deliberate pan leaves Main")
	view.pan_workspace(Vector2(-90, 0) * units, center)
	check_main("Panning back near Main still snaps")

	view.show_main()
	check_main("Explicit Main restores the exact view")
	view.show_overview()
	await hold(0.6)
	check(view.overview and view.navigation_zoom < 0.5, "Explicit Overview clears the magnet")
