extends SceneTree
## Native IME callbacks must retain modified Enter through the real key encoder.

class Ime extends "res://scenes/input/AndroidTerminalIme.gd":
	var target: Control
	func _terminal() -> Control: return target

var failures := 0

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func _initialize() -> void:
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("graffitty-ime-keys-test-%d" % OS.get_process_id()))
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
	var ime := Ime.new()
	ime.target = terminal
	ime.terminal_owner = terminal
	ime.opened = true
	# Codex requests disambiguation and alternate keys, optionally event types.
	# Also cover applications that request every key (including Enter releases).
	for flags in [5, 7, 15]:
		terminal.remote_feed_stream(("\u001b[=%du" % flags).to_utf8_buffer(), 80, 24, false, false)
		ime._native_event(0, "", "", 66, 4, 0)
		await process_frame
		var expected := "\u001b[13;2u" + ("\u001b[13;2:3u" if flags & 8 else "")
		var actual: PackedByteArray = terminal.remote_take_input()
		check(actual == expected.to_utf8_buffer(), "SwiftKey Shift+Enter remains distinct in Codex keyboard mode %d: %s" % [flags, actual.hex_encode()])
		ime._native_event(0, "", "", 66, 0, 0)
		await process_frame
		expected = "\u001b[13u\u001b[13;1:3u" if flags & 8 else "\r"
		actual = terminal.remote_take_input()
		check(actual == expected.to_utf8_buffer(), "Plain Enter stays unshifted after the chord in mode %d: %s" % [flags, actual.hex_encode()])
	terminal.remote_feed_stream("\u001b[=0u\u001b[>4;2m".to_utf8_buffer(), 80, 24, false, false)
	ime._native_event(0, "", "", 66, 4, 0)
	await process_frame
	check(terminal.remote_take_input() == "\u001b[27;2;13~".to_utf8_buffer(), "Shift+Enter retains the modifier with modifyOtherKeys too")
	ime.free()
	terminal.free()
	quit.call_deferred(failures)
