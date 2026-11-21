extends "res://scenes/AgentGraph.gd"
## Rendering fixtures use the real Rust graph authority in an isolated process.
## Helpers only translate test operations into RPCs; there is no graph policy here.
class Connection extends Node:
	var graph: Node
	var stream := StreamPeerTCP.new()
	var pid := -1
	var directory := ""
	func start() -> void:
		directory = OS.get_cache_dir().path_join("graph-fixture-" + Crypto.new().generate_random_bytes(8).hex_encode())
		DirAccess.make_dir_recursive_absolute(directory)
		var executable := OS.get_environment("GRAFFITTY_GRAPH_FIXTURE")
		if executable.is_empty():
			executable = ProjectSettings.globalize_path("res://../../../target/debug/examples/graph_fixture")
			if OS.get_name() == "Windows": executable += ".exe"
		assert(FileAccess.file_exists(executable), "Build: cargo build -p graffitty-workspace-core --example graph_fixture")
		pid = OS.create_process(executable, [directory])
		var deadline := Time.get_ticks_msec() + 5000
		while not FileAccess.file_exists(directory.path_join("ready.json")) and Time.get_ticks_msec() < deadline:
			OS.delay_msec(1)
		assert(FileAccess.file_exists(directory.path_join("ready.json")), "Rust graph fixture did not start")
		var ready: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("ready.json")))
		stream.connect_to_host("127.0.0.1", int(ready.port))
		while stream.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
			stream.poll()
			OS.delay_msec(1)
		assert(stream.get_status() == StreamPeerTCP.STATUS_CONNECTED)
		stream.set_no_delay(true)
	func remote_call(id: int, method: String, params: Dictionary) -> Dictionary:
		if pid < 0: start()
		var bytes := JSON.stringify({"id": id, "method": method, "params": params, "nodes": graph.nodes}).to_utf8_buffer()
		stream.put_u32(bytes.size())
		stream.put_data(bytes)
		var result: Array = stream.get_data(stream.get_u32())
		assert(result[0] == OK, "Fixture response failed")
		var response: Dictionary = JSON.parse_string(result[1].get_string_from_utf8())
		graph.import_remote(self, response.snapshot)
		response.erase("snapshot")
		return response
	func _notification(what: int) -> void:
		if what != NOTIFICATION_PREDELETE: return
		stream.disconnect_from_host()
		if pid > 0 and OS.is_process_running(pid): OS.kill(pid)
		if not directory.is_empty():
			DirAccess.remove_absolute(directory.path_join("ready.json"))
			DirAccess.remove_absolute(directory)

var connection := Connection.new()

func _init() -> void:
	connection.graph = self
	add_child(connection)

func _prepare() -> void:
	for key in nodes: remote_owners[key] = connection

func connect_nodes(params: Dictionary) -> Dictionary:
	_prepare()
	# Tests wait for the real authority rather than testing optimistic previews.
	return connection.remote_call(int(str(params.from).substr(1)), "graph.connect", params)

func dispatch(id: int, method: String, params: Dictionary) -> Dictionary:
	_prepare()
	return connection.remote_call(id, method, params)

func register_ports(key: String, manifest: Dictionary) -> Dictionary:
	return dispatch(int(key.substr(1)), "agent.register", manifest)

func emit_output(key: String, params: Dictionary) -> Dictionary:
	return dispatch(int(key.substr(1)), "graph.emit", params)

func enqueue(source: String, target: String, text: String, _type: String, run_id := "", outcome := "", _from_port := "", _to_port := "") -> Dictionary:
	return dispatch(int(source.substr(1)), "graph.send", {"to": target, "text": text, "run_id": run_id, "outcome": outcome})

func progress(target: String, params: Dictionary) -> Dictionary:
	return dispatch(int(target.substr(1)), "graph.progress", params.merged({"status": "pending"}))

func ack(target: String, id: String, status: String) -> void:
	dispatch(int(target.substr(1)), "graph.ack", {"event_id": id, "status": status})

func lifecycle(key: String, params: Dictionary) -> Dictionary:
	return dispatch(int(key.substr(1)), "agent.event", params)

func _edge(edge: String) -> String:
	return edge if not edge.is_empty() else str(edges.keys()[0])

func run_usage(run_id: String, edge := "") -> RunUsage:
	return super.run_usage(run_id, _edge(edge))

func run_limit(run_id: String) -> int:
	return int(run_usage(run_id).limit)

func set_default_run_limit(limit: int, edge := "") -> Dictionary:
	return await super.set_default_run_limit(limit, _edge(edge))

func set_run_limit(run_id: String, limit: int, edge := "") -> Dictionary:
	return await super.set_run_limit(run_id, limit, _edge(edge))

func reset_run_count(run_id: String, edge := "") -> Dictionary:
	return await super.reset_run_count(run_id, _edge(edge))

var default_run_limit: int:
	get: return int(default_run_usage(_edge("")).limit)

var runs: Dictionary:
	get:
		var result := {}
		for key in remote_snapshots.get(connection, {}).get("runs", {}): result[key] = remote_snapshots[connection].runs[key].count
		return result
