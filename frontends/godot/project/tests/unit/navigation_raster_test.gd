extends "res://tests/unit/test_case.gd"
const Pane := preload("res://scenes/WorkspacePane.gd")

func test_navigation_keeps_small_pane_crop_stable_at_every_edge() -> void:
	var full := Rect2(0, 0, 700, 470)
	for position in [Vector2(-1592, 0), Vector2(692, 0), Vector2(0, -992), Vector2(0, 462)]:
		var view := Rect2(position, Vector2(1600, 1000))
		expect(Pane.navigation_raster_region(view, full) == full, "Even an eight-pixel visible slice retains the pane's full crop without stretching")
	for position in [Vector2(-1600, 0), Vector2(700, 0), Vector2(0, -1000), Vector2(0, 470)]:
		expect(not Pane.navigation_raster_region(Rect2(position, Vector2(1600, 1000)), full).has_area(), "Entirely offscreen panes still release their rendering resources")

func test_large_pane_uses_a_bounded_sliding_crop() -> void:
	var full := Rect2(0, 0, 10000, 8000)
	var previous := Rect2()
	for position in [Vector2(-1500, -900), Vector2(0, 0), Vector2(4000, 3000), Vector2(9900, 7900), Vector2(0, 0)]:
		var view := Rect2(position, Vector2(1600, 1000))
		var region := Pane.navigation_raster_region(view, full, previous)
		expect(region.size == view.size, "Panning reuses a viewport-sized crop, never the whole huge pane")
		expect(full.encloses(region) and region.encloses(view.intersection(full)), "The sliding crop contains all visible content and stays inside the pane")
		previous = region

func test_navigation_crop_grows_only_when_more_content_is_needed() -> void:
	var full := Rect2(0, 0, 10000, 8000)
	var region := Pane.navigation_raster_region(Rect2(0, 0, 1600, 1000), full)
	region = Pane.navigation_raster_region(Rect2(100, 100, 1632, 1032), full, region)
	expect(region.size == Vector2(1632, 1032), "Zooming out or a larger camera bound can grow the crop")
	region = Pane.navigation_raster_region(Rect2(200, 200, 1600, 1000), full, region)
	expect(region.size == Vector2(1632, 1032), "Small bound fluctuations do not resize an in-flight texture repeatedly")
