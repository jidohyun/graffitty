# SPDX-License-Identifier: GPL-2.0-or-later
# Blender interaction translations: see docs/developers/automation-and-extensions/blender-node-links.md.
extends Node
## Preview graph edits locally; publish their final geometry through workspace authority.
const Topology := preload("res://scenes/GraphVisualTopology.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")
const Ports := preload("res://scenes/GraphPorts.gd")
const Geometry := preload("res://scenes/GraphLinkGeometry.gd")
var overlay: Control
var view: Control
var selected: Dictionary = {}
var remote_offsets := {}
var remote_weight := 0.0
var remote_tab := -1
var local_visual := {"routes": {}}
var undo_stack: Array = []
var redo_stack: Array = []
var gesture: Dictionary = {}
var cut := PackedVector2Array()
var before: Dictionary = {}
var tab_id := -1
var hovered := ""
var path_action := "cut"
var undo_key_held := false
var reroute_menu: PopupMenu
var wire_menu: PopupMenu
var wire_menu_key := ""
enum WireAction { INSPECT, PAUSE, REMOVE }
var inspection_click := 0
var camera_tween: Tween
var animate_camera := true
var selection_glow := StyleBoxFlat.new()

func _ready() -> void:
	selection_glow.draw_center = false
	selection_glow.set_border_width_all(0)
	selection_glow.shadow_color = Color("8ecaff", 0.85)
	selection_glow.shadow_size = 9
	selection_glow.shadow_offset = Vector2.ZERO
	selection_glow.corner_detail = 12
	overlay = get_parent()

func visual() -> Dictionary:
	if view == null:
		Topology.normalize(local_visual)
		return local_visual
	var group: Dictionary = view.host.workspace_layout.tab(view.host.workspace_layout.active)
	if not group.has("graph_visual"): group["graph_visual"] = {"routes": {}}
	Topology.normalize(group.graph_visual)
	return group.graph_visual

func sync() -> void:
	if view != null and tab_id != view.host.workspace_layout.active:
		tab_id = view.host.workspace_layout.active
		selected.clear()
		gesture.clear()
		cut.clear()
	# Reconnect temporarily removes an edge before transferring its route.
	# Wait for the edit to finish before collecting unreferenced reroutes.
	if before.is_empty() and is_instance_valid(overlay.graph):
		Topology.prune(visual(), overlay.graph.edges)
	for key in selected.keys():
		if not overlay.ports.has(key) and not visual().reroutes.has(key): selected.erase(key)

func selection() -> Array:
	if not selected.is_empty(): return selected.keys()
	if view != null and overlay.ports.has(view.host.pane_focus): return [view.host.pane_focus]
	return []

func related(link: Dictionary) -> bool:
	var keys := selection()
	return keys.is_empty() or link.source in keys or link.target in keys or visual().routes.get(overlay.link_key(link), []).any(func(id): return id in keys)

func clean_edges() -> Dictionary:
	var result: Dictionary = overlay.graph.edges.duplicate(true)
	for edge in result.values(): edge.erase("revision")
	return result

func begin_edit() -> void:
	before = {"edges": clean_edges(), "visual": visual().duplicate(true), "tab": tab_id, "items": pane_items(), "layout": _layout_snapshot() }

func _layout_snapshot() -> Dictionary:
	return view.host.workspace_layout.tab(tab_id).get("tree", {}).duplicate(true) if view != null else {}

func finish_edit() -> void:
	if before.is_empty(): return
	Topology.prune(visual(), overlay.graph.edges)
	var after := {"edges": clean_edges(), "visual": visual().duplicate(true), "tab": tab_id, "items": pane_items(), "layout": _layout_snapshot() }
	if before != after:
		undo_stack.append({"before": before, "after": after})
		if undo_stack.size() > 64: undo_stack.pop_front()
		redo_stack.clear()
	var base: Dictionary = before.visual
	before = {}
	refresh()
	_publish_visual(base)

func _publish_visual(base: Dictionary) -> void:
	if view == null: return
	var group: Dictionary = view.host.workspace_layout.tab(tab_id)
	group["_graph_base"] = base
	view.host.ui_changed.emit()
	group.erase("_graph_base")

