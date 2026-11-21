extends SceneTree
## Immutable terminal drawing state survives source teardown and rerasterizes.
const Updates := preload("res://scenes/TerminalViewportUpdates.gd")
const Transition := preload("res://scenes/TabTransition2D.gd")
const Capture := preload("res://scenes/CellShatter.gd")
var failures := 0

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("graffitty-capture-%d" % OS.get_process_id()))
	if "--mobile-budget" in OS.get_cmdline_user_args():
		ProjectSettings.set_setting("_custom_features", "ios")
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func ink(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a > 0.1 and color.r > 0.2: count += 1
	return count

func cyan(image: Image) -> int:
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a > 0.8 and color.r < 0.1 and color.g > 0.8 and color.b > 0.8: count += 1
	return count

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This test needs real rendering")
		quit(1)
		return
	root.size = Vector2i(700, 500)
	var source := SubViewport.new()
	source.size = Vector2i(2560, 1600)
	source.size_2d_override = Vector2i(640, 400)
	source.size_2d_override_stretch = true
	source.transparent_bg = true
	source.disable_3d = true
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(source.size_2d_override)
	terminal.configure_advanced({"cursor_blink": 0})
	terminal.set_live_background_opacity(0.35)
	Updates.configure(source, terminal)
	source.add_child(terminal)
	root.add_child(source)
	terminal.set_raster_scale(4.0)
	terminal.remote_feed_stream(("\u001b[38;2;255;0;255mCOMPLETE SNAPSHOT 0123456789\r\n"
		+ "\u001b[1;3;4mBOLD ITALIC UNDERLINE\u001b[0m é 한글 == != -> ─┼─\r\n"
		+ "\u001b_Ga=T,f=32,s=1,v=1,i=42,c=4,r=2,q=2;AP///w==\u001b\\").to_utf8_buffer(), 80, 24, false, false)
	terminal.set_preedit("한", Vector2i.ZERO)
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	var live := source.get_texture().get_image()
	var outgoing := Transition.new()
	root.add_child(outgoing)
	var text := outgoing.capture(source, 1 << 18)
	check(outgoing.capture(source, 1 << 18) == text and outgoing.captures.size() == 1, "Dust and whole letters share one retained presentation viewport")
	var group := Node2D.new()
	outgoing.add_child(group)
	outgoing.panel(text, Rect2(0, 0, 640, 400), group)
	# Additional frame layers may rebalance the pending text capture's density.
	var original_size := text.get_size()
	outgoing.capture(source, 1 << 17)
	if OS.has_feature("ios") or OS.has_feature("android"):
		check(text.get_size().x < original_size.x, "Mobile allocation rebalances an existing pending capture")
	var complete := outgoing.capture(source, (1 << 17) | (1 << 18) | (1 << 19))
	await RenderingServer.frame_post_draw
	if not OS.has_feature("ios") and not OS.has_feature("android"):
		check(complete.get_image().get_data() == live.get_data(), "Retained commands match live styled text, IME, cursor, background and inline image pixels")
	check(cyan(complete.get_image()) > 100, "Snapshot retains the actual inline image")
	terminal.set_preedit("", Vector2i.ZERO)
	terminal.remote_feed_stream("\u001b[2J\u001b[HREPLACED LIVE CONTENT".to_utf8_buffer(), 80, 24, false, false)
	var panel: Sprite2D = outgoing.panels[0]
	check((Vector2(text.get_size()) * panel.scale).is_equal_approx(Vector2(640, 400)), "Capture allocation preserves the panel's logical geometry")
	Updates.set_visible(source, false)
	await RenderingServer.frame_post_draw
	var first := text.get_image()
	var initial := ink(first)
	check(initial > 1000, "Outgoing capture contains the complete terminal glyph layer")
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	check(source.size.x <= 2 and source.size.y <= 2 and not terminal.is_render_active(), "The inactive replica releases its live target")
	check(text.get_image().get_data() == first.get_data(), "Immutable drawing state survives release of the outgoing terminal resources")
	# Destroy the source, then force an entirely new raster from native drawing
	# commands. A retained bitmap or a shared live World2D cannot pass this.
	source.free()
	var retained: SubViewport = outgoing.captures[0]
	check(retained.terminal_view.get_class() == "TerminalSnapshotView", "Presentation owns a native drawing-state view")
	var prior := retained.size
	if not OS.has_feature("ios") and not OS.has_feature("android"):
		retained.request_extent(Vector2(prior) * 1.5)
		check(retained.size.x > prior.x, "Zoom requests a denser raster without resizing a terminal")
	else:
		retained.size = Vector2i(960, 600)
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	check(ink(text.get_image()) > 1000, "Drawing state rerasterizes after the terminal is destroyed")
	var image_view: SubViewport = outgoing.captures[2]
	image_view.size = Vector2i(960, 600)
	for i in 3: await process_frame
	await RenderingServer.frame_post_draw
	check(cyan(complete.get_image()) > 100, "Inline image ownership survives live replacement and terminal destruction")
	outgoing.free()
	for i in 3: await process_frame
	print("TERMINAL_RENDER_SNAPSHOT_PASS" if failures == 0 else "TERMINAL_RENDER_SNAPSHOT_FAIL")
	quit.call_deferred(failures)
