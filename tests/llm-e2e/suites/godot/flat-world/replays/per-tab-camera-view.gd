extends "../../../../replay/replay.gd"

var views := { }
var layouts := { }


func reference() -> PackedVector2Array:
	var view: Control = host.workspace_view
	return PackedVector2Array(
		[
			view.window_point(Vector2.ZERO),
			view.window_point(view.canvas_size()),
			view.window_point(view.canvas_size() * Vector2(0.25, 0.7)),
		]
	)


func matches(index: int) -> void:
	check(host.get_tabs()[index].active, "The requested tab is active")
	var actual := reference()
	var error := 0.0
	for i in actual.size():
		error = maxf(error, actual[i].distance_to(views[index][i]))
	check(error <= 2.0, "Tab %d restores its view within two pixels (%.3f px)" % [index, error])
	check(
		host.workspace_view.pane_rects == layouts[index],
		"Tab %d navigation preserves pane placement" % index,
	)


func visit(index: int) -> void:
	start_watching_camera()
	await select_tab(index)
	await camera_at_rest()
	matches(index)
	await hold(1.0)
	matches(index)
	var frames := stop_watching_camera()
	check_no_jump_cut(frames, "Tab %d flight" % index)
	check_one_motion(frames, "Tab %d flight" % index)


func customize(factor: float, delta: Vector2) -> void:
	await point_at(content())
	# Pan first enters explicit navigation; the pinch remains pointer-anchored.
	await pan_pixels(delta)
	var before: float = host.workspace_view.navigation_zoom
	await pinch(factor)
	check(
		is_equal_approx(host.workspace_view.navigation_zoom, before * factor),
		"Pinch changes the navigation zoom by the requested factor",
	)
	await camera_at_rest()


func play() -> void:
	use_config(get_script().resource_path.get_base_dir().path_join("../per-tab-camera-view.conf"))
	await labelled_tabs(["ALPHA", "BETA", "GAMMA"])
	await say("Prepare distinct views")
	for i in 3:
		await select_tab(i)
		host.workspace_view.toggle_physics()
		host.workspace_view.show_main()
		await type("echo CAMERA_%d $$ {enter}" % i)
		host.create_terminal_window()
		await camera_at_rest()
		var pane: Control = host.workspace_view.panes[host.pane_focus]
		await drag(on(pane.handle), on(pane.handle) + Vector2(70 * (i + 1), 30 * (i + 1)))
		await type("echo SECOND_%d $$ {enter}" % i)
		await camera_at_rest()
		if i < 2:
			await customize(
				1.4 if i == 0 else 0.65,
				Vector2(180, -90) if i == 0 else Vector2(-160, 110),
			)
		views[i] = reference()
		layouts[i] = host.workspace_view.pane_rects.duplicate()
	check(
		views[0][0].distance_to(views[1][0]) > 30 and views[0][1].distance_to(views[2][1]) > 30,
		"References have visibly different framing",
	)
	var pids := { }
	for id in host.sessions:
		pids[id] = host.sessions[id].term.get_shell_pid()
	await say("Restore the destination during the flight")
	for i in [0, 1, 2, 0, 2, 1, 0]:
		await visit(i)
	await say("Update one remembered view")
	await select_tab(1)
	await camera_at_rest()
	await customize(1.3, Vector2(90, 60))
	views[1] = reference()
	for i in [0, 2, 1, 0, 2, 1]:
		await visit(i)
	await say("Interrupt switches and reset one tab")
	for route in [[0, 1, 2], [1, 0, 1]]:
		await select_tab(route[0])
		await camera_at_rest()
		start_watching_camera()
		await point_at(tab_grip(route[1]))
		tap()
		await hold(0.08)
		check(not landed(), "Interrupt while the flight is moving")
		await point_at(tab_grip(route[2]), 0.05)
		tap()
		await camera_at_rest()
		matches(route[2])
		check_no_jump_cut(stop_watching_camera(), "Interrupted flight")
	for i in [0, 1, 2]:
		await visit(i)
	await select_tab(1)
	await camera_at_rest()
	host.workspace_view.show_main()
	await camera_at_rest()
	views[1] = reference()
	for i in [0, 1]:
		await visit(i)
		var body: Control = host.workspace_view.panes[host.pane_focus].body
		var point := visible_point(body)
		if check(point.is_finite(), "A terminal is visible and clickable in the saved view"):
			await click(point)
		await type("echo STILL_HERE $$ {enter}")
		await camera_at_rest()
		matches(i)
	for id in pids:
		check(
			pids[id] > 0 and host.sessions[id].term.get_shell_pid() == pids[id],
			"Original shell %d survives" % id,
		)
