extends SceneTree
## Deadline cancellation must happen while the graph itself is idle.
const Graph := preload("res://tests/support/ServerGraph.gd")
var failures := 0


func _initialize() -> void:
	OS.set_environment(
		"XDG_CONFIG_HOME",
		OS.get_cache_dir().path_join("graph-deadline-%d" % OS.get_process_id()),
	)
	run.call_deferred()


func check(value: bool, message: String) -> void:
	print("PASS " if value else "FAIL ", message)
	if not value:
		failures += 1


func run() -> void:
	var graph := Graph.new()
	graph.nodes = { "%1": { "provider": "claude" }, "%2": { "provider": "codex" } }
	root.add_child(graph)
	graph.set_process(false)
	var params := {
		"from": "%1",
		"to": "%2",
		"send": true,
		"stop_at": Time.get_unix_time_from_system() + 0.15,
	}
	var edge: Dictionary = graph.connect_nodes(params).result
	graph.enqueue("%1", "%2", "waiting", "message")
	await create_timer(0.3).timeout
	graph.dispatch(1, "graph.list", {})
	check(
		graph.queues["%2"].is_empty(),
		"The owner expires queued messages independently of frontend execution",
	)
	check(
		graph.connection_expired(edge) and graph.edges.size() == 1,
		"The expired connection remains visible",
	)
	params.stop_at = Time.get_unix_time_from_system() + 0.1
	graph.connect_nodes(params)
	params.stop_at = 0
	graph.connect_nodes(params)
	graph.enqueue("%1", "%2", "resumed", "message")
	await create_timer(0.2).timeout
	graph.dispatch(1, "graph.list", {})
	check(
		graph.queues["%2"].size() == 1,
		"Clearing a rearmed deadline prevents its old timeout from cancelling new work",
	)
	graph.free()
	print("GRAPH_DEADLINE_PASS" if failures == 0 else "GRAPH_DEADLINE_FAIL")
	quit(failures)
