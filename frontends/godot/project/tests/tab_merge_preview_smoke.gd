extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"
## Whole-tab merge previews must stay visible and preserve untiled pane sizes.

func drag_into(target: int, point: Vector2) -> void:
	await select_tab(0)
	await owner_at_rest()
	await point_at(tab_grip(0))
	await press()
	await point_at(on(tab_button(1)))
	await hold(0.8)
	check(host.workspace_layout.active == target, "Hover opens the destination tab")
	await point_at(host.workspace_view.window_point(point))
	await hold(0.2)


func screenshot(name: String) -> void:
	var directory := OS.get_environment("GRAFFITTY_TEST_EVIDENCE")
	if directory.is_empty() or DisplayServer.get_name() == "headless": return
	overlay.hide()
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(directory.path_join(name + ".png"))
	overlay.show()


func play() -> void:
	await labelled_tabs(["SOURCE", "TARGET"])
	await select_tab(0)
	await owner_at_rest()
	var source: int = host.workspace_layout.active
	var incoming: String = host.pane_focus
	var created: Dictionary = await host.session_backend.connection.request_action("create", {"kind": "pane", "session": int(incoming.substr(1))})
	await owner_at_rest()
	var companion := "%%%d" % int(created.created)
	var source_tree: Dictionary = host.workspace_layout.tab(source).tree
	source_tree.tiling = false
	source_tree.physics = false
	Layout.find(source_tree, incoming).rect = Rect2(120, 140, 540, 360)
	Layout.find(source_tree, companion).rect = Rect2(720, 200, 380, 260)
	host.focus_pane(incoming)
	host.workspace_view.refresh()
	host.session_backend.commit_workspace(host)
	await owner_at_rest()
	var source_rect: Rect2 = host.workspace_view.pane_rects[incoming]
	var companion_rect: Rect2 = host.workspace_view.pane_rects[companion]
	var source_grid: Vector2i = host.active_terminal().get_grid_size()
	var source_pid: int = host.active_terminal().get_shell_pid()
	await select_tab(1)
	await owner_at_rest()
	var target: int = host.workspace_layout.active
	var existing: String = host.pane_focus
	var view: Control = host.workspace_view
	var area: Rect2 = view.content_rect()
	view.overview = true
	view.navigation_zoom = 0.45
	view.navigation_center = area.get_center()
	view._apply_navigation()
	await owner_at_rest()
	for mode in ["tile", "floating", "stash"]:
		await select_tab(1)
		await owner_at_rest()
		var tree: Dictionary = host.workspace_layout.tab(target).tree
		tree.tiling = mode != "floating"
		tree.physics = false
		view.refresh()
		host.session_backend.commit_workspace(host)
		await owner_at_rest()
		var destination_before: Rect2 = view.pane_rects[existing]
		var grid_before: Vector2i = host.active_terminal().get_grid_size()
		var point := area.get_center() if mode != "stash" else Vector2(area.end.x + 100, area.get_center().y)
		await drag_into(target, point)
		check(app.drag.get("mode") == app.DragMode.MERGE, "%s: content is a merge target" % mode)
		check(view.layout_preview.visible, "%s: placement preview is visible before release" % mode)
		check(view.layout_preview.rectangles.has(incoming), "%s: preview outlines the arriving pane" % mode)
		check(view.layout_preview.rectangles.has(companion), "%s: preview includes every pane in the tab" % mode)
		check(view.pane_rects[existing].is_equal_approx(destination_before), "%s: hover preserves destination size" % mode)
		check(host.active_terminal().get_grid_size() == grid_before, "%s: hover preserves the destination PTY grid" % mode)
		check(host.workspace_layout.containing(incoming) == source, "%s: hover preserves ownership" % mode)
		if mode != "tile":
			var proposed: Rect2 = view.preview_plan.get("rectangles", {}).get(incoming, Rect2())
			check(proposed.size.is_equal_approx(source_rect.size), "%s: proposal preserves the source pane size" % mode)
			var other: Rect2 = view.preview_plan.get("rectangles", {}).get(companion, Rect2())
			check(other.size.is_equal_approx(companion_rect.size), "%s: proposal preserves different pane sizes" % mode)
			check((other.position - proposed.position).is_equal_approx(companion_rect.position - source_rect.position), "%s: proposal preserves the arrangement of incoming panes" % mode)
		await screenshot(mode + "-preview")
		if mode != "stash":
			await keys("Escape")
			await release()
			await owner_at_rest()
			check(host.workspace_layout.containing(incoming) == source and host.get_tabs().size() == 2, "%s: cancellation preserves both tabs" % mode)
		else:
			var expected: Dictionary = view.preview_plan.get("rectangles", {}).duplicate()
			await release()
			await owner_at_rest()
			check(host.get_tabs().size() == 1 and host.workspace_layout.containing(incoming) == target, "Drop merges the source tab")
			check(view.pane_rects[incoming].size.is_equal_approx(source_rect.size), "Drop preserves the arriving pane's size")
			check(view.pane_rects[companion].size.is_equal_approx(companion_rect.size), "Drop preserves the companion pane's size")
			check(view.pane_rects[existing].is_equal_approx(destination_before), "Stash drop preserves the destination pane")
			for key in expected:
				check(view.pane_rects[key].is_equal_approx(expected[key]), "Drop matches the preview for " + key)
			var terminal: Node = host.sessions[int(incoming.substr(1))].term
			check(terminal.get_grid_size() == source_grid, "Stash transfer preserves the source PTY grid")
			check(terminal.get_shell_pid() == source_pid, "Transfer preserves the running shell")
			await screenshot("stash-committed")
