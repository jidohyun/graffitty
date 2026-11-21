extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/bistro-world/pinch-zoom-tab-flight.md


## Where the page is drawn: its centre in window pixels, and its width as a
## share of the frame's.
func page_on_screen() -> Vector3:
	var view: Control = host.workspace_view
	var canvas: Vector2 = view.canvas_size()
	var centre: Vector2 = view.window_point(canvas * 0.5)
	var width: float = view.view_point(Vector2(canvas.x, canvas.y * 0.5)).x - view \
			.view_point(Vector2(0, canvas.y * 0.5)) \
			.x
	return Vector3(centre.x, centre.y, width / view.size.x)


## Follows one tab flight: it lands in one motion without a cut, at the
## destination tab's saved zoom.
func watch_flight(label: String, zoom: float) -> void:
	var deadline_errors: Array[float] = []
	var observe := func():
		if host.world.tab_fx_t >= 0.0 and host.world.camera_motion.moving:
			var camera_remaining: float = host.world.camera_motion.duration - host.world.camera_motion.elapsed
			deadline_errors.append(absf((host.world.tab_fx_dur - host.world.tab_fx_t) - camera_remaining))
	process_frame.connect(observe)
	var frames := await watch_camera(4.5)
	process_frame.disconnect(observe)
	check(not deadline_errors.is_empty() and deadline_errors.max() < 0.05, "%s: camera and scatter share a landing deadline" % label)
	check(landed(), "%s: the camera lands" % label)
	check(host.world.tab_fx_t < 0.0, "%s: scatter has settled with the camera" % label)
	check_no_jump_cut(frames, label)
	check_one_motion(frames, label)
	var settled: float = page_on_screen().z
	check(
		absf(settled / zoom - 1.0) < 0.05,
		"%s: lands at its saved zoom (%.2f, expected %.2f)" % [label, settled, zoom],
	)


func play() -> void:
	await open_tabs(1)
	await select_tab(0)
	if not await open_bistro():
		return
	var bistro: String = host.current_plugin
	var bistro_world: Node = host.world
	await open_tabs(2)
	await camera_at_rest()
	check(host.current_plugin == bistro and host.world == bistro_world, "New tab inherits Bistro without reloading or switching to Flat")
	await select_tab(1)
	await camera_at_rest()
	var second_rest: float = page_on_screen().z
	await select_tab(0)
	await camera_at_rest()
	var rest: float = page_on_screen().z

	await say("Over the terminal, pinch outward once, gently")
	await point_at(
		host.workspace_view.window_point(host.workspace_view.canvas_size() * Vector2(0.35, 0.3))
	)
	await pinch(1.25)
	await hold(1.2)
	var zoom: float = page_on_screen().z
	check(
		absf(zoom / rest - 1.25) < 0.03,
		"The pinch zooms by what the fingers did, once (%.2fx for a 1.25x pinch)" % (zoom / rest),
	)

	await say("Click the second tab and watch the flight")
	var first_wall: int = host.world.active
	await click(on(tab_button(1)))
	check(
		host.world.active != first_wall and host.get_tabs()[1].active,
		"The click selects the second tab and leaves the first wall",
	)
	await watch_flight("To the second wall", second_rest)

	await say("Click the first tab and watch the flight back")
	await click(on(tab_button(0)))
	check(
		host.world.active == first_wall and host.get_tabs()[0].active,
		"The click selects the first tab again",
	)
	await watch_flight("Back to the first wall", zoom)
