extends "pinch-zoom-tab-flight.gd"
## Shared Bistro integration coverage, including rendered interrupted arrival.
var capture_root := ""

func snapshot(label: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(capture_root.path_join(label + ".png"))

func image_difference(first: Image, second: Image) -> float:
	var difference := 0.0
	var samples := 0
	for y in range(80, first.get_height(), 4):
		for x in range(0, first.get_width(), 4):
			var a := first.get_pixel(x, y)
			var b := second.get_pixel(x, y)
			difference += absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
			samples += 3
	return difference / maxf(1, samples)

func record_flight(label: String, target: int, interrupt_target := -1) -> void:
	var world: Node = host.world
	var directory := capture_root.path_join(label)
	DirAccess.make_dir_recursive_absolute(directory)
	world.set_process(false)
	overlay.visible = false
	await select_world_session(target)
	await owner_at_rest()
	var trace: Array = []
	var interrupted := false
	var assembled: Image
	var saw_arrival := false
	for frame in 300:
		if frame > 0: world._process(1.0 / 60.0)
		await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.save_png(directory.path_join("%03d.png" % frame))
		var eye: Vector3 = world.cam.global_position
		trace.append({"frame": frame, "eye": [eye.x, eye.y, eye.z],
			"transition": world.tab_fx_t, "duration": world.tab_fx_dur,
			"incoming_layers": world.tab_fx_in.size(), "active_surface": world.active})
		saw_arrival = saw_arrival or not world.tab_fx_in.is_empty()
		if interrupt_target >= 0 and not interrupted and not world.tab_fx_in.is_empty() and world.tab_fx_t > world.tab_fx_dur - 0.4:
			var before: Transform3D = world.cam.global_transform
			await select_world_session(interrupt_target)
			await owner_at_rest()
			check(world.cam.global_transform.is_equal_approx(before), "Interrupted flight begins at the displayed camera pose")
			await process_frame
			await RenderingServer.frame_post_draw
			var restart := root.get_texture().get_image()
			restart.save_png(directory.path_join("interrupted.png"))
			var delta := image_difference(image, restart)
			check(delta < 0.02, "Interrupted flight preserves the displayed opacity and pixels (%.4f)" % delta)
			interrupted = true
			assembled = null
		if world.tab_fx_t >= world.tab_fx_dur: assembled = image
		if frame > 2 and world.tab_fx_t < 0.0 and world.tab_fx_in.is_empty():
			check(assembled != null, label + ": fully assembled arrival is rendered before live handoff")
			if assembled != null:
				var delta := image_difference(assembled, image)
				check(delta < 0.02, label + ": live handoff has no pixel jump (%.4f)" % delta)
			break
	check(saw_arrival, label + ": real incoming terminal layers were rendered")
	check(world.tab_fx_t < 0.0 and not world.camera_motion.moving, label + ": camera and pane arrival finish")
	if interrupt_target >= 0: check(interrupted, "The flight was interrupted during incoming assembly")
	FileAccess.open(directory.path_join("trace.json"), FileAccess.WRITE).store_string(JSON.stringify(trace, "  "))
	world.set_process(true)
	overlay.visible = true
	await camera_at_rest()

func play() -> void:
	capture_root = evidence_path("bistro-all-destinations-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(capture_root)
	print("BISTRO_INTEGRATION_EVIDENCE ", capture_root)
	await open_tabs(1)
	if not await open_bistro(): return
	await open_world_sessions(14)
	check(world_sessions.size() == 14, "Fourteen live Bistro sessions exist")
	var identities := {}
	var poses: Array = []
	var widths: Array[float] = []
	var authored_count: int = host.world.authored_surface_count
	check(authored_count > 0, "Bistro exposes its authored destination count")
	for index in 14:
		await select_world_session(index)
		await owner_at_rest()
		await camera_at_rest()
		var terminal: Node = host.active_terminal()
		identities[world_sessions[index]] = terminal.get_shell_pid()
		var marker := "BISTRO_DESTINATION_%02d" % (index + 1)
		var command := "Write-Output ('BISTRO_' + 'DESTINATION_%02d')\r" % (index + 1) if OS.get_name() == "Windows" else "printf 'BISTRO_%%s\\n' 'DESTINATION_%02d'\n" % (index + 1)
		terminal.send_text(command)
		var deadline := Time.get_ticks_msec() + 10000
		while marker not in str(terminal.get_text(false).text) and Time.get_ticks_msec() < deadline: await process_frame
		check(marker in str(terminal.get_text(false).text), "Destination %d has a usable live terminal" % (index + 1))
		await camera_at_rest()
		var pose: Transform3D = host.world.cam.global_transform
		if index < authored_count:
			for previous in poses: check(not pose.is_equal_approx(previous), "Destination %d has a distinct authored camera pose" % (index + 1))
		else:
			check(pose.is_equal_approx(poses[index % authored_count]), "Session %d wraps to authored destination %d" % [index + 1, index % authored_count + 1])
		poses.append(pose)
		widths.append(page_on_screen().z)
		await snapshot("destination-%02d" % (index + 1))
	await select_world_session(0)
	await owner_at_rest()
	await camera_at_rest()
	var view: Control = host.workspace_view
	var anchor: Vector2 = view.canvas_size() * Vector2(0.35, 0.3)
	var before: Vector2 = view.window_point(anchor)
	await point_at(before)
	await pinch(1.25)
	await hold(1.2)
	check(view.window_point(anchor).distance_to(before) < 2.0, "Pinch preserves the off-center terminal anchor within two pixels")
	var pinched_width := page_on_screen().z
	check(absf(pinched_width / widths[0] - 1.25) < 0.03, "The pinch applies magnification exactly once")
	await snapshot("pinched-anchor")
	await record_flight("pinched-1-to-2", 1)
	check(absf(page_on_screen().z / widths[1] - 1.0) < 0.05, "Session 2 retains its own original view")
	await record_flight("return-to-pinched-1", 0)
	check(absf(page_on_screen().z / pinched_width - 1.0) < 0.05, "Returning to session 1 restores its pinched view")
	await select_world_session(13)
	await owner_at_rest()
	await camera_at_rest()
	await record_flight("14-to-13", 12)
	await record_flight("13-to-14-interrupted", 13, 12)
	var final_terminal: Node = host.active_terminal()
	final_terminal.send_text("Write-Output ('BISTRO_' + 'AFTER_INTERRUPT')\r" if OS.get_name() == "Windows" else "printf 'BISTRO_%s\\n' AFTER_INTERRUPT\n")
	var deadline := Time.get_ticks_msec() + 10000
	while "BISTRO_AFTER_INTERRUPT" not in str(final_terminal.get_text(false).text) and Time.get_ticks_msec() < deadline: await process_frame
	check("BISTRO_AFTER_INTERRUPT" in str(final_terminal.get_text(false).text), "Interrupted arrival leaves the live shell usable")
	for index in world_sessions.size():
		await select_world_session(index)
		await camera_at_rest()
		check(identities[world_sessions[index]] == host.active_terminal().get_shell_pid(), "Bistro flights preserve shell %d" % index)
	await snapshot("after-interruption")
	FileAccess.open(capture_root.path_join("identities.json"), FileAccess.WRITE).store_string(JSON.stringify(identities, "  "))
