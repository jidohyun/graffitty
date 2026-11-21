extends SceneTree
const Graph := preload("res://tests/support/ServerGraph.gd")
const Overlay := preload("res://scenes/AgentGraphOverlay.gd")
var failures := 0

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func button(at: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = at
	event.pressed = pressed
	return event

func _initialize() -> void:
	var isolated := OS.get_temp_dir().path_join("graffitty-graph-ports-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	call_deferred("run")

func run() -> void:
	var funnel := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../../../apps/cli/assets/icons/funnel.svg")).replace("currentColor", "#d8e2ef")
	check(preload("res://scenes/NodeIcon.gd").texture({"svg": funnel}) != null, "Lucide funnel renders through the node SVG icon protocol")
	for name in ["telegram", "slack", "discord"]:
		var svg := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://../../../apps/cli/assets/icons/" + name + ".svg"))
		check(preload("res://scenes/NodeIcon.gd").texture({"svg": svg}) != null, name + " brand SVG renders through the node icon protocol")
	root.size = Vector2i(1000, 600)
	var graph := Graph.new()
	root.add_child(graph)
	graph.set_process(false)
	for i in range(1, 4): graph.nodes["%%%d" % i] = {"provider": "adapter" if i == 1 else "codex"}
	graph.register_ports("%1", {"name": "Jev", "inputs": [{"id": "evaluate", "name": "Evaluate"}], "outputs": [
		{"id": "True", "name": "Approved", "color": "#33dd77"}, {"id": "False", "color": "#ee5566"}]})
	var canvas := Control.new()
	canvas.size = Vector2(1000, 600)
	root.add_child(canvas)
	var overlay := Overlay.new()
	canvas.add_child(overlay)
	overlay.size = canvas.size
	overlay.graph = graph
	var rects := {"%1": Rect2(80, 200, 220, 160), "%2": Rect2(650, 100, 220, 160), "%3": Rect2(650, 380, 220, 160)}
	var project := func(point: Vector2) -> Vector2: return point
	overlay.sync(rects, graph.edges.values(), project, true)
	check(overlay.sockets(true).size() == 12 and overlay.sockets(false).size() == 3, "Manifest adds separate inputs and outputs alongside built-in agent ports")
	var yes: Button = overlay.sockets(true)["%1/True"]
	var no: Button = overlay.sockets(true)["%1/False"]
	check(yes.tooltip_text == "Approved" and no.tooltip_text.is_empty(), "Names are optional tooltips, not persistent labels")
	check(yes.get_meta("port_color") == Color("33dd77") and no.get_meta("port_color") == Color("ee5566"), "Each output uses its declared colour")
	check(yes.position.distance_to(no.position) >= 24, "Ports have nonoverlapping hit areas")
	yes.gui_input.emit(button(Vector2.ZERO, true))
	overlay._input(button(overlay.port_center("%2/in", false), false))
	check(graph.edges.has("%1/True>%2/in"), "Dragging an advertised output connects directly without a panele dialog")
	no.gui_input.emit(button(Vector2.ZERO, true))
	overlay._input(button(overlay.port_center("%2/in", false), false))
	overlay.sync(rects, graph.edges.values(), project, true)
	check(graph.edges.size() == 2 and overlay.links.size() == 2, "Both outputs can connect independently to the same receiver")
	check(overlay.links[0].a != overlay.links[1].a, "Each wire starts at its own port")
	check(overlay.get_children().filter(func(child): return child is Button).size() == overlay.sockets(true).size() + overlay.sockets(false).size(), "Only ports are buttons; no persistent edge mode badges")
	var approved_link: Dictionary = overlay.links.filter(func(link): return link.from_socket == "%1/True")[0]
	var hover_point: Vector2 = approved_link.points[approved_link.points.size() / 2]
	var hover_motion := InputEventMouseMotion.new()
	hover_motion.position = hover_point
	overlay.tools._input(hover_motion)
	await create_timer(0.6).timeout
	check(overlay.edge_hint.visible and "Approved" in overlay.edge_hint_text.text and "Receive" in overlay.edge_hint_text.text, "Hovering a wire describes both connected ports")
	if DisplayServer.get_name() != "headless":
		RenderingServer.force_draw(false)
		root.get_texture().get_image().save_png("/tmp/graffitty-edge-tooltip.png")
	check(overlay.edge_hint.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Tooltip does not capture mouse input")
	hover_motion.position = Vector2(20, 20)
	overlay.tools._input(hover_motion)
	check(not overlay.edge_hint.visible, "Leaving the wire hides its tooltip")
	# Starting at an unused input also connects immediately, with undo support.
	var tools: Node = overlay.tools
	tools._input(button(overlay.port_center("%3/in", false), true))
	tools._input(button(overlay.port_center("%1/True", true), false))
	check(graph.edges.has("%1/True>%3/in"), "Input-to-output drag connects without a dialog")
	tools.undo()

	var emitted: Dictionary = graph.emit_output("%1", {"output": "False", "payload": {"text": "Changes requested"}})
	graph.ack("%2", emitted.result.events[0].event_id, "delivered")
	check(overlay.pulses[-1].key == "%1/False>%2/in", "Delivery animation follows the emitting output")
	var edge: Dictionary = graph.edges["%1/False>%2/in"].duplicate()
	check(overlay.tools.reconnect(edge, "to", "%3/in"), "Reconnect moves only the selected output's edge")
	check(graph.edges.has("%1/True>%2/in") and graph.edges.has("%1/False>%3/in"), "Reconnect preserves the other output")
	overlay.tools.undo()
	check(graph.edges.has("%1/False>%2/in"), "Undo restores port identity")
	overlay.sync(rects, graph.edges.values(), project, true)
	var declaration: Dictionary = graph.nodes["%1"].manifest.duplicate(true)
	declaration.outputs[0].color = "#6688ff"
	declaration.outputs[0].name = "Pass"
	graph.register_ports("%1", declaration)
	overlay.sync(rects, graph.edges.values(), project, true)
	check(yes.tooltip_text == "Pass" and yes.get_meta("port_color") == Color("6688ff"), "Readvertising updates colour and tooltip without replacing the socket")
	check(graph.edges.size() == 2, "Display changes preserve existing wires")
	# Returning wires to the same receiver use separate side and bottom lanes.
	rects["%1"] = Rect2(250, 80, 300, 140)
	rects["%2"] = Rect2(250, 320, 300, 180)
	overlay.sync(rects, graph.edges.values(), project, true)
	var bounds: Array[Rect2] = []
	for link in overlay.links:
		var bound := Rect2(link.points[0], Vector2.ZERO)
		for point in link.points: bound = bound.expand(point)
		bounds.append(bound)
	check(absf(bounds[0].end.x - bounds[1].end.x) >= 17 and absf(bounds[0].end.y - bounds[1].end.y) >= 17, "Parallel return wires have separate side and bottom lanes")
	declaration["icon"] = {"text": "⚖"}
	declaration.outputs[0]["icon"] = {"text": "✓"}
	graph.register_ports("%1", declaration)
	var badge := preload("res://scenes/AgentStatusBadge.gd").new()
	canvas.add_child(badge)
	badge.position = Vector2(250, 30)
	badge.set_agent("adapter", "idle", graph.nodes["%1"].manifest)
	check(badge.provider_label.text == "Jev" and badge.node_symbol.text == "⚖", "Node name and text icon replace generic Adapter identity")
	var icons := preload("res://scenes/NodeIcon.gd")
	check(icons.texture({"svg": '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><circle cx="10" cy="10" r="8" fill="green"/></svg>'}) != null, "Inline SVG renders as an icon")
	var wire_layer := preload("res://scenes/GraphWireLayer.gd").new()
	wire_layer.overlay = overlay
	canvas.add_child(wire_layer)
	canvas.move_child(wire_layer, 0)
	overlay.pulses.clear()
	overlay._message_transferred("%1", "%2", emitted.result.events[0].event_id)
	# Use the True output with its configured symbol for the visual preview.
	overlay.pulses[-1].key = "%1/True>%2/in"
	overlay.pulses[-1].distance = 110.0
	# Built-in source sockets select their own behavior.
	for mode in ["read", "send", "turn_completed"]:
		overlay.sockets(true)["%2/" + mode].gui_input.emit(button(Vector2.ZERO, true))
		overlay._input(button(overlay.port_center("%3/in", false), false))
		check(graph.edges.has("%2/" + mode + ">%3/in"), "Built-in " + mode + " socket creates its own wire")
	graph.nodes["%4"] = {"provider": "shell"}
	graph.nodes["%5"] = {"provider": "adapter"}
	rects["%4"] = Rect2(680, 40, 180, 100)
	rects["%5"] = Rect2(680, 180, 180, 100)
	overlay.sync(rects, graph.edges.values(), project, true)
	check(overlay.ports["%4"].is_empty() and overlay.ports["%5"].is_empty(), "Shell and unadvertised adapter panes have no sockets")
	# Draw node cards beneath the production overlay for visual inspection.
	for key in rects:
		var card := ColorRect.new()
		card.color = Color("172632")
		card.position = rects[key].position
		card.size = rects[key].size
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		canvas.add_child(card)
		canvas.move_child(card, 0)
		var label := Label.new()
		label.text = "Jev judge" if key == "%1" else key
		label.position = Vector2(18, 18)
		card.add_child(label)
	if DisplayServer.get_name() != "headless":
		await process_frame
		RenderingServer.force_draw(false)
		root.get_texture().get_image().save_png("/tmp/graffitty-node-ports.png")
	canvas.free()
	graph.free()
	# Drain queued overlay children before checking native resource shutdown.
	await process_frame
	await process_frame
	print("GRAPH_PORTS_SMOKE_REPLAY_PASS" if failures == 0 else "GRAPH_PORTS_SMOKE_REPLAY_FAIL")
	quit(1 if failures else 0)
