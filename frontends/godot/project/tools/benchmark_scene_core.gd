extends SceneTree
## A/B benchmark of the public Godot adapters, including native conversion costs.
## Requires the pre-port source directory; never ships or selects a runtime fallback.
const UserConfig := preload("res://config/UserConfig.gd")
var legacy := {}
var native := {}
var checksum := 0.0
var adjacency: Array = []
var nodes := PackedVector3Array()
var events: Array[InputEvent] = []
var results: Array = []

func _initialize() -> void:
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, OS.get_temp_dir().path_join("graffitty-scene-bench-%d/%s" % [OS.get_process_id(), kind]))
	call_deferred("run")

func run() -> void:
	var reference := OS.get_environment("GRAFFITTY_SCENE_REFERENCE")
	if reference.is_empty():
		printerr("Set GRAFFITTY_SCENE_REFERENCE to the saved pre-port GDScript directory")
		quit(1)
		return
	for name in ["CameraMotion", "GraphLinkGeometry", "WorkspacePhysics", "TouchNavigation", "TouchScrollMotion"]:
		legacy[name] = load(reference.path_join(name + ".gd"))
		native[name] = load("res://scenes/" + ("input/" if name.begins_with("Touch") else "") + name + ".gd")
	legacy.Navigation = load(reference.path_join("Navigation.gd"))
	# The navigation graph comes from the installed Bistro pack.
	var pack := UserConfig.stdpath("data").path_join("worlds/bistro/bistro.pck")
	if not ProjectSettings.load_resource_pack(pack, false):
		printerr("Install Bistro first: missing " + pack)
		quit(1)
		return
	var graph: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://worlds/bistro/navgraph.json"))
	for p in graph.nodes: nodes.append(Vector3(p[0], p[1], p[2]))
	adjacency.resize(nodes.size())
	for i in nodes.size(): adjacency[i] = []
	for e in graph.edges:
		adjacency[int(e[0])].append([int(e[1]), float(e[2])])
		adjacency[int(e[1])].append([int(e[0]), float(e[2])])
	for spec in [[0,0,10,10], [0,1,110,10], [2,1,130,30], [1,1,130,30], [2,0,40,20], [0,2,140,20], [2,2,160,40], [1,2,160,40], [1,0,40,20]]:
		var event: InputEvent
		if spec[0] == 2: event = InputEventScreenDrag.new()
		else:
			event = InputEventScreenTouch.new()
			event.pressed = spec[0] == 0
		event.index = spec[1]
		event.position = Vector2(spec[2], spec[3])
		events.append(event)
	for name in ["camera_frame", "graph_link", "graph_sample", "physics_active_4", "physics_active_12", "physics_active_64", "physics_idle_12", "world_route", "touch_gesture", "scroll_fling"]:
		var selected := OS.get_environment("GRAFFITTY_SCENE_BENCH_CASES")
		if not selected.is_empty() and name not in selected.split(","): continue
		var count := 16 if name == "world_route" else 1
		while true:
			var a := measure(name, legacy, count)
			var b := measure(name, native, count)
			if (maxf(a, b) if name == "world_route" else minf(a, b)) >= 30000 or count >= 131072: break
			count *= 2
		# Independent warmups, then alternate A/B order to reduce drift bias.
		measure(name, legacy, count)
		measure(name, native, count)
		var gd: Array[float] = []
		var rust: Array[float] = []
		for sample in 11:
			if sample % 2 == 0:
				gd.append(measure(name, legacy, count) / count)
				rust.append(measure(name, native, count) / count)
			else:
				rust.append(measure(name, native, count) / count)
				gd.append(measure(name, legacy, count) / count)
		var gd_sorted := gd.duplicate()
		var rust_sorted := rust.duplicate()
		gd_sorted.sort()
		rust_sorted.sort()
		var result := {"workload": name, "batch_count": count, "samples": 11, "gdscript_us": gd_sorted[5], "rust_us": rust_sorted[5], "speedup": gd_sorted[5] / rust_sorted[5], "gdscript_samples_us": gd, "rust_samples_us": rust}
		results.append(result)
		print("SCENE_BENCH ", JSON.stringify(result))
	var output := OS.get_environment("GRAFFITTY_SCENE_BENCH_OUTPUT")
	if not output.is_empty(): FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify({"results": results, "checksum": checksum, "godot": Engine.get_version_info().string, "nav_nodes": nodes.size(), "undirected_nav_edges": graph.edges.size()}, "\t"))
	print("SCENE_BENCH_PASS")
	quit()

