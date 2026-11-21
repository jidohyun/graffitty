extends "res://tests/unit/test_case.gd"
const Backend := preload("res://scenes/session/RemoteSessionBackend.gd")
const Workspace := preload("res://scenes/session/ServerWorkspace.gd")
class Transport extends Node:
	signal acknowledged(message: Dictionary)
	signal state_changed(message: String)
	signal changed
	var connected := true
	var topology: Dictionary = {}
	var sent: Array[Dictionary] = []
	var server_fonts := {"ready": true}
	func wire_id(id: int) -> int: return id
	func send_action(_kind: String, _id: int, values: Dictionary) -> int:
		sent.append(values.duplicate(true))
		return 40 + sent.size()
class Host extends Node:
	var layout_transaction := false
	var current_plugin := "bistro"
	var application := {"checkpoints":{"importing":false}}
	var workspace_layout := {"active":1,"tabs":[{"id":1,"focused":"%1","tree":{"windows":[{"pane":"%1","rect":Rect2(8,42,1000,700)}]}}]}
func fixture() -> Dictionary:
	var host := Host.new()
	var transport := Transport.new()
	transport.topology = {"authoritative_layout":true,"workspace_revision":1,"workspace_state":{"layout":{"tabs":{"1":Workspace.encode_tab(host.workspace_layout.tabs[0])}},"tabs":{"1":{"world":"flat","area":[0,34,1024,734]}},"active":1,"order":[1]}}
	var backend := Backend.new(transport)
	return {"host":host,"transport":transport,"backend":backend}
func test_world_choice_is_local_even_with_legacy_owner_metadata() -> void:
	var f := fixture()
	f.backend.commit_workspace(f.host)
	expect(f.transport.sent.is_empty() and not f.backend.work_pending(), "Choosing a world creates no owner edit")
	f.host.current_plugin = "flat-2d"
	f.backend.commit_workspace(f.host)
	expect(f.transport.sent.is_empty(), "Changing the world again remains entirely local")
	f.host.free(); f.transport.free()

func revision_conflict(f: Dictionary) -> void:
	f.transport.topology.workspace_revision += 1
	f.backend._workspace_ack({"type": "error", "request": f.backend.pending_edit,
		"message": "Workspace revision conflict: expected 1, current 2",
		"workspace_state": f.transport.topology.workspace_state})

func test_stale_activation_keeps_queued_drop_placement() -> void:
	var f := fixture()
	# Activation of the intermediate transferred tab is already in flight.
	f.backend.pending_edit = 40
	var pane: Dictionary = f.host.workspace_layout.tabs[0].tree.windows[0]
	pane.rect.position = Vector2(740, 443)
	pane.stashed = true
	f.backend.commit_workspace(f.host)
	revision_conflict(f)
	expect(f.transport.sent.size() == 1, "Rejected activation still sends the queued drop")
	if not f.transport.sent.is_empty():
		var placed: Dictionary = f.transport.sent[0].edit.layout.windows[0]
		expect(placed.rect[0] == 740 and placed.rect[1] == 443 and placed.stashed,
			"The exact preview position and stash classification survive the conflict")
	f.host.free(); f.transport.free()

func test_layout_revision_retry_keeps_latest_queued_placement() -> void:
	var f := fixture()
	var pane: Dictionary = f.host.workspace_layout.tabs[0].tree.windows[0]
	pane.rect.position.x = 500
	f.backend.commit_workspace(f.host)
	pane.rect.position.x = 740
	f.backend.commit_workspace(f.host)
	revision_conflict(f)
	expect(f.transport.sent.size() == 2, "Unrelated owner revision retries the pending layout")
	if f.transport.sent.size() == 2:
		expect(f.transport.sent[1].edit.layout.windows[0].rect[0] == 740,
			"Retry rebases the newest gesture against the rejected operation's original base")
	f.host.free(); f.transport.free()

func test_layout_revision_retry_rejects_competing_geometry() -> void:
	var f := fixture()
	f.host.workspace_layout.tabs[0].tree.windows[0].rect.position.x = 740
	f.backend.commit_workspace(f.host)
	f.transport.topology.workspace_state.layout.tabs["1"].windows[0].rect[0] = 300
	revision_conflict(f)
	expect(f.transport.sent.size() == 1 and not f.backend.work_pending(),
		"A conflicting owner placement is never overwritten by an automatic retry")
	f.host.free(); f.transport.free()

