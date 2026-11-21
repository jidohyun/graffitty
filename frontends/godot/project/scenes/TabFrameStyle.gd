extends RefCounted
## Shared Chromium-shaped active-tab opening, including its curved feet.

static func create_material() -> ShaderMaterial:
	var result := ShaderMaterial.new()
	result.shader = preload("res://scenes/tab_frame.gdshader")
	return result

static func update(frame: Control, tabs: Control, color: Color) -> void:
	var material := frame.material as ShaderMaterial
	material.set_shader_parameter("bar_size", frame.size)
	material.set_shader_parameter("frame_color", color)
	var active: Button = tabs.buttons.get(tabs.selected_id)
	var rect := Rect2()
	if is_instance_valid(active) and active.visible and active.modulate.a > 0:
		rect = Rect2(active.global_position - frame.global_position, active.size)
		rect.size.y = frame.size.y - rect.position.y
		# Both adjoining tabs must choose the same backing-pixel boundary.
		if frame.is_inside_tree():
			var transform := frame.get_viewport().get_final_transform() * frame.get_global_transform_with_canvas()
			var pixels := transform * rect
			rect = transform.affine_inverse() * Rect2(preload("res://scenes/ScreenSpace.gd").pixel_bounds(pixels))
	material.set_shader_parameter("active_rect", Vector4(rect.position.x, rect.position.y, rect.size.x, rect.size.y))
	var left: float = tabs.global_position.x - frame.global_position.x
	material.set_shader_parameter("visible_x", Vector2(left - 10, left + tabs.size.x + 10))
	frame.queue_redraw()
