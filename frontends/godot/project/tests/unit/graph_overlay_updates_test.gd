extends "res://tests/unit/test_case.gd"
const Graph := preload("res://tests/support/ServerGraph.gd")
const Overlay := preload("res://scenes/AgentGraphOverlay.gd")

class MoveHost extends Node:
	var workspace_layout := {"active": 7}

class MovePane extends Control:
	var _dragging := false
	var _resizing := false

func test_remote_pane_frames_do_not_accumulate_offsets() -> void:
	var view := preload("res://scenes/WorkspaceView.gd").new()
	var host := MoveHost.new()
	var pane := MovePane.new()
	view.host = host
	view.panes = {"%1": pane}
	view.pane_rects = {"%1": Rect2(400, 200, 200, 100)}
	view._remote_move_tab = 7
	view._remote_move_offsets = {"%1": Vector2(-200, -100)}
	for weight in [1.0, 0.8, 0.5, 0.2, 0.0]:
		view._remote_move_weight = weight
		for repeat in 3:
			view._apply_pane_zoom("%1")
			expect(pane.position.is_equal_approx(Vector2(400, 200) + Vector2(-200, -100) * weight), "Repeated redraws stay on the path to the received position")
	pane._dragging = true
	pane.position = Vector2(650, 350)
	view._apply_pane_zoom("%1")
	expect(pane.position == Vector2(650, 350), "Local dragging retains control of the pane")
	pane.free()
	host.free()
	view.free()

func test_typing_zoom_preserves_route_and_follows_visible_sockets() -> void:
	var graph := Graph.new()
	graph.nodes = {"%1": {"provider": "codex"}, "%2": {"provider": "codex"}}
	graph.connect_nodes({"from": "%1", "to": "%2", "send": true})
	var parent := Control.new()
	var overlay := overlay_for(graph, parent)
	# Tall enough for every port row: this covers routing, not compact bundling.
	var resting := {"%1": Rect2(0, 0, 200, 200), "%2": Rect2(220, 0, 200, 200)}
	overlay.sync(resting, graph.edges.values(), func(p): return p, true, resting)
	var original: PackedVector2Array = overlay.links[0].points.duplicate()
	var previous := original
	for step in range(1, 41):
		var visual := resting.duplicate()
		visual["%1"] = Rect2(0, -step, 200 + step * 4, 200 + step * 2)
		overlay.sync(visual, graph.edges.values(), func(p): return p, true, resting)
		var link: Dictionary = overlay.links[0]
		expect(link.points.size() == original.size(), "Zoom crossing the return-route threshold preserves curve topology")
		expect(link.points[0].is_equal_approx(link.a) and link.points[-1].is_equal_approx(link.b), "Wire stays attached to visible sockets")
		for i in original.size():
			expect(link.points[i].distance_to(previous[i]) < 5.0, "Small zoom steps cannot jump to a detour")
		previous = link.points.duplicate()
	graph.changed.emit()
	expect(overlay.links[0].points == previous, "Graph refresh retains the resting routing geometry")
	overlay.sync(resting, graph.edges.values(), func(p): return p, true, resting)
	expect(overlay.links[0].points == original, "Zoom release restores the exact resting wire")
	var moved := resting.duplicate()
	moved["%1"] = Rect2(500, 0, 200, 200)
	overlay.sync(moved, graph.edges.values(), func(p): return p, true, moved)
	expect(overlay.links[0].points.size() != original.size(), "Actual pane movement can still select a return route")
	parent.free()
	graph.free()

func test_zoom_does_not_reorder_return_lanes_or_move_manual_reroutes() -> void:
	var graph := Graph.new()
	graph.nodes = {"%1": {"provider": "codex"}, "%2": {"provider": "codex"}, "%3": {"provider": "codex"}}
	graph.connect_nodes({"from": "%1", "to": "%2", "send": true})
	graph.connect_nodes({"from": "%3", "to": "%2", "send": true})
	var parent := Control.new()
	var overlay := overlay_for(graph, parent)
	var resting := {"%1": Rect2(500, 0, 200, 100), "%2": Rect2(0, 0, 200, 100), "%3": Rect2(500, 120, 200, 100)}
	overlay.sync(resting, graph.edges.values(), func(p): return p, true, resting)
	var untouched: PackedVector2Array = overlay.links[1].points.duplicate()
	var visual := resting.duplicate()
	visual["%1"] = Rect2(500, 0, 400, 500)
	overlay.sync(visual, graph.edges.values(), func(p): return p, true, resting)
	expect(overlay.links[1].points == untouched, "Zooming a peer cannot reorder or displace another return lane")
	var edge: String = graph.edges.keys()[0]
	var anchor := Vector2(350, 350)
	overlay.tools.local_visual = {"routes": {edge: ["reroute:1"]}, "reroutes": {"reroute:1": {"position": anchor}}}
	overlay.sync(visual, graph.edges.values(), func(p): return p, true, resting)
	expect(anchor in overlay.links[0].points, "Explicit reroute remains exactly where the user placed it")
	parent.free()
	graph.free()

