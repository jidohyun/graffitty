extends "../../../../replay/replay.gd"
var shift_drag := false
var fixture_path := ""
var reports_path := ""

func _motion(at: Vector2, relative: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.device = REPLAY_POINTER_DEVICE
	event.position = at
	event.global_position = at
	event.relative = relative
	event.button_mask = _held
	event.shift_pressed = shift_drag
	root.push_input(event, true)

func press(button := MOUSE_BUTTON_LEFT) -> void:
	_motion(overlay.pointer, Vector2.ZERO)
	_held |= 1 << (button - 1)
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.button_index = button
	event.pressed = true
	event.position = overlay.pointer
	event.global_position = overlay.pointer
	event.button_mask = _held
	event.shift_pressed = shift_drag
	root.push_input(event, true)
	await hold(.12)

func release(button := MOUSE_BUTTON_LEFT, settle := .15) -> void:
	_held &= ~(1 << (button - 1))
	var event := InputEventMouseButton.new()
	event.device = REPLAY_POINTER_DEVICE
	event.button_index = button
	event.position = overlay.pointer
	event.global_position = overlay.pointer
	event.button_mask = _held
	event.shift_pressed = shift_drag
	root.push_input(event, true)
	await hold(settle)

func play() -> void:
	root.unfocusable = true
	if not check(DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD), "Replay requires a rendered desktop and clipboard"): return
	var clipboard := DisplayServer.clipboard_get()
	await labelled_tabs(["SELECTION"])
	await camera_at_rest()
	var view: Control = host.workspace_view
	var key: String = host.pane_focus
	var term: Control = host.sessions[host.active_session_id].term
	fixture_path = OS.get_environment("XDG_STATE_HOME").path_join("graffitty-selection-%d.py" % OS.get_process_id())
	reports_path = fixture_path + ".reports"
	FileAccess.open(fixture_path, FileAccess.WRITE).store_string(r"""import os,sys
if os.name=='nt':
 import ctypes
 kernel=ctypes.WinDLL('kernel32',use_last_error=True)
 kernel.GetStdHandle.restype=ctypes.c_void_p
 kernel.GetConsoleMode.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_ulong)]
 kernel.SetConsoleMode.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
 handle=kernel.GetStdHandle(-10)
 old=ctypes.c_ulong()
 assert kernel.GetConsoleMode(handle,ctypes.byref(old))
 assert kernel.SetConsoleMode(handle,(old.value & ~7) | 0x200)
 old_input_cp,old_output_cp=kernel.GetConsoleCP(),kernel.GetConsoleOutputCP()
 assert kernel.SetConsoleCP(65001)
 assert kernel.SetConsoleOutputCP(65001)
else:
 import tty,termios
 old=termios.tcgetattr(0)
 tty.setraw(0)
try:
 os.write(1,b'\x1b[?1049h\x1b[?1002h\x1b[?1006h\x1b[2J\x1b[5;5H'+ 'Alpha 한글 omega'.encode())
 with open(sys.argv[1],'wb',buffering=0) as f:
  while True:
   data=os.read(0,4096)
   if b'\x03' in data: break
   f.write(data)
finally:
 os.write(1,b'\x1b[?1002l\x1b[?1006l\x1b[?1049l')
 if os.name=='nt':
  kernel.SetConsoleMode(handle,old.value)
  kernel.SetConsoleCP(old_input_cp)
  kernel.SetConsoleOutputCP(old_output_cp)
 else:termios.tcsetattr(0,termios.TCSANOW,old)
""")
	term.send_text("%s '%s' '%s'\r" % ["python" if OS.get_name() == "Windows" else "python3", fixture_path, reports_path])
	var deadline := Time.get_ticks_msec() + 15000
	while not (FileAccess.file_exists(reports_path) and "Alpha 한글 omega" in str(term.get_text(false))) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check(FileAccess.file_exists(reports_path) and "Alpha 한글 omega" in str(term.get_text(false)), "Mouse-reporting fixture is running"):
		print("SELECTION_FIXTURE ", term.get_text(false))
		return
	await camera_at_rest()
	await app.agent_api.dispatch(host.active_session_id, "agent.event", {"kind":"custom", "event":"SessionStart", "session_id":"selection-fixture"})
	await app.agent_api.dispatch(host.active_session_id, "agent.register", {"name":"Selection fixture", "inputs":[{"id":"in"}], "outputs":[{"id":"out"}]})
	await hold(.4)
	check(view.agent_links.ports.has(key), "Fixture participates in the editable graph")
	await point_at(content(Vector2(.5, .5)))
	await pinch(.7)
	await hold(.4)
	check(view.agent_links.editing, "Graph editing is active while zoomed out")
	var cell: Vector2 = term.get_cell_size()
	# terminal_origin locates the viewport; per-world pane padding positions
	# the terminal inside it, before the terminal's own four-pixel cell inset.
	var origin: Vector2 = view.terminal_origin(key) + term.position
	var from: Vector2 = view.window_point(origin + Vector2(4, 4) + cell * Vector2(4.1, 4.5))
	var to: Vector2 = view.window_point(origin + Vector2(4, 4) + cell * Vector2(20.1, 4.5))
	await say("Shift+drag selects Unicode without sending mouse reports")
	shift_drag = true
	DisplayServer.clipboard_set("SELECTION_NOT_COPIED")
	await point_at(from)
	await press()
	await point_at(to, .6)
	DirAccess.make_dir_recursive_absolute("res://.cache/shift-selection")
	(await screen_image()).save_png("res://.cache/shift-selection/selected.png")
	shift_drag = false # Modifier release must not transfer the gesture to the app.
	await release()
	await keys("cmd+c" if OS.get_name() == "macOS" else "ctrl+shift+c")
	var selected := DisplayServer.clipboard_get()
	check(selected == "Alpha 한글 omega", "Copied selection matches Unicode text: " + selected)
	check(view.agent_links.tools.selected.is_empty(), "Text selection does not select graph nodes")
	check(FileAccess.get_file_as_string(reports_path).is_empty(), "Forced selection sends no bytes to the mouse-aware app")
	shift_drag = false
	await drag(from, to, .4)
	await hold(.2)
	check("\u001b[<" in FileAccess.get_file_as_string(reports_path), "Ordinary dragging still reaches the application")
	DisplayServer.clipboard_set(clipboard)
	term.send_text("\u0003")
	await hold(.2)
	DirAccess.remove_absolute(fixture_path)
	DirAccess.remove_absolute(reports_path)