func test_layout_ack_does_not_change_the_local_world_or_send_it_to_owner() -> void:
	var f := fixture()
	f.host.workspace_layout.tabs[0].tree.windows[0].rect.size.x = 640
	f.backend.commit_workspace(f.host)
	expect(not f.transport.sent[0].edit.settings.has("world"), "Layout edits exclude the frontend world")
	f.host.current_plugin = "flat-2d"
	f.backend.commit_workspace(f.host)
	f.transport.topology.workspace_state.layout.tabs["1"] = f.transport.sent[0].edit.layout.duplicate(true)
	f.backend._workspace_ack({"type":"ack","request":41})
	expect(f.host.current_plugin == "flat-2d", "An older layout acknowledgement cannot change the selected renderer")
	for message in f.transport.sent:
		expect(not message.edit.settings.has("world"), "Subsequent edits also omit legacy world metadata")
	f.host.free(); f.transport.free()

func test_cancelled_geometry_is_an_explicit_reversal_of_in_flight_and_queued_resizes() -> void:
	var f := fixture()
	f.host.current_plugin = "flat"
	var pane: Dictionary = f.host.workspace_layout.tabs[0].tree.windows[0]
	var original: Rect2 = pane.rect
	pane.rect.size.x = 640
	f.backend.commit_workspace(f.host)
	var accepted: Dictionary = f.transport.sent[0].edit.layout.duplicate(true)
	pane.rect.size.x = 500
	f.backend.commit_workspace(f.host)
	pane.rect = original
	f.backend.commit_workspace(f.host)
	f.transport.topology.workspace_state.layout.tabs["1"] = accepted
	f.backend._workspace_ack({"type":"ack","request":41})
	expect(f.transport.sent.size() == 2, "Cancelling to an older canonical rectangle remains a queued edit")
	expect(f.transport.sent[1].edit.layout.windows[0].rect == [8.0,42.0,1000.0,700.0], "The cancellation reverses the accepted resize instead of becoming a no-op during rebasing")
	f.host.free(); f.transport.free()

func test_layout_barrier_ignores_unrelated_pane_operations() -> void:
	var f := fixture()
	f.backend.pending_operations[999] = true # An unrelated operation can outlive the layout.
	var completion := {"passed": false}
	f.backend.queued_edits["barrier:1"] = {"op": "barrier", "completion": completion}
	f.backend._send_workspace_edit()
	expect(completion.passed and f.backend.work_pending(), "Filetree's layout barrier passes while unrelated work remains pending")
	expect(f.transport.sent.is_empty(), "A local barrier does not invent a server edit")
	f.host.free(); f.transport.free()

func test_layout_barrier_waits_for_prior_ack_but_not_new_geometry() -> void:
	var f := fixture()
	f.host.workspace_layout.tabs[0].tree.windows[0].rect.position.x = 500
	f.backend.commit_workspace(f.host)
	var completion := {"passed": false}
	f.backend.queued_edits["barrier:1"] = {"op": "barrier", "completion": completion}
	f.backend._send_workspace_edit()
	expect(not completion.passed, "Filetree cannot overtake the earlier layout edit")
	f.host.workspace_layout.tabs[0].tree.windows[0].rect.position.x = 600
	f.backend.commit_workspace(f.host)
	f.transport.topology.workspace_state.layout.tabs["1"] = f.transport.sent[0].edit.layout.duplicate(true)
	f.backend._workspace_ack({"type":"ack", "request":41})
	expect(completion.passed and f.backend.work_pending(), "Later physics edits do not starve the already queued filetree action")
	f.host.free(); f.transport.free()

func test_graph_geometry_round_trips_and_maps_federated_endpoints() -> void:
	var graph := {"routes": {"%1/out>%2/in": ["bend"]}, "reroutes": {"bend": {"position": Vector2(330, -20)}}}
	var wire := Workspace.encode_graph(graph)
	expect(Workspace.decode_graph(wire) == graph, "Canvas positions survive the wire representation")
	var mapped: Dictionary = Workspace.map_value(wire, func(id): return id + 100)
	expect(mapped.routes.has("%101/out>%102/in"), "Federated graph route keys map both endpoints")
	expect(mapped.reroutes.has("bend"), "Reroute IDs remain stable across clients")

func test_final_graph_commit_preserves_other_clients_different_node_move() -> void:
	var f := fixture()
	var original := {"routes": {"%1/out>%1/in": ["a", "b"]}, "reroutes": {"a": {"position": Vector2.ZERO}, "b": {"position": Vector2.ZERO}}}
	var group: Dictionary = f.host.workspace_layout.tabs[0]
	group.graph_visual = original.duplicate(true)
	f.transport.topology.workspace_state.layout.tabs["1"].graph_visual = Workspace.encode_graph(original)
	# The other client commits b while our local drag of a is still held.
	f.transport.topology.workspace_state.layout.tabs["1"].graph_visual.reroutes.b.position = [300, 400]
	group.graph_visual.reroutes.a.position = Vector2(100, 200)
	group._graph_base = original
	f.backend.commit_workspace(f.host)
	expect(f.transport.sent.size() == 1, "Release sends one graph edit")
	if not f.transport.sent.is_empty():
		var graph: Dictionary = f.transport.sent[0].edit.layout.graph_visual
		expect(graph.reroutes.a.position == [100.0, 200.0], "The local final position is committed")
		expect(graph.reroutes.b.position == [300.0, 400.0], "A concurrent different-node move is retained")
	f.host.free(); f.transport.free()

