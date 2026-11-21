extends Node2D
## Established links and selection glow live on the canvas, before the panes.
## Input/editing chrome stays in AgentGraphOverlay's screen-space layer.
var overlay: Control
var unproject: Callable
var frozen := false
var include_selection := true
var markers_only := false
var sheet_coordinates := false
var draw_count := 0
var commands: Array = []
var selection_commands: Array = []
var _wire_entries := {}
var _used_entries := {}
var _ribbon_styles: Array = []
var _ribbon_texture: ImageTexture

# Each wire is its own retained canvas item. A pane drag updates only changed
# entries; untouched wires keep their GPU draw commands (including dotted ones).
func begin_wires() -> void:
	_used_entries.clear()

func wire_entry(key: String, signature: Array) -> Node2D:
	if frozen: return self
	_used_entries[key] = true
	if _wire_entries.has(key) and _wire_entries[key].signature == signature: return null
	if not _wire_entries.has(key):
		var layer: Node2D = get_script().new()
		layer.frozen = true
		layer.sheet_coordinates = sheet_coordinates
		layer.unproject = unproject
		add_child(layer)
		_wire_entries[key] = {"layer": layer, "signature": []}
	var entry: Dictionary = _wire_entries[key]
	entry.signature = signature.duplicate(true)
	entry.layer.commands.clear()
	entry.layer.queue_redraw()
	return entry.layer

func end_wires() -> void:
	if frozen: return
	for key in _wire_entries.keys():
		if not _used_entries.has(key):
			_wire_entries[key].layer.queue_free()
			_wire_entries.erase(key)

func project_stems(project: Callable, dim: Callable) -> void:
	if frozen or not project.is_valid(): return
	for key in _wire_entries:
		if not str(key).begins_with("stem:"): continue
		var entry: Dictionary = _wire_entries[key]
		var path: PackedVector2Array = entry.signature[0]
		entry.layer.modulate.a = dim.call(project.call(path[0]), project.call(path[-1]))

func wire_draw_count() -> int:
	var count := 0
	for entry in _wire_entries.values(): count += entry.layer.draw_count
	return count

# Record already-unprojected geometry before a tab changes the live graph.
func still_copy(with_selection := true, with_markers := false) -> Node2D:
	var copy := get_script().new() as Node2D
	copy.unproject = unproject
	copy.frozen = true
	copy.include_selection = with_selection
	copy.sheet_coordinates = sheet_coordinates
	if is_instance_valid(overlay):
		if not markers_only: overlay.draw_established_links(copy)
		if markers_only or with_markers:
			copy.sheet_coordinates = false
			overlay.draw_markers(copy)
	return copy

func _paint(method: StringName, args: Array) -> void:
	if frozen: commands.append([method, args])
	else:
		if method == &"draw_style_box":
			selection_commands.append([method, [args[0].duplicate(), args[1]]])
		callv(method, args)


func _draw() -> void:
	var profiled_started := Time.get_ticks_usec()
	_draw_body()
	preload("res://graffitty/frame_profile.gd").add("GraphWireLayer._draw", Time.get_ticks_usec() - profiled_started)


func _draw_body() -> void:
	draw_count += 1
	if frozen:
		for command in commands: callv(command[0], command[1])
	else:
		selection_commands.clear()
		if is_instance_valid(overlay):
			if markers_only: overlay.draw_markers(self)
			else: overlay.draw_established_links(self)

func point(value: Vector2) -> Vector2:
	return unproject.call(value) if not sheet_coordinates and unproject.is_valid() else value

func points(values: PackedVector2Array) -> PackedVector2Array:
	if sheet_coordinates: return values
	var result := PackedVector2Array()
	for value in values: result.append(point(value))
	return result

func local_width(at: Vector2, width: float) -> float:
	return maxf(0.01, point(at).distance_to(point(at + Vector2(width, 0))))

## Pane decorations already use sheet coordinates; preserve their full shape.
func sheet_style_box(style: StyleBox, rect: Rect2) -> void:
	_paint("draw_style_box", [style.duplicate() if frozen else style, rect])

func polyline(values: PackedVector2Array, color: Color, width := 1.0, antialiased := true) -> void:
	if values.size() < 2: return
	_paint("draw_polyline", [points(values), color, local_width(values[values.size() / 2], width), antialiased])

