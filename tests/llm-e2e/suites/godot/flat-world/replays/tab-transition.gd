extends "../../../../replay/replay.gd"
const DepthMotion := preload("res://scenes/TabDepthMotion.gd")

func framing() -> PackedVector2Array:
	var view: Control = host.workspace_view
	return PackedVector2Array([view.view_point(Vector2.ZERO), view.view_point(view.canvas_size())])

func error(a: PackedVector2Array, b: PackedVector2Array) -> float:
	return maxf(a[0].distance_to(b[0]), a[1].distance_to(b[1]))

func capture_stage(label: String) -> void:
	var folder := OS.get_environment("GRAFFITTY_TRANSITION_ARTIFACTS")
	if folder.is_empty() or DisplayServer.get_name() == "headless": return
	DirAccess.make_dir_recursive_absolute(folder)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder.path_join(label + ".png"))

## Push/Pull moves whole panes on one dolly clock. Every layer from the
## same side shares the same phase.
##
## The departing side enlarges, or shrinks when the dolly reverses.
## The arriving side completes the reciprocal zoom. Pane layers stay whole.
func check_whole_panes(world: Node, flat_2d: bool, direction: float) -> void:
	var phase: float = DepthMotion.phase(world.tab_fx_t / world.tab_fx_dur)
	if flat_2d:
		var outgoing: Node = world._transition_out
		var incoming: Node = world._transition_in
		if not check(is_instance_valid(outgoing) and is_instance_valid(incoming), "2D keeps both workspaces during the crossing"): return
		check(outgoing.glyphs.is_empty() and incoming.glyphs.is_empty(), "2D depth uses whole panes without letters or dust")
		check(not world.sheet_2d.visible, "Live destination stays hidden until its panes finish arriving")
		check(outgoing.pane_groups.any(func(group): return group.get_meta("border_layer", "") == "selection"), "Active pane outline belongs to the intact 2D pane")
		for layer in [outgoing, incoming]:
			var zoom := pow(DepthMotion.ZOOM_RATIO, direction * (-1.0 if layer.arriving else 1.0) * (1.0 - phase if layer.arriving else phase))
			for group in layer.pane_groups + layer.ui_groups:
				var original: Vector2 = group.get_meta("depth_scale")
				check(absf(group.scale.x / original.x - zoom) < 0.001 and is_equal_approx(group.scale.x / original.x, group.scale.y / original.y),
					"Every pane, border and decoration shares one undistorted dolly zoom")
			for panel in layer.panels:
				if panel.material is ShaderMaterial:
					check(absf(panel.material.get_shader_parameter("depth_alpha") - (phase if layer.arriving else 1.0 - phase)) < 0.001, "Panes crossfade on the shared clock")
		check(outgoing.panels.any(func(panel): return panel.material is ShaderMaterial and panel.material.get_shader_parameter("depth_blur") > 0.0), "Moving panes defocus")
	else:
		if not check(not world.tab_fx_out.is_empty() and not world.tab_fx_in.is_empty(), "3D keeps both workspaces during the crossing"): return
		check(world.tab_fx_out.any(func(layer): return layer.get_meta("border_layer", "") == "selection" and layer.has_meta("panel")), "Active pane outline belongs to the intact 3D pane")
		for layer in world.tab_fx_out:
			check(not layer.get_meta("glyph_layer", false), "3D departure has no letter or dust instances")
		for layer in world.tab_fx_out + world.tab_fx_in:
			var material: ShaderMaterial = layer._material()
			var arriving: bool = material.get_shader_parameter("arrival_flight") == true
			check(layer.get_meta("depth_mode", false), "3D layer uses axial depth motion")
			check(absf(material.get_shader_parameter("fly") - (1.0 - phase if arriving else phase)) < 0.001, "Every 3D pane, border and decoration shares the same clock")
			check(material.get_shader_parameter("depth_direction") == direction and material.get_shader_parameter("depth_zoom_ratio") == DepthMotion.ZOOM_RATIO,
				"3D panes use the reciprocal dolly zoom in the switch direction")


## Clicks a tab and stops the world on the first prepared frame of the
## transition, so later steps advance it by exact amounts of time.
func begin_frozen_switch(index: int) -> Node:
	await point_at(tab_grip(index))
	tap()
	var world: Node = host.world
	var deadline := Time.get_ticks_msec() + 10000
	# Preparation never consumes the transition's time: its clock starts on the
	# first frame after the destination's pixels are ready.
	while (world.tab_fx_preparing or world.tab_fx_t <= 0.0) and Time.get_ticks_msec() < deadline: await process_frame
	world.set_process(false)
	check(not world.tab_fx_preparing and world.tab_fx_t > 0.0 and world.tab_fx_t < 0.1, "Destination pixels are prepared before the transition is measured")
	return world

