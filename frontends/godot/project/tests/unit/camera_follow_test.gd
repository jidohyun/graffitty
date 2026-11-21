extends "res://tests/unit/test_case.gd"
## The typing camera, as rules over many random terminals: whatever the window,
## cursor, cell, zoom and follow settings, the cursor is on screen and the
## camera gets there in one motion.
const Controller := preload("res://scenes/TerminalCameraController.gd")
const DT := 1.0 / 60.0

func test_mild_zoom_preserves_left_edge_until_cursor_reaches_threshold() -> void:
	var camera := Controller.new()
	camera.configure({"left_preserving_cursor_follow_threshold": 0.7})
	var viewport := Vector2(1600, 1000)
	camera.follow_rect = Rect2(Vector2.ZERO, viewport)
	camera.reset(viewport)
	for frame in 180:
		camera.advance(DT, Vector2(400, 500), viewport, Vector2(10, 20), 1.15, 0, 0, 0, true, 0.8)
		var left := viewport.x * 0.5 - camera.render_pan.x * camera.zoom
		expect(absf(left) < 0.05, "Mild zoom keeps the left edge visible throughout its transition")
	var beyond := camera._follow_target(Vector2(1450, 500), viewport, 1.15, false, Vector2(10, 20))
	expect(beyond.x > viewport.x / (2.0 * 1.15), "Long lines still pan to follow the cursor")
	for rect in [Rect2(0, 0, 800, 1000), Rect2(800, 0, 800, 1000)]:
		camera.follow_rect = rect
		var pan := camera._follow_target(rect.get_center(), viewport, 1.15, false, Vector2(10, 20))
		var left: float = (rect.position.x - pan.x) * 1.15 + viewport.x * 0.5
		var right: float = (rect.end.x - pan.x) * 1.15 + viewport.x * 0.5
		expect(left >= -0.05 and right <= viewport.x + 0.05, "A pane smaller than the camera footprint stays fully visible")
	camera.free()

func test_mild_zoom_preserves_top_over_the_typing_line_anchor() -> void:
	var camera := Controller.new()
	camera.configure({"top_preserving_cursor_follow_threshold": 0.7})
	var viewport := Vector2(1600, 1000)
	camera.follow_rect = Rect2(Vector2.ZERO, viewport)
	camera.reset(viewport)
	for frame in 180:
		camera.advance(DT, Vector2(400, 250), viewport, Vector2(10, 20), 1.15, 0, 0, 0, true, 0.8)
		var top := viewport.y * 0.5 - camera.render_pan.y * camera.zoom
		expect(absf(top) < 0.05, "Typing on an early line keeps the top visible throughout mild zoom")
	var beyond := camera._follow_target(Vector2(400, 950), viewport, 1.15, false, Vector2(10, 20))
	expect(beyond.y > viewport.y / (2.0 * 1.15), "Cursor follow can scroll down after the top-preserving threshold")
	camera.free()


func test_zoom_preserves_pane_title_below_workspace_chrome_until_cursor_needs_scroll() -> void:
	var camera := Controller.new()
	var viewport := Vector2(1600, 1000)
	camera.follow_rect = Rect2(8, 42, 1584, 950)
	camera.follow_top_inset = 44.0
	for zoom in [1.15, 2.5]:
		camera.reset(viewport)
		for frame in 180:
			camera.advance(DT, Vector2(400, 250), viewport, Vector2(10, 20), zoom, 0, 0, 0, true, 0.8)
			var top := (42.0 - camera.render_pan.y) * camera.zoom + viewport.y * 0.5
			expect(top >= 41.99, "The whole pane title stays below workspace chrome throughout zoom")
		var lower := camera._follow_target(Vector2(400, 950), viewport, zoom, false, Vector2(10, 20))
		var cursor_bottom: float = (960.0 - lower.y) * zoom + viewport.y * 0.5
		expect(cursor_bottom <= viewport.y, "A low cursor remains fully visible when the title cannot fit")
		expect((42.0 - lower.y) * zoom + viewport.y * 0.5 < 42.0, "Camera gives up the top only to reveal a low cursor")
	camera.free()


class Case:
	var viewport: Vector2
	var cell: Vector2
	var cursor: Vector2
	var zoom: float
	var tilt_limit: float
	var drift: float


func random_case() -> Case:
	var c := Case.new()
	c.viewport = Vector2(rng.randf_range(400, 3000), rng.randf_range(400, 3000))
	c.cell = Vector2(rng.randf_range(6, 30), rng.randf_range(12, 60))
	c.cursor = Vector2(
		rng.randf_range(c.cell.x, c.viewport.x - c.cell.x),
		rng.randf_range(c.cell.y, c.viewport.y - c.cell.y),
	)
	c.zoom = rng.randf_range(1.0, 4.0)
	c.tilt_limit = deg_to_rad(rng.randf_range(0.0, 30.0))
	c.drift = rng.randf_range(0.0, 40.0)
	return c


func controller(c: Case) -> Controller:
	var camera := Controller.new()
	camera.configure(
		{
			"left_preserving_cursor_follow_threshold": rng.randf(),
			"top_preserving_cursor_follow_threshold": rng.randf(),
			"overscroll": rng.randf(),
		}
	)
	camera.reset(c.viewport)
	return camera


