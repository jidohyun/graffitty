extends "res://tests/unit/test_case.gd"
const Scale := preload("res://scenes/WindowScale.gd")


func test_logical_scale_by_backend() -> void:
	expect(Scale.auto_scale("Windows", 1.0, 144) == 1.5, "Windows uses effective monitor DPI")
	expect(Scale.auto_scale("Wayland", 1.25, 192) == 1.25, "Wayland keeps the compositor's fraction")
	expect(Scale.auto_scale("macOS", 2.0, 192) == 2.0, "Retina applies the backing scale once")
	expect(Scale.auto_scale("X11", 2.0, 72) == 2.0, "X11 ignores physical DPI")
	expect(Scale.auto_scale("Android", 1.0, 320) == 2.0, "Android uses density-independent pixels")


func test_secondary_wayland_surface_moves_between_outputs() -> void:
	var points := Vector2i(793, 631)
	var backing := Vector2i((Vector2(points) * 1.25).round())
	expect(is_equal_approx(Scale.wayland_surface_scale(1.0, points, backing), 1.25), "A second surface receives 125% independently")
	expect(is_equal_approx(Scale.wayland_surface_scale(1.25, backing, points * 2), 2.0), "Move to a 200% output")
	expect(is_equal_approx(Scale.wayland_surface_scale(2.0, points * 2, backing), 1.25), "Move back to 125%")


func test_shared_tab_and_caption_boundaries_at_fractional_dpi() -> void:
	for scale: float in [1.25, 1.5, 1.75]:
		var origin := Vector2(-1920, -90) + Vector2(7, 3) * scale
		var size := Vector2(37, 42) * scale
		var left := preload("res://scenes/ScreenSpace.gd").pixel_bounds(Rect2(origin, size))
		var right := preload("res://scenes/ScreenSpace.gd").pixel_bounds(Rect2(origin + Vector2(size.x, 0), size))
		expect(left.end.x == right.position.x, "Neighboring tabs share one backing-pixel boundary")
		expect(not left.has_point(right.position) and right.has_point(right.position), "Exactly one hit region owns the shared pixel")
