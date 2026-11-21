extends SceneTree
## Geometry invariants, not machine-dependent FPS thresholds.
const Graph := preload("res://tests/support/ServerGraph.gd")
const Overlay := preload("res://scenes/AgentGraphOverlay.gd")
var failures := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func settle() -> void:
	for i in 4: await process_frame
func run() -> void:
	var graph := Graph.new()
	root.add_child(graph)
	graph.set_process(false)
	var canvas := Control.new()
	root.add_child(canvas)
	var rectangles := {}
	for i in 14:
		var key := "%%%d" % i
		graph.nodes[key] = {"provider": "adapter", "manifest": {"inputs": [{"id": "in"}], "outputs": [{"id": "out", "mode": "send", "line_style": "dashed"}]}}
		rectangles[key] = Rect2(100 + (i % 4) * 200, 100 + (i / 4) * 150, 120, 100)
	for i in 14:
		for step in [1, 3, 5]: graph.connect_nodes({"from": "%%%d" % i, "to": "%%%d" % ((i + step) % 14), "send": true})
	var overlay := Overlay.new()
	canvas.add_child(overlay)
	overlay.graph = graph
	overlay.sync(rectangles, graph.edges.values(), func(p): return p, true)
	await settle()
	check(overlay.sheet_links.size() == 42, "Large graph has 42 retained routes")
	var builds: int = overlay.tools.route_builds
	var draws: int = overlay.wire_layer.draw_count
	var geometry: int = overlay.geometry_rebuilds
	var original: Array = overlay.sheet_links.duplicate(true)
	var started := Time.get_ticks_usec()
	for i in 20:
		var transform := Transform2D(0.01 * i, Vector2(20 + i, 30))
		overlay.sync(rectangles, graph.edges.values(), func(p): return transform * p, true)
	print("BENCH camera sync %.3fms" % [(Time.get_ticks_usec() - started) / 20000.0])
	await settle()
	check(overlay.geometry_rebuilds == geometry and overlay.tools.route_builds == builds, "Camera movement never rebuilds geometry or routes")
	check(overlay.sheet_links == original, "Camera movement preserves authored sheet geometry")
	check(overlay.wire_layer.draw_count == draws, "Camera movement does not repaint retained wires")
	var event: Dictionary = graph.enqueue("%0", "%1", "queued", "message")
	check(event.has("result") and overlay.waiting.size() == 1, "Fixture really has a queued message")
	await settle()
	draws = overlay.wire_layer.draw_count
	var marker_draws: int = overlay.marker_layer.draw_count
	await create_timer(0.15).timeout
	check(overlay.wire_layer.draw_count == draws, "Blinking a queue marker never repaints wires")
	check(overlay.marker_layer.draw_count > marker_draws or DisplayServer.get_name() == "headless", "Only animated marker layer repaints")
	builds = overlay.tools.route_builds
	var wire_draws: int = overlay.wire_layer.wire_draw_count()
	rectangles["%0"].position += Vector2(10, 5)
	overlay.sync(rectangles, graph.edges.values(), func(p): return p, true)
	var rebuilt: int = overlay.tools.route_builds - builds
	check(rebuilt > 0 and rebuilt < 42, "Dragging one pane rebuilds only dependent routes (%d/42)" % rebuilt)
	await settle()
	var repainted: int = overlay.wire_layer.wire_draw_count() - wire_draws
	check(repainted > 0 and repainted < 42, "Dragging one pane repaints only changed wire canvases (%d/42)" % repainted)
	for link in overlay.links:
		check(link.points[0].is_equal_approx(overlay.port_center(link.from_socket, true)), "Wire endpoint matches its socket")
	canvas.free()
	graph.free()
	quit(1 if failures else 0)
