extends "res://tests/unit/test_case.gd"
## The camera lean and the typing zoom as geometry, for random lenses and angles.
const Motion := preload("res://scenes/CameraMotion.gd")


## A frame looking down -Z from the origin, with an off-axis lens.
func random_frame() -> Dictionary:
	var width := rng.randf_range(0.2, 1.4)
	var height := width / rng.randf_range(0.4, 2.5)
	var rect := Vector4(
		-width * rng.randf_range(0.2, 0.8),
		-height * rng.randf_range(0.2, 0.8),
		width,
		height,
	)
	return Motion.pose(Vector3.ZERO, Vector3.FORWARD, Vector3.UP, rect)


func random_tilt() -> Vector2:
	return Vector2(deg_to_rad(rng.randf_range(-25, 25)), deg_to_rad(rng.randf_range(-25, 25)))


## Where a world point lands in a frame's lens, and how deep it is.
func seen(frame: Dictionary, point: Vector3) -> Vector3:
	var relative: Vector3 = point - frame.transform.origin
	var depth := relative.dot(-frame.transform.basis.z)
	return Vector3(
		relative.dot(frame.transform.basis.x) / depth,
		relative.dot(frame.transform.basis.y) / depth,
		depth,
	)


func corners(frame: Dictionary, depth: float) -> Array[Vector3]:
	var rect: Vector4 = frame.rect
	var points: Array[Vector3] = []
	for x in [rect.x, rect.x + rect.z]:
		for y in [rect.y, rect.y + rect.w]:
			points.append(Vector3(x * depth, y * depth, -depth))
	return points


func test_a_lean_keeps_the_whole_view_in_frame() -> void:
	for n in 500:
		var frame := random_frame()
		var depth := rng.randf_range(1, 50)
		var leaned := Motion.lean(frame, random_tilt(), depth)
		var rect: Vector4 = leaned.rect
		for corner in corners(frame, depth):
			var at := seen(leaned, corner)
			if not expect(
				at.z > 0 and at.x > rect.x - 1e-4 and at.x < rect.x + rect.z + 1e-4
				and at.y > rect.y - 1e-4 and at.y < rect.y + rect.w + 1e-4,
				"case %d: corner %s leaves the leaned frame" % [n, corner],
			):
				break


func test_the_cursor_side_comes_closer() -> void:
	# A negative horizontal tilt leans toward a cursor on the right, a positive
	# vertical one toward a cursor at the top.
	for n in 500:
		var frame := random_frame()
		var depth := rng.randf_range(1, 50)
		var tilt := random_tilt()
		var leaned := Motion.lean(frame, tilt, depth)
		var rect: Vector4 = frame.rect
		var middle := Vector2(rect.x + rect.z * 0.5, rect.y + rect.w * 0.5)
		var right := seen(leaned, Vector3((rect.x + rect.z) * depth, middle.y * depth, -depth)).z
		var left := seen(leaned, Vector3(rect.x * depth, middle.y * depth, -depth)).z
		var top := seen(leaned, Vector3(middle.x * depth, (rect.y + rect.w) * depth, -depth)).z
		var bottom := seen(leaned, Vector3(middle.x * depth, rect.y * depth, -depth)).z
		if absf(tilt.x) > 0.01:
			expect(
				(right < left) == (tilt.x < 0),
				"case %d: horizontal lean %.3f turns the wrong way" % [n, tilt.x],
			)
		if absf(tilt.y) > 0.01:
			expect(
				(top < bottom) == (tilt.y > 0),
				"case %d: vertical lean %.3f turns the wrong way" % [n, tilt.y],
			)


func test_a_tilt_looks_the_same_through_any_lens() -> void:
	# Through a wider lens the same angle would exaggerate perspective, so the
	# lean is scaled: the near/far depth ratio across the view stays the same.
	for n in 200:
		var tilt := Vector2(deg_to_rad(rng.randf_range(-20, 20)), 0.0)
		var ratios: Array[float] = []
		for width in [0.5, rng.randf_range(0.6, 1.4)]:
			var frame := Motion.pose(
				Vector3.ZERO,
				Vector3.FORWARD,
				Vector3.UP,
				Vector4(-width * 0.5, -width * 0.3, width, width * 0.6),
			)
			var leaned := Motion.lean(frame, tilt, 10.0)
			ratios.append(
				seen(leaned, Vector3(width * 5, 0, -10)).z
				/ seen(leaned, Vector3(-width * 5, 0, -10)).z
			)
		expect(
			absf(ratios[0] / ratios[1] - 1.0) < 0.02,
			"case %d: depth ratio %.4f through the reference lens but %.4f through another"
			% [n, ratios[0], ratios[1]],
		)


func test_telephoto_lean_does_not_orbit_several_sheet_widths() -> void:
	# Imported sprite worlds have 2-5 degree lenses. The same physical orbit as
	# an authored 3D world sweeps several screens of scenery past their narrow view.
	for width in [0.01, 0.02, 0.04, 0.08, 0.15, 0.3, 0.5]:
		var frame := Motion.pose(
			Vector3.ZERO,
			Vector3.FORWARD,
			Vector3.UP,
			Vector4(-width * 0.5, -width * 0.3, width, width * 0.6),
		)
		for tilt in [Vector2(18, 0), Vector2(-18, 0), Vector2(0, 18), Vector2(18, -18)]:
			var depth := 3.0
			var leaned := Motion.lean(frame, tilt * PI / 180.0, depth)
			var orbit: float = leaned.transform.origin.length() / (width * depth)
			expect(
				orbit < 1.0,
				"lens %.3f, tilt %s: camera moves %.2f sheet widths" % [width, tilt, orbit],
			)
			var rect: Vector4 = leaned.rect
			for corner in corners(frame, depth):
				var at := seen(leaned, corner)
				expect(
					at.z > 0 and at.x >= rect.x - 1e-4 and at.x <= rect.x + rect.z + 1e-4
					and at.y >= rect.y - 1e-4 and at.y <= rect.y + rect.w + 1e-4,
					"telephoto lean must retain every sheet corner",
				)


func test_zoom_closes_in_on_the_page_centre() -> void:
	for n in 300:
		var frame := random_frame()
		var depth := rng.randf_range(1, 50)
		var rect: Vector4 = frame.rect
		var centre := Vector3(
			(rect.x + rect.z * 0.5) * depth,
			(rect.y + rect.w * 0.5) * depth,
			-depth,
		)
		var u := Vector3(rect.z * depth, 0, 0)
		var v := Vector3(0, -rect.w * depth, 0)
		var zoom := rng.randf_range(0.25, 6.0)
		var framed := Motion.frame_sheet(frame, zoom, Vector2.ZERO, Vector2.ZERO, centre, u, v)
		var before := seen(frame, centre)
		var after := seen(framed, centre)
		expect(
			after.z > 0 and absf(after.x - before.x) < 1e-4 and absf(after.y - before.y) < 1e-4,
			"case %d: zoom %.2f moves the page centre" % [n, zoom],
		)
		expect(
			is_equal_approx(before.z / after.z, maxf(zoom, 0.25)),
			"case %d: zoom %.2f magnifies %.3fx" % [n, zoom, before.z / after.z],
		)
