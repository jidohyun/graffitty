extends SceneTree
## Production workspace camera under repeated preview updates. All input and
## owner state are isolated by the Python scene fixture.
var wrapper: Node
var host: Node
var term: Node
var failures := 0

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1

func _initialize() -> void:
	run.call_deferred()

func wait_text(marker: String) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		if marker in str(term.get_text(true).get("text", "")):
			return true
		await process_frame
	return false

func run() -> void:
	root.size = Vector2i(1280, 800)
	wrapper = load("res://scenes/terminal.tscn").instantiate()
	wrapper.launch_args = PackedStringArray(["--no-plugin", "--workspace=main", "--attach-session"])
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline:
		await process_frame
	if wrapper.host == null:
		check(false, "Production workspace starts")
		quit(1)
		return
	host = wrapper.host
	while not host.sessions.has(host.active_session_id) and Time.get_ticks_msec() < deadline:
		await process_frame
	term = host.sessions[host.active_session_id].term
	check(await wait_text("@@READY@@"), "Production terminal adopts initial snapshot")
	var folder := OS.get_environment("GRAFFITTY_SCENE_FIXTURE")
	term.send_text(folder.path_join("image.vt") + "\n")
	check(await wait_text("@@IMAGE_DONE@@"), "Production workspace displays the image")
	deadline = Time.get_ticks_msec() + 10000
	while int(term.remote_image_stats().textures) == 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(int(term.remote_image_stats().imports) == 1, "Production workspace uses shared GPU storage")
	for _i in 30:
		await process_frame
	var samples: Array[float] = []
	var blank := 0
	var anchor := Vector2(640, 400)
	var previous := Time.get_ticks_usec()
	for frame in 180:
		if frame % 6 == 0:
			term.send_text(folder.path_join("erase-line.vt") + "\n")
		var factor := 1.006 if frame % 60 < 30 else 1.0 / 1.006
		host.workspace_view.pinch_workspace(anchor, anchor + Vector2(sin(frame * 0.1), 0), factor)
		await process_frame
		var now := Time.get_ticks_usec()
		samples.append((now - previous) / 1000.0)
		previous = now
		if str(term.get_text(false).get("text", "")).strip_edges().is_empty():
			blank += 1
	samples.sort()
	var p95 := samples[int(samples.size() * 0.95)]
	var maximum := samples[-1]
	print("SCENE_MOTION ", JSON.stringify({"p95_frame_ms": p95, "max_frame_ms": maximum, "blank_frames": blank, "images": term.remote_image_stats()}))
	check(blank == 0, "Camera motion and preview erasure never blank terminal text")
	check(p95 < 100.0 and maximum < 500.0, "Camera continues rendering during preview churn")
	check(int(term.remote_image_stats().imports) == 1 and int(term.remote_image_stats().uploads) == 0, "Zoom and erase reuse the same shared image texture")
	wrapper.connection.disconnect_remote()
	wrapper.queue_free()
	for _i in 5:
		await process_frame
	quit(0 if failures == 0 else 1)
