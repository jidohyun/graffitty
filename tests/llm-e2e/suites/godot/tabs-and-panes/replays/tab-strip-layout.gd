extends "../../../../replay/replay.gd"

var samples: Array[Dictionary] = []


func sample() -> void:
	var rects := { }
	for id in tab_strip().buttons:
		var button: Button = tab_strip().buttons[id]
		rects[id] = Rect2(button.position, button.size)
	var closing_rects: Array[Rect2] = []
	for view: Control in tab_strip()._closing_tabs:
		closing_rects.append(view.get_rect())
	samples.append(
		{
			"rects": rects,
			"closing": tab_strip()._closing_tabs.size(),
			"closing_rects": closing_rects,
			"viewport_right": tab_strip().scroll_horizontal + tab_strip().size.x,
			"plus": tab_strip().plus.position.x,
			"time": Time.get_ticks_msec(),
		}
	)


func save_samples(name: String) -> void:
	var frames: Array = []
	for sample_frame in samples:
		var frame: Dictionary = sample_frame.duplicate(true)
		for id in frame.rects:
			var rect: Rect2 = frame.rects[id]
			frame.rects[id] = [rect.position.x, rect.position.y, rect.size.x, rect.size.y]
		frame.closing_rects = frame.closing_rects.map(func(rect): return [rect.position.x, rect.position.y, rect.size.x, rect.size.y])
		frames.append(frame)
	FileAccess.open(evidence_path(name + ".json"), FileAccess.WRITE).store_string(
		JSON.stringify(frames)
	)


func continuous_width(id: int, start: float, finish: float) -> bool:
	var previous := start
	for frame in samples:
		if not frame.rects.has(id):
			continue
		var width: float = frame.rects[id].size.x
		if absf(width - previous) > absf(finish - start) * 0.6:
			return false
		if width < minf(start, finish) - 0.1 or width > maxf(start, finish) + 0.1:
			return false
		if (width - previous) * (finish - start) < -0.1:
			return false
		previous = width
	return is_equal_approx(previous, finish)


func settled() -> void:
	await owner_at_rest()
	for frame in 180:
		await process_frame
		if frame > 3 and not tab_strip()._settling:
			return
	check(false, "Tab strip settles within three seconds")


func resize_tabs(width: float) -> void:
	var logical := root.get_visible_rect().size
	logical.x += host.get_tabs().size() * (width + 3) - tab_strip().size.x
	root.size = Vector2i(logical * root.content_scale_factor)
	root.content_scale_size = Vector2i(logical)
	await settled()


func intermediate_widths(id: int, start: float, finish: float) -> int:
	var widths := { }
	for frame in samples:
		if not frame.rects.has(id):
			continue
		var width: float = frame.rects[id].size.x
		if width > minf(start, finish) + 0.2 and width < maxf(start, finish) - 0.2:
			widths[snappedf(width, 0.1)] = true
	return widths.size()


func repeated_mouse_closes() -> void:
	await say("Repeated mouse closes keep the next target under the pointer")
	await select_tab(1)
	await settled()
	var strip: Control = tab_strip()
	var width: float = tab_button(0).size.x
	var target := on(tab_button(1).get_node("Close"))
	for expected in [5, 4]:
		await click(target)
		await settled()
		check(host.get_tabs().size() == expected, "Stationary pointer closes exactly the next tab")
		check(is_equal_approx(tab_button(0).size.x, width), "Middle mouse-close holds surviving widths")
		check(on(tab_button(1).get_node("Close")).distance_to(target) < 1.0, "Next close target remains under pointer")
	var bounds := strip.get_global_rect()
	await point_at(Vector2(target.x, bounds.end.y + 25))
	await create_timer(.4).timeout
	check(is_equal_approx(tab_button(0).size.x, width), "40 px vertical allowance keeps closing mode")
	await point_at(Vector2(target.x, bounds.end.y + 65))
	await create_timer(.12).timeout
	check(is_equal_approx(tab_button(0).size.x, width), "Mouse exit waits before expanding")
	await point_at(target)
	await create_timer(.35).timeout
	check(is_equal_approx(tab_button(0).size.x, width), "Re-entry cancels delayed expansion")
	await point_at(Vector2(target.x, bounds.end.y + 65))
	samples.clear()
	process_frame.connect(sample)
	await create_timer(.65).timeout
	await settled()
	process_frame.disconnect(sample)
	var first: int = host.get_tabs()[0].id
	check(tab_button(0).size.x > width + 10, "Leaving closes mode and expands tabs")
	check(intermediate_widths(first, width, tab_button(0).size.x) >= 3, "Post-close expansion is animated")
	save_samples("tabs-mouse-close-expansion")
	await select_tab(1)
	width = tab_button(0).size.x
	await keys("cmd+w")
	await settled()
	check(host.get_tabs().size() == 3 and tab_button(0).size.x > width, "Keyboard close expands without mouse closing mode")
	await open_tabs(6)
	await settled()


