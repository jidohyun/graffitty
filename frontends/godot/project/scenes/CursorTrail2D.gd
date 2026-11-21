extends Node2D
## Kitty-style four-corner exponential cursor trail in terminal cell coordinates.
## Based on kitty/cursor_trail.c (GPLv3); geometry is reprojected each frame.
var style := "smear"
var duration := 0.4
var age := 0.0
var previous := Rect2()
var event_seed := 0.0
var jaggedness := 0.085
var glow_width := 5.5
var delay_ms := 0
var decay := Vector2(0.1, 0.4)
var threshold := Vector2(2, 2)
var color := Color.WHITE
var cursor_shape := Rect2(0, 0, 1, 1)
var corners := PackedVector2Array()
var target := PackedVector2Array()
var pending_cell := Vector2(-1, -1)
var target_cell := Vector2(-1, -1)
var stable_time := 0.0
var grid_size := Vector2i.ZERO
var active := false
var _material := ShaderMaterial.new()
var _node: Polygon2D


func _ready() -> void:
	_material.shader = preload("res://scenes/cursor_trail_2d.gdshader")
	_node = Polygon2D.new()
	# A one-pixel texture preserves explicit cell-space UVs in Polygon2D.
	var white := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	white.fill(Color.WHITE)
	_node.texture = ImageTexture.create_from_image(white)
	_node.material = _material
	add_child(_node)
	_node.hide()


func configure(delay: int, times: Vector2, start_threshold: Vector2, tint: Color, selected_style := "smear", options: Dictionary = {}) -> void:
	if style != selected_style: clear()
	style = selected_style
	duration = maxf(float(options.get("duration", 0.4)), 0.001)
	jaggedness = maxf(float(options.get("jaggedness", 0.085)), 0.0)
	glow_width = maxf(float(options.get("glow_width", 5.5)), 0.01)
	_material.set_shader_parameter("trail_style", {"smear": 0, "blaze": 1, "lightning": 2}.get(style, 0))
	for key in options:
		var value = options[key]
		_material.set_shader_parameter("effect_" + key, Color(str(value)) if key.ends_with("color") and not value is Color else value)
	delay_ms = maxi(delay, 0)
	decay = Vector2(maxf(times.x, 0.001), maxf(times.y, maxf(times.x, 0.001)))
	threshold = start_threshold.max(Vector2.ZERO)
	color = tint
	if delay_ms == 0:
		clear()


func rect(cell: Vector2) -> PackedVector2Array:
	var origin := cell + cursor_shape.position
	var size := cursor_shape.size
	return PackedVector2Array(
		[origin + Vector2(size.x, 0), origin, origin + Vector2(0, size.y), origin + size]
	)


func update_cursor(
	cell: Vector2i,
	grid: Vector2i,
	dt: float,
	cell_pixels: Vector2,
	project: Callable,
	shape: Rect2 = Rect2(0, 0, 1, 1),
	cursor_color: Color = Color.WHITE,
	emit_trail := true,
) -> void:
	if delay_ms == 0 or cell.x < 0 or grid.x < 1 or grid.y < 1:
		clear()
		return
	if cursor_shape != shape:
		cursor_shape = shape
		target = rect(target_cell)
		if not active:
			corners = target.duplicate()
	if grid_size != grid or corners.is_empty():
		grid_size = grid
		pending_cell = Vector2(cell)
		target_cell = pending_cell
		target = rect(target_cell)
		corners = target.duplicate()
		active = false
		stable_time = 0
	if Vector2(cell) != pending_cell:
		pending_cell = Vector2(cell)
		stable_time = 0
	else:
		stable_time += dt
	if pending_cell != target_cell and stable_time * 1000.0 >= delay_ms and (emit_trail or not active):
		var distance := (pending_cell - target_cell).abs()
		previous = Rect2(target_cell + cursor_shape.position, cursor_shape.size)
		target_cell = pending_cell
		target = rect(target_cell)
		if not emit_trail:
			if not active: corners = target.duplicate()
		elif not active and distance.x <= threshold.x and distance.y <= threshold.y:
			corners = target.duplicate()
		else:
			active = true
			age = 0.0
			event_seed += 1.0
	if active:
		if style == "smear":
			advance_corners(dt, cell_pixels)
		else:
			age += dt
			active = age < duration
	_node.visible = active
	if not active:
		return
	var draw_corners := effect_corners(cell_pixels)
	var points := PackedVector2Array()
	for i in 4:
		points.append(project.call(draw_corners[i] / Vector2(grid)))
	_node.polygon = points
	_node.uv = draw_corners
	_material.set_shader_parameter("cell_pixels", cell_pixels)
	_material.set_shader_parameter("effect_age", age)
	_material.set_shader_parameter("event_seed", event_seed)
	_material.set_shader_parameter("previous_rect", Vector4(previous.position.x, previous.position.y, previous.size.x, previous.size.y))
	_material.set_shader_parameter("target_rect", Vector4(target_cell.x + shape.position.x, target_cell.y + shape.position.y, shape.size.x, shape.size.y))
	# Mask the actual cursor, even while the trail is waiting for a new target.
	var cursor_origin := Vector2(cell) + shape.position
	_material.set_shader_parameter(
		"cursor_rect",
		Vector4(cursor_origin.x, cursor_origin.y, shape.size.x, shape.size.y),
	)
	_material.set_shader_parameter("trail_color", cursor_color if color.a == 0.0 else color)


func advance_corners(dt: float, cell_pixels: Vector2) -> void:
	var dots: Array[float] = []
	var center := (target[0] + target[2]) * 0.5
	for i in 4:
		var delta := (target[i] - corners[i]) * cell_pixels
		var radial := (target[i] - center) * cell_pixels
		dots.append(
			delta.normalized().dot(radial.normalized()) if delta.length() > 0.000001 else 0.0
		)
	var lo: float = dots.min()
	var hi: float = dots.max()
	active = false
	for i in 4:
		var seconds := (
			decay.y
			if is_equal_approx(lo, hi)
			else lerpf(decay.y, decay.x, (dots[i] - lo) / (hi - lo))
		)
		corners[i] = corners[i].lerp(target[i], 1.0 - pow(2.0, -10.0 * dt / seconds))
		var distance := ((corners[i] - target[i]) * cell_pixels).abs()
		active = active or distance.x >= 0.5 or distance.y >= 0.5


func clear() -> void:
	corners.clear()
	target.clear()
	grid_size = Vector2i.ZERO
	active = false
	if _node != null:
		_node.hide()


func effect_corners(cell_pixels: Vector2) -> PackedVector2Array:
	if style == "smear": return corners
	var bounds := previous.merge(Rect2(target_cell + cursor_shape.position, cursor_shape.size))
	var pixels := cell_pixels.max(Vector2.ONE)
	var length_px := ((target_cell + cursor_shape.position - previous.position) * pixels).length()
	var margin := Vector2.ONE * (length_px * (jaggedness + 0.1) + glow_width * 4.0 + 4.0) / pixels
	bounds = Rect2(bounds.position - margin, bounds.size + margin * 2.0)
	return PackedVector2Array([bounds.position, bounds.position + Vector2(bounds.size.x, 0), bounds.end, bounds.position + Vector2(0, bounds.size.y)])
