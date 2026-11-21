extends SceneTree
## Windowed diagnostic; synthetic input to post-draw is NOT input-to-photon
## latency. godot --path . --script tools/benchmark_idle_latency.gd --
## --shell=/bin/cat --no-fx Add --direct-2d for a bare native Terminal Control
## without the workspace/world.
##
## Add --idle-only to skip synthetic input timing. CPU excludes child
## processes. Add --fps=120 to test a particular frame cap instead of 60 and
## 30.
##
## Add --production to measure idle with the application's own render
## settings.
var host: Node
var terminal: Control
var direct := false
var frame_events := 0
var drawn := 0
var pending := false
var expected := ""
var started := 0
var output_us := 0
var paint_us := 0
var samples: Array = []

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("idle-latency-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME", isolated)
	OS.set_environment("XDG_STATE_HOME", isolated)
	direct = "--direct-2d" in OS.get_cmdline_user_args()
	run.call_deferred()

func cpu_seconds() -> float:
	var output := []
	OS.execute("ps", ["-p", str(OS.get_process_id()), "-o", "time="], output)
	var fields := str(output[0]).strip_edges().split(":")
	return float(fields[-1]) + float(fields[-2]) * 60.0

func frame_changed() -> void:
	frame_events += 1
	if pending and paint_us == 0 and expected in str(terminal.get_text(false).get("text", "")):
		paint_us = Time.get_ticks_usec()

func post_draw() -> void:
	drawn += 1
	if pending and paint_us > 0:
		var end := Time.get_ticks_usec()
		samples.append({"output_ms": (output_us - started) / 1000.0,
			"paint_ms": (paint_us - started) / 1000.0,
			"post_draw_ms": (end - started) / 1000.0})
		pending = false

func idle_sample(label: String) -> void:
	await create_timer(1.0).timeout
	var cpu := cpu_seconds()
	var start := Time.get_ticks_usec()
	var first_frame := Engine.get_process_frames()
	var first_draw := drawn
	var first_paint := frame_events
	await create_timer(5.0).timeout
	var elapsed := (Time.get_ticks_usec() - start) / 1000000.0
	print("BENCH ", JSON.stringify({"kind": "idle", "mode": label, "direct_2d": direct,
		"elapsed_s": elapsed, "cpu_percent_one_core": 100.0 * (cpu_seconds() - cpu) / elapsed,
		"process_fps": (Engine.get_process_frames() - first_frame) / elapsed,
		"draw_fps": (drawn - first_draw) / elapsed, "terminal_paints": frame_events - first_paint,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"video_memory_bytes": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)}))

func latency_sample(cap: int) -> void:
	Engine.max_fps = cap
	OS.low_processor_usage_mode = false
	samples.clear()
	for index in 24:
		await create_timer(0.08 + (index % 7) * 0.013).timeout
		# Inject after a draw, exercising the next process/render cycle.
		await RenderingServer.frame_post_draw
		expected += "x"
		output_us = 0
		paint_us = 0
		started = Time.get_ticks_usec()
		pending = true
		var event := InputEventKey.new()
		event.keycode = KEY_X
		event.unicode = 120
		event.pressed = true
		root.push_input(event, true)
		event = event.duplicate()
		event.pressed = false
		root.push_input(event, true)
		while pending and Time.get_ticks_usec() - started < 2000000:
			await process_frame
		if pending:
			push_error("Timed out waiting for echoed marker: " + expected)
			quit(1)
			return
	var summary := {"kind": "latency", "direct_2d": direct, "cap": cap, "n": samples.size()}
	for metric in ["output_ms", "paint_ms", "post_draw_ms"]:
		var values: Array = samples.map(func(sample): return sample[metric])
		values.sort()
		summary[metric] = {"p50": values[values.size() / 2], "p95": values[ceili(values.size() * 0.95) - 1], "max": values[-1]}
	print("BENCH ", JSON.stringify(summary))

func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Run windowed: headless cannot measure rendering.")
		quit(1)
		return
	root.size = Vector2i(1000, 650)
	if direct:
		terminal = ClassDB.instantiate("Terminal")
		terminal.shell = "/bin/cat"
		terminal.login_shell = false
		terminal.size = Vector2(1000, 650)
		root.add_child(terminal)
	else:
		host = load("res://scenes/terminal.tscn").instantiate()
		root.add_child(host)
		terminal = host.sessions[host.active_session_id].term
	# Keep the same internal render extent despite desktop tiling/DPI changes.
	root.content_scale_factor = 1.0
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.content_scale_size = Vector2i(1000, 650)
	root.unresizable = true
	root.min_size = Vector2i(1000, 650)
	root.max_size = Vector2i(1000, 650)
	root.size = Vector2i(1000, 650)
	terminal.configure_advanced({"cursor_blink": 0})
	terminal.frame_changed.connect(frame_changed)
	terminal.output.connect(func(_bytes):
		if pending and output_us == 0: output_us = Time.get_ticks_usec())
	RenderingServer.frame_post_draw.connect(post_draw)
	await create_timer(3.0).timeout
	terminal.grab_focus()
	print("BENCH ", JSON.stringify({"kind": "environment", "direct_2d": direct,
		"engine": Engine.get_version_info().string, "window": root.size, "render_size": root.content_scale_size,
		"renderer": RenderingServer.get_current_rendering_method(),
		"vsync": DisplayServer.window_get_vsync_mode(), "focused": root.has_focus(),
		"low_processor_mode": OS.low_processor_usage_mode}))
	if "--production" in OS.get_cmdline_user_args():
		await idle_sample("production")
		quit()
		return
	Engine.max_fps = 0
	await idle_sample("uncapped_vsync")
	var caps := [60, 30]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fps="):
			caps = [maxi(1, int(arg.get_slice("=", 1)))]
	for cap in caps:
		Engine.max_fps = cap
		await idle_sample("capped_%d" % cap)
		if "--idle-only" not in OS.get_cmdline_user_args():
			await latency_sample(cap)
	Engine.max_fps = 60
	OS.low_processor_usage_mode = true
	await idle_sample("low_processor_60")
	OS.low_processor_usage_mode = false
	quit()
