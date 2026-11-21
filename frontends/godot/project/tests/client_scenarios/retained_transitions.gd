extends "res://tests/client_scenarios/workspace.gd"
## The same real remote-shell close runs on desktop and mobile GPUs.

func retained_transitions() -> void:
	if OS.has_feature("mobile"):
		expect(host.current_plugin == "flat-2d", "Mobile starts in Flat 2D")
	var choices: Array = host.available_worlds().map(func(entry): return entry.path)
	expect("flat-2d" in choices and "flat-3d" in choices, "Both built-in worlds are selectable")
	for path in ["flat-2d", "flat-3d"]:
		await close_with_state(path, "push_pull")
	expect(host.switch_world("flat-2d"), "Return to Flat 2D after rendering in 3D")
	expect(host.world_viewport.disable_3d and host.world.scenery_vp == null, "Returning to Flat 2D disables 3D and releases its rendering viewport")
	terminal().send_text("printf 'RETAINED_SURVIVOR_OK\\n'\r")
	await until(func(): return "RETAINED_SURVIVOR_OK" in text_in(), "Surviving owner terminal still accepts input")

func marker_pixels(image: Image) -> int:
	var count := 0
	for y in range(0, image.get_height(), 2):
		for x in range(0, image.get_width(), 2):
			var pixel := image.get_pixel(x, y)
			if pixel.r > .3 and pixel.b > .3 and pixel.g < .2 and pixel.a > .5: count += 1
	return count

func close_with_state(path: String, effect: String) -> void:
	await menu("View::World::" + ("Flat 3D" if path == "flat-3d" else "Flat 2D"))
	if not await until(func(): return host.current_plugin == path, "World menu selects " + path): return
	var checked: Array = host.menu_entries.filter(func(entry): return entry.action is String and entry.action == "SwitchWorld" and host.menu_entry_state(entry).checked)
	expect(checked.size() == 1 and checked[0].path == path, "World menu checks exactly the selected world")
	host.set_tab_transition_effect("none")
	await new_tab()
	expect(host.switch_world(path), "Closing tab uses requested world")
	expect(host.current_plugin == path, "Platform renders the requested world without substitution")
	var world: Node = host.world
	if path == "flat-3d":
		expect(host.world_viewport.own_world_3d and world.scenery_vp != null and not world.scenery_vp.disable_3d and world.cam.current, "Flat 3D has an isolated world and active 3D rendering")
	else:
		expect(host.world_viewport.disable_3d and world.scenery_vp == null, "Flat 2D keeps 3D rendering disabled")
	await until(func(): return world.tab_fx_t < 0.0 and not world.tab_fx_preparing, "Arrival settles before Ctrl+D")
	host.set_tab_transition_effect(effect)
	var closing: int = host.active_session_id
	var source: SubViewport = host.sessions[closing].vp
	terminal().send_text("printf '\\033[38;2;255;0;255mRETAINED_STATE_0123456789\\nABCDEFGHIJKLMN\\n\\033[0m'\r")
	if not await until(func(): return "RETAINED_STATE_0123456789" in text_in(), "Colored text reaches the remote renderer"): return
	await wait(.3)
	var evidence := OS.get_cache_dir().path_join("retained-transitions")
	DirAccess.make_dir_recursive_absolute(evidence)
	var label := path + "-" + effect
	await RenderingServer.frame_post_draw
	var live := source.get_texture().get_image()
	live.save_png(evidence.path_join(label + "-live.png"))
	expect(marker_pixels(live) > 20, "Live fixture contains colored terminal pixels")
	var presented := root.get_texture().get_image()
	presented.save_png(evidence.path_join(label + "-presented.png"))
	expect(marker_pixels(presented) > 20, "Selected world presents the colored text in the final frame")
	terminal().grab_focus()
	# Hold only presentation time; network replication and source teardown remain
	# live, so the outgoing view must own its state independently of the terminal.
	world.set_process(false)
	await key(KEY_D, true, false, 100)
	if not await until(func(): return not host.sessions.has(closing), "Ctrl+D closes the real remote shell"):
		world.set_process(true)
		return
	var deadline := Time.get_ticks_msec() + 10000
	while world.tab_fx_preparing and Time.get_ticks_msec() < deadline:
		world._process(0.0)
		await get_tree().process_frame
	world._process(0.0)
	expect(not world.tab_fx_preparing and world.tab_fx_t >= 0.0, "Close prepares a retained " + effect + " departure")
	await get_tree().process_frame
	expect(not is_instance_valid(source), "Closed terminal viewport is released during departure")
	var lens_targets: Array = []
	if world.get("camera_2d") == null and effect == "push_pull" and world.transition_ink != null:
		world._prepare_ink_frame()
		lens_targets = world.transition_ink.passes.values().map(func(render_pass): return render_pass.view)
		expect(lens_targets.size() == 2, "Departure and arrival use independent screen-space lenses")
	var captures: Array = []
	if world.get("camera_2d") != null:
		for layer in [world._transition_out] + world._transition_stale:
			if not is_instance_valid(layer): continue
			for capture in layer.terminal_captures.values():
				if capture not in captures: captures.append(capture)
	else:
		var layers: Array = world.tab_fx_out + world.tab_fx_stale.map(func(entry): return entry.layer)
		for layer in layers:
			for capture in layer._captures:
				if capture not in captures: captures.append(capture)
	expect(not captures.is_empty(), "Outgoing animation owns independent terminal views")
	var ink := 0
	for capture in captures:
		expect(is_instance_valid(capture.terminal_view) and capture.terminal_view.is_class("TerminalSnapshotView"), "Departure retains native terminal drawing state")
		capture.request_extent(Vector2(capture.size) * 1.5)
		capture.render_target_update_mode = SubViewport.UPDATE_ONCE
	for unused in 3: await get_tree().process_frame
	await RenderingServer.frame_post_draw
	for index in captures.size():
		var image: Image = captures[index].get_texture().get_image()
		image.save_png(evidence.path_join(label + "-capture-%d.png" % index))
		ink += marker_pixels(image)
	expect(ink > 20, "Retained text rerenders on the GPU after source destruction: %d colored pixels" % ink)
	world.set_process(true)
	await until(func(): return world.tab_fx_t < 0.0, "Close animation returns to live panes")
	await until(func(): return captures.all(func(capture): return not is_instance_valid(capture)), "Completed departure releases every retained target")
	if not lens_targets.is_empty():
		await until(func(): return lens_targets.all(func(view): return not is_instance_valid(view)), "Landing releases every transition lens target")
	expect(host.sessions.has(initial_id), "Original owner terminal survives " + effect)
