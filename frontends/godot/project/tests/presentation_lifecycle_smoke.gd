extends SceneTree
## Inactive replicas allocate no renderer, stop processing and release GPU state.
const Updates := preload("res://scenes/TerminalViewportUpdates.gd")
const Capture := preload("res://scenes/CellShatter.gd")
const Transition := preload("res://scenes/TabTransition2D.gd")
var failures := 0
var frames := 0
var bells := 0
var strokes := 0
var input_events := 0

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("presentation-lifecycle-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func settle() -> void:
	for i in 4: await process_frame

func run() -> void:
	var pairs: Array[Dictionary] = []
	for i in 12:
		var viewport := SubViewport.new()
		viewport.size = Vector2i(640, 400)
		var terminal: Control = ClassDB.instantiate("Terminal")
		terminal.remote_mode = true
		terminal.size = Vector2(640, 400)
		terminal.configure_advanced({"cursor_blink": 0})
		Updates.configure(viewport, terminal)
		Updates.set_visible(viewport, false)
		viewport.add_child(terminal)
		root.add_child(viewport)
		terminal.frame_changed.connect(func(): frames += 1)
		pairs.append({"vp": viewport, "term": terminal})
	await settle()
	check(pairs.all(func(pair): return pair.term.get_grid_size() == Vector2i.ZERO and not pair.term.is_processing()), "Unopened tabs never initialize native renderers or process")
	check(pairs.all(func(pair): return pair.vp.size == Vector2i(2, 2)), "Inactive render targets release their backing storage")
	pairs[0].term.bell.connect(func(): bells += 1)
	pairs[0].term.remote_bell()
	await settle()
	check(bells == 1 and not pairs[0].term.is_processing(), "Inactive tabs deliver bell notifications without starting a renderer")
	pairs[1].term.send_text("reply")
	await settle()
	check(pairs[1].term.remote_take_input().get_string_from_utf8() == "reply" and not pairs[1].term.is_processing(), "Unopened tabs forward sent text without processing")
	for i in pairs.size():
		if i > 0: Updates.set_visible(pairs[i-1].vp, false)
		Updates.set_visible(pairs[i].vp, true)
		pairs[i].term.remote_feed_stream(("tab-%d" % i).to_utf8_buffer(), 80, 20, false, false)
		await settle()
	check(pairs.filter(func(pair): return pair.term.is_processing()).size() == 1, "Repeated tab switches leave only the selected renderer processing")
	var before := frames
	Updates.set_enabled(pairs.back().vp, false)
	await settle()
	before = frames
	await create_timer(0.2).timeout
	check(frames == before, "Hidden presentation performs zero native repaints")
	Updates.set_enabled(pairs.back().vp, true)
	Updates.set_visible(pairs[0].vp, true)
	await settle()
	check(pairs[0].vp.size == Vector2i(640, 400), "Returning to a tab restores its render target")
	check("tab-0" in str(pairs[0].term.get_text(false).get("text", "")), "Returning to a tab preserves terminal contents")
	var pixels := 0
	var bytes := 0
	for pair in pairs:
		if Updates.is_active(pair.vp):
			pixels += int(pair.vp.get_meta("terminal_pixel_budget"))
			bytes += int(pair.term.remote_image_stats().budget)
	check(pixels <= Updates.pixel_budget() and bytes <= Updates.image_budget(), "Visible panes share one target/image budget")
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	var texture := ImageTexture.create_from_image(image)
	var terminal: Node = pairs[0].term
	terminal.remote_set_asset_texture("test-image", texture, 32, 32)
	check(terminal.remote_image_stats().textures == 1, "Visible terminal accepts an image texture")
	Updates.set_visible(pairs[0].vp, false)
	await settle()
	check(terminal.remote_image_stats().textures == 0, "Inactive terminal drops its image textures")
	terminal.remote_set_asset_texture("late-image", texture, 32, 32)
	check(terminal.remote_image_stats().textures == 0, "Late image delivery cannot allocate an inactive texture")
	terminal.keystroke.connect(func(_cell, _unicode): strokes += 1)
	var key := InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_A
	key.unicode = 97
	terminal.send_key(key)
	terminal.set_preedit("한", Vector2i.ZERO)
	await settle()
	check(strokes == 0 and terminal.remote_take_input().get_string_from_utf8() == "a", "Inactive key/composition input forwards committed bytes without typing effects")
	var selected: Node = pairs.back().term
	selected.input_ready.connect(func(): input_events += 1)
	selected.respawn()
	selected.send_key(key)
	await settle()
	check(input_events == 1 and selected.remote_take_input().get_string_from_utf8() == "a", "Recreating a renderer preserves event-driven input delivery")
	check(selected.remote_image_stats().budget == pairs.back().vp.get_meta("terminal_image_budget"), "Recreating a renderer preserves its shared image budget")
	# Frozen captures are owned by the effect, including captures parented under
	# a different viewport. Repeated/interrupted effects must release them all.
	var source: SubViewport = pairs.back().vp
	var baseline := source.get_parent().get_child_count()
	for i in 30:
		var outgoing := Transition.new()
		root.add_child(outgoing)
		outgoing.capture(source, 1 << 18)
		outgoing.capture(source, 1 << 19)
		outgoing.retire()
		outgoing.queue_free()
		var first := Capture.new()
		var second := Capture.new()
		root.add_child(first)
		root.add_child(second)
		first._capture_texture(source, 1 << 18)
		second._capture_texture(source, 1 << 18)
		first.queue_free()
		second.queue_free()
		await settle()
	check(source.get_parent().get_child_count() == baseline, "Repeated 2D and shared 3D captures leave no retained viewports")
	var budget := preload("res://scenes/EffectCaptureBudget.gd")
	var captures: Array[SubViewport] = []
	var capture_pixels := 0
	for i in 10:
		var capture := SubViewport.new()
		capture.size = Vector2i(4000, 4000)
		budget.fit(capture)
		captures.append(capture)
	for capture in captures: capture_pixels += capture.size.x * capture.size.y
	check(capture_pixels <= budget.limit() + 40, "Concurrent effect captures share a bounded pixel budget")
	check(captures.all(func(capture): return capture.size == captures[0].size and capture.size.x > 512), "Later glyph captures retain the same detail as earlier backing captures")
	for capture in captures: capture.free()
	for script in [preload("res://scenes/TerminalEffects2D.gd"), preload("res://scenes/TerminalEffects.gd")]:
		var effects: Node = script.new()
		effects.automatic = false
		root.add_child(effects)
		var particles: Node = effects.particles
		for preset in particles.PROFILES:
			particles.configure(preset, 64, 1.0)
			for i in 100: particles.burst(Vector3.ZERO, Vector3.UP, Vector3.FORWARD, 4.0)
			check(particles.sparks.size() <= particles.CAPACITY, "%s particle bursts stay bounded" % preset)
			for i in 20: particles._process(0.25)
			check(particles.sparks.is_empty() and particles.mesh.multimesh.visible_instance_count == 0 and not particles.is_processing(), "%s particles clear CPU/GPU state and stop processing" % preset)
		particles.configure("sparks", 6, 1.0)
		particles.burst(Vector3.ZERO, Vector3.UP, Vector3.FORWARD)
		particles.clear()
		check(particles.sparks.is_empty() and not particles.is_processing(), "Cancelling an effect stops its particle work immediately")
		effects.free()
	for pair in pairs: pair.vp.free()
	await settle()
	print("PRESENTATION_LIFECYCLE_PASS" if failures == 0 else "PRESENTATION_LIFECYCLE_FAIL")
	quit.call_deferred(failures)
