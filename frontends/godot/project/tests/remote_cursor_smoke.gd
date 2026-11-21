extends SceneTree
const Presentation := preload("res://scenes/remote/RemotePresentation.gd")
func _initialize() -> void: run.call_deferred()
func run() -> void:
	var source: Control = ClassDB.instantiate("Terminal")
	var client: Control = ClassDB.instantiate("Terminal")
	for terminal in [source, client]:
		terminal.remote_mode = true
		terminal.size = Vector2(800,500)
		root.add_child(terminal)
	await process_frame
	await process_frame
	for style in [6,2,5,1,4,3]:
		source.remote_feed(("\u001b[%d q" % style).to_utf8_buffer(),80,24)
		var frame: Dictionary = source.remote_snapshot()
		assert(frame.cursor_style == style, "Source exposes the application's DECSCUSR")
		client.remote_feed(Presentation.encode(frame,[],false),80,24)
		assert(client.remote_snapshot().cursor_style == style, "Cursor-only presentation preserves insert/command shape and blink")
	if DisplayServer.get_name() != "headless":
		client.grab_focus()
		await create_timer(0.1).timeout
		assert(client.has_focus() and root.has_focus(), "Cursor rendering test owns focus")
		# Replacing State must not wait for another FOCUS_ENTER notification.
		client.respawn()
		client.remote_feed("\u001b[6 q".to_utf8_buffer(),80,24)
		await create_timer(0.1).timeout
		var caret: Rect2 = client.get_cursor_render_info().rect
		assert(caret.size.x < 0.5 and is_equal_approx(caret.size.y, 1.0), "Focused replacement immediately renders the application bar, not an unfocused box")
	print("REMOTE_CURSOR_ROUNDTRIP_PASS")
	quit()
