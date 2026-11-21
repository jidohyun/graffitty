extends "main-area-tiling.gd"

func controls(key: String, tiled: bool) -> void:
	var header: Control = host.workspace_view.panes[key].header
	await on_header(key, "split_right")
	check(header.has_part("split_right") and header.has_part("split_down"), "Both directional controls are available for " + key)

func directional(key: String, axis := "h") -> String:
	var view: Control = host.workspace_view
	var before := Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree)
	await click(await on_header(key, "split_right" if axis == "h" else "split_down"))
	await hold(0.1)
	var added: String = host.pane_focus
	check(added not in before and added in view.panes, "Directional icon creates a real pane in the current tab")
	return added

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	if group.tree.get("tiling", false):
		await toggle_tiling()
	if not view.physics_enabled():
		await view_menu("Floating Pane Physics")
	var first: String = host.pane_focus
	var pid: int = host.sessions[int(first.substr(1))].term.get_shell_pid()
	view.set_window_rect(first, Rect2(220, 200, 460, 300), true)
	await hold(0.3)
	await say("Floating pane: directional icons add right or below")
	await controls(first, false)
	var original: Rect2 = view.pane_rects[first]
	var second := await directional(first)
	if second == first: return
	await controls(second, false)
	check(not group.tree.get("tiling", false), "Directional creation keeps floating mode")
	check(view.pane_rects[second].position.x > original.position.x, "New pane starts close to its source")
	var start: Rect2 = view.pane_rects[second]
	await hold(3.0)
	check(view.pane_rects[second].position.distance_to(start.position) > 5 or view.pane_rects[first].position.distance_to(original.position) > 5, "Physics pushes overlapping panes apart")
	await say("Managed panes: two directional splits")
	await toggle_tiling()
	await controls(first, true)
	await controls(second, true)
	var third := await add_window(second, "v")
	if third.is_empty(): return
	check_tiles()
	await say("Outside Main: directional creation stays local and does not join the tiles")
	# Place a stash fixture; creation and its controls are the behavior under test.
	Layout.place(group.tree, third, Rect2(view.size.x + 100, 180, 460, 300), view.content_rect())
	view.refresh()
	view.inspect_pane(third)
	await hold(0.4)
	await controls(third, false)
	var tiles: Dictionary = group.tree.tiles.duplicate(true)
	var stash: Rect2 = view.pane_rects[third]
	var fourth := await directional(third, "v")
	if fourth == third: return
	check(Layout.find(group.tree, fourth).get("stashed", false), "New outside pane remains outside tiling management")
	check(group.tree.tiling and group.tree.tiles == tiles, "Outside creation preserves every managed tile")
	check(view.pane_rects[fourth].position.y > stash.position.y, "Outside creation creates beside the stash")
	# The new pane starts outside the camera; bring it into view to reach its header.
	view.inspect_pane(fourth)
	await camera_at_rest()
	await controls(fourth, false)
	check(host.sessions[int(first.substr(1))].term.get_shell_pid() == pid, "Original shell survives creation and mode changes")
