extends Control
## Screen-space ports and wires on the actual terminal panes; no separate graph window.
var graph: Node:
	set(value):
		if graph == value: return
		if is_instance_valid(graph) and graph.message_transferred.is_connected(_message_transferred):
			graph.message_transferred.disconnect(_message_transferred)
			graph.message_rejected.disconnect(_message_rejected)
			graph.changed.disconnect(_graph_changed)
		graph = value
		pulses.clear()
		queued_routes.clear()
		if is_instance_valid(graph):
			graph.message_transferred.connect(_message_transferred)
			graph.message_rejected.connect(_message_rejected)
			graph.changed.connect(_graph_changed)
		_graph_changed()
		redraw()
var pulses: Array[Dictionary] = []
var waiting: Dictionary = {}
var queued_routes: Dictionary = {}
var blink_time := 0.0
const Geometry := preload("res://scenes/GraphLinkGeometry.gd")
const MESSAGE_SPEED := 220.0 # Maximum screen pixels per second.
const MIN_FLOW_DURATION := 1.2 # Short links must remain visible too.
var links: Array:
	get:
		var projected: Array = []
		for link in sheet_links: projected.append(_screen_link(link))
		return projected
var _screen_cache := {}
var sheet_links: Array = []
# Retained routing/paint live on the sheet; screen copies serve input/markers.
var sheet_geometry := false
var sheet_sockets := {}
# Presentation only: real sockets/edges remain available for delivery and editing.
var compact_nodes := {}
var compact_bundles := {}
var socket_index := [{}, {}]
var marker_layer := preload("res://scenes/GraphWireLayer.gd").new()
var ports: Dictionary = {}
var wire_layer := preload("res://scenes/GraphWireLayer.gd").new()
var tools := preload("res://scenes/GraphWorkspaceTools.gd").new()
var editing := false
var dragging := ""
var touch_drag := false
var cursor := Vector2.ZERO
var pane_screen_bounds: Dictionary = {}
var routing_bounds: Dictionary = {}
var routing_sockets: Dictionary = {}
var edge_hint := PanelContainer.new()
var edge_hint_text := Label.new()
var hover_timer := Timer.new()
var hover_edge := ""
var hover_position := Vector2.ZERO
var queue_inspector: AcceptDialog
const Graph := preload("res://scenes/AgentGraph.gd")
const Ports := preload("res://scenes/GraphPorts.gd")


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 4
	clip_contents = true
	set_process(false)
	wire_layer.overlay = self
	wire_layer.sheet_coordinates = true
	add_child(wire_layer)
	marker_layer.overlay = self
	marker_layer.markers_only = true
	add_child(marker_layer)
	edge_hint.z_index = 16
	edge_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edge_hint.add_theme_stylebox_override("panel", _box())
	edge_hint_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edge_hint_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	edge_hint_text.custom_minimum_size.x = 360
	edge_hint.add_child(edge_hint_text)
	add_child(edge_hint)
	edge_hint.hide()
	hover_timer.one_shot = true
	hover_timer.wait_time = 0.5
	hover_timer.timeout.connect(_show_edge_hint)
	add_child(hover_timer)
	visibility_changed.connect(func():
		if not is_visible_in_tree():
			clear_edge_hover()
			if is_instance_valid(queue_inspector): queue_inspector.hide()
		_refresh_waiting()
	)
	get_window().mouse_exited.connect(clear_edge_hover)
	add_child(tools)


var _sync_snapshot: Array = []
var geometry_rebuilds := 0
var _layout_rectangles: Dictionary = {}
var _routing_rectangles: Dictionary = {}
var _layout_project: Callable
var _layout_editable := false

func _exit_tree() -> void:
	# Hosts revoke graph nodes after child views have left the tree. Their
	# camera projection is no longer usable during those teardown signals.
	_layout_project = Callable()
	graph = null

func _graph_changed() -> void:
	# Provider detection also creates/removes sockets. Refresh them on the same
	# signal as the status strip, without waiting for another workspace layout pass.
	if is_instance_valid(graph) and _layout_project.is_valid():
		sync(_layout_rectangles, graph.edges.values(), _layout_project, _layout_editable, _routing_rectangles)
		_refresh_waiting()
	else:
		_refresh_waiting()

