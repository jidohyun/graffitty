extends "res://tests/unit/test_case.gd"
const Links := preload("res://scenes/WorkspaceChromiumLinks.gd")


func test_multiple_chromiums_follow_their_owner() -> void:
	var links := Links.new()
	var rects := {
		"%1": Rect2(0, 0, 200, 200),
		"%2": Rect2(0, 500, 200, 200),
		"%3": Rect2(300, 0, 200, 100),
		"%4": Rect2(300, 150, 200, 100),
	}
	var owners := {"%3": "%1", "%4": "%1"}
	links.sync(rects, owners)
	expect(links.edges.size() == 2, "One terminal can have two chromium edges")
	for edge in links.edges:
		expect(is_equal_approx(edge[0].x, 200), "Edges start at the owning terminal perimeter")
		expect(is_equal_approx(edge[-1].x, 300), "Edges end at each chromium perimeter")
	var previous: Vector2 = links.edges[0][-1]
	rects["%3"] = Rect2(500, 0, 200, 100)
	links.sync(rects, owners)
	expect(links.edges[0][-1] != previous, "Moving a chromium updates its connector")
	rects.erase("%3")
	links.sync(rects, owners)
	expect(links.edges.size() == 1, "Hiding a chromium removes only its edge")
	rects.erase("%1")
	links.sync(rects, owners)
	expect(links.edges.is_empty(), "Hidden owners leave no dangling edges")
	links.free()


func test_overlap_keeps_connection_and_removed_ownership_clears_it() -> void:
	var links := Links.new()
	var rects := {"t": Rect2(0, 0, 100, 100), "b": Rect2(50, 0, 100, 100)}
	links.sync(rects, {"b": "t"})
	expect(links.edges.size() == 1, "Overlapping panes retain their ownership connection")
	expect(links.edges[0][8].y < 0, "Overlapping panes route the connection above their headers")
	rects.b = Rect2(200, 0, 100, 100)
	links.sync(rects, {"b": "t"})
	expect(links.edges.size() == 1, "Separated panes expose a connector")
	links.sync(rects, {})
	expect(links.edges.is_empty(), "Closing or transferring chromiums clears old ownership")
	links.free()


func test_camera_projection_updates_edges_without_layout_changes() -> void:
	var links := Links.new()
	var rects := {"t": Rect2(0, 0, 100, 100), "b": Rect2(200, 0, 100, 100)}
	links.sync(rects, {"b": "t"})
	var start: Vector2 = links.edges[0][0]
	var end: Vector2 = links.edges[0][-1]
	links.sync(rects, {"b": "t"}, func(p): return p * 3.0 + Vector2(17, -41))
	expect(links.edges[0][0].is_equal_approx(start * 3.0 + Vector2(17, -41)), "Zoom and pan project the terminal endpoint")
	expect(links.edges[0][-1].is_equal_approx(end * 3.0 + Vector2(17, -41)), "Zoom and pan project the chromium endpoint")
	links.free()


func test_typing_zoom_keeps_ownership_route_and_attachment_side() -> void:
	var links := Links.new()
	var resting := {"t": Rect2(0, 0, 200, 100), "b": Rect2(220, 0, 200, 100)}
	links.sync(resting, {"b": "t"}, Callable(), resting)
	var original := links.edges[0].duplicate()
	var previous := original
	for step in range(1, 41):
		var visual := resting.duplicate()
		visual.t = Rect2(-step, -step, 200 + step * 4, 100 + step * 2)
		links.sync(visual, {"b": "t"}, Callable(), resting)
		var edge := links.edges[0]
		expect(edge.size() == original.size(), "Typing overlap cannot turn a direct ownership edge into a detour")
		expect(edge[0].is_equal_approx(Vector2(200 + step * 3, 50)), "Source endpoint follows the same side of the enlarged pane")
		expect(edge[-1].is_equal_approx(original[-1]), "Destination attachment stays fixed")
		for i in edge.size(): expect(edge[i].distance_to(previous[i]) < 4, "Small zoom steps move the entire route smoothly")
		previous = edge.duplicate()
	links.sync(resting, {"b": "t"}, Callable(), resting)
	expect(links.edges[0] == original, "Ending typing restores the resting ownership edge exactly")
	var moved := resting.duplicate()
	moved.b = Rect2(50, 0, 200, 100)
	links.sync(moved, {"b": "t"}, Callable(), moved)
	expect(links.edges[0].size() > original.size(), "Real layout overlap can still select a detour")
	links.free()


func test_camera_zoom_does_not_flip_overlap_route() -> void:
	var links := Links.new()
	links.visible_area = Rect2(0, 0, 400, 400)
	var resting := {"t": Rect2(20, 50, 100, 100), "b": Rect2(70, 50, 100, 100)}
	links.sync(resting, {"b": "t"}, Callable(), resting)
	var original := links.edges[0].duplicate()
	links.sync(resting, {"b": "t"}, func(p): return p * 3 - Vector2(0, 200), resting)
	for i in original.size(): expect(links.edges[0][i].is_equal_approx(original[i] * 3 - Vector2(0, 200)), "Camera zoom only projects the established overlap route")
	links.free()
