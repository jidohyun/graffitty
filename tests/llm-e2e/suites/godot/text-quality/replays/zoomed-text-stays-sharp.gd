extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/text-quality/zoomed-text-stays-sharp.md


## Adaptive framing is the default zoom mode; this case exercises the fixed
## typing zoom, so select it as `[effects.camera] zoom_mode = "typing"` does.
func use_typing_zoom(zoom: float) -> void:
	var world: Node = host.world
	world.fx_cfg.set_option("scene.camera", "zoom_mode", "typing")
	world.fx_cfg.set_option("state." + str(world.fx_cfg.behavior.active_state), "camera.zoom", zoom)
	world._fx_apply_scene()


## The printed line, just above the cursor's row, in window pixels. Near the
## cursor it is only the few cells beside it, where depth of field is in focus.
func printed_line(near_cursor := false) -> Rect2:
	var world: Node = host.world
	var view: Control = host.workspace_view
	var cell: Vector2 = world.fx_cell_px
	var cursor: Vector2 = world._camera_cursor_uv() * world._sheet_size()
	var left: float = (world._terminal_sheet_origin() + Vector2(world.term.position)).x
	var line := Rect2(Vector2(left, cursor.y - 2.5 * cell.y), Vector2(40.0 * cell.x, 2.0 * cell.y))
	if near_cursor:
		line = Rect2(
			Vector2(maxf(left, cursor.x - 8.0 * cell.x), cursor.y - 2.5 * cell.y),
			Vector2(10.0 * cell.x, 2.0 * cell.y),
		)
	var corners: Array[Vector2] = [
		view.window_point(line.position),
		view.window_point(line.end),
		view.window_point(Vector2(line.position.x, line.end.y)),
		view.window_point(Vector2(line.end.x, line.position.y)),
	]
	var box := Rect2(corners[0], Vector2.ZERO)
	for corner in corners:
		box = box.expand(corner)
	return box.intersection(root.get_visible_rect())


func settled() -> bool:
	return (
		host.world.fx_typing < 0.01
		and absf(host.world.fx_camera.zoom - host.world.fx_camera.target_zoom) < 0.002
	)


func settle() -> void:
	for i in 400:
		if settled():
			break
		await process_frame
	await wait(0.5)


## Measure edge width independently of the world's lighting / typing tint.
## Raw luminance gradients confuse a dimmer sharp glyph with a blurred one.
func sharpness(picture: Image, area: Rect2) -> float:
	var patch := luma(picture, area)
	var values: Array = Array(patch.v)
	if values.size() < 20: return 0.0
	values.sort()
	var contrast: float = values[int(values.size() * .99)] - values[int(values.size() * .5)]
	return edge_steepness(picture, area) / maxf(contrast, .01)


func capture(label: String, near_cursor := false) -> float:
	var picture := await screen_image()
	picture.save_png("res://.cache/e2e-full/text-quality/" + label + ".png")
	return sharpness(picture, printed_line(near_cursor))


func inspect_world(label: String) -> void:
	use_typing_zoom(1.15)
	await say(label + ": print a line and wait for rest")
	host.workspace_view.show_main()
	await type("clear; echo The quick brown fox jumps over 0123456789{enter}")
	await camera_at_rest(20.0)
	var reference := await capture(label + "-rest")
	# Pixel phase and antialiasing change the sampled slope by up to 25%.
	# Verify that the tolerance still rejects enlarged low-resolution glyphs.
	var blurred := await screen_image()
	var original_size := blurred.get_size()
	blurred.resize(maxi(original_size.x / 5, 1), maxi(original_size.y / 5, 1), Image.INTERPOLATE_BILINEAR)
	blurred.resize(original_size.x, original_size.y, Image.INTERPOLATE_BILINEAR)
	check(sharpness(blurred, printed_line()) < reference * .75, label + ": sharpness metric rejects a 5x enlarged low-resolution reference")
	check(reference > 0.1, label + ": the reference has crisp edges (%.2f)" % reference)
	for zoom in [3.0, 5.0]:
		await say(label + ": pinch to %dx over the printed line" % int(zoom))
		await point_at(printed_line().get_center())
		var now: float = host.workspace_view.navigation_zoom
		await pinch(zoom / maxf(now, 0.01), 1.2)
		await hold(1.5)
		check(absf(host.workspace_view.navigation_zoom - zoom) < .001, label + ": actual navigation zoom reaches %dx (%.6f)" % [int(zoom), host.workspace_view.navigation_zoom])
		var zoomed := await capture(label + "-%dx" % int(zoom))
		check(zoomed >= reference * .75, label + ": %dx text edge sharpness %.2f of rest" % [int(zoom), zoomed / maxf(reference, .001)])
	await say(label + ": return to Main Area and engage the typing zoom")
	host.workspace_view.show_main()
	await camera_at_rest(20.0)
	var nearby_reference := await capture(label + "-cursor-rest", true)
	await type("abc")
	await hold(.6)
	var typing := await capture(label + "-typing", true)
	check(host.world.fx_camera.zoom > 1.1, label + ": typing actually engages the camera zoom")
	check(typing >= nearby_reference * .8, label + ": cursor text edge sharpness %.2f of rest" % (typing / maxf(nearby_reference, .001)))
	await type("{backspace}{backspace}{backspace}")
	await camera_at_rest(20.0)


func play() -> void:
	DirAccess.make_dir_recursive_absolute("res://.cache/e2e-full/text-quality")
	await inspect_world("flat")
	if await open_bistro():
		await inspect_world("bistro")
