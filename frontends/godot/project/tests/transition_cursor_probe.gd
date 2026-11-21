extends RefCounted
## Exercise native key notifications while a real transition is held still.
static func run(world: Node, live: bool, check: Callable) -> void:
	var canvas := world.get("camera_2d") != null
	var effects: Node = world.effects_2d if canvas else world.terminal_effects
	effects.config.set_option("state.typing", "typing.particles", "sparks")
	effects.particles.clear()
	var observed := {"key": false}
	var inspect := func(uv: Vector2):
		observed.key = true
		var pixel := preload("res://scenes/TerminalPresentation.gd").grid_point(world.term, uv)
		var pose = world._terminal_presentation_frame(pixel)
		check.call((pose != null) == live, "Cursor model exposes only the displayed live terminal")
		if not live:
			check.call(effects.particles.sparks.is_empty(), "Frozen glyph flights cannot emit at the hidden live cursor")
			return
		if pose == null: return
		var origin: Vector3 = Vector3(pose.x, pose.y, 0) if canvas else pose.origin
		check.call(not effects.particles.sparks.is_empty(), "Native typing emits during the live arrival")
		for particle in effects.particles.sparks:
			check.call(particle.position.distance_to(origin) <= particle.unit * 3.0, "Particle birth is within two source pixels per axis of the displayed cursor")
		if canvas:
			check.call(effects.is_visible_in_tree(), "2D live arrival keeps typing effects visible")
		else:
			for layer in world.tab_fx_in:
				if layer.live_source == null or layer.live_source.get_ref() != world.term_vp: continue
				var shader_pose: Transform3D = layer._material().get_shader_parameter("depth_transform")
				check.call(shader_pose.is_equal_approx(layer.global_transform), "GPU pane geometry and cursor use exactly the same transition transform")
	effects.typed.connect(inspect, CONNECT_ONE_SHOT)
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.unicode = 32
	key.pressed = true
	world.term.send_key(key)
	key.pressed = false
	world.term.send_key(key)
	var deadline := Time.get_ticks_msec() + 2000
	while not observed.key and Time.get_ticks_msec() < deadline: await world.get_tree().process_frame
	check.call(observed.key, "Native keystroke reaches the transition cursor probe")
	if effects.typed.is_connected(inspect): effects.typed.disconnect(inspect)
	effects.particles.clear()
