extends SceneTree
## Conditional terminal shortcuts (`when`): the default prompt jumps act at a
## shell prompt and leave Shift+Up/Down to commands that keep the main screen.
## godot --headless --path frontends/godot/project --script res://tests/key_binding_condition_smoke.gd

const SHIFT_UP := KEY_UP | KEY_MASK_SHIFT
const SHIFT_DOWN := KEY_DOWN | KEY_MASK_SHIFT
const PROMPT := "\u001b]133;A\u0007$ \u001b]133;B\u0007"
const COMMAND := "pi\r\n\u001b]133;C\u0007"
const DONE := "\u001b]133;D;0\u0007"
var failures := 0


func check(ok: bool, what: String) -> void:
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		failures += 1


func _initialize() -> void:
	call_deferred("run")


func feed(term: Control, text: String) -> void:
	term.remote_feed(text.to_utf8_buffer(), 80, 24)


func press(term: Control, code: int) -> PackedByteArray:
	term.remote_take_input()
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code & KEY_CODE_MASK
		event.shift_pressed = bool(code & KEY_MASK_SHIFT)
		event.pressed = pressed
		term.get_viewport().push_input(event)
	return term.remote_take_input()


func run() -> void:
	var term: Control = ClassDB.instantiate("Terminal")
	term.remote_mode = true
	term.use_custom_key_bindings = true
	term.size = Vector2(640, 400)
	term.key_bindings = { SHIFT_UP: "previous_prompt", SHIFT_DOWN: "next_prompt", KEY_F8: "ignore" }
	term.key_binding_conditions = { SHIFT_UP: "prompt", SHIFT_DOWN: "prompt", KEY_F8: "!alt_screen" }
	term.configure_advanced({ "cursor_blink": 0 })
	root.add_child(term)
	term.grab_focus()
	await create_timer(1).timeout

	feed(term, PROMPT)
	await process_frame
	check(press(term, SHIFT_UP).is_empty(), "At the shell prompt, Shift+Up jumps prompts")
	check(press(term, SHIFT_DOWN).is_empty(), "At the shell prompt, Shift+Down jumps prompts")

	feed(term, COMMAND + "inline TUI on the main screen\r\n")
	await process_frame
	check(press(term, SHIFT_UP) == "\u001b[1;2A".to_utf8_buffer(), "While a command runs, Shift+Up reaches it")
	check(press(term, SHIFT_DOWN) == "\u001b[1;2B".to_utf8_buffer(), "While a command runs, Shift+Down reaches it")
	check(press(term, KEY_F8).is_empty(), "!alt_screen holds on the main screen")

	feed(term, "\u001b[?1049h")
	await process_frame
	check(not press(term, KEY_F8).is_empty(), "!alt_screen fails on the alternate screen, so F8 reaches the app")
	feed(term, "\u001b[?1049l" + DONE + PROMPT)
	await process_frame
	check(press(term, SHIFT_UP).is_empty(), "Back at the next prompt, Shift+Up jumps again")

	term.key_binding_conditions = { }
	feed(term, COMMAND)
	await process_frame
	check(press(term, SHIFT_UP).is_empty(), "Without a condition, the binding acts while a command runs")

	print("KEY_BINDING_CONDITION_" + ("PASS" if failures == 0 else "FAIL"))
	quit(1 if failures else 0)
