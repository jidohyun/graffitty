extends "res://tests/unit/test_case.gd"
const KeyBar := preload("res://scenes/input/TouchKeyBar.gd")
const Prefix := preload("res://scenes/WorkspacePrefix.gd")
const Settings := preload("res://graffitty/config.gd")

class Host extends Node:
	signal ui_changed
	var active_session_id := 1
	var created := 0
	var opened: Array[String] = []
	var tab_steps: Array[int] = []
	var pane_focus := "%1"
	var sessions := {}
	func command_line_open() -> bool: return false
	func is_terminal_pane(key: String) -> bool: return key.begins_with("%")
	func select_next_workspace(step: int) -> void:
		tab_steps.append(step)
	func create_session() -> void:
		created += 1
	func open_command_line(text := "") -> void:
		opened.append(text)

func ime_key(character: String, missing_code: int, down := true) -> InputEventKey:
	var event := InputEventKey.new()
	event.unicode = character.unicode_at(0)
	event.keycode = missing_code
	event.physical_keycode = missing_code
	event.pressed = down
	return event

class BufferedKeyBar extends KeyBar:
	var ime_buffer := ""
	var resets := 0
	func reset_keyboard_buffer() -> void:
		ime_buffer = ""
		resets += 1

func test_ctrl_c_clears_ime_text_before_and_after_shortcut() -> void:
	var bar := BufferedKeyBar.new()
	bar.show()
	bar.ime_buffer = "previous command"
	bar.cycle_modifier("ctrl")
	expect(bar.ime_buffer.is_empty(), "Arming Ctrl drops prior IME composition before it can replace text")
	bar.ime_buffer = "c"
	var interrupt := ime_key("c", KEY_UNKNOWN)
	bar.apply_modifiers(interrupt)
	expect(interrupt.ctrl_pressed and interrupt.keycode == KEY_C, "The shortcut is delivered as Ctrl+C")
	expect(bar.ime_buffer.is_empty() and bar.resets == 2, "The consumed C is removed from the keyboard buffer")
	var release := ime_key("c", KEY_UNKNOWN, false)
	bar.apply_modifiers(release)
	expect(release.ctrl_pressed and bar.resets == 2, "Release preserves Ctrl without another buffer reset")
	var next := ime_key("x", KEY_UNKNOWN)
	bar.apply_modifiers(next)
	expect(not next.ctrl_pressed and next.unicode == 120 and bar.resets == 2, "Ordinary typing after the shortcut is untouched")
	bar.free()

func test_android_ctrl_a_and_ime_prefix_command() -> void:
	for missing_code in [KEY_NONE, KEY_UNKNOWN]:
		var host := Host.new()
		var bar := KeyBar.new()
		bar.host = host
		bar.show()
		bar.update_host()
		var prefix := Prefix.new()
		prefix.host = host
		prefix.settings = Settings.PrefixSettings.new()
		prefix.settings.key = KEY_A | KEY_MASK_CTRL
		bar.modifiers.ctrl = true
		var trigger := ime_key("a", missing_code)
		bar.apply_modifiers(trigger)
		expect(prefix.handle(trigger) and prefix.active, "On-screen Ctrl plus IME A arms the prefix (%d)" % missing_code)
		expect(bar.modifiers.is_empty(), "On-screen Ctrl is consumed once")
		var release := ime_key("a", missing_code, false)
		bar.apply_modifiers(release)
		expect(prefix.handle(release) and prefix.active, "IME trigger release leaves prefix armed")
		var command := ime_key("c", missing_code)
		bar.apply_modifiers(command)
		expect(not command.ctrl_pressed, "The following command does not inherit Ctrl")
		expect(prefix.handle(command) and not prefix.active and host.created == 1, "IME C executes New Tab exactly once")
		bar.free()
		host.free()

func test_android_ime_prefix_without_key_releases() -> void:
	var host := Host.new()
	var bar := KeyBar.new()
	bar.host = host
	bar.show()
	bar.update_host()
	var prefix := Prefix.new()
	prefix.host = host
	prefix.settings = Settings.PrefixSettings.new()
	prefix.settings.key = KEY_A | KEY_MASK_CTRL
	for unused in 2:
		bar.modifiers.ctrl = true
		var trigger := ime_key("a", KEY_UNKNOWN)
		bar.apply_modifiers(trigger)
		expect(prefix.handle(trigger) and prefix.active, "IME can arm prefix without an earlier key release")
		var number := ime_key("1", KEY_UNKNOWN)
		bar.apply_modifiers(number)
		expect(prefix.handle(number) and not prefix.active, "IME digit opens numeric navigation")
	expect(host.opened == ["1", "1"], "Repeated sequences each reach the command line")
	bar.free()
	host.free()

