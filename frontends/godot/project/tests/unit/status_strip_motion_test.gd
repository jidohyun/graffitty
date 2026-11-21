extends "res://tests/unit/test_case.gd"
const View := preload("res://scenes/WorkspaceView.gd")

func test_usable_location_does_not_snap_back_to_preferred_top() -> void:
	var owner := Rect2(200, 200, 300, 200)
	var prior := Rect2(230, 403, 108, 64)
	for i in 80:
		var jitter := Vector2(sin(i) * 0.0001, cos(i) * 0.0001)
		var moved := Rect2(owner.position + jitter, owner.size)
		var carried := View.carry_status_strip(prior, owner, moved, prior.size)
		var placed := View.place_status_strips([Rect2(moved.position - Vector2(0, 67), prior.size)], Rect2(0, 0, 900, 700), [moved], [], [], [carried])
		expect(placed[0].position.is_equal_approx(carried.position), "A usable bottom position survives subpixel jitter and an available top edge")

func test_stashing_pane_moves_its_strip_without_repositioning_neighbor() -> void:
	var owners: Array[Rect2] = [Rect2(250, 200, 240, 180), Rect2(250, 385, 240, 110)]
	var previous: Array[Rect2] = [Rect2(250, 133, 108, 64), Rect2(250, 498, 108, 84)]
	var bounds := Rect2(0, 0, 1000, 1000)
	for i in 180:
		var next: Array[Rect2] = [owners[0], Rect2(owners[1].position + Vector2(0.2, 1), owners[1].size)]
		var carried: Array[Rect2] = []
		var desired: Array[Rect2] = []
		for j in 2:
			carried.append(View.carry_status_strip(previous[j], owners[j], next[j], previous[j].size))
			desired.append(Rect2(next[j].position - Vector2(0, previous[j].size.y + 3), previous[j].size))
		var placed := View.place_status_strips(desired, bounds, next, [], [], carried)
		expect(placed[0] == previous[0], "Stationary %1 keeps its usable location while %3 is stashed")
		expect(placed[1].position.distance_to(previous[1].position) < 1.1, "%3 follows its owner without jumping edges")
		for j in 2:
			for owner in next: expect(not placed[j].grow(1).intersects(owner), "Moving strips never cross pane content")
		previous = placed
		owners = next

func test_moving_obstacle_pushes_strip_along_same_edge() -> void:
	var owner := Rect2(200, 200, 500, 200)
	var prior := Rect2(220, 133, 108, 64)
	for i in 120:
		var obstacle := Rect2(100 + i * 0.5, 120, 117, 75)
		var placed := View.place_status_strips([Rect2(200, 133, 108, 64)], Rect2(0, 0, 1000, 700), [owner], [owner, obstacle], [], [prior])
		expect(placed[0].position.y == 133, "The strip slides along its current edge")
		expect(placed[0].position.distance_to(prior.position) <= 3.5, "Half-pixel obstacle movement cannot cause a cross-pane jump")
		expect(not placed[0].grow(1).intersects(obstacle), "The retained position yields when an obstacle blocks it")
		prior = placed[0]

func test_new_strip_respects_existing_neighbor_location() -> void:
	var owners: Array[Rect2] = [Rect2(200, 200, 300, 200), Rect2(200, 420, 300, 150)]
	var retained := Rect2(91, 420, 108, 64)
	# The first pane's preferred left candidate would collide with the later strip.
	var placed := View.place_status_strips([Rect2(91, 360, 108, 64), Rect2(200, 353, 108, 64)], Rect2(0, 0, 900, 700), owners, [], [], [Rect2(), retained])
	expect(placed[1] == retained, "A newcomer never evicts another pane's usable strip")
	expect(not placed[0].intersects(placed[1]), "Reservation keeps both strips distinct")

func test_retained_position_yields_to_port_and_viewport_constraints() -> void:
	var owner := Rect2(200, 200, 300, 200)
	var prior := Rect2(200, 133, 108, 64)
	var port := Rect2(215, 155, 14, 14)
	var placed := View.place_status_strips([prior], Rect2(0, 100, 800, 500), [owner], [], [port], [prior])
	expect(placed[0].has_area() and not placed[0].intersects(port), "A newly exposed port makes the prior location unusable")
	var tight := Rect2(190, 200, 400, 300)
	placed = View.place_status_strips([prior], tight, [owner], [], [], [prior])
	expect(placed[0].has_area() and tight.encloses(placed[0]), "Offscreen previous locations relocate into the viewport")

func test_same_edge_preference_never_overrides_clear_port_access() -> void:
	var owner := Rect2(200, 200, 300, 200)
	var prior := Rect2(200, 133, 108, 64)
	# Only one pixel of this port enters the old top position. A tiny overlap
	# must still lose to a completely clear bottom edge.
	var port := Rect2(200, 196, 108, 100)
	var placed := View.place_status_strips([prior], Rect2(200, 100, 108, 400), [owner], [], [port], [prior])
	expect(placed[0] == Rect2(200, 403, 108, 64), "Continuity never outweighs a clear alternative")
