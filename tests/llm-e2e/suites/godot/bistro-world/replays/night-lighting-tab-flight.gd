extends "../../../../replay/replay.gd"
var evidence := "res://.cache/bistro-e2e/current"
var flights: Array = []

func capture_view(index: int) -> void:
	if DisplayServer.get_name() == "headless": return
	var picture := await screen_image()
	picture.save_png(evidence.path_join("tab-%02d.png" % (index + 1)))
	host.world.scenery_vp.get_texture().get_image().save_png(evidence.path_join("scenery-%02d.png" % (index + 1)))

func flight_to(index: int, label: String, resize := false) -> void:
	await say(label)
	var frames: Array[Dictionary] = []
	var trace: Array = []
	var w = host.world
	var start: float = overlay.clock
	var began := Time.get_ticks_usec()
	await select_world_session(index)
	if resize:
		# Movie Maker fixes output pixels; change the logical window size so
		# the app experiences the same resize while the video keeps its format.
		if DisplayServer.get_name() != "headless":
			root.content_scale_size = Vector2i(950, 1000)
		else:
			root.size = Vector2i(950, 1000)
	var route: Array = []
	for p in w.camera_motion._points: route.append([p.x,p.y,p.z])
	var until: float = overlay.clock + 2.5
	while overlay.clock < until:
		await process_frame
		var p: Vector3 = w.proj_eye
		var f: Vector3 = w.proj_forward
		var v: Vector3 = w.camera_motion.velocity
		frames.append({"eye":p,"forward":f,"lens":w.proj_rect.z,"at":overlay.clock,"progress":w.camera_motion.elapsed/w.camera_motion.duration,"depth":(w.uv_origin-p).dot(f)})
		trace.append({"t":overlay.clock-start,"wall_ms":(Time.get_ticks_usec()-began)/1000.0,
			"position":[p.x,p.y,p.z],"forward":[f.x,f.y,f.z],"velocity":[v.x,v.y,v.z],
			"progress":w.camera_motion.elapsed/w.camera_motion.duration,"moving":w.camera_motion.moving,
			"lens":w.proj_rect.z,"target_rect":str(w.camera_motion._target.rect),"target_eye":str(w.camera_motion._target.transform.origin),"rest_eye":str(w._camera_fx_frame(w._camera_base_frame(w.surfaces[w.active].eye,w.surfaces[w.active].forward,w.surfaces[w.active].up,w.surfaces[w.active].half_x)).transform.origin),"navigation_center":str(host.workspace_view.navigation_center),"navigation_zoom":host.workspace_view.navigation_zoom,
			"sheet":str(w._sheet_size()),"pan":str(w.fx_cam_pan),"controller_pan":str(w.fx_camera.render_pan),"zoom":w.fx_cam_zoom,"cursor":str(w._camera_cursor_uv()),"uv_origin":str(w.uv_origin),"uv_du":str(w.uv_du),"uv_dv":str(w.uv_dv)})
	check(landed(),label+": landed")
	check_no_jump_cut(frames,label)
	if index == 2:
		var direction: Vector3 = (frames[-1].eye - frames[0].eye).normalized()
		var backwards := false
		for item in trace:
			var velocity := Vector3(item.velocity[0], item.velocity[1], item.velocity[2])
			if velocity.dot(direction) < -0.05: backwards = true
		check(not backwards, "Session 2 to 3 never doubles back along its approach")
	# Mid-route slowdowns around obstacles are valid; inspect the final approach.
	var approach: Array[Dictionary] = []
	var peak := 0.0
	var late := 0.0
	for item in trace:
		var v := Vector3(item.velocity[0],item.velocity[1],item.velocity[2]).length()
		peak = maxf(peak,v)
		if item.progress >= .95: late = maxf(late,v)
	for item in frames:
		if item.progress >= .75: approach.append(item)
	check_one_motion(approach,label+" (final quarter)")
	check(late < peak*.35,label+": slows before the final 5%% (%.2f of peak)" % (late/maxf(peak,.001)))
	flights.append({"label":label,"started_at":start,"route":route,"frames":trace})
	FileAccess.open(evidence.path_join("flights.json"),FileAccess.WRITE).store_string(JSON.stringify(flights,"  "))
	await capture_view(index)

func play() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--evidence="): evidence = arg.trim_prefix("--evidence=")
	DirAccess.make_dir_recursive_absolute(evidence)
	# A world layout override must preserve the world's backdrop opacity.
	var config_path := preload("res://config/UserConfig.gd").config_path()
	DirAccess.make_dir_recursive_absolute(config_path.get_base_dir())
	FileAccess.open(config_path, FileAccess.WRITE).store_string("[worlds.bistro.sheet]\npadding = 48\n")
	await say("Open the baked Bistro with nine terminal sessions")
	if not check(host.switch_world("bistro"),"Baked Bistro opens"): return
	check(host.world.authored_surface_count == 9, "Nine authored Bistro spaces")
	check((host.world.surfaces + host.world.spare_places).any(func(surface): return surface.id == "pharmacy-lane"), "Last space is pharmacy; duplicate tree removed")
	check(is_equal_approx(host.world.settings.terminal.background.alpha, .85), "Bistro terminal background is 85 percent opaque")
	_stay_awake()
	await camera_at_rest()
	await open_world_sessions(9)
	await capture_view(0)
	if "--first-flight" in OS.get_cmdline_user_args():
		await flight_to(1,"First flight")
		return
	for index in range(1,9):
		await flight_to(index,"Click session %d; inspect lighting and the landing" % (index+1))
	await flight_to(0,"Return from session 9 to session 1")
	await say("Interrupt a flight with another tab")
	await select_world_session(8)
	await hold(.35)
	await flight_to(6,"Redirect the moving camera to session 7")
	await say("Pinch session 7, visit session 8, and return")
	await camera_at_rest()
	await point_at(root.get_visible_rect().size * Vector2(.45,.45))
	var zoom_before: float = host.workspace_view.navigation_zoom
	await pinch(1.2)
	await hold(.5)
	var saved_zoom: float = host.workspace_view.navigation_zoom
	check(is_equal_approx(saved_zoom, zoom_before * 1.2), "Pinch sets the requested 1.2x framing (%.6f to %.6f)" % [zoom_before, saved_zoom])
	var view = host.workspace_view
	var reference := PackedVector2Array([view.window_point(Vector2.ZERO), view.window_point(view.canvas_size())])
	await flight_to(7,"Visit session 8 from a pinched view")
	await flight_to(6,"Restore session 7's pinched view")
	check(is_equal_approx(host.workspace_view.navigation_zoom, saved_zoom), "Session 7 restores its saved zoom")
	var restored := PackedVector2Array([view.window_point(Vector2.ZERO), view.window_point(view.canvas_size())])
	check(reference[0].distance_to(restored[0]) <= 2.0 and reference[1].distance_to(restored[1]) <= 2.0, "Saved view restores within two pixels")
	await flight_to(0, "Resize the window during a flight; land without a lens snap", true)
