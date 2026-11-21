extends SceneTree
## Windowed renderer A/B. Run with --no-focus-skip and an idle native shell.
## Same PTYs, pane layout, resolution and compatible effects in both worlds.
var host: Node
var samples: Array[Dictionary] = []
var folder := OS.get_environment("GRAFFITTY_2D_ARTIFACTS")
var motion := false
var phase := 0.0
func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("flat-benchmark-%d" % OS.get_process_id())
	OS.set_environment("XDG_CONFIG_HOME",isolated.path_join("config"))
	OS.set_environment("XDG_STATE_HOME",isolated.path_join("state"))
	if folder.is_empty(): folder = OS.get_cache_dir().path_join("graffitty-flat-2d")
	DirAccess.make_dir_recursive_absolute(folder)
	run.call_deferred()
func _process(dt: float) -> bool:
	if motion and is_instance_valid(host) and host.world != null:
		phase += dt
		var view: Control = host.workspace_view
		view.overview = true
		view.navigation_zoom = 1.15 + .15*sin(phase)
		view.navigation_center = view.canvas_size()*.5+Vector2(sin(phase*.7)*60,cos(phase*.9)*30)
		host.world._apply_camera_fx()
	return false
func run() -> void:
	host = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(host)
	await create_timer(2).timeout
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1600,1000)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for count in [1,8]:
		while host.workspace_view.panes.size()<count:
			host.create_terminal_window(host.pane_focus)
			await process_frame
		await create_timer(2).timeout
		for round_index in 4:
			var path := "" if round_index in [0,3] else "flat-2d"
			host.switch_world(path)
			var world: Node = host.world
			world.fx_enabled = false
			world.tab_fx = false
			world.fx_curvature_deg = 0.0
			Engine.max_fps = 0
			for scenario in ["rest","zoom_pan"]:
				motion = scenario == "zoom_pan"
				phase = 0.0
				host.workspace_view.overview = motion
				world._settle_camera_at_rest()
				world._apply_camera_fx()
				await create_timer(1.0).timeout
				var frames: Array[float] = []
				var process_ms := 0.0
				var calls := 0.0
				var start := Time.get_ticks_usec()
				var previous := start
				while Time.get_ticks_usec()-start < 3000000:
					await RenderingServer.frame_post_draw
					var now := Time.get_ticks_usec()
					frames.append((now-previous)/1000.0)
					previous = now
					process_ms += Performance.get_monitor(Performance.TIME_PROCESS)*1000.0
					calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
				var elapsed := (previous-start)/1000000.0
				frames.sort()
				var sample := {"world":"Flat" if path.is_empty() else "Flat 2D","panes":count,"scenario":scenario,"round":round_index,
					"frames":frames.size(),"seconds":elapsed,"fps":frames.size()/elapsed,
					"frame_mean_ms":elapsed*1000.0/frames.size(),"frame_p50_ms":frames[frames.size()/2],"frame_p95_ms":frames[int(frames.size()*.95)],
					"process_mean_ms":process_ms/frames.size(),"draw_calls_mean":calls/frames.size(),
					"video_memory_mib":Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)/1048576.0,
					"objects":Performance.get_monitor(Performance.OBJECT_NODE_COUNT)}
				samples.append(sample)
				print("BENCHMARK "+JSON.stringify(sample))
				var file := FileAccess.open(folder.path_join("benchmark.json"),FileAccess.WRITE)
				file.store_string(JSON.stringify({"godot":Engine.get_version_info().string,"os":OS.get_name(),"cpu":OS.get_processor_name(),"gpu":RenderingServer.get_video_adapter_name(),"window":root.size,"vsync":"disabled","effects":"off; zoom/pan driven identically","order":"A B B A","warmup_seconds":1,"sample_seconds":3,"samples":samples},"  "))
			motion = false
	quit()