func sync(rectangles: Dictionary, edges: Array, project: Callable, editable := false, routing_rectangles: Dictionary = {}) -> void:
	_layout_rectangles = rectangles.duplicate()
	_routing_rectangles = routing_rectangles.duplicate()
	_layout_project = project
	_layout_editable = editable
	editing = editable and graph != null
	tools.sync()
	# GUI hit testing follows sibling order, not z_index. Resource strips are added
	# dynamically; keep the ports above them for input as well as drawing.
	if editing and get_index() != get_parent().get_child_count() - 1:
		get_parent().move_child(self, -1)
	compact_nodes.clear()
	pane_screen_bounds.clear()
	routing_bounds.clear()
	routing_sockets.clear()
	sheet_sockets.clear()
	var touch := preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	var hit_size := 44.0 if touch else 24.0
	var minimum_pitch := 44.0 if touch else 28.0
	var visible_keys: Array = []
	for key in rectangles:
		if graph == null or not graph.nodes.has(key):
			continue
		visible_keys.append(key)
		if not ports.has(key):
			ports[key] = {}
		var rect: Rect2 = rectangles[key]
		var bounds := Rect2(project.call(rect.position), Vector2.ZERO)
		for corner in [rect.end, Vector2(rect.end.x, rect.position.y), Vector2(rect.position.x, rect.end.y)]:
			bounds = bounds.expand(project.call(corner))
		pane_screen_bounds[key] = bounds
		var resting: Rect2 = routing_rectangles.get(key, rect)
		routing_bounds[key] = resting
		var expected := {}
		var banks := []
		var row_pitches := []
		# Measure each projected pane edge and the actual themed hit targets.
		# Canvas zoom must not squeeze independently clickable/touchable rows.
		for output in [false, true]:
			var declared := Ports.ports(graph.nodes[key], output)
			banks.append(declared)
			var pitch := minimum_pitch
			for descriptor in declared:
				var slot := ("out" if output else "in") + ("/" + str(descriptor.id) if descriptor.id != "" else "")
				expected[slot] = true
				if not ports[key].has(slot): ports[key][slot] = _port(Ports.socket_id(key, str(descriptor.id)), output)
				pitch = maxf(pitch, ports[key][slot].get_combined_minimum_size().ceil().y)
			var edge_x := rect.end.x + 6 if output else rect.position.x - 6
			var top: Vector2 = project.call(Vector2(edge_x, rect.position.y))
			var bottom: Vector2 = project.call(Vector2(edge_x, rect.end.y))
			var row_pitch := Geometry.port_row_pitch(rect.size.y, absf(bottom.y - top.y), declared.size(), pitch)
			row_pitches.append(row_pitch)
			if row_pitch < 0: compact_nodes[key] = true
		for output in [false, true]:
			var declared: Array = banks[1 if output else 0]
			for i in declared.size():
				var descriptor: Dictionary = declared[i]
				var slot := ("out" if output else "in") + ("/" + str(descriptor.id) if descriptor.id != "" else "")
				var button: Button = ports[key][slot]
				var color := Color(descriptor.color)
				if button.get_meta("port_color", Color.TRANSPARENT) != color:
					button.set_meta("port_color", color)
					button.queue_redraw()
				button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED if graph.nodes.get(key, {}).has("manifest") else Node.AUTO_TRANSLATE_MODE_INHERIT
				button.tooltip_text = descriptor.get("name", "")
				var bundle_colors: Array = []
				if compact_nodes.has(key) and i == 0:
					var names := PackedStringArray()
					for port in declared:
						bundle_colors.append(Color(port.color))
						names.append(str(port.get("name", "")) if graph.nodes[key].has("manifest") else tr(str(port.get("name", ""))))
					button.tooltip_text = " · ".join(names)
				var stack_pitch := minf(6.0, maxf(0.0, (bounds.size.y - 8.0) / maxf(1.0, bundle_colors.size() - 1)))
				# Respect theme minimums and pixel snapping. Requesting a fractional
				# or undersized height can requeue resized -> sync indefinitely.
				button.size = Vector2(hit_size, maxf(hit_size, 8.0 + stack_pitch * maxf(0.0, bundle_colors.size() - 1))).max(button.get_combined_minimum_size()).ceil()
				if button.get_meta("bundle_colors", []) != bundle_colors or button.get_meta("stack_pitch", -1.0) != stack_pitch:
					button.set_meta("bundle_colors", bundle_colors)
					button.set_meta("stack_pitch", stack_pitch)
					button.queue_redraw()
				var anchor := Vector2(rect.end.x if output else rect.position.x, rect.get_center().y)
				var row_pitch: float = row_pitches[1 if output else 0]
				var offset := Vector2(6 if output else -6, (i - (declared.size() - 1) * 0.5) * row_pitch) - button.size * .5
				var socket_offset := offset + button.size * .5
				if compact_nodes.has(key): socket_offset.y = 0
				button.set_meta("sheet_anchor", anchor + socket_offset)
				button.set_meta("anchor_offset", -button.size * .5)
				var socket_key := ("out:" if output else "in:") + Ports.socket_id(key, str(descriptor.id))
				sheet_sockets[socket_key] = anchor + socket_offset
				button.position = project.call(anchor + socket_offset) - button.size * .5
				var resting_anchor := Vector2(resting.end.x if output else resting.position.x, resting.get_center().y)
				# Keep the router's canonical endpoints independent of camera zoom.
				# Cached paths deform to the displayed sockets without rerouting.
				var routing_offset := Vector2(socket_offset.x, (i - (declared.size() - 1) * .5) * minf(maxf(28, button.size.y), resting.size.y / declared.size()))
				if compact_nodes.has(key): routing_offset.y = 0
				routing_sockets[socket_key] = resting_anchor + routing_offset
				button.visible = editing and (not compact_nodes.has(key) or i == 0)
		for slot in ports[key].keys():
			if not expected.has(slot):
				ports[key][slot].queue_free()
				ports[key].erase(slot)
	for key in ports.keys():
		if key not in visible_keys:
			for button in ports[key].values(): button.queue_free()
			ports.erase(key)
	socket_index = [{}, {}]
	for node in ports:
		for slot in ports[node]:
			socket_index[1 if slot == "out" or slot.begins_with("out/") else 0][Ports.socket_id(node, Ports.port_id(slot))] = ports[node][slot]
	if not editing or not has_socket(dragging, true):
		dragging = ""
	if not editing: clear_edge_hover()
	# Selection, hover and delivery state affect paint, not wire geometry. Their
	# input/graph signals already request redraws and refresh queue markers.
	var colors := {}
	for output in [false, true]:
		for key in sockets(output): colors[("out:" if output else "in:") + key] = socket_color(key, output)
	var snapshot: Array = [sheet_sockets, colors, routing_bounds, routing_sockets, edges, tools.visual(), tools.remote_weight, editing, compact_nodes]
	if snapshot == _sync_snapshot:
		_project_links(project)
		marker_layer.queue_redraw()
		return
	_sync_snapshot = snapshot.duplicate(true)
	geometry_rebuilds += 1
	sheet_links.clear()
	compact_bundles.clear()
	var bundle_routes := {}
	sheet_geometry = true
	tools.prepare_routes(edges)
	for edge in edges:
		if not has_socket(Ports.endpoint(edge, true), true) or not has_socket(Ports.endpoint(edge, false), false): continue
		var a := port_center(Ports.endpoint(edge, true), true)
		var b := port_center(Ports.endpoint(edge, false), false)
		var key := Ports.edge_key(edge)
		var bundle := str(edge.from) + ">" + str(edge.to) if compact_nodes.has(edge.from) else ""
		if not bundle.is_empty():
			var target_rect: Rect2 = rectangles[edge.to]
			b = Vector2(target_rect.position.x - 6, target_rect.get_center().y)
			if not compact_bundles.has(bundle): compact_bundles[bundle] = []
			compact_bundles[bundle].append(key)
		var routed: Dictionary
		if not bundle.is_empty() and bundle_routes.has(bundle):
			routed = bundle_routes[bundle]
		else:
			routed = tools.route_points(key, a, b)
			if not bundle.is_empty(): bundle_routes[bundle] = routed
		var points: PackedVector2Array = routed.points
		sheet_links.append({"points": points, "muted": edge.get("muted", false), "first_controls": routed.first, "controls": routed.last, "lengths": Geometry.distances(points), "a": a, "b": b, "both": false, "source": edge.from, "target": edge.to, "key": key, "from_socket": Ports.endpoint(edge, true), "to_socket": Ports.endpoint(edge, false)})
	sheet_geometry = false
	_project_links(project)
	_refresh_waiting()
	redraw()


