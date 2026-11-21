extends "scatter_interruption_smoke.gd"
## Camera timing must not attach a world-space terminal to the viewer. Exercise
## Bistro's real route, captured source planes, and a shared smooth landing for the camera and scatter.

func sample_ink(layers: Array, other: Array, label: String) -> int:
	for layer in other: layer.hide()
	var pixels := await marked_pixels(label)
	for layer in other: layer.show()
	check(layers.any(func(layer): return layer.get_meta("glyph_layer", false)), label + ": has captured glyphs")
	print("SCATTER_VISIBLE_PIXELS ", label, " ", pixels)
	return pixels


func check_world_anchors(layers: Array, anchors: Dictionary, label: String) -> void:
	check(layers.any(func(layer): return layer.has_meta("panel")), label + ": includes pane backings")
	var anchored := true
	for layer in layers:
		var material: ShaderMaterial = layer._material()
		var plane: Array = [material.get_shader_parameter("plane_a_origin"), material.get_shader_parameter("plane_a_du"), material.get_shader_parameter("plane_a_dv")]
		if not anchors.has(layer): anchors[layer] = plane
		anchored = anchored and anchors[layer] == plane and layer.global_transform.is_equal_approx(Transform3D.IDENTITY)
		anchored = anchored and not material.get_shader_parameter("camera_relative_flight")
	check(anchored, label + ": source planes and pane backings stay anchored in the world as the camera moves")


func flight(index: int, seconds: float) -> void:
	var world: Node = host.world
	await switch_and_freeze(index)
	# A longer authored world flight must work without changing scatter constants.
	# Keep the production route; only change its time before advancing it.
	var motion = world.camera_motion
	var route := PackedVector3Array()
	for i in range(1, motion._points.size() - 1): route.append(motion._points[i])
	motion.retarget(motion._target, seconds, route)
	world._sync_tab_transition_deadline()
	var camera_deadline: float = world.tab_fx_t + seconds
	var deadline: float = camera_deadline
	var source_camera: Transform3D = world.cam.global_transform
	var anchors := {}
	check_world_anchors(world.tab_fx_out, anchors, "Departure start")
	check(is_equal_approx(world.tab_fx_dur, deadline), "Scatter shares the %.1f s camera landing deadline" % seconds)
	for at in [0.35, 0.65]:
		world._process(maxf(0.0, at - world.tab_fx_t))
		await sample_ink(world.tab_fx_out, world.tab_fx_in, "%s-departure-%s" % [seconds, at])
		check_world_anchors(world.tab_fx_out, anchors, "Departure at %.2f s" % at)
		check(not world.cam.global_transform.is_equal_approx(source_camera), "Camera leaves the anchored source terminal")
		check(not world.tab_fx_wall.visible, "The live destination stays hidden during scatter")
	if seconds > world.tab_transition_duration() + .1:
		world._process(0.65)
		check(not world.tab_fx_in.is_empty(), "Long flight already owns a populated destination capture")
		for layer in world.tab_fx_in:
			check(is_equal_approx(float(layer._material().get_shader_parameter("fly")), 1.0), "Prepared destination stays unrevealed before its arrival interval")
	# Layout/zoom can reset CameraMotion.elapsed via retarget_remaining. It must
	# neither restart arrival nor move its deadline.
	motion.retarget_remaining(motion._target)
	for remaining in [0.8, 0.4]:
		world._process(maxf(0.0, camera_deadline - remaining - world.tab_fx_t))
		check(is_equal_approx(world.tab_fx_dur, deadline), "Camera retarget preserves the scatter landing deadline")
		await sample_ink(world.tab_fx_in, world.tab_fx_out, "%s-arrival-%s" % [seconds, remaining])
		check_world_anchors(world.tab_fx_in, anchors, "Arrival with %.2f s remaining" % remaining)
		check(motion.moving, "Arrival runs while the camera is still moving")
		for layer in world.tab_fx_in:
			if not layer.get_meta("glyph_layer", false): continue
			var phase: float = layer._material().get_shader_parameter("fly")
			check(is_equal_approx(phase, remaining / world._tab_arrival_duration()), "Incoming glyph phase follows the remaining camera time")
	var previous_speed: float = motion.velocity.length()
	for remaining in [0.25, 0.1, 0.025]:
		world._process(maxf(0.0, deadline - remaining - world.tab_fx_t))
		check(motion.moving, "Camera keeps easing throughout the scatter landing interval")
		check(motion.velocity.length() < previous_speed, "Camera speed falls smoothly toward rest")
		previous_speed = motion.velocity.length()
		check(not world.tab_fx_wall.visible, "Live wall stays hidden until the last group settles")
		check(await sample_ink(world.tab_fx_in, world.tab_fx_out, "%s-landing-%s" % [seconds, remaining]) > 1000,
			"Incoming text remains visible during camera deceleration")
	world._process(maxf(0.0, deadline - world.tab_fx_t))
	check(not motion.moving, "Camera stops at the scatter landing deadline")
	check(is_equal_approx(world.tab_fx_t, deadline), "Arrival finishes at its settling deadline")
	for layer in world.tab_fx_in:
		check(is_zero_approx(layer._material().get_shader_parameter("fly")), "Every arriving layer reaches rest at the settling endpoint")
		check(layer.global_transform.is_equal_approx(Transform3D.IDENTITY), "Arrival returns to its real wall without a camera offset")
	world.set_process(true)
	await camera_at_rest()
	check(world.tab_fx_wall == null and world.tab_fx_in.is_empty(), "Live destination replaces its pieces after landing")


func play() -> void:
	use_config("res://../../../tests/llm-e2e/suites/godot/flat-world/per-tab-camera-view.conf")
	await open_tabs(1)
	if not await open_bistro(): return
	await open_tabs(2)
	var world: Node = host.world
	for index in [1, 0]:
		await select_tab(index)
		await camera_at_rest()
		var terminal: Node = host.sessions[int(host.get_tabs()[index].id)].term
		terminal.send_text("i=0; while [ $i -lt 20 ]; do printf '\\033[38;2;255;0;255mROW %02d CAMERA FLIGHT VISIBLE SCATTER\\033[0m\\n' $i; i=$((i+1)); done\r")
		var ready_deadline := Time.get_ticks_msec() + 5000
		while "ROW 19 CAMERA" not in str(terminal.get_text(false).get("text", "")) and Time.get_ticks_msec() < ready_deadline: await process_frame
		check("ROW 19 CAMERA" in str(terminal.get_text(false).get("text", "")), "Source shell finishes drawing its marked rows before capture")
		await camera_at_rest()
		check(await marked_pixels("source-%s" % index) > 1000, "Dense marked text is visible in Bistro tab %d" % index)
	check(host.world == world, "Both tabs retain the same Bistro world")
	await flight(1, world.tab_transition_duration())
	await flight(0, 3.2)
