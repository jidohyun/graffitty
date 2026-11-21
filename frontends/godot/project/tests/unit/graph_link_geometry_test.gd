extends "res://tests/unit/test_case.gd"
const Geometry := preload("res://scenes/GraphLinkGeometry.gd")

func test_curve_endpoints_and_degenerate_cases() -> void:
	for end in [Vector2.ZERO, Vector2(10, 0), Vector2(0, 300), Vector2(400, 250), Vector2(-300, 0)]:
		var points := Geometry.curve(Vector2.ZERO, end)
		var lengths := Geometry.distances(points)
		expect(points[0] == Vector2.ZERO and points[-1] == end, "Curve preserves both sockets")
		for i in points.size():
			expect(points[i].is_finite(), "Curve coordinates remain finite")
			if i > 0: expect(lengths[i] >= lengths[i - 1], "Arc distances are monotonic")
		expect(Geometry.at_distance(points, lengths, lengths[-1]).is_equal_approx(end), "Distance sampling reaches the endpoint")
	var backward := Geometry.curve(Vector2.ZERO, Vector2(-300, 0))
	expect(backward[backward.size() / 2].y == 0, "Backward same-row links match Blender without a custom return arc")
	var short_link := Geometry.curve(Vector2.ZERO, Vector2(10, 0))
	for point in short_link: expect(point.x >= 0 and point.x <= 10 and point.y == 0, "Short horizontal links do not overshoot")

func test_distance_sampling_has_constant_speed_through_bends() -> void:
	for end in [Vector2(500, 300), Vector2(-300, 0)]:
		var points := Geometry.curve(Vector2.ZERO, end)
		var lengths := Geometry.distances(points)
		var previous := points[0]
		for distance in range(2, int(lengths[-1]), 2):
			var current := Geometry.at_distance(points, lengths, distance)
			expect(absf(previous.distance_to(current) - 2) < 0.15, "Equal distances produce equal movement around bends")
			previous = current

func test_arrows_follow_forward_and_reverse_tangents() -> void:
	var points := Geometry.controls(Vector2.ZERO, Vector2(0, 300))
	var forward := Geometry.arrow(points)
	var reverse := Geometry.arrow(points, true)
	expect(forward[0].y > forward[1].y, "Vertical forward arrow points down")
	expect(reverse[0].y < reverse[1].y, "Reverse arrow points up")
	expect(Geometry.arrow(Geometry.controls(Vector2.ZERO, Vector2.ZERO)).is_empty(), "Zero-length link has no invalid arrow")

func test_matches_compiled_blender_reference() -> void:
	var reference: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/blender_link_reference.json"))
	for case in reference.cases:
		var expected: Array = case.controls
		var control := Geometry.controls(Vector2(expected[0][0], expected[0][1]), Vector2(expected[3][0], expected[3][1]), int(case.curving))
		for i in 4:
			expect(control[i].distance_to(Vector2(expected[i][0], expected[i][1])) < 0.001, "Handles match compiled Blender")
		for i in 5:
			var sample: Array = case.samples[i]
			var t := i / 4.0
			expect(Geometry.evaluate(control, t).distance_to(Vector2(sample[0], sample[1])) < 0.001, "Curve evaluation matches Blender shader")
			expect(Geometry.tangent(control, t).distance_to(Vector2(sample[2], sample[3])) < 0.0001, "Analytic tangent matches Blender shader")

func test_steep_arrows_follow_visible_wire_and_clear_socket() -> void:
	for end in [Vector2(12, 300), Vector2(12, -300), Vector2(-12, 300)]:
		var control := Geometry.controls(Vector2.ZERO, end)
		for reverse in [false, true]:
			var arrow := Geometry.arrow(control, reverse)
			var socket: Vector2 = Vector2.ZERO if reverse else end
			var direction := (arrow[0] - (arrow[1] + arrow[2]) * 0.5).normalized()
			expect(arrow[0].distance_to(socket) > 8.0, "Arrow does not overlap the socket")
			expect(absf(direction.y) > 0.9, "Steep wire has a steep arrow instead of a horizontal one")
			# Arrow parameter lookup uses uniform samples, unlike adaptive display points.
			var points := PackedVector2Array()
			for i in Geometry.LINK_RESOLUTION:
				points.append(Geometry.evaluate(control, float(i) / (Geometry.LINK_RESOLUTION - 1)))
			var lengths := Geometry.distances(points)
			var t := Geometry.parameter_at_distance(lengths, 10.0 if reverse else lengths[-1] - 10.0)
			var expected := Geometry.tangent(control, t) * (-1 if reverse else 1)
			expect(direction.dot(expected) > 0.999, "Arrow follows the analytic tangent at its displayed position")

