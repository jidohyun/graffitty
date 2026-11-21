extends "../../../../replay/replay.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")

func exercise_browser_physics(browser: Node) -> void:
	var view: Control = host.workspace_view
	var browser_key := "%%%d" % browser.session_id
	var owner_key := "%%%d" % browser.owner_id
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	group.tree["physics"] = false
	view.wake_pane_physics()
	var origin: Vector2 = view.content_rect().position + Vector2(100, 100)
	for anchor in [owner_key, browser_key]:
		group = host.workspace_layout.tab(host.workspace_layout.active)
		group.tree["physics"] = false
		Layout.find(group.tree, owner_key).rect = Rect2(origin, Vector2(360, 260))
		Layout.find(group.tree, browser_key).rect = Rect2(origin + Vector2(240, 0), Vector2(360, 260))
		group.tree["physics_anchor"] = anchor
		view.refresh()
		host.session_backend.commit_workspace(host)
		await owner_at_rest()
		var before: Dictionary = view.pane_rects.duplicate()
		var moving: String = browser_key if anchor == owner_key else owner_key
		view.pane_physics.reset()
		view.toggle_physics()
		await hold(.8)
		check(view.pane_rects[anchor].is_equal_approx(before[anchor]), "The placed pane stays anchored, including Chromium")
		check(view.pane_rects[moving].position.distance_to(before[moving].position) > 15, "Terminal and owned Chromium push each other independently")
		check(view.pane_rects[moving].size == before[moving].size, "Repulsion preserves pane size")
		# The owner echoes each physics commit; the view glides from where the pane
		# was drawn (animate_shared_move), so compare with that animation applied.
		var shown: Vector2 = view.pane_rects[moving].position
		if view._remote_move_tab == host.workspace_layout.active:
			shown += Vector2(view._remote_move_offsets.get(moving, Vector2.ZERO)) * view._remote_move_weight
		check(view.panes[moving].position.is_equal_approx(shown), "Visible content and header follow the repelled pane")
		await hold(2.0)
		check(not view.pane_rects[owner_key].intersects(view.pane_rects[browser_key]), "Linked browser and terminal separate on contact")
	check(host.chromiums[browser.session_id] == browser and browser.page_tabs.size() == 10, "Motion preserves the live browser and its tabs")
	(await screen_image()).save_png(evidence_path("chromium-pane-repulsion.png"))

func wait_browser(browser: Node, count: int) -> void:
	var deadline := Time.get_ticks_msec() + 20000
	while browser.page_tabs.size() != count and Time.get_ticks_msec() < deadline: await process_frame
	check(browser.page_tabs.size() == count, "Browser reports requested tab count")
	await create_timer(.25).timeout

func play() -> void:
	await open_tabs(2)
	var browser: Node = await host.create_chromium_session("about:blank")
	if not check(browser != null, "Create a real about:blank browser pane"): return
	await wait_browser(browser, 1)
	var browser_key := "%%%d" % browser.session_id
	var browser_tab: int = host.workspace_layout.containing(browser_key)
	var first_tab: int = host.get_tabs()[0].id
	for path in ["", "flat-2d"]:
		for tab in host.get_tabs():
			host.select_workspace(tab.id, true)
			check(host.switch_world(path), "Set renderer for browser tab transition")
			host.session_backend.commit_workspace(host)
			await owner_at_rest()
		host.select_workspace(browser_tab, true)
		host.focus_pane(browser_key)
		for effect in ["scatter", "push_pull"]:
			host.set_tab_transition_effect(effect)
			host.select_workspace(first_tab, true)
			await camera_at_rest()
			await click(tab_grip(1))
			check(host.pane_focus == browser_key, "Switch preserves browser focus")
			check(host.world.tab_fx_t >= 0.0, "about:blank workspace animates in " + path + " / " + effect)
			check(host.world.surfaces[host.world.active].session_id == host.world._first_terminal(host.workspace_layout.tab(browser_tab)), "Browser workspace navigates its own sheet")
			await camera_at_rest()
			await click(tab_grip(0))
			check(host.world.tab_fx_t >= 0.0, "Leaving browser workspace also animates")
			await camera_at_rest()
			host.select_workspace(browser_tab, true)
			host.focus_pane(browser_key)
	var chrome: Control = host.workspace_view.panes[browser_key].chrome
	for count in range(2, 11):
		await click(on(chrome.tabs.plus))
		await wait_browser(browser, count)
		var plus: Rect2 = chrome.tabs.plus.get_global_rect()
		check(chrome.tab_frame.get_global_rect().encloses(plus), "Plus stays visible with %d browser tabs" % count)
		check(chrome.tabs.plus.get_parent() != chrome.tabs.row, "Plus is outside clipped row")
	for value in [0, 50000, 0]:
		chrome.tabs.scroll_horizontal = value
		await process_frame
		check(chrome.tab_frame.get_global_rect().encloses(chrome.tabs.plus.get_global_rect()), "Scrolling never hides plus")
	(await screen_image()).save_png(evidence_path("chromium-overflow-plus.png"))
	await exercise_browser_physics(browser)
