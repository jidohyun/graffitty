extends SceneTree
## Real libghostty state -> production Rust paint pass -> published cell bounds.
var failures := 0
var terminal: Control

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print(("PASS " if ok else "FAIL ") + label)
	if not ok: failures += 1

func feed(text: String, cols := 80, rows := 24) -> Dictionary:
	terminal.remote_feed_stream(text.to_utf8_buffer(), cols, rows, false, false)
	for i in 4: await process_frame
	return terminal.get_visible_area()

func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1000, 700)
	root.add_child(viewport)
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(1000, 700)
	viewport.add_child(terminal)
	var area := await feed("\u001b[2J\u001b[H")
	check(not area.has("text") and not area.has("content"), "Blank viewport has no occupied content")
	check(area.get("cursor") == Rect2i(0, 0, 1, 1), "Blank viewport retains cursor context")
	area = await feed("\u001b[3;5Hhi")
	check(area.get("text") == Rect2i(4, 2, 2, 1), "Sparse text uses exact cell bounds")
	var generation: int = area.get("generation", -1)
	area = await feed("\u001b[3;5Hhi")
	check(area.get("generation") == generation, "Identical redraw does not change bounds generation")
	area = await feed("\u001b[4;9H界")
	check(area.get("text") == Rect2i(4, 2, 6, 2), "Wide glyph includes both columns")
	area = await feed("\u001b[2J\u001b[H   ")
	check(not area.has("text"), "Plain whitespace is not text ink")
	area = await feed("\u001b[2J\u001b[H\u001b[41m  \u001b[0m")
	check(not area.has("text") and area.get("content") == Rect2i(0, 0, 2, 1), "Colored blank cells contribute content but not text")
	area = await feed("\u001b[2J\u001b[H\u001b[8msecret\u001b[0m")
	check(not area.has("text"), "Concealed glyphs do not inflate ink bounds")
	area = await feed("\u001b[2J\u001b[H\u001b[5mblink\u001b[0m")
	check(area.get("text") == Rect2i(0, 0, 5, 1), "Blinking text retains a stable footprint")
	area = await feed("\u001b[?1049h\u001b[2J\u001b[Halt")
	check(area.get("text") == Rect2i(0, 0, 3, 1), "Alternate screen replaces old bounds")
	area = await feed("\u001b[?1049l")
	check(area.get("text") == Rect2i(0, 0, 5, 1), "Returning from alternate screen restores visible content")
	area = await feed("\u001b[2J\u001b[H", 20, 10)
	check(area.get("grid") == Vector2i(20, 10) and not area.has("content"), "Resize and erase cannot retain old bounds")
	viewport.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
