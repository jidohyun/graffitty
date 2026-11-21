extends StyleBox
## A round or pill-shaped control's background: StyleBoxFlat's fill and
## shadow, with the outline drawn as a true anti-aliased curve.
##
## StyleBoxFlat polygonizes a round border and feathers it by a pixel; on a 1
## px translucent outline that left a dashed ring with bright dots where its
## corner arcs meet.
##
## `base` stays live: its border color and width become the outline (its own
## border is never drawn), its expand margins place it, and its changes repaint.

var base: StyleBoxFlat
var _width := 1.0


func _init(fill: StyleBoxFlat = null) -> void:
	base = fill if fill != null else StyleBoxFlat.new()
	_width = float(base.border_width_top)
	_hide_base_border()
	# A method callable, not a lambda capturing self: no reference cycle.
	base.changed.connect(_base_changed)
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		set_content_margin(side, base.get_content_margin(side))


func _base_changed() -> void:
	_hide_base_border()
	emit_changed()


## The outline replaces the fill's border; a later width change moves here.
func _hide_base_border() -> void:
	if base.border_width_top > 0: _width = float(base.border_width_top)
	if base.border_width_top != 0 or base.border_width_left != 0 or base.border_width_right != 0 or base.border_width_bottom != 0:
		base.set_block_signals(true)
		base.set_border_width_all(0)
		base.set_block_signals(false)


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	base.draw(to_canvas_item, rect)
	var color := base.border_color
	if _width <= 0.0 or color.a <= 0.0: return
	var area := rect.grow_individual(base.expand_margin_left, base.expand_margin_top, base.expand_margin_right, base.expand_margin_bottom)
	RenderingServer.canvas_item_add_polyline(to_canvas_item, outline(area, _width), PackedColorArray([color]), _width, true)


## A closed circle or pill inside `area`, centred on a stroke of `width`.
static func outline(area: Rect2, width: float) -> PackedVector2Array:
	var r := minf(area.size.x, area.size.y) / 2.0 - width / 2.0
	var horizontal := area.size.x >= area.size.y
	var first := area.position + Vector2.ONE * (r + width / 2.0)
	var second := (Vector2(area.end.x, first.y) - Vector2(r + width / 2.0, 0)) if horizontal else (Vector2(first.x, area.end.y) - Vector2(0, r + width / 2.0))
	var start := PI / 2.0 if horizontal else PI
	var steps := clampi(int(r * 2.0), 16, 64)
	var points := PackedVector2Array()
	for i in steps + 1:
		points.append(first + Vector2.from_angle(start + PI * i / steps) * r)
	for i in steps + 1:
		points.append(second + Vector2.from_angle(start + PI + PI * i / steps) * r)
	points.append(points[0])
	return points