func play() -> void:
	var renderer: String = host.current_plugin
	use_config(get_script().resource_path.get_base_dir().path_join("../per-tab-camera-view.conf"))
	await labelled_tabs(["ALPHA", "BETA"])
	# The owner stores worlds per tab. A CLI world on the first tab alone
	# otherwise lets this purported 2D replay silently switch back to 3D.
	if not renderer.is_empty():
		for index in range(2):
			await select_tab(index)
			check(host.switch_world(renderer), "Set the requested renderer on both tabs")
			host.session_backend.commit_workspace(host)
			await owner_at_rest()
		await select_tab(0)
		use_config(get_script().resource_path.get_base_dir().path_join("../per-tab-camera-view.conf"))
	if not host.pane_status_visible: host.toggle_pane_status()
	await type("echo OUTGOING text stays separate from its pane{enter}")
	await select_tab(1)
	await camera_at_rest()
	await type("echo DESTINATION builds while the camera moves{enter}")
	await point_at(content())
	await pan_pixels(Vector2(130, -65))
	await point_at(content())
	await pinch(0.65)
	await camera_at_rest()
	var destination := framing()
	await select_tab(0)
	await camera_at_rest()
	# Both borders are visible only in overview. Exercise their real live
	# visibility before verifying that their captured copies stay intact.
	await point_at(content())
	await pinch(0.82)
	await camera_at_rest()
	var original := framing()
	if not check(host.get_tabs().size() == 2, "Both tabs remain in the same window"): return
	var pids := {}
	for id in host.sessions: pids[id] = host.sessions[id].term.get_shell_pid()
	await say("Whole panes push away as the camera starts moving")
	var world: Node = await begin_frozen_switch(1)
	var flat_2d := world.get("camera_2d") != null
	check(flat_2d == (renderer == "flat-2d"), "Transition exercises the requested renderer")
	check(world.tab_fx_direction == 1.0, "Switching to a later tab pushes forward")
	check(is_equal_approx(world.tab_fx_dur, DepthMotion.DURATION), "Push/Pull lasts its own short duration")
	world._process(0.05)
	check(error(framing(), original) > 0.1, "Camera starts moving with the departing panes")
	check_whole_panes(world, flat_2d, 1.0)
	await capture_stage("01-panes-leaving")
	world._process(0.15)
	check(error(framing(), original) > 3.0 and error(framing(), destination) > 3.0,
		"Camera moves through an intermediate frame during the crossing")
	check(world.camera_motion.moving and absf((world.tab_fx_dur - world.tab_fx_t) - (world.camera_motion.duration - world.camera_motion.elapsed)) < 0.001,
		"Camera and panes share one landing deadline, with no settling tail")
	check(is_instance_valid(world._transition_in) if flat_2d else not world.tab_fx_in.is_empty(), "Incoming panes overlap the departure")
	var backing_layers: Array = world._transition_in.pane_groups if flat_2d else world.tab_fx_in
	check(backing_layers.any(func(layer): return layer.get_meta("border_layer", "") == "main"), "Zoomed-out Main View border returns with the incoming panes")
	check(backing_layers.any(func(layer): return layer.get_meta("border_layer", "") == "selection"), "Incoming panes use the destination pane's active outline")
	check_whole_panes(world, flat_2d, 1.0)
	await capture_stage("02-crossing")
	world._process(0.15)
	check_whole_panes(world, flat_2d, 1.0)
	await capture_stage("03-arriving")
	world.set_process(true)
	await camera_at_rest()
	check(error(framing(), destination) < 2.0, "Camera lands directly on the destination's saved view")
	check(world.tab_fx_t < 0.0, "Transition releases its layers at completion")
	if flat_2d: check(world.sheet_2d.visible, "Live 2D canvas is restored")
	await capture_stage("04-destination")
	await say("Switching back reverses the dolly")
	world = await begin_frozen_switch(0)
	check(world.tab_fx_direction == -1.0, "Switching to an earlier tab pulls back")
	world._process(0.2)
	check_whole_panes(world, flat_2d, -1.0)
	world.set_process(true)
	await camera_at_rest()
	check(error(framing(), original) < 2.0, "Camera returns directly to the first tab's saved view")
	await say("Rapid switches retire existing panes without losing the destination")
	for delay in [0.1, DepthMotion.DURATION * 0.65]:
		await select_tab(0)
		await hold(delay)
		await point_at(tab_grip(1))
		var before := framing()
		tap()
		check(error(framing(), before) < 1.0, "Interrupted switch starts at the displayed camera")
		await camera_at_rest()
		check(error(framing(), destination) < 2.0, "Interrupted switch restores the latest destination")
	await select_tab(0)
	await camera_at_rest()
	world = await begin_frozen_switch(1)
	# Exercise the real frame entry point: two 12 FPS frames and a 150 ms
	# stall must advance the clock fully, despite the physics step cap.
	var started: float = world.tab_fx_t
	for dt in [1.0 / 12.0, 1.0 / 12.0, 0.15]: world._process(dt)
	check(started + 1.0 / 6.0 + 0.15 < world.tab_fx_dur and absf(world.tab_fx_t - started - (1.0 / 6.0 + 0.15)) < 0.000001,
		"Low FPS and render stalls preserve elapsed transition time")
	world.set_process(true)
	await camera_at_rest()
	await say("Instant switches and disabled effects restore the live canvas")
	await select_tab(0)
	host.instant_workspace_switch = true
	await select_tab(1)
	host.instant_workspace_switch = false
	check(world.tab_fx_t < 0.0 and landed(), "Instant switch cancels the active transition and camera tween")
	if flat_2d:
		check(world.sheet_2d.visible and world._transition_stale.is_empty(), "Instant 2D switch releases stale captures and reveals the live canvas")
	world.tab_fx = false
	await select_tab(0)
	await camera_at_rest()
	check(world.tab_fx_t < 0.0, "Disabled tab effects do not create transition layers")
	if flat_2d: check(world.sheet_2d.visible, "Disabled effects leave the 2D canvas visible")
	for id in pids: check(host.sessions[id].term.get_shell_pid() == pids[id], "Switches preserve shell %d" % id)
