extends "../../../../replay/replay.gd"
var client: Node
var delayed: Array = []
var live_departure := -1

func delay_scene(id: int, frame: Dictionary, data: PackedByteArray) -> void:
	if id == live_departure: client._frame(id, frame, data)
	else: delayed.append([id, frame, data])

func begin_delay() -> void:
	delayed.clear()
	live_departure = host.active_session_id
	client.connection.terminal_received.disconnect(client._frame)
	client.connection.terminal_received.connect(delay_scene)

func end_delay() -> void:
	client.connection.terminal_received.disconnect(delay_scene)
	client.connection.terminal_received.connect(client._frame)
	for update in delayed: client._frame.callv(update)
	delayed.clear()

func incoming(world: Node) -> Array:
	if world.get("camera_2d") != null:
		return [world._transition_in] if is_instance_valid(world._transition_in) else []
	return world.tab_fx_in

func departing_textures(world: Node) -> Array:
	var textures: Array = []
	if world.get("camera_2d") != null:
		if is_instance_valid(world._transition_out):
			for item in world._transition_out.live_panels: textures.append(item.sprite.texture)
	else:
		for layer in world.tab_fx_out:
			if layer.live_source != null: textures.append(layer._material().get_shader_parameter("terminal_tex"))
	return textures

func check_live_departure(world: Node, id: int, phase: String) -> void:
	var textures := departing_textures(world)
	if not check(not textures.is_empty(), phase + ": departure uses a live terminal texture"): return
	check(id in client.connection.subscriptions, phase + ": departing terminal remains subscribed")
	var before: PackedByteArray = textures[0].get_image().get_data()
	var marker := "LIVE_DEPARTURE_%d" % Time.get_ticks_usec()
	client.connection.send_input(id, ("printf '\\033[46m%s\\033[0m\\n'\r" % marker).to_utf8_buffer())
	var deadline := Time.get_ticks_msec() + 5000
	while marker not in str(host.sessions[id].term.get_text(false).get("text", "")) and Time.get_ticks_msec() < deadline: await process_frame
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	check(marker in str(host.sessions[id].term.get_text(false).get("text", "")), phase + ": departing terminal receives new owner output")
	check(textures[0].get_image().get_data() != before, phase + ": departing pixels continue updating")

func interrupt_preparation(instant: bool) -> void:
	host.select_workspace(host.get_tabs()[0].id, true)
	await camera_at_rest()
	host.set_tab_transition_effect("push_pull")
	var world: Node = host.world
	begin_delay()
	host.select_workspace(host.get_tabs()[1].id)
	await hold(.2)
	var held: Array = world._tab_fx_prepared_viewports.duplicate()
	check(world.tab_fx_preparing and not held.is_empty(), "A delayed destination retains its render sources")
	host.select_workspace(host.get_tabs()[0].id, instant)
	for viewport in held:
		check(not viewport.get_meta("terminal_capture_active", false), "Interrupting preparation releases the abandoned viewport hold")
	end_delay()
	await camera_at_rest()
	check(not world.tab_fx_preparing and world._tab_fx_prepared_viewports.is_empty(), "Interrupted preparation returns to live content")

func interrupt_live_arrival() -> void:
	host.select_workspace(host.get_tabs()[0].id, true)
	await camera_at_rest()
	host.set_tab_transition_effect("push_pull")
	var world: Node = host.world
	host.select_workspace(host.get_tabs()[1].id)
	var deadline := Time.get_ticks_msec() + 10000
	while world.tab_fx_preparing and Time.get_ticks_msec() < deadline: await process_frame
	world.set_process(false)
	var layers: Array = []
	if world.get("camera_2d") != null and is_instance_valid(world._transition_in):
		for item in world._transition_in.live_panels:
			layers.append({"sprite": item.sprite, "texture": item.sprite.texture})
	else:
		for layer in world.tab_fx_in:
			if layer.live_source != null:
				layers.append({"layer": layer, "texture": layer._material().get_shader_parameter("terminal_tex")})
	check(not layers.is_empty(), "Interruption starts with a live incoming terminal")
	host.select_workspace(host.get_tabs()[0].id)
	for item in layers:
		if item.has("sprite"):
			check(item.sprite.texture != item.texture, "Retiring 2D arrival freezes its live terminal source")
		else:
			check(item.layer.live_source == null and item.layer._material().get_shader_parameter("terminal_tex") != item.texture, "Retiring 3D arrival freezes its live terminal source")
	world.set_process(true)
	await camera_at_rest()
	check(world._tab_fx_prepared_viewports.is_empty(), "Interrupted live arrival releases its viewport holds")