var _projection_snapshot: Array = []
var _wire_screen_scale := 1.0
func _project_links(project: Callable) -> void:
	var snapshot: Array = [geometry_rebuilds, project.call(Vector2.ZERO), project.call(Vector2(100, 0)), project.call(Vector2(0, 100)), project.call(Vector2(100, 100))]
	if snapshot == _projection_snapshot: return
	_projection_snapshot = snapshot
	_screen_cache.clear()
	# Repaint only stroke widths when zoom changes. Routes stay cached, and
	# translation alone keeps the retained draw commands and ribbon textures.
	var scale_x: float = snapshot[1].distance_to(snapshot[2]) / 100.0
	var scale_y: float = snapshot[1].distance_to(snapshot[3]) / 100.0
	var scale := maxf(0.0001, snappedf(minf(scale_x, scale_y), 0.0001))
	var old_width_scale := maxf(1.0, 1.0 / _wire_screen_scale)
	_wire_screen_scale = scale
	if not is_equal_approx(old_width_scale, maxf(1.0, 1.0 / scale)):
		wire_layer.queue_redraw()
	wire_layer.project_stems(project, tools.segment_dim)
	queue_redraw() # Screen-space reroute handles and preview.


# Project only a picked/animated route. Camera motion itself does not walk all
# sampled points; the renderer transforms the retained sheet geometry instead.
func _screen_link(original: Dictionary) -> Dictionary:
	var key: String = original.key
	if _screen_cache.has(key): return _screen_cache[key]
	var link: Dictionary = original.duplicate()
	var points := PackedVector2Array()
	for point in original.points: points.append(_layout_project.call(point))
	link.points = points
	link.lengths = Geometry.distances(points)
	for field in ["first_controls", "controls"]:
		var controls := PackedVector2Array()
		for point in original[field]: controls.append(_layout_project.call(point))
		link[field] = controls
	link.a = points[0]
	link.b = points[-1]
	_screen_cache[key] = link
	return link


func _port(key: String, output: bool) -> Button:
	var button := Button.new()
	# A small visible socket with a forgiving, invisible hit area.
	button.size = Vector2(44, 44) if preload("res://scenes/input/InteractionProfile.gd").touch_controls() else Vector2(24, 24)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_CROSS
	for state in ["normal", "hover", "pressed", "focus"]:
		button.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	button.draw.connect(func():
		var color: Color = button.get_meta("port_color", Color("89ddbd") if output else Color("8ecaff"))
		var colors: Array = button.get_meta("bundle_colors", [])
		if colors.is_empty(): button.draw_circle(button.size * .5, 4.0, color, true, -1.0, true)
		var pitch: float = button.get_meta("stack_pitch", 6.0)
		for i in colors.size():
			var center := button.size * .5 + Vector2(0, (i - (colors.size() - 1) * 0.5) * pitch)
			button.draw_circle(center, 4.0, colors[i], true, -1.0, true)
	)
	button.tooltip_text = tr("Drag to another terminal's input" if output else "Receive a connection") + " · " + preload("res://scenes/PaneTargets.gd").label(Ports.node_id(key)) + (" / " + Ports.port_id(key) if not Ports.port_id(key).is_empty() else "")
	add_child(button)
	# Theme changes can change the minimum hit area. Geometry sync itself owns
	# button size; listening to resized feeds its layout writes back into sync.
	button.theme_changed.connect(_graph_changed, CONNECT_DEFERRED)
	if output:
		button.gui_input.connect(func(event):
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				start_connection(key, bool(event.get_meta("direct_touch", false)))
				button.accept_event()
		)
	return button


