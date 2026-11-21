extends "main-area-tiling.gd"

var expected := [true, true]
var layouts := { }


func mode(index: int) -> bool:
	return host.workspace_layout.tabs[index].tree.get("tiling", false)


func verify_tabs() -> void:
	for i in expected.size():
		await select_tab(i)
		await camera_at_rest()
		check(mode(i) == expected[i], "Tab %d independently keeps tiling %s" % [i, expected[i]])
		if expected[i]:
			check_tiles()
		if layouts.has(i):
			check(
				host.workspace_view.pane_rects.size() == layouts[i].size() and layouts[i].keys().all(func(key): return host.workspace_view.pane_rects.has(key) and host.workspace_view.pane_rects[key].is_equal_approx(layouts[i][key])),
				"Tab %d keeps its pane placement: %s -> %s" % [i, layouts[i], host.workspace_view.pane_rects],
			)


func set_default(enabled: bool) -> bool:
	host.session_backend.set_default_tiling(host, enabled)
	await wait(0.3)
	return host.application.tiling_default == enabled


func new_tab(tiled: bool) -> void:
	await open_tabs(expected.size() + 1)
	expected.append(tiled)
	await label_tab(
		expected.size() - 1,
		["ALPHA", "BETA", "GAMMA", "DELTA", "EPSILON", "ZETA"][expected.size() - 1],
	)
	await camera_at_rest()
	check(mode(expected.size() - 1) == tiled, "New tab inherits only the explicit default")
	host.create_terminal_window()
	await camera_at_rest()
	check(mode(expected.size() - 1) == tiled, "Adding a window preserves inherited mode")
	if tiled:
		check_tiles()


func play() -> void:
	use_config(get_script().resource_path.get_base_dir().path_join("../per-tab-tiling.conf"))
	await labelled_tabs(["ALPHA", "BETA"])
	check(host.application.tiling_default, "New tabs default to tiling")
	check(host.menu_entries.all(func(entry): return entry.label not in ["View::Tiling", "View::Tiling for New Tabs"]), "Tiling switches are absent from the menu")
	# Start the default stage from off even when startup defaults to tiled,
	# so both changes of the future-tab default are actually exercised.
	if not await set_default(false):
		return
	await say("Prepare distinct spaces")
	for i in 2:
		await select_tab(i)
		await view_menu("Floating Pane Physics")
		await type("echo SPACE_%d $$ {enter}" % i)
		await camera_at_rest()
		var added := await add_window(host.pane_focus, "h" if i == 0 else "v")
		if added.is_empty():
			return
		await type("echo SECOND_%d $$ {enter}" % i)
		await camera_at_rest()
		var view: Control = host.workspace_view
		var tree: Dictionary = host.workspace_layout.tabs[i].tree
		var divider: Vector2 = Layout.tile_dividers(tree.tiles, view.content_rect())[0] \
				.rect \
				.get_center()
		await drag(
			view.window_point(divider),
			view.window_point(divider + (Vector2(100, 0) if i == 0 else Vector2(0, -90))),
		)
		layouts[i] = view.pane_rects.duplicate()
	var pids := { }
	for id in host.sessions:
		pids[id] = host.sessions[id].term.get_shell_pid()
	await say("Toggle each tab independently")
	for i in [0, 1, 0, 0, 1, 0, 1]:
		await select_tab(i)
		await camera_at_rest()
		await toggle_tiling()
		expected[i] = not expected[i]
		if i == 0 and not expected[i]:
			var pane: Control = host.workspace_view.panes[host.pane_focus]
			await drag(on(pane.handle), on(pane.handle) + Vector2(45, 35))
		layouts[i] = host.workspace_view.pane_rects.duplicate()
		await verify_tabs()
	await say("Change the default for future tabs")
	if host.application.tiling_default:
		if not await set_default(false): return
	# ALPHA tiled, BETA floating, before changing either default.
	if not await set_default(true):
		return
	await verify_tabs()
	await new_tab(true)
	await toggle_tiling()
	expected[2] = false
	await new_tab(true)
	if not await set_default(false):
		return
	await new_tab(false)
	await toggle_tiling()
	expected[4] = true
	await new_tab(false)
	await say("Verify continuity and cleanup")
	await verify_tabs()
	for id in pids:
		check(
			pids[id] > 0 and host.sessions[id].term.get_shell_pid() == pids[id],
			"Original shell %d survives" % id,
		)