func exercise(operation: String, effect: String, label: String) -> void:
	await camera_at_rest()
	host.set_tab_transition_effect(effect)
	var world: Node = host.world
	var previous: int = host.workspace_layout.active
	var departing_id: int = host.active_session_id
	begin_delay()
	match operation:
		"switch": host.select_workspace(host.get_tabs()[0].id)
		"create": host.create_session()
		"close": host.request_close_tab()
	var deadline := Time.get_ticks_msec() + 10000
	while host.workspace_layout.active == previous and Time.get_ticks_msec() < deadline: await process_frame
	check(host.workspace_layout.active != previous, "Operation selects its destination: " + operation)
	# The real owner has the content; only its scene delivery is held back.
	# Creation also gets distinctive output before any capture is allowed.
	if operation == "create":
		client.connection.send_input(host.active_session_id, "printf '\\033[32mREADY DESTINATION\\033[0m\\n'\r".to_utf8_buffer())
	await hold(.6)
	check(not delayed.is_empty(), "A real owner snapshot is delayed")
	check(world == host.world and world.tab_fx_preparing, "Create/switch/close all wait for content: " + operation)
	check(world.tab_fx_t == 0.0 and world.camera_motion.elapsed == 0.0, "Loading consumes neither camera nor content animation time")
	check(incoming(world).is_empty(), "No empty incoming snapshot is frozen")
	if operation != "close": await check_live_departure(world, departing_id, "Waiting for destination")
	(await screen_image()).save_png(evidence_path(label + "-" + operation + "-waiting.png"))
	end_delay()
	deadline = Time.get_ticks_msec() + 10000
	while world.tab_fx_preparing and Time.get_ticks_msec() < deadline: await process_frame
	if not check(not world.tab_fx_preparing, "Rendered snapshot releases the shared gate"): return
	check(world.tab_fx_t < .05, "Reveal begins at the start after loading")
	check(not incoming(world).is_empty(), "Incoming captures exist before camera motion")
	check(world.term.is_render_snapshot_ready(), "Native renderer reports painted content")
	check("READY DESTINATION" in str(world.term.get_text(false).get("text", "")), "The arriving capture uses the loaded destination content")
	# Pause after readiness to inspect the GPU texture used by the arrival.
	world.set_process(false)
	var textures: Array = []
	if world.get("camera_2d") != null:
		for item in world._transition_in.live_panels:
			check(item.sprite.texture == item.source.get_ref().get_texture(), "Zoom arrival samples the live terminal viewport")
			textures.append(item.sprite.texture)
		for key: String in world._transition_in.terminal_captures:
			# The background/image capture can correctly be fully transparent.
			if int(key.get_slice(":", 1)) & (1 << 18):
				textures.append(world._transition_in.terminal_captures[key].get_texture())
	else:
		for layer in world.tab_fx_in:
			if layer.live_source != null:
				check(layer._material().get_shader_parameter("terminal_tex") == layer.live_source.get_ref().get_texture(), "Zoom arrival samples the live terminal viewport")
			if layer.get_meta("glyph_layer", false) or layer.live_source != null:
				textures.append(layer._material().get_shader_parameter("terminal_tex"))
	check(not textures.is_empty(), "Arrival contains terminal pixels, not only chrome")
	for texture in textures:
		check(not texture.get_image().is_invisible(), "The incoming texture has visible ink")
	world.tab_fx_t = world.tab_fx_dur * .5
	if world.get("camera_2d") != null: world._update_transition_2d(0.0)
	else: world._update_tab_transition(0.0)
	await preload("res://tests/transition_cursor_probe.gd").run(world, true, check)
	if operation != "close": await check_live_departure(world, departing_id, "Mid-transition")
	(await screen_image()).save_png(evidence_path(label + "-" + operation + "-reveal.png"))
	if effect == "push_pull" and not textures.is_empty():
		var before: PackedByteArray = textures[0].get_image().get_data()
		var marker := "LIVE_ARRIVAL_%d" % Time.get_ticks_usec()
		client.connection.send_input(host.active_session_id, ("printf '\\033[45m%s\\033[0m\\n'\r" % marker).to_utf8_buffer())
		deadline = Time.get_ticks_msec() + 5000
		while marker not in str(world.term.get_text(false).get("text", "")) and Time.get_ticks_msec() < deadline: await process_frame
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		check(marker in str(world.term.get_text(false).get("text", "")), "Owner produces new output during the held zoom arrival")
		check(textures[0].get_image().get_data() != before, "Arrival pixels update before the live-sheet handoff")
	world.set_process(true)
	await camera_at_rest()
	check(not world.tab_fx_preparing and world._tab_fx_prepared_viewports.is_empty(), "Prepared viewport holds are released")
	await hold(.3)
	check(host.sessions.values().all(func(pair): return int(pair.vp.get_meta("terminal_live_users", 0)) == 0), "Completed transition releases all live source holds")
	if operation != "close":
		check(departing_id not in client.connection.subscriptions, "Completed transition unsubscribes its hidden departure")

func play() -> void:
	client = get_nodes_in_group("shared_presentations").filter(func(node): return node.host == host)[0]
	await open_tabs(2)
	for path in ["", "flat-2d"]:
		for tab in host.get_tabs():
			host.select_workspace(tab.id, true)
			check(host.switch_world(path), "Choose test renderer")
			host.session_backend.commit_workspace(host)
			await camera_at_rest()
			await type("printf '\\033[32mREADY DESTINATION\\033[0m\\n'{enter}")
		for effect in ["push_pull"]:
			host.select_workspace(host.get_tabs()[1].id, true)
			await exercise("switch", effect, ("flat-3d" if path.is_empty() else path) + "-" + effect)
			await exercise("create", effect, ("flat-3d" if path.is_empty() else path) + "-" + effect)
			await exercise("close", effect, ("flat-3d" if path.is_empty() else path) + "-" + effect)
		await interrupt_preparation(false)
		await interrupt_preparation(true)
		await interrupt_live_arrival()
