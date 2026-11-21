extends SceneTree
## macOS process-CPU A/B benchmark; creates isolated idle shell panes and quits.
## godot --path . --script tools/benchmark_workspace_physics_app.gd -- --shell=/bin/sh --no-fx
## Reports total Godot process CPU (100% = one core), not chromium/shell child CPU or GPU.
const Layout := preload("res://scenes/WorkspaceLayout.gd")
var host: Node

func _initialize() -> void:
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("physics-bench-%d" % OS.get_process_id()))
	run.call_deferred()

func cpu_seconds() -> float:
	var output := []
	OS.execute("ps", ["-p", str(OS.get_process_id()), "-o", "time="], output)
	var fields := str(output[0]).strip_edges().split(":")
	return float(fields[-1]) + float(fields[-2]) * 60.0

func run() -> void:
	host = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(host)
	await create_timer(2.0).timeout
	var view: Control = host.workspace_view
	view.set_physics_process(false)
	Engine.max_fps = 60
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	for count in [4, 12]:
		while view.pane_rects.size() < count:
			host.create_terminal_window(host.pane_focus)
			await process_frame
		var keys: Array = view.pane_rects.keys()
		for i in keys.size():
			Layout.find(group.tree, keys[i])["rect"] = Rect2(20 + (i % 3) * 340, 60 + (i / 3) * 240, 320, 220)
		view.refresh()
		await create_timer(2.0).timeout
		for mode in ["off", "sleeping", "active", "off"]:
			group.tree["physics"] = mode != "off"
			view.pane_physics.reset()
			view.moving = keys[0] if mode != "sleeping" else ""
			view._physics_process(1.0 / 60)
			if mode == "sleeping":
				view.pane_physics.sleep()
			var cpu_start := cpu_seconds()
			var start := Time.get_ticks_usec()
			var callback_us := 0.0
			var frames := 0
			while Time.get_ticks_usec() - start < 3000000:
				await process_frame
				if mode != "sleeping":
					var rect: Rect2 = view.pane_rects[keys[0]]
					rect.position.x += .25 if frames % 120 < 60 else -.25
					view.pane_rects[keys[0]] = rect
					Layout.find(group.tree, keys[0])["rect"] = rect
					view.panes[keys[0]].position = rect.position
				var tick := Time.get_ticks_usec()
				view._physics_process(1.0 / 60)
				callback_us += Time.get_ticks_usec() - tick
				frames += 1
			var elapsed := (Time.get_ticks_usec() - start) / 1000000.0
			print(JSON.stringify({"panes":count,"mode":mode,"process_cpu_percent_one_core":100 * (cpu_seconds()-cpu_start)/elapsed,"callback_mean_us":callback_us/maxf(frames,1),"fps":frames/elapsed}))
		view.moving = ""
		group.tree["physics"] = false
	quit()
