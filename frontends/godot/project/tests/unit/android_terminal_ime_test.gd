extends "res://tests/unit/test_case.gd"

class TerminalStub extends Control:
	var preview := ""
	func set_preedit(text: String, _mark: Vector2i) -> void: preview = text

class Ime extends "res://scenes/input/AndroidTerminalIme.gd":
	var target: Control
	var keys: Array = []
	func _terminal() -> Control: return target
	func _send_key(code: int, unicode: int, through_input: bool, modifiers := 0) -> void:
		keys.append([code, unicode, through_input, modifiers])
	func reset(_shortcut: bool) -> void:
		epoch += 1
		preview = ""
		target.set_preedit("", Vector2i.ZERO)

func test_native_insets_publish_changes_and_cache_the_measurement() -> void:
	var ime := Ime.new()
	var heights: Array[int] = []
	ime.keyboard_height_changed.connect(func(height): heights.append(height))
	ime._native_keyboard_height(420)
	ime._native_keyboard_height(420)
	expect(heights == [420] and ime.keyboard_height() == 420, "Repeated native insets do not trigger duplicate layout work")
	ime._native_keyboard_height(0)
	expect(heights == [420, 0] and ime.keyboard_height() == 0, "Dismissal immediately clears the cached keyboard height")
	ime.free()

func test_composition_stays_local_and_commits_once() -> void:
	var terminal := TerminalStub.new()
	var ime := Ime.new()
	ime.target = terminal
	ime.terminal_owner = terminal
	ime.opened = true
	for text in ["ㅎ", "하", "한", "한ㄱ", "한그", "한글", "한그", "한글"]:
		ime._native_event(0, "", text, 0, 0, 0)
		expect(terminal.preview == text and ime.keys.is_empty(), "Composition and consonant deletion never become PTY keys")
	ime._native_event(0, "한글 ", "", 0, 0, 0)
	expect(ime.keys.size() == 3 and ime.keys[0][1] == "한".unicode_at(0) and ime.keys[1][1] == "글".unicode_at(0), "Only completed syllables and space are dispatched")
	expect(terminal.preview.is_empty(), "Commit clears local composition")
	ime.free()
	terminal.free()

func test_finalizing_before_shortcut_rejects_stale_keyboard_callbacks() -> void:
	var terminal := TerminalStub.new()
	var ime := Ime.new()
	ime.target = terminal
	ime.terminal_owner = terminal
	ime.opened = true
	ime._native_event(0, "", "했", 0, 0, 0)
	ime.finish_composition()
	expect(ime.keys == [[0, "했".unicode_at(0), false, 0]], "Accessory key finalizes composition without applying its new modifier")
	ime._native_event(0, "했", "c", 0, 0, 0)
	expect(ime.keys.size() == 1 and ime.preview.is_empty(), "Old native connection cannot recommit text or queue a shortcut letter")
	ime.target = null
	ime._native_event(ime.epoch, "wrong pane", "", 0, 0, 0)
	expect(ime.keys.size() == 1, "Composition cannot cross into a different focused pane")
	ime.free()
	terminal.free()

func test_native_hardware_chords_preserve_modifiers() -> void:
	var terminal := TerminalStub.new()
	var ime := Ime.new()
	ime.target = terminal
	ime.terminal_owner = terminal
	ime.opened = true
	ime._native_event(0, "", "", 70, 5, 61)
	ime._native_event(0, "", "", 21, 2, 0)
	ime._native_event(0, "", "", 21, 4, 0)
	ime._native_event(0, "", "", 66, 4, 0)
	expect(ime.keys == [[KEY_EQUAL, 61, true, 5], [KEY_LEFT, 0, true, 2], [KEY_LEFT, 0, true, 4], [KEY_ENTER, 0, true, 4]], "Ctrl+Shift+Equal, Alt+Left, SwiftKey Shift+Left and Shift+Enter retain modifiers across the native editor")
	ime.free()
	terminal.free()