func step(camera: Controller, c: Case, typing := true) -> void:
	camera.advance(
		DT,
		c.cursor,
		c.viewport,
		c.cell,
		c.zoom if typing else 1.0,
		c.tilt_limit if typing else 0.0,
		c.drift,
		2.0,
		typing,
		0.8 if typing else 2.5,
	)


## Where the cursor cell is drawn: its screen rectangle, in window pixels.
func cell_on_screen(camera: Controller, c: Case) -> Rect2:
	var centre := (c.cursor - camera.render_pan) * camera.zoom + c.viewport * 0.5
	return Rect2(centre - c.cell * camera.zoom * 0.5, c.cell * camera.zoom)


func inside(rect: Rect2, c: Case) -> bool:
	return Rect2(Vector2.ZERO, c.viewport).grow(0.5).encloses(rect)


func test_typing_keeps_the_cursor_on_screen() -> void:
	for n in 300:
		var c := random_case()
		var camera := controller(c)
		for frame in 180:
			step(camera, c)
			if not expect(
				inside(cell_on_screen(camera, c), c),
				"case %d frame %d: cursor cell %s leaves a %s window at zoom %.2f"
				% [n, frame, cell_on_screen(camera, c), c.viewport, camera.zoom],
			):
				break
		camera.free()


func test_the_camera_finds_a_cursor_that_jumps() -> void:
	# A new line, a clear, a wrap: the camera glides there and shows it again.
	for n in 200:
		var c := random_case()
		var camera := controller(c)
		for frame in 120:
			step(camera, c)
		c.cursor = Vector2(
			rng.randf_range(c.cell.x, c.viewport.x - c.cell.x),
			rng.randf_range(c.cell.y, c.viewport.y - c.cell.y),
		)
		for frame in 120:
			step(camera, c)
		expect(
			inside(cell_on_screen(camera, c), c),
			"case %d: cursor cell %s not back on a %s screen"
			% [n, cell_on_screen(camera, c), c.viewport],
		)
		camera.free()


func test_zooming_in_is_one_motion() -> void:
	# Every point of the page heads straight for where it ends up: it never
	# turns back, which is what a second, later motion would look like.
	for n in 200:
		var c := random_case()
		c.drift = 0.0
		var camera := controller(c)
		var points: Array[Vector2] = []
		for i in 5:
			points.append(Vector2(rng.randf() * c.viewport.x, rng.randf() * c.viewport.y))
		var paths: Array = points.map(
			func(_p):
				return [],
		)
		for frame in 240:
			step(camera, c)
			for i in points.size():
				paths[i].append((points[i] - camera.render_pan) * camera.zoom + c.viewport * 0.5)
		for i in points.size():
			var path: Array = paths[i]
			var end: Vector2 = path[-1]
			for frame in range(1, path.size()):
				if not expect(
					path[frame].distance_to(end) <= path[frame - 1].distance_to(end) + 0.01,
					"case %d point %d turns back at frame %d" % [n, i, frame],
				):
					break
		camera.free()


func test_the_lean_stays_within_its_limit_and_rests_flat() -> void:
	for n in 200:
		var c := random_case()
		var camera := controller(c)
		for frame in 120:
			step(camera, c)
			expect(
				absf(camera.tilt.x) <= c.tilt_limit + 1e-6
				and absf(camera.tilt.y) <= c.tilt_limit + 1e-6,
				"case %d: lean %s past its %.3f limit" % [n, camera.tilt, c.tilt_limit],
			)
		for frame in 600:
			step(camera, c, false)
		expect(
			camera.tilt.length() < 1e-3 and absf(camera.zoom - 1.0) < 1e-3,
			"case %d: rest keeps lean %s at zoom %.3f" % [n, camera.tilt, camera.zoom],
		)
		camera.free()


func test_later_keys_keep_the_framing_taken_as_typing_began() -> void:
	# Keys arrive mid-zoom; each one re-aiming the camera was a second motion.
	for n in 100:
		var c := random_case()
		var camera := controller(c)
		camera.typed(0.0, 0.0)
		step(camera, c)
		var anchor := camera.cursor_anchor_y
		for frame in 60:
			c.cursor.x = clampf(c.cursor.x + c.cell.x, c.cell.x, c.viewport.x - c.cell.x)
			camera.typed(0.0, 0.0)
			step(camera, c)
		expect(
			is_equal_approx(camera.cursor_anchor_y, anchor),
			"case %d: typing on one line moved the anchor" % n,
		)
		camera.free()


func test_resizing_the_canvas_keeps_idle_framing_centered() -> void:
	var camera = preload("res://scenes/TerminalCameraController.gd").new()
	camera.reset(Vector2(1600,969))
	var viewport := Vector2(560,1074)
	camera.advance(1.0/60.0, Vector2(150,155), viewport, Vector2(9,18), 1.0, 0.0, 0.0, 1.0, false, 2.5, false)
	expect(camera.pan.distance_to(viewport*.5) < .001,"A resized tab must not accumulate a hidden pan during its flight")
	expect(camera.render_pan.distance_to(viewport*.5) < .001,"Displayed idle framing stays at the resized canvas centre")
	camera.free()
