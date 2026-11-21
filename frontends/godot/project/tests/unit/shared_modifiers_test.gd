extends "res://tests/unit/test_case.gd"

class TerminalStub extends Control:
	var keys: Array[InputEventKey] = []
	func set_preedit(_text: String, _mark: Vector2i) -> void: pass
	func send_key(event: InputEventKey) -> void: keys.append(event.duplicate())

class Ime extends "res://scenes/input/AndroidTerminalIme.gd":
	var target: Control
	var bar: Control
	var keys: Array[InputEventKey] = []
	func _terminal() -> Control: return target
	func _modifier_bar() -> Control: return bar
	func _dispatch_shared_key(event: InputEventKey) -> void:
		bar.apply_modifiers(event)
		keys.append(event.duplicate())

func test_shared_shift_survives_entire_hold_then_is_consumed() -> void:
	var terminal := TerminalStub.new()
	var ime := Ime.new()
	var bar := preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.terminal_ime = ime
	ime.target = terminal
	ime.terminal_owner = terminal
	ime.bar = bar
	ime.opened = true
	ime._native_modifier_command(0, "keyboard", 1, "hello", 0)
	# The keyboard's Shift selection changes the same toolbar state.
	ime._native_modifier_command(0, "keyboard", 2, "cycle", 4)
	expect(bar.modifier_masks() == Vector2i(4, 0), "Keyboard Shift arms Graffitty's toolbar")
	# Finishing a pre-existing Hangul syllable must leave Shift for the arrow.
	ime._native_event(0, "한", "", 0, 0, 0, true)
	expect(terminal.keys.size() == 2 and not terminal.keys[0].shift_pressed and bar.modifier_masks().x == 4, "Composition commits before the chord without consuming its Shift")
	ime._native_shared_key(0, "keyboard", 3, 21, 0, 0, 1)
	for index in 50: ime._native_shared_key(0, "keyboard", 4 + index, 21, 0, 0, 2)
	ime._native_shared_key(0, "keyboard", 54, 21, 0, 0, 3)
	expect(ime.keys.size() == 52 and ime.keys.all(func(key): return key.shift_pressed), "Every repeat and the release retain the captured one-shot Shift")
	expect(bar.pressed_keys.is_empty() and bar.modifier_masks() == Vector2i.ZERO, "Release clears tracking and spends the one-shot selection")
	ime._native_shared_key(0, "keyboard", 55, 21, 0, 0, 1)
	ime._native_shared_key(0, "keyboard", 56, 21, 0, 0, 3)
	expect(not ime.keys[-2].shift_pressed and not ime.keys[-1].shift_pressed, "The next arrow is unshifted")
	bar.free(); ime.free(); terminal.free()

func test_shortcuts_preserve_physical_key_and_shifted_punctuation_text() -> void:
	var terminal := TerminalStub.new()
	var ime := Ime.new()
	var bar := preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.terminal_ime = ime
	ime.target = terminal; ime.terminal_owner = terminal; ime.bar = bar; ime.opened = true
	ime._native_modifier_command(0, "keyboard", 1, "hello", 0)
	ime._native_shared_key(0, "keyboard", 2, 8, 4, "!".unicode_at(0), 1)
	ime._native_shared_key(0, "keyboard", 3, 8, 4, "!".unicode_at(0), 3)
	expect(ime.keys[0].keycode == KEY_1 and ime.keys[0].unicode == "!".unicode_at(0) and ime.keys[0].shift_pressed, "Shifted punctuation retains the physical base key and produced character")
	ime._native_modifier_command(0, "keyboard", 4, "cycle", 1)
	ime._native_modifier_command(0, "keyboard", 5, "cycle", 4)
	ime._native_shared_key(0, "keyboard", 6, 49, 0, "u".unicode_at(0), 1)
	ime._native_shared_key(0, "keyboard", 7, 49, 0, "u".unicode_at(0), 3)
	expect(ime.keys[-2].keycode == KEY_U and ime.keys[-2].ctrl_pressed and ime.keys[-2].shift_pressed, "Combined toolbar and keyboard modifiers reach the letter")
	expect(ime.keys[-1].ctrl_pressed and ime.keys[-1].shift_pressed, "The release retains both modifiers")
	bar.free(); ime.free(); terminal.free()

func test_keyboard_modifiers_work_when_accessory_bar_is_hidden() -> void:
	var terminal := TerminalStub.new()
	var ime := Ime.new()
	var bar := preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.terminal_ime = ime
	bar.hide()
	ime.target = terminal; ime.terminal_owner = terminal; ime.bar = bar; ime.opened = true
	ime._native_modifier_command(0, "keyboard", 1, "hello", 0)
	ime._native_modifier_command(0, "keyboard", 2, "cycle", 1)
	ime._native_shared_key(0, "keyboard", 3, 29, 0, "a".unicode_at(0), 1)
	ime._native_shared_key(0, "keyboard", 4, 29, 0, "a".unicode_at(0), 3)
	expect(ime.keys.size() == 2 and ime.keys.all(func(key): return key.ctrl_pressed), "Keyboard Ctrl applies even with Graffitty's accessory bar hidden")
	expect(bar.modifier_masks() == Vector2i.ZERO, "Hidden shared one-shot is consumed")
	bar.free(); ime.free(); terminal.free()

func test_toolbar_lock_and_keyboard_edits_share_state_and_reject_old_sessions() -> void:
	var terminal := TerminalStub.new()
	var ime := Ime.new()
	var bar := preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.terminal_ime = ime
	ime.target = terminal; ime.terminal_owner = terminal; ime.bar = bar; ime.opened = true
	ime._native_modifier_command(0, "current", 1, "hello", 0)
	# A real toolbar selection is visible to subsequent keyboard commands.
	bar.cycle_modifier("shift")
	ime._native_modifier_command(0, "current", 2, "cycle", 4)
	expect(bar.modifier_masks() == Vector2i(4, 4), "Tapping Shift in the other UI locks the existing selection")
	for index in 3:
		ime._native_shared_key(0, "current", 3 + index * 2, 22, 0, 0, 1)
		ime._native_shared_key(0, "current", 4 + index * 2, 22, 0, 0, 3)
	expect(ime.keys.all(func(key): return key.shift_pressed) and bar.modifier_masks() == Vector2i(4, 4), "Toolbar lock survives distinct keyboard gestures")
	ime._native_modifier_command(0, "old", 100, "cycle", 4)
	ime._native_shared_key(1, "current", 100, 21, 0, 0, 1)
	expect(bar.modifier_masks() == Vector2i(4, 4) and ime.keys.size() == 6, "Stale peers and editor generations cannot mutate input")
	ime._native_modifier_command(0, "current", 9, "bye", 0)
	expect(ime._modifier_session.is_empty() and bar.modifier_masks() == Vector2i(4, 4), "Editor replacement detaches the peer while preserving the toolbar selection")
	ime._native_modifier_command(0, "replacement", 1, "hello", 0)
	ime._native_modifier_command(0, "replacement", 2, "cycle", 4)
	expect(bar.modifier_masks() == Vector2i.ZERO, "Replacement keyboard cycles the preserved toolbar lock off")
	bar.free(); ime.free(); terminal.free()