func measure(name: String, implementation: Dictionary, count: int) -> float:
	return work(name, implementation, count)

func work(name: String, implementation: Dictionary, count: int) -> float:
	var begin := Time.get_ticks_usec()
	match name:
		"camera_frame":
			var script = implementation.CameraMotion
			var motion = script.new()
			var a: Dictionary = script.pose(Vector3(0,2,20), Vector3.FORWARD, Vector3.UP, Vector4(-.4,-.3,.8,.6))
			var b: Dictionary = script.pose(Vector3(40,8,-10), Vector3(-.2,0,-1).normalized(), Vector3.UP, Vector4(-.3,-.2,.6,.4))
			motion.reset(a)
			begin = Time.get_ticks_usec()
			for i in count:
				if i % 120 == 0: motion.retarget(b if (i / 120) % 2 == 0 else a, 2.0, PackedVector3Array([Vector3(12,8,12), Vector3(30,8,2)]))
				var frame: Dictionary = motion.advance(1.0 / 60)
				checksum += frame.transform.origin.x
		"graph_link":
			var script = implementation.GraphLinkGeometry
			begin = Time.get_ticks_usec()
			for i in count:
				var controls: PackedVector2Array = script.controls(Vector2(i % 100, 50), Vector2(500, 200))
				var points: PackedVector2Array = script.sample_controls(controls)
				var lengths: PackedFloat32Array = script.distances(points)
				checksum += script.arrow(controls).size() + lengths[-1]
		"graph_sample":
			var script = implementation.GraphLinkGeometry
			var points: PackedVector2Array = script.sample_controls(script.controls(Vector2(0,50), Vector2(500,200)))
			var lengths: PackedFloat32Array = script.distances(points)
			begin = Time.get_ticks_usec()
			for i in count:
				checksum += script.at_distance(points, lengths, lengths[-1] * (i % 100) / 100.0).x
		"world_route":
			var old = implementation.Navigation.new() if implementation.has("Navigation") else null
			var core: RefCounted = ClassDB.instantiate("SceneNavigationGraph")
			if old == null: core.replace(adjacency)
			if old != null:
				old.nav_nodes = nodes
				old.nav_adj = adjacency
			begin = Time.get_ticks_usec()
			for i in count:
				var route: PackedInt32Array = old._route(i % 14, (i + 7) % 14) if old != null else core.route(i % 14, (i + 7) % 14)
				checksum += route.size()
		"touch_gesture":
			var gesture = implementation.TouchNavigation.new()
			begin = Time.get_ticks_usec()
			for i in count:
				for j in events.size(): gesture.handle(events[j], i * 2000 + j * 150)
				gesture.advance(i * 2000 + 1500)
				gesture.cancel()
		"scroll_fling":
			var motion = implementation.TouchScrollMotion.new()
			begin = Time.get_ticks_usec()
			for i in count:
				motion.begin(0)
				for j in 8: motion.track(Vector2(12,-7), j * 12)
				motion.release(90)
				for now in range(106, 1500, 16): checksum += motion.advance(now).x
		_:
			var amount := int(name.get_slice("_", 2))
			var idle := name.contains("idle")
			var simulation = implementation.WorkspacePhysics.new()
			var rectangles: Dictionary[String,Rect2] = {}
			var movable: Dictionary[String,bool] = {}
			for i in amount:
				var key := str(i)
				rectangles[key] = Rect2(200 + (i % 8) * 350, 200 + (i / 8) * 270, 320, 220)
				if i > 0: movable[key] = false
			var area := Rect2(0,0,4000,3000)
			var constrain := func(_key: String, rect: Rect2) -> Rect2:
				rect.position = rect.position.clamp(area.position, area.end - rect.size)
				return rect
			if idle:
				for i in 1200: rectangles.assign(simulation.step(rectangles, movable, area, 1.0/60, constrain))
				assert(simulation.sleeping, "Idle benchmark requires a settled solver")
			begin = Time.get_ticks_usec()
			for i in count:
				if not idle: rectangles["0"].position.x += .4 if i % 120 < 60 else -.4
				rectangles.assign(simulation.step(rectangles, movable, area, 1.0/60, constrain))
			checksum += rectangles["0"].position.x
	return float(Time.get_ticks_usec() - begin)
