extends Control
## What a viewer of a replay needs to see: the pointer, its presses and
## clicks, the keys typed, the step being performed, and each check as it is
## made.
##
## Draws above the whole application and never takes input.

var pointer := Vector2(-100, -100)
var pressed := false
var step := ""
var clock := 0.0
var _ripples: Array[Dictionary] = []
var _keys: Array[Dictionary] = []
var _toasts: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	clock += delta
	size = get_viewport_rect().size
	for list in [_ripples, _keys, _toasts]:
		for i in range(list.size() - 1, -1, -1):
			list[i].age += delta
			if list[i].age > list[i].life:
				list.remove_at(i)
	queue_redraw()


func ripple(at: Vector2) -> void:
	_ripples.append({ "at": at, "age": 0.0, "life": 0.5 })


func key(label: String) -> void:
	_keys.append({ "label": label, "age": 0.0, "life": 1.6 })


func toast(ok: bool, message: String) -> void:
	_toasts.append({ "ok": ok, "message": message, "age": 0.0, "life": 2.5 })


func _panel(rect: Rect2, alpha := 0.72) -> void:
	draw_style_box(_box(Color(0.05, 0.06, 0.08, alpha)), rect)


func _box(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(8)
	return box


func _draw() -> void:
	var font := get_theme_default_font()
	# The step being performed, as the test case words it.
	if not step.is_empty():
		var width := minf(
			size.x - 40,
			font.get_string_size(step, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x + 32,
		)
		var rect := Rect2(Vector2((size.x - width) * 0.5, size.y - 150), Vector2(width, 44))
		_panel(rect)
		draw_string(
			font,
			rect.position + Vector2(16, 30),
			step,
			HORIZONTAL_ALIGNMENT_LEFT,
			width - 32,
			22,
			Color.WHITE,
		)
	# Keys, newest last.
	if not _keys.is_empty():
		var text := " ".join(
			_keys.map(
				func(k):
					return k.label,
			)
		)
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x + 32
		var rect := Rect2(Vector2((size.x - width) * 0.5, size.y - 96), Vector2(width, 48))
		_panel(rect, 0.85)
		draw_string(
			font,
			rect.position + Vector2(16, 34),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			26,
			Color(1, 0.93, 0.6),
		)
	# Checks, top right.
	var y := 60.0
	for toast in _toasts:
		var text := ("✓ " if toast.ok else "✗ ") + String(toast.message)
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x + 24
		var fade := clampf((toast.life - toast.age) / 0.4, 0.0, 1.0)
		draw_style_box(
			_box(
				(
					Color(0.1, 0.45, 0.2, 0.85 * fade)
					if toast.ok
					else Color(0.6, 0.12, 0.12, 0.9 * fade)
				)
			),
			Rect2(Vector2(size.x - width - 16, y), Vector2(width, 32)),
		)
		draw_string(
			font,
			Vector2(size.x - width - 4, y + 22),
			text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			18,
			Color(1, 1, 1, fade),
		)
		y += 38
	# Clicks spread out and fade where they landed.
	for r in _ripples:
		var t: float = r.age / r.life
		draw_arc(r.at, lerpf(10, 34, t), 0, TAU, 40, Color(0.35, 0.7, 1.0, 1.0 - t), 3.0, true)
	# The pointer: a large arrow, filled while the button is down.
	if pressed:
		draw_circle(pointer, 16, Color(0.35, 0.7, 1.0, 0.35))
	var arrow := PackedVector2Array(
		[
			Vector2(0, 0),
			Vector2(0, 26),
			Vector2(7, 20),
			Vector2(12, 31),
			Vector2(17, 29),
			Vector2(12, 18),
			Vector2(20, 18),
		]
	)
	for i in arrow.size():
		arrow[i] = pointer + arrow[i] * 1.2
	draw_colored_polygon(arrow, Color.WHITE)
	draw_polyline(arrow + PackedVector2Array([arrow[0]]), Color.BLACK, 2.0, true)
