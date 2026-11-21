extends "../../../../replay/replay.gd"
## Replays tests/llm-e2e/suites/shared/tabs-and-panes/pane-header-reachable.md


## The part of a window's drag handle inside the frame, in window pixels.
func handle_in_frame(title: String) -> Rect2:
	var view: Control = host.workspace_view
	var pane: Control = window(title)
	var grip := Rect2(view.pane_rects[pane.key].position + pane.handle.position, pane.handle.size)
	var visible: Rect2 = view._foreground_rect()
	var frame := Rect2(view.canvas_point_at(visible.position), view.canvas_point_at(visible.end) - view.canvas_point_at(visible.position))
	var inside := grip.intersection(frame)
	return Rect2(
		view.window_point(inside.position),
		view.window_point(inside.end) - view.window_point(inside.position),
	)


func play() -> void:
	# This regression exercises floating window clamping, not tiled placement.
	if host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		host.workspace_view.toggle_tiling()
	await say("Name the window ALPHA")
	await label_tab(0, "ALPHA")
	await camera_at_rest()
	var view: Control = host.workspace_view
	var key: String = window("ALPHA").key
	# This case exercises a floating header, independent of startup tiling.
	if host.workspace_layout.tab(host.workspace_layout.active).tree.get("tiling", false):
		view.toggle_tiling()
	await camera_at_rest()

	await say("Drag the ALPHA handle up until it is just below the tab bar")
	await drag(
		on(handle("ALPHA")),
		Vector2(on(handle("ALPHA")).x, view.get_global_rect().position.y + view._foreground_rect().position.y + 4),
		1.0,
	)
	await wait(0.4)
	check(
		absf(view.view_point(view.pane_rects[key].position).y - view._foreground_rect().position.y) < 0.01,
		"The window's top stops at the tab bar; its header stays whole (rect %s, visible %s, main %s)" % [view.pane_rects[key], view._foreground_rect(), view.main_frame()],
	)

	await say("Drag the handle onto the tab bar, then back down without releasing")
	await point_at(on(handle("ALPHA")))
	await press()
	await point_at(on(tab_strip().plus, Vector2(1, 0.5)) + Vector2(90, 0), 0.9)
	await wait(0.5)
	await point_at(content(Vector2(0.4, 0.35)), 0.9)
	await wait(0.3)
	await release()
	await wait(0.5)
	check(host.get_tabs().size() == 1, "Coming back from the bar adds no tab")

	var size := root.get_visible_rect().size
	for edge in [
		["left", Vector2(4, size.y * 0.5)],
		["right", Vector2(size.x - 4, size.y * 0.5)],
		["bottom", Vector2(size.x * 0.5, size.y - 4)],
	]:
		await say("Drag the window to the %s edge and let go" % edge[0])
		var grip := handle_in_frame("ALPHA")
		await drag(grip.get_center(), edge[1], 1.0)
		await wait(0.4)
		grip = handle_in_frame("ALPHA")
		check(
			grip.size.x >= 20.0,
			"At the %s edge a stretch of the handle stays inside the frame (%.0f px)"
			% [edge[0], grip.size.x],
		)
		await say("Grab what shows of the handle and bring the window back")
		await drag(grip.get_center(), content(Vector2(0.35, 0.3)), 1.0)
		await wait(0.4)
		check(
			view.pane_rects[key].get_center().distance_to(view.size * 0.5)
			< view.size.length() * 0.4,
			"The window follows the handle back from the %s edge" % edge[0],
		)

	var visible: Rect2 = view.viewport_content_rect()
	var center := visible.get_center()
	await say("An overflowing window does not scroll unless the cursor reaches an edge")
	view.set_window_rect(key, Rect2(center - Vector2(200, 150), visible.size))
	view.show_main()
	await camera_at_rest()
	var stationary: Vector2 = view.navigation_center
	await point_at(on(handle("ALPHA"), Vector2(.2, .5)))
	await press()
	await point_at(view.get_global_transform_with_canvas() * center, .3)
	await hold(.8)
	check(view.view_point(view.pane_rects[key].end).x > visible.end.x, "The dragged window extends beyond the right edge")
	check(view.navigation_center.is_equal_approx(stationary), "An interior cursor never pans an offscreen window")
	await release()
	for edge in [
		["right", Vector2(visible.end.x - 4, center.y), 0, 1, 1.0],
		["left", Vector2(visible.position.x + 4, center.y), 0, -1, 1.0],
		["bottom", Vector2(center.x, visible.end.y - 4), 1, 1, 1.5],
		["top", Vector2(center.x, visible.position.y + 4), 1, -1, 0.7],
	]:
		await say("Hold a dragged window at the %s edge" % edge[0])
		# Independent starting geometry makes the old Overview cutoff reproducible.
		view.set_window_rect(key, Rect2(center - Vector2(240, 150), Vector2(480, 300)))
		view.show_main()
		await camera_at_rest()
		check(not view.boundary.visible, "%s: exact Main framing hides its outline" % edge[0])
		if edge[4] != 1.0:
			await point_at(view.get_global_transform_with_canvas() * center)
			await pinch(edge[4])
			await camera_at_rest()
		var region: Rect2 = view.overview_region()
		var before: Vector2 = view.navigation_center
		var zoom: float = view.navigation_zoom
		await point_at(on(handle("ALPHA")))
		await press()
		await point_at(view.get_global_transform_with_canvas() * edge[1], 0.6)
		await hold(0.1)
		check(view.navigation_center.is_equal_approx(before), "%s: a brief edge visit does not pan" % edge[0])
		await hold(.4)
		var early: Vector2 = view.navigation_center
		await hold(.4)
		var later: Vector2 = view.navigation_center
		check((early - before).length() > 0 and (later - early).length() > (early - before).length() * 2, "%s: scrolling starts gently and accelerates while held" % edge[0])
		await hold(.7)
		check(view.overview and is_equal_approx(view.navigation_zoom, zoom), "%s: edge hold pans without zooming" % edge[0])
		check(view.boundary.visible, "%s: panning shows the Main outline, including at unchanged or greater zoom" % edge[0])
		check((view.navigation_center[edge[2]] - before[edge[2]]) * edge[3] > 200, "%s: a stationary pointer keeps panning outward" % edge[0])
		await hold(4.0)
		var corner: Vector2 = view.canvas_point_at(visible.end if edge[3] > 0 else visible.position)
		var limit: Vector2 = region.end if edge[3] > 0 else region.position
		check((corner[edge[2]] - limit[edge[2]]) * edge[3] > 300, "%s: pan continues beyond the old Overview cutoff" % edge[0])
		var grip := handle_in_frame("ALPHA")
		check(grip.size.x >= 20 and grip.size.y > 0, "%s: the handle remains grabbable beyond the old cutoff" % edge[0])
		var header_top: Vector2 = view.view_point(view.pane_rects[key].position)
		check(header_top.y >= visible.position.y - 1 and header_top.y <= visible.end.y - view.HEADER_HEIGHT + 1, "%s: the header remains inside the view" % edge[0])
		await release()
		var stopped: Vector2 = view.navigation_center
		await hold(0.4)
		check(view.navigation_center.is_equal_approx(stopped), "%s: release stops panning" % edge[0])
		check(not view.panes[key].is_processing(), "%s: release disables the edge-scroll callback" % edge[0])
	check(host.get_tabs().size() == 1, "Panning at the edges adds no tab")

	await say("Leaving the edge, transfers, and Escape stop scrolling")
	view.set_window_rect(key, Rect2(center - Vector2(240, 150), Vector2(480, 300)))
	view.show_main()
	await camera_at_rest()
	var original: Rect2 = view.pane_rects[key]
	var right: Vector2 = view.get_global_transform_with_canvas() * Vector2(visible.end.x - 4, center.y)
	await point_at(on(handle("ALPHA")))
	await press()
	await point_at(right, 0.6)
	await hold(0.6)
	check(view.overview, "Panning is active before leaving the edge")
	await point_at(view.get_global_transform_with_canvas() * center, 0.2)
	var stopped: Vector2 = view.navigation_center
	await hold(0.4)
	check(view.navigation_center.is_equal_approx(stopped), "Moving inside stops scrolling with the button still held")
	await point_at(on(tab_strip().plus) + Vector2(90, 0), 0.2)
	stopped = view.navigation_center
	await hold(0.4)
	check(view.navigation_center.is_equal_approx(stopped), "Tab-bar transfers do not edge-scroll the source")
	await point_at(right, 0.2)
	await hold(0.1)
	check(view.navigation_center.is_equal_approx(stopped), "Returning from a transfer waits for a fresh dwell")
	await hold(0.6)
	check(view.navigation_center.x > stopped.x, "Edge scrolling resumes after returning from a transfer")
	await keys("escape")
	stopped = view.navigation_center
	await hold(0.4)
	check(view.navigation_center.is_equal_approx(stopped), "Escape stops scrolling")
	check(view.pane_rects[key].is_equal_approx(original), "Escape restores the window's original position")
	check(not view.panes[key].is_processing(), "Idle panes do not keep an edge-scroll callback running")
	await release()

	await say("A tiled window can also be dragged beyond Main without zooming out")
	view.show_main()
	view.toggle_tiling()
	await camera_at_rest()
	await point_at(on(handle("ALPHA")))
	await press()
	await point_at(right, 0.6)
	# Rendering can stall while the full-size tile changes its crop. The pan
	# intentionally never catches up with a jump; wait for the spatial result.
	for step in 12:
		await hold(.5)
		if view.overview and view.pane_rects[key].position.x > view.content_rect().end.x:
			break
	check(view.overview and view.pane_rects[key].position.x > view.content_rect().end.x, "Edge scrolling carries a tiled window outside Main (rect %s, main %s)" % [view.pane_rects[key], view.content_rect()])
	await release()
	await owner_at_rest()
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	check(host.workspace_layout.find(tree, key).get("stashed", false), "Release commits the tiled window as a reachable stash")
