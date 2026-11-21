extends "../../../../replay/replay.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const DepthMotion := preload("res://scenes/TabDepthMotion.gd")

func configure_depth_panes(index: int) -> void:
	host.create_terminal_window(host.pane_focus)
	await owner_at_rest()
	var view: Control = host.workspace_view
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	var keys := Layout.keys(group.tree)
	for i in keys.size():
		Layout.find(group.tree, keys[i]).rect = Rect2(Vector2(90 + i * 390, 130 + i * 95), Vector2(360, 250))
	view.refresh()
	# Different framing used to add a second, unequal acceleration on top of
	# the depth effect. Include real saved pan/zoom in the transition checks.
	view.overview = true
	view.navigation_center = view.content_rect().get_center() + Vector2(index * 70, index * 25)
	view.navigation_zoom = 0.75 + index * 0.12
	view._apply_navigation()
	host.session_backend.commit_workspace(host)
	await camera_at_rest()
	check(Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree).size() >= 2, "Depth setup retains multiple real panes")

func check_depth_clock(world: Node, label: String) -> void:
	# Sample the actual retained scene at the beginning, both quarters, and
	# midpoint. Cubic smoothstep and staggered arrival both fail these checks.
	for sample in [[0.0, 0.0], [.25, .103515625], [.5, .5], [.75, .896484375]]:
		world.tab_fx_t = world.tab_fx_dur * sample[0]
		if world.get("camera_2d") != null:
			world._update_transition_2d(0.0)
			for layer in [world._transition_out, world._transition_in]:
				if not check(is_instance_valid(layer), "Both workspaces share the full transition interval"): continue
				check(layer.global_transform.is_equal_approx(layer.depth_projection), "Saved pan/zoom does not add motion to captured panes")
				var phase: float = 1.0 - sample[1] if layer.arriving else sample[1]
				var expected := pow(2.0, world.tab_fx_direction * (-1.0 if layer.arriving else 1.0) * phase)
				for group in layer.pane_groups + layer.ui_groups:
					var original: Vector2 = group.get_meta("depth_scale")
					check(is_equal_approx(group.scale.x / original.x, expected), "Every pane and decoration shares the same smooth reciprocal zoom")
				for panel in layer.panels:
					check(is_equal_approx(panel.material.get_shader_parameter("depth_alpha"), 1.0 - phase), "Opacity follows the shared clock")
		else:
			world._update_tab_transition(0.0)
			check(not world.tab_fx_out.is_empty() and not world.tab_fx_in.is_empty(), "Both workspaces share the full transition interval")
			for layer in world.tab_fx_out + world.tab_fx_in:
				var material: ShaderMaterial = layer._material()
				var arriving: bool = material.get_shader_parameter("arrival_flight")
				var phase: float = 1.0 - sample[1] if arriving else sample[1]
				check(is_equal_approx(material.get_shader_parameter("fly"), phase), "Every 3D pane uses the same quintic clock")
				var reference: Transform3D = layer.get_meta("transition_camera")
				# The capture keeps its own frustum while the live camera moves to the
				# saved view; only the shared dolly magnification scales it.
				var magnification := pow(DepthMotion.ZOOM_RATIO, world.tab_fx_direction * (-1.0 if arriving else 1.0) * phase)
				var expected: Transform3D = DepthMotion.presentation_transform(reference, world.cam.global_transform, layer.get_meta("transition_frustum"), world.proj_rect, magnification)
				check(layer.global_transform.is_equal_approx(expected) and (material.get_shader_parameter("depth_transform") as Transform3D).is_equal_approx(expected),
					"3D pane motion stays camera relative through arrival")
				check(material.get_shader_parameter("depth_zoom_ratio") == 2.0, "3D shares the reciprocal 2D zoom range")
		if sample[0] == 0.0 or sample[0] == .5:
			(await screen_image()).save_png(evidence_path(label + "-phase-" + str(sample[0]) + ".png"))

func use_world(path: String) -> void:
	await open_tabs(3)
	for tab in host.get_tabs():
		host.select_workspace(tab.id, true)
		check(host.switch_world(path), "Load transition test world")
		host.session_backend.commit_workspace(host)
		await owner_at_rest()
	host.select_workspace(host.get_tabs()[0].id, true)
	await camera_at_rest()
	await create_timer(.3).timeout

