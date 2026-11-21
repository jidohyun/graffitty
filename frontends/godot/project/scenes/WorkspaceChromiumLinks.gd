extends Control
## Ownership geometry is retained on the sheet, beneath pane contents.
## Screen-space copies support inspection without repainting on camera motion.
var edges: Array[PackedVector2Array]:
	get:
		var result: Array[PackedVector2Array] = []
		for edge in sheet_edges:
			var projected := PackedVector2Array()
			for point in edge: projected.append(_project.call(point) if _project.is_valid() else point)
			result.append(projected)
		return result
var _project: Callable
var sheet_edges: Array[PackedVector2Array] = []
var visible_area := Rect2()
var routes := {}
var wire_layer := preload("res://scenes/GraphWireLayer.gd").new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	wire_layer.overlay = self
	wire_layer.sheet_coordinates = true
	add_child(wire_layer)


func mount_wire_layer(canvas: Control, unproject: Callable) -> void:
	wire_layer.unproject = unproject
	if wire_layer.get_parent() != canvas:
		# Screen-space chrome must not offset the sheet-space wire geometry.
		wire_layer.reparent(canvas, false)
		canvas.move_child(wire_layer, 0)


func sync(rectangles: Dictionary, owners: Dictionary, project := Callable(), routing_rectangles: Dictionary = {}, graph_edges: Array = []) -> void:
	_project = project
	# This is presentation-only: ownership metadata remains authoritative even
	# when an explicit graph wire already explains the relationship.
	var connected := {}
	for edge in graph_edges:
		connected[str(edge.from) + ">" + str(edge.to)] = true
		connected[str(edge.to) + ">" + str(edge.from)] = true
	var next_sheet: Array[PackedVector2Array] = []
	var next_routes := {}
	for chromium in owners:
		var terminal: String = owners[chromium]
		if connected.has(terminal + ">" + str(chromium)): continue
		if not rectangles.has(chromium) or not rectangles.has(terminal):
			continue
		var source: Rect2 = routing_rectangles.get(terminal, rectangles[terminal])
		var destination: Rect2 = routing_rectangles.get(chromium, rectangles[chromium])
		# Choose topology from resting layout only. Camera movement and typing
		# zoom must not change the chosen side of an overlap detour either.
		var cached: Dictionary = routes.get(chromium, {})
		if cached.get("owner") == terminal and cached.get("source") == source and cached.get("destination") == destination and cached.get("visual_source") == rectangles[terminal] and cached.get("visual_destination") == rectangles[chromium]:
			next_routes[chromium] = cached
			next_sheet.append(cached.sheet)
			continue
		var path := PackedVector2Array()
		if cached.get("owner") == terminal and cached.get("source") == source and cached.get("destination") == destination:
			path = cached.path
		elif source.grow(4).intersects(destination):
			path = overlap_path(source, destination, project)
		else:
			path = PackedVector2Array([
				perimeter(source, destination.get_center()),
				perimeter(destination, source.get_center()),
			])
		next_routes[chromium] = {"owner": terminal, "source": source, "destination": destination, "path": path}
		var start_delta := visual_attachment(path[0], source, rectangles[terminal]) - path[0]
		var end_delta := visual_attachment(path[-1], destination, rectangles[chromium]) - path[-1]
		var sheet := PackedVector2Array()
		var samples := (path.size() - 1) * 8
		for sample in samples + 1:
			var segment := mini(sample / 8, path.size() - 2)
			var point := path[segment].lerp(path[segment + 1], float(sample - segment * 8) / 8)
			point += start_delta.lerp(end_delta, smoothstep(0.0, 1.0, float(sample) / samples))
			sheet.append(point)
		var finite := true
		for point in sheet:
			finite = finite and point.is_finite()
		if finite:
			next_sheet.append(sheet)
			next_routes[chromium].merge({"visual_source": rectangles[terminal], "visual_destination": rectangles[chromium], "sheet": sheet})
	routes = next_routes
	if next_sheet != sheet_edges:
		sheet_edges = next_sheet
		wire_layer.queue_redraw()


static func visual_attachment(point: Vector2, resting: Rect2, visual: Rect2) -> Vector2:
	return visual.position + (point - resting.position) / resting.size.max(Vector2.ONE * 0.001) * visual.size


func overlap_path(source: Rect2, destination: Rect2, project: Callable) -> PackedVector2Array:
	var candidates: Array[PackedVector2Array] = []
	for side in 4:
		var horizontal := side < 2
		var far_side := side % 2 == 1
		var start := source.position + source.size * (
			Vector2(0.35, 1 if far_side else 0) if horizontal else Vector2(1 if far_side else 0, 0.35)
		)
		var end := destination.position + destination.size * (
			Vector2(0.65, 1 if far_side else 0) if horizontal else Vector2(1 if far_side else 0, 0.65)
		)
		var corner_a := start
		var corner_b := end
		var axis := 1 if horizontal else 0
		var outside := maxf(source.end[axis], destination.end[axis]) + 24 if far_side else minf(source.position[axis], destination.position[axis]) - 24
		corner_a[axis] = outside
		corner_b[axis] = outside
		candidates.append(PackedVector2Array([start, corner_a, corner_b, end]))
	var best := candidates[0]
	var best_score := -1
	# At high zoom the top route may be outside the view or behind the tab bar.
	# Choose the side with the most visible samples, keeping both endpoints linked.
	for candidate in candidates:
		var score := 0
		for i in 3:
			for sample in 9:
				var point := candidate[i].lerp(candidate[i + 1], float(sample) / 8)
				if project.is_valid():
					point = project.call(point)
				if not visible_area.has_area() or visible_area.has_point(point):
					score += 1
		if score > best_score:
			best = candidate
			best_score = score
	return best


static func perimeter(rect: Rect2, toward: Vector2) -> Vector2:
	var direction := toward - rect.get_center()
	var half := rect.size * 0.5
	var scale := maxf(absf(direction.x) / maxf(half.x, 0.001), absf(direction.y) / maxf(half.y, 0.001))
	return rect.get_center() + direction / maxf(scale, 0.001)


func draw_established_links(layer: Node2D) -> void:
	layer.begin_wires()
	for key in routes:
		if not routes[key].has("sheet"): continue
		var edge: PackedVector2Array = routes[key].sheet
		var entry: Node2D = layer.wire_entry(str(key), [edge])
		if entry == null: continue
		# Dark outline keeps the link legible against both light and dark worlds.
		entry.polyline(edge, Color("182536"), 5.0, true)
		entry.polyline(edge, Color("8ecaff"), 2.0, true)
		for endpoint in [edge[0], edge[-1]]:
			entry.circle(endpoint, 4.0, Color("182536"), true, -1.0, true)
			entry.circle(endpoint, 2.5, Color("8ecaff"), true, -1.0, true)
	layer.end_wires()
