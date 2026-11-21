extends "res://tests/unit/test_case.gd"
const Region := preload("res://scenes/WorkspaceRegion.gd")
const Camera := preload("res://scenes/TerminalCameraController.gd")

func test_reserved_geometry_is_shared_by_fit_projection_and_hit_testing() -> void:
	var region := Region.new()
	region.configure(Vector2(1000, 700), Vector4(220, 40, 280, 60))
	expect(region.rect() == Rect2(220, 40, 500, 600), "Docks and chrome are not main content")
	expect(not region.contains(Vector2(100, 300)) and not region.contains(Vector2(900, 300)), "Both docks reject workspace pointer input")
	expect(region.contains(Vector2(400, 300)), "Main content accepts pointer input")
	expect(region.in_projection(Vector2(2000, 1400)) == Rect2(440, 80, 1000, 1200), "Projection uses the same region at HiDPI")
	var content := Rect2(0, 0, 800, 500)
	var fitted := region.fit(content)
	var visible: Rect2 = region.canvas_rect(fitted.center, fitted.zoom)
	expect(visible.grow(.01).encloses(content), "Fit and inverse mapping agree without counting dock area")
	region.configure(Vector2(100, 80), Vector4(220, 100, 280, 60))
	expect(region.rect().size == Vector2.ZERO, "Overlapping reservations never become a full-window fallback")

func test_dock_resize_and_cursor_jumps_are_contained_during_zoom() -> void:
	var region := Region.new()
	var camera := Camera.new()
	var viewport := Vector2(1000, 700)
	var cell := Vector2(10, 20)
	camera.reset(viewport)
	for docks in [Vector4(300, 0, 0, 0), Vector4(0, 350, 0, 0), Vector4(220, 280, 0, 0), Vector4(0, 0, 160, 0), Vector4(220, 280, 160, 0), Vector4(0, 0, 0, 160), Vector4(220, 280, 0, 160)]:
		region.configure(viewport, Vector4(docks.x, 40 + docks.z, docks.y, docks.w))
		camera.visible_rect = region.in_projection(viewport)
		camera.follow_rect = camera.visible_rect
		for cursor in [Vector2(30, 100), Vector2(970, 650)]:
			for zoom in [1.15, 2.0, 3.5]:
				for frame in 30:
					# Resize the occupied band while the camera is still easing.
					var height_delta := 60.0 if frame >= 10 and frame < 20 else 0.0
					region.configure(viewport, Vector4(docks.x, 40 + docks.z + (height_delta if docks.z > 0 else 0), docks.y, docks.w + (height_delta if docks.w > 0 else 0)))
					camera.visible_rect = region.in_projection(viewport)
					camera.follow_rect = camera.visible_rect
					camera.advance(1.0 / 60, cursor, viewport, cell, zoom, 0, 4, 1, true, .8, true)
					var point: Vector2 = viewport * .5 + (cursor - camera.render_pan) * camera.zoom
					var shown := Rect2(point - cell * camera.zoom * .5, cell * camera.zoom)
					expect(region.rect().grow(.01).encloses(shown), "Entire cursor stays outside docks on every animated frame")
	camera.free()