func restore_edit(action: Dictionary, backwards: bool) -> bool:
	var wanted: Dictionary = action.before if backwards else action.after
	var expected: Dictionary = action.after if backwards else action.before
	if wanted.tab != tab_id:
		push_warning("Switch to the tab where this edit was made to undo it.")
		return false
	if visual() != expected.visual:
		push_warning("Visual graph changed elsewhere; undo would overwrite it.")
		return false
	if wanted.layout != expected.layout and _layout_snapshot() != expected.layout:
		push_warning("Layout changed elsewhere; undo would overwrite it.")
		return false
	var current := clean_edges()
	var changed_keys: Array = wanted.edges.keys()
	for key in expected.edges:
		if key not in changed_keys: changed_keys.append(key)
	for key in changed_keys:
		if wanted.edges.get(key) == expected.edges.get(key): continue
		if current.get(key) != expected.edges.get(key):
			push_warning("Connection changed elsewhere; undo would overwrite it.")
			return false
		if wanted.edges.has(key) and (not overlay.graph.nodes.has(wanted.edges[key].from) or not overlay.graph.nodes.has(wanted.edges[key].to)):
			push_warning("A terminal was closed; this connection cannot be restored.")
			return false
		if wanted.edges.has(key):
			var edge: Dictionary = wanted.edges[key]
			if not Ports.has_port(overlay.graph.nodes[edge.from], true, str(edge.get("from_port", ""))) or not Ports.has_port(overlay.graph.nodes[edge.to], false, str(edge.get("to_port", ""))):
				push_warning("A port was removed; this connection cannot be restored.")
				return false
	for key in wanted.get("items", {}):
		if wanted.items[key] == expected.items.get(key): continue
		var item := Layout.find(view.host.workspace_layout.tab(tab_id).tree, key)
		if item.is_empty() or item != expected.items.get(key):
			push_warning("Pane changed elsewhere; undo would overwrite it.")
			return false
	for key in wanted.get("items", {}):
		if wanted.items[key] == expected.items.get(key): continue
		var item := Layout.find(view.host.workspace_layout.tab(tab_id).tree, key)
		item.clear()
		item.merge(wanted.items[key].duplicate(true))
	for key in changed_keys:
		if wanted.edges.get(key) == expected.edges.get(key): continue
		if wanted.edges.has(key):
			var restored: Dictionary = wanted.edges[key].duplicate()
			# A saved snapshot is complete, while an omitted connect parameter
			# preserves the current deadline during an ordinary connection edit.
			restored["stop_at"] = restored.get("stop_at", 0.0)
			overlay.graph.connect_nodes(restored)
		elif current.has(key): overlay.graph.disconnect_edge(current[key])
	var data := visual()
	if wanted.layout != expected.layout:
		view.host.workspace_layout.tab(tab_id).tree = wanted.layout.duplicate(true)
	data.clear()
	data.merge(wanted.visual.duplicate(true))
	refresh()
	_publish_visual(expected.visual)
	return true

func undo() -> void:
	if not undo_stack.is_empty() and restore_edit(undo_stack[-1], true): redo_stack.append(undo_stack.pop_back())

func redo() -> void:
	if not redo_stack.is_empty() and restore_edit(redo_stack[-1], false): undo_stack.append(redo_stack.pop_back())

func refresh() -> void:
	if view != null: view.refresh()
	else: overlay.redraw()

func render_position(id: String) -> Vector2:
	var point: Vector2 = visual().reroutes[id].position
	if remote_tab == tab_id and before.is_empty():
		point += Vector2(remote_offsets.get(id, Vector2.ZERO)) * remote_weight
	return point

func to_canvas(point: Vector2) -> Vector2:
	return view.canvas_point_at(point) if view != null else point

func to_screen(point: Vector2) -> Vector2:
	if overlay.sheet_geometry: return point
	if overlay._layout_project.is_valid(): return overlay._layout_project.call(point)
	return view.view_point(point) if view != null else point

var route_cache := {}
var route_peers := {}
var return_lanes := {}
var route_builds := 0

# Build destination lane dependencies once, not once per edge. Moving a pane
# invalidates its incident routes and peers sharing its return-wire lanes.
func prepare_routes(edges: Array) -> void:
	route_peers.clear()
	var live := {}
	for edge in edges:
		var key := Ports.edge_key(edge)
		live[key] = true
		var target := Ports.endpoint(edge, false)
		if not route_peers.has(target): route_peers[target] = []
		var source := Ports.endpoint(edge, true)
		if overlay.has_socket(source, true):
			route_peers[target].append([key, _routing_output(source), visual().routes.get(key, [])])
	return_lanes.clear()
	for target in route_peers:
		var outputs := PackedVector2Array()
		var keys := PackedStringArray()
		for peer in route_peers[target]:
			if peer[2].is_empty():
				keys.append(peer[0])
				outputs.append(peer[1])
		var lanes := Geometry.return_lanes(outputs, keys, overlay.routing_sockets.get("in:" + target, Vector2.INF))
		for i in keys.size(): return_lanes[keys[i]] = lanes[i]
	for key in route_cache.keys():
		if not live.has(key): route_cache.erase(key)

func route_points(key: String, a: Vector2, b: Vector2, interaction := false, route_key := "") -> Dictionary:
	if not overlay.sheet_geometry: return _route_points(key, a, b, interaction, route_key)
	var compact: bool = overlay.compact_nodes.has(Ports.node_id(key.get_slice(">", 0)))
	var authored: bool = not compact and not visual().routes.get(key if route_key.is_empty() else route_key, []).is_empty()
	var resting_a: Vector2 = overlay.routing_sockets.get("out:" + key.get_slice(">", 0), a)
	var resting_b: Vector2 = overlay.routing_sockets.get("in:" + key.get_slice(">", 1), b)
	var route_a := a if authored else resting_a
	var route_b := b if authored else resting_b
	var signature: Array = [route_a, route_b, resting_a, resting_b, overlay.routing_bounds.get(Ports.node_id(key.get_slice(">", 0))), overlay.routing_bounds.get(Ports.node_id(key.get_slice(">", 1))), route_peers.get(key.get_slice(">", 1), []), visual() if authored else {}, remote_weight, compact]
	var cached: Dictionary = route_cache.get(key, {})
	if cached.get("signature", []) != signature:
		route_builds += 1
		cached = {"signature": signature.duplicate(true), "route": _route_points(key, route_a, route_b, interaction, route_key)}
		route_cache[key] = cached
	return cached.route if authored else Geometry.deform_endpoints(cached.route, a - resting_a, b - resting_b)

