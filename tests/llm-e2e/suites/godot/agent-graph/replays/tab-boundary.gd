extends "../../tabs-and-panes/replays/main-area-tiling.gd"
## Fixtures use the owner API; every transfer/cancel uses real pointer/key events.
var members: Array[String] = []
var pids := {}
var graph: Node

func tab_position(id: int) -> int:
	for i in host.get_tabs().size():
		if int(host.get_tabs()[i].id) == id: return i
	return -1

func connect_request(from: String, to: String, muted := false) -> Dictionary:
	return await graph.dispatch(int(members[0].substr(1)), "graph.connect", {"from": from, "to": to, "from_port": "out", "to_port": "in", "muted": muted})

func stable_shells() -> void:
	for key in pids:
		check(host.sessions[int(key.substr(1))].term.get_shell_pid() == pids[key], "Same shell and pane identity: " + key)

func play() -> void:
	await say("Prepare a connected group")
	await owner_at_rest()
	graph = host.agent_api.graph
	var connection: Node = host.session_backend.connection
	var source: int = host.workspace_layout.active
	members.append(host.pane_focus)
	for i in 3:
		var reply: Dictionary = await connection.request_action("create", {"kind": "pane", "session": int(members[0].substr(1))})
		members.append("%%%d" % int(reply.created))
	var created: Dictionary = await connection.request_action("create", {"kind": "tab"})
	var destination := int(created.created)
	var target := "%%%d" % destination
	await owner_at_rest()
	var all_keys: Array = members + [target]
	var names := ["ALPHA", "BRAVO", "CHARLIE", "UNRELATED", "TARGET"]
	for i in all_keys.size():
		var id := int(str(all_keys[i]).substr(1))
		await host.agent_api.dispatch(id, "window.set_title", {"title": names[i]})
		pids[all_keys[i]] = host.sessions[id].term.get_shell_pid()
		await graph.dispatch(id, "agent.event", {"provider": "adapter", "event": "SessionStart"})
		await graph.dispatch(id, "agent.register", {"name": names[i], "inputs": [{"id": "in"}], "outputs": [{"id": "out"}]})
	check((await connect_request(members[0], members[1])).has("result"), "Connect ALPHA to BRAVO")
	check((await connect_request(members[2], members[1], true)).has("result"), "Paused incoming link also belongs to the group")
	await owner_at_rest()
	var saved_edges: Dictionary = graph.edges.duplicate(true)
	await say("Reject cross-tab connections")
	for pair in [[members[0], target], [target, members[0]]]:
		for muted in [false, true]:
			var denied := await connect_request(pair[0], pair[1], muted)
			check(denied.has("error") and "one tab" in str(denied), "Owner rejects cross-tab connection, including paused links")
	check(graph.edges == saved_edges, "Rejected requests do not mutate the graph")
	await select_tab(tab_position(destination))
	var target_tree: Dictionary = host.workspace_layout.tab(destination).tree
	target_tree.tiling = true
	target_tree.physics = true
	host.workspace_view.refresh()
	host.session_backend.commit_workspace(host)
	await owner_at_rest()
	await select_tab(tab_position(source))
	var tree: Dictionary = host.workspace_layout.tab(source).tree
	tree.tiling = false
	tree.physics = false
	var rects := [Rect2(60, 100, 360, 240), Rect2(490, 140, 400, 260), Rect2(260, 500, 380, 280), Rect2(950, 450, 360, 240)]
	for i in members.size(): Layout.find(tree, members[i]).rect = rects[i]
	host.workspace_view.refresh()
	host.session_backend.commit_workspace(host)
	await owner_at_rest()
	await pinch_overview()
	await camera_at_rest()
	var original: Dictionary = host.workspace_view.pane_rects.duplicate(true)
	await say("Preview and move the connected group")
	await point_at(on(handle("BRAVO")))
	await press()
	await point_at(overlay.pointer + Vector2(30, 20), 0.4)
	await point_at(on(tab_button(tab_position(destination))), 0.8)
	await hold(1.0)
	await point_at(content(Vector2(0.55, 0.5)), 0.8)
	await hold(0.3)
	var plan: Dictionary = host.workspace_view.preview_plan
	check(plan.get("incoming", []).size() == 3, "Preview carries exactly the connected component")
	check(host.workspace_view.layout_preview.connections.size() == 2, "Preview displays both wires")
	if not plan.get("rectangles", {}).has(members[2]): return
	var expected: Dictionary = plan.rectangles.duplicate(true)
	var offset: Vector2 = expected[members[1]].position - original[members[1]].position
	for key in members.slice(0, 3):
		check((expected[key].position - original[key].position).is_equal_approx(offset) and expected[key].size == original[key].size, "One translation preserves pre-drag geometry: " + key)
	await hold(0.8)
	await release()
	await owner_at_rest()
	await panes_at_rest()
	for key in members.slice(0, 3):
		check(host.workspace_layout.containing(key) == destination, "Connected pane moves: " + key)
		var actual: Rect2 = host.workspace_view.pane_rects.get(key, Rect2())
		check(actual.size.is_equal_approx(expected[key].size), "Physics preserves each carried pane’s size: " + key)
		if key == members[1]:
			check(actual.is_equal_approx(expected[key]), "Dragged anchor lands at its preview")
		else:
			var tile: Rect2 = host.workspace_view.pane_rects[target]
			check(actual.intersection(tile).get_area() < expected[key].intersection(tile).get_area(), "Floating group member reduces its overlap with the destination tile: " + key)
	check(host.workspace_layout.containing(members[3]) == source, "Unrelated pane stays behind")
	check(graph.edges == saved_edges, "Connections survive the group move")
	check((await connect_request(members[0], members[3])).has("error"), "Moved graph cannot connect back across the tab boundary")
	stable_shells()
	await say("Move to a new tab and cancel a move")
	var baseline: Dictionary = host.workspace_view.pane_rects.duplicate(true)
	await point_at(on(handle("BRAVO")))
	await press()
	await point_at(on(tab_strip().plus, Vector2(1, 0.5)) + Vector2(90, 0), 1.0)
	await hold(0.4)
	check("group" in str(app.drag.get("title", "")), "Tab placeholder identifies the connected group")
	await release()
	await owner_at_rest()
	await panes_at_rest()
	var new_tab: int = host.workspace_layout.containing(members[1])
	check(new_tab != destination, "Group receives a new tab")
	for key in members.slice(0, 3):
		check(host.workspace_layout.containing(key) == new_tab and host.workspace_view.pane_rects.get(key, Rect2()).is_equal_approx(baseline[key]), "New tab preserves group geometry: " + key)
	check(host.workspace_layout.containing(target) == destination, "TARGET stays behind")
	await point_at(on(handle("BRAVO")))
	await press()
	await point_at(on(tab_button(tab_position(source))), 0.8)
	await hold(1.0)
	await point_at(content(Vector2(0.5, 0.5)), 0.6)
	await hold(0.3)
	await keys("escape")
	await release()
	await owner_at_rest()
	check(app.drag.is_empty(), "Escape clears the group preview")
	await select_tab(tab_position(new_tab))
	for key in members.slice(0, 3):
		check(host.workspace_layout.containing(key) == new_tab and host.workspace_view.pane_rects.get(key, Rect2()).is_equal_approx(baseline[key]), "Cancel preserves group membership and geometry: " + key)
	check(graph.edges == saved_edges, "Cancel preserves both connections")
	stable_shells()
