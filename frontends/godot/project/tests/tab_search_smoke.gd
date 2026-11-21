extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"
var typed_into_terminal := 0

func menu_ready() -> void:
	for i in 3: await process_frame
	check(host.all_tabs_open() and host.workspace_view.tab_bar.navigation.menu.search.has_focus(),
		"Tab search opens with the text field focused")

func replace_query(value: String) -> void:
	await keys("ctrl+a")
	await keys("backspace")
	await type(value)
	for i in 3: await process_frame

func play() -> void:
	await labelled_tabs(["Backend", "Docs", "Build"])
	var first: int = host.workspace_layout.active
	var source: String = host.pane_focus
	var extra := await add_window(source, "h")
	if extra.is_empty(): return
	await app.agent_api.dispatch(int(extra.substr(1)), "window.set_title", {"title": "Database migration"})
	await host.session_backend.connection.remote_call(int(source.substr(1)), "tab.set_title", {"id": first, "title": "Backend"})
	await owner_at_rest()
	await select_tab(1)
	await camera_at_rest()
	var before: String = host.pane_focus
	host.active_terminal().keystroke.connect(func(_cell, _unicode): typed_into_terminal += 1)
	var strip: Control = host.workspace_view.tab_bar
	var menu: Control = strip.navigation.menu
	var prefix := "ctrl+a"
	await keys(prefix)
	await keys("v")
	await menu_ready()
	check(menu.list.item_count == 3, "An empty search shows tabs without pane rows")
	var strokes := typed_into_terminal
	await type("dtbsmgr")
	check(menu.list.item_count == 2 and menu.model.preferred == "pane:" + extra,
		"Fuzzy pane title search exposes its owning tab and matching pane")
	check(menu.list.rows[0].get_meta("title_label").get_parsed_text().begins_with("1:"),
		"Filtering preserves the original tab number")
	var chosen: String = menu.list.get_item_identity(menu.list.selected)
	strip._populate_tab_menu()
	check(menu.search.text == "dtbsmgr" and menu.search.has_focus() and menu.list.get_item_identity(menu.list.selected) == chosen,
		"Status refresh preserves search, focus and selection")
	await keys("up")
	check(menu.list.get_item_identity(menu.list.selected) == "tab:%d" % first, "Up selects the owning tab")
	await keys("down")
	check(menu.list.get_item_identity(menu.list.selected) == "pane:" + extra, "Down selects its matching pane")
	check(menu.search.text == "dtbsmgr" and host.pane_focus == before, "Arrow selection keeps the query and current pane unchanged")
	check(typed_into_terminal == strokes, "Search text and arrows never reach the shell")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_TEST_EVIDENCE").path_join("tab-search.png"))
	await keys("enter")
	await camera_at_rest()
	check(not menu.visible and host.workspace_layout.active == first and host.pane_focus == extra,
		"Enter switches tabs and focuses the matching pane")
	await click(on(strip.all_tabs))
	await menu_ready()
	await type("zzzzzzzzzz")
	check(menu.list.item_count == 0 and menu.empty.visible, "No-match search has an explicit empty state")
	await keys("enter")
	check(menu.visible and host.pane_focus == extra, "Enter on no matches does nothing")
	await replace_query("Docs")
	check(menu.list.item_count >= 1 and menu.list.rows[0].get_meta("title_label").get_parsed_text().begins_with("2:"), "Tab titles are searchable")
	await replace_query("")
	check(menu.list.item_count == 3 and menu.list.rows.all(func(row): return row.get_meta("kind") == "tab"),
		"Clearing the query hides all temporary pane matches")
	await keys("escape")
	check(not menu.visible and not strip.navigation.all_tabs.button_pressed, "Escape restores ordinary terminal focus")
	# Remapping uses the same public action, not a hard-coded V event handler.
	host.prefix_commands.settings.bindings.erase(KEY_V)
	host.prefix_commands.settings.bindings[KEY_G] = "ShowAllTabs"
	await keys(prefix)
	await keys("g")
	await menu_ready()
	await keys("escape")
	var commands := preload("res://scenes/CommandLineModel.gd").new()
	commands.host = host
	commands.set_text("show-all-tabs")
	check(not commands.accepted().is_empty(), "The tab search action is available from command mode")
	commands.execute(commands.accepted())
	for i in 4: await process_frame
	await menu_ready()
	await keys("escape")