func _route_points(key: String, a: Vector2, b: Vector2, interaction := false, route_key := "") -> Dictionary:
	var route: Array = visual().routes.get(key if route_key.is_empty() else route_key, [])
	# Compact bundles are a presentation of node-to-node connectivity. Keep
	# authored per-edge reroutes intact, but reveal them only in expanded view.
	if overlay.compact_nodes.has(Ports.node_id(key.get_slice(">", 0))): route = []
	if route.is_empty():
		var resting_a: Vector2 = overlay.routing_sockets.get("out:" + key.get_slice(">", 0), a) if overlay.sheet_geometry else a
		var resting_b: Vector2 = overlay.routing_sockets.get("in:" + key.get_slice(">", 1), b) if overlay.sheet_geometry else b
		return Geometry.deform_endpoints(_automatic_route(key, resting_a, resting_b), a - resting_a, b - resting_b)
	var anchors: Array[Vector2] = [a]
	var ids: Array = [key.get_slice(">", 0)]
	for id in route:
		anchors.append(to_screen(render_position(id)))
		ids.append(id)
	anchors.append(b)
	ids.append(key.get_slice(">", 1))
	var points := PackedVector2Array()
	var first := PackedVector2Array()
	var last := PackedVector2Array()
	for i in range(1, anchors.size()):
		last = reroute_controls(str(ids[i - 1]), str(ids[i]), anchors[i - 1], anchors[i])
		if first.is_empty(): first = last
		var segment := Geometry.sample_controls(last)
		points.append_array(segment if points.is_empty() else segment.slice(1))
	return {"points": points, "first": first, "last": last}

func _automatic_route(key: String, a: Vector2, b: Vector2) -> Dictionary:
	if a.x - 20.0 > b.x:
		var bottom := maxf(a.y, b.y)
		for node in key.split(">"):
			var bounds: Dictionary = overlay.routing_bounds if overlay.sheet_geometry else overlay.pane_screen_bounds
			if bounds.has(Ports.node_id(node)):
				bottom = maxf(bottom, bounds[Ports.node_id(node)].end.y)
		if overlay.sheet_geometry:
			var lane := maxi(0, int(return_lanes.get(key, 0)))
			return Geometry.feedback_curve(a, b, bottom + 40.0 + lane * 18.0, 40.0 + lane * 18.0, true)
		# Keep automatic return wires in stable, separate lanes. Explicit
		# reroutes retain their user-selected shared paths.
		var peers: Array[String] = []
		for edge in overlay.graph.edges.values():
			if Ports.endpoint(edge, false) == key.get_slice(">", 1) and overlay.has_socket(Ports.endpoint(edge, true), true):
				if _routing_output(Ports.endpoint(edge, true)).x - 20.0 > b.x and visual().routes.get(Ports.edge_key(edge), []).is_empty(): peers.append(Ports.edge_key(edge))
		peers.sort_custom(func(left, right):
			var lp: Vector2 = _routing_output(str(left).get_slice(">", 0))
			var rp: Vector2 = _routing_output(str(right).get_slice(">", 0))
			if not is_equal_approx(lp.y, rp.y): return lp.y > rp.y
			if not is_equal_approx(lp.x, rp.x): return lp.x < rp.x
			return left < right
		)
		var lane := maxi(0, peers.find(key))
		return Geometry.feedback_curve(a, b, bottom + 40.0 + lane * 18.0, 40.0 + lane * 18.0, true)
	var plain := Geometry.arrival_controls(a, b)
	return {"points": Geometry.sample_controls(plain), "first": plain, "last": plain}

func _routing_output(id: String) -> Vector2:
	return overlay.routing_sockets.get("out:" + id, overlay.port_center(id, true)) if overlay.sheet_geometry else overlay.port_center(id, true)

func socket_position(id: String, output: bool) -> Vector2:
	return to_screen(render_position(id)) if visual().reroutes.has(id) else overlay.port_center(id, output)

func reroute_direction(id: String) -> Vector2:
	var incoming := Vector2.ZERO
	var outgoing := Vector2.ZERO
	var at := socket_position(id, true)
	# Unique shared stems count once, so fan-out does not duplicate the input.
	for segment in Topology.segments(visual(), overlay.graph.edges):
		if segment.to == id: incoming += (at - socket_position(segment.from, true)).normalized()
		if segment.from == id: outgoing += (socket_position(segment.to, false) - at).normalized()
	var direction := incoming.normalized() + outgoing.normalized()
	if direction.length_squared() < 0.000001:
		direction = outgoing if outgoing != Vector2.ZERO else incoming
	return direction.normalized() if direction != Vector2.ZERO else Vector2.RIGHT

func reroute_controls(source: String, target: String, a: Vector2, b: Vector2) -> PackedVector2Array:
	return Geometry.directed_controls(a, b,
		reroute_direction(source) if visual().reroutes.has(source) else Vector2.RIGHT,
		reroute_direction(target) if visual().reroutes.has(target) else Geometry.arrival_direction(a, b))

func hit_wire(point: Vector2, reach := 9.0) -> Dictionary:
	var nearest := reach
	var result := {}
	for link in overlay.links:
		for i in range(1, link.points.size()):
			var hit := Geometry2D.get_closest_point_to_segment(point, link.points[i - 1], link.points[i])
			var distance := point.distance_to(hit)
			if distance < nearest:
				nearest = distance
				result = link
	return result

