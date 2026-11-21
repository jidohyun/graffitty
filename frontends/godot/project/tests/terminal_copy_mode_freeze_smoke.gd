extends SceneTree
## Copy mode, search and Quick Select freeze the replica, as tmux copy mode
## does: owner output is held, then applied in order on refresh or exit.
## godot --headless --path . --script tests/terminal_copy_mode_freeze_smoke.gd

var failures := 0
var terminal: Control


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-freeze-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")


func settle() -> void:
	await process_frame
	await process_frame


func feed(text: String, exited := false) -> void:
	terminal.remote_feed_stream(text.to_utf8_buffer(), 80, 20, false, exited)
	await settle()


## A real key press and release through the focused GUI route.
func press(keycode: Key, unicode := 0) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = keycode
		event.unicode = unicode
		event.pressed = down
		terminal.get_viewport().push_input(event)
	await settle()


func screen() -> String:
	return str(terminal.get_text(true).get("text", ""))


func state() -> Dictionary:
	return terminal.get_ui_state()


func run() -> void:
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(640, 400)
	root.add_child(terminal)
	preload("res://graffitty/terminal_config.gd").new().apply_live(terminal)
	terminal.grab_focus()
	await settle()
	if not "modal" in state():
		push_error("Rebuild graffitty before running the copy-mode freeze test")
		quit(1)
		return
	await feed("BEFORE\r\n")
	check("BEFORE" in screen(), "Output applies while no overlay is open")

	check(terminal.perform_action("copy_mode"), "Copy mode opens")
	await feed("DURING\r\n")
	check(not "DURING" in screen(), "Copy mode holds owner output")
	check(state().modal == "copy_mode" and state().held_output, "UI state reports held output")
	await press(KEY_R, "r".unicode_at(0))
	check("DURING" in screen(), "r applies held output")
	check(state().modal == "copy_mode" and not state().held_output, "r keeps copy mode open")
	await feed("FIRST ")
	await feed("SECOND\r\n\u001b[?1049h", true)
	check(not state().exited and not state().alternate_screen, "Exit and screen switches wait too")
	await press(KEY_ESCAPE)
	check(state().modal == "", "Escape leaves copy mode")
	check(state().alternate_screen and state().exited, "Held updates apply on exit")
	terminal.remote_feed_stream("\u001b[?1049l".to_utf8_buffer(), 80, 20, false, false)
	await settle()
	check("FIRST SECOND" in screen(), "Held output applies in order")
	check(terminal.remote_take_input().is_empty(), "Copy-mode keys never reach the program")

	terminal.remote_feed_stream("needle\r\n".to_utf8_buffer(), 80, 20, true, false)
	await settle()
	check(terminal.search_scrollback("needle", 1) == 1, "API search finds the match")
	check(state().modal == "copy_mode", "API search opens copy mode on it")
	await press(KEY_ESCAPE)
	check(terminal.perform_action("search"), "Search opens")
	await feed("SEARCH_LATER\r\n")
	check(state().modal == "search" and not "SEARCH_LATER" in screen(), "The search prompt freezes too")
	await press(KEY_ESCAPE)
	check(state().modal == "" and "SEARCH_LATER" in screen(), "Cancelling the search catches up")

	check(terminal.perform_action("quick_select"), "Quick Select opens")
	await feed("QUICK_LATER\r\n")
	check(state().modal == "quick_select" and not "QUICK_LATER" in screen(), "Quick Select freezes")
	await press(KEY_ESCAPE)
	check(state().modal == "" and "QUICK_LATER" in screen(), "Leaving Quick Select catches up")

	# The Android key bar and prefix pass-through encode keys directly.
	check(terminal.perform_action("copy_mode"), "Copy mode reopens")
	await feed("KEYBAR_LATER\r\n")
	for down in [true, false]:
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = down
		terminal.send_key(escape)
	await settle()
	check(state().modal == "" and "KEYBAR_LATER" in screen(), "Direct key routes reach copy mode")
	check(terminal.remote_take_input().is_empty(), "Direct copy-mode keys never reach the program")

	terminal.queue_free()
	await settle()
	quit(1 if failures else 0)
