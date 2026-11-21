extends "res://tests/unit/test_case.gd"
const Graph := preload("res://scenes/AgentGraph.gd")

class Owner extends Node:
	var calls: Array = []
	var response := {"result": {"ok": true}}
	func remote_call(id: int, method: String, params: Dictionary) -> Dictionary:
		calls.append({"id": id, "method": method, "params": params})
		return response

func snapshot(limit := 17) -> Dictionary:
	return {"nodes": [{"node": "%1", "provider": "codex"}, {"node": "%2", "provider": "codex"}], "edges": [], "queues": {}, "receipts": [], "limits": {"pending_per_node": 7, "run_messages": limit}, "runs": {}}

func test_unowned_nodes_never_start_a_local_graph() -> void:
	var graph: Node = Graph.new()
	graph.nodes = {"%1": {"provider": "codex"}, "%2": {"provider": "codex"}}
	expect(graph.dispatch(1, "graph.send", {"to": "%2", "text": "hello"}).has("error"), "Missing owner fails rather than enqueuing locally")
	expect(graph.connect_nodes({"from": "%1", "to": "%2", "send": true}).has("error"), "An unowned connection cannot become authoritative")
	expect(graph.queues.is_empty() and graph.edges.is_empty(), "No fallback queue or edge is created")
	graph.free()

func test_requests_are_forwarded_and_cross_owner_targets_are_rejected() -> void:
	var graph: Node = Graph.new()
	var owner := Owner.new()
	graph.import_remote(owner, snapshot())
	var params := {"to": "%2", "text": "hello"}
	expect(graph.dispatch(1, "graph.send", params).has("result"), "Owner receives the send")
	expect(owner.calls == [{"id": 1, "method": "graph.send", "params": params}], "The owning connection receives the original command")
	expect(graph.queues.is_empty(), "Forwarding never queues locally")
	var other := Owner.new()
	graph.remote_owners["%2"] = other
	expect(graph.dispatch(1, "graph.send", params).has("error") and owner.calls.size() == 1, "Cross-workspace targets fail before transport")
	graph.free()
	owner.free()
	other.free()

func test_budget_controls_use_the_selected_server_and_its_reported_limits() -> void:
	var graph: Node = Graph.new()
	var first := Owner.new()
	var second := Owner.new()
	graph.import_remote(first, snapshot(17))
	var another := snapshot(23)
	another.nodes = [{"node": "%3", "provider": "codex"}]
	graph.import_remote(second, another)
	expect(graph.default_run_usage("%1/send>%2/in").limit == 17, "Limit comes from the first server")
	expect(graph.default_run_usage("%3/send>%3/in").limit == 23, "Another server retains its own limit")
	first.response = {"result": {"limits": {"pending_per_node": 7, "run_messages": 5}, "runs": {}}}
	graph.set_default_run_limit(5, "%1/send>%2/in")
	expect(first.calls[0].method == "graph.run.default" and second.calls.is_empty(), "Only the selected server receives the edit")
	expect(graph.default_run_usage("%1/send>%2/in").limit == 5, "Acknowledged server value updates the UI")
	graph.import_remote(first, {})
	expect(not graph.default_run_usage("%1/send>%2/in").available, "Disconnect disables budget controls")
	expect(graph.dispatch(1, "graph.list", {}).has("error"), "Disconnect never activates a fallback engine")
	graph.free()
	first.free()
	second.free()

func test_failed_preview_restores_the_last_server_snapshot() -> void:
	expected_errors.append("server rejected connection")
	var graph: Node = Graph.new()
	var owner := Owner.new()
	graph.import_remote(owner, snapshot())
	owner.response = {"error": {"message": "server rejected connection"}}
	graph.connect_nodes({"from": "%1", "to": "%2", "send": true})
	expect(graph.edges.is_empty() and owner.calls.size() == 1, "Server rejection removes the tentative wire")
	graph.free()
	owner.free()

func test_native_receiver_preserves_integer_metadata_and_rejects_partial_graphs() -> void:
	var protocol: RefCounted = ClassDB.instantiate("RemoteClientCore")
	var decoded: Dictionary = protocol.decode_message('{"type":"ack","request":9007199254740993}'.to_utf8_buffer())
	expect(decoded.message.request is int and decoded.message.request == 9007199254740993, "Wire integers reach Godot without a float conversion")
	var core: RefCounted = ClassDB.instantiate("GraphClientCore")
	var received: Dictionary = core.receive(1, snapshot())
	expect(received.changes.changed, "Rust accepts the initial graph")
	var unchanged: Dictionary = core.receive(1, snapshot())
	expect(not unchanged.changes.changed and unchanged.view == null and unchanged.snapshot == null, "Identical snapshots do not serialize a redundant graph view")
	expect(core.view() == received.view, "Skipping the redundant result preserves the complete graph")
	var invalid: Dictionary = core.receive(1, {"nodes": [{"node": "%1", "provider": 42}]})
	expect(invalid.has("error") and core.view() == received.view, "A malformed update leaves the last complete graph intact")


func test_decoded_topology_cache_is_immutable_and_validated() -> void:
	var protocol: RefCounted = ClassDB.instantiate("RemoteClientCore")
	var wire := {"type": "topology", "graph": snapshot(), "workspace_state": {"revision": 7, "layout": {"label": "owner"}}, "terminal_font": {"family": "test"}}
	var first: Dictionary = protocol.decode_message(JSON.stringify(wire).to_utf8_buffer())
	expect(first.message.graph.is_read_only() and first.message.graph.nodes.is_read_only() and first.message.graph.nodes[0].is_read_only(), "Shared graph containers are recursively immutable")
	expect(first.message.workspace_state.layout.is_read_only() and first.message.terminal_font.is_read_only(), "Shared layout and font containers are immutable")
	var editable: Dictionary = first.message.duplicate(true)
	editable.graph.nodes[0].provider = "mutated"
	editable.workspace_state.layout.label = "mutated"
	editable.terminal_font.family = "mutated"
	var again: Dictionary = protocol.decode_message(JSON.stringify(wire).to_utf8_buffer())
	expect(again.message.graph.nodes[0].provider == "codex" and again.message.workspace_state.layout.label == "owner" and again.message.terminal_font.family == "test", "Caller edits cannot mutate any cached decoded section")
	wire.graph.nodes[0].provider = 42
	expect(protocol.decode_message(JSON.stringify(wire).to_utf8_buffer()).has("error"), "Cached topology never bypasses graph validation")
	wire.graph = snapshot(23)
	wire.workspace_state.revision = 8
	var changed: Dictionary = protocol.decode_message(JSON.stringify(wire).to_utf8_buffer())
	expect(changed.message.graph.limits.run_messages == 23 and changed.message.workspace_state.revision == 8, "Changed content replaces the cached section immediately")
