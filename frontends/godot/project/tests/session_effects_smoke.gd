extends SceneTree
## Run against a disposable server with alpha/beta sessions. Never attaches to
## a running source session; the fixture launcher supplies an isolated descriptor.
var failures: Array[String] = []
var client: Node
func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()
func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)
func until(condition: Callable, seconds := 12.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while not condition.call() and Time.get_ticks_msec() < deadline: await process_frame
	return condition.call()

func check_arrival(host: Node, path: String, live: bool) -> String:
	var world: Node = host.world
	var started := Time.get_ticks_msec()
	var ready := func():
		return world.tab_fx_t >= 0.0 and not world.tab_fx_preparing and (is_instance_valid(world._transition_in) if path == "flat-2d" else not world.tab_fx_in.is_empty())
	if not await until(ready):
		check(false, path + " arrival becomes ready")
		return ""
	print("Arrival ready in %d ms" % (Time.get_ticks_msec() - started))
	world.set_process(false)
	world.tab_fx_t = world._tab_arrival_start() + world._tab_arrival_duration() * 0.5
	if path == "flat-2d": world._update_transition_2d(0.0)
	else: world._update_tab_transition(0.0)
	await preload("res://tests/transition_cursor_probe.gd").run(world, live, check)
	var textures: Array[Texture2D] = []
	if not live:
		textures = frozen_textures(world, path, true)
	elif path == "flat-2d":
		for item in world._transition_in.live_panels:
			check(item.sprite.texture == item.source.get_ref().get_texture(), "Fly away uses a live 2D terminal texture")
			textures.append(item.sprite.texture)
	else:
		for layer in world.tab_fx_in:
			if layer.live_source == null: continue
			var texture: Texture2D = layer._material().get_shader_parameter("terminal_tex")
			check(texture == layer.live_source.get_ref().get_texture(), "Fly away uses a live 3D terminal texture")
			textures.append(texture)
	check(not textures.is_empty(), path + (" Fly away has live terminal layers" if live else " Fly away and in has frozen terminal layers"))
	var departure := frozen_textures(world, path, false)
	check(not departure.is_empty(), path + " departure has frozen glyph layers")
	var marker := "SESSION_OUTPUT_%d" % Time.get_ticks_usec()
	if not textures.is_empty():
		await process_frame
		RenderingServer.force_draw(false)
		var before := textures[0].get_image().get_data()
		var departure_before: Array = departure.map(func(texture): return texture.get_image().get_data())
		client.connection.send_input(host.active_session_id, ("printf '\\033[45m%s\\033[0m\\n'\r" % marker).to_utf8_buffer())
		check(await until(func(): return marker in str(world.term.get_text(false).get("text", ""))), "New shell output arrives during the flight")
		await process_frame
		await process_frame
		RenderingServer.force_draw(false)
		var changed := textures[0].get_image().get_data() != before
		check(changed == live, path + (" arrival pixels update before handoff" if live else " arriving glyphs stay frozen until handoff"))
		for i in departure.size():
			check(departure[i].get_image().get_data() == departure_before[i], path + " departing glyphs stay frozen")
	world.set_process(true)
	return marker

func frozen_textures(world: Node, path: String, arriving: bool) -> Array[Texture2D]:
	var textures: Array[Texture2D] = []
	if path == "flat-2d":
		var layer: Node = world._transition_in if arriving else world._transition_out
		if not is_instance_valid(layer): return textures
		check(layer.live_panels.is_empty(), "Glyph flight has no live terminal panels")
		for key: String in layer.terminal_captures:
			if int(key.get_slice(":", 1)) & (1 << 18):
				textures.append(layer.terminal_captures[key].get_texture())
	else:
		for layer in (world.tab_fx_in if arriving else world.tab_fx_out):
			check(layer.live_source == null, "Glyph flight has no live terminal source")
			if layer.get_meta("glyph_layer", false):
				textures.append(layer._material().get_shader_parameter("terminal_tex"))
	return textures

func run() -> void:
	if OS.get_environment("GRAFFITTY_EFFECT_FIXTURE") != "1":
		printerr("Requires an isolated session-effects fixture")
		quit(2)
		return
	root.size = Vector2i(900, 600)
	client = preload("res://scenes/SharedWorkspace.gd").new()
	client.launch_args = PackedStringArray(["--workspace=alpha", "--attach-session", "--plugin=flat-2d"])
	root.add_child(client)
	if not await until(func(): return client.host != null and client.host.active_terminal() != null):
		check(false, "Fixture attaches")
		quit(1)
		return
	var host: Node = client.host
	for path in ["flat-2d", ""]:
		check(host.switch_world(path), "Open world " + path)
		await create_timer(0.5).timeout
		var world: Node = host.world
		var saved_center := Vector2(340, 210)
		host.workspace_view.overview = true
		host.workspace_view.navigation_zoom = 0.73
		host.workspace_view.navigation_center = saved_center + host.workspace_view.inset_shift / 0.73
		host.workspace_view._apply_navigation()
		# Both sessions are already sampling, even before beta has a viewer.
		await create_timer(1.2).timeout
		for effect in ["fly_away", "fly_away_and_in"]:
			host.set_session_transition_effect(effect)
			for incoming in ["beta", "alpha"]:
				var seen := {"switched": false, "out": false, "in": false, "resources": false, "missing_resources": false, "lens": false}
				var outgoing_lens := {}
				var switched := func():
					seen.switched = true
					# A session-list update can refresh while the old topology is still
					# installed. It must not consume the departing session capture.
					client._refresh()
					check(client.switching_session and not world.session_transition_capture.is_empty(), "Old topology cannot start the new session flight")
					if path != "flat-2d":
						outgoing_lens.depth = world.session_transition_capture.focus_depth
						outgoing_lens.zoom = world.session_transition_capture.lens_zoom
				client.connection.session_switched.connect(switched)
				var observe := func():
					if not seen.switched: return
					if path == "flat-2d":
						if is_instance_valid(world._transition_out): seen.out = seen.out or world._transition_out.dust_mode
						if is_instance_valid(world._transition_in):
							seen["in"] = seen["in"] or (world._transition_in.depth_mode if effect == "fly_away" else world._transition_in.dust_mode)
					else:
						if not seen.lens and world.tab_fx_t >= 0.0:
							check(not outgoing_lens.is_empty() and world.lens_transition_t >= 0.0
								and is_equal_approx(world.lens_transition_from, outgoing_lens.depth)
								and is_equal_approx(world.lens_transition_zoom_from, outgoing_lens.zoom),
								"Session flight starts from the departing optical focus and zoom")
							seen.lens = true
						seen.out = seen.out or world.tab_fx_out.any(func(layer): return layer.has_meta("dust"))
						seen["in"] = seen["in"] or world.tab_fx_in.any(func(layer): return layer.get_meta("depth_mode", false) if effect == "fly_away" else layer.has_meta("dust"))
					if seen["in"]:
						var monitor: Node = host.resource_monitor_for(host.active_session_id)
						var sample: Dictionary = monitor.snapshot() if monitor != null else {}
						var ready: bool = sample.get("status") == "running" and sample.get("cpu_valid", false) and sample.get("memory_current", 0) > 0
						seen.resources = seen.resources or ready
						if not ready and not seen.missing_resources:
							print("Missing arrival resources: pane=", host.active_session_id, " sample=", sample)
						seen.missing_resources = seen.missing_resources or not ready
				process_frame.connect(observe)
				var result: Dictionary = await client.connection.request_action("session_switch", {"name": incoming})
				check(result.get("type") != "error", "Switch fixture session for " + effect)
				var marker := await check_arrival(host, path, effect == "fly_away")
				check(await until(func():
					return world.tab_fx_t < 0.0 and not world.tab_fx_preparing and (not is_instance_valid(world._transition_in) if path == "flat-2d" else world.tab_fx_in.is_empty())), path + " session arrival lands")
				await process_frame
				check(not marker.is_empty() and marker in str(world.term.get_text(false).get("text", "")), path + " live handoff shows output received during the flight")
				for pair in host.sessions.values():
					check(int(pair.vp.get_meta("terminal_live_users", 0)) == 0, "Session arrival releases live rendering holds")
				process_frame.disconnect(observe)
				client.connection.session_switched.disconnect(switched)
				check(seen.out and seen["in"], path + " " + effect + " renders departure and arrival")
				check(seen.resources and not seen.missing_resources, path + " " + effect + " has CPU/RAM from the first arrival frame")
				check(world.fx_mat.get_shader_parameter("terminal_tex") == world._sheet_viewport().get_texture(), path + " retains live terminal texture")
			var view: Control = host.workspace_view
			check(view.overview and is_equal_approx(view.navigation_zoom, 0.73) and (view.navigation_center - view.inset_shift / 0.73).distance_to(saved_center) < 0.01,
				path + " " + effect + " returns to the session's saved viewport")
		host.set_effects_profile("off")
		var off := {"switched": false, "animated": false}
		var check_off := func():
			off.switched = true
			off.animated = world.session_transition_active or not world.session_transition_capture.is_empty()
		client.connection.session_switched.connect(check_off)
		for incoming in ["beta", "alpha"]:
			var result: Dictionary = await client.connection.request_action("session_switch", {"name": incoming})
			check(result.get("type") != "error", "Switch with effects Off")
			await process_frame
			check(off.switched and not off.animated and not world.session_transition_active and world.session_transition_capture.is_empty(), path + " Off skips session flight and capture")
		client.connection.session_switched.disconnect(check_off)
		host.set_effects_profile("world")
		check(world.effect_control.allows("session_switch"), path + " World Default enables session effects again")
	client.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