func test_display_curve_stays_within_subpixel_error() -> void:
	for end in [Vector2(2000, 1400), Vector2(-1800, 900), Vector2(20, 1800)]:
		var control := Geometry.controls(Vector2.ZERO, end)
		var points := Geometry.curve(Vector2.ZERO, end)
		for i in 1001:
			var exact := Geometry.evaluate(control, i / 1000.0)
			var error := INF
			for j in range(1, points.size()):
				error = minf(error, exact.distance_to(Geometry2D.get_closest_point_to_segment(exact, points[j - 1], points[j])))
			expect(error <= 0.21, "Display curve stays within 0.2 pixels of the exact cubic")
	expect(Geometry.curve(Vector2.ZERO, Vector2(2000, 0)).size() == 2, "Straight wires need only their endpoints")

func test_feedback_route_and_midpoint_direction() -> void:
	var a := Vector2(800, 100)
	var b := Vector2(100, 100)
	var route := Geometry.feedback_curve(a, b)
	var points: PackedVector2Array = route.points
	expect(points[0] == a and points[-1] == b, "Feedback connects its actual output and input")
	expect(points[1].x > a.x and points[-2].x < b.x, "Feedback leaves right and enters from left")
	var arrow := Geometry.path_arrow(points)
	expect(is_equal_approx(arrow[0].y, a.y + 130.0), "Feedback follows n8n source-relative 130px return")
	expect(arrow[0].x < (arrow[1].x + arrow[2].x) * 0.5, "Feedback midpoint arrow points back to the source side")


func test_n8n_same_side_clearance_and_short_span() -> void:
	for span in [10.0, 20.0, 40.0, 80.0, 700.0]:
		var a := Vector2(800, 100)
		var b := Vector2(800 - span, 340)
		var route := Geometry.feedback_curve(a, b)
		var join := Vector2((a.x + b.x) / 2.0, 230)
		expect(join in route.points, "Two n8n segments meet at source Y + 130")
		for point in route.points:
			expect(point.is_finite(), "Close endpoints remain finite")
	var points := Geometry.smooth_step_same_side(Vector2(800, 100), Vector2(450, 230), 1.0)
	expect(Vector2(840, 116) in points and Vector2(840, 214) in points, "40px clearance and 16px quadratic corner endpoints match Vue Flow")

func test_direction_aware_reroute_tangent() -> void:
	var waypoint := Vector2(450, 500)
	var first := Geometry.directed_controls(Vector2(900, 100), waypoint, Vector2.RIGHT, Vector2.LEFT)
	var last := Geometry.directed_controls(waypoint, Vector2(0, 100), Vector2.LEFT, Vector2.RIGHT)
	expect(Geometry.tangent(first, 1.0).is_equal_approx(Vector2.LEFT), "Backward reroute enters leftward")
	expect(Geometry.tangent(last, 0.0).is_equal_approx(Vector2.LEFT), "Backward reroute exits with the same tangent")


func test_input_arrival_follows_source_angle_without_crossing() -> void:
	var target := Vector2(600, 300)
	var upper := Geometry.arrival_controls(Vector2(100, 100), target)
	var lower := Geometry.arrival_controls(Vector2(100, 500), target)
	expect(Geometry.tangent(upper, 1).y > 0.2, "Upper source reaches the top of the input")
	expect(Geometry.tangent(lower, 1).y < -0.2, "Lower source reaches the bottom of the input")
	for i in range(1, 100):
		var t := i / 100.0
		expect(Geometry.evaluate(upper, t).y < target.y and Geometry.evaluate(lower, t).y > target.y, "Opposite arrivals do not cross or merge before the input")
	for x in [40.0, 58.0, 76.0]:
		var route := Geometry.feedback_curve(Vector2(850, 100), target, 650, x, true)
		expect(Geometry.tangent(route.last, 1).y < -0.5, "Return lane connects upward from below")
		expect(route.points[-1] == target, "Input port position is unchanged")
		for point in Geometry.sample_controls(route.last):
			expect(point.x <= target.x and point.y >= target.y, "Arrival stays outside the pane and below the input")
