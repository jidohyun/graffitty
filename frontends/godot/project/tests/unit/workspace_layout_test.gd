extends "res://tests/unit/test_case.gd"
## Tabs and their windows under random sequences of moves: nothing is lost,
## duplicated or left pointing at a window that is gone.
const Layout := preload("res://scenes/WorkspaceLayout.gd")


func test_closed_tab_selects_neighbor_in_visual_order() -> void:
	var layout := Layout.new()
	for id in [8, 4, 13, 2]: layout.add(id, Layout.leaf("%%%d" % id))
	layout.active = 13
	layout.take(13)
	expect(layout.active == 4, "Closing the third tab selects the second, regardless of IDs")
	layout.take(8)
	expect(layout.active == 4, "Closing an inactive tab preserves the active tab")
	layout.take(4)
	expect(layout.active == 2, "Closing the first tab selects its right neighbor")
	layout.take(2)
	expect(layout.active == -1, "Closing the last tab leaves no selection")
	expect(Layout.surviving_active([8, 4, 13, 2], 13, [8, 2]) == 8,
		"A batched remote update chooses the nearest surviving left neighbor")
	expect(Layout.surviving_active([8, 4, 13, 2], 13, [2]) == 2,
		"A batched remote update uses the right neighbor when no left tab survives")


func all_keys(layout: Layout) -> Array[String]:
	var result: Array[String] = []
	for tab in layout.tabs:
		result.append_array(Layout.keys(tab.tree))
	return result


func consistent(layout: Layout, expected: Array[String], step: String) -> bool:
	var keys := all_keys(layout)
	var sorted_keys := keys.duplicate()
	sorted_keys.sort()
	var sorted_expected := expected.duplicate()
	sorted_expected.sort()
	if not expect(
		sorted_keys == sorted_expected,
		"%s: windows %s, expected %s" % [step, sorted_keys, sorted_expected],
	):
		return false
	for tab in layout.tabs:
		if not expect(
			not Layout.keys(tab.tree).is_empty() and tab.focused in Layout.keys(tab.tree),
			"%s: tab %d is empty or focuses a window it lacks" % [step, tab.id],
		):
			return false
		for key in Layout.keys(tab.tree):
			if not expect(
				layout.containing(key) == tab.id,
				"%s: %s is not found in its tab" % [step, key],
			):
				return false
	return expect(
		layout.tabs.is_empty() == (layout.active < 0)
		and (layout.active < 0 or not layout.tab(layout.active).is_empty()),
		"%s: active tab %d does not exist" % [step, layout.active],
	)


func test_no_move_loses_or_duplicates_a_window() -> void:
	for n in 200:
		var layout := Layout.new()
		var expected: Array[String] = []
		var next := 0
		for step in 40:
			var tabs := layout.tabs
			match rng.randi_range(0, 4):
				0: # A new terminal tab.
					layout.ensure_terminal(next)
					expected.append("%%%d" % next)
					next += 1
				1: # Drag one window into another tab.
					if tabs.size() >= 2:
						var from: Dictionary = tabs[rng.randi_range(0, tabs.size() - 1)]
						var to: Dictionary = tabs[rng.randi_range(0, tabs.size() - 1)]
						if from != to:
							var key: String = Layout.keys(from.tree)[
								rng.randi_range(0, Layout.keys(from.tree).size() - 1)
							]
							var target: int = to.id
							var window := layout.take_pane(key)
							if not layout.tab(target).is_empty():
								layout.merge(target, window)
							else:
								expected.erase(key)
				2: # Drag a window out into a tab of its own.
					if not tabs.is_empty():
						var from: Dictionary = tabs[rng.randi_range(0, tabs.size() - 1)]
						var key: String = Layout.keys(from.tree)[0]
						if Layout.keys(from.tree).size() > 1:
							layout.add(1000 + next, layout.take_pane(key))
							next += 1
				3: # Reorder.
					if not tabs.is_empty():
						layout.reorder(
							tabs[rng.randi_range(0, tabs.size() - 1)].id,
							rng.randi_range(-2, tabs.size() + 2),
						)
				4: # Close a tab with everything in it.
					if not tabs.is_empty():
						var closing: Dictionary = layout.take(
							tabs[rng.randi_range(0, tabs.size() - 1)].id
						)
						for key in Layout.keys(closing.tree):
							expected.erase(key)
			if not consistent(layout, expected, "case %d step %d" % [n, step]):
				break


func test_a_merged_window_never_hides_exactly_behind_another() -> void:
	for n in 200:
		var layout := Layout.new()
		var rect := Rect2(rng.randf_range(0, 500), rng.randf_range(0, 500), 400, 300)
		layout.add(0, { "windows": [{ "pane": "%0", "rect": rect }] })
		for i in range(1, 6):
			layout.merge(0, { "pane": "%%%d" % i, "rect": rect })
		var rects: Array = Layout.windows(layout.tab(0).tree).map(
			func(window):
				return window.rect,
		)
		for i in rects.size():
			for j in range(i + 1, rects.size()):
				expect(
					rects[i] != rects[j],
					"case %d: windows %d and %d share %s" % [n, i, j, rects[i]],
				)


func test_a_tab_keeps_its_own_name_until_merged() -> void:
	for n in 100:
		var layout := Layout.new()
		for i in 5:
			layout.ensure_terminal(i)
		var named: int = layout.tabs[rng.randi_range(0, 4)].id
		layout.set_title(named, "NAME %d" % n)
		layout.reorder(named, rng.randi_range(0, 4))
		var moved := layout.take(named)
		layout.tabs.append(moved)
		expect(
			layout.tab(named).get("title", "") == "NAME %d" % n,
			"case %d: the name is lost moving the tab" % n,
		)
		var other: int = layout.tabs[0].id if layout.tabs[0].id != named else layout.tabs[1].id
		layout.merge(other, layout.take(named).tree)
		expect(not layout.tab(other).has("title"), "case %d: a merged tab passes its name on" % n)
		layout.set_title(other, "X")
		layout.set_title(other, "")
		expect(
			not layout.tab(other).has("title"),
			"case %d: an empty name does not clear the pin" % n,
		)
