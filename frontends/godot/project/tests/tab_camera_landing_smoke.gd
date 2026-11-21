extends "scatter_interruption_smoke.gd"
## Both built-in renderers spend the scatter tail decelerating the camera.
func play() -> void:
	use_config("res://../../../tests/llm-e2e/suites/godot/flat-world/per-tab-camera-view.conf")
	await labelled_tabs(["SOURCE", "DESTINATION"])
	for path in ["", "flat-2d"]:
		# Renderer choice belongs to each tab; exercise the same renderer at
		# both ends instead of silently switching back to Flat 3D on arrival.
		for index in 2:
			await select_tab(index)
			check(host.switch_world(path), "Open built-in world " + path)
			host.session_backend.commit_workspace(host)
			await owner_at_rest()
			await camera_at_rest()
		await select_tab(0)
		await camera_at_rest()
		# Give the two tabs visibly different framing, including in Flat 2D.
		var view: Control = host.workspace_view
		view.overview = true
		view.navigation_center = view.content_rect().get_center() + Vector2(200, 80)
		view.navigation_zoom = 0.6
		view._apply_navigation()
		await camera_at_rest()
		var world: Node = host.world
		world.set_process(false)
		var source_zoom: Vector2 = world.camera_2d.zoom if path == "flat-2d" else Vector2.ONE
		var source_center: Vector2 = world.camera_2d.position if path == "flat-2d" else Vector2.ZERO
		await switch_and_freeze(1)
		check(host.world == world, "Tab change retains the requested renderer")
		if path == "flat-2d":
			var destination: Dictionary = world._canvas_camera_target()
			var eye: Vector3 = destination.transform.origin
			var target_zoom := Vector2.ONE / (Vector2(destination.rect.z, destination.rect.w) * eye.z)
			world._process(world.tab_transition_duration() * .25)
			# At one quarter of the shared quintic, depth has covered 10.3515625%.
			# Magnification interpolation looks different even with the same clock.
			var expected_zoom := Vector2.ONE / (Vector2.ONE / source_zoom).lerp(Vector2.ONE / target_zoom, .103515625)
			check(world.camera_2d.zoom.distance_to(expected_zoom) < .0001, "2D zoom follows the 3D dolly curve")
			check(world.camera_2d.position.distance_to(source_center.lerp(Vector2(eye.x, eye.y), .103515625)) < .01,
				"2D pan and depth share one speed ramp")
		world._process(maxf(0.0, world.FLY_TIME - world.tab_fx_t))
		check(world.fly_dur > 0.0, path + ": camera is still travelling at 1.6 seconds")
		check(is_equal_approx(world.tab_fx_dur, world.tab_transition_duration()), path + ": scatter and camera share a deadline")
		var displayed: Variant = world.camera_2d.position if path == "flat-2d" else world.cam.global_transform
		world._process(0.25)
		var later: Variant = world.camera_2d.position if path == "flat-2d" else world.cam.global_transform
		check(displayed != later and world.fly_dur > 0.0, path + ": camera continues moving through the landing interval")
		world._process(0.25)
		check(is_zero_approx(world.fly_dur), path + ": camera finishes with scatter at 2.1 seconds")
		world.set_process(true)
		await camera_at_rest()
		if path == "flat-2d": await interrupted_2d_flight(world)

func interrupted_2d_flight(world: Node) -> void:
	world.set_process(false)
	await switch_and_freeze(0)
	world._process(.7)
	var position: Vector2 = world.camera_2d.position
	var zoom: Vector2 = world.camera_2d.zoom
	var velocity: Vector3 = world.camera_motion.velocity
	await switch_and_freeze(1)
	check(world.camera_2d.position.distance_to(position) < .001 and world.camera_2d.zoom.distance_to(zoom) < .00001,
		"Interrupted 2D flight keeps the displayed pan and zoom")
	world._process(.0001)
	check(world.camera_motion.velocity.distance_to(velocity) < .01,
		"Interrupted 2D flight preserves incoming speed instead of restarting at rest")
	# A destination that settles late must not be substituted into a partially
	# completed lerp: retain the displayed frame, derivative and landing time.
	world._process(.4)
	position = world.camera_2d.position
	zoom = world.camera_2d.zoom
	velocity = world.camera_motion.velocity
	var remaining: float = world.camera_motion.duration - world.camera_motion.elapsed
	host.workspace_view.overview = true
	host.workspace_view.navigation_center += Vector2(30, -15)
	host.workspace_view.navigation_zoom *= .8
	world._process(.0001)
	check(world.camera_2d.position.distance_to(position) < .1 and world.camera_2d.zoom.distance_to(zoom) < .0001,
		"Late destination changes do not jump the 2D camera")
	check(world.camera_motion.velocity.distance_to(velocity) < .01,
		"Late destination changes preserve 2D camera speed (%s -> %s)" % [velocity, world.camera_motion.velocity])
	check(absf(world.camera_motion.duration - world.camera_motion.elapsed - remaining + .0001) < .00001,
		"Late destination changes preserve the original landing time")
	world._process(remaining)
	check(not world.camera_motion.moving and is_zero_approx(world.fly_dur) and world.tab_fx_t < 0.0,
		"Interrupted 2D flight and scatter finish together")
	position = world.camera_2d.position
	zoom = world.camera_2d.zoom
	world._process(.1)
	check(world.camera_2d.position.distance_to(position) < .001 and world.camera_2d.zoom.distance_to(zoom) < .00001,
		"2D landing has no second pan or zoom")
	world.set_process(true)
