extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/tab-hover-merge.md


func play() -> void:
	await labelled_tabs(["ALPHA", "BRAVO", "CHARLIE"])
	await select_tab(0)

	await say("Drag ALPHA onto the middle of CHARLIE and hold still")
	await point_at(tab_grip(0))
	await press()
	await point_at(on(tab_button(2)), 1.2)
	await hold(1.0)
	check(
		selected_title() == "CHARLIE",
		"Holding over CHARLIE shows its content (%s shown)" % selected_title(),
	)
	await say("Press Escape, then release")
	await keys("escape")
	await release()
	await wait(0.6)
	check(
		titles() == ["ALPHA", "BRAVO", "CHARLIE"] and selected_title() == "ALPHA",
		"Escape restores ALPHA and the order; nothing merged (%s)" % [titles()],
	)

	await say("Drag ALPHA onto CHARLIE again, but move on before it opens")
	await point_at(tab_grip(0))
	await press()
	# Across CHARLIE and on in one quick sweep: well under the half second
	# that opens a tab, even with the pointer easing in and out.
	await point_at(on(tab_button(2)), 0.6)
	await point_at(on(tab_strip().plus, Vector2(1, 0.5)) + Vector2(80, 0), 0.25)
	await wait(0.6)
	check(selected_title() != "CHARLIE", "Moving on early does not open CHARLIE")
	await say("Return to the middle of CHARLIE and hold until it opens")
	await hold(0.4)
	await point_at(on(tab_button(tab_index("CHARLIE"))), 0.7)
	await hold(1.0)
	check(selected_title() == "CHARLIE", "Holding opens CHARLIE")
	await say("Move down into CHARLIE's content and release")
	await point_at(content(Vector2(0.5, 0.45)), 0.9)
	await wait(0.5)
	check(app.drag.get("mode") == app.DragMode.MERGE, "Content offers a merge")
	await point_at(on(tab_strip().plus, Vector2(1, 0.5)) + Vector2(80, 0), 0.4)
	check(
		host.workspace_view.preview_plan.is_empty()
		and not host.workspace_view.layout_preview.visible
		and not host.workspace_view.drop_hint.visible,
		"Moving back to the tab bar cancels the split preview",
	)
	await point_at(content(Vector2(0.5, 0.45)), 0.4)
	await release()
	await wait(0.8)
	# Regroup can outlive the visual release animation. Read the final focus
	# only after the owner's merge/layout transaction is acknowledged.
	await owner_at_rest()

	check(
		titles() == ["BRAVO", "ALPHA"]
		and host.workspace_layout.keys(host.workspace_layout.tabs[1].tree).size() == 2,
		"Two tabs remain: BRAVO, and the merged tab following focused ALPHA (%s)" % [titles()],
	)
	check(
		window("ALPHA") != null and window("ALPHA").visible and window("CHARLIE").visible,
		"CHARLIE's tab shows the ALPHA and CHARLIE windows",
	)
	check_same_shells()