func test_accessory_modifiers_combine_for_one_key_and_its_release() -> void:
	var bar := KeyBar.new()
	bar._ready()
	bar.show()
	for key in ["ctrl", "alt", "shift"]: bar.buttons[key].button_pressed = true
	var press := ime_key("u", KEY_UNKNOWN)
	bar.apply_modifiers(press)
	expect(press.ctrl_pressed and press.alt_pressed and press.shift_pressed and press.unicode == 85, "All three one-shot modifiers combine on the same character")
	expect(bar.modifiers.is_empty(), "All one-shot modifiers are consumed together")
	for key in ["ctrl", "alt", "shift"]:
		expect(not bar.buttons[key].button_pressed, key + " loses its highlight after the key")
	var release := ime_key("u", KEY_UNKNOWN, false)
	bar.apply_modifiers(release)
	expect(release.ctrl_pressed and release.alt_pressed and release.shift_pressed and release.unicode == 85, "Release retains the modifiers from its matching press")
	var next := ime_key("u", KEY_UNKNOWN)
	bar.apply_modifiers(next)
	expect(not next.ctrl_pressed and not next.alt_pressed and not next.shift_pressed and next.unicode == 117, "The next character is unmodified")
	bar.free()

func test_locked_ctrl_survives_input_and_combines_with_one_shot_alt_shift() -> void:
	var bar := KeyBar.new()
	bar._ready()
	bar.show()
	bar.buttons.ctrl.button_pressed = true
	var face := func(key: String) -> Dictionary: return bar.buttons[key].get_node("Face").get_meta(&"face_props")
	expect(not face.call("ctrl").locked, "One tap highlights Ctrl without bold lock styling")
	bar.buttons.ctrl.button_pressed = false # Second tap is immediately kept pressed.
	expect(bar.buttons.ctrl.button_pressed and bar.locked_modifiers.get("ctrl", false), "Second tap locks Ctrl")
	expect(face.call("ctrl").locked, "Locked Ctrl's face is drawn locked (bold, lock color)")
	bar.buttons.alt.button_pressed = true
	bar.buttons.shift.button_pressed = true
	var first := ime_key("u", KEY_UNKNOWN)
	bar.apply_modifiers(first)
	expect(first.ctrl_pressed and first.alt_pressed and first.shift_pressed, "A locked modifier combines with the other one-shot modifiers")
	for unused in 2:
		var next := ime_key("u", KEY_UNKNOWN) # IME presses can omit releases.
		bar.apply_modifiers(next)
		expect(next.ctrl_pressed and not next.alt_pressed and not next.shift_pressed, "Only locked Ctrl persists across subsequent inputs")
	bar.buttons.ctrl.button_pressed = false
	expect(bar.modifiers.is_empty() and bar.locked_modifiers.is_empty() and not face.call("ctrl").locked, "Third tap releases Ctrl and removes lock styling")
	var release := ime_key("u", KEY_UNKNOWN, false)
	bar.apply_modifiers(release)
	expect(release.ctrl_pressed, "Unlocking does not change the modifier on an already pressed key's release")
	var plain := ime_key("u", KEY_UNKNOWN)
	bar.apply_modifiers(plain)
	expect(not plain.ctrl_pressed, "Typing after unlocking is unmodified")
	bar.free()

func test_each_locked_modifier_persists_across_tabs_until_tapped_again() -> void:
	var host := Host.new()
	var bar := KeyBar.new()
	bar.host = host
	bar._ready()
	bar.show()
	for key in ["ctrl", "alt", "shift"]:
		bar.buttons[key].button_pressed = true
		bar.buttons[key].button_pressed = false
	host.active_session_id = 2
	for unused in 2:
		var event := ime_key("u", KEY_UNKNOWN)
		bar.apply_modifiers(event)
		expect(event.ctrl_pressed and event.alt_pressed and event.shift_pressed and event.unicode == 85, "All three locked modifiers survive input and a tab change")
	for key in ["ctrl", "alt", "shift"]:
		expect(bar.buttons[key].button_pressed, key + " stays highlighted while locked")
		bar.buttons[key].button_pressed = false
	var plain := ime_key("u", KEY_UNKNOWN)
	bar.apply_modifiers(plain)
	expect(not plain.ctrl_pressed and not plain.alt_pressed and not plain.shift_pressed, "Each modifier releases on its third tap")
	bar.free()
	host.free()

class RecordedTerminal extends Node:
	var events: Array[InputEventKey] = []
	func send_key(event: InputEventKey) -> void: events.append(event.duplicate())

