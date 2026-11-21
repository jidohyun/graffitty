extends "res://tests/unit/test_case.gd"
const Zoom := preload("res://scenes/TypingPaneZoom.gd")
const View := preload("res://scenes/WorkspaceView.gd")
const Config := preload("res://graffitty/terminal_config.gd")
const Effects := preload("res://scenes/Effects.gd")
const Physics := preload("res://scenes/WorkspacePhysics.gd")
const AREA := Rect2(8, 44, 1200, 800)


func test_tiled_corners_grow_inward_and_keep_every_edge_visible() -> void:
	for corner in [Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN, Vector2.ONE]:
		var rect := Rect2(AREA.position + (AREA.size - Vector2(400, 300)) * corner, Vector2(400, 300))
		var visual := Zoom.geometry(rect, 1.1, AREA)
		expect(visual.size.is_equal_approx(rect.size * 1.1), "Corner pane grows by ten percent")
		expect(AREA.grow(0.001).encloses(visual), "Enlarged pane stays inside all view edges")
		var anchor: Vector2 = rect.position + rect.size * corner
		expect((visual.position + visual.size * corner).is_equal_approx(anchor), "Touching corner stays fixed")
	expect(Zoom.geometry(AREA, 1.1, AREA) == AREA, "A single full-view pane stays fitted")


func test_three_pane_layout_keeps_zoom_on_the_full_height_left_pane() -> void:
	for side in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
		var vertical: bool = side.x != 0
		var extent := Vector2(600, 800) if vertical else Vector2(1200, 400)
		var rect := Rect2(AREA.position + (AREA.size - extent) * (side + Vector2.ONE) / 2, extent)
		var visual := Zoom.geometry(rect, 1.1, AREA)
		expect(visual.size.is_equal_approx(rect.size * 1.1), "Spanning one axis cannot disable uniform typing zoom")
		if vertical:
			expect(is_equal_approx(visual.get_center().y, rect.get_center().y), "Three-edge vertical pane grows equally above and below")
			expect(is_equal_approx(visual.position.x if side.x < 0 else visual.end.x, AREA.position.x if side.x < 0 else AREA.end.x), "Only the left or right outer edge stays fixed")
		else:
			expect(is_equal_approx(visual.get_center().x, rect.get_center().x), "Three-edge horizontal pane grows equally left and right")
			expect(is_equal_approx(visual.position.y if side.y < 0 else visual.end.y, AREA.position.y if side.y < 0 else AREA.end.y), "Only the top or bottom outer edge stays fixed")
		var pane := Control.new()
		pane.position = rect.position
		pane.size = rect.size
		Zoom.apply(pane, rect, 1.1, AREA)
		expect(pane.scale.is_equal_approx(Vector2(1.1, 1.1)), "Full-height pane receives the same visible scale as its neighbours")
		pane.free()


func test_interior_and_floating_panes_grow_about_the_center() -> void:
	for bounds in [Rect2(), AREA]:
		var rect := Rect2(300, 250, 400, 300)
		var visual := Zoom.geometry(rect, 1.1, bounds)
		expect(visual.get_center().is_equal_approx(rect.get_center()), "Room on every side preserves the center")
		expect(visual.size.is_equal_approx(Vector2(440, 330)), "Reading scale is uniform")
	var outside := Rect2(1800, 1200, 400, 300)
	expect(Zoom.geometry(outside, 1.1).get_center().is_equal_approx(outside.get_center()), "Stashes grow at their actual position")


func test_target_weight_names_where_each_pane_is_heading() -> void:
	var zoom := Zoom.new()
	zoom.pulse("a", 1.2)
	expect(zoom.target_weight("a", "a") == 1.0, "The typed, focused pane heads to full magnification")
	expect(zoom.target_weight("a", "b") == 0.0, "Losing focus heads back to rest")
	expect(zoom.target_weight("b", "b") == 0.0, "Other panes head back to rest")
	for i in 90: zoom.advance(1.0 / 60.0, "a", 0.5, 1.5)
	expect(zoom.target_weight("a", "a") == 0.0, "Idle heads back to rest")


func test_typing_handoff_and_idle_restore_without_jumps() -> void:
	var zoom := Zoom.new()
	zoom.pulse("a", 1.2)
	expect(zoom.weights.a == 0.0, "Keystroke starts the animation without jumping")
	for i in 30: zoom.advance(1.0 / 60.0, "a", 0.5, 1.5)
	expect(zoom.weights.a > 0.99, "Typing reaches the reading size")
	var previous: float = zoom.weights.a
	zoom.pulse("b", 1.2)
	expect(zoom.weights.a == previous and zoom.weights.b == 0.0, "Switching typing panes does not snap either pane")
	zoom.advance(1.0 / 60.0, "b", 0.5, 1.5)
	expect(zoom.weights.a < previous and zoom.weights.b > 0.0, "Previous pane shrinks while the new one grows")
	for i in 240: zoom.advance(1.0 / 60.0, "b", 0.5, 1.5)
	expect(zoom.weights.is_empty(), "Idle returns exactly to normal and stops animation work")


