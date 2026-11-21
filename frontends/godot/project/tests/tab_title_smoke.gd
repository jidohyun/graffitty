extends "res://tests/tab_overflow_smoke.gd"


func settle(strip: Control) -> void:
	for i in 120:
		await process_frame
		if i > 4 and not strip.tabs._settling:
			break


func motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	root.push_input(event, true)


func run() -> void:
	root.gui_embed_subwindows = true
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.0
	root.size = Vector2i(1000, 400)
	var host := FakeHost.new()
	root.add_child(host)
	for i in 6:
		host.items.append(
			{
				"id": i + 1,
				"title": "iiiiiiiiiiiiiiiiiiii",
				"progress_state": 0,
				"progress_value": -1,
			}
		)
	var strip = load("res://scenes/TerminalTabBar.tscn").instantiate()
	strip.theme = Theme.new()
	strip.theme.default_font_size = 20
	strip.bind_host(host)
	root.add_child(strip)
	strip.size.x = 800
	await settle(strip)
	for id in strip.tabs.ids:
		var button: Button = strip.tabs.buttons[id]
		check(
			not button.get_meta("compact", false),
			"Narrow title characters retain their name in tab %d" % id,
		)
		var font_size := button.get_theme_font_size("font_size")
		check(font_size < 20 and font_size >= 16, "Crowded title uses a modestly smaller font")
		var width := button \
				.get_theme_font("font") \
				.get_string_size(button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size) \
				.x
		# Only the selected tab shows a close at rest; the others lend that room to their title.
		var allowance := 40.0 if button.button_pressed else 20.0
		check(width <= button.size.x - allowance + 0.1, "Displayed title fits its actual text budget")
		check(
			button.get_theme_stylebox("normal").content_margin_right == (30 if button.button_pressed else 10),
			"Resting tab reserves close room only when the close shows",
		)
	var font: Font = strip.tabs.get_theme_font("font", strip.tabs.tab_theme_type)
	var item := {
		"id": 1,
		"ordinal": 1,
		"title": "WWWWWWWWWWWWWWWWWWWW",
		"progress_state": 0,
		"progress_value": -1,
	}
	for count in [5, 6]:
		var budget := font \
				.get_string_size("1: " + "W".repeat(count) + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, 16) \
				.x + 0.1
		var formatted: Dictionary = strip._format_title(item, budget)
		check(
			(formatted.text == "1") == (count == 5),
			"Title fallback occurs at five characters, not six",
		)
	item.title = "src"
	check(strip._format_title(item, 100).text == "1: src", "A short complete title keeps its name")
	for title in ["A", ""]:
		item.title = title
		check(
			strip._format_title(item, 1).text == "1",
			"Even a one-character or empty title falls back to its number",
		)
	# A number-only title still leaves room for a separate close at this width.
	for page in host.items:
		page.title = "Workspace with a long title"
	strip.size.x = 500
	host.ui_changed.emit()
	await settle(strip)
	var paired: Button = strip.tabs.buttons[1]
	var paired_close: Button = paired.get_node("Close")
	motion(Vector2(400, 200))
	await process_frame
	var resting: Button = strip.tabs.buttons[3]
	var resting_text := resting.text
	check(
		resting.get_theme_stylebox("normal").content_margin_right == 10,
		"Resting inactive tab gives its close room to the title",
	)
	motion(resting.get_global_rect().get_center())
	await process_frame
	check(
		resting.get_theme_stylebox("normal").content_margin_right == 30 and resting.get_node("Close").visible,
		"Hovering an inactive tab reserves close room again",
	)
	motion(Vector2(400, 200))
	await process_frame
	await process_frame
	check(
		resting.text == resting_text and resting.get_theme_stylebox("normal").content_margin_right == 10,
		"Leaving the tab restores its wider title",
	)
	check(
		paired.text == "1" and paired_close.visible,
		"Number and close both remain visible when they fit",
	)
	var inactive: Button = strip.tabs.buttons[2]
	motion(inactive.get_global_rect().get_center())
	await process_frame
	check(
		inactive.text == "2" and inactive.get_node("Close").visible,
		"Hovering a wider inactive tab preserves its number beside close",
	)
	for page in host.items:
		page.title = "iiiiiiiiiiiiiiiiiiii"
	host.ui_changed.emit()
	root.size.x = 1400
	strip.size.x = 1400
	await settle(strip)
	check(
		strip.tabs.buttons[1].get_theme_font_size("font_size") == 20,
		"Title font returns to normal when space is available",
	)
	strip.theme.default_font_size = 14
	await settle(strip)
	check(
		strip._format_title(item, 1).font_size == 12,
		"Adaptive font respects its twelve-pixel minimum",
	)
	for i in range(7, 41):
		host.items.append(
			{ "id": i, "title": "Workspace %d" % i, "progress_state": 0, "progress_value": -1 }
		)
	host.select_workspace(40)
	strip.size.x = 700
	await settle(strip)
	var selected: Button = strip.tabs.buttons[40]
	motion(selected.global_position + Vector2(1, selected.size.y * 0.5))
	await process_frame
	await process_frame
	check(
		selected.text == "40" and not selected.get_node("Close").visible,
		"Hovering beside a cramped number does not replace it",
	)
	motion(selected.get_global_rect().get_center())
	await process_frame
	var close: Button = selected.get_node("Close")
	check(
		close.visible and selected.text.is_empty(),
		"Hovering compact tab replaces its number with the close icon",
	)
	check(strip.tabs.get_tab_title(39) == "40", "Hidden hover label does not erase the tab's title")
	motion(Vector2(400, 200))
	await process_frame
	await process_frame
	check(not close.visible and selected.text == "40", "Leaving compact tab restores its number")
	strip.tabs._ensure_tab_visible(39)
	await process_frame
	inactive = strip.tabs.buttons[39]
	motion(inactive.get_global_rect().get_center())
	await process_frame
	check(
		inactive.text == "39" and not inactive.get_node("Close").visible,
		"Hovering an inactive cramped tab keeps its number",
	)
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = inactive.get_global_rect().get_center()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		root.push_input(event, true)
		await process_frame
	check(
		host.workspace_layout.active == 39 and host.closed_ids.is_empty(),
		"Clicking a cramped number selects without closing",
	)
	# Control the frame clock to exercise an owner update halfway through a
	# transition even on machines where starting another shell takes >200 ms.
	host.items = host.items.slice(0, 6)
	strip.size.x = 800
	host.select_workspace(1)
	await settle(strip)
	var first: Button = strip.tabs.buttons[1]
	var before := first.get_rect()
	host.items.append(
		{ "id": 7, "title": "Seventh workspace", "progress_state": 0, "progress_value": -1 }
	)
	strip.present_tabs(host.items, 7)
	check(
		first.get_rect().is_equal_approx(before),
		"Adding leaves existing bounds unchanged until the first animation frame",
	)
	strip.tabs._process(0)
	strip.tabs._process(0.05)
	var halfway := first.get_rect()
	check(
		halfway.size.x < before.size.x and halfway.size.x > strip.tabs._tab_width,
		"Insertion has an intermediate width",
	)
	var animation = strip.tabs._bounds_animations[first]
	strip.present_tabs(host.items, 7)
	strip.tabs._process(0.05)
	check(
		strip.tabs._bounds_animations[first] == animation and animation.elapsed >= 0.1,
		"Identical owner refreshes preserve the running animation clock",
	)
	halfway = first.get_rect()
	host.items.append(
		{ "id": 8, "title": "Eighth workspace", "progress_state": 0, "progress_value": -1 }
	)
	strip.present_tabs(host.items, 8)
	strip.tabs._process(0)
	check(
		first.get_rect().is_equal_approx(halfway),
		"Interrupted insertion starts at the currently displayed bounds",
	)
	strip.tabs._process(0.1)
	check(
		first.size.x < halfway.size.x and first.size.x > strip.tabs._tab_width,
		"Retargeted insertion continues shrinking smoothly",
	)
	strip.tabs._process(0.1)
	check(
		is_equal_approx(first.size.x, strip.tabs._tab_width),
		"Bounds reach the exact target after 200 ms",
	)
	await settle(strip)
	if DisplayServer.get_name() != "headless":
		host.items = host.items.slice(0, 6)
		for item_page in host.items:
			item_page.title = "/home/demo/project/graffitty"
		strip.theme.default_font_size = 16
		root.size = Vector2i(800, 180)
		strip.size.x = 800
		host.select_workspace(6)
		await settle(strip)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/graffitty-adaptive-tabs.png")
	strip.queue_free()
	host.queue_free()
	await process_frame
	print("TAB_TITLES failures=", failures)
	quit(1 if failures else 0)
