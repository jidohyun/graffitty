extends "res://tests/tab_overflow_smoke.gd"
## Exercise the real title formatter and parent layout, with a controlled clock.

func items(count: int) -> Array:
	var result: Array = []
	for i in count:
		result.append({"id": i + 1, "title": "Workspace %d" % (i + 1), "progress_state": 0, "progress_value": -1})
	return result


func tick(strip: Control, delta: float) -> void:
	strip.tabs._process(delta)
	strip.tabs.set_process(false)


func separated(strip: Control, label: String) -> void:
	for i in range(1, strip.tabs.ids.size()):
		var left: Button = strip.tabs.buttons[strip.tabs.ids[i - 1]]
		var right: Button = strip.tabs.buttons[strip.tabs.ids[i]]
		check(right.position.x >= left.get_rect().end.x + 2.9,
			"%s: tab %d starts after its predecessor (%.2f >= %.2f)" % [label, i + 1, right.position.x, left.get_rect().end.x + 3])
		if right.size.x < strip.tabs.minimum_tab_width:
			var close: Button = right.get_node("Close")
			var pointer: Vector2 = strip.tabs._pointer
			strip.tabs._pointer = right.position + strip.tabs.row.position + close.get_rect().get_center()
			strip.tabs._update_close_visibility(right, true)
			check(not close.visible, "%s: collapsed tab has no overflowing close target" % label)
			strip.tabs._pointer = pointer
	var last: Button = strip.tabs.buttons[strip.tabs.ids[-1]]
	var visible := last.get_global_rect().intersection(strip.tabs.get_global_rect())
	check(strip.tabs.plus.global_position.x >= visible.end.x + 2.9,
		"%s: plus stays outside the visible trailing tab" % label)


func run() -> void:
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1.0
	root.size = Vector2i(1400, 400)
	var strip = load("res://scenes/TerminalTabBar.tscn").instantiate()
	root.add_child(strip)
	strip.size.x = 1400
	strip.present_tabs(items(1), 1)
	for i in 5: await process_frame
	tick(strip, 0)
	tick(strip, 0.2)
	var first: Rect2 = strip.tabs.buttons[1].get_rect()
	strip.present_tabs(items(2), 2)
	separated(strip, "Roomy insertion, before the first frame")
	tick(strip, 0)
	for frame in 10:
		tick(strip, 0.02)
		separated(strip, "Roomy insertion frame %d" % frame)
		check(strip.tabs.buttons[1].get_rect().is_equal_approx(first), "Roomy insertion does not resize or move tab 1")
	check(is_equal_approx(strip.tabs.buttons[2].size.x, strip.tabs.maximum_tab_width), "New tab finishes at full width")

	# The preceding tab may still be growing when another new tab arrives.
	strip.present_tabs(items(3), 3)
	tick(strip, 0)
	tick(strip, 0.05)
	strip.present_tabs(items(4), 4)
	tick(strip, 0)
	for frame in 10:
		tick(strip, 0.02)
		separated(strip, "Interrupted roomy insertion frame %d" % frame)

	# A crowded strip must shrink existing tabs, without placing the new one
	# on top of the old trailing close button at any point in the animation.
	strip.size.x = 600
	strip.present_tabs(items(6), 6)
	for i in 5: await process_frame
	tick(strip, 0)
	tick(strip, 0.2)
	tick(strip, 0.2)
	var old_width: float = strip.tabs.buttons[1].size.x
	strip.present_tabs(items(7), 7)
	separated(strip, "Crowded insertion, before the first frame")
	tick(strip, 0)
	for frame in 10:
		tick(strip, 0.02)
		separated(strip, "Crowded insertion frame %d" % frame)
	check(strip.tabs.buttons[1].size.x < old_width, "Crowded insertion shrinks existing tabs")
	check(is_equal_approx(strip.tabs.buttons[7].size.x, strip.tabs._tab_width), "Crowded insertion reaches its target width")
	strip.queue_free()
	await process_frame
	print("TAB_INSERT_BOUNDS failures=", failures)
	quit(1 if failures else 0)
