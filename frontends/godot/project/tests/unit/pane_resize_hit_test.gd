extends "res://tests/unit/test_case.gd"
const Pane := preload("res://scenes/WorkspacePane.gd")
const View := preload("res://scenes/WorkspaceView.gd")
const Layout := preload("res://scenes/WorkspaceLayout.gd")

class App extends RefCounted:
	var drag := {}

class Backend extends RefCounted:
	var sizes: Array[Rect2] = []
	func resize_pane(_host: Node, _key: String, rect: Rect2) -> void: sizes.append(rect)

class Host extends Node:
	var application := App.new()
	var session_backend := Backend.new()
	var workspace_layout := Layout.new()
	var workspace_view: Control
	var tiling_config := {"gap": 8.0}

class ProjectedView extends View:
	var projection := Vector2.ONE
	func window_point(point: Vector2) -> Vector2: return point * projection
	func content_rect() -> Rect2: return Rect2(0, 0, 1000, 600)
	func refresh() -> void:
		pane_rects.clear()
		Layout.arrange(host.workspace_layout.tab(1).tree, content_rect(), pane_rects)

func fixture() -> ProjectedView:
	var view := ProjectedView.new()
	var host := Host.new()
	host.workspace_view = view
	view.host = host
	host.workspace_layout.add(1, {"windows": [{"pane": "%1"}, {"pane": "%2"}]})
	for index in 2:
		var pane := Pane.new()
		pane.host = host
		pane.key = "%%%d" % (index + 1)
		pane.position = Vector2(100 + index * 430, 100)
		pane.size = Vector2(400, 300)
		view.panes[pane.key] = pane
		view.canvas_root.add_child(pane)
	return view

func test_resizing_across_main_boundary_preserves_geometry_and_membership() -> void:
	for tiling in [false, true]:
		for membership in ["floating", "stashed", "graph_floating"]:
			if tiling and membership == "floating": continue
			for origin in [Vector2(-20, 100), Vector2(620, 100), Vector2(100, -20), Vector2(100, 320)]:
				var view := fixture()
				view.overview = true
				view.navigation_center = Vector2(500, 300)
				view.navigation_zoom = .7
				var tree: Dictionary = view.host.workspace_layout.tab(1).tree
				tree.tiling = tiling
				var item := Layout.find(tree, "%1")
				item.rect = Rect2(origin, Vector2(400, 300))
				if membership != "floating": item[membership] = true
				view.refresh()
				var original := item.duplicate(true)
				var tiles: Dictionary = tree.get("tiles", {}).duplicate(true)
				var neighbor: Rect2 = view.pane_rects["%2"]
				var pane: Control = view.panes["%1"]
				pane._start_rect = original.rect
				for edge in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN, Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2.ONE]:
					pane._resize_edges = edge
					var wanted: Rect2 = pane._resize_rect(edge * 24.0)
					view.set_window_rect("%1", wanted, true)
					expect(view.pane_rects["%1"] == wanted, "Resize never fits a free pane back into Main: %s, tiling=%s, edge=%s" % [membership, tiling, edge])
					expect(item == original.merged({"rect": wanted}, true), "Resizing changes geometry, not stash or graph membership")
					expect(tree.get("tiles", {}) == tiles and view.pane_rects["%2"] == neighbor, "Resizing a free pane never changes the tiled tree or neighbors")
					expect(view.host.session_backend.sizes.back() == wanted, "Terminal sizing receives the exact requested geometry")
					view.set_window_rect("%1", original.rect, true)
					expect(item == original and view.pane_rects["%1"] == original.rect, "Cancellation restores geometry without changing membership")
				expect(view.overview and view.navigation_center == Vector2(500, 300) and view.navigation_zoom == .7, "Resizing never changes navigation")