func add_reroute(link: Dictionary, point: Vector2) -> void:
	var closest := {}
	var best := INF
	for segment in visual_segments():
		if overlay.link_key(link) not in segment.edges: continue
		var points: PackedVector2Array = segment.points
		for i in range(1, points.size()):
			var distance := point.distance_to(Geometry2D.get_closest_point_to_segment(point, points[i - 1], points[i]))
			if distance < best:
				best = distance
				closest = segment
	if closest.is_empty(): return
	begin_edit()
	insert_reroutes([{ "segment": closest, "position": to_canvas(point) }])
	finish_edit()

func insert_reroutes(cuts: Array) -> void:
	selected.clear()
	var directed_cuts: Array = []
	for hit in cuts:
		var forward: Dictionary = hit.duplicate(true)
		forward.segment.edges = []
		for key in hit.segment.edges:
			var edge: Dictionary = overlay.graph.edges[key]
			if not visual().reroutes.has(hit.segment.from) and Ports.endpoint(edge, true) != hit.segment.from:
				directed_cuts.append({"segment": {"from": Ports.endpoint(edge, true), "to": Ports.endpoint(edge, false), "edges": [key]}, "position": hit.position})
			else: forward.segment.edges.append(key)
		if not forward.segment.edges.is_empty(): directed_cuts.append(forward)
	for id in Topology.insert_cuts(visual(), directed_cuts):
		selected[id] = true

var _segments_snapshot: Array = []
var _segments_cache: Array = []

func visual_segments(visible_preview := false, interaction := true) -> Array:
	if not overlay.sheet_geometry:
		overlay.sheet_geometry = true
		var sheet := visual_segments(visible_preview, interaction)
		overlay.sheet_geometry = false
		var screen: Array = []
		for original in sheet:
			var segment: Dictionary = original.duplicate()
			var projected := PackedVector2Array()
			for point in original.points: projected.append(to_screen(point))
			segment.points = projected
			segment.dim = segment_dim(projected[0], projected[-1])
			screen.append(segment)
		return screen
	var result: Array = []
	var edges: Dictionary = overlay.graph.edges.duplicate()
	if visible_preview:
		for key in edges.keys():
			if preview_detached(key): edges.erase(key)
	var positions := {}
	for output in [false, true]:
		for key in overlay.sockets(output): positions[("out:" if output else "in:") + key] = overlay.port_center(key, output)
	for id in visual().reroutes: positions[id] = to_screen(render_position(id))
	var snapshot: Array = [edges, visual(), positions, overlay.routing_bounds, interaction]
	if snapshot == _segments_snapshot: return _segments_cache
	_segments_snapshot = snapshot.duplicate(true)
	for segment in Topology.segments(visual(), edges):
		if not (overlay.has_socket(segment.from, true) or visual().reroutes.has(segment.from)): continue
		if not (overlay.has_socket(segment.to, false) or visual().reroutes.has(segment.to)): continue
		var a: Vector2 = to_screen(render_position(segment.from)) if visual().reroutes.has(segment.from) else overlay.port_center(segment.from, true)
		var b: Vector2 = to_screen(render_position(segment.to)) if visual().reroutes.has(segment.to) else overlay.port_center(segment.to, false)
		segment.dim = 1.0 # Screen-dependent fading is a canvas modulate, not geometry.
		if not visual().reroutes.has(segment.from) and not visual().reroutes.has(segment.to):
			segment.points = route_points(segment.from + ">" + segment.to, a, b, interaction).points
		else:
			segment.points = Geometry.sample_controls(reroute_controls(segment.from, segment.to, a, b))
		result.append(segment)
	_segments_cache = result
	return result

func bounds_for(keys: Array) -> Rect2:
	var bounds := Rect2()
	if view == null: return bounds
	for key in keys:
		var rect := Rect2()
		if view.pane_rects.has(key): rect = view.pane_rects[key]
		elif visual().reroutes.has(key): rect = Rect2(visual().reroutes[key].position - Vector2(5, 5), Vector2(10, 10))
		if rect.has_area(): bounds = rect if not bounds.has_area() else bounds.merge(rect)
	return bounds

func frame_keys(keys: Array) -> void:
	if view == null: return
	var bounds := bounds_for(keys)
	if not bounds.has_area(): return
	# space_node_view_flag: expand the limiting axis, then scale bounds by 1.1.
	var aspect := view.size.x / maxf(view.size.y, 1.0)
	if aspect < bounds.size.x / bounds.size.y:
		bounds = bounds.grow_individual(0, bounds.size.x / aspect / 4.0, 0, bounds.size.x / aspect / 4.0)
	else:
		bounds = bounds.grow_individual(bounds.size.y * aspect / 4.0, 0, bounds.size.y * aspect / 4.0, 0)
	bounds = Rect2(bounds.get_center() - bounds.size * 0.55, bounds.size * 1.1)
	view._cancel_main_magnet()
	view.overview = true
	var center := bounds.get_center()
	var zoom := clampf(minf(view.size.x / bounds.size.x, view.size.y / bounds.size.y), 0.05, 6.0)
	if camera_tween != null: camera_tween.kill()
	var start_center: Vector2 = view.navigation_center
	var start_zoom: float = view.navigation_zoom
	if not animate_camera:
		apply_camera(center, zoom)
		return
	camera_tween = create_tween()
	camera_tween.tween_method(func(t: float):
		var smooth := t * t * (3.0 - 2.0 * t)
		apply_camera(start_center.lerp(center, smooth), 1.0 / lerpf(1.0 / start_zoom, 1.0 / zoom, smooth))
	, 0.0, 1.0, maxf(0.001, 0.25 * camera_factor(start_center, start_zoom, center, zoom)))

