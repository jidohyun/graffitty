extends "main-area-tiling.gd"


func hover_pane(key: String, point: Vector2) -> void:
	var view: Control = host.workspace_view
	await point_at(on(view.panes[key].handle))
	await press()
	await point_at(view.window_point(point), 1.2)
	await hold(0.3)


func matches_preview(proposed: Dictionary) -> void:
	var view: Control = host.workspace_view
	if proposed.keys().any(func(key): return not view.pane_rects[key].is_equal_approx(proposed[key])):
		print("PREVIEW_OWNER_STATE ", JSON.stringify({"pending": host.session_backend.pending_edit,
			"queued": host.session_backend.queued_edits, "local": host.workspace_layout.tab(host.workspace_layout.active),
			"owner": host.session_backend.connection.topology.get("workspace_state", {})}))
	for key in proposed:
		check(
			view.pane_rects[key].is_equal_approx(proposed[key]),
			"%s lands exactly in its previewed rectangle (expected %s, actual %s)" % [key, proposed[key], view.pane_rects[key]],
		)
	check(not view.layout_preview.visible, "Release clears the preview")


func play() -> void:
	await label_tab(0, "LAYOUT")
	await camera_at_rest()
	var view: Control = host.workspace_view
	var alpha: String = host.pane_focus
	# This case compares the entire committed layout, including old stashes.
	# Collision response intentionally moves neighbours after a drop and has
	# its own physics coverage; keep this placement transaction deterministic.
	if view.physics_enabled(): view.toggle_physics()
	await owner_at_rest()
	await toggle_tiling()
	var beta := await add_window(alpha)
	var gamma := await add_window(beta)
	if beta.is_empty() or gamma.is_empty():
		return
	await camera_at_rest()
	var tab_id: int = host.workspace_layout.active
	var original: Dictionary = host.workspace_layout.tab(tab_id).tree.tiles.duplicate(true)
	var before: Dictionary = view.pane_rects.duplicate()
	var destination: Vector2 = before[alpha].position + Vector2(
		before[alpha].size.x * 0.5,
		before[alpha].size.y - 40,
	)
	await say("Hold the drag over the bottom edge: preview every resulting tile")
	await hover_pane(gamma, destination)
	check(view.layout_preview.visible, "The preview is visible before releasing the mouse")
	check(
		not view.preview_plan.is_empty() and view.preview_plan.edge == "bottom",
		"The preview selects the bottom split",
	)
	check(
		host.workspace_layout.tab(tab_id).tree.tiles == original,
		"Hover leaves the live split tree unchanged",
	)
	check(
		view.pane_rects[alpha] == before[alpha] and view.pane_rects[beta] == before[beta],
		"Other live panes do not resize during hover",
	)
	await wait(1.0)
	await say("Escape cancels the preview")
	await keys("Escape")
	await release()
	await hold(0.3)
	check(
		not view.layout_preview.visible and host.workspace_layout.tab(tab_id).tree.tiles == original,
		"Cancel clears the preview and keeps the original layout",
	)
	await say("Repeat and release: the preview becomes the layout")
	await hover_pane(gamma, destination)
	var expected: Dictionary = view.preview_plan.get("rectangles", { }).duplicate()
	check(not expected.is_empty(), "Release has a complete proposed layout")
	await wait(1.0)
	await release()
	await hold(0.3)
	matches_preview(expected)
	await say("Bring a pane from another tab; preview the merge before release")
	await open_tabs(2)
	await camera_at_rest()
	var incoming: String = host.pane_focus
	await point_at(on(view.panes[incoming].handle))
	await press()
	await point_at(tab_grip(0), 1.0)
	await hold(0.7)
	await point_at(view.window_point(view.content_rect().get_center()), 1.0)
	await hold(0.3)
	check(view.layout_preview.visible, "Cross-tab merge has a layout preview")
	check(
		host.workspace_layout.containing(incoming) != tab_id,
		"Hover does not transfer pane ownership",
	)
	expected = view.preview_plan.get("rectangles", { }).duplicate()
	check(expected.has(incoming), "Merge preview includes the incoming pane")
	await wait(1.0)
	await release()
	await hold(0.5)
	matches_preview(expected)
	check(
		host.workspace_layout.containing(incoming) == tab_id,
		"Release transfers ownership to the previewed tab",
	)
	await say("Overview: preview a stash and the remaining tiles before release")
	await pinch_overview()
	await hold(0.5)
	var outside := Vector2(view.size.x + 160, view.size.y * 0.5)
	await hover_pane(incoming, outside)
	check(not view.layout_preview.visible and view.layout_preview.rectangles.is_empty(), "Leaving the main area clears the tile highlight")
	check(view.preview_plan.get("label", "") == "Stash", "Outside the border previews a stash")
	var tree: Dictionary = host.workspace_layout.tab(tab_id).tree
	check(
		not Layout.find(tree, incoming).get("stashed", false),
		"Hover keeps live stash membership",
	)
	expected = view.preview_plan.get("rectangles", { }).duplicate()
	await wait(1.0)
	await release()
	await hold(0.3)
	matches_preview(expected)
	check(Layout.find(tree, incoming).get("stashed", false), "Release commits the previewed stash")
	await say("Drag a whole tab: preview both incoming windows together")
	await view_menu("Fit to Main Area")
	await open_tabs(2)
	await camera_at_rest()
	var first: String = host.pane_focus
	var second := await add_window(first)
	if second.is_empty():
		return
	await camera_at_rest()
	await point_at(tab_grip(1))
	await press()
	await point_at(on(tab_button(0)), 1.0)
	await hold(0.7)
	await point_at(view.window_point(view.content_rect().get_center()), 1.0)
	await hold(0.3)
	expected = view.preview_plan.get("rectangles", { }).duplicate()
	check(
		view.layout_preview.visible and expected.has(first) and expected.has(second),
		"Tab merge previews both incoming windows",
	)
	check(host.get_tabs().size() == 2, "Tab merge hover preserves both tabs")
	await wait(1.0)
	await release()
	await hold(0.4)
	matches_preview(expected)
	check(host.get_tabs().size() == 1, "Release commits the whole-tab merge")