func has_departure(world: Node) -> bool:
	return is_instance_valid(world._transition_out) if world.get("camera_2d") != null else not world.tab_fx_out.is_empty()

func exercise_close(path: String, effect: String) -> void:
	await use_world(path)
	host.set_tab_transition_effect(effect)
	await select_tab(1)
	await camera_at_rest()
	var world: Node = host.world
	var removed: int = host.active_session_id
	var source: SubViewport = host.sessions[removed].vp
	var count: int = host.get_tabs().size()
	await click(on(tab_button(1).get_node("Close")))
	var deadline := Time.get_ticks_msec() + 5000
	while host.get_tabs().size() == count and Time.get_ticks_msec() < deadline: await process_frame
	check(host.get_tabs().size() == count - 1, "Close reaches the authoritative layout")
	check(world == host.world and world.tab_fx_t >= 0.0, "Closing selected tab animates in " + path + " / " + effect)
	check(has_departure(world), "Closing preserves the outgoing pane capture")
	await process_frame
	check(not is_instance_valid(source), "Closed terminal is released while its independent presentation departs")
	(await screen_image()).save_png(evidence_path(("flat-3d" if path.is_empty() else path.get_file()) + "-" + effect + "-close.png"))
	await camera_at_rest()
	await create_timer(.2).timeout
	check(not is_instance_valid(source), "Closed source is released after animation")

func exercise_depth(path: String) -> void:
	await use_world(path)
	host.set_tab_transition_effect("none")
	for index in range(3):
		await select_tab(index)
		await camera_at_rest()
		await label_tab(index, "DEPTH " + str(index + 1))
		await type("printf 'DEPTH PANE " + str(index + 1) + "\\nABCDEFGHIJKLMN 0123456789\\n'{enter}")
		await configure_depth_panes(index)
	host.select_workspace(host.get_tabs()[0].id, true)
	await camera_at_rest()
	# Reordering changes the semantic direction even though session IDs do not.
	host.move_session(host.get_tabs()[2].id, 1)
	await owner_at_rest()
	host.set_tab_transition_effect("push_pull")
	for index in [2, 0]:
		await select_tab(index)
		var world: Node = host.world
		var deadline := Time.get_ticks_msec() + 10000
		while (world.tab_fx_preparing or world.tab_fx_t <= 0.0) and Time.get_ticks_msec() < deadline: await process_frame
		check(not world.tab_fx_preparing, "Destination pixels are prepared before measuring motion")
		check(world.tab_fx_direction == (1.0 if index == 2 else -1.0), "Depth direction follows displayed tab number")
		check(world.tab_fx_dur < .7, "Depth transition is faster than dust")
		if world.get("camera_2d") != null:
			var outgoing: Node = world._transition_out
			if check(is_instance_valid(outgoing), "2D keeps outgoing panes"):
				check(outgoing.glyphs.is_empty(), "2D depth uses whole panes without particles")
				var group: Node2D = outgoing.pane_groups[0]
				var original: Vector2 = group.get_meta("depth_scale")
				check(group.scale.x > original.x if index == 2 else group.scale.x < original.x, "Push enlarges and pull shrinks departing panes")
				check(outgoing.panels[0].material.get_shader_parameter("depth_blur") > 0.0, "Moving panes defocus")
		else:
			check(not world.tab_fx_out.is_empty(), "3D keeps outgoing panes")
			for layer in world.tab_fx_out:
				check(layer.get_meta("depth_mode", false), "3D layer uses axial depth motion")
				check(not layer.get_meta("glyph_layer", false), "3D depth has no glyph/particle instances")
		# Freeze only the presenter at a middle pose while the GPU captures draw.
		# Shader compilation/readback time must not move evidence to the endpoint.
		world.set_process(false)
		await check_depth_clock(world, ("flat-3d" if path.is_empty() else path) + "-depth-" + str(index))
		world.tab_fx_t = .17
		if world.get("camera_2d") != null: world._update_transition_2d(0.0)
		else: world._update_tab_transition(0.0)
		(await screen_image()).save_png(evidence_path(("flat-3d" if path.is_empty() else path) + "-depth-" + str(index) + ".png"))
		world.set_process(true)
		await camera_at_rest()
	# Reverse before arrival, keeping the displayed frame rather than jumping.
	await select_tab(2)
	await select_tab(0)
	if host.world.get("camera_2d") == null and host.world.transition_ink != null:
		host.world._prepare_ink_frame()
		check(host.world.transition_ink.passes.size() <= 4, "Interrupted depth rendering keeps at most four independent lens targets")
	await camera_at_rest()
	check(host.world.tab_fx_t < 0.0, "Interrupted depth transition returns to live panes")
	if host.world.get("camera_2d") == null and host.world.transition_ink != null:
		host.world._prepare_ink_frame()
		check(host.world.transition_ink.passes.is_empty(), "Settled depth rendering releases all lens targets")
	var selected: int = host.active_session_id
	var pose: Dictionary = host.world.camera_motion.frame.duplicate(true)
	await point_at(on(tab_button(2)))
	await click(on(tab_button(2).get_node("Close")))
	await owner_at_rest()
	check(host.active_session_id == selected and host.world.tab_fx_t < 0.0, "Inactive close preserves selected pane without a transition")
	check(host.world.camera_motion.frame.transform.is_equal_approx(pose.transform), "Inactive close preserves camera pose")

