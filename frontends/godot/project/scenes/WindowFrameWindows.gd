extends Control
## Paint over Godot's opaque surface at the system caption-button positions.
## Input remains non-client Win32 input; this control never consumes a click.
var state := PackedInt32Array()
var _scale := Vector2.ZERO


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_caption_state(value: PackedInt32Array) -> void:
	# Detaching the native frame resizes the window after this control left the tree.
	if not is_inside_tree():
		return
	var scale := get_viewport().get_final_transform().get_scale()
	if state == value and _scale == scale:
		return
	state = value
	_scale = scale
	queue_redraw()


func _draw() -> void:
	if state.size() != 17 or state[12] == 0:
		return
	var scale := get_viewport().get_final_transform().get_scale()
	# DWM supplies client pixels. Paint in those units so DPI rounding and
	# stroke widths match the caption hit rectangles, even with a UI override.
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE / scale)
	var dpi := float(state[12]) / 96.0
	for i in 3:
		var rect := Rect2(
			Vector2(state[i * 4], state[i * 4 + 1]),
			Vector2(state[i * 4 + 2], state[i * 4 + 3]),
		)
		if not rect.has_area():
			continue
		var hovered := state[13] == i
		if hovered:
			var background := Color("c42b1c") if i == 2 else Color(1, 1, 1, 0.10)
			if state[14] != 0:
				background.a = 0.75 if i == 2 else 0.16
			draw_rect(rect, background)
		var color := Color.WHITE if state[16] != 0 or hovered else Color(1, 1, 1, 0.5)
		var side := roundf(10.0 * dpi)
		var thickness := maxf(1.0, roundf(dpi))
		var start := (rect.get_center() - Vector2.ONE * side * 0.5).floor()
		# Center a stroke of odd width halfway into the first pixel.
		var half := Vector2.ONE * (side - thickness) * 0.5
		var center := start + Vector2.ONE * side * 0.5
		if i == 0:
			draw_rect(Rect2(Vector2(start.x, floorf(center.y - thickness * 0.5)), Vector2(side, thickness)), color)
		elif i == 1:
			if state[15] != 0:
				var offset := Vector2.ONE * roundf(2.0 * dpi)
				draw_polyline(
					PackedVector2Array(
						[
							center - half + Vector2(offset.x, 0),
							center + Vector2(half.x, -half.y),
							center + half - Vector2(0, offset.y),
						]
					),
					color,
					thickness,
				)
				draw_rect(
					Rect2(center - half + Vector2(0, offset.y), half * 2 - offset),
					color,
					false,
					thickness,
				)
			else:
				draw_rect(Rect2(center - half, half * 2), color, false, thickness)
		else:
			draw_line(center - half, center + half, color, thickness, true)
			draw_line(
				center + Vector2(half.x, -half.y),
				center + Vector2(-half.x, half.y),
				color,
				thickness,
				true,
			)