class GraphView extends Node:
	var agent_links: Node
class GraphHost extends Host:
	var workspace_view: Node

func test_graph_drag_preview_is_not_sent_by_incidental_commit() -> void:
	var f := fixture()
	var host := GraphHost.new()
	host.workspace_layout = f.host.workspace_layout
	f.host.free()
	var view := GraphView.new()
	var overlay := preload("res://scenes/AgentGraphOverlay.gd").new()
	view.agent_links = overlay
	# Use the actual tool type to exercise the same gesture snapshot guard.
	var group: Dictionary = host.workspace_layout.tabs[0]
	var original := {"routes": {"%1/out>%1/in": ["a"]}, "reroutes": {"a": {"position": Vector2.ZERO}}}
	group.graph_visual = original.duplicate(true)
	f.transport.topology.workspace_state.layout.tabs["1"].graph_visual = Workspace.encode_graph(original)
	overlay.tools.tab_id = 1
	overlay.tools.before = {"visual": original.duplicate(true)}
	host.workspace_view = view
	for index in 20:
		group.graph_visual.reroutes.a.position = Vector2(index * 10, 50)
		f.backend.commit_workspace(host)
	expect(f.transport.sent.is_empty(), "Twenty drag samples cause no workspace messages")
	overlay.tools.before.clear()
	group._graph_base = original
	f.backend.commit_workspace(host)
	expect(f.transport.sent.size() == 1, "Releasing publishes exactly one final edit")
	host.free(); view.free(); overlay.free(); f.transport.free()

class ResizeView extends GraphView:
	var resizing := false
	func resizing_window() -> bool: return resizing

func test_pane_resize_preview_is_not_sent_by_incidental_commit() -> void:
	var f := fixture()
	var host := GraphHost.new()
	host.workspace_layout = f.host.workspace_layout
	f.host.free()
	var view := ResizeView.new()
	host.workspace_view = view
	var window: Dictionary = host.workspace_layout.tabs[0].tree.windows[0]
	var original: Rect2 = window.rect
	# A phone's terminal resize reply can trigger a metadata commit mid-drag.
	view.resizing = true
	window.rect = Rect2(original.position, original.size + Vector2(30, 30))
	f.backend.commit_workspace(host)
	expect(f.transport.sent.is_empty(), "An incidental commit during an edge drag publishes no preview")
	# A pinch cancellation restores the rectangle the owner already has.
	view.resizing = false
	window.rect = original
	f.backend.commit_workspace(host)
	expect(f.transport.sent.is_empty(), "A cancelled edge drag leaves nothing to publish")
	window.rect = Rect2(original.position, original.size + Vector2(30, 30))
	f.backend.commit_workspace(host)
	expect(f.transport.sent.size() == 1, "Releasing an edge drag publishes its final rectangle")
	host.free(); view.free(); f.transport.free()

func test_federation_commits_to_owning_transport_with_its_revision() -> void:
	var f := fixture()
	var federation := preload("res://scenes/remote/FederatedConnection.gd").new()
	federation.connections.append(f.transport)
	federation.owners[1] = f.transport
	federation.connected = true
	var backend := Backend.new(federation)
	f.host.workspace_layout.tabs[0].tree.windows[0].rect.position = Vector2(500, 300)
	backend.commit_workspace(f.host)
	expect(f.transport.sent.size() == 1, "Federated pane moves reach their server")
	if not f.transport.sent.is_empty():
		expect(f.transport.sent[0].expected_revision == 1, "Revision belongs to the owning transport")
		expect(f.transport.sent[0].edit.layout.windows[0].rect[0] == 500, "Final node position is shared")
	f.host.free(); f.transport.free(); federation.free()

func test_federation_preserves_each_servers_canonical_layout() -> void:
	var f := fixture()
	f.transport.topology.tabs = [{"id": 1, "title": "One", "layout": {}}]
	f.transport.topology.panes = [{"id": 1, "tab": 1}]
	var federation := preload("res://scenes/remote/FederatedConnection.gd").new()
	federation.connections.append(f.transport)
	federation.labels[f.transport] = "Server"
	federation._merge()
	expect(federation.topology.tabs[0].canonical_layout == f.transport.topology.workspace_state.layout.tabs["1"], "Combined clients receive the owning server's layout")
	expect(federation.topology.panes[0].authoritative_layout, "Grid changes cannot replace shared pane geometry")
	f.host.free(); f.transport.free(); federation.free()