func test_focus_loss_permanently_cancels_the_trigger_without_snapping() -> void:
	var zoom := Zoom.new()
	zoom.pulse("a", 10.0)
	zoom.advance(.2, "a", .2, .8)
	var previous: float = zoom.weights.a
	zoom.cancel()
	expect(zoom.weights.a == previous, "Focus loss preserves the displayed weight")
	# Even returning before the next animation frame cannot re-arm the timer.
	for i in 120:
		zoom.advance(1.0 / 60.0, "a", .2, .8)
		var current: float = zoom.weights.get("a", 0.0)
		expect(current <= previous, "Cancelled zoom only shrinks after returning")
		previous = current
	expect(zoom.weights.is_empty(), "The leave animation reaches exact identity")
	zoom.pulse("a", 10.0)
	zoom.advance(.2, "a", .2, .8)
	expect(zoom.weights.a > .9, "New typing can activate the effect again")
	zoom.advance(.01, "b", .2, .8)
	previous = zoom.weights.a
	zoom.advance(.01, "a", .2, .8)
	expect(zoom.weights.a < previous, "An observed focus change also clears the trigger")


class Pane extends Control:
	var key := ""
	func _resize_terminal_preview() -> void: pass


func test_visual_overlap_does_not_push_panes_and_picking_matches_topmost_pane() -> void:
	var view := View.new()
	var rects := {"a": Rect2(100, 100, 400, 300), "b": Rect2(504, 100, 400, 300)}
	for key in rects:
		var pane := Pane.new()
		pane.key = key
		pane.position = rects[key].position
		pane.size = rects[key].size
		view.canvas_root.add_child(pane)
		view.panes[key] = pane
	view.pane_rects.assign(rects)
	var pane: Control = view.panes.a
	Zoom.apply(pane, rects.a, 1.1)
	view.raise_window("a")
	expect(pane.position == rects.a.position and pane.size == rects.a.size, "Presentation preserves layout position and terminal dimensions")
	expect(view.panes.b.scale == Vector2.ONE, "Other panes keep their size")
	expect(pane.get_index() == view.canvas_root.get_child_count() - 1, "Typing pane draws last and receives input first")
	expect(view.window_at(Vector2(510, 200)) == "a", "Expanded overlap picks the typing pane")
	expect(view.window_at(Vector2(525, 200)) == "b", "Uncovered neighbor remains clickable")
	var simulation := Physics.new()
	var baseline := Physics.new()
	var next := rects.duplicate()
	var unzoomed := rects.duplicate()
	for i in 120:
		next = simulation.step(next, {"a": false, "b": false}, AREA, 1.0 / 60.0)
		unzoomed = baseline.step(unzoomed, {"a": false, "b": false}, AREA, 1.0 / 60.0)
	expect(next == unzoomed and view.pane_rects == rects, "Visual overlap adds no physics force or layout mutation")
	Zoom.apply(pane, rects.a, 1.0)
	expect(pane.scale == Vector2.ONE and pane.pivot_offset == Vector2.ZERO, "Restores exact identity transform")
	expect(view.window_at(Vector2(510, 200)) == "b", "Picking restores with the pane")
	view.canvas_root.free()
	view.free()


func test_zoom_preference_round_trip_copy_validation_and_camera_independence() -> void:
	var config := Config.new()
	config.effects.typing_pane_zoom.scale = 1.15
	var copy: RefCounted = config.copy()
	copy.effects.typing_pane_zoom.scale = 1.25
	expect(config.effects.typing_pane_zoom.scale == 1.15, "World copies do not mutate the user's setting")
	var restored := Config.new()
	restored.overlay(config.to_config())
	expect(restored.effects.typing_pane_zoom.scale == 1.15, "Conf serialization preserves the pane zoom preference")
	var effects := Effects.new()
	config.apply_effects(effects)
	expect(is_equal_approx(effects.typing_settings().pane_zoom, 1.15), "Typed preference reaches the visual effect")
	expect(effects.frame("typing")["camera.zoom"] == 1.0, "Pane zoom never enables camera zoom")
	config.effects.typing_pane_zoom.scale = 1.0
	expect(config.validate().is_empty(), "Identity scale disables pane zoom")
	config.effects.typing_pane_zoom.scale = NAN
	expect(not config.validate().is_empty(), "Nonfinite zoom is rejected")


class MarkerHost extends Node:
	var world: Node


func test_blue_selection_glow_scales_with_the_pane() -> void:
	var view := View.new()
	var host := MarkerHost.new()
	view.host = host
	var pane := Pane.new()
	pane.position = Vector2(300, 200)
	pane.size = Vector2(400, 300)
	view.panes = {"a": pane}
	view.pane_rects = {"a": Rect2(pane.position, pane.size)}
	var overlay := preload("res://scenes/AgentGraphOverlay.gd").new()
	var tools: Node = overlay.tools
	tools.view = view
	tools.overlay = overlay
	tools.selected = {"a": true}
	overlay.editing = true
	var painter := preload("res://scenes/GraphWireLayer.gd").new()
	painter.frozen = true
	Zoom.apply(pane, view.pane_rects.a, 1.1)
	tools.draw_selection(painter)
	var visual := pane.get_transform() * Rect2(Vector2.ZERO, pane.size)
	expect(painter.commands[0][1][1].is_equal_approx(visual), "Blue marker matches the enlarged bounds rather than collision bounds")
	expect(painter.commands[0][1][0].shadow_size == 10, "Blue blur grows with the pane")
	expect(painter.commands[0][1][0].corner_radius_top_left == 13, "Marker corners grow with pane corners")
	painter.free()
	pane.free()
	overlay.free()
	view.free()
	host.free()