func start_connection(key: String, touch: bool) -> void:
	dragging = key
	touch_drag = touch
	cursor = port_center(key, true)
	clear_edge_hover()
	redraw()

func nearest_socket(at: Vector2) -> Dictionary:
	var hit := {}
	var distance := INF
	for output in [false, true]:
		for key in sockets(output):
			var button: Button = sockets(output)[key]
			var candidate := at.distance_to(port_center(key, output))
			if button.visible and Rect2(button.position, button.size).has_point(at) and candidate < distance:
				distance = candidate
				hit = {"key": key, "output": output}
	return hit


func sockets(output: bool) -> Dictionary:
	return socket_index[1 if output else 0]

func has_socket(key: String, output: bool) -> bool:
	return sockets(output).has(key)

func port_center(key: String, output: bool) -> Vector2:
	if sheet_geometry: return sheet_sockets.get(("out:" if output else "in:") + key, Vector2.INF)
	var button: Button = sockets(output).get(key)
	return button.position + button.size * 0.5 if button != null else Vector2.INF

func socket_color(key: String, output: bool) -> Color:
	var button: Button = sockets(output).get(key)
	return button.get_meta("port_color", Color("89ddbd")) if button != null else Color("89ddbd")

func disconnect_sockets(source: String, target: String) -> void:
	graph.disconnect_nodes(Ports.node_id(source), Ports.node_id(target), Ports.port_id(source), Ports.port_id(target))

static func link_key(link: Dictionary) -> String:
	return str(link.get("key", str(link.source) + ">" + str(link.target)))


func _input(event: InputEvent) -> void:
	if not editing: return
	if touch_drag and not dragging.is_empty() and event is InputEventMouse and not event.get_meta("direct_touch", false): return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and not dragging.is_empty():
		dragging = ""
		clear_edge_hover()
		get_viewport().set_input_as_handled()
	if dragging.is_empty(): return
	if event is InputEventMouse:
		cursor = get_global_transform_with_canvas().affine_inverse() * event.position
		# Let GUI receive the release so the output button relinquishes mouse capture.
		if event is InputEventMouseMotion:
			get_viewport().set_input_as_handled()
		redraw()
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			var source := dragging
			dragging = ""
			touch_drag = false
			for key in sockets(false):
				if Ports.node_id(key) != Ports.node_id(source) and cursor.distance_to(port_center(key, false)) < 24:
					_connect_compact(source, key)
					break


func _choose_port(node: String, output: bool, chosen: Callable) -> void:
	var declared := Ports.ports(graph.nodes.get(node, {}), output)
	if declared.size() == 1:
		chosen.call(Ports.socket_id(node, str(declared[0].id)))
		return
	if declared.is_empty(): return
	var menu := PopupMenu.new()
	add_child(menu)
	for descriptor in declared:
		var label := str(descriptor.get("name", descriptor.id))
		menu.add_item(label if graph.nodes[node].has("manifest") else tr(label))
	menu.index_pressed.connect(func(index): chosen.call(Ports.socket_id(node, str(declared[index].id))))
	menu.popup_hide.connect(menu.queue_free)
	preload("res://scenes/input/PointerPopup.gd").open(menu)


func _connect_compact(source: String, target: String, source_chosen := false, target_chosen := false) -> void:
	if not source_chosen and compact_nodes.has(Ports.node_id(source)):
		_choose_port(Ports.node_id(source), true, func(selected): _connect_compact(selected, target, true, target_chosen))
	elif not target_chosen and compact_nodes.has(Ports.node_id(target)):
		_choose_port(Ports.node_id(target), false, func(selected): _connect_compact(source, selected, true, true))
	else:
		connect_sockets(source, target)


func connect_sockets(source: String, target: String) -> void:
	clear_edge_hover()
	tools.begin_edit()
	var result: Dictionary = graph.connect_nodes({"from": Ports.node_id(source), "to": Ports.node_id(target), "from_port": Ports.port_id(source), "to_port": Ports.port_id(target)})
	tools.finish_edit()
	if result.has("error"): push_warning(str(result.error.message))


func _endpoint_description(edge: Dictionary, output: bool) -> String:
	var node_id: String = edge.from if output else edge.to
	var node: Dictionary = graph.nodes.get(node_id, {})
	var title := str(node.get("title", ""))
	if title.is_empty(): title = str(node.get("manifest", {}).get("name", preload("res://scenes/PaneTargets.gd").label(node_id)))
	var port_id := str(edge.get("from_port" if output else "to_port", ""))
	for port in Ports.ports(node, output):
		if port.id == port_id:
			var name := str(port.get("name", ""))
			if not node.has("manifest"): name = tr(name)
			return title + " · " + (name if not name.is_empty() else port_id)
	return title + (" · " + port_id if not port_id.is_empty() else "")


