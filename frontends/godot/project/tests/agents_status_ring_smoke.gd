extends "res://tests/mods_fixture.gd"
## Check that the Agents idle ring and done dot are symmetric circles.
## A 7 px ring with a 1.5 px stroke catches uneven whole-pixel rounding.
##
## Run with a real renderer and `--position -32000,-32000`. The test writes
## screenshots for review.

func luminance_grid(image: Image, rect: Rect2i) -> Array:
	var rows := []
	for y in rect.size.y:
		var row := []
		for x in rect.size.x:
			row.append(image.get_pixel(rect.position.x + x, rect.position.y + y).get_luminance())
		rows.append(row)
	return rows

## Largest mirror difference across the vertical and horizontal axes, as a
## share of the brightest pixel; a perfect circle on a pixel grid scores ~0.
func asymmetry(grid: Array) -> float:
	var h := grid.size()
	var w: int = grid[0].size()
	var peak := 0.0
	var worst := 0.0
	for y in h: for x in w: peak = maxf(peak, grid[y][x])
	for y in h:
		for x in w:
			worst = maxf(worst, absf(grid[y][x] - grid[y][w - 1 - x]))
			worst = maxf(worst, absf(grid[y][x] - grid[h - 1 - y][x]))
	return worst / maxf(peak, .001)

func run() -> void:
	setup()
	var now := int(Time.get_unix_time_from_system())
	for index in 3:
		app.agents.rows.append({"id": "test-%d" % index, "key": "%%%d" % index,
			"title": ["Idle agent", "Done agent", "Working agent"][index], "provider": "claude",
			"status": ["idle", "done", "working"][index], "section": ["Idle", "Done", "Working"][index],
			"at": now, "focused": false, "pinned": false, "remote": "", "session": ""})
	app.agents.changed.emit()
	var dialog: Window = PanelWindow.open(host, "agents")
	await settle()
	check(dialog.load_error.is_empty(), "Agents mod loads")
	check(is_instance_valid(dialog._desktop) and dialog._desktop.side == "left", "Docked for an in-viewport capture")
	for i in 6: await process_frame
	var image: Image = root.get_viewport().get_texture().get_image()
	var scale := root.get_viewport().get_screen_transform().get_scale().x
	var view_origin: Vector2 = dialog.view.get_global_rect().position
	var out := OS.get_environment("GFT_CAPTURE_DIR")
	if out.is_empty(): out = OS.get_cache_dir()
	for id in ["status-test-0", "status-test-1"]:
		var local: Rect2 = dialog.view.hit_rect(id)
		check(local.has_area(), id + " is laid out")
		# The glyph is 7 px inside its 3 px side margins; sample a 9 px square around its centre.
		var center := (view_origin + local.get_center()) * scale
		var side := int(9 * scale)
		var rect := Rect2i(Vector2i(center) - Vector2i(side / 2, side / 2), Vector2i(side, side))
		var grid := luminance_grid(image, rect)
		var score := asymmetry(grid)
		check(score < .25, "%s is drawn as a symmetric circle (mirror difference %.2f)" % [id, score])
		var zoom := image.get_region(rect)
		zoom.resize(side * 12, side * 12, Image.INTERPOLATE_NEAREST)
		zoom.save_png(out.path_join(id + "-x12.png"))
	image.get_region(Rect2i(dialog._desktop.get_global_rect()).intersection(Rect2i(Vector2i.ZERO, image.get_size()))).save_png(out.path_join("agents-dock.png"))
	print("AGENTS_STATUS_RING_PASS" if failures.is_empty() else "AGENTS_STATUS_RING_FAIL")
	quit(0 if failures.is_empty() else 1)
