extends "res://tests/unit/test_case.gd"
const Motion := preload("res://scenes/TabDepthMotion.gd")

func screen_fraction(camera: Transform3D, frustum: Vector4, point: Vector3) -> Vector2:
	var local := camera.affine_inverse() * point
	return (Vector2(local.x, local.y) / -local.z - Vector2(frustum.x, frustum.y)) / Vector2(frustum.z, frustum.w)

func test_cursor_follows_dolly_with_off_axis_camera_pan_tilt_and_zoom() -> void:
	var reference := Transform3D(Basis.from_euler(Vector3(.12, -.3, .05)), Vector3(2, 1, 10))
	var camera := Transform3D(Basis.from_euler(Vector3(-.1, .4, -.08)), Vector3(-3, 2, 8))
	var captured := Vector4(-.7, -.3, 1.1, .8)
	var current := Vector4(-.25, -.6, .8, 1.0)
	for point in [Vector3(-2, 1, -10), Vector3(3, -2, -7)]:
		var world: Vector3 = reference * point
		var before := screen_fraction(reference, captured, world)
		for direction in [-1.0, 1.0]:
			for arriving in [false, true]:
				for progress in [0.0, .25, .5, .75, 1.0]:
					var zoom := Motion.magnification(progress, direction, arriving)
					var transform := Motion.presentation_transform(reference, camera, captured, current, zoom)
					var actual := screen_fraction(camera, current, transform * world)
					var expected := Vector2(.5, .5) + (before - Vector2(.5, .5)) * zoom
					expect(actual.distance_to(expected) < .00001, "Cursor and pane retain the captured screen framing throughout push/pull")

class Grid extends Control:
	var cell_padding := 4
	func get_visible_area() -> Dictionary: return {"grid_origin": Vector2(4, -3)}
	func get_grid_size() -> Vector2i: return Vector2i(80, 24)
	func get_cell_size() -> Vector2: return Vector2(12, 28)

func test_cursor_uses_native_grid_origin_including_fractional_scroll() -> void:
	var terminal := Grid.new()
	terminal.position = Vector2(9, 13)
	var point := preload("res://scenes/TerminalPresentation.gd").grid_point(terminal, Vector2(4.5 / 80, 2.5 / 24))
	expect(point.is_equal_approx(Vector2(67, 80)), "Logical cursor pixels include terminal offset and the native scrolled grid origin")
	terminal.free()

func test_world_menu_replaces_same_target_and_keeps_names_literal() -> void:
	var configured: Array[Dictionary] = [{"label": "View::World::Flat", "action": "SwitchWorld", "path": "flat-3d"}]
	var builtins: Array[Dictionary] = [
		{"label": "View::World::Flat 3D", "action": "SwitchWorld", "path": "flat-3d"},
		{"label": "View::World::Flat 2D", "action": "SwitchWorld", "path": "flat-2d"},
	]
	builtins.append({"label": "View::Test", "action": func(): pass})
	var entries := preload("res://scenes/TerminalHost.gd").merge_menu_entries(configured, builtins)
	expect(entries.size() == 3 and entries[0].label == "View::World::Flat", "A configured world replaces the automatic entry even under a different label")
	for entry in entries.slice(0, 2): expect(entry.literal_label, "Built-in and configured world names are never translated")
