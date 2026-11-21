extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/pane-hover-move.md


func play() -> void:
	await labelled_tabs(["ALPHA", "BRAVO", "CHARLIE"])
	await say("Merge BRAVO into ALPHA: drag its tab onto ALPHA, hold, drop into the content")
	await merge_tab("BRAVO", "ALPHA")
	await panes_at_rest()
	await say("Move the BRAVO window by its header so both windows show")
	await drag(on(handle("BRAVO")), content(Vector2(0.62, 0.5)), 1.0)
	await panes_at_rest()
	var key := "%%%d" % terminal_id("BRAVO")
	var placed: Rect2 = host.workspace_view.pane_rects[key]

	await say("Drag the BRAVO handle onto the middle of CHARLIE's tab and hold")
	await point_at(on(handle("BRAVO")))
	await press()
	await point_at(on(tab_button(tab_index("CHARLIE"))), 1.2)
	await hold(1.0)
	check(selected_title() == "CHARLIE", "Holding shows CHARLIE's content (%s)" % selected_title())
	await say("Press Escape, then release")
	await keys("escape")
	await release()
	await wait(0.6)
	check(
		titles() == ["BRAVO", "CHARLIE"] and selected_title() == "BRAVO"
		and host.workspace_layout.keys(host.workspace_layout.tabs[0].tree).size() == 2
		and host.workspace_view.pane_rects.get(key) == placed,
		"Escape brings back ALPHA with both windows, BRAVO where it was",
	)

	await say("Drag BRAVO onto CHARLIE again and hold until CHARLIE opens")
	await point_at(on(handle("BRAVO")))
	await press()
	await point_at(on(tab_button(tab_index("CHARLIE"))), 1.2)
	await hold(1.0)
	await say("Move down into CHARLIE's content, lower right, and release")
	await point_at(content(Vector2(0.7, 0.68)), 1.0)
	await wait(0.5)
	await release()
	await wait(0.8)

	check(
		titles() == ["ALPHA", "BRAVO"]
		and host.workspace_layout.keys(host.workspace_layout.tabs[1].tree).size() == 2,
		"BRAVO moved into CHARLIE's tab (%s)" % [titles()],
	)
	check(host.pane_focus == key, "BRAVO has keyboard focus")
	check_same_shells()