func edge_tooltip(key: String) -> String:
	var edge: Dictionary = graph.edges.get(key, {})
	if edge.is_empty(): return ""
	var text := _endpoint_description(edge, true) + "\n→ " + _endpoint_description(edge, false)
	var queue: Dictionary = graph.queue_log.snapshot(key)
	text += "\n" + tr("%d pending · %d recorded deliveries") % [queue.pending, queue.events.size()]
	text += "\n" + tr("Click this wire for delivery history · Double-click to add a reroute.")
	if edge.get("muted", false): text += "\n" + tr("Paused")
	if graph.connection_expired(edge):
		text += "\n" + tr("Stopped: stop time reached")
	elif float(edge.get("stop_at", 0.0)) > 0.0:
		var offset := int(Time.get_time_zone_from_system().bias)
		var local := Time.get_datetime_string_from_unix_time(int(edge.stop_at) + offset * 60, true)
		text += "\n" + tr("Stops at %s (local time)") % local
	if not str(edge.get("contains", "")).is_empty(): text += "\n" + tr("Contains: %s") % str(edge.contains)
	if not str(edge.get("outcome", "")).is_empty(): text += "\n" + tr("Outcome: %s") % tr(str(edge.outcome))
	for i in range(graph.receipts.size() - 1, -1, -1):
		var receipt: Dictionary = graph.receipts[i]
		if receipt.get("edge", str(receipt.get("source")) + ">" + str(receipt.get("target"))) != key: continue
		text += "\n" + tr("Last delivery: %s") % tr(str(receipt.get("status", "unknown")))
		if not str(receipt.get("message", "")).is_empty(): text += "\n" + str(receipt.message)
		break
	return text


func clear_edge_hover() -> void:
	hover_edge = ""
	hover_timer.stop()
	edge_hint.hide()


func update_edge_hover(at: Vector2) -> void:
	hover_position = at
	if not editing or not is_visible_in_tree() or not dragging.is_empty() or not tools.gesture.is_empty() or not tools.cut.is_empty():
		clear_edge_hover()
		return
	var queued_key := queue_hit(at)
	if not queued_key.is_empty():
		if hover_edge != queued_key:
			clear_edge_hover()
			hover_edge = queued_key
			hover_timer.start()
		elif edge_hint.visible: _show_edge_hint()
		return
	# Ports have their own native tooltips. Never cover them with an edge hint.
	for output in [false, true]:
		for button in sockets(output).values():
			if button.get_rect().has_point(at):
				clear_edge_hover()
				return
	for bounds in pane_screen_bounds.values():
		if bounds.has_point(at):
			clear_edge_hover()
			return
	var hit: Dictionary = tools.hit_wire(at)
	var key := "" if hit.is_empty() else link_key(hit)
	if key.is_empty():
		clear_edge_hover()
	elif key != hover_edge:
		clear_edge_hover()
		hover_edge = key
		hover_timer.start()
	elif edge_hint.visible:
		_show_edge_hint()


func _show_edge_hint() -> void:
	if not editing or not is_visible_in_tree() or not graph.edges.has(hover_edge):
		clear_edge_hover()
		return
	edge_hint_text.text = edge_tooltip(hover_edge)
	edge_hint_text.custom_minimum_size.x = minf(360, maxf(80, size.x - 40))
	edge_hint.reset_size()
	var extent := edge_hint.get_combined_minimum_size()
	edge_hint.position = Vector2(clampf(hover_position.x + 16, 0, maxf(0, size.x - extent.x)), clampf(hover_position.y + 20, 0, maxf(0, size.y - extent.y)))
	edge_hint.show()


func queue_indicator_position(queued: Dictionary) -> Vector2:
	var route := _route(queued.source, queued.target, queued.key)
	if route.is_empty(): return Vector2.INF
	var link: Dictionary = route.link
	var distance: float = minf(12.0, link.lengths[-1] * 0.2)
	if queued.get("received", false): distance = link.lengths[-1] - distance
	if route.reverse: distance = link.lengths[-1] - distance
	return Geometry.at_distance(link.points, link.lengths, distance)


func queue_hit(at: Vector2) -> String:
	var nearest := ""
	var distance := 10.0
	for queued in waiting.values():
		var delta := at.distance_to(queue_indicator_position(queued))
		if delta < distance:
			distance = delta
			nearest = queued.key
	return nearest


func open_queue_inspector(key: String) -> void:
	if not is_instance_valid(graph): return
	clear_edge_hover()
	if not is_instance_valid(queue_inspector):
		queue_inspector = preload("res://scenes/GraphQueueInspector.gd").new()
		add_child(queue_inspector)
	queue_inspector.inspect(graph, key)


static func curve(a: Vector2, b: Vector2) -> PackedVector2Array:
	return Geometry.curve(a, b)


func _route(source: String, target: String, key := "") -> Dictionary:
	for link in sheet_links:
		if link.source == source and link.target == target and (key.is_empty() or link_key(link) == key):
			return {"link": _screen_link(link), "reverse": false}
	return {}


func _message_transferred(source: String, target: String, event_id: String) -> void:
	queued_routes.erase(event_id)
	var key: String = graph.event_edges.get(event_id, source + ">" + target)
	if not is_visible_in_tree() or _route(source, target, key).is_empty(): return
	# Flow means sent/received by the adapter, or dequeued by Codex, not model completion.
	pulses.append({"source": source, "target": target, "event_id": event_id, "key": key, "distance": 0.0, "age": 0.0})
	if pulses.size() > 64: pulses.pop_front()
	set_process(true)
	marker_layer.queue_redraw()


