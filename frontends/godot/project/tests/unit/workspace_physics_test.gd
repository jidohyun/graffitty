extends "res://tests/unit/test_case.gd"
const Physics := preload("res://scenes/WorkspacePhysics.gd")
const AREA := Rect2(0, 0, 1200, 800)


func settle(rects: Dictionary, movable: Dictionary) -> Dictionary:
	var simulation := Physics.new()
	for i in 1200:
		rects = simulation.step(rects, movable, AREA, 1.0 / 60)
		if simulation.sleeping:
			break
	expect(simulation.sleeping, "Layout eventually sleeps after contacts settle")
	var sleeping := rects.duplicate()
	for i in 60:
		rects = simulation.step(rects, movable, AREA, 1.0 / 60)
	expect(rects == sleeping, "Settled layouts sleep instead of drifting forever")
	return rects


func test_overlapping_rectangles_separate_without_resizing() -> void:
	var rects := {"a": Rect2(300, 200, 320, 200), "b": Rect2(300, 200, 320, 200), "c": Rect2(300, 200, 320, 200)}
	var result := settle(rects, {"a": false, "b": false, "c": false})
	for key in result:
		expect(result[key].size == rects[key].size, "Physics never resizes terminal grids")
		for other in result:
			if key != other:
				expect(not result[key].intersects(result[other]), "Coincident panes separate: %s %s" % [key, other])


func test_tiled_obstacles_stay_fixed_and_stashes_stay_outside() -> void:
	var fixed := Rect2(0, 0, 1200, 800)
	var result := settle({"tile": fixed, "a": Rect2(1250, 100, 320, 200), "b": Rect2(1250, 100, 320, 200)}, {"a": true, "b": true})
	expect(result.tile == fixed, "Tiled panes never move")
	for key in ["a", "b"]:
		expect(not result[key].intersects(AREA), "Stashed panes remain outside the main area")
	expect(not result.a.intersects(result.b), "Stashes separate along the main area's perimeter")


func test_connections_do_not_attract_and_external_moves_wake_contacts() -> void:
	var simulation := Physics.new()
	var rects := {"terminal": Rect2(50, 200, 200, 200), "chromium": Rect2(950, 200, 200, 200)}
	var movable := {"chromium": false}
	var before := rects.duplicate()
	for i in 60:
		rects = simulation.step(rects, movable, AREA, 1.0 / 60)
	expect(rects == before, "Chromium connections exert no attraction")
	rects.chromium = Rect2(200, 200, 200, 200)
	for i in 300:
		rects = simulation.step(rects, movable, AREA, 1.0 / 60)
	expect(rects.terminal == before.terminal, "The chosen terminal position remains fixed")
	expect(not rects.chromium.intersects(rects.terminal), "Moving a pane wakes its contacts")


func test_overloaded_main_area_preserves_reachable_headers() -> void:
	var rects := {}
	var movable := {}
	for i in 8:
		rects[str(i)] = Rect2(100, 100, 960, 720)
		movable[str(i)] = false
	var result := settle(rects, movable)
	for rect in result.values():
		expect(rect.position.is_finite(), "Crowded layouts stay finite")
		expect(rect.position.y >= AREA.position.y and rect.position.y <= AREA.end.y - 34, "Headers remain vertically reachable")
		expect(rect.end.x >= 80 and rect.position.x <= AREA.end.x - 80, "Headers remain horizontally reachable")


func test_isolated_stash_stays_where_placed() -> void:
	var start := {"a": Rect2(1500, 1500, 320, 200)}
	var result := settle(start, {"a": true})
	expect(result == start, "An isolated stash is never pulled toward the main area")


func test_dragged_obstacle_pushes_neighbours_with_continuous_momentum() -> void:
	var simulation := Physics.new()
	var rects := {"held": Rect2(200, 200, 320, 200), "free": Rect2(470, 200, 320, 200)}
	var start: Vector2 = rects.free.position
	var previous_speed := 0.0
	for i in 30:
		rects.held.position.x += 2.0
		var held: Rect2 = rects.held
		rects = simulation.step(rects, {"free": false}, AREA, 1.0 / 60)
		expect(rects.held == held, "Dragged pane stays exactly under pointer control")
		if i == 0:
			previous_speed = simulation.velocities.free.length()
	expect(rects.free.position.x > start.x + 30, "Neighbours react before the dragged pane is released")
	expect(simulation.velocities.free.length() > previous_speed * 2, "Pointer updates preserve accumulated velocity")


