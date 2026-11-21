extends SceneTree

var failures := 0
var strokes: Array = []

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1

func _initialize() -> void:
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("graffitty-ime-effects-test-%d" % OS.get_process_id()))
	call_deferred("run")

func run() -> void:
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(640, 400)
	root.add_child(terminal)
	await create_timer(0.2).timeout
	terminal.keystroke.connect(func(cell: Vector2i, unicode: int): strokes.append([cell, unicode]))
	var cursor: Vector2i = terminal.get_cursor_cell()
	var before: Dictionary = terminal.get_text(false)
	for composition in ["ㅎ", "하", "한"]:
		terminal.set_preedit(composition, Vector2i.ZERO)
	terminal.set_preedit("한", Vector2i.ZERO) # Duplicate OS notification.
	terminal.set_preedit("한", Vector2i(1, 0)) # Same normalized mark.
	terminal.set_preedit("한글", Vector2i.ZERO)
	terminal.set_preedit("한글", Vector2i(0, 1)) # Moving the mark alone is not typing.
	terminal.set_preedit("", Vector2i.ZERO) # Commit/cancel cleanup is not typing.
	await create_timer(0.1).timeout
	check(strokes.size() == 4, "Each Hangul composition change emits activity; duplicates and clearing do not")
	if strokes.size() == 4:
		for i in 3:
			check(strokes[i] == [cursor, ["ㅎ", "하", "한"][i].unicode_at(0)], "Composition step %d sparks at the composing cell" % i)
		check(strokes[3] == [cursor + Vector2i(2, 0), "글".unicode_at(0)], "A preceding Hangul syllable advances the spark by two cells")
	check(terminal.get_text(false) == before, "Composition activity never sends uncommitted text to the application")
	check(terminal.remote_take_input().is_empty(), "Uncommitted composition produces no terminal input bytes")
	if OS.get_name() == "macOS":
		var committed := InputEventKey.new()
		committed.pressed = true
		committed.unicode = "글".unicode_at(0)
		var right := InputEventKey.new()
		right.pressed = true
		right.keycode = KEY_RIGHT
		terminal.send_key(committed)
		terminal.send_key(right)
		check(terminal.remote_take_input().get_string_from_utf8() == "글", "IME commit flushes without the following physical key")
		check(terminal.remote_take_input().is_empty(), "Following key waits for program output")
		terminal.remote_feed_stream("글".to_utf8_buffer(), 80, 24, false, false)
		check(terminal.remote_take_input() == PackedByteArray([27, 91, 67]), "Program output releases Right Arrow once")
		terminal.send_key(committed)
		var shortcut := InputEventKey.new()
		shortcut.pressed = true
		shortcut.keycode = KEY_S
		shortcut.ctrl_pressed = true
		terminal.send_key(shortcut)
		check(terminal.remote_take_input().get_string_from_utf8() == "글", "Custom Control chord also follows a separate commit")
		var ready_count := [0]
		terminal.input_ready.connect(func(): ready_count[0] += 1)
		await process_frame
		var ready_before: int = ready_count[0]
		terminal.set_process(false)
		await create_timer(0.2).timeout
		check(ready_count[0] > ready_before, "Timeout wakes delivery even when terminal processing is disabled")
		check(terminal.remote_take_input() == PackedByteArray([19]), "Silent program receives Control chord after bounded wait")
		terminal.send_key(committed)
		terminal.send_key(right)
		terminal.remote_take_input()
		terminal.remote_discard_input()
		await create_timer(0.2).timeout
		check(terminal.remote_take_input().is_empty(), "Discarded input cannot replay after a timeout or reconnect")
	terminal.free()
	quit.call_deferred(failures)
