extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/pane-to-new-tab.md


func bar_end() -> Vector2:
	return on(tab_strip().plus, Vector2(1, 0.5)) + Vector2(90, 0)


func play() -> void:
	# Keep both source and destination floating to test rectangle preservation.
	host.session_backend.set_default_tiling(host, false)
	await owner_at_rest()
	if host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		host.workspace_view.toggle_tiling()
	await labelled_tabs(["ALPHA", "BRAVO", "CHARLIE"])
	await say("Merge BRAVO into ALPHA: drag its tab onto ALPHA, hold, drop into the content")
	await merge_tab("BRAVO", "ALPHA")
	await panes_at_rest()
	check(
		titles() == ["BRAVO", "CHARLIE"]
		and host.workspace_layout.keys(host.workspace_layout.tabs[0].tree).size() == 2,
		"ALPHA's tab holds two windows (%s)" % [titles()],
	)
	await say("Move the BRAVO window by its header so both windows show")
	await drag(on(handle("BRAVO")), content(Vector2(0.62, 0.5)), 1.0)
	await panes_at_rest()
	var key := "%%%d" % terminal_id("BRAVO")
	var placed: Rect2 = host.workspace_view.pane_rects[key]

	await say("Drag the BRAVO handle up onto the tab bar, beside the last tab")
	await point_at(on(handle("BRAVO")))
	await press()
	await point_at(content(Vector2(0.55, 0.35)), 0.8)
	await point_at(bar_end(), 1.0)
	await wait(0.5)
	check(
		host.workspace_view.pane_rects[key] == placed,
		"Over the bar, the window waits where it was",
	)
	await say("Move over the gap between ALPHA and CHARLIE, then back to the end")
	await point_at(on(tab_button(0), Vector2(1.0, 0.5)), 0.8)
	await wait(0.8)
	await point_at(bar_end(), 0.8)
	await wait(0.4)
	await release()
	await wait(0.8)
	await owner_at_rest()

	check(
		titles() == ["ALPHA", "CHARLIE", "BRAVO"] and selected_title() == "BRAVO",
		"A new tab BRAVO, selected, at the end (%s; selected=%s)" % [titles(), selected_title()],
	)
	check(host.workspace_view.pane_rects.get(key) == placed, "BRAVO keeps its position and size (%s -> %s)" % [placed, host.workspace_view.pane_rects.get(key)])
	check_same_shells()

	# Exercise the same target change with tiling enabled: content offers a
	# split, but carrying a pane back to the bar must only offer tab insertion.
	await select_tab(0)
	if not host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		host.workspace_view.toggle_tiling()
	await owner_at_rest()
	await select_tab(2)
	await point_at(on(handle("BRAVO")))
	await press()
	await point_at(on(tab_button(0)), 0.8)
	await hold(1.0)
	await point_at(content(Vector2(0.6, 0.5)), 0.6)
	await wait(0.3)
	check(not host.workspace_view.preview_plan.is_empty(), "A carried pane offers a split over tiled content")
	await point_at(bar_end(), 0.6)
	check(
		# A sole-pane tab cannot become another tab in the same host. The bar
		# rejects that redundant insertion while still clearing the split hint.
		app.drag.get("mode") == app.DragMode.BLOCKED
		and host.workspace_view.preview_plan.is_empty()
		and not host.workspace_view.layout_preview.visible
		and not host.workspace_view.drop_hint.visible,
		"Carrying the pane back to the bar cancels the split preview",
	)
	await release()
	await owner_at_rest()
	check(host.get_tabs().size() == 3, "Dropping on the bar keeps three tabs instead of splitting the destination")
	check_same_shells()
