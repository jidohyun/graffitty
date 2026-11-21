extends "res://tests/unit/test_case.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Physics := preload("res://scenes/WorkspacePhysics.gd")
const Prefix := preload("res://scenes/WorkspacePrefix.gd")
const Settings := preload("res://graffitty/config.gd")

class View extends RefCounted:
	var calls: Array = []
	func split_window(axis: String, beside := "", before := false) -> void: calls.append([axis, beside, before])
	func resize_to_fit_main(key := "") -> void: calls.append(["resize_to_fit_main", key])

class TerminalStub extends RefCounted:
	var keys: Array[InputEventKey] = []
	func send_key(event: InputEventKey) -> bool:
		keys.append(event.duplicate())
		return true

class Host extends Node:
	var chromiums := {}
	func is_terminal_pane(key: String) -> bool:
		return preload("res://scenes/PaneTargets.gd").valid(key) and sessions.has(int(key.substr(1)))
	signal ui_changed
	var workspace_view := View.new()
	var pane_focus := "%1"
	var terminal := TerminalStub.new()
	var sessions := {1: {"term": terminal}}
	var opened: Array[String] = []
	func open_command_line(text := "") -> void:
		opened.append(text)

func key_event(code: int, pressed := true, echo := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code & KEY_CODE_MASK
	event.ctrl_pressed = bool(code & KEY_MASK_CTRL)
	event.alt_pressed = bool(code & KEY_MASK_ALT)
	event.meta_pressed = bool(code & KEY_MASK_META)
	event.shift_pressed = bool(code & KEY_MASK_SHIFT)
	if event.keycode >= KEY_SPACE and event.keycode <= 0x10ffff:
		var letter := String.chr(event.keycode)
		event.unicode = (letter if event.shift_pressed else letter.to_lower()).unicode_at(0)
	event.pressed = pressed
	event.echo = echo
	return event

func test_directional_spawn_and_anchored_physics() -> void:
	var source := Rect2(200, 200, 360, 240)
	for axis in ["h", "v"]:
		var spawn := Layout.adjacent_spawn_rect(source, axis)
		expect(spawn.intersects(source), "New pane begins in shallow contact")
		var physics := Physics.new()
		var rects := {"source": source, "new": spawn}
		for i in 180: rects = physics.step(rects, {"new": false}, Rect2(0, 0, 4000, 3000), 1.0 / 60.0)
		expect(rects.source == source, "Source remains anchored")
		if axis == "h":
			expect(rects.new.position.x > spawn.position.x, "Right creation is pushed right")
			expect(absf(rects.new.position.y - spawn.position.y) < 1, "Right creation keeps vertical alignment")
		else:
			expect(rects.new.position.y > spawn.position.y, "Below creation is pushed downward")
			expect(absf(rects.new.position.x - spawn.position.x) < 1, "Below creation keeps horizontal alignment")
		expect(not rects.new.intersects(source), "Physics separates the new pane")

func test_prefix_direction_sequences() -> void:
	var host := Host.new()
	var prefix := Prefix.new()
	prefix.host = host
	prefix.settings = Settings.PrefixSettings.new()
	for item in [
		[KEY_BACKSLASH, 92], [KEY_MINUS, 45],
		[KEY_BACKSLASH | KEY_MASK_SHIFT, 124], [KEY_BAR | KEY_MASK_SHIFT, 124], [KEY_BAR, 124],
		[KEY_MINUS | KEY_MASK_SHIFT, 95], [KEY_UNDERSCORE | KEY_MASK_SHIFT, 95], [KEY_UNDERSCORE, 95],
		[KEY_7 | KEY_MASK_CTRL | KEY_MASK_ALT, 124], [KEY_U | KEY_MASK_ALT, 95],
		[KEY_BACKSLASH | KEY_MASK_SHIFT, 47],
	]:
		var trigger := key_event(prefix.settings.key)
		expect(prefix.handle(trigger) and prefix.active, "This client's configured key arms prefix")
		trigger.pressed = false
		prefix.handle(trigger)
		var direction := key_event(item[0])
		direction.unicode = item[1]
		expect(prefix.handle(direction) and not prefix.active, "Direction is consumed once")
		direction.pressed = false
		prefix.handle(direction)
	expect(host.workspace_view.calls == [["h", "", false], ["v", "", false], ["h", "", true], ["h", "", true], ["h", "", true], ["v", "", true], ["v", "", true], ["v", "", true], ["h", "", true], ["v", "", true]], "Typed split symbols work with Shift, Option and AltGr; an unrelated shifted character never splits")
	host.free()

func test_prefix_e_resizes_once_without_typing_into_the_terminal() -> void:
	var host := Host.new()
	var prefix := Prefix.new()
	prefix.host = host
	prefix.settings = Settings.PrefixSettings.new()
	expect(prefix.settings.bindings[KEY_E] == "ResizeToFitMain" and prefix.settings.validate().is_empty(), "Prefix E is a valid default resize action")
	for key in [KEY_E, KEY_Q]:
		if key == KEY_Q:
			prefix.settings.bindings.erase(KEY_E)
			prefix.settings.bindings[KEY_Q] = "ResizeToFitMain"
		expect(prefix.handle(key_event(prefix.settings.key)), "Prefix arms")
		expect(prefix.handle(key_event(prefix.settings.key, false)), "Prefix release is consumed")
		expect(prefix.handle(key_event(key)) and not prefix.active, "Resize consumes and disarms prefix")
		expect(prefix.handle(key_event(key, true, true)), "Repeat is swallowed")
		expect(prefix.handle(key_event(key, false)), "Resize release is consumed")
	expect(host.workspace_view.calls == [["resize_to_fit_main", ""], ["resize_to_fit_main", ""]], "Default and remapped shortcuts each resize once")
	expect(host.terminal.keys.is_empty(), "No resize keystrokes reach the terminal")
	host.free()

func test_configured_prefix_passthrough_consumes_sequence_and_repeat_releases() -> void:
	for trigger in [KEY_A | KEY_MASK_CTRL, KEY_B | KEY_MASK_CTRL, KEY_A | KEY_MASK_META, KEY_X | KEY_MASK_CTRL | KEY_MASK_ALT, KEY_B | KEY_MASK_ALT, KEY_B | KEY_MASK_ALT | KEY_MASK_SHIFT, KEY_B | KEY_MASK_CTRL | KEY_MASK_SHIFT, KEY_F5, KEY_G]:
		for followup in [trigger, trigger & KEY_CODE_MASK, KEY_A]:
			var host := Host.new()
			var prefix := Prefix.new()
			prefix.host = host
			prefix.settings = Settings.PrefixSettings.new()
			prefix.settings.key = trigger
			expect(prefix.handle(key_event(trigger)) and prefix.active, "Prefix arms without sending terminal input")
			expect(prefix.handle(key_event(trigger, true, true)) and host.terminal.keys.is_empty(), "Holding the trigger does not send it through")
			expect(prefix.handle(key_event(trigger, false)), "Trigger release is consumed")
			expect(prefix.handle(key_event(followup)) and not prefix.active, "Repeated prefix, bare key or A sends the configured prefix and disarms")
			expect(prefix.handle(key_event(followup, true, true)), "Follow-up repeat is consumed")
			expect(prefix.handle(key_event(followup, false)), "Follow-up release is consumed")
			expect(host.terminal.keys.size() == 2, "One terminal key press and release, without duplicate input")
			if host.terminal.keys.size() == 2:
				for event in host.terminal.keys:
					expect(event.get_keycode_with_modifiers() == trigger, "Terminal receives the configured key and every modifier, including Command")
					expect(event.unicode == key_event(trigger).unicode, "Aliases preserve the prefix text, including shifted letters")
				if trigger == KEY_G:
					expect(host.terminal.keys[0].unicode == 103, "A printable prefix keeps the text needed by the terminal encoder")
				expect(host.terminal.keys[0].pressed and not host.terminal.keys[1].pressed, "Terminal receives a complete key lifecycle")
			expect(not prefix.handle(key_event(KEY_Z)), "Ordinary typing resumes after the sequence")
			host.free()

func test_repeating_custom_prefix_does_not_require_a_binding() -> void:
	for followup in [KEY_B, KEY_B | KEY_MASK_CTRL]:
		var host := Host.new()
		var prefix := Prefix.new()
		prefix.host = host
		prefix.settings = Settings.PrefixSettings.new()
		prefix.settings.key = KEY_B | KEY_MASK_CTRL
		prefix.settings.bindings = {}
		prefix.handle(key_event(prefix.settings.key))
		prefix.handle(key_event(prefix.settings.key, false))
		prefix.handle(key_event(followup))
		prefix.handle(key_event(followup, false))
		expect(not prefix.active and host.terminal.keys.size() == 2, "Repeating a custom prefix works with all bindings replaced")
		for event in host.terminal.keys:
			expect(event.get_keycode_with_modifiers() == prefix.settings.key, "Passthrough follows the client prefix rather than a hard-coded Ctrl+A")
		host.free()

func test_prefix_toggle_and_hints_use_client_configuration() -> void:
	var host := Host.new()
	var prefix := Prefix.new()
	prefix.host = host
	prefix.settings = Settings.PrefixSettings.new()
	prefix.settings.key = KEY_B | KEY_MASK_CTRL
	prefix.toggle()
	expect(prefix.handle(key_event(KEY_1)) and prefix.handle(key_event(KEY_1, false)), "The digit and its release are consumed")
	expect(not prefix.active and host.opened == ["1"], "A digit opens the command line with that digit typed")
	prefix.toggle()
	prefix.toggle()
	expect(not prefix.active, "Clicking the tab again cancels the prefix")
	var mac := OS.get_name() == "macOS"
	expect(prefix.shortcut_label("NewPaneLeft") == ("⌃B, |" if mac else "Ctrl+B, |"), "Menu hint follows the client's remapped prefix")
	prefix.settings.bindings.erase(KEY_MINUS)
	prefix.settings.bindings[KEY_D] = "NewPaneBelow"
	expect(prefix.shortcut_label("NewPaneBelow") == ("⌃B, D" if mac else "Ctrl+B, D"), "Menu hint follows remapped direction keys")
	prefix.settings.key = KEY_NONE
	prefix.toggle()
	expect(not prefix.active and prefix.shortcut_label("NewPaneLeft").is_empty(), "Disabled prefix cannot be armed by a tab click and has no keyboard hint")
	host.free()
