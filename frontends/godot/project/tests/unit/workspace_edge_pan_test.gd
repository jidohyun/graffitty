extends "res://tests/unit/test_case.gd"
const View := preload("res://scenes/WorkspaceView.gd")
const VISIBLE := Rect2(0, 40, 800, 600)
const Layout := preload("res://scenes/WorkspaceLayout.gd")


func test_drag_limits_are_the_actual_layout_limits_not_an_overview_fit() -> void:
	var distant := Rect2(-50000, 70000, 480, 300)
	expect(Layout.clamp_window_position(distant) == distant, "Valid placements far beyond the default Overview remain available")
	for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var outside := Rect2(direction * 2_000_000, Vector2(480, 300))
		var limit := Layout.clamp_window_position(outside)
		expect(limit.position == direction * 1_000_000 and limit.size == outside.size, "Only the validated placement boundary limits a drag")
		var farther := Layout.clamp_window_position(Rect2(limit.position + direction * 100, limit.size))
		expect(farther.position - limit.position == Vector2.ZERO, "Outward camera movement stops when the pane cannot follow")
		var inward := Rect2(limit.position - direction * 100, limit.size)
		expect(Layout.clamp_window_position(inward) == inward, "A window at the real boundary can immediately move back inward")


class FittedView extends View:
	func content_rect() -> Rect2: return Rect2(0, 34, 1280, 766)
	func viewport_content_rect() -> Rect2: return VISIBLE


func test_main_outline_depends_on_both_pan_and_zoom() -> void:
	var view := FittedView.new()
	view.size = Vector2(800, 640)
	view.overview = true
	var main := view.main_frame()
	expect(main.zoom != 1.0, "Remote/letterboxed Main uses its actual fitted zoom, not a hardcoded 1")
	for offset in [Vector2.ZERO, Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		for factor in [.99, 1.0, 1.01, 1.5]:
			view.navigation_center = main.center + offset
			view.navigation_zoom = main.zoom * factor
			expect(view.main_boundary_visible() == (offset != Vector2.ZERO or factor != 1.0), "The outline hides only when BOTH pan and zoom match Main")
	view.navigation_center = main.center + Vector2(.0001, 0)
	view.navigation_zoom = main.zoom * (1.0 + .000001)
	expect(not view.main_boundary_visible(), "Floating-point noise does not flicker the outline")
	view.overview = false
	view.navigation_center = Vector2.ZERO
	expect(not view.main_boundary_visible(), "Startup and Main's transient typing effects do not expose a stale navigation frame")
	view.free()


func test_only_a_cursor_inside_the_edge_band_requests_scrolling() -> void:
	for cursor in [VISIBLE.get_center(), Vector2(400, 39), Vector2(-1, 300), Vector2(801, 300), Vector2(400, 641)]:
		expect(View.edge_pan_pressure(cursor, VISIBLE) == Vector2.ZERO, "Interior, chrome, and outside cursors never scroll")
	for sample in [
		[Vector2(1, 300), Vector2.LEFT], [Vector2(799, 300), Vector2.RIGHT],
		[Vector2(400, 41), Vector2.UP], [Vector2(400, 639), Vector2.DOWN],
	]:
		var pressure := View.edge_pan_pressure(sample[0], VISIBLE)
		expect(pressure.normalized() == sample[1], "Each edge scrolls outward")
		expect(pressure.length() > .99, "The cursor at the very edge can reach full speed")


func test_pressure_rises_smoothly_with_cursor_proximity() -> void:
	var previous := 0.0
	for step in 25:
		var distance := View.EDGE_PAN_BAND * (1.0 - step / 24.0)
		var pressure := View.edge_pan_pressure(Vector2(distance, 300), VISIBLE).length()
		expect(pressure >= previous and pressure <= 1.0, "Closer cursors increase speed without exceeding full pressure")
		previous = pressure
	expect(View.edge_pan_pressure(Vector2(View.EDGE_PAN_BAND, 300), VISIBLE) == Vector2.ZERO, "No jump at the band's inner boundary")
	expect(View.edge_pan_pressure(Vector2(View.EDGE_PAN_BAND - .1, 300), VISIBLE).length() < .001, "Entering the band starts almost at rest")
	expect(is_equal_approx(View.edge_pan_pressure(Vector2(View.EDGE_PAN_BAND * .5, 300), VISIBLE).length(), .5), "Halfway in provides a controlled half speed")
	var corner := View.edge_pan_pressure(Vector2(1, 41), VISIBLE)
	expect(corner.x < 0 and corner.y < 0 and is_equal_approx(corner.length(), 1.0), "Diagonal scrolling has the same overall speed cap")


func velocity_at(held: float) -> float:
	var epsilon := .0001
	return (View.edge_pan_travel(held + epsilon) - View.edge_pan_travel(held - epsilon)) / (2.0 * epsilon)


func test_dwell_then_gentle_acceleration_to_a_moderate_cap() -> void:
	expect(View.edge_pan_travel(0) == 0 and View.edge_pan_travel(View.EDGE_PAN_DELAY) == 0, "No movement during the dwell")
	var first_frame := View.edge_pan_travel(View.EDGE_PAN_DELAY + 1.0 / 60.0)
	expect(first_frame > 0 and first_frame < .05, "The first scrolling frame eases in rather than jumping")
	var previous := 0.0
	for step in range(1, 81):
		var speed := velocity_at(View.EDGE_PAN_DELAY + View.EDGE_PAN_RAMP * step / 80.0)
		expect(speed >= previous and speed <= View.EDGE_PAN_MAX_SPEED + .001, "Holding accelerates monotonically without overshoot")
		previous = speed
	expect(is_equal_approx(velocity_at(View.EDGE_PAN_DELAY + View.EDGE_PAN_RAMP * .5), View.EDGE_PAN_MAX_SPEED * .5), "The ramp midpoint has half speed")
	expect(absf(velocity_at(5) - View.EDGE_PAN_MAX_SPEED) < .001, "Long holds stay capped")
	expect(velocity_at(View.EDGE_PAN_DELAY + .01) < 1.0, "Acceleration begins gently")
	expect(View.EDGE_PAN_MAX_SPEED - velocity_at(View.EDGE_PAN_DELAY + View.EDGE_PAN_RAMP - .01) < 1.0, "Acceleration settles gently at the cap")


func test_integrated_travel_is_identical_at_different_frame_rates() -> void:
	var duration := 2.0
	var expected := View.EDGE_PAN_MAX_SPEED * (duration - View.EDGE_PAN_DELAY - View.EDGE_PAN_RAMP * .5)
	for fps in [30, 60, 120, 144]:
		var held := 0.0
		var distance := 0.0
		while held < duration:
			var dt := minf(1.0 / fps, duration - held)
			var step := View.edge_pan_travel(held + dt) - View.edge_pan_travel(held)
			expect(step >= 0 and step <= View.EDGE_PAN_MAX_SPEED * dt + .0001, "Every frame respects the speed cap")
			distance += step
			held += dt
		expect(absf(distance - expected) < .0001, "Frame rate does not change travel or acceleration: %d fps" % fps)
