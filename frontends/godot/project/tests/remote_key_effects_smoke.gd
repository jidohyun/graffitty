extends SceneTree
const ARROWS := {KEY_LEFT: "D", KEY_RIGHT: "C", KEY_UP: "A", KEY_DOWN: "B"}
var strokes: Array = []
var pulses := 0
func _initialize() -> void:
	# Exercise default input encoding without retaining personal menu callbacks.
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("graffitty-effects-test-%d" % OS.get_process_id()))
	run.call_deferred()
func run() -> void:
	var terminal: Control = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.use_custom_key_bindings = true
	terminal.size = Vector2(640, 400)
	root.add_child(terminal)
	terminal.grab_focus()
	await process_frame
	await process_frame
	terminal.remote_feed_stream("prompt> ".to_utf8_buffer(), 80, 24, true, false)
	await process_frame
	await process_frame
	var effects := preload("res://scenes/TerminalEffects2D.gd").new()
	root.add_child(effects)
	effects.config.set_option("state.typing", "typing.particles", "sparks")
	effects.bind_terminal(terminal, null, func(uv): return uv * Vector2(640, 400), func(point): return point)
	effects.typed.connect(func(_uv): pulses += 1)
	terminal.keystroke.connect(func(cell, unicode): strokes.append([cell, unicode]))
	for code in [KEY_TAB, KEY_ESCAPE]:
		var key := InputEventKey.new()
		key.keycode = code
		key.pressed = true
		terminal.send_key(key)
		key.pressed = false
		terminal.send_key(key)
	await process_frame
	await process_frame
	var ok: bool = pulses == 2 and effects.burst_count == 2 and strokes.size() == 2 and terminal.remote_take_input() == PackedByteArray([9, 27])
	for stroke in strokes:
		ok = ok and stroke[0] == Vector2i(8, 0) and stroke[1] == 0
	# Android's key bar calls send_key; desktop/hardware keys use GUI input.
	# Plain, modified and held arrows must still encode in both cursor modes,
	# but none of them count as typing activity.
	var arrow_bytes := PackedByteArray()
	var expected_arrows := ""
	for desktop in [false, true]:
		for application in [false, true]:
			terminal.remote_feed_stream(("\u001b[?1h" if application else "\u001b[?1l").to_utf8_buffer(), 80, 24, false, false)
			for ctrl in [false, true]:
				for code in ARROWS:
					var suffix: String = ARROWS[code]
					var encoded := "\u001b" + ("[1;5" if ctrl else ("O" if application else "[")) + suffix
					expected_arrows += encoded.repeat(2)
					for action in ["press", "repeat", "release"]:
						var key := InputEventKey.new()
						key.keycode = code
						key.ctrl_pressed = ctrl
						key.pressed = action != "release"
						key.echo = action == "repeat"
						if desktop: root.push_input(key)
						else: terminal.send_key(key)
					arrow_bytes.append_array(terminal.remote_take_input())
	await process_frame
	await process_frame
	ok = ok and pulses == 2 and effects.burst_count == 2 and strokes.size() == 2
	ok = ok and arrow_bytes == expected_arrows.to_utf8_buffer()
	print("ARROW_KEY_EFFECTS_PASS" if ok else "ARROW_KEY_EFFECTS_FAIL " + str({"strokes": strokes.size(), "pulses": pulses, "bursts": effects.burst_count, "bytes_match": arrow_bytes == expected_arrows.to_utf8_buffer()}))
	# Navigation must deliver identical terminal bytes without exciting either
	# the typing-camera signal or particles, including repeated presses.
	for code in [KEY_H, KEY_J, KEY_K, KEY_L]:
		var key := InputEventKey.new()
		key.keycode = code
		key.ctrl_pressed = true
		key.pressed = true
		terminal.send_key(key, false)
		key.echo = true
		terminal.send_key(key, false)
		key.pressed = false
		key.echo = false
		terminal.send_key(key, false)
	await process_frame
	await process_frame
	ok = ok and pulses == 2 and effects.burst_count == 2 and strokes.size() == 2
	var navigation_bytes: PackedByteArray = terminal.remote_take_input()
	ok = ok and navigation_bytes == PackedByteArray([8,8,10,10,11,11,12,12])
	# Explicit literal delivery and ordinary typing retain effects afterwards.
	var literal := InputEventKey.new()
	literal.keycode = KEY_H
	literal.ctrl_pressed = true
	literal.pressed = true
	terminal.send_key(literal, true)
	var letter := InputEventKey.new()
	letter.keycode = KEY_A
	letter.unicode = 97
	letter.pressed = true
	terminal.send_key(letter)
	await process_frame
	await process_frame
	ok = ok and pulses == 4 and effects.burst_count == 4 and strokes.size() == 4
	var typing_bytes: PackedByteArray = terminal.remote_take_input()
	ok = ok and typing_bytes == PackedByteArray([8,97])
	# Kitty applications receive releases too. Those are never typing, and
	# arrows remain silent while ordinary presses/repeats retain their effects.
	terminal.remote_feed_stream("\u001b[?1l\u001b[>3u".to_utf8_buffer(), 80, 24, false, false)
	for desktop in [false, true]:
		for code in [KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_A]:
			for action in ["press", "repeat", "release"]:
				var key := InputEventKey.new()
				key.keycode = code
				key.unicode = 97 if code == KEY_A and action != "release" else 0
				key.pressed = action != "release"
				key.echo = action == "repeat"
				if desktop: root.push_input(key)
				else: terminal.send_key(key)
				var bytes: PackedByteArray = terminal.remote_take_input()
				ok = ok and not bytes.is_empty()
	await process_frame
	await process_frame
	ok = ok and pulses == 8 and effects.burst_count == 8 and strokes.size() == 8
	print("REMOTE_KEY_EFFECTS_PASS" if ok else "REMOTE_KEY_EFFECTS_FAIL " + str([strokes, pulses, effects.burst_count, navigation_bytes, typing_bytes]))
	effects.free()
	terminal.free()
	quit.call_deferred(0 if ok else 1)