func _message_rejected(source: String, target: String, event_id: String, reason: String) -> void:
	var route: Dictionary = queued_routes.get(event_id, _route(source, target, graph.event_edges.get(event_id, source + ">" + target)))
	queued_routes.erase(event_id)
	if not is_visible_in_tree() or route.is_empty(): return
	for pulse in pulses.duplicate():
		if pulse.event_id == event_id:
			if pulse.get("failed", false): return
			pulses.erase(pulse)
	# Preserve the last route so cancelling by disconnect still has a visible result.
	pulses.append({"source": source, "target": target, "event_id": event_id,
		"key": graph.event_edges.get(event_id, source + ">" + target), "distance": 0.0, "age": 0.0, "failed": true, "reason": reason, "route": route.duplicate(true)})
	if pulses.size() > 64: pulses.pop_front()
	set_process(true)
	marker_layer.queue_redraw()


func _pulse_route(pulse: Dictionary) -> Dictionary:
	return pulse.route if pulse.get("failed", false) else _route(pulse.source, pulse.target, pulse.get("key", ""))


func _refresh_waiting() -> void:
	# External disconnects must retire routes before a same-endpoint reconnect,
	# even when both requests arrive between rendered frames.
	waiting.clear()
	if not hover_edge.is_empty(): update_edge_hover(hover_position)
	if is_instance_valid(graph):
		for queue in graph.queues.values():
			for event in queue: _add_waiting(event)
		for row in graph.queue_log.entries.values():
			if row.pending and row.status == "queued in Codex": _add_waiting(row)
	set_process(not pulses.is_empty() or not waiting.is_empty())
	marker_layer.queue_redraw()


func _add_waiting(event: Dictionary) -> void:
	if not is_visible_in_tree(): return
	var key: String = graph.event_edge(event)
	if not graph.edges.has(key) or _edge_paused(graph.edges[key]): return
	var route := _route(event.source, event.target, key)
	if route.is_empty(): return
	queued_routes[event.event_id] = route.duplicate(true)
	if queued_routes.size() > 256: queued_routes.erase(queued_routes.keys()[0])
	var failed: bool = event.get("progress", {}).get("status", "") == "failed"
	var received: bool = failed or event.get("progress", {}).get("status", "") == "pending"
	var group := key + (":failed" if failed else (":received" if received else ""))
	if not waiting.has(group): waiting[group] = {"source": event.source, "target": event.target, "key": key, "ids": {}, "received": received, "failed": failed}
	waiting[group].ids[event.event_id] = true


