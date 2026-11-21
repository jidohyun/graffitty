extends SceneTree
const Graph := preload("res://tests/support/ServerGraph.gd")
const Overlay := preload("res://scenes/AgentGraphOverlay.gd")
var failures := 0
func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1
func _initialize() -> void: call_deferred("run")
func run() -> void:
	root.size = Vector2i(1000, 700)
	var graph := Graph.new()
	root.add_child(graph)
	graph.set_process(false)
	var canvas := Control.new()
	canvas.size = Vector2(1000, 700)
	root.add_child(canvas)
	var rects := {"%1": Rect2(550, 50, 200, 150), "%2": Rect2(60, 450, 150, 100), "%3": Rect2(250, 350, 150, 100), "%4": Rect2(300, 10, 150, 100)}
	for i in range(1, 5):
		var id := "%%%d" % i
		graph.nodes[id] = {"provider":"adapter"}
		graph.register_ports(id, {"name":id,"inputs":[{"id":"in","name":"Receive"}],"outputs":[{"id":"out","color":["#89ddbd","#8ecaff","#ffd47a","#ee8585"][i-1]}]})
		var panel := Panel.new()
		canvas.add_child(panel)
		panel.position = rects[id].position
		panel.size = rects[id].size
	for i in [2,3,4]: graph.connect_nodes({"from":"%%%d" % i,"from_port":"out","to":"%1","to_port":"in"})
	var overlay := Overlay.new()
	canvas.add_child(overlay)
	overlay.size = canvas.size
	overlay.graph = graph
	overlay.sync(rects,graph.edges.values(),func(p):return p,true)
	for link in overlay.links:
		var tangent: Vector2 = (link.b - link.controls[2]).normalized()
		check(tangent.y < 0 if link.source != "%4" else tangent.y > 0, "Wire reaches input from its source's side: " + link.source)
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-natural-arrivals.png")
	# Distinct source panes must not collapse into one return lane either.
	for i in [2,3,4]: rects["%%%d" % i].position.x = 800 + i * 10
	overlay.sync(rects,graph.edges.values(),func(p):return p,true)
	var approaches := {}
	for link in overlay.links:
		approaches[link.controls[2]] = true
		check((link.b - link.controls[2]).normalized().y < -0.5, "Return route approaches from below")
	check(approaches.size() == 3, "Different source panes retain separate return approaches")
	quit(1 if failures else 0)
