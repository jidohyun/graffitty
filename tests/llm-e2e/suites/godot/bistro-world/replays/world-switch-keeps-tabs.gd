extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/bistro-world/world-switch-keeps-tabs.md


## Everything a person arranged: tabs, their names and windows, where the
## windows are, which has the keyboard, and the shells behind them.
func arrangement() -> Dictionary:
	var tabs := []
	for group in host.workspace_layout.tabs:
		var windows := { }
		for key in host.workspace_layout.keys(group.tree):
			windows[key] = host.workspace_layout.find(group.tree, key).get("rect")
		tabs.append({ "title": group.get("title", ""), "focused": group.focused, "windows": windows })
	var shells := { }
	for id in host.sessions:
		shells[id] = host.sessions[id].term.get_shell_pid()
	return {
		"titles": titles(),
		"selected": selected_title(),
		"keyboard": host.pane_focus,
		"tabs": tabs,
		"shells": shells,
	}


## What differs between two arrangements, for the report.
func changes(before: Dictionary, after: Dictionary) -> String:
	var different: Array[String] = []
	for name in before:
		if before[name] != after.get(name):
			different.append("%s: %s, was %s" % [name, after.get(name), before[name]])
	return "; ".join(different)


func check_kept(before: Dictionary, label: String) -> void:
	var now := arrangement()
	check(now.titles == before.titles, "%s: the same tabs, and no new ones (%s)" % [label, now.titles])
	check(now == before, "%s: every tab, window, name, shell and the keyboard stay as they were%s" % [label, "" if now == before else " - " + changes(before, now)])
	var shown: Dictionary = host.sessions.get(int(host.pane_focus.substr(1)), { })
	check(not shown.is_empty() and host.world.term == shown.term, "%s: the world shows the window with the keyboard" % label)


func play() -> void:
	await labelled_tabs(["ALPHA", "BRAVO", "CHARLIE", "DELTA"])
	await say("Merge BRAVO into ALPHA, then move the windows apart")
	await merge_tab("BRAVO", "ALPHA")
	var view: Control = host.workspace_view
	await drag(on(handle("BRAVO")), on(handle("BRAVO")) + Vector2(view.size.x * 0.3, view.size.y * 0.15), 1.0)
	await say("Name the tab PAIR, and move DELTA to the front")
	await app.agent_api.dispatch(terminal_id("ALPHA"), "tab.set_title", { "title": "PAIR" })
	# Setup, not the test: tab-reorder drags tabs.
	host.move_session(int(host.get_tabs()[tab_index("DELTA")].id), 0)
	# The tabs slide to their new order before anyone clicks one.
	await hold(0.8)
	await say("Open PAIR again and click inside BRAVO so it has the keyboard")
	await select_tab(tab_index("PAIR"))
	await click(visible_point(window("BRAVO").body))
	await camera_at_rest()
	await panes_at_rest()
	var before := arrangement()
	var pair: Dictionary = host.workspace_layout.tab(host.workspace_layout.containing(window("ALPHA").key))
	check(
		before.titles == ["DELTA", "PAIR", "CHARLIE"] and host.workspace_layout.keys(pair.tree).size() == 2
		and before.keyboard == window("BRAVO").key,
		"Setup: DELTA first, PAIR holding ALPHA and BRAVO, BRAVO with the keyboard (%s)" % [before.titles],
	)

	if not await open_bistro():
		return
	check_kept(before, "In Bistro")

	await say("Open a new tab with the + button")
	var world: Node = host.world
	# Tabs exchange content on the wall in view; they do not travel between
	# Bistro's places.
	var viewed: Node = world.surfaces[world.active]
	var places := places_in_use().size()
	await click(on(tab_strip().plus))
	await owner_at_rest()
	await wait_landed()
	check(titles().size() == before.titles.size() + 1 and host.get_tabs()[-1].active, "The new tab opens, last and selected (%s)" % [titles()])
	check(shown_on(viewed), "It is shown on the wall already in view, and the camera stays there")
	check(places_in_use().size() == places + 1, "The new tab has a place in Bistro")

	await say("Move BRAVO out of PAIR into a tab of its own")
	await select_tab(tab_index("PAIR"))
	await wait_landed()
	check(shown_on(viewed), "PAIR is shown on the same wall")
	places = places_in_use().size()
	await app.move_pane(host, host, window("BRAVO").key, -1, "", "right")
	await wait_landed()
	check(selected_title() == "BRAVO" and shown_on(viewed), "BRAVO's new tab is shown on the wall already in view, and the camera stays there")
	check(places_in_use().size() == places + 1, "BRAVO's new tab has a place in Bistro")
	await panes_at_rest()
	var with_new := arrangement()

	await say("Choose View > World > Flat")
	overlay.key("View › World › Flat")
	host.switch_world("")
	_stay_awake()
	await wait_landed()
	check_kept(with_new, "Back in the flat world")


## The selected tab's own terminal is on `surface`, with the camera at rest
## on that surface's view.
func shown_on(surface: Node) -> bool:
	var world: Node = host.world
	var shown: Dictionary = host.sessions.get(int(host.pane_focus.substr(1)), { })
	return (
		world.surfaces[world.active] == surface and not shown.is_empty() and world.term == shown.term
		and int(surface.session_id) == world._first_terminal(host.workspace_layout.tab(host.workspace_layout.active))
		and landed()
	)


## Where the open tabs stand in the world.
func places_in_use() -> Array:
	var world: Node = host.world
	var result := []
	for group in host.workspace_layout.tabs:
		var place: int = world._surface_for_session(world._first_terminal(group))
		if place >= 0:
			result.append(world.surfaces[place].global_transform.origin)
	return result
