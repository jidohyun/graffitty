extends "res://tests/terminal_space_smoke.gd"
## Exercise the real 2D renderer: chrome clips foreground, never its background.
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")

func _initialize() -> void:
	Background.install(self)
	super._initialize()

func snapshot(viewport: SubViewport) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()

func region_error(actual: Image, expected: Image, rect: Rect2i) -> float:
	var worst := 0.0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var a := actual.get_pixel(x, y)
			var b := expected.get_pixel(x, y)
			worst = maxf(worst, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), maxf(absf(a.b - b.b), absf(a.a - b.a)))))
	return worst

func run() -> void:
	var host := TestHost.new()
	root.add_child(host)
	await create_timer(0.5).timeout
	check(host.switch_world("flat-2d"), "Flat 2D loads")
	await create_timer(0.5).timeout
	var world: Node = host.world
	world.fx_enabled = false
	world._settle_camera_at_rest()
	world._apply_camera_fx()
	world.set_process(false)
	host.active_terminal().set_process(false)
	var viewport: SubViewport = host.world_viewport
	# A frozen, camera-projected marker makes coverage independent of shell text.
	var marker := Polygon2D.new()
	var logical: Vector2 = world._sheet_size()
	marker.polygon = PackedVector2Array([Vector2.ZERO, Vector2(logical.x, 0), logical, Vector2(0, logical.y)])
	marker.color = Color(0.85, 0.2, 0.4)
	world._foreground_canvas_2d.add_child(marker)
	for opacity in [1.0, 0.35]:
		world.background_2d.modulate.a = opacity
		viewport.transparent_bg = opacity < 1.0
		world.set_workspace_clip_top(0.0)
		var full := await snapshot(viewport)
		world._foreground_clip_2d.hide()
		var background := await snapshot(viewport)
		world._foreground_clip_2d.show()
		for cutoff in [0.025, 0.35]:
			world.set_workspace_clip_top(cutoff)
			var clipped := await snapshot(viewport)
			var width := clipped.get_width()
			var height := clipped.get_height()
			var boundary := floori(height * cutoff)
			var top := Rect2i(0, 0, width, boundary - 1)
			var bottom := Rect2i(0, boundary + 1, width, height - boundary - 1)
			var description := " (opacity %s, cutoff %s)" % [opacity, cutoff]
			check(region_error(full, background, top) > 0.1, "Foreground reaches tab area before clipping" + description)
			check(region_error(clipped, background, top) < 0.001, "Tab area preserves background without foreground" + description)
			check(region_error(clipped, full, bottom) < 0.001, "Content below tabs retains identical pixels" + description)
		world.set_workspace_clip_top(0.0)
		var restored := await snapshot(viewport)
		check(region_error(restored, full, Rect2i(Vector2i.ZERO, full.get_size())) < 0.001, "Hiding tabs restores every foreground pixel (opacity %s)" % opacity)
	for point in [Vector2.ZERO, Vector2(300, 200), Vector2(1100, 600)]:
		check(world.sheet_point_at(world.sheet_window_fraction(point)).distance_to(point) < 0.01, "Clipping preserves 2D input projection")
	world.set_workspace_clip_top(0.0)
	check(world._foreground_clip_2d.position == Vector2.ZERO, "Hiding tabs removes foreground clip")
	check(error_watch.errors.is_empty(), "No engine/script/shader errors: " + str(error_watch.errors))
	print("FLAT_2D_FOREGROUND_CLIP_SMOKE " + JSON.stringify({"failures": failures}))
	host.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