func apply_camera(center: Vector2, zoom: float) -> void:
	view.navigation_center = center
	view.navigation_zoom = zoom
	view._apply_navigation()
	view.refresh()

func fit_selected() -> void: frame_keys(selection())

func fit_connected() -> void:
	var keys := selection().duplicate()
	var i := 0
	while i < keys.size():
		for edge in overlay.graph.edges.values():
			if edge.from == keys[i] and overlay.ports.has(edge.to) and edge.to not in keys: keys.append(edge.to)
			if edge.to == keys[i] and overlay.ports.has(edge.from) and edge.from not in keys: keys.append(edge.from)
		i += 1
	frame_keys(keys)

func draw_selection(painter: Node2D) -> void:
	if not overlay.editing: return
	if view != null:
		for key in selection():
			if view.pane_rects.has(key):
				var rect: Rect2 = view.pane_rects[key]
				var pane_scale := 1.0
				if view.panes.has(key):
					var pane: Control = view.panes[key]
					rect = pane.get_transform() * Rect2(Vector2.ZERO, pane.size)
					pane_scale = pane.scale.x
				var radius := 12.0
				if is_instance_valid(view.host.get("world")):
					radius = float(view.host.world.terminal_window.corner_radius)
				# Draw on the sheet with the pane, so perspective and curvature
				# transform its whole outline instead of only two opposite corners.
				selection_glow.set_corner_radius_all(roundi(radius * pane_scale))
				selection_glow.shadow_size = maxi(1, roundi(painter.local_width(to_screen(rect.get_center()), 9.0) * pane_scale))
				painter.sheet_style_box(selection_glow, rect)

func draw_overlay() -> void:
	if not overlay.editing: return
	for id in visual().reroutes:
		var at := to_screen(render_position(id))
		overlay.draw_circle(at, 5, Color("14212a"))
		overlay.draw_arc(at, 5, 0, TAU, 16, Color("ffd47a") if selected.has(id) else Color("89ddbd"), 1.5, true)
	if cut.size() > 1: overlay.draw_polyline(cut, Color("ff8585"), 2, true)
	if gesture.get("kind") in ["reconnect", "new_input"]:
		var edges: Array = gesture.get("edges", [gesture.get("edge", {})])
		if gesture.kind == "new_input": edges = [{"from": "", "to": Ports.node_id(gesture.node), "to_port": Ports.port_id(gesture.node)}]
		for edge in edges:
			var target: Vector2 = gesture.at
			var snapped := ""
			for key in overlay.sockets(gesture.end == "from"):
				if target.distance_to(overlay.port_center(key, gesture.end == "from")) < 24:
					target = overlay.port_center(key, gesture.end == "from")
					snapped = key
					break
			var a: Vector2 = target if gesture.end == "from" else overlay.port_center(Ports.endpoint(edge, true), true)
			var b: Vector2 = target if gesture.end == "to" else overlay.port_center(Ports.endpoint(edge, false), false)
			var source: String = snapped if gesture.end == "from" else Ports.endpoint(edge, true)
			var destination: String = snapped if gesture.end == "to" else Ports.endpoint(edge, false)
			var route_key: String = Ports.edge_key(edge)
			var preview := route_points(source + ">" + destination, a, b, false, route_key)
			overlay.draw_preview_wire(preview.points, source, edge)
			overlay.draw_arc(target, 9, 0, TAU, 24, Color("ffd47a"), 1.5, true)

func cut_links() -> void:
	# Freeze the intersection set before mutating topology (Blender operators).
	var cuts: Array = []
	for segment in visual_segments():
		if segment.dim < 0.5: continue
		var intersection: Variant = null
		for i in range(1, mini(cut.size(), 256)):
			for j in range(1, segment.points.size()):
				intersection = Geometry2D.segment_intersects_segment(cut[i - 1], cut[i], segment.points[j - 1], segment.points[j])
				if intersection != null: break
			if intersection != null: break
		if intersection != null: cuts.append({"segment": segment, "position": to_canvas(intersection)})
	if not cuts.is_empty():
		begin_edit()
		if path_action == "reroute": insert_reroutes(cuts)
		else:
			var affected := {}
			for hit in cuts:
				for key in hit.segment.edges: affected[key] = not hit.segment.muted
			for key in affected:
				if not overlay.graph.edges.has(key): continue
				var edge: Dictionary = overlay.graph.edges[key].duplicate()
				if path_action == "mute":
					edge.muted = affected[key]
					overlay.graph.connect_nodes(edge)
				else:
					overlay.graph.disconnect_edge(edge)
					visual().routes.erase(key)
		finish_edit()
	cut.clear()