func test_touch_targets_cover_every_edge_and_corner_without_covering_content() -> void:
	var extent := Vector2(400, 300)
	for zoom in [.25, .5, 1.0, 2.0]:
		var units: Vector2 = Vector2.ONE / zoom
		for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN, Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
			var edge: Vector2 = extent * (Vector2.ONE + direction) * .5
			expect(Pane.touch_resize_edges(edge + direction * 30.0 * units, extent, units) == direction, "All eight grips extend into empty canvas at constant screen size")
			expect(Pane.touch_resize_edges(edge + direction * 37.0 * units, extent, units) == Vector2.ZERO, "The expanded target has a bounded outer edge")
			expect(Pane.touch_resize_edges(edge - direction * 5.0 * units, extent, units) == direction, "The thin inside border is still grabbable")
		for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			var edge: Vector2 = extent * (Vector2.ONE + direction) * .5
			expect(Pane.touch_resize_edges(edge - direction * 9.0 * units, extent, units) == Vector2.ZERO, "Beyond the inside border, touches still belong to content")
		expect(Pane.touch_resize_edges(extent * .5, extent, units) == Vector2.ZERO, "Pane center stays interactive at every zoom")
	var tiny := Vector2(30, 20)
	expect(Pane.touch_resize_edges(tiny * .5, tiny, Vector2.ONE) == Vector2.ZERO, "Targets never swallow the entire interior of a tiny pane")

func test_real_pane_hit_testing_uses_projected_screen_size_and_preserves_mouse_grips() -> void:
	var view := fixture()
	var pane: Control = view.panes["%1"]
	for projection in [Vector2(.25, .5), Vector2(.5, .5), Vector2.ONE, Vector2(2, 1.5)]:
		view.projection = projection
		pane.scale = Vector2(1.2, .8)
		for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
			var local: Vector2 = pane.size * (Vector2.ONE + direction) * .5 + direction * 30.0 / (projection * pane.scale)
			expect(pane._edge_at(local, true) == direction, "Camera and pane scaling leave the finger grip unchanged")
			expect(pane._edge_at(local) == Vector2.ZERO, "Mouse hits do not acquire the touch-only exterior zone")
		expect(pane._edge_at(Vector2(3, 100)) == Vector2.LEFT, "Existing mouse edge width is preserved")
		expect(pane._edge_at(pane.size - Vector2(10, 10)) == Vector2.ONE, "Existing mouse corner grip is preserved")

func test_exterior_targets_choose_nearest_edge_without_stealing_other_panes_content() -> void:
	var view := fixture()
	expect(view.resize_window_at(Vector2(510, 250), true) == "%1", "Closest edge wins in the gap, even when the other pane is in front")
	expect(view.resize_window_at(Vector2(520, 250), true) == "%2", "The opposite side of the gap picks the opposite pane")
	expect(view.resize_window_at(Vector2(510, 250)).is_empty(), "Mouse background is not a touch target")
	var front: Control = view.panes["%2"]
	front.position.x = 500
	expect(view.resize_window_at(Vector2(525, 250), true).is_empty(), "Expanded borders cannot steal a neighboring pane's content")
	front.position.x = 450
	expect(view.resize_window_at(Vector2(495, 250), true).is_empty(), "An obscured resize edge cannot grab through a front pane")
	front.hide()
	expect(view.resize_window_at(Vector2(495, 250), true) == "%1", "Hidden panes cannot block a visible resize edge")
	expect(view.resize_window_at(Vector2(1000, 800), true).is_empty(), "Distant background remains workspace navigation")

func test_touch_tile_dividers_are_screen_sized_without_detaching_tiles() -> void:
	var view := fixture()
	var tree: Dictionary = view.host.workspace_layout.tab(1).tree
	tree.tiling = true
	tree.tiles = {"axis": "h", "children": [{"pane": "%1"}, {"pane": "%2"}]}
	var divider: Dictionary = Layout.tile_dividers(tree.tiles, view.content_rect(), [], 8.0)[0]
	for zoom in [.25, .5, 1.0, 2.0]:
		view.projection = Vector2.ONE * zoom
		var middle: Vector2 = divider.rect.get_center()
		for side in [-1, 1]:
			expect(view.dividers_at(middle + Vector2(side * 20.0 / zoom, 0), true).size() == 1, "Both sides of a tiled divider have a finger-sized target at every zoom")
			expect(view.dividers_at(middle + Vector2(side * 24.0 / zoom, 0), true).is_empty(), "Divider targets remain bounded and do not grow with zoom")
		expect(view.panes["%1"]._edge_at(Vector2(-10, 100), true) == Vector2.ZERO, "Tiled panes cannot be resized as floating windows")
	view.projection = Vector2.ONE
	expect(view.dividers_at(divider.rect.get_center() + Vector2(20, 0)).is_empty(), "Mouse divider hitboxes remain unchanged")
