extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/tab-reorder.md


func play() -> void:
	await labelled_tabs(["ALPHA", "BRAVO", "CHARLIE"])
	check(
		titles() == ["ALPHA", "BRAVO", "CHARLIE"],
		"The bar reads ALPHA, BRAVO, CHARLIE: %s" % [titles()],
	)

	await say("Select ALPHA and drag it along the bar, past CHARLIE")
	await select_tab(0)
	await point_at(tab_grip(0))
	await press()
	await point_at(on(tab_button(2), Vector2(0.9, 0.5)), 2.2)
	await wait(0.3)
	await release()
	await wait(0.6)
	check(
		titles() == ["BRAVO", "CHARLIE", "ALPHA"] and selected_title() == "ALPHA",
		"Dropped at the end: BRAVO, CHARLIE, ALPHA, with ALPHA still selected (%s)" % [titles()],
	)

	await say("Drag CHARLIE to the left of every tab")
	await drag(tab_grip(1), on(tab_button(0), Vector2(0.05, 0.5)), 1.6)
	await wait(0.6)
	check(
		titles() == ["CHARLIE", "BRAVO", "ALPHA"],
		"Dropped first: CHARLIE, BRAVO, ALPHA (%s)" % [titles()],
	)

	check_same_shells()
	check(app.hosts.size() == 1, "Still one window, nothing merged or lost")
