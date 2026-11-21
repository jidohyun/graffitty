extends SceneTree
## Follow the displayed Flat 2D camera through approach, filetree reveal and
## release; checking only internal controllers missed their opposing motion.
## Run with tests/godot/test_session_effects.py --case adaptive on a private server.
var failures: Array[String] = []

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)

func sample(frame: Dictionary) -> Vector3:
	var eye: Vector3 = frame.transform.origin
	return Vector3(eye.x, eye.y, 1.0 / (frame.rect.z * eye.z))

func run() -> void:
	if OS.get_environment("GRAFFITTY_EFFECT_FIXTURE") != "1":
		printerr("Requires an isolated session-effects fixture")
		quit(2)
		return
	root.size = Vector2i(1280, 800)
	var client := preload("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session", "--plugin=flat-2d"])
	root.add_child(client)
	var deadline := Time.get_ticks_msec() + 15000
	while (client.host == null or client.host.active_terminal() == null) and Time.get_ticks_msec() < deadline:
		await process_frame
	if client.host == null or client.host.active_terminal() == null:
		check(false, "Fixture attaches")
		quit(1)
		return
	var host: Node = client.host
	await create_timer(.3).timeout
	var world: Node = host.world
	world.set_process(false)
	world.fx_enabled = true
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "adaptive")
	var sheet: Vector2 = world._sheet_size()
	var camera: Node = world.fx_camera
	camera.reset(sheet)
	if world.navigation_camera == null:
		world.navigation_camera = load("res://scenes/TerminalCameraController.gd").new()
		world.add_child(world.navigation_camera)
	var navigation: Node = world.navigation_camera
	navigation.reset(sheet)
	world.navigation_camera_active = true
	for controller in [camera, navigation]:
		controller.adaptive_enabled = true
		controller.adaptive_zoom_in_seconds = 10.0
		controller.adaptive_zoom_out_seconds = 1.5
	host.workspace_view.navigation_zoom = 2.0
	host.workspace_view.navigation_center = sheet * .5
	var initial: Dictionary = world._canvas_camera_target()
	var previous := sample(initial)
	for phase in ["focus", "filetree", "idle"]:
		var typing: bool = phase != "idle"
		var goal := Vector3(sheet.x * .4, sheet.y * .4, 2.5) if phase == "focus" else Vector3(sheet.x * .5, sheet.y * .5, 1.0)
		world._adaptive_content_rect = Rect2(sheet * .25, sheet * .25) if phase == "focus" else Rect2(Vector2.ZERO, sheet)
		for controller in [camera, navigation]: controller.adaptive_target = goal
		var samples: Array[Vector3] = [previous]
		var queries_stable := true
		for i in 1800:
			world.fx_typing = 1.0 if typing else exp(-float(i) / 30.0)
			for controller in [camera, navigation]:
				controller.advance(1.0 / 60, sheet * .4, sheet, Vector2.ONE, 1, 0, 0, 0, typing, .5)
			world.fx_cam_zoom = camera.zoom
			var frame: Dictionary = world._canvas_camera_target()
			world._display_canvas_camera_frame(frame)
			previous = sample(frame)
			samples.append(previous)
			queries_stable = queries_stable and sample(world._canvas_camera_target()).is_equal_approx(previous)
		check(queries_stable, "Repeated projection queries cannot advance time")
		var reversals := 0
		for axis in 3:
			var direction := signf(samples.back()[axis] - samples.front()[axis])
			for i in range(1, samples.size()):
				if (samples[i][axis] - samples[i - 1][axis]) * direction < -.0001:
					reversals += 1
		check(reversals == 0, "%s: displayed pan/zoom converge without reversals (%d)" % [phase, reversals])
		check(samples[-1].distance_to(samples[-30]) < .001, "%s: displayed camera settles" % phase)
		check(samples[1].distance_to(samples[0]) < samples[-1].distance_to(samples[0]) * .15 + .001, "%s: no first-frame snap" % phase)
	check(previous.distance_to(sample(initial)) < .001, "Idle returns to the saved navigation frame")
	for path in ["flat-2d", "flat-3d"]:
		if path != "flat-2d":
			check(host.switch_world(path), path + " loads for manual takeover")
			await create_timer(.3).timeout
		check_manual_takeover(host, path)
		await check_prefix_settle(client, host, path)
	client.queue_free()
	await process_frame
	await process_frame
	print("ADAPTIVE_PROJECTION_PASS" if failures.is_empty() else "ADAPTIVE_PROJECTION_FAIL")
	quit(0 if failures.is_empty() else 1)


