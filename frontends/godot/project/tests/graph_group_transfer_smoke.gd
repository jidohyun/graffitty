extends "res://tests/tab_window_session_smoke.gd"
## Real server membership plus the exact canvas preview committed on drop.

func end_drag(point: Vector2) -> void:
	# Group membership/placement fixtures construct coordinator state directly.
	app.finish_drag(point)
	await process_frame

## Carry a pane's header just past the last tab of its own bar, where a drop
## opens a new tab, and report what the bar offers.
func header_to_bar(host: Node, key: String) -> Dictionary:
	var pane: Control = host.workspace_view.panes[key]
	var rect: Rect2 = host.workspace_view.pane_rects[key]
	pane.begin_header_drag(host.workspace_view.canvas_root.get_global_transform() * (rect.position + Vector2(40, 22)))
	pane._dragging = true
	app.begin_pane_drag(host, pane, key)
	var strip: Control = host.workspace_view.tab_bar.tabs
	var last: Button = strip.buttons[host.get_tabs().back().id] if not host.get_tabs().is_empty() else null
	var at: Vector2 = last.get_global_rect().end - Vector2(-8, last.size.y * .5) if last != null else strip.get_global_rect().get_center()
	var point: Vector2 = app.screen_point(host.get_window(), at)
	pointer_position = point
	app.update_drag(point)
	return {"pane": pane, "point": point, "mode": app.drag.get("mode", -1), "hint": strip.external_drop_hint}

## Releasing a drag the bar refused must leave every tab exactly as it was.
func release_unchanged(host: Node, offer: Dictionary, members: Array, label: String) -> void:
	var tabs: Array = host.get_tabs().map(func(tab): return tab.id)
	var homes: Array = members.map(func(member): return host.workspace_layout.containing(member))
	await end_drag(offer.point)
	offer.pane.abort_drag()
	await settled(host)
	check(host.get_tabs().map(func(tab): return tab.id) == tabs, label + ": no tab is created or removed")
	check(members.map(func(member): return host.workspace_layout.containing(member)) == homes, label + ": panes stay in their tab")

