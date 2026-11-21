extends SceneTree
## GPU checks for s: neutral backdrop, original match ink, and no-match restore.
var failures := 0
var terminal: Control
var cell_size: Vector2
const EVIDENCE := "/tmp/graffitty-copy-flash-validation"


func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func keys(text: String) -> void:
	for c in text:
		var event := InputEventKey.new()
		event.unicode = c.unicode_at(0)
		event.pressed = true
		terminal.send_key(event)
		event.pressed = false
		terminal.send_key(event)
	await process_frame
	await process_frame


func frame(name: String) -> Image:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image()
	result.save_png(EVIDENCE.path_join(name + ".png"))
	return result


func colored_pixels(image: Image, row: int, channel: int) -> int:
	var total := 0
	for y in range(int(row * cell_size.y), mini(image.get_height(), int((row + 1) * cell_size.y))):
		for x in range(mini(image.get_width(), int(cell_size.x * 8))):
			var color := image.get_pixel(x, y)
			var channels := [color.r, color.g, color.b]
			if channels[channel] > 0.6 and channels[channel] > channels[(channel + 1) % 3] * 1.4 and channels[channel] > channels[(channel + 2) % 3] * 1.4:
				total += 1
	return total


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Flash pixel checks require a real renderer")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(EVIDENCE)
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.cell_padding = 0
	terminal.size = Vector2(800, 300)
	root.add_child(terminal)
	var config := preload("res://graffitty/terminal_config.gd").new()
	config.font_size = 24
	config.background.color = Color.BLACK
	config.background.alpha = 1.0
	config.cursor_blink = "off"
	config.apply_live(terminal)
	await process_frame
	await process_frame
	terminal.remote_feed_stream(("\u001b[38;2;255;40;40mneedle\r\n" +
		"\u001b[38;2;40;255;40mhaystack\r\n" +
		"\u001b[38;2;40;40;255mneedle\u001b[0m\r\n").to_utf8_buffer(), 40, 6, false, false)
	var original := await frame("original")
	cell_size = terminal.get_cell_size()
	for channel in 3:
		check(colored_pixels(original, channel, channel) > 10, "Original row %d has its ANSI color" % channel)
	terminal.perform_action("copy_mode")
	await keys("s")
	var dimmed := await frame("dimmed")
	for channel in 3:
		check(colored_pixels(dimmed, channel, channel) == 0, "s removes color from row %d before typing" % channel)
	await keys("needle")
	var matches := await frame("matches")
	check(colored_pixels(matches, 0, 0) > 10, "First match retains red ink")
	check(colored_pixels(matches, 1, 1) == 0, "Nonmatching green text stays gray")
	check(colored_pixels(matches, 2, 2) > 10, "Second match retains blue ink")
	for row in [0, 2]:
		var ink := Color8(255, 40, 40) if row == 0 else Color8(40, 40, 255)
		var background := matches.get_pixel(int(cell_size.x / 2), int((row + 1) * cell_size.y) - 1)
		var ink_luminance := ink.srgb_to_linear().get_luminance()
		var bg_luminance := background.srgb_to_linear().get_luminance()
		var contrast := (maxf(ink_luminance, bg_luminance) + 0.05) / (minf(ink_luminance, bg_luminance) + 0.05)
		check(contrast > 4.5, "Match row %d keeps readable contrast" % row)
	check(terminal.get_ui_state().copy_labels.size() == 2, "Both matches have distinct jump labels")
	await keys("!")
	check(terminal.get_ui_state().modal == "copy_mode" and not terminal.get_ui_state().flash_active, "No match immediately exits Flash")
	var restored := await frame("no-match")
	for channel in 3:
		check(colored_pixels(restored, channel, channel) > 10, "No match restores row %d's original color" % channel)
	terminal.queue_free()
	await process_frame
	quit(1 if failures else 0)