func displayed_points(world: Node) -> PackedVector2Array:
	var points := PackedVector2Array()
	for fraction in [Vector2(.2, .2), Vector2(.5, .5), Vector2(.8, .7)]:
		points.append(world.sheet_window_fraction(fraction * world._sheet_size()))
	return points


func same_points(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for i in a.size():
		if a[i].distance_to(b[i]) > .00001: return false
	return true


func advance_camera(world: Node, typing: bool) -> void:
	var sheet: Vector2 = world._sheet_size()
	for controller in [world.fx_camera, world.navigation_camera]:
		controller.advance(1.0 / 60, sheet * .4, sheet, Vector2.ONE, 1, 0, 0, 0, typing, .5)
	world.fx_cam_zoom = world.fx_camera.zoom
	world.fx_cam_pan = (world.fx_camera.render_pan / sheet - Vector2.ONE * .5) * 2.0
	world._apply_camera_fx()


func check_manual_takeover(host: Node, path: String) -> void:
	host.effect_control.pulse()
	var world: Node = host.world
	var view: Control = host.workspace_view
	world.set_process(false)
	world.fx_enabled = true
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "adaptive")
	var sheet: Vector2 = world._sheet_size()
	if world.navigation_camera == null:
		world.navigation_camera = load("res://scenes/TerminalCameraController.gd").new()
		world.add_child(world.navigation_camera)
	for overview in [false, true]:
		for action in ["pan", "zoom", "pinch"]:
			view._cancel_main_magnet()
			view.overview = overview
			view.navigation_center = view.main_frame().center
			view.navigation_zoom = view.main_frame().zoom * (0.7 if overview else 1.0)
			world.navigation_camera_active = view.uses_navigation_camera()
			for controller in [world.fx_camera, world.navigation_camera]:
				controller.reset(sheet)
				controller.adaptive_enabled = true
				controller.adaptive_target = Vector3(sheet.x * .4, sheet.y * .4, 2.5)
			world._adaptive_content_rect = Rect2(sheet * .25, sheet * .25)
			for i in 30: advance_camera(world, true)
			var before := displayed_points(world)
			check(world.interrupt_adaptive_camera(), path + " can interrupt adaptive framing")
			world._apply_camera_fx()
			check(same_points(before, displayed_points(world)), path + " interruption does not snap")
			# Resume so the public navigation method must interrupt on its own.
			world.fx_camera.resume_projection()
			match action:
				"pan": view.pan_workspace(Vector2(100, 60) * (0.03 if OS.get_name() == "macOS" else 1.0), view.size * .5)
				"zoom": view.zoom_workspace(.7, view.size * .5)
				"pinch": view.pinch_workspace(view.size * .5, view.size * .5 + Vector2(60, 40), .7)
			var manual := displayed_points(world)
			check(not same_points(before, manual), path + " " + action + " responds immediately")
			var stable := true
			for i in 300:
				# Both new content and the idle return leave the manual view alone.
				for controller in [world.fx_camera, world.navigation_camera]:
					controller.adaptive_target = Vector3(sheet.x * .6, sheet.y * .5, 1.2)
				advance_camera(world, i < 150)
				stable = stable and same_points(manual, displayed_points(world))
			check(stable, "%s %s stops adaptive motion from overview=%s, including idle return" % [path, action, overview])
			if path == "flat-2d": world._typed_2d(Vector2(.4, .4))
			else: world._on_effect_typed(Vector2(.4, .4))
			for i in 30: advance_camera(world, true)
			check(not same_points(manual, displayed_points(world)), path + " fresh typing resumes adaptive framing")


func key(code: Key, unicode: int, control := false) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.unicode = unicode if down else 0
		event.ctrl_pressed = control
		event.pressed = down
		Input.parse_input_event(event)


func settle_points(world: Node) -> PackedVector2Array:
	var result := displayed_points(world)
	for i in result.size(): result[i] *= Vector2(root.size)
	return result


