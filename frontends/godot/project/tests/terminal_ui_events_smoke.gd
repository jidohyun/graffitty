extends SceneTree
## Native semantic events must work without painting or periodic state reads.
## godot --headless --path . --script tests/terminal_ui_events_smoke.gd

const Session := preload("res://scenes/TerminalSession.gd")


class CountingSession extends Session:
	var reads := 0


	func refresh() -> void:
		reads += 1
		super.refresh()


var failures := 0
var frames := 0


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-ui-events-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")


func settle() -> void:
	await process_frame
	await process_frame


func run() -> void:
	var terminal: Control = ClassDB.instantiate("Terminal")
	if not terminal.has_signal("ui_state_changed"):
		push_error("Rebuild graffitty before running terminal UI event tests")
		terminal.free()
		quit(1)
		return
	terminal.remote_mode = true
	terminal.size = Vector2(640, 400)
	terminal.visible = false
	terminal.configure_advanced({ "cursor_blink": 0 })
	terminal.frame_changed.connect(
		func():
			frames += 1,
	)
	# A SubViewport paints in headless mode even though its root Window is hidden.
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 400)
	root.add_child(viewport)
	viewport.add_child(terminal)
	var session := CountingSession.new()
	session.configure(1, terminal)
	root.add_child(session)
	await settle()
	check(session.get_child_count() == 0, "Native sessions need no compatibility timer")
	var before := session.reads
	await create_timer(0.25).timeout
	check(session.reads == before, "Idle hidden terminals perform zero semantic reads")
	terminal.remote_feed_stream(
		(
			"\u001b]0;Remote job\u0007\u001b]7;file://localhost/work/two%20words\u0007"
			+ "\u001b]9;4;1;42\u0007"
		).to_utf8_buffer(),
		80,
		20,
		false,
		false,
	)
	await settle()
	check(session.title == "Remote job", "Hidden remote titles arrive without a title timer")
	check(session.cwd == "file://localhost/work/two%20words", "Hidden remote CWD is notified")
	check(
		session.progress_state == 1 and session.progress_value == 42,
		"Remote OSC progress is parsed and notified",
	)
	check(frames == 0, "Hidden metadata updates require no painted frame")
	check(session.reads == before + 1, "One remote update coalesces to one semantic read")
	terminal.remote_feed_stream("\u001b]0;\u0007".to_utf8_buffer(), 80, 20, false, false)
	await settle()
	check(session.title == "/work/two words", "Clearing a remote title restores the CWD title")
	terminal.remote_feed_stream("row\r\n".repeat(60).to_utf8_buffer(), 80, 20, false, false)
	await settle()
	check(session.scroll_total > session.scroll_page, "Hidden output updates scrollback extent")
	terminal.scroll_to_position(2.25)
	await settle()
	check(
		is_equal_approx(session.scroll_offset, 2.25),
		"Native fractional scrolling emits an event",
	)
	terminal.perform_action("scroll_bottom")
	await settle()
	check(session.scroll_snapshot().at_bottom, "Native scroll actions notify without painting")
	terminal.remote_feed_stream("\u001b[?1049h".to_utf8_buffer(), 80, 20, false, false)
	await settle()
	check(session.alternate_screen, "Alternate-screen transitions update session state")
	terminal.remote_feed_stream("\u001b[?1049l".to_utf8_buffer(), 100, 24, false, true)
	await settle()
	check(not session.alternate_screen, "Leaving alternate screen updates session state")
	check(
		session.snapshot().columns == 100 and session.scroll_page == 24,
		"Remote resize updates grid and scrollbar",
	)
	check(session.has_exited, "Remote exits update UI without a local process signal")
	terminal.remote_feed_stream(PackedByteArray(), 80, 20, true, false)
	await settle()
	check(not session.has_exited, "A stream reset clears remote exit state")
	check(
		session.progress_state == 0 and session.progress_value == -1,
		"A stream reset clears stale progress",
	)
	before = session.reads
	await create_timer(0.25).timeout
	check(session.reads == before, "Hidden pending paint does not repeatedly invalidate UI")
	terminal.show()
	terminal.configure_advanced({ "cursor_blink": 1, "cursor_blink_interval_ms": 60 })
	await create_timer(0.1).timeout
	before = session.reads
	var previous_frames := frames
	await create_timer(0.3).timeout
	check(frames > previous_frames, "Native cursor blinking still paints")
	check(session.reads == before, "Cursor blinking performs zero semantic reads")
	session.free()
	viewport.free()
	# Every frontend terminal is now an owner-backed replica. PTY launch,
	# authoritative grid resize and shell exit policy are server E2E contracts.
	print("TERMINAL_UI_EVENTS_PASS" if failures == 0 else "TERMINAL_UI_EVENTS_FAIL")
	quit(failures)
