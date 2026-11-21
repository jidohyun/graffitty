extends SceneTree
const Graph := preload("res://tests/support/ServerGraph.gd")
const Overlay := preload("res://scenes/AgentGraphOverlay.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")
var failures := 0

class Host extends Node:
	signal ui_changed
	var workspace_layout := Layout.new()
	var pane_focus := "%0"

class View extends Control:
	var host := Host.new()
	var overlay: Control
	var pane_rects := {}
	var panes := {}
	var overview := true
	var text_focus := false
	func has_text_focus() -> bool: return text_focus
	var navigation_center := Vector2.ZERO
	var navigation_zoom := 1.0
	func canvas_point_at(point: Vector2) -> Vector2: return point
	func view_point(point: Vector2) -> Vector2: return point
	func _cancel_main_magnet() -> void: pass
	func _apply_navigation() -> void: pass
	func wake_pane_physics() -> void: pass
	func refresh() -> void:
		pane_rects.clear()
		Layout.arrange(host.workspace_layout.tab(0).tree, Rect2(0, 100, 1000, 600), pane_rects)
		overlay.sync(pane_rects, overlay.graph.edges.values(), view_point, true)
	func _exit_tree() -> void: host.free()

func check(value: bool, label: String) -> void:
	print("PASS " if value else "FAIL ", label)
	if not value: failures += 1

func mouse(point: Vector2, pressed: bool, button := MOUSE_BUTTON_LEFT, alt := false) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = button
	event.pressed = pressed
	event.alt_pressed = alt
	return event

