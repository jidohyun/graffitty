extends SceneTree
## Pi hides the hardware cursor while still moving it to its drawn input caret.
## Typing and IME must follow those moves without making the cursor visible.
var failures := 0
var strokes: Array = []

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(800, 500)
	root.add_child(terminal)
	terminal.keystroke.connect(func(cell: Vector2i, unicode: int): strokes.append([cell, unicode]))
	terminal.remote_feed("\u001b[?25h\u001b[2;3H".to_utf8_buffer(), 80, 24)
	await create_timer(0.1).timeout
	check(terminal.get_cursor_cell() == Vector2i(2, 1), "Visible cursor establishes the initial position")
	for cell in [Vector2i(9, 7), Vector2i(20, 12)]:
		terminal.remote_feed(("\u001b[?25l\u001b[%d;%dH" % [cell.y + 1, cell.x + 1]).to_utf8_buffer(), 80, 24)
		await create_timer(0.1).timeout
		check(terminal.get_cursor_cell() == Vector2i(-1, -1), "Hidden hardware cursor stays hidden")
		var key := InputEventKey.new()
		key.pressed = true
		key.keycode = KEY_A
		key.unicode = 97
		terminal.send_key(key)
		terminal.set_preedit("한", Vector2i.ZERO)
		terminal.set_preedit("", Vector2i.ZERO)
		await process_frame
		check(strokes.size() == 2, "Typing and composition each emit one effect")
		if strokes.size() == 2:
			check(strokes[0] == [cell, 97], "Typing effect follows the hidden cursor to %s" % cell)
			check(strokes[1] == [cell, "한".unicode_at(0)], "IME effect follows the hidden cursor to %s" % cell)
		strokes.clear()
	terminal.remote_feed("\u001b[?25h".to_utf8_buffer(), 80, 24)
	await create_timer(0.1).timeout
	check(terminal.get_cursor_cell() == Vector2i(20, 12), "Showing the cursor uses its latest position")
	terminal.free()
	await process_frame
	await process_frame
	if failures == 0:
		print("HIDDEN_CURSOR_TYPING_PASS")
	quit(failures)
