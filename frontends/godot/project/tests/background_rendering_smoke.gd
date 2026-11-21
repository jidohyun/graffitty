extends "../../../../tests/llm-e2e/replay/replay.gd"
## Run with tests/support/e2e_background.py's environment and renderer arguments.
## Also accepts --write-movie to verify Movie Maker receives these same frames.


func play() -> void:
	if not check(
		DisplayServer.get_name() != "headless",
		"Graphics smoke uses a real rendering device",
	):
		return
	create_timer(20.0).timeout.connect(
		func():
			push_error("Background rendering timed out waiting for a rendered frame")
			quit(1),
	)
	if Background.enabled():
		check(not root.has_focus(), "Background replay never needs native window focus")
	var patch := ColorRect.new()
	patch.position = Vector2(16, 16)
	patch.size = Vector2(64, 64)
	patch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var layer := CanvasLayer.new()
	layer.layer = 129
	root.add_child(layer)
	layer.add_child(patch)
	# Inspect known pixels, not just draw counters: a hidden viewport can emit
	# frame_post_draw while its texture remains stale unless UPDATE_ALWAYS is set.
	for color in [Color.RED, Color.BLUE, Color.GREEN, Color.RED]:
		patch.color = color
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		var at := Vector2i(
			Vector2(32, 32) * Vector2(image.get_size()) / root.get_visible_rect().size
		)
		var actual := image.get_pixelv(at)
		check(
			actual.is_equal_approx(color),
			"Hidden viewport draws the current color: %s (got %s)" % [color, actual],
		)
	var image := await screen_image()
	var before := hash(image.get_data())
	var terminal: Control = host.sessions[host.active_session_id].term
	terminal.send_text("printf 'BACKGROUND_RENDER_MARKER\\n'\r")
	var deadline := Time.get_ticks_msec() + 5000
	while (
		not "BACKGROUND_RENDER_MARKER" in terminal_text(host.active_session_id)
		and Time.get_ticks_msec() < deadline
	):
		await process_frame
	check(
		"BACKGROUND_RENDER_MARKER" in terminal_text(host.active_session_id),
		"Terminal output arrives without desktop focus",
	)
	image = await screen_image()
	check(hash(image.get_data()) != before, "Terminal output changes the captured window pixels")
	var frames := await frames_during(
		func():
			patch.color = Color.BLUE,
		func():
			return true,
	)
	check(frames.size() >= 2, "Frame capture resumes after frame_post_draw")
	layer.queue_free()
