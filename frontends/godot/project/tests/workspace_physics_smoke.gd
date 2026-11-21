extends "../../../../tests/llm-e2e/suites/godot/tabs-and-panes/replays/main-area-tiling.gd"
## Real workspace integration, including the actual View menu action.


func play() -> void:
	use_config("res://../../../tests/llm-e2e/suites/godot/flat-world/per-tab-camera-view.conf")
	await camera_at_rest()
	var view: Control = host.workspace_view
	var first: String = host.pane_focus
	var before := Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree)
	host.create_terminal_window(first)
	await hold(0.3)
	var second := ""
	for key in Layout.keys(host.workspace_layout.tab(host.workspace_layout.active).tree):
		if key not in before:
			second = key
	check(not second.is_empty(), "Nearby creation adds another pane")
	if second.is_empty():
		return
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	var start := Rect2(view.content_rect().position + Vector2(200, 160), Vector2(360, 240))
	for key in [first, second]:
		Layout.find(group.tree, key)["rect"] = start
	view.refresh()
	check(view.physics_enabled(), "Floating physics is enabled by default")
	await hold(7.0)
	check(not view.pane_rects[first].intersects(view.pane_rects[second]), "Real floating terminal panes separate")
	check(view.panes[first].position == view.pane_rects[first].position, "Displayed pane follows simulated position")
	check(view.pane_rects[first].size == start.size, "Physics preserves terminal dimensions")
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("/tmp/workspace-physics-settled.png")
	# Keep the pointer down: physics pins its pane and moves the other one now.
	Layout.find(group.tree, first)["rect"] = start
	Layout.find(group.tree, second)["rect"] = Rect2(start.position + Vector2(280, 0), start.size)
	view.refresh()
	await point_at(view.window_point(start.position + Vector2(70, 17)))
	await press()
	# A press alone temporarily pins a pane; an actual drag establishes the
	# persistent placement anchor whose release behavior this case checks.
	await point_at(overlay.pointer + Vector2(12, 0))
	check(view.panes[first]._dragging, "Fixture crosses the actual drag threshold")
	var held: Rect2 = view.pane_rects[first]
	var neighbour: Rect2 = view.pane_rects[second]
	await host.session_backend.connection.request_action("sync")
	await hold(0.6)
	check(view.pane_rects[first].is_equal_approx(held), "Held pane remains under pointer control: %s -> %s" % [held, view.pane_rects[first]])
	check(view.pane_rects[second].position.distance_to(neighbour.position) > 20, "Neighbours react while the mouse remains held, without pausing the simulation")
	# Dispatch the actual release: the old input debounce froze this for 600 ms.
	var at_release: Vector2 = view.pane_rects[second].position
	await release(MOUSE_BUTTON_LEFT, 0.0)
	# Release commits the final pointer position before physics resumes.
	held = view.pane_rects[first]
	await hold(0.1)
	check(view.moving.is_empty() and not view.panes[first]._pressed, "Mouse release ends the drag")
	check(view.pane_rects[second].position.distance_to(at_release) > 0.5, "Motion continues within 100 ms of the real mouse release")
	var after_release: Vector2 = view.pane_rects[second].position
	await hold(0.25)
	check(view.pane_rects[second].position.distance_to(after_release) > 0.5, "Release does not produce a short burst followed by a cutoff")
	check(view.pane_rects[first].is_equal_approx(held), "The released pane stays exactly at its chosen position: %s -> %s" % [held, view.pane_rects[first]])
	await hold(2.0)
	check(not view.is_physics_processing(), "Settled workspace stops scheduling physics ticks")
	# A new user placement takes priority over the previous one.
	var grab: Vector2 = view.window_point(view.pane_rects[second].position + Vector2(70, 17))
	await point_at(grab)
	await press()
	var chosen := Rect2(held.position + Vector2(280, 0), held.size)
	await point_at(view.window_point(chosen.position + Vector2(70, 17)))
	check(view.panes[second]._dragging, "Next placement also uses a real drag")
	await hold(0.6)
	check(view.pane_rects[second].is_equal_approx(chosen), "The next chosen pane becomes the fixed anchor: %s -> %s" % [chosen, view.pane_rects[second]])
	check(view.pane_rects[first].position.distance_to(held.position) > 20, "Previous placement yields when the new placement overlaps it")
	await release()
	await view_menu("Floating Pane Physics")
	check(not view.physics_enabled(), "View menu disables physics")
	var frozen: Dictionary = view.pane_rects.duplicate()
	await hold(1.0)
	check(view.pane_rects == frozen, "Disabled physics leaves panes exactly where they are")
	if view.pane_rects != frozen:
		print("Frozen: ", frozen, " Current: ", view.pane_rects)
	# Tiling anchors inside panes; an outside pane remains simulated.
	await view_menu("Tiling")
	var item := Layout.find(group.tree, second)
	item["stashed"] = true
	item["rect"] = Rect2(view.content_rect().end + Vector2(700, 0), start.size)
	view.refresh()
	var tile: Rect2 = view.pane_rects[first]
	var stash: Rect2 = view.pane_rects[second]
	await view_menu("Floating Pane Physics")
	await hold(7.0)
	check(view.pane_rects[first] == tile, "Physics keeps the main-area tile fixed")
	check(view.pane_rects[second] == stash, "Isolated outside panes stay where placed")
	check(not view.pane_rects[second].intersects(view.content_rect()), "Outside panes stay outside")
	# Direct interaction pins only the grabbed pane.
	item["rect"] = stash
	view.refresh()
	view.moving = second
	await hold(1.0)
	check(view.pane_rects[second] == stash, "Dragging pins the grabbed stash")
	view.moving = ""
	await view_menu("Floating Pane Physics")
	check(group.tree.get("physics", true) == false, "Opt-out is stored in the tab layout for session snapshots")
	print("WORKSPACE_PHYSICS_SMOKE_DONE")
