extends "res://tests/unit/test_case.gd"
## The page bend: drawing and pointer lookup must agree everywhere on the page.
const Sheet := preload("res://scenes/SheetMath.gd")


func random_pane() -> Rect2:
	var size := Vector2(rng.randf_range(0.2, 1.0), rng.randf_range(0.2, 1.0))
	return Rect2(
		Vector2(rng.randf_range(0.0, 1.0 - size.x), rng.randf_range(0.0, 1.0 - size.y)),
		size,
	)


func random_point(pane: Rect2) -> Vector2:
	return pane.position + Vector2(rng.randf(), rng.randf()) * pane.size


func test_the_pointer_finds_what_the_bend_drew() -> void:
	for n in 1000:
		var pane := random_pane()
		var texture := Vector2(rng.randf_range(300, 4000), rng.randf_range(300, 4000))
		var degrees := rng.randf_range(0.0, 30.0)
		var uv := random_point(pane)
		var back := Sheet.saddle_unproject(
			Sheet.saddle_project(uv, pane, texture, degrees),
			pane,
			texture,
			degrees,
		)
		if not expect(
			back.distance_to(uv) < 1e-4,
			"case %d: %s comes back as %s at %.1f degrees" % [n, uv, back, degrees],
		):
			break


func test_no_bend_draws_the_page_as_it_is() -> void:
	for n in 200:
		var pane := random_pane()
		var uv := random_point(pane)
		expect(
			Sheet.saddle_project(uv, pane, Vector2(1600, 1000), 0.0).distance_to(uv) < 1e-6,
			"case %d: a flat page moves %s" % [n, uv],
		)


func test_the_bend_never_pushes_the_page_off_its_frame() -> void:
	for n in 300:
		var pane := random_pane()
		var texture := Vector2(rng.randf_range(300, 4000), rng.randf_range(300, 4000))
		var degrees := rng.randf_range(0.0, 30.0)
		for corner in [
			pane.position,
			pane.end,
			Vector2(pane.position.x, pane.end.y),
			Vector2(pane.end.x, pane.position.y),
		]:
			var drawn := Sheet.saddle_project(corner, pane, texture, degrees)
			expect(
				pane.grow(1e-5).has_point(drawn),
				"case %d: corner %s drawn outside the page at %.1f degrees" % [n, corner, degrees],
			)
