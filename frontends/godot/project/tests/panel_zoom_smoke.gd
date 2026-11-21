extends "res://tests/mods_fixture.gd"
## Panel magnification: the font-size steps scale one whole panel (content,
## title row, compact threshold, a bar's row), and the dock layout remembers it.

func run() -> void:
	setup(false)
	space.state_path = OS.get_cache_dir().path_join("gft-panel-zoom-test-%d.json" % OS.get_process_id())
	DirAccess.remove_absolute(space.state_path)
	var bar: Window = PanelWindow.open(host, "status-line")
	var list: Window = PanelWindow.open(host, "sessions")
	await settle()
	check(list.load_error.is_empty() and list.view.last_error().is_empty(), "Sessions mod loads: " + list.view.last_error())
	var dock: Control = list._desktop
	if dock.side.is_empty():
		space.commit(dock, space.plan(dock, Vector2(4, 300), "left"))
		await settle()
	space.widths.left = 300.0
	space.reflow()
	await settle()
	check(dock.side == "left" and not list.compact, "Sessions is docked wide on the left: %s %s" % [dock.side, dock.size])
	# A row, not the list that fills the panel at any magnification.
	var key := ""
	for candidate in list.view.hit_keys():
		var bounds: Rect2 = list.view.hit_rect(candidate)
		if bounds.size.y > 4 and bounds.size.y < 60: key = candidate
	var natural: Rect2 = list.view.hit_rect(key)
	check(not key.is_empty(), "The list has a row to measure: %s" % [list.view.hit_keys()])
	var title_height: float = dock._header.custom_minimum_size.y
	var logical_width: int = list._props().width
	for step in 5: list.zoom_step(1)
	await settle()
	check(is_equal_approx(list.panel_scale, 1.5) and is_equal_approx(list.view.get_zoom(), 1.5), "Five steps up reach 150%%: %s" % list.panel_scale)
	var zoomed: Rect2 = list.view.hit_rect(key)
	check(zoomed.size.y > natural.size.y * 1.4 and zoomed.size.y < natural.size.y * 1.6, "Content draws 1.5 times larger: %s -> %s" % [natural, zoomed])
	check(is_equal_approx(dock._header.custom_minimum_size.y, roundf(title_height * 1.5)), "The title row scales with the content")
	check(is_equal_approx(dock.size.x, 300.0) or dock.size.x <= 300.0, "The dock keeps its width in the window: %s" % dock.size.x)
	check(list._props().width < logical_width, "The mod is told a narrower logical width: %s -> %s" % [logical_width, list._props().width])
	check(not list.compact, "200 logical units still show the full list")
	# 100 px is full size at 100% (>= 80) and compact at 150% (66 logical units).
	space.widths.left = 100.0
	space.reflow()
	await settle()
	check(list.compact, "The compact threshold follows the magnification")
	space.toggle_fold("left")
	await settle()
	check(is_equal_approx(space.widths.left, 300.0) and not list.compact, "Unfolding a compact column restores its expanded width")
	space.toggle_fold("left")
	await settle()
	check(is_equal_approx(space.widths.left, space.COLLAPSED_WIDTH * 1.5), "The collapsed rail is as wide as the magnified panel needs: %s" % space.widths.left)
	list.zoom_step(-1)
	await settle()
	check(is_equal_approx(space.widths.left, space.COLLAPSED_WIDTH * 1.4), "A collapsed rail follows the magnification: %s" % space.widths.left)
	space.widths.left = 100.0
	space.reflow()
	list.zoom_step(0)
	await settle()
	check(is_equal_approx(list.panel_scale, 1.0) and not list.compact, "Reset returns to the natural size, wide enough again at 100 px")
	var bar_dock: Control = bar._desktop
	var bar_height: float = bar_dock.size.y
	for step in 5: bar.zoom_step(1)
	await settle()
	check(is_equal_approx(bar_dock.size.y, bar_height * 1.5), "A bar's row grows with it: %s -> %s" % [bar_height, bar_dock.size.y])
	# A stale or dragged row height never makes the bar taller than its content.
	space.band_rows[bar_dock.side][bar_dock.row] = 192.0
	space.reflow()
	await settle()
	check(is_equal_approx(bar_dock.size.y, bar_height * 1.5), "A bar is exactly its own height, whatever height its row stored: %s" % bar_dock.size.y)
	for step in 10: bar.zoom_step(-1)
	await settle()
	check(is_equal_approx(bar_dock.size.y, bar_height * 0.5), "A smaller bar takes less room, not a fixed minimum: %s" % bar_dock.size.y)
	for step in 10: bar.zoom_step(1)
	await settle()
	for step in 2: list.zoom_step(-1)
	await settle()
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(space.state_path))
	check(is_equal_approx(float(data.panels[list.persistence_key].scale), 0.8) and is_equal_approx(float(data.panels[bar.persistence_key].scale), 1.5), "The layout file records each panel's magnification")
	var again := preload("res://scenes/ListDockSpace.gd").new()
	again.state_path = space.state_path
	again.load_layout()
	check(is_equal_approx(float(again._saved.get(list.persistence_key, {}).get("scale", 0)), 0.8), "A saved layout with magnification loads")
	again.free()
	for step in 40: list.zoom_step(-1)
	check(is_equal_approx(list.panel_scale, space.MIN_SCALE), "Magnification stops at the lower limit")
	for step in 60: list.zoom_step(1)
	check(is_equal_approx(list.panel_scale, space.MAX_SCALE), "Magnification stops at the upper limit")
	DirAccess.remove_absolute(space.state_path)
	finish("PANEL_ZOOM")
