extends SceneTree
## Copy mode freezes a native scene replica fed by a real owner. Held commits,
## including a reconnect snapshot, apply in order once it closes.
## Run through tests/godot/test_terminal_scene_godot.py, which supplies the owner.
var connection: Node
var terminal: Control
var session_id := 0
var failures := 0
var folder := ""
var snapshots := 0
var closed_sessions := 0


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func _initialize() -> void:
	run.call_deferred()


func receive(id: int, header: Dictionary, _data: PackedByteArray) -> void:
	session_id = id
	if header.has("asset_texture"):
		terminal.remote_set_asset_texture(str(header.asset), header.asset_texture, int(header.width), int(header.height))
	elif header.has("native"):
		terminal.remote_apply_scene(header.native)
		if header.has("columns"):
			snapshots += 1


func screen() -> String:
	return str(terminal.get_text(true).get("text", ""))


func eventually(condition: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		if condition.call():
			return true
		await process_frame
	return false


## The fixture shell writes the bytes of each file path it reads.
func output(text: String) -> void:
	var path := folder.path_join("freeze-%d.vt" % Time.get_ticks_usec())
	FileAccess.open(path, FileAccess.WRITE).store_string(text)
	connection.send_action("text", session_id, {"text": path + "\n"})


func connect_owner() -> void:
	connection.connect_shared({"descriptor": folder.path_join("connection.json"), "server": OS.get_environment("GRAFFITTY_TEST_SERVER")})


func run() -> void:
	folder = OS.get_environment("GRAFFITTY_SCENE_FIXTURE")
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(800, 480)
	terminal.set_render_active(false)
	root.add_child(terminal)
	connection = preload("res://scenes/remote/RemoteConnection.gd").new()
	root.add_child(connection)
	connection.terminal_received.connect(receive)
	connection.session_closed.connect(func(): closed_sessions += 1)
	connection.changed.connect(func():
		if not connection.topology.panes.is_empty():
			session_id = int(connection.topology.panes[0].id)
			connection.subscribe([session_id]))
	connect_owner()
	check(await eventually(func(): return "@@READY@@" in screen()), "Initially hidden replica retains its owner snapshot")
	check(not terminal.is_processing(), "Hidden replica retains state without frame processing")
	output("\r\n@@HIDDEN@@")
	check(await eventually(func(): return "@@HIDDEN@@" in screen()), "Hidden replica applies subsequent owner updates")
	terminal.set_render_active(true)
	check("@@READY@@" in screen() and "@@HIDDEN@@" in screen(), "Activation preserves snapshot and updates without new output")
	check(terminal.perform_action("copy_mode"), "Copy mode opens")
	output("\r\n@@DURING@@")
	check(await eventually(func(): return terminal.get_ui_state().held_output), "Owner commits wait in copy mode")
	check(not "@@DURING@@" in screen(), "The frozen replica keeps its screen")
	var before := snapshots
	connection.disconnect_remote()
	connect_owner()
	check(await eventually(func(): return snapshots > before), "Reconnect delivers a new snapshot")
	check(not "@@DURING@@" in screen(), "The reconnect snapshot waits too")
	for down in [true, false]:
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = down
		terminal.send_key(escape)
	check(await eventually(func(): return "@@DURING@@" in screen()), "Leaving copy mode applies held commits")
	check(terminal.get_ui_state().modal == "" and not terminal.get_ui_state().held_output, "Nothing stays held")
	output("\r\n@@AFTER@@")
	check(await eventually(func(): return "@@AFTER@@" in screen()), "Live updates resume")
	connection.send_action("text", session_id, {"text": "--exit--\n"})
	await eventually(func(): return closed_sessions > 0)
	connection.disconnect_remote()
	connection.queue_free()
	terminal.queue_free()
	for _i in 4:
		await process_frame
	quit(0 if failures == 0 else 1)