func reconnect(edge: Dictionary, endpoint: String, node: String, transaction := true, batch_keys: Array = [], route_remap: Dictionary = {}) -> bool:
	var replacement := edge.duplicate()
	replacement[endpoint] = Ports.node_id(node)
	replacement[endpoint + "_port"] = Ports.port_id(node)
	if replacement.from == replacement.to or Ports.edge_key(replacement) == Ports.edge_key(edge): return false
	if overlay.graph.edges.has(Ports.edge_key(replacement)):
		push_warning("That connection already exists.")
		return false
	if transaction: begin_edit()
	var result: Dictionary = overlay.graph.connect_nodes(replacement)
	if result.has("error"):
		before = {}
		return false
	overlay.graph.disconnect_edge(edge)
	var old_key: String = Ports.edge_key(edge)
	if visual().routes.has(old_key):
		var route: Array = visual().routes[old_key].duplicate()
		if endpoint == "from":
			for i in route.size():
				var id: String = route[i]
				var shared_outside_batch := false
				for key in visual().routes:
					if key != old_key and key not in batch_keys and id in visual().routes[key]: shared_outside_batch = true
				if shared_outside_batch:
					if not route_remap.has(id):
						var copy := Topology.allocate(visual(), "reroute")
						visual().reroutes[copy] = visual().reroutes[id].duplicate(true)
						route_remap[id] = copy
					route[i] = route_remap[id]
		visual().routes[Ports.edge_key(replacement)] = route
		visual().routes.erase(old_key)
	if transaction: finish_edit()
	return true

func handle_undo_shortcut(event: InputEvent) -> bool:
	if not event is InputEventKey or event.keycode != KEY_Z:
		return false
	if undo_key_held:
		if not event.pressed: undo_key_held = false
		return true
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return false
	# Browser content and canvas editors own keyboard editing even though
	# their focus is inside the workspace's separate viewport.
	if view != null and view.has_text_focus():
		return false
	var command: bool = event.meta_pressed and not event.ctrl_pressed if OS.get_name() == "macOS" else event.ctrl_pressed and not event.meta_pressed
	if not event.pressed or not command or event.alt_pressed:
		return false
	undo_key_held = true
	if not event.echo:
		if event.shift_pressed: redo()
		else: undo()
	return true

func open_reroute_menu(id: String) -> void:
	if not visual().reroutes.has(id): return
	if not selected.has(id): selected = {id: true}
	if not is_instance_valid(reroute_menu):
		reroute_menu = PopupMenu.new()
		reroute_menu.prefer_native_menu = true
		reroute_menu.id_pressed.connect(func(_action): delete_visual_selection.call_deferred())
		add_child(reroute_menu)
	reroute_menu.clear()
	reroute_menu.add_item("Remove reroutes" if selected.keys().filter(func(key): return visual().reroutes.has(key)).size() > 1 else "Remove reroute")
	preload("res://scenes/input/PointerPopup.gd").open(reroute_menu)
	overlay.redraw()

func open_wire_menu(key: String) -> void:
	if not overlay.graph.edges.has(key): return
	wire_menu_key = key
	if not is_instance_valid(wire_menu):
		wire_menu = PopupMenu.new()
		wire_menu.prefer_native_menu = true
		wire_menu.id_pressed.connect(func(action): _wire_action.call_deferred(action))
		add_child(wire_menu)
	wire_menu.clear()
	wire_menu.add_item("Queue Inspector", WireAction.INSPECT)
	var paused: bool = overlay.graph.edges[key].get("muted", false)
	wire_menu.add_item("Resume connection" if paused else "Pause connection", WireAction.PAUSE)
	wire_menu.add_separator()
	var Icons := preload("res://scenes/PaneIcons.gd")
	wire_menu.add_icon_item(Icons.menu_icon(wire_menu, Icons.trash()), "Remove connection", WireAction.REMOVE)
	preload("res://scenes/PopupChrome.gd").mark_danger(wire_menu, wire_menu.get_item_index(WireAction.REMOVE))
	preload("res://scenes/input/PointerPopup.gd").open(wire_menu)

func _wire_action(action: int) -> void:
	var key := wire_menu_key
	if not overlay.graph.edges.has(key): return
	if action == WireAction.INSPECT:
		overlay.open_queue_inspector(key)
		return
	# One undo step, matching the Ctrl+Alt mute and Ctrl cut gestures.
	begin_edit()
	var edge: Dictionary = overlay.graph.edges[key].duplicate()
	if action == WireAction.PAUSE:
		edge.muted = not edge.get("muted", false)
		overlay.graph.connect_nodes(edge)
	elif action == WireAction.REMOVE:
		overlay.graph.disconnect_edge(edge)
		visual().routes.erase(key)
	finish_edit()

