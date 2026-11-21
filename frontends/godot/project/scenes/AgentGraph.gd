extends Node

class RunUsage extends RefCounted:
	var count: int
	var limit: int
	var available: bool
	func _init(used := 0, maximum := 0, present := false) -> void:
		count = used
		limit = maximum
		available = present

## Presentation cache and command forwarding. The workspace server owns graph policy.
signal changed
signal message_transferred(source: String, target: String, event_id: String)
signal message_rejected(source: String, target: String, event_id: String, reason: String)
signal run_usage_changed(run_id: String)
signal default_run_limit_changed
var nodes: Dictionary = {}
var remote_owners: Dictionary[String, Node] = {}
var remote_snapshots: Dictionary = {}
var edges: Dictionary = {}
var queues: Dictionary = {}
var receipts: Array = []
var queue_log := preload("res://scenes/GraphQueueLog.gd").new()
var event_edges: Dictionary[String, String] = {}
var _core: RefCounted = ClassDB.instantiate("GraphClientCore")

func _init() -> void:
	queue_log._core = _core
const Targets := preload("res://scenes/PaneTargets.gd")
const Ports := preload("res://scenes/GraphPorts.gd")

func connection_expired(edge: Dictionary) -> bool:
	var deadline := float(edge.get("stop_at", 0.0))
	return deadline > 0.0 and deadline <= Time.get_unix_time_from_system()

func edge_id(source: String, target: String, from_port := "", to_port := "") -> String:
	return Ports.socket_id(source, from_port) + ">" + Ports.socket_id(target, to_port)

func event_edge(event: Dictionary) -> String:
	return edge_id(event.source, event.target, str(event.get("source_port", "")), str(event.get("target_port", "")))

func fail(message: String) -> Dictionary:
	return {"error": {"code": "graph_error", "message": message}}

func public_node(key: String) -> Dictionary:
	var value: Dictionary = nodes.get(key, {}).duplicate(true)
	value["node"] = key
	value["pane"] = key
	return value

func _owner_for_edge(edge: String) -> Node:
	return remote_owners.get(Ports.node_id(edge.get_slice(">", 0)))

func default_run_usage(edge: String) -> RunUsage:
	var limits: Dictionary = remote_snapshots.get(_owner_for_edge(edge), {}).get("limits", {})
	return RunUsage.new(0, int(limits.get("run_messages", 0)), limits.has("run_messages"))

func run_usage(run_id: String, edge: String) -> RunUsage:
	var usage: Dictionary = remote_snapshots.get(_owner_for_edge(edge), {}).get("runs", {}).get(run_id, {})
	return RunUsage.new(int(usage.get("count", 0)), int(usage.get("limit", 0)), bool(usage.get("available", false)))

func set_default_run_limit(limit: int, edge: String) -> Dictionary:
	return await _budget_command(edge, "graph.run.default", {"limit": limit})

func set_run_limit(run_id: String, limit: int, edge: String) -> Dictionary:
	return await _budget_command(edge, "graph.run.limit", {"run_id": run_id, "limit": limit})

func reset_run_count(run_id: String, edge: String) -> Dictionary:
	return await _budget_command(edge, "graph.run.reset", {"run_id": run_id})

func _budget_command(edge: String, method: String, params: Dictionary) -> Dictionary:
	var connection := _owner_for_edge(edge)
	if not is_instance_valid(connection): return fail("Graph server is not connected")
	var id := int(Ports.node_id(edge.get_slice(">", 0)).substr(1))
	var result: Dictionary = await connection.remote_call(id, method, params)
	if not is_instance_valid(connection) or not remote_snapshots.has(connection): return fail("Graph server disconnected")
	if not result.has("error"):
		var snapshot: Dictionary = remote_snapshots[connection].duplicate(true)
		snapshot.merge(result.result, true)
		import_remote(connection, snapshot)
	return result

func dispatch(id: int, method: String, params: Dictionary) -> Dictionary:
	var connection: Node = remote_owners.get("%%%d" % id)
	if not is_instance_valid(connection): return fail("Graph server is not connected")
	for field in ["from", "to", "node"]:
		if params.has(field) and remote_owners.get(str(params[field])) != connection:
			return fail("Choose a node on the same server workspace")
	return await connection.remote_call(id, method, params)

static func label(edge: Dictionary) -> String:
	if edge.get("turn_completed", false):
		return "Send + Turn completed" if edge.get("send", false) else "Turn completed"
	if edge.get("read", false):
		return "Read + Send" if edge.get("send", false) else "Read"
	return "Send"


func connect_nodes(params: Dictionary) -> Dictionary:
	var remote: Node = remote_owners.get(str(params.get("from", "")))
	if remote == null or remote != remote_owners.get(str(params.get("to", ""))):
		return fail("Connect nodes on the same server workspace")
	var preview: Dictionary = _core.preview_connect(remote.get_instance_id(), params)
	if preview.has("error"): return fail(str(preview.error))
	# The wire is a visual preview for undo/drag feedback. Rust normalizes it;
	# only the server assigns revisions or permits delivery.
	_sync_view(_core.view())
	changed.emit()
	_remote_edit(remote, int(str(params.from).substr(1)), "graph.connect", params)
	return preview


func disconnect_edge(edge: Dictionary) -> void:
	disconnect_nodes(edge.from, edge.to, str(edge.get("from_port", "")), str(edge.get("to_port", "")))

func disconnect_nodes(source: String, target: String, from_port := "", to_port := "") -> void:
	var connection: Node = remote_owners.get(source)
	if not is_instance_valid(connection) or remote_owners.get(target) != connection: return
	_sync_view(_core.preview_disconnect(connection.get_instance_id(), source, target, from_port, to_port))
	changed.emit()
	_remote_edit(connection, int(source.substr(1)), "graph.disconnect", {"from": source, "to": target, "from_port": from_port, "to_port": to_port})

func _remote_edit(connection: Node, id: int, method: String, params: Dictionary) -> void:
	var result: Dictionary = await connection.remote_call(id, method, params)
	if not is_instance_valid(connection) or not remote_snapshots.has(connection): return
	if result.has("error"):
		_sync_view(_core.rollback(connection.get_instance_id()))
		changed.emit()
		push_error(str(result.error.get("message", "Graph edit failed")))

func _sync_view(view: Dictionary) -> void:
	queue_log._core = _core
	nodes = view.nodes
	edges = view.edges
	queues = view.queues
	receipts = view.receipts
	event_edges.assign(view.event_edges)
	queue_log.entries = view.journal_entries
	remote_owners.clear()
	for key in view.owners:
		var connection: Object = instance_from_id(int(view.owners[key]))
		if is_instance_valid(connection): remote_owners[key] = connection

func import_remote(connection: Node, snapshot: Dictionary) -> void:
	var update: Dictionary = _core.receive(connection.get_instance_id(), snapshot)
	if update.has("error"):
		push_error(str(update.error))
		return
	if not update.changes.changed: return
	if update.snapshot == null: remote_snapshots.erase(connection)
	else: remote_snapshots[connection] = update.snapshot
	_sync_view(update.view)
	for edge in update.changes.journal_edges: queue_log.changed.emit(edge)
	for event in update.changes.transfers:
		if event.failed: message_rejected.emit(event.source, event.target, event.event_id, event.status)
		else: message_transferred.emit(event.source, event.target, event.event_id)
	for run in update.changes.runs: run_usage_changed.emit(run)
	if update.changes.limits: default_run_limit_changed.emit()
	changed.emit()