func run() -> void:
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if not check_host(wrapper): return
	var host: Node = wrapper.host
	app = host.application
	app.scripted_pointer = true
	await settled(host)
	var connection: Node = host.session_backend.connection
	var first: int = host.active_session_id
	var source: int = host.workspace_layout.active
	var second_reply: Dictionary = await connection.request_action("create", {"kind": "pane", "session": first})
	var second := int(second_reply.created)
	var third_reply: Dictionary = await connection.request_action("create", {"kind": "pane", "session": first})
	var third := int(third_reply.created)
	var other_reply: Dictionary = await connection.request_action("create", {"kind": "tab"})
	var destination := int(other_reply.created)
	await settled(host)
	for id in [first, second]:
		await connection.remote_call(id, "agent.event", {"provider": "adapter", "event": "SessionStart"})
		await connection.remote_call(id, "agent.register", {"name": "Test", "inputs": [{"id": "in"}], "outputs": [{"id": "out"}]})
	var edge := {"from": "%%%d" % first, "to": "%%%d" % second, "from_port": "out", "to_port": "in"}
	var linked: Dictionary = await connection.remote_call(first, "graph.connect", edge)
	check(not linked.has("error"), "Same-tab graph connection succeeds")
	await connection.request_action("sync", {})
	await settled(host)
	host.select_workspace(source, true)
	var key := "%%%d" % first
	var peer := "%%%d" % second
	var tree: Dictionary = host.workspace_layout.tab(source).tree
	tree.tiling = false
	tree.physics = false
	Layout.find(tree, key).rect = Rect2(80, 120, 400, 300)
	Layout.find(tree, peer).rect = Rect2(650, 260, 420, 320)
	host.workspace_view.refresh()
	host.session_backend.commit_workspace(host)
	await settled(host)
	var original: Dictionary = host.workspace_view.pane_rects.duplicate(true)
	var pane: Control = host.workspace_view.panes[key]
	pane.begin_header_drag(host.workspace_view.canvas_root.get_global_transform() * (original[key].position + Vector2(40, 22)))
	pane._dragging = true
	app.begin_pane_drag(host, pane, key)
	check(app.drag.keys.size() == 2, "Drag includes the connected pair and excludes unrelated pane")
	var outside := Vector2(root.position + Vector2i(root.size.x + 150, 120))
	pointer_position = outside
	app.update_drag(outside)
	check(is_instance_valid(app.drag_preview) and is_instance_valid(app.drag_preview.group_canvas), "Floating preview carries only the connected group")
	if is_instance_valid(app.drag_preview) and is_instance_valid(app.drag_preview.group_canvas):
		var carried: Control = app.drag_preview.group_canvas.get_child(0)
		check(carried.rectangles.size() == 2 and carried.connections.size() == 1, "Floating preview shows both panes and their wire")
	host.select_workspace(destination, true)
	var target_tree: Dictionary = host.workspace_layout.tab(destination).tree
	target_tree.tiling = true
	target_tree.physics = true
	host.workspace_view.refresh()
	host.session_backend.commit_workspace(host)
	await settled(host)
	var point := Vector2(400, 280)
	var pointer: Vector2 = app.screen_point(host.get_window(), host.workspace_view.window_point(point))
	pointer_position = pointer
	app.update_drag(pointer)
	check(not app.drag.get("zone", {}).is_empty(), "Group has a destination preview")
	var plan: Dictionary = host.workspace_view.preview_plan
	check(plan.get("rectangles", {}).has(peer), "Preview includes connected pane")
	check(host.workspace_view.layout_preview.connections.size() == 1, "Preview includes connecting wire")
	if not plan.get("rectangles", {}).has(peer): quit(1); return
	var expected: Dictionary = plan.rectangles.duplicate(true)
	check(expected[peer].position - expected[key].position == original[peer].position - original[key].position, "Preview preserves pre-drag relative positions")
	await end_drag(pointer)
	deadline = Time.get_ticks_msec() + 10000
	while host.workspace_layout.containing(key) != destination and Time.get_ticks_msec() < deadline: await process_frame
	await settled(host)
	await create_timer(.4).timeout
	for member in [key, peer]:
		check(host.workspace_layout.containing(member) == destination, "Connected pane moved: " + member)
		# The dragged pane is the anchor and stays where its preview showed it.
		# The pane carried with it keeps its size and yields to the tile under
		# it, as tests/llm-e2e/suites/shared/agent-graph/tab-boundary.md says.
		var landed: Rect2 = host.workspace_view.pane_rects.get(member, Rect2())
		if member == key:
			check(landed.is_equal_approx(expected[member]), "The dragged pane lands at its preview despite destination tiling and physics")
		else:
			var tile: Rect2 = host.workspace_view.pane_rects["%%%d" % destination]
			check(landed.size.is_equal_approx(expected[member].size), "Physics preserves the carried pane's size: " + member)
			check(landed.intersection(tile).get_area() < expected[member].intersection(tile).get_area(), "The carried pane reduces its overlap with the destination tile: " + member)
	check(host.workspace_layout.containing("%%%d" % third) == source, "Unconnected pane stays behind")
	# Tab-bar drops also use the pointer-down snapshot, even if a neighbour
	# changed while the header was still moving inside its original canvas.
	var baseline: Dictionary = {key: expected[key], peer: expected[peer]}
	Layout.find(host.workspace_layout.tab(destination).tree, peer).rect.position += Vector2(75, 30)
	host.workspace_view.refresh()
	host.session_backend.commit_workspace(host)
	await settled(host)
	var Drag = preload("res://scenes/TerminalApplication.gd").DragMode
	# The pair shares its tab with that tab's own pane, so a new tab is real.
	var offer := header_to_bar(host, key)
	check(offer.mode == Drag.DOCKED and offer.hint >= 0, "The bar offers a new tab for a group that leaves a pane behind")
	app.cancel_drag()
	offer.pane.abort_drag()
	await settled(host)
	await app._dock_pane(host, host, key, host.get_tabs().size(), baseline)
	await settled(host)
	var new_tab: int = host.workspace_layout.containing(key)
	check(new_tab != destination and host.workspace_layout.containing(peer) == new_tab, "Tab-bar drop creates a tab for the entire group")
	for member in [key, peer]:
		check(host.workspace_view.pane_rects.get(member, Rect2()).is_equal_approx(baseline[member]), "New-tab drop restores pointer-down geometry: " + member)
	# Now the pair is its whole tab: a "new" tab would only replace it.
	host.select_workspace(new_tab, true)
	await settled(host)
	offer = header_to_bar(host, peer)
	check(offer.mode == Drag.BLOCKED and offer.hint < 0, "No new-tab slot for a group that fills its tab")
	await release_unchanged(host, offer, [key, peer], "Group filling its tab")
	host.select_workspace(source, true)
	await settled(host)
	var sole := "%%%d" % third
	offer = header_to_bar(host, sole)
	check(offer.mode == Drag.BLOCKED and offer.hint < 0, "No new-tab slot for a tab's only pane")
	await release_unchanged(host, offer, [sole], "Sole pane")
	check(error_watch.errors.is_empty(), "No engine errors: " + str(error_watch.errors))
	print("GRAPH_GROUP_TRANSFER failures=", JSON.stringify(failures))
	wrapper.connection.disconnect_remote()
	wrapper.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
