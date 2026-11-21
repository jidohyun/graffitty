extends "../../tabs-and-panes/replays/main-area-tiling.gd"
const Ports := preload("res://scenes/GraphPorts.gd")
var graph: Node
var links: Control
var tools: Node
var source: String
var review: String
var other: String

func connect_to(target: String) -> String:
	var result: Dictionary = await graph.dispatch(int(source.substr(1)), "graph.connect", {"from": source, "to": target, "from_port": "send", "to_port": "receive", "send": true})
	check(result.has("result"), "Fixture wire connects")
	check(result.result.from == source and result.result.to == target, "Connection endpoints retain the real %N pane IDs")
	var key := Ports.edge_key(result.result)
	check(key == source + "/send>" + target + "/receive", "Graph socket and edge IDs use %N with port suffixes")
	var deadline := Time.get_ticks_msec() + 3000
	while not graph.edges.has(key) and Time.get_ticks_msec() < deadline: await process_frame
	check(graph.edges.has(key), "Acknowledged wire reaches the frontend topology mirror")
	host.workspace_view.refresh()
	return key

func add_dot(key: String, offset: Vector2) -> String:
	var link: Dictionary = links.links.filter(func(value): return links.link_key(value) == key)[0]
	var point: Vector2 = (link.points[0] + link.points[-1]) * 0.5 + offset
	tools.add_reroute(link, point)
	host.workspace_view.refresh()
	return tools.visual().routes[key][-1]

func disconnect_ui(key: String) -> void:
	# Pull the input socket into empty space, the current disconnect gesture.
	var edge: Dictionary = graph.edges[key]
	var socket: Vector2 = links.get_global_transform_with_canvas() * links.port_center(Ports.endpoint(edge, false), false)
	await point_at(socket)
	await press()
	await point_at(socket + Vector2(-55, -65))
	await release()
	await hold(0.2)
	host.workspace_view.refresh()
	check(not graph.edges.has(key), "Disconnect removes authoritative edge")

func empty_routes() -> void:
	check(tools.visual().routes.is_empty(), "Disconnected route records are removed")
	check(tools.visual().reroutes.is_empty(), "No orphan reroute dots remain")
	check(tools.selected.is_empty(), "Removed dots cannot remain selected")

func play() -> void:
	await camera_at_rest()
	source = host.pane_focus
	review = await add_window(source)
	other = await add_window(review, "v")
	if review.is_empty() or other.is_empty(): return
	graph = host.agent_api.graph
	var pids := {}
	for key in [source, review, other]:
		check(preload("res://scenes/PaneTargets.gd").valid(key), "The workspace and graph share a canonical %N pane identity")
		pids[key] = host.sessions[int(key.substr(1))].term.get_shell_pid()
		await graph.dispatch(int(key.substr(1)), "agent.event", {"provider": "adapter", "event": "SessionStart"})
		await graph.dispatch(int(key.substr(1)), "agent.register", {"inputs": [{"id": "receive", "name": "Receive"}], "outputs": [{"id": "send", "name": "Send"}]})
	await pinch_overview()
	links = host.workspace_view.agent_links
	tools = links.tools
	await say("Single connection: disconnect removes both reroute dots")
	var key := await connect_to(review)
	var first := add_dot(key, Vector2(-30, -55))
	var second := add_dot(key, Vector2(35, 55))
	var original: Dictionary = preload("res://scenes/session/ServerWorkspace.gd").encode_graph(tools.visual())
	tools.selected = {first: true, second: true}
	await hold(0.4)
	await disconnect_ui(key)
	empty_routes()
	await say("Undo restores the same dots; redo removes them")
	await keys("cmd+z")
	check(graph.edges.has(key) and preload("res://scenes/session/ServerWorkspace.gd").encode_graph(tools.visual()) == original, "Undo restores exact route and dot positions")
	await keys("cmd+shift+z")
	empty_routes()
	key = await connect_to(review)
	check(tools.visual().routes.is_empty(), "Reconnecting endpoints does not revive old dots")
	await disconnect_ui(key)
	await say("Shared branches: keep the used dot, remove the private one")
	key = await connect_to(review)
	var other_key := await connect_to(other)
	first = add_dot(key, Vector2(-30, -55))
	tools.begin_edit()
	tools.visual().routes[other_key] = [first]
	tools.finish_edit()
	tools.insert_reroutes([{"segment": {"from": first, "to": Ports.endpoint(graph.edges[key], false), "edges": [key]}, "position": tools.visual().reroutes[first].position + Vector2(90, 65)}])
	second = tools.visual().routes[key][-1]
	host.workspace_view.refresh()
	await disconnect_ui(key)
	check(not tools.visual().reroutes.has(second), "Private branch dot is removed")
	check(tools.visual().reroutes.has(first) and graph.edges.has(other_key), "Shared dot and remaining branch survive")
	await disconnect_ui(other_key)
	empty_routes()
	await keys("cmd+z")
	check(tools.visual().reroutes.size() == 1 and graph.edges.has(other_key), "Undo restores only the remaining shared route")
	await keys("cmd+shift+z")
	empty_routes()
	await say("External disconnect also removes reroute dots")
	key = await connect_to(review)
	first = add_dot(key, Vector2(0, -65))
	tools.selected = {first: true}
	await graph.dispatch(int(source.substr(1)), "graph.disconnect", {"from": source, "to": review, "from_port": "send", "to_port": "receive"})
	var disconnect_deadline := Time.get_ticks_msec() + 3000
	while graph.edges.has(key) and Time.get_ticks_msec() < disconnect_deadline: await process_frame
	host.workspace_view.refresh()
	empty_routes()
	key = await connect_to(review)
	check(tools.visual().routes.is_empty(), "Immediate reconnect cannot revive the removed path")
	graph.disconnect_edge(graph.edges[key])
	host.workspace_view.refresh()
	empty_routes()
	for terminal in pids:
		check(host.sessions[int(terminal.substr(1))].term.get_shell_pid() == pids[terminal], "Disconnect preserves the terminal shell")
