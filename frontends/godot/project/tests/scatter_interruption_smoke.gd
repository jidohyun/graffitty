extends "scatter_residual_smoke.gd"
## Interrupt both departure and arrival. Only the pieces actually on screen
## may survive a retarget; the hidden terminal must not be captured again.

func switch_and_freeze(index: int) -> void:
	var world: Node = host.world
	var target: int = host.get_tabs()[index].id
	await point_at(tab_grip(index))
	tap()
	var deadline := Time.get_ticks_msec() + 3000
	while host.workspace_layout.active != target and Time.get_ticks_msec() < deadline:
		await process_frame
	check(host.workspace_layout.active == target, "Tab switch reaches its requested target")
	world.set_process(false)
	while world.tab_fx_preparing and Time.get_ticks_msec() < deadline:
		world._process(0.0)
		await process_frame
	check(not world.tab_fx_preparing, "Destination pixels are ready before sampling the animation clock")
	world._transition_elapsed(0.0) # Consume the first zero-time presentation frame.

func play() -> void:
	use_config("res://../../../tests/llm-e2e/suites/godot/flat-world/per-tab-camera-view.conf")
	await labelled_tabs(["MARKED", "PLAIN"])
	await type("i=0; while [ $i -lt 20 ]; do printf '\\033[38;2;255;0;255mROW %02d ONLY ONE COPY OF THIS TEXT\\033[0m\\n' $i; i=$((i+1)); done{enter}")
	await camera_at_rest()
	check(await marked_pixels("marked-source") > 1000, "Dense marked text is visible")
	await select_tab(1)
	await camera_at_rest()
	var world: Node = host.world
	var arrive_at: float = world.FLY_TIME + world.TAB_FX_SETTLE - world.TAB_FX_ARRIVE
	for elapsed in [0.03, arrive_at + world.TAB_FX_ARRIVE * 0.6, world.FLY_TIME + 0.2]:
		await switch_and_freeze(0)
		for stage in [0.05, 0.17, 0.34]:
			if stage >= elapsed: break
			world._process(maxf(0.0, stage - world.tab_fx_t))
			await marked_pixels("release-%s-%s" % [elapsed, stage])
		world._process(maxf(0.0, elapsed - world.tab_fx_t))
		await marked_pixels("before-interrupt-%s" % elapsed)
		var retained: Array = world.tab_fx_out + world.tab_fx_in
		var arriving: Array = world.tab_fx_in.duplicate()
		var arrival_phase: float = 1.0 - (elapsed - arrive_at) / world.TAB_FX_ARRIVE
		await switch_and_freeze(1)
		check(world.tab_fx_out.is_empty(), "Interruption at %.2f s does not recapture the hidden terminal" % elapsed)
		check(retained.all(func(layer): return world.tab_fx_stale.any(func(entry): return entry.layer == layer)),
			"Displayed pieces keep their identity during interruption")
		if elapsed > arrive_at:
			check(not arriving.is_empty(), "Interruption exercises visible incoming pieces")
			for layer in arriving:
				var material: ShaderMaterial = layer._material()
				check(is_equal_approx(material.get_shader_parameter("retirement_phase"), arrival_phase)
					and is_zero_approx(material.get_shader_parameter("retirement_time")),
					"Incoming shader carries the displayed phase into retirement")
				check(material.get_shader_parameter("arrival_flight"), "Interrupted arrivals keep their right-side path")
		await marked_pixels("interrupted-%s" % elapsed)
		# Remove only retained glyphs from this diagnostic frame. Any remaining
		# magenta ink is an unwanted fresh copy of the interrupted destination.
		for entry in world.tab_fx_stale:
			if entry.layer.get_meta("glyph_layer", false): entry.layer.hide()
		var duplicate := await marked_pixels("duplicate-only-%s" % elapsed)
		check(duplicate == 0, "No recaptured stationary text after interruption at %.2f s: %d pixels" % [elapsed, duplicate])
		for entry in world.tab_fx_stale: entry.layer.show()
		if not arriving.is_empty():
			world._update_stale_pieces(0.05)
			await switch_and_freeze(0)
			await switch_and_freeze(1)
			for layer in arriving:
				check(is_instance_valid(layer) and is_equal_approx(layer._material().get_shader_parameter("retirement_time"), 0.05),
					"Further rapid switches keep the retirement clock without restarting it")
		world.set_process(true)
		await camera_at_rest()
		check(await marked_pixels("settled-%s" % elapsed) == 0, "Interrupted text is gone after landing")