func text_edge_energy(image: Image) -> float:
	# Dense text near the cursor starts in focus. A foreground pane incorrectly
	# supplying its depth to all text erases these edges on the first flight frame.
	var region := Rect2i(32, 120, 620, 280)
	var energy := 0.0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var value := image.get_pixel(x, y).get_luminance()
			energy += pow(value - image.get_pixel(x + 1, y).get_luminance(), 2)
			energy += pow(value - image.get_pixel(x, y + 1).get_luminance(), 2)
	return energy / float(region.size.x * region.size.y)


func exercise_close_dof() -> void:
	await use_world("")
	use_config("res://presets/flat.conf")
	host.set_tab_transition_effect("push_pull")
	# Closing the last tab selects its predecessor: the arriving pane starts
	# closer to the lens and used to defocus the outgoing text at near-zero alpha.
	host.select_workspace(host.get_tabs()[-1].id, true)
	await camera_at_rest()
	await type("printf '" + "DEPTH OF FIELD ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789\\n".repeat(15) + "'{enter}")
	await camera_at_rest()
	await type(" {backspace}")
	var world: Node = host.world
	world.set_process(false)
	var source: SubViewport = host.sessions[host.active_session_id].vp
	var before := await screen_image()
	var baseline := text_edge_energy(before)
	before.save_png(evidence_path("close-dof-before.png"))
	check(baseline > 0.001, "DOF close fixture contains readable text")
	check(world.terminal_effects.blur_radius > 1.0, "Ctrl+D exercises an active typing lens")
	var count: int = host.get_tabs().size()
	await keys("ctrl+d")
	var deadline := Time.get_ticks_msec() + 5000
	while host.get_tabs().size() == count and Time.get_ticks_msec() < deadline: await process_frame
	check(host.get_tabs().size() == count - 1, "Ctrl+D closes the shell through the owner")
	while world.tab_fx_preparing and Time.get_ticks_msec() < deadline:
		world._process(0.0)
		await process_frame
	check(not world.tab_fx_preparing, "Close captures finish preparing")
	world._process(0.0)
	for step in [0.0, 1.0 / 60.0]:
		world._process(step)
		var captured := await screen_image()
		captured.save_png(evidence_path("close-dof-%.3f.png" % step))
		var energy := text_edge_energy(captured)
		print("CLOSE_DOF_EDGE_RATIO ", step, " ", energy / maxf(baseline, 0.000001))
		check(energy > baseline * 0.55, "Text retains its focus at %.3f s instead of abruptly blurring" % step)
		check(world.terminal_effects.blur_radius > 1.0, "The normal lens remains enabled during departure")
	world.set_process(true)
	await camera_at_rest()
	await create_timer(.2).timeout
	check(world.terminal_effects.screen_dof, "Live terminal resumes screen-space DOF after landing")
	check(not is_instance_valid(source), "Ctrl+D capture source is released after landing")


func play() -> void:
	await exercise_close_dof()
	for path in ["", "flat-2d", "bistro"]:
		await exercise_close(path, "push_pull")
	for path in ["", "flat-2d"]:
		await exercise_depth(path)
		await exercise_close(path, "push_pull")
