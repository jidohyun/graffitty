extends "../../../../replay/replay.gd"
const Diagnostics = preload("res://graffitty/diagnostics.gd")

func play() -> void:
	root.unfocusable = true
	if not check(DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD), "Requires desktop clipboard"): return
	var previous := DisplayServer.clipboard_get()
	diagnostic_guard.allow("Clipboard 한글 test", "example.gd", 12)
	Diagnostics.history.assign([{"message": "Clipboard 한글 test", "file": "example.gd", "line": 12, "warning": false}])
	Diagnostics.revision += 1
	host.show_messages()
	await hold(.3)
	var panel = host.diagnostic_panel
	var label: RichTextLabel = panel.messages
	var shortcut := "cmd+c" if OS.get_name() == "macOS" else "ctrl+c"
	# Messages open in a window embedded in the replay's window: offset into it.
	var origin := Vector2(label.get_window().position)
	await click(origin + on(label, Vector2(.5, .5)))
	check(label.has_focus(), "Clicking the messages focuses them")
	DisplayServer.clipboard_set("NOT_COPIED")
	await keys(shortcut)
	# The Windows clipboard exposes CRLF text; RichTextLabel stores LF.
	check(DisplayServer.clipboard_get().replace("\r\n", "\n") == label.get_parsed_text(), "Click then copy copies all messages")
	await point_at(origin + on(label, Vector2.ZERO) + Vector2(85, 12))
	var double_click := InputEventMouseButton.new()
	double_click.device = REPLAY_POINTER_DEVICE
	double_click.position = overlay.pointer
	double_click.global_position = overlay.pointer
	double_click.button_index = MOUSE_BUTTON_LEFT
	double_click.pressed = true
	double_click.double_click = true
	root.push_input(double_click, true)
	double_click.pressed = false
	root.push_input(double_click, true)
	await hold(.1)
	var selected := label.get_selected_text()
	check(selected == "Clipboard", "Double click selects one message word")
	DisplayServer.clipboard_set("NOT_COPIED")
	await keys(shortcut)
	check(DisplayServer.clipboard_get() == selected, "Copy copies only selected text")
	panel.dismiss_messages()
	DisplayServer.clipboard_set("DISMISSED")
	await keys(shortcut)
	check(DisplayServer.clipboard_get() == "DISMISSED", "Dismissed panel does not intercept copy")
	DisplayServer.clipboard_set(previous)