func overlay_for(graph: Node, parent: Node) -> Control:
	var overlay := Overlay.new()
	parent.add_child(overlay)
	overlay.tools.overlay = overlay
	overlay.graph = graph
	# Tall enough that each port keeps its own socket instead of a compact bundle.
	overlay.sync({"%1": Rect2(0, 0, 200, 200), "%2": Rect2(400, 0, 200, 200)}, graph.edges.values(), func(p): return p, true)
	return overlay

func test_detection_updates_ports_without_another_layout_pass() -> void:
	var graph := Graph.new()
	graph.nodes = {"%1": {"provider": "shell"}, "%2": {"provider": "codex"}}
	var parent := Control.new()
	var overlay := overlay_for(graph, parent)
	var outputs: Array = overlay.sockets(true).keys()
	expect(not outputs.is_empty() and outputs.all(func(id): return str(id).begins_with("%2/")), "Only the known agent has output ports")
	graph.nodes["%1"].provider = "codex"
	graph.changed.emit()
	expect(overlay.has_socket("%1/send", true) and overlay.has_socket("%1/in", false), "Detection creates sockets synchronously with the status notification")
	graph.connect_nodes({"from": "%1", "to": "%2", "send": true})
	expect(overlay.links.size() == 1, "Connection appears without another layout pass")
	graph.nodes["%1"].provider = "shell"
	graph.nodes["%1"].erase("manifest")
	graph.changed.emit()
	expect(not overlay.has_socket("%1/send", true) and overlay.links.is_empty(), "Provider removal also refreshes sockets and geometry immediately")
	parent.free()
	graph.free()

func test_delete_selected_reroute_keeps_delivery_and_supports_undo() -> void:
	var graph := Graph.new()
	graph.nodes = {"%1": {"provider": "codex"}, "%2": {"provider": "codex"}}
	graph.connect_nodes({"from": "%1", "to": "%2", "send": true})
	graph.enqueue("%1", "%2", "pending", "message")
	var parent := Control.new()
	var overlay := overlay_for(graph, parent)
	var tools = overlay.tools
	var edge: String = graph.edges.keys()[0]
	tools.local_visual = {"routes": {edge: ["reroute:1"]}, "reroutes": {"reroute:1": {"position": Vector2(300, 50)}}}
	tools.selected = {"reroute:1": true}
	tools.delete_visual_selection()
	expect(tools.visual().reroutes.is_empty() and graph.edges.size() == 1 and graph.queues["%2"].size() == 1, "Removing a bend preserves permission and pending delivery")
	tools.undo()
	expect(tools.visual().reroutes.has("reroute:1"), "Undo restores the bend")
	parent.free()
	graph.free()

func test_overlapping_socket_targets_choose_nearest_center() -> void:
	var graph := Graph.new()
	graph.nodes = {"%1": {"provider": "codex"}, "%2": {"provider": "codex"}}
	var parent := Control.new()
	var overlay := overlay_for(graph, parent)
	var output: Button = overlay.sockets(true)["%1/send"]
	var input: Button = overlay.sockets(false)["%2/in"]
	output.position = Vector2(200, 50)
	input.position = Vector2(208, 50)
	expect(overlay.nearest_socket(output.position + output.size * .5) == {"key": "%1/send", "output": true}, "Output center wins even under a later input hit target")
	expect(overlay.nearest_socket(input.position + input.size * .5) == {"key": "%2/in", "output": false}, "Input center remains selectable in the overlap")
	parent.free()
	graph.free()

func test_remote_reroute_animation_does_not_mutate_shared_positions() -> void:
	var overlay := Overlay.new()
	var tools: Node = overlay.tools
	tools.local_visual = {"routes": {}, "reroutes": {"bend": {"position": Vector2(400, 200)}}}
	tools.tab_id = 7
	tools.remote_tab = 7
	tools.remote_offsets = {"bend": Vector2(-200, -100)}
	tools.remote_weight = 1.0
	expect(tools.render_position("bend") == Vector2(200, 100), "Animation starts at the previously displayed position")
	tools.remote_weight = 0.5
	expect(tools.render_position("bend") == Vector2(300, 150), "Intermediate position is display-only")
	expect(tools.visual().reroutes.bend.position == Vector2(400, 200), "Shared state remains at the committed destination")
	tools.before = {"visual": tools.visual().duplicate(true)}
	expect(tools.render_position("bend") == Vector2(400, 200), "A local drag takes precedence over remote animation")
	overlay.free()
