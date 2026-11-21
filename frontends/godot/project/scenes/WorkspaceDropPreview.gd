extends Control
## Draw the proposed layout without resizing controls or their live PTYs.
var rectangles: Dictionary = { }
var connections: Array = []
var incoming: Array[String] = []
const Layout := preload("res://scenes/WorkspaceLayout.gd")


func present(plan: Dictionary, area: Rect2, point: Vector2, show_incoming := false) -> void:
	rectangles = { }
	connections = []
	incoming = plan.incoming
	# Keep the placement transaction for release, but only advertise tiling
	# inside the main area. Stashed and floating panes are not tile targets.
	if plan.tree.get("tiling", false) and area.has_point(point):
		for key in Layout.tile_keys(plan.tree.get("tiles", { })):
			if plan.rectangles.has(key):
				rectangles[key] = plan.rectangles[key]
	if show_incoming:
		for key in incoming:
			if plan.rectangles.has(key): rectangles[key] = plan.rectangles[key]
	visible = not rectangles.is_empty()
	# Give the renderer real culling bounds. A zero-size Control at the origin
	# disappears when the remote camera crops that origin out of its viewport.
	if visible:
		var bounds: Rect2 = rectangles.values()[0]
		for rect: Rect2 in rectangles.values(): bounds = bounds.merge(rect)
		position = bounds.position - Vector2(4, 4)
		size = bounds.size + Vector2(8, 8)
	queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 50


func _draw() -> void:
	for edge: Dictionary in connections:
		if not rectangles.has(edge.from) or not rectangles.has(edge.to): continue
		var from: Rect2 = rectangles[edge.from]
		var to: Rect2 = rectangles[edge.to]
		var start := Vector2(from.end.x, from.get_center().y) - position
		var end := Vector2(to.position.x, to.get_center().y) - position
		var color := Color("80bdff") if not edge.get("muted", false) else Color("89939f")
		draw_line(start, end, color, 3.0, true)
		var direction := (end - start).normalized()
		draw_colored_polygon(PackedVector2Array([end, end - direction * 14 + direction.orthogonal() * 7, end - direction * 14 - direction.orthogonal() * 7]), color)
	for key in rectangles:
		var rect: Rect2 = rectangles[key]
		rect.position -= position
		var selected: bool = key in incoming
		var color := Color("80bdff") if selected else Color("a5d9c5")
		draw_rect(rect, Color(color, 0.24 if selected else 0.10), true)
		draw_rect(rect, color, false, 4.0 if selected else 2.0)