func motion(point: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = point
	return event

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var graph := Graph.new()
	root.add_child(graph)
	graph.set_process(false)
	# Advertised ports exercise the same server authority as the application.
	for i in 3: graph.nodes["%%%d" % i] = {"provider": "adapter", "manifest": {"inputs": [{"id": "in", "color": "#8ecaff"}], "outputs": [{"id": "out", "mode": "send", "color": "#89ddbd"}]}}
	var view := View.new()
	root.add_child(view)
	view.size = Vector2(1100, 800)
	var windows: Array = []
	for i in 3: windows.append({"pane": "%%%d" % i, "rect": Rect2(60 + i * 350, 200 + i * 110, 220, 160)})
	view.host.workspace_layout.add(0, {"windows": windows, "tiling": false})
	var overlay := Overlay.new()
	view.add_child(overlay)
	overlay.size = view.size
	overlay.graph = graph
	view.overlay = overlay
	overlay.tools.view = view
	view.refresh()
	var tools: Node = overlay.tools
	tools.animate_camera = false
	# Port dragging is exercised with real advertised ports in graph_ports_smoke.
	# The server derives permissions from the advertised output.
	tools.begin_edit()
	graph.connect_nodes({"from": "%0", "to": "%1", "send": true, "contains": "queued"})
	tools.finish_edit()
	tools.undo()
	check(graph.edges.is_empty(), "Undo removes the new connection")
	tools.redo()
	check(graph.edges.has("%0/out>%1/in"), "Redo restores its settings")
	view.refresh()
	var link: Dictionary = overlay.links[0]
	var middle: Vector2 = link.points[12]
	var double := mouse(middle, true)
	double.double_click = true
	tools._input(double)
	check(tools.visual().routes["%0/out>%1/in"].size() == 1, "Double-click inserts a visual reroute")
	tools._input(mouse(middle, true))
	tools._input(motion(middle + Vector2(0, 90)))
	tools._input(mouse(middle + Vector2(0, 90), false))
	check(tools.visual().reroutes[tools.visual().routes["%0/out>%1/in"][0]].position.distance_to(middle + Vector2(0, 90)) < 0.1, "Waypoint drag changes the wire path")
	check(graph.edges.size() == 1, "Rerouting does not create agents or permissions")
	tools.undo()
	check(tools.visual().reroutes[tools.visual().routes["%0/out>%1/in"][0]].position.distance_to(middle) < 0.1, "Waypoint movement is undoable")
	# Pause cancels queued events; undo restores permissions, not old messages.
	graph.connect_nodes(graph.edges["%0/out>%1/in"].merged({"send": true, "contains": "queued"}, true))
	graph.enqueue("%0", "%1", "queued", "message")
	tools.begin_edit()
	graph.connect_nodes(graph.edges["%0/out>%1/in"].merged({"muted": true}, true))
	tools.finish_edit()
	check(graph.queues["%1"].is_empty(), "Mute cancels pending work")
	check(graph.enqueue("%0", "%1", "blocked", "message").has("error"), "Muted sends are rejected")
	var context: Dictionary = await graph.lifecycle("%1", {"provider": "adapter", "event": "PreToolUse"})
	check(context.result.graph_changed and context.result.adjacent.incoming[0].muted, "Next hook teaches the muted connection")
	await graph.lifecycle("%0", {"provider": "adapter", "event": "Stop", "text": "finished while paused"})
	check(graph.queues["%1"].is_empty(), "Muted turn completion notifications are skipped")
	tools.undo()
	check(not graph.edges["%0/out>%1/in"].muted and graph.queues["%1"].is_empty(), "Undo mute restores settings without replaying cancelled work")
	# Move the destination with the real Alt-drag interaction.
	view.refresh()
	tools._input(mouse(overlay.port_center("%1/in", false), true, MOUSE_BUTTON_LEFT, true))
	check(tools.gesture.get("kind") == "reconnect", "Alt-drag starts a reconnect preview")
	tools._input(motion(overlay.port_center("%2/in", false)))
	tools._input(mouse(overlay.port_center("%2/in", false), false))
	check(graph.edges.has("%0/out>%2/in") and not graph.edges.has("%0/out>%1/in"), "Reconnect moves the endpoint")
	check(graph.edges["%0/out>%2/in"].send and graph.edges["%0/out>%2/in"].contains == "queued", "Reconnect retains permissions")
	tools.undo()
	check(graph.edges.has("%0/out>%1/in"), "Reconnect is undoable")
	view.refresh()
	link = overlay.links[0]
	middle = link.points[10]
	tools._input(mouse(middle - Vector2(0, 50), true, MOUSE_BUTTON_RIGHT, true))
	tools._input(motion(middle + Vector2(0, 50)))
	tools._input(mouse(middle + Vector2(0, 50), false, MOUSE_BUTTON_RIGHT, true))
	check(graph.edges.is_empty(), "Cut gesture disconnects intersected wires")
	tools.undo()
	check(graph.edges.has("%0/out>%1/in"), "Cut undo restores the edge")
	# Fitting selected terminals remains available without grouping.
	tools.selected = {"%0": true, "%1": true}
	tools.fit_selected()
	check(view.navigation_center == tools.bounds_for(tools.selection()).get_center(), "Fit selected centers the camera on the selection")
	tools.selected = {"%0": true}
	tools.fit_connected()
	check(view.navigation_center == tools.bounds_for(["%0", "%1"]).get_center(), "Fit connected includes connected neighbors")
	check(tools.related({"source": "%0", "target": "%1"}) and not tools.related({"source": "%1", "target": "%2"}), "Selection highlights incident links and dims unrelated links")
	# Do not overwrite an external agent's newer edge edit with undo.
	tools.begin_edit()
	graph.disconnect_nodes("%0", "%1")
	tools.finish_edit()
	graph.connect_nodes({"from": "%0", "to": "%1", "muted": true})
	tools.undo()
	check(graph.edges["%0/out>%1/in"].muted, "Undo preserves conflicting external changes")
	# Source-derived topology: shared output cuts and downstream mute propagation.
	var topology := preload("res://scenes/GraphVisualTopology.gd")
	var data := {"routes": {}, "groups": []}
	data.groups = [{"id": "frame:old", "name": "Old"}]
	data.parents = {"a": "frame:old"}
	topology.normalize(data)
	check(not data.has("groups") and not data.has("parents"), "Legacy frame metadata is retired")
	var edges := {
		"a>b": {"from": "a", "to": "b", "muted": false},
		"a>c": {"from": "a", "to": "c", "muted": true},
		"d>c": {"from": "d", "to": "c", "muted": false},
	}
	var segments := topology.segments(data, edges)
	var cuts: Array = []
	for segment in segments:
		if segment.from == "a": cuts.append({"segment": segment, "position": Vector2(100, 100 if segment.to == "b" else 200)})
	var inserted := topology.insert_cuts(data, cuts)
	check(inserted.size() == 1 and data.routes["a>b"] == data.routes["a>c"], "Intersected fan-out shares one reroute per output socket")
	var reroute: String = inserted[0]
	check(data.reroutes[reroute].position == Vector2(100, 150), "Shared reroute uses mean intersection location")
	check(not data.routes.has("d>c"), "Reroute gesture leaves uncut sockets alone")
	segments = topology.segments(data, edges)
	var stems: Array = segments.filter(func(segment): return segment.from == "a")
	check(stems.size() == 1 and stems[0].edges.size() == 2 and not stems[0].muted, "Shared stem is unique and stays active while one branch is active")
	edges["a>b"].muted = true
	stems = topology.segments(data, edges).filter(func(segment): return segment.from == "a")
	check(stems[0].muted, "All muted branches propagate mute upstream")
	edges["a>c"].muted = false
	stems = topology.segments(data, edges).filter(func(segment): return segment.from == "a")
	check(not stems[0].muted, "Unmuting a branch unmutes its shared stem")
	topology.remove_reroute(data, reroute)
	check(data.routes["a>b"].is_empty() and data.routes["a>c"].is_empty(), "Deleting a shared reroute reconnects every visual branch")
	# New controls exercise actual input dispatch on live graph/layout objects.
	for edge in graph.edges.values().duplicate(): graph.disconnect_edge(edge)
	tools.visual().routes.clear()
	tools.visual().reroutes.clear()
	tools.selected.clear()
	graph.connect_nodes({"from": "%0", "to": "%1", "send": true})
	graph.connect_nodes({"from": "%0", "to": "%2", "send": true})
	view.refresh()
	var output_at: Vector2 = overlay.port_center("%0/out", true)
	var detach_drag := mouse(output_at, true)
	detach_drag.ctrl_pressed = true
	tools._input(detach_drag)
	check(tools.gesture.kind == "reconnect" and tools.gesture.edges.size() == 2, "Ctrl-drag output picks every outgoing link")
	check(tools.preview_detached("%0/out>%1/in") and graph.edges.size() == 2, "Detach preview leaves permissions intact until drop")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	tools._input(escape)
	check(tools.gesture.is_empty() and graph.edges.size() == 2, "Escape cancels a batch reconnect without changing permissions")
	tools._input(detach_drag)
	tools._input(mouse(Vector2(50, 740), false))
	check(graph.edges.is_empty(), "Dropping detached links in empty space disconnects the batch")
	tools.undo()
	check(graph.edges.size() == 2, "Batch reconnect undo restores all edges as one edit")
	# Input sockets select the wire under the cursor, remembering the last hit.
	graph.disconnect_nodes("%0", "%1")
	graph.connect_nodes({"from": "%1", "to": "%2", "send": true})
	view.refresh()
	tools._input(mouse(overlay.port_center("%2/in", false), true))
	check(tools.gesture.kind == "pick_input", "Multi-input starts link selection instead of picking the first edge")
	var incoming: Dictionary = overlay.links.filter(func(item): return item.source == "%1")[0]
	tools._input(motion(incoming.points[8]))
	check(tools.gesture.kind == "reconnect" and tools.gesture.edge.from == "%1", "Following a multi-input wire selects that particular connection")
	tools._input(escape)
	# A gesture crosses two fan-out branches; the shared reroute is not an agent.
	for edge in graph.edges.values().duplicate(): graph.disconnect_edge(edge)
	graph.connect_nodes({"from": "%0", "to": "%1", "send": true})
	graph.connect_nodes({"from": "%0", "to": "%2", "send": true})
	view.refresh()
	var wire_a: Dictionary = overlay.links[0]
	var wire_b: Dictionary = overlay.links[1]
	var mid_x: float = (wire_a.a.x + wire_a.b.x) / 2
	var reroute_drag := mouse(Vector2(mid_x, 110), true, MOUSE_BUTTON_RIGHT)
	reroute_drag.shift_pressed = true
	tools._input(reroute_drag)
	tools._input(motion(Vector2(mid_x, 760)))
	tools._input(mouse(Vector2(mid_x, 760), false, MOUSE_BUTTON_RIGHT))
	check(tools.visual().reroutes.size() == 1 and tools.visual().routes.size() == 2, "Shift-right gesture inserts a shared fan-out reroute")
	check(graph.nodes.size() == 3 and graph.edges.size() == 2, "Visual topology creates no agents or new permission edges")
	var shared: String = tools.visual().reroutes.keys()[0]
	var stem: Dictionary = tools.visual_segments().filter(func(segment): return segment.to == shared)[0]
	var rendered_stem: Dictionary = tools.visual_segments(true, false).filter(func(segment): return segment.to == shared)[0]
	check(stem.points == rendered_stem.points, "Reroute hit-testing and drawing use identical direction-aware paths")
	check(rendered_stem.points == preload("res://scenes/GraphLinkGeometry.gd").sample_controls(tools.reroute_controls(stem.from, stem.to, stem.points[0], stem.points[-1])), "Reroute drawing uses adaptive curve sampling")
	var stem_mid: Vector2 = stem.points[stem.points.size() / 2]
	var mute_drag := mouse(stem_mid - Vector2(0, 30), true, MOUSE_BUTTON_RIGHT, true)
	mute_drag.ctrl_pressed = true
	tools._input(mute_drag)
	tools._input(motion(stem_mid + Vector2(0, 30)))
	tools._input(mouse(stem_mid + Vector2(0, 30), false, MOUSE_BUTTON_RIGHT))
	check(graph.edges.values().all(func(edge): return edge.muted), "Ctrl-Alt-right gesture on a shared stem mutes all downstream connections")
	tools.undo()
	check(graph.edges.values().all(func(edge): return not edge.muted), "Shared-stem mute is one undoable edit")
	check(is_equal_approx(tools.camera_factor(Vector2.ZERO, 1.0, Vector2.ZERO, 2.0), 1.0), "Blender camera duration factor saturates on doubled zoom")
	check(is_zero_approx(tools.camera_factor(Vector2.ZERO, 1.0, Vector2.ZERO, 1.0)), "Unchanged camera has zero animation factor")
	check(preload("res://scenes/GraphLinkGeometry.gd").interaction_curve(Vector2.ZERO, Vector2(100, 200)).size() == 25, "Gesture intersection uses Blender's 25 CPU samples")
	var old_route: Array = tools.visual().routes["%0/out>%1/in"].duplicate()
	check(tools.reconnect(graph.edges["%0/out>%1/in"], "from", "%2/out"), "A shared branch can move to a different source")
	check(tools.visual().routes["%2/out>%1/in"] != old_route and tools.visual().routes["%0/out>%2/in"] == old_route, "Source reconnect splits reroutes without changing the other branch")
	tools.undo()
	# Each direction has its own displayed path and cut target.
	for edge in graph.edges.values().duplicate(): graph.disconnect_edge(edge)
	tools.visual().routes.clear()
	tools.visual().reroutes.clear()
	graph.connect_nodes({"from": "%0", "to": "%1", "send": true})
	graph.connect_nodes({"from": "%1", "to": "%0", "send": true})
	view.refresh()
	var bidirectional: Dictionary = overlay.links[0]
	check(overlay.links.size() == 2 and tools.visual_segments().size() == 2, "Bidirectional links have two independent displayed and selectable paths")
	var cut_at: Vector2 = preload("res://scenes/GraphLinkGeometry.gd").at_distance(bidirectional.points, bidirectional.lengths, bidirectional.lengths[-1] * 0.5)
	var cut_drag := mouse(cut_at - Vector2(0, 40), true, MOUSE_BUTTON_RIGHT)
	cut_drag.ctrl_pressed = true
	tools._input(cut_drag)
	tools._input(motion(cut_at + Vector2(0, 40)))
	tools._input(mouse(cut_at + Vector2(0, 40), false, MOUSE_BUTTON_RIGHT))
	check(graph.edges.size() == 1 and graph.edges.has("%1/out>%0/in"), "Cut removes only the forward wire and preserves feedback")
	tools.undo()
	check(graph.edges.size() == 2, "Cut undo restores the removed direction")
	# Removed grouping cannot capture terminal keys or show controls.
	tools.begin_edit()
	tools.add_reroute(overlay.links[0], Vector2(400, 180))
	tools.finish_edit()
	var visual_before: Dictionary = tools.visual().duplicate(true)
	var non_command := KEY_MASK_CTRL if OS.get_name() == "macOS" else KEY_MASK_META
	for combination in [KEY_BACKSPACE, KEY_DELETE, KEY_F, KEY_J | KEY_MASK_CTRL, KEY_P | KEY_MASK_ALT, KEY_KP_PERIOD, KEY_Z | non_command]:
		var event: InputEventKey = preload("res://graffitty/terminal_config.gd").KeyBinding.new(combination, "").key
		event.pressed = true
		root.push_input(event, true)
		check(not root.is_input_handled(), "Graph leaves terminal key unconsumed: " + event.as_text())
	check(tools.visual() == visual_before, "Terminal editing keys leave selected graph items intact")
	var undo_key := InputEventKey.new()
	undo_key.keycode = KEY_Z
	undo_key.meta_pressed = OS.get_name() == "macOS"
	undo_key.ctrl_pressed = OS.get_name() != "macOS"
	undo_key.pressed = true
	check(tools.handle_undo_shortcut(undo_key), "Platform undo shortcut is handled by graph undo")
	check(tools.visual() != visual_before, "Platform undo shortcut undoes the last graph edit")
	undo_key.pressed = false
	check(tools.handle_undo_shortcut(undo_key), "Undo key release is consumed")
	undo_key.pressed = true
	undo_key.shift_pressed = true
	check(tools.handle_undo_shortcut(undo_key), "Platform redo shortcut is handled by graph redo")
	check(tools.visual() == visual_before, "Platform redo shortcut restores the graph edit")
	undo_key.pressed = false
	tools.handle_undo_shortcut(undo_key)
	var text_field := LineEdit.new()
	view.add_child(text_field)
	text_field.grab_focus()
	undo_key.pressed = true
	check(not tools.handle_undo_shortcut(undo_key), "Native text field keeps its own undo shortcut")
	text_field.release_focus()
	text_field.queue_free()
	view.text_focus = true
	check(not tools.handle_undo_shortcut(undo_key), "Embedded browser or canvas editor keeps its redo shortcut")
	undo_key.shift_pressed = false
	check(not tools.handle_undo_shortcut(undo_key), "Embedded browser or canvas editor keeps its undo shortcut")
	undo_key.pressed = false
	check(not tools.handle_undo_shortcut(undo_key), "Unconsumed browser undo release reaches its owner")
	check(tools.visual() == visual_before, "Browser editing shortcuts leave graph history intact")
	view.text_focus = false
	var feedback_source := overlay.port_center("%2/out", true)
	var feedback_target := overlay.port_center("%0/in", false)
	var feedback_preview: Dictionary = tools.route_points("%2/out>%0/in", feedback_source, feedback_target)
	var lower_edge := maxf(overlay.pane_screen_bounds["%2"].end.y, overlay.pane_screen_bounds["%0"].end.y)
	check(Array(feedback_preview.points).any(func(point): return is_equal_approx(point.y, lower_edge + 40.0)), "Feedback preview clears both endpoint panes by 40px")
	var free_preview: Dictionary = tools.route_points("%2>", feedback_source, feedback_target)
	check(Array(free_preview.points).any(func(point): return is_equal_approx(point.y, maxf(feedback_target.y, overlay.pane_screen_bounds["%2"].end.y) + 40.0)), "Unsnapped backward preview clears the source pane")
	view.refresh()
	var rebuilds: int = overlay.geometry_rebuilds
	for i in 20: view.refresh()
	check(overlay.geometry_rebuilds == rebuilds, "Idle frames reuse graph geometry")
	var saved_position: Vector2 = tools.visual().reroutes.values()[0].position
	tools.visual().reroutes.values()[0].position += Vector2(8, 0)
	view.refresh()
	check(overlay.geometry_rebuilds == rebuilds + 1, "Moving a reroute invalidates graph geometry")
	tools.visual().reroutes.values()[0].position = saved_position
	view.refresh()
	# Rendering ownership: persistent wires share the pane canvas, while the
	# tooltip and interactive preview retain their screen-space overlay.
	var pane_canvas := Control.new()
	view.add_child(pane_canvas)
	var occluding_pane := Panel.new()
	pane_canvas.add_child(occluding_pane)
	overlay.mount_wire_layer(pane_canvas, func(point: Vector2): return point * 2 + Vector2(30, 40))
	check(overlay.wire_layer.get_parent() == pane_canvas and overlay.wire_layer.get_index() < occluding_pane.get_index(), "Established wires draw in the pane canvas before foreground panes")
	check(overlay.edge_hint.get_parent() == overlay and overlay.tools.get_parent() == overlay, "Tooltip and connection preview remain in the screen overlay")
	check(overlay.wire_layer.point(Vector2(20, 10)) == Vector2(20, 10), "Retained wire geometry is already in sheet coordinates")
	check(is_equal_approx(overlay.wire_layer.local_width(Vector2.ZERO, 3), 3), "Retained wire strokes move with the sheet camera")
	check(overlay.marker_layer.point(Vector2(20, 10)) == Vector2(70, 60), "Screen-sized animated markers still unproject into the sheet")
	await process_frame
	await process_frame
	view.free()
	graph.free()
	quit(1 if failures else 0)
