extends SceneTree
var frames := 0
var failures := 0
func check(ok: bool, message: String):
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1
func _initialize():
	var isolated := OS.get_cache_dir().path_join("graffitty-frame-events-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")
func run():
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 400)
	vp.transparent_bg = true
	root.add_child(vp)
	var terminal: Control = ClassDB.instantiate("Terminal")
	if not terminal.has_signal("frame_changed"):
		push_error("Rebuild graffitty before running terminal frame event tests")
		terminal.free()
		vp.free()
		quit(1)
		return
	terminal.shell = "/bin/cat"
	terminal.login_shell = false
	terminal.size = Vector2(640, 400)
	terminal.configure_advanced({"cursor_blink": 0})
	terminal.frame_changed.connect(func(): frames += 1)
	preload("res://scenes/TerminalViewportUpdates.gd").configure(vp, terminal)
	vp.add_child(terminal)
	await create_timer(0.3).timeout
	check(frames > 0, "Native initial paint emits a frame change")
	var before := frames
	await create_timer(0.2).timeout
	check(frames == before, "Idle native terminal emits no frame changes")
	terminal.send_text("frame invalidation test\n")
	await create_timer(0.3).timeout
	check(frames > before, "PTY output emits a frame change")
	before = frames
	terminal.set_live_background_opacity(0.4)
	await create_timer(0.1).timeout
	check(frames > before, "Live style change emits a frame change")
	before = frames
	terminal.configure_advanced({"cursor_blink": 1, "cursor_blink_interval_ms": 60.0})
	await create_timer(0.3).timeout
	check(frames > before + 1, "Cursor blink emits frame changes")
	vp.free()
	quit(failures)
