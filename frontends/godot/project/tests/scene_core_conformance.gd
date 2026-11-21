extends SceneTree
## Frozen traces captured from the established Godot implementation, before the port.
## No legacy implementation is shipped. GRAFFITTY_SCENE_REFERENCE is only an authoring input.
var failures: Array[String] = []
var trace: Dictionary = {}
var events: Array = []

func implementation(name: String, path: String) -> GDScript:
	var reference := OS.get_environment("GRAFFITTY_SCENE_REFERENCE")
	return load(reference.path_join(name + ".gd") if not reference.is_empty() else path)

func plain(value: Variant) -> Variant:
	if value is Vector2: return [value.x, value.y]
	if value is Vector3: return [value.x, value.y, value.z]
	if value is Vector4: return [value.x, value.y, value.z, value.w]
	if value is Transform3D: return [plain(value.basis.x), plain(value.basis.y), plain(value.basis.z), plain(value.origin)]
	if value is Rect2: return [plain(value.position), plain(value.size)]
	if value is Dictionary:
		var result := {}
		for key in value: result[str(key)] = plain(value[key])
		return result
	if value is Array or value is PackedVector2Array or value is PackedVector3Array or value is PackedFloat32Array or value is PackedInt32Array:
		var result := []
		for item in value: result.append(plain(item))
		return result
	return value

func check(actual: Variant, expected: Variant, path := "") -> void:
	if failures.size() >= 12: return
	if (actual is float or actual is int) and (expected is float or expected is int):
		if absf(actual - expected) > 0.002 + absf(expected) * 0.00002:
			failures.append("%s: %.9f != %.9f" % [path, actual, expected])
	elif actual is Array and expected is Array:
		if actual.size() != expected.size(): failures.append("%s: array length %d != %d" % [path, actual.size(), expected.size()])
		else:
			for i in actual.size(): check(actual[i], expected[i], path + "/" + str(i))
	elif actual is Dictionary and expected is Dictionary:
		if actual.size() != expected.size(): failures.append(path + ": dictionary size differs")
		for key in expected:
			if not actual.has(key): failures.append(path + ": missing " + key)
			else: check(actual[key], expected[key], path + "/" + key)
	elif actual != expected: failures.append("%s: %s != %s" % [path, actual, expected])

func _initialize() -> void:
	var isolated := OS.get_temp_dir().path_join("graffitty-scene-conformance-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")

