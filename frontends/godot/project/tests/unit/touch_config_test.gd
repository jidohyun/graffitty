extends "res://tests/unit/test_case.gd"
## client.toml `[touch]`: the key strip and floating buttons come from config,
## with the shipped set as the default, and every face is the touch-controls mod.
const KeyBar := preload("res://scenes/input/TouchKeyBar.gd")
const UserConfig := preload("res://config/UserConfig.gd")


func test_defaults_are_the_shipped_strip_and_buttons() -> void:
	var touch := UserConfig.touch_config(PackedStringArray(["--no-config"]))
	expect(touch.keys == ["copy", "paste", "escape", "tab", "ctrl", "alt", "shift", "left", "down", "up", "right", "home", "end", "page_up", "page_down"], "Default strip: %s" % [touch.keys])
	expect(touch.buttons == ["keyboard", "text_size", "microphone"], "Default floating buttons: %s" % [touch.buttons])


func test_configured_lists_reach_the_client() -> void:
	var config := client_toml("touch", "[touch]\nkeys = [\"ctrl\", { label = \"|\", action = \"SendText\", text = \"|\" }]\nbuttons = [\"keyboard\"]\n")
	var touch := UserConfig.touch_config(PackedStringArray(["--no-config", config]))
	expect(touch.keys.size() == 2 and touch.keys[0] == "ctrl" and touch.keys[1].action == "SendText" and touch.keys[1].text == "|", "Keys keep order and action entries: %s" % [touch.keys])
	expect(touch.buttons == ["keyboard"], "Buttons keep only what is listed: %s" % [touch.buttons])


func test_strip_builds_configured_keys_with_mod_faces() -> void:
	var bar := KeyBar.new()
	bar.layout = ["ctrl", {"label": "⌃A", "action": "TogglePrefix"}, "escape", "left"]
	bar._ready()
	var names := []
	for button in bar.buttons.values(): names.append(String(button.name))
	expect(names == ["ctrl", "action_1", "escape", "left"], "Keys appear in configured order: %s" % [names])
	var action: Button = bar.buttons.action_1
	var face: Control = action.get_node_or_null("Face")
	expect(face != null and face.get_meta(&"face_props").label == "⌃A" and action.text == "⌃A", "An action key shows its label through the mod face")
	expect(not action.toggle_mode and action.tooltip_text == "⌃A", "An action key is a plain tap with its label as accessible name")
	expect(bar.buttons.left.get_node("Face").get_meta(&"face_props").key == "left", "Icon keys hand their key to the face, which owns the art")
	expect(face.last_error().is_empty() and bar.buttons.ctrl.get_node("Face").last_error().is_empty(), "Faces render without mod errors")
	for button in bar.buttons.values():
		expect(button.get_theme_color("font_color", "Button").a == 0.0 and button.get_theme_color("icon_normal_color", "Button").a == 0.0, "The native label/icon stay for layout only: " + String(button.name))
	bar.free()


func test_default_strip_has_clipboard_and_navigation_keys() -> void:
	var bar := KeyBar.new()
	bar._ready()
	for key in ["copy", "paste"]:
		var button: Button = bar.buttons[key]
		expect(not button.toggle_mode and button.text.is_empty() and button.get_node("Face").get_meta(&"face_props").key == key, "%s is an icon key that taps an action" % key)
		expect(button.get_node("Face").last_error().is_empty(), "%s face renders without mod errors" % key)
	for key in ["home", "end", "page_up", "page_down"]:
		var button: Button = bar.buttons[key]
		expect(not button.toggle_mode and not button.text.is_empty() and button.get_node("Face").last_error().is_empty(), "%s is a labelled key" % key)
	bar.free()


func test_shift_turns_one_terminal_drag_into_a_selecting_chord() -> void:
	var bar := KeyBar.new()
	bar.layout = ["shift"]
	bar._ready()
	bar.show()
	expect(not bar.shift_drag_selects(), "Without Shift a terminal drag scrolls")
	bar.cycle_modifier("shift")
	expect(bar.shift_drag_selects(), "Armed Shift claims the next terminal drag")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	press.pressed = true
	var move := InputEventMouseMotion.new()
	move.button_mask = MOUSE_BUTTON_MASK_LEFT
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	for event in [press, move, release]: bar.apply_pointer_modifiers(event, "%1")
	expect(press.shift_pressed and move.shift_pressed and release.shift_pressed, "The press, the drag and the release all carry Shift")
	expect(not bar.shift_drag_selects() and bar.pointer_chords.is_empty(), "One-shot Shift is spent by that drag")
	bar.cycle_modifier("shift")
	bar.cycle_modifier("shift")
	for event in [press, move, release]: bar.apply_pointer_modifiers(event, "%1")
	expect(bar.shift_drag_selects(), "Locked Shift keeps selecting drag after drag")
	bar.hide()
	expect(not bar.shift_drag_selects(), "A hidden strip claims nothing")
	bar.free()


func test_face_follows_press_and_lock_states() -> void:
	var bar := KeyBar.new()
	bar.layout = ["ctrl"]
	bar._ready()
	var ctrl: Button = bar.buttons.ctrl
	var props := func() -> Dictionary: return ctrl.get_node("Face").get_meta(&"face_props")
	expect(props.call().mode == "normal" and not props.call().locked, "A resting key's face is plain")
	ctrl.button_pressed = true
	preload("res://scenes/input/TouchFace.gd")._follow(ctrl)
	expect(props.call().mode == "pressed", "An armed modifier's face uses the pressed color")
	ctrl.button_pressed = false
	expect(props.call().locked, "A locked modifier's face is locked")
	expect(props.call().palette.pressed != props.call().palette.normal or props.call().locked_color != props.call().palette.normal, "The face carries the native color for each state")
	bar.free()
