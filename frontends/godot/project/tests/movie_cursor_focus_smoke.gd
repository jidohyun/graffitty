extends SceneTree
## Pixel check: a hidden recording window paints only its focused pane as active.
var failures := 0
var terminals: Array[Control] = []

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func _initialize() -> void:
	root.unfocusable = true
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()

func frame() -> Image:
	for i in 4: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func cursor_center(image: Image, terminal: Control) -> Color:
	var point: Vector2 = terminal.global_position + terminal.get_cursor_anchor_local()
	point += terminal.get_cell_size() * Vector2(.5, -.5)
	point *= Vector2(image.get_size()) / root.get_visible_rect().size
	return image.get_pixelv(Vector2i(point))

func run() -> void:
	var movie := "--expect-movie-focus" in OS.get_cmdline_user_args()
	for i in 2:
		var terminal: Control = ClassDB.instantiate("Terminal")
		terminal.remote_mode = true
		terminal.position = Vector2(20 + i * 240, 30)
		terminal.size = Vector2(220, 180)
		terminal.configure_advanced({"cursor_blink": 0})
		root.add_child(terminal)
		terminal.set_colors(Color.BLACK, Color.WHITE, Color.WHITE, PackedColorArray())
		terminal.remote_feed("\u001b[2J\u001b[H\u001b[2 q\u001b[?25h".to_utf8_buffer(), 20, 8)
		terminals.append(terminal)
	terminals[0].grab_focus()
	var image := await frame()
	check(not root.has_focus(), "Test never takes native window focus")
	check(terminals[0].has_focus(), "First terminal owns control focus")
	check((cursor_center(image, terminals[0]).r > .8) == movie,
		"Focused cursor is filled only in the Movie Maker foreground")
	check(cursor_center(image, terminals[1]).r < .2, "Inactive pane cursor stays hollow")
	terminals[1].grab_focus()
	image = await frame()
	check(cursor_center(image, terminals[0]).r < .2, "Previous pane becomes hollow after focus moves")
	check((cursor_center(image, terminals[1]).r > .8) == movie, "Cursor appearance follows control focus")
	terminals[1].remote_feed("\u001b[6 q".to_utf8_buffer(), 20, 8)
	image = await frame()
	var rect: Rect2 = terminals[1].get_cursor_render_info().rect
	check((rect.size.x < .5) == movie, "Movie cursor respects the application's bar shape")
	for terminal in terminals: terminal.free()
	terminals.clear()
	for i in 4: await process_frame
	# Allow the native guard to sample this short test at least ten times.
	var guard_until := Time.get_ticks_msec() + 400
	while Time.get_ticks_msec() < guard_until: await process_frame
	print("MOVIE_CURSOR_FOCUS_PASS" if failures == 0 else "MOVIE_CURSOR_FOCUS_FAIL")
	quit(failures)