# One route, with a repeating texture carrying every member's color and style.
# No parallel offset paths or per-member path finding are needed.
func patterned_ribbon(values: PackedVector2Array, styles: Array, width: float, pattern_scale: float) -> void:
	if values.size() < 2 or styles.is_empty(): return
	if _ribbon_styles != styles:
		var image := Image.create(styles.size() * 32, 8, false, Image.FORMAT_RGBA8)
		image.fill(Color.TRANSPARENT)
		for member in styles.size():
			var color: Color = styles[member][0]
			var pattern: String = styles[member][1]
			for x in 32:
				for y in 8:
					var ink := true
					if pattern == "dashed": ink = x % 16 < 10
					if pattern == "dotted": ink = Vector2(x % 8 - 3.5, y - 3.5).length() < 2.5
					if ink: image.set_pixel(member * 32 + x, y, color)
		_ribbon_texture = ImageTexture.create_from_image(image)
		_ribbon_styles = styles.duplicate(true)
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	var path := points(values)
	var total := 0.0
	for i in range(1, values.size()): total += values[i].distance_to(values[i - 1])
	var period := maxf(0.001, minf(total, _ribbon_texture.get_width() * pattern_scale))
	var distance := 0.0
	for i in range(1, path.size()):
		var delta := path[i] - path[i - 1]
		if delta.length_squared() < 0.000001: continue
		var normal := delta.normalized().orthogonal() * local_width(values[i], width) * 0.5
		var start := distance / period
		distance += values[i].distance_to(values[i - 1])
		var end := distance / period
		_paint("draw_polygon", [PackedVector2Array([path[i - 1] + normal, path[i] + normal, path[i] - normal, path[i - 1] - normal]), PackedColorArray([Color.WHITE]), PackedVector2Array([Vector2(start, 0), Vector2(end, 0), Vector2(end, 1), Vector2(start, 1)]), _ribbon_texture])


func multiline(values: PackedVector2Array, color: Color, width := 1.0, antialiased := true) -> void:
	if values.size() < 2 or values.size() % 2 != 0: return
	_paint("draw_multiline", [points(values), color, local_width(values[0], width), antialiased])

func polygon(values: PackedVector2Array, color: Color) -> void:
	if values.size() < 3: return
	var vertices := points(values)
	var origin := vertices[0]
	if not origin.is_finite(): return
	for i in vertices.size():
		if not vertices[i].is_finite(): return
		vertices[i] -= origin
	var double_area := 0.0
	for i in vertices.size():
		double_area += vertices[i].cross(vertices[(i + 1) % vertices.size()])
	if absf(double_area) < 0.000001: return
	# Small pulse rings far from the canvas origin lose triangulation precision.
	# Work near zero; a ring crossing the projection horizon can also collapse,
	# so never submit that degenerate geometry to the canvas renderer.
	if Geometry2D.triangulate_polygon(vertices).is_empty(): return
	_paint("draw_set_transform", [origin])
	_paint("draw_colored_polygon", [vertices, color])
	_paint("draw_set_transform", [Vector2.ZERO])

func line(a: Vector2, b: Vector2, color: Color, width := 1.0, antialiased := true) -> void:
	_paint("draw_line", [point(a), point(b), color, local_width((a + b) * 0.5, width), antialiased])

func circle(at: Vector2, radius: float, color: Color, _filled := true, _width := -1.0, _antialiased := true) -> void:
	# Unproject the circumference as well as the center, preserving screen-space
	# pulse shape under the world's perspective projection.
	var ring := PackedVector2Array()
	for i in 32: ring.append(at + Vector2.from_angle(TAU * i / 32.0) * radius)
	polygon(ring, color)

func arc(at: Vector2, radius: float, start: float, end: float, count: int, color: Color, width := 1.0, antialiased := true) -> void:
	var ring := PackedVector2Array()
	for i in count: ring.append(at + Vector2.from_angle(lerpf(start, end, float(i) / (count - 1))) * radius)
	polyline(ring, color, width, antialiased)


func symbol(at: Vector2, spec: Dictionary, color: Color) -> void:
	var icons := preload("res://scenes/NodeIcon.gd")
	var texture: Texture2D = icons.texture(spec)
	if texture != null:
		_paint("draw_texture_rect", [texture, Rect2(point(at - Vector2(10, 10)), Vector2.ONE * local_width(at, 20)), false])
	else:
		var font: Font = icons.font(spec)
		var size := maxi(1, roundi(local_width(at, 18)))
		var text: String = spec.get("text", "")
		var extent := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		var baseline := point(at) + Vector2(-extent.x * 0.5, (font.get_ascent(size) - font.get_descent(size)) * 0.5)
		_paint("draw_string_outline", [font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 3, Color("14212a")])
		_paint("draw_string", [font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color])