func points_distance(a: PackedVector2Array, b: PackedVector2Array) -> float:
	var largest := 0.0
	for i in a.size(): largest = maxf(largest, a[i].distance_to(b[i]))
	return largest


func check_prefix_settle(client: Node, host: Node, path: String) -> void:
	var world: Node = host.world
	var view: Control = host.workspace_view
	world.set_process(true)
	view._cancel_main_magnet()
	view.overview = false
	view.navigation_zoom = view.main_frame().zoom
	view.navigation_center = view.main_frame().center
	world.fx_enabled = true
	world.fx_cfg.set_option("behavior", "idle_after", 30.0)
	world.fx_idle_after = 30.0
	world.fx_cfg.set_option("state.typing", "camera.zoom", 2.5)
	world.fx_cfg.set_option("state.typing", "camera.tilt_limit_deg", 0.0)
	world.fx_cfg.set_option("scene.camera", "adaptive_group", {"main_view": false})
	world.fx_cfg.set_option("scene.camera", "adaptive_zoom_in_seconds", 1.0)
	world.fx_cfg.set_option("scene.camera", "adaptive_zoom_out_seconds", 1.5)
	var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	for mode in ["typing", "adaptive"]:
		world.fx_cfg.set_option("scene.camera", "zoom_mode", mode)
		host.effect_control.pulse()
		client.connection.send_input(host.active_session_id, "\u0015PS1='$ '; printf '\\033[2J\\033[HSETTLE_MARKER\\n'\r".to_utf8_buffer())
		await create_timer(.4).timeout
		world.term.grab_focus()
		key(KEY_A, 97)
		await create_timer(.2 if mode == "adaptive" else 2.2).timeout
		var before := settle_points(world)
		if not evidence.is_empty():
			root.get_texture().get_image().save_png(evidence.path_join(path + "-" + mode + "-before.png"))
		key(KEY_A, 1, true)
		await process_frame
		check(host.prefix_commands.active, path + " " + mode + ": real Ctrl+A arms prefix")
		world._apply_camera_fx()
		before = settle_points(world)
		world.set_process(false)
		key(KEY_R, 114)
		await process_frame
		check(not host.effect_control.allows("camera.zoom"), path + " " + mode + ": prefix action reaches the effect gate before advancing")
		world._apply_camera_fx()
		check(points_distance(before, settle_points(world)) < .5, path + " " + mode + ": settling does not replace the displayed frame synchronously")
		world.set_process(true)
		var samples: Array[PackedVector2Array] = [before]
		var trace: Array = []
		var frame_index := -1
		var deadline := Time.get_ticks_msec() + 3500
		while Time.get_ticks_msec() < deadline:
			frame_index += 1
			await RenderingServer.frame_post_draw
			var points := settle_points(world)
			samples.append(points)
			trace.append({"frame": frame_index, "points": Array(points).map(func(p): return [p.x, p.y])})
			if not evidence.is_empty() and frame_index in [0, 1, 2, 8, 30, 119]:
				root.get_texture().get_image().save_png(evidence.path_join("%s-%s-settle-%03d.png" % [path, mode, frame_index]))
		check(not host.prefix_commands.active and not host.effect_control.allows("camera.zoom"), path + " " + mode + ": real prefix,R settles effects")
		var travel := points_distance(samples.front(), samples.back())
		var largest := 0.0
		for i in range(1, samples.size()): largest = maxf(largest, points_distance(samples[i - 1], samples[i]))
		check(travel > 5.0, path + " " + mode + ": settling visibly returns from a zoomed view")
		# Production caps a render step at 50 ms: the 1.5 s exponential
		# return can cover 20.63% of its remaining distance in that step.
		check(largest < travel * .25 + .5, "%s %s: no rendered jump cut (largest %.2f, travel %.2f px)" % [path, mode, largest, travel])
		check(points_distance(samples[-1], samples[-10]) < 1.0, path + " " + mode + ": return converges")
		if not evidence.is_empty():
			FileAccess.open(evidence.path_join(path + "-" + mode + "-settle.json"), FileAccess.WRITE).store_string(JSON.stringify(trace))
	world.set_process(false)
