extends "res://tests/tab_insert_bounds_smoke.gd"
## Chromium-style removal: collapse outside neighbours, preserving content insets.

func _initialize() -> void:
	preload("../../../../tests/llm-e2e/replay/background.gd").install(self)
	super._initialize()


func prepare(strip: Control, count: int, width: float) -> void:
	strip.size.x = width
	strip.present_tabs(items(count), count)
	for i in 5: await process_frame
	tick(strip, 0)
	tick(strip, 0.2)
	tick(strip, 0.2)
	for i in 3: await process_frame
	strip.tabs.set_process(false)


func closing_separated(strip: Control, label: String) -> void:
	var closing: Array = strip.tabs._closing_tabs.keys()
	var views: Array = strip.tabs.buttons.values() + closing
	for i in views.size():
		var rect: Rect2 = views[i].get_rect()
		if rect.size.x < 0.01: continue
		for j in range(i + 1, views.size()):
			var overlap: Rect2 = rect.intersection(views[j].get_rect())
			check(overlap.size.x < 0.1 or overlap.size.y < 0.1,
				"%s: tab bodies do not overlap (%.2f px)" % [label, overlap.size.x])
	for view: Control in closing:
		for close: Button in view.find_children("Close", "Button", true, false):
			check(not close.visible, "%s: closing tab cannot be closed twice" % label)
		var visible := view.get_global_rect().intersection(strip.tabs.get_global_rect())
		if visible.size.x > 0.1:
			check(strip.tabs.plus.global_position.x >= visible.end.x + 2.9,
				"%s: plus stays outside the closing tab" % label)


func animate_close(strip: Control, label: String) -> void:
	closing_separated(strip, label + " initial")
	tick(strip, 0)
	for frame in 11:
		tick(strip, 0.02)
		closing_separated(strip, "%s frame %d" % [label, frame])
		var evidence := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
		if not evidence.is_empty() and DisplayServer.get_name() != "headless" and frame in [0, 4, 8]:
			await process_frame
			strip.tabs.set_process(false)
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(evidence.path_join("%s-%d.png" % [label.to_lower().replace(" ", "-"), frame]))
	check(strip.tabs._closing_tabs.is_empty(), label + ": closing views are deleted at completion")


func run() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.0
	root.size = Vector2i(1400, 400)
	var strip = load("res://scenes/TerminalTabBar.tscn").instantiate()
	root.add_child(strip)

	await prepare(strip, 3, 1400)
	var closing_button: Button = strip.tabs.buttons[3]
	var inset: float = closing_button.get_theme_stylebox("normal").content_margin_left
	var first: Rect2 = strip.tabs.buttons[1].get_rect()
	strip.present_tabs(items(2), 2)
	check(is_equal_approx(closing_button.get_theme_stylebox("normal").content_margin_left, inset),
		"Closing keeps the label inset instead of moving it into the preceding close button")
	var closing_view: Control = strip.tabs._closing_tabs.keys()[0]
	check(closing_view.get_global_rect().end.x <= strip.tabs.get_global_rect().end.x + 0.1,
		"Roomy strip keeps the closing tab visible instead of immediately clipping away its slot")
	await animate_close(strip, "Roomy trailing close")
	check(strip.tabs.buttons[1].get_rect().is_equal_approx(first), "Roomy close leaves existing tab bounds unchanged")

	await prepare(strip, 7, 600)
	var old_width: float = strip.tabs.buttons[1].size.x
	strip.present_tabs(items(6), 6)
	await animate_close(strip, "Crowded trailing close")
	check(strip.tabs.buttons[1].size.x > old_width, "Crowded close expands surviving tabs")

	await prepare(strip, 6, 600)
	var remaining := items(6)
	strip.tabs._request_close(3)
	remaining.remove_at(2)
	strip.present_tabs(remaining, 4)
	await animate_close(strip, "Middle mouse close")

	# Remove the predecessor of a tab which is already shrinking. The older
	# closing view must follow the new boundary, not jump back across tab 1.
	await prepare(strip, 4, 1400)
	strip.present_tabs(items(3), 3)
	tick(strip, 0)
	tick(strip, 0.06)
	strip.present_tabs(items(2), 2)
	await animate_close(strip, "Rapid trailing closes")

	await prepare(strip, 6, 600)
	remaining = items(6)
	strip.tabs._request_close(2)
	remaining.remove_at(1)
	strip.present_tabs(remaining, 3)
	tick(strip, 0)
	tick(strip, 0.06)
	strip.tabs._request_close(3)
	remaining.remove_at(1)
	strip.present_tabs(remaining, 4)
	await animate_close(strip, "Rapid middle closes")

	await prepare(strip, 4, 1400)
	strip.present_tabs([items(4)[0], items(4)[3]], 4)
	await animate_close(strip, "Adjacent simultaneous closes")

	await prepare(strip, 2, 1400)
	strip.present_tabs(items(3), 3)
	tick(strip, 0)
	tick(strip, 0.05)
	strip.present_tabs(items(2), 2)
	await animate_close(strip, "Close during insertion")

	await prepare(strip, 3, 1400)
	strip.present_tabs(items(2), 2)
	tick(strip, 0)
	tick(strip, 0.05)
	remaining = items(4)
	remaining.remove_at(2)
	strip.present_tabs(remaining, 4)
	await animate_close(strip, "Insert during closure")

	strip.queue_free()
	await process_frame
	print("TAB_CLOSE_BOUNDS failures=", failures)
	quit(1 if failures else 0)
