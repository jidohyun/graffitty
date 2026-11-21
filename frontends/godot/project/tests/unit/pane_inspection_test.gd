extends "res://tests/unit/test_case.gd"
const View := preload("res://scenes/WorkspaceView.gd")


func test_main_view_requires_a_full_aligned_span() -> void:
	var area := Rect2(8, 44, 1184, 748)
	expect(View.spans_main_area(area, area), "Single pane shows Main View")
	expect(View.spans_main_area(Rect2(8, 44, 588, 748), area), "Full-height half shows Main View")
	expect(View.spans_main_area(Rect2(8, 44, 1184, 370), area), "Full-width half shows Main View")
	expect(not View.spans_main_area(Rect2(604, 44, 588, 370), area), "Quarter pane fits individually")
	expect(not View.spans_main_area(Rect2(1400, 44, 588, 748), area), "Stashed full-height pane still fits individually")


func test_remote_main_fits_full_owner_area_into_client_viewport() -> void:
	for client in [Vector2(800, 700), Vector2(1600, 600), Vector2(720, 1280)]:
		var owner := Rect2(0, 34, 1280, 766)
		var visible := Rect2(0, 72, client.x, client.y - 72)
		var target := View.fit_frame(owner, visible, client, 1.0)
		var shown := Rect2((owner.position - target.center) * target.zoom + client * 0.5, owner.size * target.zoom)
		expect(visible.grow(.001).encloses(shown), "Different owner/client aspect ratios keep the entire main area visible")
		expect(shown.get_center().distance_to(visible.get_center()) < .001, "Main area centers below this client's toolbar")
		var coverage := shown.size / visible.size
		expect(absf(maxf(coverage.x, coverage.y) - 1.0) < .001, "Main fit fills one usable viewport dimension at 100 percent")
		var pane := View.fit_frame(Rect2(180, 120, 420, 300), visible, client, .9)
		coverage = Vector2(420, 300) * pane.zoom / visible.size
		expect(absf(maxf(coverage.x, coverage.y) - .9) < .001, "Other panes retain 90 percent fit")


class FittedView extends View:
	func content_rect() -> Rect2: return Rect2(0, 34, 1280, 766)
	func viewport_content_rect() -> Rect2: return Rect2(0, 72, 800, 628)
	## The usable region the fixture declares through viewport_content_rect().
	func workspace_region() -> RefCounted:
		var visible := viewport_content_rect()
		var region := preload("res://scenes/WorkspaceRegion.gd").new()
		region.configure(size, Vector4(visible.position.x, visible.position.y, size.x - visible.end.x, size.y - visible.end.y))
		return region
class NavigationHost extends Node:
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var world: Node
	## Where the window's own chrome ends, in window pixels; the fixtures draw none.
	func workspace_chrome_bottom() -> float: return 0.0
	func is_terminal_pane(_key: String) -> bool: return false
func test_unsaved_tabs_fit_main_but_explicit_navigation_is_preserved() -> void:
	var host := NavigationHost.new()
	host.workspace_layout.ensure_terminal(1)
	host.workspace_layout.ensure_terminal(2)
	host.workspace_layout.tab(2).navigation = {"center":[333,444],"zoom":.4,"overview":true}
	var view := FittedView.new()
	view.host = host
	view.size = Vector2(800, 700)
	view.restore_navigation(1)
	var area := view.content_rect()
	var shown := Rect2((area.position-view.navigation_center)*view.navigation_zoom+view.size*.5,area.size*view.navigation_zoom)
	expect(view.viewport_content_rect().grow(.001).encloses(shown), "Unsaved remote tabs keep the whole owner main area visible")
	expect(absf(shown.size.x - 800) < .001 and shown.get_center().distance_to(Vector2(400,386)) < .001, "New tab fills the available main width and is centered below local chrome")
	view.restore_navigation(2)
	expect(view.navigation_center == Vector2(333,444) and view.navigation_zoom == .4 and view.overview, "Explicit saved navigation remains independent of the default fit")
	view.free();host.free()


class RevealView extends View:
	var destination := {}
	var visible_area := Rect2(0, 34, 1000, 700)
	func content_rect() -> Rect2: return Rect2(0, 34, 1000, 700)
	func viewport_content_rect() -> Rect2: return visible_area
	## The usable region the fixture declares through viewport_content_rect().
	func workspace_region() -> RefCounted:
		var visible := viewport_content_rect()
		var region := preload("res://scenes/WorkspaceRegion.gd").new()
		region.configure(size, Vector4(visible.position.x, visible.position.y, size.x - visible.end.x, size.y - visible.end.y))
		return region
	func canvas_point_at(point: Vector2) -> Vector2:
		return navigation_center + (point - size * .5) / navigation_zoom
	func _animate_inspection(center: Vector2, zoom: float, main: bool) -> void:
		destination = {"center": center, "zoom": zoom, "main": main}
		navigation_center = center
		navigation_zoom = zoom


func reveal_fixture() -> RevealView:
	var view := RevealView.new()
	view.host = NavigationHost.new()
	view.host.workspace_layout.ensure_terminal(1)
	view.size = Vector2(1000, 734)
	view.navigation_center = view.main_frame().center
	view.navigation_zoom = view.main_frame().zoom
	view.pane_rects = {
		"inside": Rect2(8, 42, 400, 350),
		"below": Rect2(8, 850, 400, 350), "above": Rect2(8, -500, 400, 350),
		"right": Rect2(1120, 42, 400, 350), "left": Rect2(-520, 42, 400, 350),
	}
	return view


