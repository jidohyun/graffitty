extends "res://llm-e2e/replay/replay.gd"
## Fast real-window preflight before a full demo recording.
var output := ""

func play() -> void:
	var url := "about:blank"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--demo-output="): output = arg.trim_prefix("--demo-output=")
		if arg.begins_with("--demo-url="): url = arg.trim_prefix("--demo-url=")
	var chromium: Node = await host.create_chromium_session(url)
	if not check(chromium != null, "Private chromium is created"): return
	var deadline := Time.get_ticks_msec() + 20000
	while not chromium.chromium_ready and Time.get_ticks_msec() < deadline: await process_frame
	if not check(chromium.chromium_ready, "Private chromium is ready"): return
	chromium.open_native()
	deadline = Time.get_ticks_msec() + 10000
	while not chromium.native_visible and Time.get_ticks_msec() < deadline: await process_frame
	if not check(chromium.native_visible, "Native presentation is visible"): return
	check(preload("NativeWindowLayout.gd").float_owned_window(chromium.pid), "Only the private Chromium window floats")
	var resized: Dictionary = await chromium.request("resize", {"width": 900, "height": 500})
	check(not resized.has("error"), "Native content size applied")
	OS.delay_msec(300)
	var capture := preload("NativeWindowCapture.gd").new(self, chromium)
	capture.sample()
	if not capture.failed:
		var dimensions: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("native-window/window.json")))
		print("NATIVE_WINDOW_DIMENSIONS ", dimensions.width, "x", dimensions.height)
		check(int(dimensions.width) <= 1964 and int(dimensions.height) <= 1160, "Native window fits the composition")
	chromium.return_to_preview()
	deadline = Time.get_ticks_msec() + 10000
	while chromium.native_visible and Time.get_ticks_msec() < deadline: await process_frame
	check(not chromium.native_visible, "Native window returns to its embedded pane")
	host.close_chromium_session(chromium.session_id)