func test_escape_tab_are_momentary_and_modifier_buttons_are_adjacent() -> void:
	var host := Host.new()
	var terminal := RecordedTerminal.new()
	host.sessions[1] = {"term": terminal}
	var bar := KeyBar.new()
	bar.host = host
	bar._ready()
	bar.show()
	for key in ["escape", "tab"]:
		bar.buttons[key].pressed.emit()
		expect(not bar.buttons[key].toggle_mode and not bar.buttons[key].button_pressed, key + " never latches")
		expect(bar.buttons[key].get_theme_stylebox("hover") == bar.buttons[key].get_theme_stylebox("normal"), key + " cannot retain a touch hover highlight")
	expect(terminal.events.size() == 4, "Esc and Tab each send exactly one press and one release")
	if terminal.events.size() == 4:
		expect(terminal.events[0].keycode == KEY_ESCAPE and terminal.events[0].pressed and not terminal.events[1].pressed, "Esc is a single complete keypress")
		expect(terminal.events[2].keycode == KEY_TAB and terminal.events[2].pressed and not terminal.events[3].pressed, "Tab is a single complete keypress")
	expect(bar.buttons.alt.get_index() == bar.buttons.ctrl.get_index() + 1 and bar.buttons.shift.get_index() == bar.buttons.alt.get_index() + 1, "Ctrl, Alt, and Shift are consecutive")
	bar.free()
	terminal.free()
	host.free()

func test_android_ime_key_identity_preserves_real_keycodes() -> void:
	var bar := KeyBar.new()
	var a := ime_key("a", KEY_UNKNOWN)
	var b := ime_key("b", KEY_UNKNOWN)
	expect(bar.key_identity(a) != bar.key_identity(b), "Unknown physical keycodes do not collapse distinct IME keys")
	bar.apply_modifiers(a)
	expect(a.keycode == KEY_A and not a.ctrl_pressed and a.unicode == 97, "Plain IME text keeps its character without adding modifiers")
	var hardware := ime_key("a", KEY_B)
	bar.apply_modifiers(hardware)
	expect(hardware.keycode == KEY_B, "Explicit keyboard layout keycodes remain authoritative")
	var korean := ime_key("한", KEY_NONE)
	bar.apply_modifiers(korean)
	expect(korean.keycode == KEY_NONE and korean.unicode == "한".unicode_at(0), "Non-ASCII composition stays a text event")
	bar.free()

func test_android_ime_session_and_tab_selectors() -> void:
	for missing_code in [KEY_NONE, KEY_UNKNOWN]:
		var host := Host.new()
		var bar := KeyBar.new()
		bar.host = host
		bar.show()
		bar.update_host()
		var prefix := Prefix.new()
		prefix.host = host
		prefix.settings = Settings.PrefixSettings.new()
		prefix.settings.key = KEY_A | KEY_MASK_CTRL
		for selector in ["$", "@"]:
			bar.modifiers.ctrl = true
			var trigger := ime_key("a", missing_code)
			bar.apply_modifiers(trigger)
			expect(prefix.handle(trigger) and prefix.active, "On-screen Ctrl+A arms prefix for selector")
			var command := ime_key(selector, missing_code)
			bar.apply_modifiers(command)
			expect(prefix.handle(command) and not prefix.active, "IME selector opens command line")
		expect(host.opened == ["$", "@"], "Android session and tab selectors seed the correct command lines")
		bar.free()
		host.free()

func test_android_ime_next_and_previous_tab() -> void:
	var host := Host.new()
	var bar := KeyBar.new()
	bar.host = host
	bar.show()
	bar.update_host()
	var prefix := Prefix.new()
	prefix.host = host
	prefix.settings = Settings.PrefixSettings.new()
	prefix.settings.key = KEY_A | KEY_MASK_CTRL
	expect(prefix.settings.validate().is_empty(), "Default navigation bindings validate")
	for command in ["n", "p", "n"]:
		bar.modifiers.ctrl = true
		var trigger := ime_key("a", KEY_UNKNOWN)
		bar.apply_modifiers(trigger)
		expect(prefix.handle(trigger) and prefix.active, "Ctrl+A arms each tab navigation")
		var event := ime_key(command, KEY_UNKNOWN)
		bar.apply_modifiers(event)
		expect(prefix.handle(event) and not prefix.active, "Tab navigation consumes the IME command")
	expect(host.tab_steps == [1, -1, 1], "N and P navigate next and previous tabs")
	bar.free()
	host.free()

func test_ctrl_after_tab_change_is_not_cleared_by_the_next_key() -> void:
	var host := Host.new()
	var bar := KeyBar.new()
	bar.host = host
	bar._ready()
	bar.show()
	bar.update_host()
	host.active_session_id = 2
	bar.buttons.ctrl.button_pressed = true
	var event := ime_key("a", KEY_UNKNOWN)
	bar.apply_modifiers(event)
	expect(event.ctrl_pressed, "Ctrl armed after changing tabs applies to the next character")
	expect(not bar.buttons.ctrl.button_pressed, "Ctrl is consumed once after a tab change")
	bar.free()
	host.free()