func separated_insertion(previous: int, added: int) -> bool:
	var seen := false
	for frame in samples:
		if not frame.rects.has(previous) or not frame.rects.has(added):
			continue
		seen = true
		if frame.rects[added].position.x < frame.rects[previous].end.x + 2.9:
			return false
	return seen


func separated_closure() -> bool:
	var seen := false
	for frame in samples:
		for rect: Rect2 in frame.closing_rects:
			seen = true
			for live: Rect2 in frame.rects.values():
				var overlap := rect.intersection(live)
				if overlap.size.x > 0.1 and overlap.size.y > 0.1:
					return false
	return seen


func play() -> void:
	await open_tabs(1)
	await settled()
	await resize_tabs(600)
	await say("With room available, the new tab opens entirely to the right")
	var roomy_first: int = host.get_tabs()[0].id
	var roomy_bounds: Rect2 = tab_strip().buttons[roomy_first].get_rect()
	samples.clear()
	process_frame.connect(sample)
	await click(on(tab_strip().plus))
	await settled()
	process_frame.disconnect(sample)
	if not check(host.get_tabs().size() == 2, "Plus adds a second tab to the roomy strip"):
		return
	check(separated_insertion(roomy_first, host.get_tabs()[-1].id), "New tab never overlaps the preceding tab or its close button")
	check(samples.all(func(frame): return frame.rects[roomy_first].is_equal_approx(roomy_bounds)), "Existing tab stays fixed when there is room")
	save_samples("tabs-roomy-add-bounds")

	await say("Closing stays outside the preceding tab and remains visible as it shrinks")
	samples.clear()
	process_frame.connect(sample)
	await click(on(tab_button(1).get_node("Close")))
	await settled()
	process_frame.disconnect(sample)
	check(host.get_tabs().size() == 1, "Roomy trailing close removes only the second tab")
	check(separated_closure(), "Closing tab never slides its label over the preceding tab")
	check(samples.all(func(frame): return frame.closing_rects.all(func(rect): return rect.end.x <= frame.viewport_right + 0.1)), "Viewport retains the closing tab throughout its animation")
	check(samples.all(func(frame): return frame.rects[roomy_first].is_equal_approx(roomy_bounds)), "Roomy close leaves the first tab fixed")
	save_samples("tabs-roomy-close-bounds")

	await open_tabs(6)
	await settled()
	await resize_tabs(110)
	await point_at(Vector2(400, 150))
	var first: int = host.get_tabs()[0].id
	var previous_width: float = tab_strip().buttons[first].size.x
	await say("Add a tab: grow from the preceding edge while neighbours shrink")
	samples.clear()
	process_frame.connect(sample)
	await click(on(tab_strip().plus))
	await settled()
	process_frame.disconnect(sample)
	if not check(host.get_tabs().size() == 7, "Plus creates exactly one tab"):
		return
	var added: int = host.get_tabs()[-1].id
	var added_button: Button = tab_strip().buttons[added]
	check(separated_insertion(host.get_tabs()[-2].id, added), "Crowded insertion also stays outside the preceding tab")
	check(
		intermediate_widths(first, previous_width, tab_strip().buttons[first].size.x) >= 3,
		"Existing widths shrink through multiple frames",
	)
	check(
		continuous_width(first, previous_width, tab_strip().buttons[first].size.x),
		"Adding never snaps existing widths or reverses their motion",
	)
	check(
		intermediate_widths(added, 16, added_button.size.x) >= 3,
		"New tab grows through multiple widths",
	)
	var positions: Array[float] = []
	for frame in samples:
		if frame.rects.has(added):
			positions.append(frame.rects[added].position.x)
	check(
		positions.size() > 2 and positions[0] > positions[-1] + 20,
		"New tab opens toward the left in a crowded strip",
	)
	check(
		is_equal_approx(tab_strip().buttons[first].size.x, tab_strip()._tab_width),
		"Owner refreshes do not restart or leave unfinished widths",
	)
	save_samples("tabs-add-bounds")

	await say("Close the trailing tab: shrink it while remaining tabs expand rightward")
	previous_width = tab_strip().buttons[first].size.x
	var last_right: float = tab_button(5).get_rect().end.x
	samples.clear()
	process_frame.connect(sample)
	await click(on(added_button.get_node("Close")))
	await settled()
	process_frame.disconnect(sample)
	check(host.get_tabs().size() == 6, "Close removes exactly the trailing tab")
	check(separated_closure(), "Crowded closure does not overlap expanding neighbours")
	check(
		intermediate_widths(first, previous_width, tab_strip().buttons[first].size.x) >= 3,
		"Surviving widths expand through multiple frames",
	)
	check(
		continuous_width(first, previous_width, tab_strip().buttons[first].size.x),
		"Closing never snaps existing widths or reverses their motion",
	)
	check(tab_button(5).get_rect().end.x > last_right + 20, "Survivors expand from left to right")
	check(
		samples.any(
			func(frame):
				return frame.closing > 0,
		),
		"Closing view remains present during its shrink animation",
	)
	check(tab_strip()._closing_tabs.is_empty(), "Closing view is deleted when animation finishes")
	save_samples("tabs-close-bounds")
	await repeated_mouse_closes()

	# This step acts on purpose before the strip has come to rest.
	waits_for_rest = false
	await say("Add again during an unfinished animation")
	previous_width = tab_strip().buttons[first].size.x
	samples.clear()
	process_frame.connect(sample)
	await click(on(tab_strip().plus))
	var deadline := Time.get_ticks_msec() + 5000
	while host.get_tabs().size() < 7 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(tab_strip()._settling, "Second add begins while the first is still animating")
	waits_for_rest = true
	await keys("cmd+t")
	await settled()
	process_frame.disconnect(sample)
	check(host.get_tabs().size() == 8, "Rapid additions create both requested tabs")
	check(
		continuous_width(first, previous_width, tab_strip().buttons[first].size.x),
		"Interrupted insertion retargets continuously from visible bounds",
	)
	save_samples("tabs-interrupted-add-bounds")

	await say("At maximum tab width the plus button follows smoothly")
	await resize_tabs(300)
	var plus_start: float = tab_strip().plus.position.x
	samples.clear()
	process_frame.connect(sample)
	await click(on(tab_strip().plus))
	await settled()
	process_frame.disconnect(sample)
	var plus_end: float = tab_strip().plus.position.x
	var intermediate := { }
	for frame in samples:
		if frame.plus > plus_start + 1 and frame.plus < plus_end - 1:
			intermediate[snappedf(frame.plus, 0.1)] = true
	check(
		plus_end > plus_start + 100 and intermediate.size() >= 3,
		"Plus advances through intermediate positions as a full-width tab opens",
	)
	save_samples("tabs-plus-bounds")

	await open_tabs(12)
	for index in 12:
		await label_tab(index, "Workspace with a long title")
	await select_tab(0)
	await resize_tabs(60)
	await point_at(Vector2(400, 150))
	var active: Button = tab_button(0)
	var close: Button = active.get_node("Close")
	check(active.text == "1" and close.visible, "Two slots show both the number and close")
	(await screen_image()).save_png(evidence_path("tabs-number-and-close.png"))
	await point_at(on(tab_button(1)))
	check(
		tab_button(1).text == "2" and tab_button(1).get_node("Close").visible,
		"Wider inactive hover keeps number beside close",
	)

	await label_tab(0, "A")
	await resize_tabs(32)
	await point_at(Vector2(400, 150))
	check(
		active.text == "1" and not close.visible,
		"One-character title still shows its number when cramped",
	)
	(await screen_image()).save_png(evidence_path("tabs-number-only.png"))
	await point_at(on(active, Vector2(0.02, 0.5)))
	check(
		active.text == "1" and not close.visible,
		"Hover beside the active number keeps the number",
	)
	await point_at(on(active))
	check(
		active.text.is_empty() and close.visible,
		"Only hovering the focused number replaces it with close",
	)
	(await screen_image()).save_png(evidence_path("tabs-number-hover-close.png"))
	await point_at(on(tab_button(1)))
	check(active.text == "1" and not close.visible, "Leaving restores the focused number")
	check(
		tab_button(1).text == "2" and not tab_button(1).get_node("Close").visible,
		"Inactive cramped hover preserves its number",
	)
	await click(on(tab_button(1)))
	await settled()
	check(
		host.get_tabs().size() == 12 and tab_strip().selected_id == int(host.get_tabs()[1].id),
		"Clicking an inactive number selects without closing",
	)
