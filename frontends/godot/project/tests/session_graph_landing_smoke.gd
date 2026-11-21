extends "res://tests/session_landing_smoke.gd"
## Off-canvas graph chrome must be present before the live-view handoff.

func prepare(host: Node, name: String, offset: float) -> void:
	await super.prepare(host, name, offset)
	var view: Control = host.workspace_view
	if view.panes.size() == 1:
		host.create_terminal_window(host.pane_focus)
		check(await until(func(): return view.panes.size() == 2 and host.active_terminal() != null), "Two graph panes in " + name)
		await create_timer(.3).timeout
	var keys: Array = view.panes.keys()
	var graph: Node = host.agent_api.graph
	graph.set_process(false)
	for key in keys:
		await graph.dispatch(int(key.substr(1)), "agent.event", {"provider":"claude", "event":"SessionStart", "integrated":true})
	await graph.dispatch(int(keys[0].substr(1)), "graph.connect", {"from":keys[0], "to":keys[1], "turn_completed":true})
	var group: Dictionary = host.workspace_layout.tab(host.workspace_layout.active)
	group.tree["tiling"] = false
	for index in keys.size():
		var pane: Dictionary = Layout.find(group.tree, keys[index])
		pane["rect"] = Rect2(offset + index * 1000, 180, 650, 700)
		pane["stashed"] = false
		pane["graph_floating"] = true
	view.overview = true
	view.navigation_center = Vector2(offset + 825, 480)
	view.navigation_zoom = .55
	view.refresh()
	view._apply_navigation()
	host.session_backend.commit_workspace(host)
	await create_timer(.5).timeout
	view.save_navigation()
