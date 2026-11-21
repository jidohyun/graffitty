extends SceneTree
## Real owner + common connection worker + renderer. The Python fixture supplies
## an isolated descriptor and VT files; run once headless and once with a GPU.
var connection: Node
var terminal: Control
var session_id := 0
var failures := 0
var blank_frames := 0
var observing := false
var folder := ""
var presentations := 0
var closed_sessions := 0

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1

func _initialize() -> void:
	run.call_deferred()

func _process(_dt: float) -> bool:
	if terminal != null and connection != null and connection.connected and session_id > 0:
		for asset in terminal.remote_take_asset_requests():
			connection.send_action("terminal_asset_request", session_id, {"asset": asset})
		if observing and str(terminal.get_text(false).get("text", "")).strip_edges().is_empty():
			blank_frames += 1
	return false

func receive(id: int, header: Dictionary, _data: PackedByteArray) -> void:
	session_id = id
	if header.has("asset_texture"):
		terminal.remote_set_asset_texture(str(header.asset), header.asset_texture, int(header.width), int(header.height))
	elif header.has("native"):
		terminal.remote_apply_scene(header.native)
		if header.has("columns"):
			presentations += 1

func wait_text(marker: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		if marker in str(terminal.get_text(true).get("text", "")):
			return true
		await process_frame
	return false

func send_file(name: String) -> void:
	connection.send_action("text", session_id, {"text": folder.path_join(name) + "\n"})

func red_pixels() -> int:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.r > 0.7 and color.g < 0.25 and color.b < 0.35:
				count += 1
	return count

func run() -> void:
	folder = OS.get_environment("GRAFFITTY_SCENE_FIXTURE")
	root.size = Vector2i(1000, 700)
	terminal = ClassDB.instantiate("Terminal")
	terminal.remote_mode = true
	terminal.size = Vector2(1000, 700)
	root.add_child(terminal)
	connection = preload("res://scenes/remote/RemoteConnection.gd").new()
	root.add_child(connection)
	connection.terminal_received.connect(receive)
	connection.session_closed.connect(func(): closed_sessions += 1)
	connection.changed.connect(func():
		if not connection.topology.panes.is_empty():
			session_id = int(connection.topology.panes[0].id)
			connection.subscribe([session_id]))
	connection.connect_shared({"descriptor": folder.path_join("connection.json"), "server": OS.get_environment("GRAFFITTY_TEST_SERVER")})
	check(await wait_text("@@READY@@"), "Atomic initial snapshot arrives through the native worker")
	observing = true
	send_file("image.vt")
	check(await wait_text("@@IMAGE_DONE@@"), "Image output leaves terminal text visible")
	var deadline := Time.get_ticks_msec() + 12000
	while int(terminal.remote_image_stats().textures) == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	var stats: Dictionary = terminal.remote_image_stats()
	FileAccess.open(folder.path_join("image-stats.json"), FileAccess.WRITE).store_string(JSON.stringify(stats, "  "))
	check(int(stats.textures) == 1, "Requested image becomes a retained texture")
	var graphical := DisplayServer.get_name() != "headless"
	if graphical:
		if OS.get_environment("GRAFFITTY_TEST_RAW_IMAGE_PIXELS") == "1":
			check(int(stats.imports) == 0 and int(stats.uploads) == 1, "Local decoded pixels become one retained GPU texture")
		else:
			check(int(stats.imports) == 1 and int(stats.uploads) == 0, "Native renderer imports shared image storage without a CPU texture upload")
		check(await red_pixels() > 100, "Imported image pixels are visible in the rendered terminal")
		root.get_texture().get_image().save_png(folder.path_join("image-visible.png"))
	else:
		check(int(stats.uploads) == 1, "Headless fallback decodes and uploads the resource once")
	send_file("erase.vt")
	check(await wait_text("@@ERASE_DONE@@"), "Erase arrives without resetting visible terminal")
	check(terminal.image_placements().is_empty(), "Deleted placement disappears")
	if graphical:
		for _i in 3:
			await process_frame
		check(await red_pixels() == 0, "Deleted placement leaves no stale GPU pixels")
		root.get_texture().get_image().save_png(folder.path_join("image-erased.png"))
	send_file("reuse.vt")
	check(await wait_text("@@REUSE_DONE@@"), "Retained image can be placed again")
	for _i in 4:
		await process_frame
	check(terminal.remote_image_stats().uploads == stats.uploads and terminal.remote_image_stats().imports == stats.imports, "Placement reuse does not decode, upload or import again")
	var previous_presentations := presentations
	connection.disconnect_remote()
	connection.connect_shared({"descriptor": folder.path_join("connection.json"), "server": OS.get_environment("GRAFFITTY_TEST_SERVER")})
	deadline = Time.get_ticks_msec() + 15000
	while presentations == previous_presentations and Time.get_ticks_msec() < deadline:
		await process_frame
	check(presentations > previous_presentations, "Reconnect adopts a new committed snapshot")
	check("@@REUSE_DONE@@" in str(terminal.get_text(true).get("text", "")), "Reconnect preserves terminal contents")
	check(terminal.remote_image_stats().uploads == stats.uploads and terminal.remote_image_stats().imports == stats.imports, "Reconnect retains unchanged image textures")
	if graphical:
		check(await red_pixels() > 100, "Shared texture remains valid after its original connection closes")
	check(blank_frames == 0, "No blank terminal frames during image/erase/reuse")
	terminal.set_render_image_budget(1)
	for _i in 3:
		await process_frame
	var constrained: Dictionary = terminal.remote_image_stats()
	check(int(constrained.bytes) <= 1 and int(constrained.textures) == 0, "Retained image cache obeys a reduced render budget")
	connection.send_action("text", session_id, {"text": "--exit--\n"})
	deadline = Time.get_ticks_msec() + 5000
	while closed_sessions == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(closed_sessions == 1, "Owner session closure survives worker shutdown and EOF")
	connection.disconnect_remote()
	connection.queue_free()
	terminal.queue_free()
	for _i in 4:
		await process_frame
	quit(0 if failures == 0 else 1)