func _input(event: InputEvent) -> void:
	if (event is InputEventMouseButton or event is InputEventKey) and event.pressed:
		inspection_click += 1
	if handle_undo_shortcut(event):
		get_viewport().set_input_as_handled()
		return
	if not overlay.editing: return
	# Other keyboard input belongs to the terminal; Escape cancels graph gestures.
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE and (not gesture.is_empty() or not cut.is_empty()):
			if gesture.get("kind") == "waypoint": visual().reroutes[gesture.id].position = gesture.original
			if not before.is_empty():
				var data := visual()
				data.clear()
				data.merge(before.visual.duplicate(true))
			gesture.clear()
			cut.clear()
			before = {}
			refresh()
			get_viewport().set_input_as_handled()
		return
	if not event is InputEventMouse: return
	var at: Vector2 = overlay.get_global_transform_with_canvas().affine_inverse() * event.position
	if event is InputEventMouseMotion:
		if gesture.get("kind") == "inspect_wire":
			if at.distance_to(gesture.at) > 6: gesture.clear()
			return
		if not cut.is_empty():
			if cut.size() < 256: cut.append(at)
		elif gesture.get("kind") == "waypoint":
			visual().reroutes[gesture.id].position = to_canvas(at)
			refresh()
		elif gesture.get("kind") in ["reconnect", "new_input"]: gesture.at = at
		elif gesture.get("kind") == "pick_input": pick_input(at)
		else:
			var hit := hit_wire(at)
			hovered = "" if hit.is_empty() else overlay.link_key(hit)
			overlay.update_edge_hover(at)
			overlay.redraw()
			return
		overlay.redraw()
		get_viewport().set_input_as_handled()
		return
	if not event is InputEventMouseButton: return
	overlay.clear_edge_hover()
	if not event.pressed:
		if not cut.is_empty():
			cut_links()
		elif gesture.get("kind") == "inspect_wire":
			_inspect_wire_after_click(gesture.key)
		elif gesture.get("kind") == "reconnect":
			var node := ""
			for key in overlay.sockets(gesture.end == "from"):
				if at.distance_to(overlay.port_center(key, gesture.end == "from")) < 24: node = key
			var edges: Array = gesture.get("edges", [gesture.edge])
			# Validate the complete batch before committing any endpoint changes.
			var valid := true
			for edge in edges:
				if node.is_empty(): continue
				var source: String = node if gesture.end == "from" else Ports.endpoint(edge, true)
				var target: String = node if gesture.end == "to" else Ports.endpoint(edge, false)
				if Ports.node_id(source) == Ports.node_id(target) or (overlay.graph.edges.has(source + ">" + target) and source + ">" + target != Ports.edge_key(edge)): valid = false
			if valid:
				var batch_keys: Array = edges.map(func(edge): return Ports.edge_key(edge))
				var route_remap := {}
				begin_edit()
				for edge in edges:
					if node.is_empty():
						overlay.graph.disconnect_edge(edge)
						visual().routes.erase(Ports.edge_key(edge))
					else: reconnect(edge, gesture.end, node, false, batch_keys, route_remap)
				finish_edit()
			else: push_warning("Cannot reconnect: a destination already exists or would connect to itself.")
		elif gesture.get("kind") == "new_input":
			for key in overlay.sockets(true):
				if Ports.node_id(key) != Ports.node_id(gesture.node) and at.distance_to(overlay.port_center(key, true)) < 24:
					overlay.connect_sockets(key, gesture.node)
					break
		elif gesture.get("kind") == "waypoint":
			finish_edit()
		elif gesture.is_empty(): return
		gesture.clear()
		get_viewport().set_input_as_handled()
		overlay.redraw()
		return
	# Shift+left over terminal content belongs to text selection, including
	# registered graph nodes in overview. Graph selection remains on headers.
	if gesture.is_empty() and cut.is_empty() and not (event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed):
		if event.button_index == MOUSE_BUTTON_RIGHT:
			for id in visual().reroutes:
				if at.distance_to(to_screen(render_position(id))) < 10:
					open_reroute_menu.call_deferred(id)
					get_viewport().set_input_as_handled()
					return
		var queue_key: String = overlay.queue_hit(at) if event.button_index == MOUSE_BUTTON_LEFT else ""
		# Right-click, or a touch hold (delivered as right-click), offers the
		# wire's actions: the only touch route to pause or remove it.
		if event.button_index == MOUSE_BUTTON_RIGHT and not overlay.pane_screen_bounds.values().any(func(bounds): return bounds.has_point(at)):
			# A fingertip covers far more than a cursor; keep a hold forgiving.
			var wire := hit_wire(at, 24.0 if event.get_meta("direct_touch", false) else 9.0)
			if not wire.is_empty():
				open_wire_menu.call_deferred(overlay.link_key(wire))
				get_viewport().set_input_as_handled()
				return
		if not queue_key.is_empty():
			overlay.open_queue_inspector.call_deferred(queue_key)
			get_viewport().set_input_as_handled()
			return
	if event.button_index == MOUSE_BUTTON_LEFT and event.shift_pressed and view != null and gesture.is_empty():
		var canvas_point := to_canvas(at)
		var pane_key: String = view.window_at(canvas_point)
		var pane: Control = view.panes.get(pane_key)
		if pane != null and view.host.is_terminal_pane(pane_key) and canvas_point.y >= pane.position.y + pane.body.position.y:
			return
	if event.button_index == MOUSE_BUTTON_RIGHT and (event.ctrl_pressed or event.shift_pressed or event.alt_pressed):
		path_action = "mute" if event.ctrl_pressed and event.alt_pressed else ("reroute" if event.shift_pressed else "cut")
		cut = PackedVector2Array([at])
		get_viewport().set_input_as_handled()
		return
	for id in visual().reroutes:
		var point: Vector2 = visual().reroutes[id].position
		if at.distance_to(to_screen(point)) < 10:
			if event.button_index == MOUSE_BUTTON_LEFT:
				if not event.shift_pressed: selected.clear()
				selected[id] = true
				begin_edit()
				gesture = {"kind": "waypoint", "id": id, "original": point}
				get_viewport().set_input_as_handled()
				return
	if event.button_index != MOUSE_BUTTON_LEFT: return
	if gesture.get("kind") == "reconnect":
		# Keep the active reconnect gesture until its release.
		gesture.at = at
		get_viewport().set_input_as_handled()
		return

	# Enlarged touch targets can overlap. The nearest visible socket wins,
	# rather than whichever pane's button was inserted last.
	var socket: Dictionary = overlay.nearest_socket(at)
	if socket.get("output", false) and not (event.ctrl_pressed or event.alt_pressed):
		overlay.start_connection(socket.key, bool(event.get_meta("direct_touch", false)))
		get_viewport().set_input_as_handled()
		return

	for key in overlay.sockets(true):
		if at.distance_to(overlay.port_center(key, true)) < 12 and (event.ctrl_pressed or event.alt_pressed):
			var edges: Array = []
			for edge in overlay.graph.edges.values():
				if Ports.endpoint(edge, true) == key: edges.append(edge.duplicate())
			if not edges.is_empty():
				gesture = {"kind": "reconnect", "edge": edges[0], "edges": edges, "end": "from", "at": at}
				get_viewport().set_input_as_handled()
				return
	for key in overlay.sockets(false):
		if socket.get("key", "") == key and not socket.get("output", true):
			var edges: Array = []
			for edge in overlay.graph.edges.values():
				if Ports.endpoint(edge, false) == key: edges.append(edge.duplicate())
			if edges.size() == 1:
				gesture = {"kind": "reconnect", "edge": edges[0], "end": "to", "at": at}
			elif edges.size() > 1:
				gesture = {"kind": "pick_input", "node": key, "candidates": edges, "picked": {}, "at": at}
				pick_input(at)
			else: gesture = {"kind": "new_input", "node": key, "end": "from", "at": at}
			get_viewport().set_input_as_handled()
			return
	if event.shift_pressed and view != null:
		for key in overlay.ports:
			if view.pane_rects[key].has_point(to_canvas(at)):
				if selected.has(key): selected.erase(key)
				else: selected[key] = true
				get_viewport().set_input_as_handled()
				overlay.redraw()
				return
	if not event.shift_pressed and view != null:
		for key in overlay.ports:
			if view.pane_rects[key].has_point(to_canvas(at)):
				selected.clear()
				overlay.redraw()
				break
	if gesture.is_empty() and not (event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed) and not overlay.pane_screen_bounds.values().any(func(bounds): return bounds.has_point(at)):
		var link := hit_wire(at)
		if not link.is_empty():
			if event.double_click:
				add_reroute(link, at)
			else:
				gesture = {"kind": "inspect_wire", "key": overlay.link_key(link), "at": at}
			get_viewport().set_input_as_handled()

