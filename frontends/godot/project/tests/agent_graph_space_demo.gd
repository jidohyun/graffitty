extends "../../../../tests/llm-e2e/replay/replay.gd"
const Layout := preload("res://scenes/WorkspaceLayout.gd")


func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var first := "%%%d" % host.active_session_id
	host.create_terminal_window(first)
	var second := "%%%d" % host.active_session_id
	host.create_terminal_window(second)
	var third := "%%%d" % host.active_session_id
	var keys := [first, second, third]
	var names := ["Planner", "Worker", "Reports"]
	var tree: Dictionary = host.workspace_layout.tab(host.workspace_layout.active).tree
	tree.physics = false
	tree.tiling = false
	for i in keys.size():
		var item: Dictionary = Layout.find(tree, keys[i])
		item.rect = Rect2(Vector2(view.size.x * (-0.375 + i * 0.65), 360 if i == 1 else 200), Vector2(view.size.x * 0.45, 470))
		var id := int(str(keys[i]).substr(1))
		await app.agent_api.dispatch(id, "window.set_title", {"title": names[i]})
		host.sessions[id].term.send_text("printf '\\033[2J\\033[H%s\\n\\nNode editing demo workspace\\nConnect terminals directly in the canvas.\\n'\r" % names[i])
	view.refresh()
	await hold(2.5)
	await camera_at_rest()
	view.show_main()
	await camera_at_rest()
	await wait(1.0)
	await say("Pinch out: terminals become nodes in the same space")
	await point_at(view.size * 0.5)
	await pinch(0.52, 1.4)
	await hold(0.8)
	var graph: Node = app.agent_api.graph
	var wires: Control = view.agent_links
	check(wires.editing, "Zooming out reveals connection ports")
	check(wires.ports.size() == 3, "Each real terminal has input and output ports")
	for key in keys:
		await graph.dispatch(int(key.substr(1)), "agent.event", {"provider": "adapter", "event": "SessionStart"})
		await graph.dispatch(int(key.substr(1)), "agent.register", {"inputs": [{"id": "in", "name": "Receive"}], "outputs": [{"id": "send", "name": "Send"}]})
	view.refresh()
	await say("Drag Planner's Send output to Worker's Receive input")
	await drag(wires.port_center(first + "/send", true), wires.port_center(second + "/in", false), 1.8)
	await wait(0.6)
	check(graph.edges.has(first + "/send>" + second + "/in"), "Dragging ports connects directly")
	await say("Hover the wire to inspect its ports and delivery status")
	var link: Dictionary = wires.links[0]
	await point_at(link.points[link.points.size() / 2])
	await hold(1.5)
	check(wires.edge_hint.visible, "Wire hover shows its description")
	await say("Connect Worker to Reports")
	await drag(wires.port_center(second + "/send", true), wires.port_center(third + "/in", false), 1.8)
	await hold(1.0)
	check(graph.edges.size() == 2, "Both connections exist without dialogs")