func test_keyboard_reveal_round_trip_restores_exact_main_frame() -> void:
	for outside in ["below", "above", "right", "left"]:
		var view := reveal_fixture()
		var main := view.main_frame()
		view.reveal_navigation_target(outside)
		expect(view.overview and not view.destination.main, "Outside pane pans away from Main View")
		expect(view.navigation_zoom == main.zoom, "Outbound reveal preserves zoom")
		view.reveal_navigation_target("inside")
		expect(view.destination.main, "Return is Main View, not an offset overview")
		expect(view.destination.center == main.center and view.destination.zoom == main.zoom, "Return uses the exact Main View frame")
		view.host.free(); view.free()


func test_keyboard_reverse_restores_main_even_when_pane_is_already_readable() -> void:
	for outside in ["below", "above", "right", "left"]:
		var view := reveal_fixture()
		var main := view.main_frame()
		view.reveal_navigation_target(outside)
		# Reverse near the start of the flight: the main pane is still readable.
		view.navigation_center = main.center + (view.navigation_center - Vector2(main.center)).normalized() * 10
		view.reveal_navigation_target("inside")
		expect(view.destination.main and view.destination.center == main.center, "A quick reverse from %s does not strand the camera at the interrupted sample" % outside)
		view.host.free(); view.free()


func test_different_zoom_preserves_keyboard_reveal_scale() -> void:
	for outside in ["below", "above", "right", "left"]:
		var view := reveal_fixture()
		view.reveal_navigation_target(outside)
		view._begin_magnetic_navigation()
		view.navigation_zoom = .8
		view.reveal_navigation_target("inside")
		expect(not view.destination.main and view.navigation_zoom == .8, "Manual navigation from %s retains its chosen framing and zoom" % outside)
		view.host.free(); view.free()


func test_same_zoom_manual_pan_fits_main_even_when_pane_is_readable() -> void:
	for offset in [Vector2(10, 0), Vector2(-10, 0), Vector2(0, 10), Vector2(0, -10)]:
		var view := reveal_fixture()
		var main := view.main_frame()
		view.overview = true
		view.navigation_center += offset
		view.reveal_navigation_target("inside")
		expect(view.destination.get("main", false), "Same-zoom focus fits Main View without requiring a previous keyboard excursion")
		expect(view.destination.get("center") == main.center and view.destination.get("zoom") == main.zoom, "Small manual offsets are removed exactly")
		view.host.free(); view.free()


func test_restored_same_zoom_view_fits_main_on_focus() -> void:
	var view := reveal_fixture()
	var main := view.main_frame()
	var tab: int = view.host.workspace_layout.active
	view.host.workspace_layout.tab(tab).navigation = {
		"overview": true, "center": [main.center.x + 20, main.center.y - 30], "zoom": main.zoom,
	}
	view.restore_navigation(tab)
	view.reveal_navigation_target("inside")
	expect(view.destination.get("main", false) and view.destination.get("center") == main.center, "Restored navigation does not need hidden return-to-main history")
	view.host.free(); view.free()


func test_focus_compares_against_fitted_main_zoom_not_one() -> void:
	var view := reveal_fixture()
	view.size = Vector2(800, 600)
	view.visible_area = Rect2(0, 72, 800, 528)
	var main := view.main_frame()
	expect(not is_equal_approx(main.zoom, 1.0), "Owner/client aspect ratio fixture has a non-unit Main View zoom")
	view.overview = true
	view.navigation_center = main.center + Vector2(15, -20)
	view.navigation_zoom = main.zoom * (1.0 + 0.000001)
	view.reveal_navigation_target("inside")
	expect(view.destination.get("main", false), "Floating-point noise still counts as the Main View zoom")
	expect(view.destination.get("center") == main.center and view.destination.get("zoom") == main.zoom, "Remote Main View restores the actual fitted frame")
	view.host.free(); view.free()


func test_visible_panes_at_other_zooms_do_not_fit_main() -> void:
	for zoom in [.8, 1.2]:
		var view := reveal_fixture()
		view.overview = true
		view.navigation_zoom = zoom
		# Fully on screen at either zoom: a clipped pane that fits is centered instead.
		view.navigation_center = view.pane_rects.inside.get_center() + Vector2(20, 10)
		var center := view.navigation_center
		view.reveal_navigation_target("inside")
		expect(view.destination.is_empty() and view.navigation_center == center and view.navigation_zoom == zoom, "A readable pane at a different zoom keeps its deliberate framing")
		view.host.free(); view.free()


func test_partial_outside_pane_is_revealed_without_fitting_main() -> void:
	var view := reveal_fixture()
	view.overview = true
	view.pane_rects["partial"] = Rect2(900, 42, 400, 350)
	view.reveal_navigation_target("partial")
	expect(not view.destination.get("main", true), "A pane crossing the main boundary is not forced into Main View")
	expect(view.navigation_zoom == view.main_frame().zoom, "Outside reveal still preserves zoom")
	view.host.free(); view.free()


func test_already_in_main_does_not_start_another_fit() -> void:
	var view := reveal_fixture()
	view.reveal_navigation_target("inside")
	expect(view.destination.is_empty() and not view.overview, "Focus within Main View does not restart its camera or settle typing effects")
	view.host.free(); view.free()
