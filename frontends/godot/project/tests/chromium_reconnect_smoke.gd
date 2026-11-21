extends SceneTree
## Attach two retained native chromium windows, then use the real Detach action.
func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(1280, 800)
	var wrapper = load("res://scenes/terminal.tscn").instantiate()
	wrapper.launch_args = PackedStringArray(["--workspace=main", "--attach-session"])
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if wrapper.host != null and wrapper.host.chromiums.size() == 2:
			break
	if wrapper.host == null or wrapper.host.chromiums.size() != 2:
		printerr("FAIL: frontend did not restore both Chromium windows")
		quit(1)
		return
	var main_count := 0
	for chromium in wrapper.host.chromiums.values():
		if chromium.main_window: main_count += 1
	if main_count != 1:
		printerr("FAIL: expected one session status owner")
		quit(1)
		return
	await create_timer(0.5).timeout
	print("PASS: frontend restored both Chromium windows; detaching")
	wrapper.detach()
