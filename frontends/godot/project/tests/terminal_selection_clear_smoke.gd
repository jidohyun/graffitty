extends SceneTree
## Real-renderer regression for stale mouse selections in the scrolled viewport.
var failures := 0
var terminal: Control
var cell_size: Vector2
var evidence: String


func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func frame(name: String) -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image()
	result.save_png(evidence.path_join(name + ".png"))
	return result


func point(col: float, row: float) -> Vector2:
	return Vector2(col * cell_size.x, row * cell_size.y)


func button(at: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = at
	root.push_input(event, true)
	await process_frame


func drag(from: Vector2, to: Vector2) -> void:
	# Keep separate gestures outside the double/triple-click interval.
	await create_timer(0.6).timeout
	await button(from, true)
	var event := InputEventMouseMotion.new()
	event.position = to
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(event, true)
	await process_frame
	await button(to, false)


func selected_pixels(image: Image) -> int:
	var count := 0
	for y in mini(image.get_height(), int(terminal.size.y)):
		for x in mini(image.get_width(), int(terminal.size.x)):
			var c := image.get_pixel(x, y)
			if c.r > 0.5 and c.b > 0.5 and c.g < 0.25:
				count += 1
	return count


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Selection pixel checks require a real renderer")
		quit(1)
		return
	evidence = OS.get_environment("GRAFFITTY_SELECTION_EVIDENCE")
	if evidence.is_empty():
		evidence = OS.get_cache_dir().path_join("graffitty-selection-clear")
	DirAccess.make_dir_recursive_absolute(evidence)
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.cell_padding = 0
	terminal.size = Vector2(600, 260)
	root.add_child(terminal)
	await process_frame
	await process_frame
	var config := preload("res://graffitty/terminal_config.gd").new()
	config.font_size = 24
	config.background.color = Color.BLACK
	config.background.alpha = 1.0
	config.cursor_blink = "off"
	config.copy_on_select = "none"
	config.selection_background = Color.MAGENTA
	config.selection_foreground = Color.WHITE
	config.apply_to(terminal)
	await process_frame
	await process_frame
	var grid: Vector2i = terminal.get_grid_size()
	var text := "\u001b[?25l"
	for i in 60:
		text += "line %02d abcdefghijklmnopqrstuvwxyz\r\n" % i
	terminal.remote_feed_stream(text.to_utf8_buffer(), grid.x, grid.y, false, false)
	cell_size = terminal.get_cell_size()
	for scroll in [5.0, 5.5]:
		terminal.scroll_to_position(scroll)
		var prefix := str(scroll).replace(".", "-")
		check(selected_pixels(await frame(prefix + "-initial")) == 0, "No selection before drag at scroll %s" % scroll)
		# Include the extra bottom row exposed by a partial cell or scroll offset.
		await drag(point(3.2, 1.5), Vector2(cell_size.x * 18.8, terminal.size.y - 1))
		check(selected_pixels(await frame(prefix + "-selected")) > 1000, "Drag highlights multiple rows at scroll %s" % scroll)
		await drag(point(2.2, 1.5), point(5.8, 1.5))
		var smaller := await frame(prefix + "-smaller")
		var count := selected_pixels(smaller)
		check(count > 0 and count < int(cell_size.x * cell_size.y * 5), "New short selection replaces all previous rows at scroll %s (%d pixels)" % [scroll, count])
		await create_timer(0.6).timeout
		await button(point(25.5, 0.5), true)
		await button(point(25.5, 0.5), false)
		check(selected_pixels(await frame(prefix + "-cleared")) == 0, "Click clears every highlighted pixel at scroll %s" % scroll)
	terminal.queue_free()
	await process_frame
	quit(1 if failures else 0)