func test_release_has_no_gap_or_motion_cutoff() -> void:
	var simulation := Physics.new()
	var rects := {"held": Rect2(200, 200, 320, 200), "free": Rect2(460, 200, 320, 200)}
	for i in 20:
		rects.held.position.x += 3.0
		rects = simulation.step(rects, {"free": false}, AREA, 1.0 / 60)
	var previous: Vector2 = rects.free.position
	var speed: float = simulation.velocities.free.length()
	var released := {"held": false, "free": false}
	rects = simulation.step(rects, released, AREA, 1.0 / 60)
	expect(rects.free.position.distance_to(previous) > 0.2, "First released frame continues moving")
	expect(simulation.velocities.free.length() > speed * 0.5, "Release preserves neighbour momentum")
	for i in 1200:
		var before := rects.duplicate()
		rects = simulation.step(rects, released, AREA, 1.0 / 60)
		if simulation.sleeping:
			for key in rects:
				expect(rects[key].position.distance_to(before[key].position) * 60 < 0.6, "Sleep only stops imperceptible motion")
			break
	expect(simulation.sleeping, "Release settles without perpetual drift")


func test_contact_chain_propagates_and_leaves_unrelated_panes_alone() -> void:
	var rects := {
		"held": Rect2(100, 200, 200, 200),
		"b": Rect2(270, 200, 200, 200),
		"c": Rect2(460, 200, 200, 200),
		"far": Rect2(2000, 1600, 200, 200),
	}
	var result := settle(rects, {"b": false, "c": false, "far": true})
	expect(result.held == rects.held, "The most recently placed pane stays exactly fixed")
	expect(result.b.position.x > rects.b.position.x, "Direct contact yields")
	expect(result.c.position.x > rects.c.position.x, "Push propagates to the next pane")
	expect(result.far == rects.far, "Disconnected panes stay exactly as placed")
	expect(not result.held.intersects(result.b) and not result.b.intersects(result.c), "Contact chain resolves")


func test_spatial_grid_avoids_all_pairs_and_handles_cell_crossings() -> void:
	var simulation := Physics.new()
	var rects := {}
	var movable := {}
	for i in 128:
		var key := str(i)
		rects[key] = Rect2(i * 1000, 1200, 200, 200)
		movable[key] = true
	var result := simulation.step(rects, movable, AREA, 1.0 / 60)
	expect(result == rects, "Scattered panes stay where placed")
	expect(simulation.pair_checks < 128, "Scattered panes avoid the 8128 all-pairs checks")
	rects["0"] = Rect2(1080, 1200, 200, 200)
	movable.erase("0")
	for i in 300:
		rects = simulation.step(rects, movable, AREA, 1.0 / 60)
	expect(not rects["0"].intersects(rects["1"]), "Moving across grid cells finds the new neighbour")
	rects.erase("1")
	movable.erase("1")
	simulation.step(rects, movable, AREA, 1.0 / 60)
	expect(not simulation.indexed.has("1"), "Closing a pane removes it from the spatial index")


func test_open_space_leaves_room_for_connection_wires() -> void:
	var source := Rect2(100, 100, 320, 200)
	for direction in [Vector2.RIGHT, Vector2.DOWN]:
		var offset := Vector2(300, 0) if direction == Vector2.RIGHT else Vector2(0, 180)
		var result := settle({"source": source, "new": Rect2(source.position + offset, source.size)}, {"new": false})
		var gap: float = result.new.position.x - source.end.x if direction == Vector2.RIGHT else result.new.position.y - source.end.y
		expect(result.source == source, "Source remains a rigid obstacle")
		expect(gap >= 68.0, "Open space leaves about 72px for a connection")