func _inspect_wire_after_click(key: String) -> void:
	# A second click must add a reroute before a dialog can take mouse focus.
	var serial := inspection_click
	var clicked_tab := tab_id
	await get_tree().create_timer(0.5).timeout
	if serial != inspection_click or tab_id != clicked_tab: return
	if not overlay.editing or not overlay.is_visible_in_tree() or not overlay.graph.edges.has(key): return
	overlay.open_queue_inspector(key)

func pane_items() -> Dictionary:
	var items := {}
	if view != null:
		var tab: Dictionary = view.host.workspace_layout.tab(view.host.workspace_layout.active)
		for key in view.pane_rects: items[key] = Layout.find(tab.tree, key).duplicate(true)
	return items

func delete_visual_selection() -> void:
	begin_edit()
	for key in selection():
		if visual().reroutes.has(key): Topology.remove_reroute(visual(), key)
	selected.clear()
	finish_edit()

func pick_input(at: Vector2) -> void:
	# pick_input_link_by_link_intersect: keep the last candidate across gaps;
	# detach only when the pointer leaves the input socket's hit area.
	for edge in gesture.candidates:
		var points: PackedVector2Array = route_points(Ports.edge_key(edge), overlay.port_center(Ports.endpoint(edge, true), true), overlay.port_center(Ports.endpoint(edge, false), false), true).points
		for i in range(1, points.size()):
			if at.distance_squared_to(Geometry2D.get_closest_point_to_segment(at, points[i - 1], points[i])) < 12.5:
				gesture.picked = edge
	if not gesture.picked.is_empty():
		hovered = Ports.edge_key(gesture.picked)
		if at.distance_to(overlay.port_center(gesture.node, false)) >= 12:
			gesture = {"kind": "reconnect", "edge": gesture.picked, "end": "to", "at": at}

func preview_detached(key: String) -> bool:
	if gesture.get("kind") != "reconnect": return false
	for edge in gesture.get("edges", [gesture.edge]):
		if key == Ports.edge_key(edge): return true
	return false

func camera_factor(a: Vector2, az: float, b: Vector2, bz: float) -> float:
	# view2d_ops.cc smooth_view_rect_to_fac.
	var small: Vector2 = view.size / maxf(az, bz)
	var factor := 2.0 * (1.0 - minf(az, bz) / maxf(az, bz))
	for axis in 2: factor = maxf(factor, absf(a[axis] - b[axis]) / maxf(small[axis], 0.001))
	return minf(factor, 1.0)

func segment_dim(a: Vector2, b: Vector2) -> float:
	# node_link_dim_factor: fade links whose endpoints are both offscreen.
	var viewport := Rect2(Vector2.ZERO, overlay.size)
	var nearest := INF
	for point in [a, b]:
		var dx := maxf(maxf(-point.x, point.x - viewport.end.x), 0)
		var dy := maxf(maxf(-point.y, point.y - viewport.end.y), 0)
		nearest = minf(nearest, maxf(dx, dy))
	return clampf(1.0 - nearest / maxf(viewport.size.x, 1.0) * 10.0, 0.05, 1.0)