func run() -> void:
	var motion = implementation("CameraMotion", "res://scenes/CameraMotion.gd")
	var geometry = implementation("GraphLinkGeometry", "res://scenes/GraphLinkGeometry.gd")
	var physics = implementation("WorkspacePhysics", "res://scenes/WorkspacePhysics.gd")
	var gestures = implementation("TouchNavigation", "res://scenes/input/TouchNavigation.gd")
	var scroll = implementation("TouchScrollMotion", "res://scenes/input/TouchScrollMotion.gd")
	trace.navigation = []
	var reference_dir := OS.get_environment("GRAFFITTY_SCENE_REFERENCE")
	for graph in [ [[ [1, .10000000001], [2, .3]], [[2, .1]], [], []], [[[1, 3], [2, 1]], [], [[1, 1]]], [[], []], [[[1,1.0],[2,1.0],[3,1.0]],[],[[4,1.0]],[[4,1.0]],[]] ]:
		var native_graph: RefCounted = ClassDB.instantiate("SceneNavigationGraph") if reference_dir.is_empty() else null
		if native_graph != null: native_graph.replace(graph)
		for ends in [Vector2i(0, 1), Vector2i(0, 2), Vector2i(1, 1), Vector2i(-1, 0), Vector2i(0, 4)]:
			if reference_dir.is_empty(): trace.navigation.append(plain(native_graph.route(ends.x, ends.y)))
			else:
				var route = load(reference_dir.path_join("Navigation.gd")).new()
				route.nav_adj = graph
				route.nav_nodes.resize(graph.size())
				trace.navigation.append(plain(route._route(ends.x, ends.y)))
	trace.camera = []
	var a: Dictionary = motion.pose(Vector3(2, 3, 8), Vector3(0.1, -.2, -1).normalized(), Vector3.UP, Vector4(-.4, -.3, .8, .6))
	var b: Dictionary = motion.pose(Vector3(32, 5, -8), Vector3(-.3, .1, -1).normalized(), Vector3.UP, Vector4(-.2, -.2, .5, .4))
	for routed in [false, true]:
		var model = motion.new()
		model.reset(a)
		model.retarget(b, 2.1, PackedVector3Array([Vector3(12, 10, 5), Vector3(24, 6, -6)]) if routed else PackedVector3Array())
		for i in 180:
			if i == 45: model.retarget_on_path(a, 1.7)
			if i == 75: model.retarget_on_path(b, 1.4)
			if i == 100:
				var resized := b.duplicate()
				resized.rect = Vector4(-.4, -.1, .8, .3)
				model.retarget_remaining(resized)
			model.advance(1.0 / 60)
			if i % 5 == 0: trace.camera.append(plain([model.frame, model.velocity, model.angular_velocity, model.framing_velocity, model.moving]))
	trace.framing = []
	for zoom in [.8, 1.0, 1.6]:
		for tilt in [Vector2.ZERO, Vector2(.1, -.08), Vector2(-.15, .2)]:
			trace.framing.append(plain(motion.frame_pane(a, zoom, Vector2(.2, -.15), tilt, 10.0)))
			trace.framing.append(plain(motion.frame_sheet(a, zoom, Vector2(.1, .2), tilt, Vector3.ZERO, Vector3.RIGHT * 12, Vector3.DOWN * 8)))
			trace.framing.append(plain(motion.compose(a, zoom, Vector2(.1, .2), tilt, Vector3.ZERO, Vector3.RIGHT * 12, Vector3.DOWN * 8, Vector3(1, 1, 0), .05, true)))
	trace.graph = []
	for source in [Vector2.ZERO, Vector2(400, 100), Vector2(-40, 500)]:
		for target in [Vector2(500, 200), Vector2(100, 400), source]:
			var c: PackedVector2Array = geometry.controls(source, target)
			trace.graph.append(plain([c, geometry.sample_controls(c), geometry.arrow(c), geometry.arrow(c, true), geometry.arrival_controls(source, target)]))
			for natural in [false, true]:
				var route: Dictionary = geometry.feedback_curve(source, target, 600, 40, natural)
				trace.graph.append(plain([route, geometry.deform_endpoints(route, Vector2(20, -10), Vector2(-8, 30))]))
	trace.physics = []
	var simulation = physics.new()
	var rectangles: Dictionary[String, Rect2] = {"held": Rect2(200,200,320,200), "free": Rect2(200,200,320,200), "third": Rect2(520,200,320,200)}
	var movable: Dictionary[StringName, bool] = {"free": false, "third": false}
	for i in 720:
		if i < 30: rectangles.held.position.x += 2
		if i == 60: movable.held = false
		if i == 120:
			rectangles.erase("third")
			movable.erase("third")
		rectangles.assign(simulation.step(rectangles, movable, Rect2(0,0,1200,800), 1.0/60))
		if i % 30 == 0: trace.physics.append(plain([rectangles, simulation.sleeping]))
	var gesture = gestures.new()
	check([gesture.held, gesture.navigating, gesture.long_pressed, gesture.scrolling], [false, false, false, false], "gesture/initial-state")
	gesture.pointer.connect(func(event):
		if event is InputEventMouseButton: events.append(["button", event.position, event.pressed, event.button_index, event.double_click, event.canceled, event.button_mask])
		else: events.append(["motion", event.position, event.relative, event.button_mask]))
	gesture.pinch.connect(func(previous, center, factor): events.append(["pinch", previous, center, factor]))
	gesture.scroll.connect(func(anchor, delta, stage):
		if stage != "ended": events.append(["scroll", anchor, delta]))
	gesture.canceled.connect(func(): events.append(["cancel"]))
	for cycle in 4:
		var now := cycle * 1000
		touch(gesture, 0, true, Vector2(10,10), now)
		if cycle == 0:
			gesture.advance(now + 130)
			drag(gesture, 0, Vector2(70,10), now + 150)
		elif cycle == 1: gesture.advance(now + 600)
		else:
			touch(gesture, 1, true, Vector2(110,10), now + 20)
			if cycle == 3: touch(gesture, 2, true, Vector2(210,10), now + 40)
			gesture.advance(now + 180)
			drag(gesture, 1, Vector2(130,40), now + 200)
			touch(gesture, 1, false, Vector2(130,40), now + 210)
			drag(gesture, 0, Vector2(50,30), now + 230)
			if cycle == 3: touch(gesture, 2, false, Vector2(210,10), now + 240)
		touch(gesture, 0, false, Vector2(50,30), now + 250 if cycle != 1 else now + 650)
		gesture.advance(now + 700)
		gesture.cancel()
	trace.touch = plain(events)
	trace.momentum = []
	for step in [8, 16, 33, 100]:
		var model = scroll.new()
		model.begin(0)
		for i in 8: model.track(Vector2(12, -7), i * 12)
		model.release(90)
		var total := Vector2.ZERO
		for now in range(90 + step, 1500, step): total += model.advance(now)
		trace.momentum.append(plain([total, model.velocity]))
	var reference := OS.get_environment("GRAFFITTY_SCENE_REFERENCE")
	var path := "res://tests/fixtures/scene_core_godot.json"
	if not reference.is_empty():
		FileAccess.open(path, FileAccess.WRITE).store_string(JSON.stringify(trace))
		print("Recorded stable Godot scene traces")
	else:
		check(trace, JSON.parse_string(FileAccess.get_file_as_string(path)))
		for failure in failures: printerr(failure)
		print("SCENE_CORE_CONFORMANCE ", "PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func touch(model: RefCounted, id: int, pressed: bool, position: Vector2, now: int) -> void:
	var event := InputEventScreenTouch.new()
	event.index = id; event.pressed = pressed; event.position = position
	model.handle(event, now)

func drag(model: RefCounted, id: int, position: Vector2, now: int) -> void:
	var event := InputEventScreenDrag.new()
	event.index = id; event.position = position
	model.handle(event, now)
