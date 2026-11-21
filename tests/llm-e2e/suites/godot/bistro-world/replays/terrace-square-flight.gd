extends "../../../../replay/replay.gd"
## The terrace-to-square crossing repeats at sessions 15–16 after the nine places wrap.
var evidence := ""

func crossing(index: int, label: String) -> void:
	var world: Node = host.world
	var from: Vector3 = world.camera_motion.frame.transform.origin
	var start_frame: Dictionary = world.camera_motion.frame.duplicate(true)
	var frames: Array[Dictionary] = []
	var trace: Array = []
	# Capture from the first displayed frame, including the button press itself.
	var record := func():
		var eye: Vector3 = world.proj_eye
		frames.append({"eye": eye, "forward": world.proj_forward, "lens": world.proj_rect.z, "at": overlay.clock})
		trace.append({"elapsed": world.camera_motion.elapsed, "eye": [eye.x, eye.y, eye.z]})
	process_frame.connect(record)
	await select_world_session(index)
	var target_frame: Dictionary = world.camera_motion._target.duplicate()
	var route: PackedVector3Array = world.camera_motion._points.duplicate()
	var duration: float = world.camera_motion.duration
	await camera_at_rest()
	process_frame.disconnect(record)
	check(landed(), label + ": reaches the destination")
	check_no_jump_cut(frames, label)
	var forward: Vector3 = target_frame.transform.origin - from
	forward.y = 0.0
	forward = forward.normalized()
	var motion := CameraMotion.new()
	motion.reset(start_frame)
	motion.retarget(target_frame, duration, route)
	var previous := from
	var backwards := false
	var obstructed := false
	var max_accel := 0.0
	var previous_velocity := Vector3.ZERO
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	for i in range(1, 385):
		motion.advance(duration / 384.0)
		var point: Vector3 = motion.frame.transform.origin
		backwards = backwards or motion.velocity.dot(forward) < -.01
		max_accel = maxf(max_accel, motion.velocity.distance_to(previous_velocity) / (duration / 384.0))
		# A small tube also checks clearance around the camera's near plane.
		for offset in [Vector3.ZERO, Vector3.UP * .15, Vector3.DOWN * .15, Vector3.RIGHT * .15, Vector3.LEFT * .15, Vector3.FORWARD * .15, Vector3.BACK * .15]:
			obstructed = obstructed or not space.intersect_ray(PhysicsRayQueryParameters3D.create(previous + offset, point + offset)).is_empty()
		previous = point
		previous_velocity = motion.velocity
	check(not backwards, label + ": continuously advances across the square")
	check(not obstructed, label + ": camera and near plane clear the scenery")
	check(max_accel < 160.0, label + ": no sharp acceleration at the old vertical corner (%.2f m/s²)" % max_accel)
	FileAccess.open(evidence.path_join(label + ".json"), FileAccess.WRITE).store_string(JSON.stringify({"trace": trace, "max_acceleration": max_accel}))
	print("TERRACE_ROUTE ", label, " ", route)
	if DisplayServer.get_name() != "headless": (await screen_image()).save_png(evidence.path_join(label + ".png"))

func play() -> void:
	evidence = OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if evidence.is_empty(): evidence = "res://.cache/bistro-terrace-flight"
	DirAccess.make_dir_recursive_absolute(evidence)
	check(host.switch_world("bistro"), "Bistro opens")
	_stay_awake()
	await camera_at_rest()
	host.instant_workspace_switch = true
	await open_world_sessions(16)
	host.instant_workspace_switch = false
	await select_world_session(14)
	await camera_at_rest()
	var world: Node = host.world
	check(world._nav_node_for(world.surfaces[world.active]) == world.nav_node_for_surface["cafe-terrace"], "Session 15 wraps to the cafe terrace")
	for mesh in world.get_node("Scenery").find_children("*", "MeshInstance3D", true, false):
		if mesh.is_visible_in_tree() and mesh.mesh != null: mesh.create_trimesh_collision()
	await physics_frame
	await physics_frame
	await crossing(15, "15-to-16")
	await crossing(14, "16-to-15")
