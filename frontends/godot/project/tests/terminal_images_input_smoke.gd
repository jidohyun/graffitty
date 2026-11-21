extends SceneTree
## Exercise the real terminal adapter; works headless, with optional GPU checks.
var failures := 0
var terminal: Control

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1

func feed(text: String, reset := false) -> void:
	terminal.remote_feed_stream(text.to_utf8_buffer(), 20, 10, reset, false)

func rendered() -> Image:
	for _frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func changed_pixels(before: Image, after: Image) -> int:
	var count := 0
	for y in mini(before.get_height(), after.get_height()):
		for x in mini(before.get_width(), after.get_width()):
			var a := before.get_pixel(x, y)
			var b := after.get_pixel(x, y)
			if absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b) > 0.02:
				count += 1
	return count

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	run.call_deferred()

func run() -> void:
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(640, 400)
	root.add_child(terminal)
	await process_frame
	await process_frame
	feed("\u001b_Ga=T,f=32,s=1,v=1,i=42,p=7,U=1,c=4,r=2,q=2;/wAA/w==\u001b\\", true)
	feed("\u001b[?25l")
	var graphical := DisplayServer.get_name() != "headless"
	var blank: Image = await rendered() if graphical else null
	check(terminal.image_placements().is_empty(), "Virtual image waits for placeholder cells")
	var mark := String.chr(0x10eeee)
	var row0 := mark + String.chr(0x305) + String.chr(0x305)
	var row1 := mark + String.chr(0x30d) + String.chr(0x305)
	feed("\u001b[38;2;0;0;42m\u001b[58;2;0;0;7m" + row0 + mark.repeat(3) + "\r\n" + row1 + mark.repeat(3) + "\u001b[0m")
	check(terminal.image_placements().size() == 2, "Placeholder rows render image strips")
	if graphical:
		check(changed_pixels(blank, await rendered()) > 100, "GPU paints placeholder image pixels")
	feed("\u001b[?1049h")
	check(terminal.image_placements().is_empty(), "Primary images stay out of alternate screen")
	feed("\u001b[?1049l")
	check(terminal.image_placements().size() == 2, "Primary placeholders return after alternate screen")
	feed("\u001b[1;1H\u001b[2K\u001b[2;1H\u001b[2K")
	check(terminal.image_placements().is_empty(), "fzf line erasure removes placeholder previews")
	if graphical:
		check(changed_pixels(blank, await rendered()) == 0, "GPU clears all preview pixels and placeholder glyphs")
		feed("\u001b[1;1H\u001b[38;2;0;0;42m" + row0 + mark.repeat(3) + "\u001b[0m\u001b_Ga=d,d=I,i=42,q=2;\u001b\\")
		check(changed_pixels(blank, await rendered()) == 0, "Deleted image placeholders never become font glyphs")
	feed("\u001b[3;4H\u001bP0;1q\"1;1;2;6#1;2;100;0;0!2~\u001b\\", true)
	check(terminal.image_placements().size() == 1, "Sixel preview appears")
	feed("\u001b[3;1H\u001b[2K")
	check(terminal.image_placements().is_empty(), "fzf line erasure removes Sixel preview")
	terminal.remote_take_input()
	for spec in [[KEY_B, 98, false, "\u001bb"], [KEY_F, 102, false, "\u001bf"], [KEY_B, 66, true, "\u001bB"]]:
		var event := InputEventKey.new()
		event.keycode = spec[0]
		event.key_label = spec[0]
		event.unicode = spec[1]
		event.pressed = true
		event.alt_pressed = true
		event.shift_pressed = spec[2]
		terminal.send_key(event)
		check(terminal.remote_take_input().get_string_from_utf8() == spec[3], "Alt shortcut sends terminal bytes: " + str(spec[0]))
	terminal.free()
	await process_frame
	print("TERMINAL_IMAGES_INPUT_PASS" if failures == 0 else "TERMINAL_IMAGES_INPUT_FAIL")
	quit(failures)
