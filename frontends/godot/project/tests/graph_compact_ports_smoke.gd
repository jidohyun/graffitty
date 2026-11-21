extends SceneTree
const Graph := preload("res://tests/support/ServerGraph.gd")
const Overlay := preload("res://scenes/AgentGraphOverlay.gd")
var failures := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func run() -> void:
	var graph := Graph.new()
	root.add_child(graph)
	graph.set_process(false)
	var outputs := []
	for i in 5:
		outputs.append({"id": "out%d" % i, "name": "Output %d" % i, "mode": "send", "color": ["#ff0000", "#00ff00", "#0000ff", "#ffff00", "#ff00ff"][i], "line_style": "solid" if i % 2 else "dashed"})
	for key in ["%1", "%2", "%3"]:
		graph.nodes[key] = {"provider": "adapter", "manifest": {"inputs": [{"id": "in"}], "outputs": outputs}}
	for i in 5:
		graph.connect_nodes({"from": "%1", "to": "%2", "from_port": "out%d" % i, "to_port": "in", "send": true})
	graph.connect_nodes({"from": "%1", "to": "%3", "from_port": "out0", "to_port": "in", "send": true})
	graph.edges["%1/out4>%2/in"].muted = true
	var saved: Dictionary = graph.edges.duplicate(true)
	var canvas := Control.new()
	# Exercise a theme minimum taller than the nominal socket hit target.
	# Socket resize callbacks must settle instead of exhausting the message queue.
	canvas.add_theme_font_size_override("font_size", 40)
	root.add_child(canvas)
	var overlay := Overlay.new()
	canvas.add_child(overlay)
	overlay.graph = graph
	var rectangles := {"%1": Rect2(0, 0, 120, 60), "%2": Rect2(300, 0, 120, 60), "%3": Rect2(300, 180, 120, 60)}
	overlay.sync(rectangles, graph.edges.values(), func(p): return p, true)
	for i in 4: await process_frame
	check(overlay.compact_nodes.size() == 3, "Short nodes collapse without changing bounds")
	check(overlay.compact_bundles.size() == 2, "Five connections to one node and another destination produce two bundles")
	check(overlay.sheet_links.size() == 6 and graph.edges == saved, "All logical edges and their settings survive")
	check(overlay.tools.route_builds == 2, "Only one route is built per destination")
	var visible := 0
	for key in overlay.sockets(true):
		if key.begins_with("%1/") and overlay.sockets(true)[key].visible: visible += 1
	check(visible == 1, "Exactly one output connector is visible")
	var connector: Button = overlay.sockets(true)["%1/out0"]
	check(connector.get_meta("bundle_colors").size() == 5 and connector.get_meta("stack_pitch") == 6.0, "Compact connector stacks all five colors with slightly overlapping dots")
	check(connector.size.y >= 32, "Hit target contains the entire overlapping stack")
	var shared: PackedVector2Array = overlay.sheet_links[0].points
	for link in overlay.sheet_links:
		if link.target == "%2": check(link.points == shared, "Bundle members share exact geometry")
	var copy: Node2D = overlay.wire_layer.still_copy(false)
	check(copy.commands.size() > 0, "Compact texture produces retained draw commands")
	var texture: Texture2D = copy.commands[0][1][3]
	var image := texture.get_image()
	check(image.get_width() == 160, "Texture includes all five member styles")
	check(image.get_pixel(0, 4).r > 0.9 and image.get_pixel(12, 4).a == 0, "Red dashed member retains color and gaps")
	check(image.get_pixel(44, 4).g > 0.9, "Green solid member remains solid")
	check(image.get_pixel(131, 4).r > 0.9 and image.get_pixel(128, 0).a == 0, "Muted member retains color with dotted pattern")
	copy.free()
	var builds: int = overlay.tools.route_builds
	overlay.sync(rectangles, graph.edges.values(), func(p): return p + Vector2(10, 10), true)
	check(overlay.tools.route_builds == builds, "Panning compact nodes does not rebuild routes")
	for zoom in [0.1, 0.02]:
		overlay.sync(rectangles, graph.edges.values(), func(p): return p * zoom, true)
		var zoomed: Node2D = overlay.wire_layer.still_copy(false)
		var vertices: PackedVector2Array = zoomed.commands[0][1][0]
		check(vertices[0].distance_to(vertices[3]) * zoom >= 3.99, "Compact wires keep a four-pixel minimum when zoomed out")
		check(overlay.tools.route_builds == builds, "Minimum wire width reuses the cached route")
		zoomed.free()
	overlay.sync(rectangles, graph.edges.values(), func(p): return p * 4, true)
	check(overlay.compact_nodes.is_empty() and overlay.compact_bundles.is_empty(), "Zooming in restores separate ports and wires")
	for key in overlay.sockets(true):
		if key.begins_with("%1/"):
			var center: Vector2 = overlay.port_center(key, true)
			check(center.y >= 0 and center.y <= 240, "Expanded port stays within projected terminal height")
	check(graph.edges == saved and rectangles["%1"].size.y == 60, "Presentation never mutates graph or terminal dimensions")
	overlay.sync(rectangles, graph.edges.values(), func(p): return p, true)
	overlay._connect_compact("%1/out0", "%3/in")
	var menu: PopupMenu
	for child in overlay.get_children():
		if child is PopupMenu: menu = child
	check(menu != null and menu.item_count == 5, "Compact connection offers all real output ports")
	if menu != null:
		menu.index_pressed.emit(3)
		menu.hide()
	check(graph.edges.has("%1/out3>%3/in"), "Chosen output connects to another terminal without replacing existing connections")
	canvas.add_theme_font_size_override("font_size", 10)
	var touch := preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	var min_pitch := 44.0 if touch else 28.0
	var connected: Dictionary = graph.edges.duplicate(true)
	var large := {"%1": Rect2(0, 0, 400, 800), "%2": Rect2(700, 0, 400, 800), "%3": Rect2(1400, 0, 400, 800)}
	overlay.sync(large, graph.edges.values(), func(p): return p * .25, true)
	check(overlay.compact_nodes.is_empty(), "A 200-pixel pane spreads five usable ports even at quarter zoom")
	var previous_bottom := -INF
	for i in 5:
		var port: Button = overlay.sockets(true)["%%1/out%d" % i]
		var center := port.position + port.size * .5
		check(port.visible and center.y >= 4 and center.y <= 196, "Expanded port dots fit the projected pane")
		check(port.position.y >= previous_bottom - .01, "Expanded hit targets do not overlap")
		check(overlay.nearest_socket(center).get("key") == "%%1/out%d" % i, "Each expanded target selects its own named output")
		previous_bottom = port.position.y + port.size.y
		if i > 0:
			var previous: Button = overlay.sockets(true)["%%1/out%d" % (i - 1)]
			check(center.y - (previous.position.y + previous.size.y * .5) >= min_pitch - .01, "Zoomed-out ports retain comfortable screen spacing")
		var link: Dictionary = overlay.sheet_links.filter(func(row): return row.from_socket == "%%1/out%d" % i)[0]
		check(center.distance_to(link.a * .25) < .01, "Wire endpoint follows the displayed port")
	builds = overlay.tools.route_builds
	overlay.sync(large, graph.edges.values(), func(p): return p * .3 + Vector2(25, 15), true)
	check(overlay.tools.route_builds == builds, "Spreading ports during zoom deforms cached paths without rerouting")
	overlay.sync(large, graph.edges.values(), func(p): return p * .1, true)
	check(overlay.compact_nodes.size() == 3, "An 80-pixel pane compacts when independent targets cannot fit")
	check(graph.edges == connected, "Zoom changes only presentation")
	root.gui_snap_controls_to_pixels = true
	rectangles["%1"].size.y = 26.4
	overlay.sync(rectangles, graph.edges.values(), func(p): return p, true)
	for i in 4: await process_frame
	check(connector.size.y == (44 if touch else 27), "Fractional compact stack settles at a whole-pixel hit target")
	canvas.free()
	graph.free()
	quit(1 if failures else 0)
