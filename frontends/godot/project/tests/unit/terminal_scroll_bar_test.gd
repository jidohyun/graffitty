extends "res://tests/unit/test_case.gd"
const Bar := preload("res://scenes/TerminalScrollBar.gd")


func test_painted_thumb_matches_native_hit_geometry() -> void:
	var bar: VScrollBar = Bar.new()
	bar._ready()
	bar.max_value = 100
	bar.page = 25
	bar.value = 50
	bar.size = Vector2(bar.get_combined_minimum_size().x, 300)
	expect(is_equal_approx(bar.get_combined_minimum_size().x, Bar.WIDTH), "The bar reserves its painted width")
	var span: Vector2 = bar._thumb_span()
	expect(span.y >= Bar.MIN_THUMB and span.x > 0.0 and span.x + span.y < bar.size.y, "Thumb sits inside the track")
	expect(bar._track_direction(Vector2(6, span.x - 1)) == -1 and bar._track_direction(Vector2(6, span.x + span.y * .5)) == 0 and bar._track_direction(Vector2(6, span.x + span.y + 1)) == 1, "Track paging uses the painted thumb")
	bar._sync_skin()
	expect(bar._material.get_shader_parameter("thumb") == span, "Shader receives thumb geometry")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(6, span.x + span.y * .5)
	bar._gui_input(press)
	expect(bar._material.get_shader_parameter("pressed") == 1.0, "Grabbing the thumb lights it")
	expect(bar._material.get_shader_parameter("hover") == 1.0, "Out of the tree, the thumb widens at once")
	press.pressed = false
	bar._gui_input(press)
	expect(bar._material.get_shader_parameter("pressed") == 0.0, "Releasing the thumb restores it")
	bar.free()