func _process(dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(dt)
	preload("res://graffitty/frame_profile.gd").add("AgentGraphOverlay", Time.get_ticks_usec() - profiled_started)


func _process_body(dt: float) -> void:
	blink_time = fmod(blink_time + dt, 1.2)
	for pulse in pulses.duplicate():
		var route := _pulse_route(pulse)
		if not is_visible_in_tree() or route.is_empty() or not is_instance_valid(graph) or not ports.has(pulse.source) or not ports.has(pulse.target) or (not pulse.get("failed", false) and not graph.edges.has(pulse.get("key", pulse.source + ">" + pulse.target))):
			pulses.erase(pulse)
			continue
		var total: float = route.link.lengths[-1]
		var duration := maxf(MIN_FLOW_DURATION, total / MESSAGE_SPEED)
		pulse.age += dt
		# One traversal, without wrapping. Distance-based sampling keeps its speed
		# steady through bends; short links move more slowly so the send is visible.
		pulse.distance = total * minf(pulse.age / duration, 1.0)
		if pulse.age > duration:
			pulse.distance = total + 24.0 * (pulse.age - duration) / 0.12
		if pulse.age >= duration + 0.12:
			pulses.erase(pulse)
	set_process(not pulses.is_empty() or not waiting.is_empty())
	marker_layer.queue_redraw()


func _edge_paused(edge: Dictionary) -> bool:
	return edge.get("muted", false) or graph.connection_expired(edge)


func draw_established_links(painter: Node2D) -> void:
	# The first canvas draw can precede workspace graph assignment.
	painter.begin_wires()
	if is_instance_valid(graph):
		sheet_geometry = true
		_draw_sheet_links(painter)
		sheet_geometry = false
	painter.end_wires()
	painter.project_stems(_layout_project, tools.segment_dim)


func _draw_sheet_links(painter: Node2D) -> void:
	if painter.include_selection: tools.draw_selection(painter)
	for link in sheet_links:
		if compact_nodes.has(link.source):
			var bundle := str(link.source) + ">" + str(link.target)
			var members: Array = compact_bundles.get(bundle, [])
			if not members.is_empty() and members[0] == link_key(link):
				_draw_compact_bundle(painter, bundle, link, members)
			continue
		if tools.preview_detached(link_key(link)): continue
		var points: PackedVector2Array = link.points
		var alpha := 1.0 if tools.related(link) else 0.22
		var paused := _edge_paused(graph.edges.get(link_key(link), {}))
		var color := Color("80909e") if paused else socket_color(link.get("from_socket", link.source), true)
		color.a = alpha
		var width := (2.5 if tools.hovered == link_key(link) else 1.5) * maxf(1.0, 1.0 / _wire_screen_scale)
		var draw_path: bool = tools.visual().routes.get(link_key(link), []).is_empty()
		var pattern := wire_pattern(graph.edges.get(link_key(link), {}))
		var entry: Node2D = painter.wire_entry(link_key(link), [points, color, width, draw_path, pattern])
		if entry == null: continue
		if draw_path: draw_wire(entry, points, color, width, pattern == "dashed", pattern == "dotted")
		var arrow: PackedVector2Array = Geometry.path_arrow(points)
		if not arrow.is_empty(): entry.polygon(arrow, color)

	# Automatic links have no shared stems; avoid building that topology at all.
	if tools.visual().reroutes.is_empty(): return
	# Draw shared reroute stems once. A stem is muted only when all downstream
	# connections are muted, matching Blender's reroute propagation semantics.
	for segment in tools.visual_segments(true, false):
		segment = segment.duplicate()
		segment.edges = segment.edges.filter(func(key): return not compact_nodes.has(graph.edges[key].from))
		if segment.edges.is_empty(): continue
		if not tools.visual().reroutes.has(segment.from) and not tools.visual().reroutes.has(segment.to): continue
		var related := false
		for key in segment.edges:
			var edge: Dictionary = graph.edges[key]
			related = related or tools.related({"source": edge.from, "target": edge.to, "key": key, "from_socket": Ports.endpoint(edge, true), "to_socket": Ports.endpoint(edge, false)})
		var first_edge: Dictionary = graph.edges[segment.edges[0]]
		var paused: bool = segment.edges.all(func(key): return _edge_paused(graph.edges[key]))
		var color := Color("80909e") if paused else socket_color(Ports.endpoint(first_edge, true), true)
		color.a = 1.0 if related else 0.22
		if painter.frozen:
			color.a *= tools.segment_dim(_layout_project.call(segment.points[0]), _layout_project.call(segment.points[-1]))
		var dashed: bool = segment.edges.all(func(key): return wire_pattern(graph.edges[key]) != "solid")
		var width := (2.5 if tools.hovered in segment.edges else 1.5) * maxf(1.0, 1.0 / _wire_screen_scale)
		var entry: Node2D = painter.wire_entry("stem:" + str(segment.from) + ">" + str(segment.to), [segment.points, color, width, dashed, paused])
		if entry != null: draw_wire(entry, segment.points, color, width, dashed, paused)


func _draw_compact_bundle(painter: Node2D, bundle: String, link: Dictionary, members: Array) -> void:
	var styles: Array = []
	for key in members:
		if tools.preview_detached(key): continue
		var edge: Dictionary = graph.edges.get(key, {})
		var color := socket_color(Ports.endpoint(edge, true), true)
		color.a = 1.0 if tools.related(link) else 0.22
		styles.append([color, wire_pattern(edge)])
	if styles.is_empty(): return
	# Compact bundles carry several colors and must stay readable zoomed out.
	var pattern_scale := maxf(1.0, 0.5 / _wire_screen_scale)
	var width := (10.0 if tools.hovered in members else 8.0) * pattern_scale
	var entry: Node2D = painter.wire_entry("bundle:" + bundle, [link.points, styles, width, pattern_scale])
	if entry != null: entry.patterned_ribbon(link.points, styles, width, pattern_scale)


func draw_markers(painter: Node2D) -> void:
	if not is_instance_valid(graph): return
	for queued in waiting.values():
		var point := queue_indicator_position(queued)
		if not point.is_finite(): continue
		var alpha := 0.35 + 0.65 * (0.5 + 0.5 * cos(blink_time / 1.2 * TAU))
		var indicator := Color(1.0, 0.3, 0.3, alpha) if queued.get("failed", false) else Color(1.0, 0.76, 0.35, alpha)
		painter.circle(point, 4.0, indicator, true, -1.0, true)
		indicator.a *= 0.4
		painter.arc(point, 6.5, 0, TAU, 24, indicator, 1.0, true)
	for pulse in pulses:
		var route := _pulse_route(pulse)
		if route.is_empty(): continue
		var link: Dictionary = route.link
		var total: float = link.lengths[-1]
		if pulse.get("failed", false):
			var distance: float = minf(pulse.distance, total)
			var point := Geometry.at_distance(link.points, link.lengths, total - distance if route.reverse else distance)
			var color := Color("ff8585")
			color.a = clampf((total + 24 - pulse.distance) / 24.0, 0.0, 1.0)
			if not graph.edges.has(pulse.get("key", pulse.source + ">" + pulse.target)):
				painter.polyline(link.points, Color(1.0, 0.45, 0.45, 0.15 * color.a), 1.0, true)
			for diagonal in [Vector2(4, 4), Vector2(4, -4)]:
				painter.line(point - diagonal, point + diagonal, Color("14212a"), 4.5, true)
				painter.line(point - diagonal, point + diagonal, color, 2.0, true)
			continue
		var output := Ports.port_id(str(pulse.get("key", "")).get_slice(">", 0))
		var spec := {}
		for port in Ports.ports(graph.nodes.get(pulse.source, {}), true):
			if port.id == output: spec = port.get("icon", {})
		var color := socket_color(str(pulse.get("key", "")).get_slice(">", 0), true)
		if not spec.is_empty():
			if pulse.distance <= total:
				var point := Geometry.at_distance(link.points, link.lengths, total - pulse.distance if route.reverse else pulse.distance)
				painter.symbol(point, spec, color)
			continue
		# A small fading trail makes direction clear even on short connections.
		for i in range(3, -1, -1):
			var distance: float = pulse.distance - i * 7.0
			if distance < 0 or distance > total: continue
			var point := Geometry.at_distance(link.points, link.lengths, total - distance if route.reverse else distance)
			painter.circle(point, 3.2 - i * 0.55, Color(color, 1.0 - i * 0.23), true, -1.0, true)


func _draw() -> void:
	var profiled_started := Time.get_ticks_usec()
	_draw_body()
	preload("res://graffitty/frame_profile.gd").add("AgentGraphOverlay._draw", Time.get_ticks_usec() - profiled_started)


func _draw_body() -> void:
	tools.draw_overlay()
	if not dragging.is_empty() and has_socket(dragging, true):
		var target := cursor
		var valid := false
		var destination := ""
		for key in sockets(false):
			if Ports.node_id(key) != Ports.node_id(dragging) and cursor.distance_to(port_center(key, false)) < 24:
				target = port_center(key, false)
				valid = true
				destination = key
		var preview: PackedVector2Array = tools.route_points(dragging + ">" + destination, port_center(dragging, true), target).points
		draw_preview_wire(preview, dragging)
		draw_arc(target, 9, 0, TAU, 24, Color("c5f5e4") if valid else Color("ffd47a"), 2, true)


func draw_preview_wire(points: PackedVector2Array, source: String, previous_edge: Dictionary = {}) -> void:
	var mode := Ports.mode(graph.nodes.get(Ports.node_id(source), {}), Ports.port_id(source))
	var edge := previous_edge.duplicate()
	if not mode.is_empty():
		edge.merge({"from": Ports.node_id(source), "from_port": Ports.port_id(source),
			"read": mode == "read", "send": mode == "send", "turn_completed": mode == "turn_completed"}, true)
	var pattern := wire_pattern(edge)
	var color_source := source if has_socket(source, true) else Ports.endpoint(previous_edge, true) if previous_edge.has("from") else ""
	var color := socket_color(color_source, true) if has_socket(color_source, true) else Color("ffd47a")
	if pattern == "dotted": color = Color("80909e")
	draw_wire(self, points, color, 3, pattern == "dashed", pattern == "dotted")


func _box() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("14212a")
	style.border_color = Color("436878")
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	return style


func wire_pattern(edge: Dictionary) -> String:
	# Resolve the wire pattern from port metadata. Use the same rule for
	# finished wires, previews, and shared reroute stems.
	#
	# - Dotted overrides every style on muted or expired connections.
	# - Solid marks automatic emission (Turn completed, Manual Prompt, SystemOne).
	# - Dashed marks access or agent choice (Read, agent-controlled Send).
	if _edge_paused(edge): return "dotted"
	var node: Dictionary = graph.nodes.get(edge.get("from", ""), {})
	var output := Ports.resolve(node, true, str(edge.get("from_port", "")))
	for port in Ports.ports(node, true):
		if port.id == output and port.get("line_style", "") in ["solid", "dashed"]:
			return port.line_style
	if not edge.get("turn_completed", false) and (edge.get("read", false) or edge.get("send", false)):
		return "dashed"
	return "solid"


func draw_wire(painter: CanvasItem, points: PackedVector2Array, color: Color, width: float, dashed: bool, dotted := false) -> void:
	if points.size() < 2: return
	# Preview coordinates are already on screen; established wires use the
	# canvas adapter. Both paths share the same line-pattern renderer.
	var circle := Callable(painter, "draw_circle" if painter == self else "circle")
	var polyline := Callable(painter, "draw_polyline" if painter == self else "polyline")
	var pattern_scale := 1.0 if painter == self else maxf(1.0, 1.0 / _wire_screen_scale)
	if dotted:
		var lengths := Geometry.distances(points)
		var distance := 0.0
		while distance < lengths[-1]:
			circle.call(Geometry.at_distance(points, lengths, distance), width * 0.65, color, true, -1.0, true)
			distance += 7.0 * pattern_scale
		return
	polyline.call(points, Color(0.08, 0.13, 0.16, color.a), 4.0 * pattern_scale, true)
	if not dashed:
		polyline.call(points, color, width, true)
		return
	# One retained batch, not hundreds of GDScript calls and GPU buffers.
	var segments := Geometry.dashed_segments(points, 10.0 * pattern_scale, 6.0 * pattern_scale)
	# A drag can begin with coincident endpoints. Godot requires a nonempty
	# list of endpoint pairs, even when there is nothing visible to paint yet.
	if segments.size() < 2 or segments.size() % 2 != 0: return
	if painter == self: draw_multiline(segments, color, width, true)
	else: painter.multiline(segments, color, width, true)


func redraw() -> void:
	queue_redraw()
	if is_instance_valid(wire_layer): wire_layer.queue_redraw()
	if is_instance_valid(marker_layer): marker_layer.queue_redraw()

func mount_wire_layer(canvas: Control, unproject: Callable) -> void:
	wire_layer.unproject = unproject
	marker_layer.unproject = unproject
	if marker_layer.get_parent() != canvas:
		marker_layer.reparent(canvas, false)
		canvas.move_child(marker_layer, 0)
	if wire_layer.get_parent() != canvas:
		# Geometry is already unprojected into sheet coordinates. Retaining the
		# overlay's global transform adds the title strip's offset a second time.
		wire_layer.reparent(canvas, false)
		canvas.move_child(wire_layer, 0)
	redraw()

func _notification(what: int) -> void:
	var profiled_started := Time.get_ticks_usec()
	_notification_body(what)
	preload("res://graffitty/frame_profile.gd").add("AgentGraphOverlay._notification", Time.get_ticks_usec() - profiled_started)


func _notification_body(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		if not hover_edge.is_empty(): edge_hint_text.text = edge_tooltip(hover_edge)
