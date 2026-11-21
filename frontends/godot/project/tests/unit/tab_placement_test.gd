extends "res://tests/unit/test_case.gd"
## Where a dragged tab would land, for a pointer anywhere along the bar.
var strip: Control


func place(x: float, count: int, gap: int) -> Dictionary:
	var others: Array = []
	for i in count:
		others.append(100 + i)
	return strip._placement(x, others, gap)


func each_strip(body: Callable) -> void:
	for n in 100:
		strip = load("res://scenes/TabStrip.gd").new()
		strip._tab_width = rng.randf_range(40, 220)
		body.call(n, rng.randi_range(1, 12))
		strip.free()


func test_a_resting_pointer_never_flips_its_slot() -> void:
	# Opening the slot moves the neighbours; asked again with the slot open,
	# the same pointer must choose the same slot, or the bar flickers.
	each_strip(
		func(n: int, count: int) -> void:
			for sample in 60:
				var x: float = rng.randf_range(-50, (count + 2) * (strip._tab_width + 3))
				var first := place(x, count, -1)
				var settled := place(x, count, first.index)
				expect(
					settled.index == first.index,
					"case %d: at %.1f the slot flips from %d to %d"
					% [n, x, first.index, settled.index],
				),
	)


func test_moving_right_never_moves_the_slot_left() -> void:
	each_strip(
		func(n: int, count: int) -> void:
			var previous := -1
			var x := -20.0
			while x < (count + 2) * (strip._tab_width + 3):
				var index: int = place(x, count, -1).index
				if not expect(
					index >= previous,
					"case %d: the slot goes back from %d to %d at %.1f" % [n, previous, index, x],
				):
					return
				previous = index
				x += 2.0,
	)


func test_the_middle_of_a_tab_targets_that_tab() -> void:
	each_strip(
		func(n: int, count: int) -> void:
			for i in count:
				var middle: float = i * (strip._tab_width + 3) + strip._tab_width * 0.5
				expect(
					place(middle, count, -1).hover == 100 + i,
					"case %d: the middle of tab %d does not target it" % [n, i],
				),
	)


func test_chromium_swaps_at_half_overlap_from_any_grab_point() -> void:
	var chromium := preload("res://scenes/ChromiumTabStrip.gd").new()
	chromium._tab_width = 200.0
	for grab in [10.0, 100.0, 190.0]:
		chromium._grab_offset = grab
		expect(chromium._placement(grab + 102, [2, 3], 0).index == 0, "Below half overlap stays put")
		var swapped: Dictionary = chromium._placement(grab + 104, [2, 3], 0)
		expect(swapped.index == 1 and swapped.hover == -1, "Half overlap swaps without a merge target")
		expect(chromium._placement(grab + 104, [2, 3], 1).index == 1, "Stationary drag does not oscillate")
		expect(chromium._placement(grab + 99, [2, 3], 1).index == 0, "Crossing back swaps left")
		expect(chromium._placement(grab + 500, [2, 3], 0).index == 2, "Fast drag crosses multiple tabs")
	chromium.free()


func test_an_incoming_slot_keeps_the_held_tab_under_the_pointer() -> void:
	# A narrow phone bar: shrinking tabs for the placeholder slid the hovered
	# tab out from under a held finger, so hold-to-open never fired.
	strip = load("res://scenes/TabStrip.gd").new()
	strip._ready()
	strip.size = Vector2(420, 34)
	strip.reconcile([{"id": 1, "title": "One"}, {"id": 2, "title": "Two"}, {"id": 3, "title": "Three"}], 1)
	strip._fit()
	var width: float = strip._tab_width
	var middle: float = (width + 3) + width * 0.5
	var first: Dictionary = strip._placement(middle, strip.ids, -1)
	expect(first.hover == 2, "The middle of the second tab targets it")
	strip.set_external_drop_hint(first.index, "Incoming")
	expect(is_equal_approx(strip._tab_width, width), "Opening an incoming slot keeps tab widths")
	expect(strip._placement(middle, strip.ids, strip.external_drop_hint).hover == 2, "The held pointer still targets the same tab")
	strip.free()
