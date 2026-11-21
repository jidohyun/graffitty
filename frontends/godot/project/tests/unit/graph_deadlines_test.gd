extends "res://tests/unit/test_case.gd"
const Graph := preload("res://scenes/AgentGraph.gd")

func test_expired_edges_are_displayed_without_frontend_cancellation() -> void:
	var graph := Graph.new()
	var owner := Node.new()
	var edge := {"from":"%1", "to":"%2", "from_port":"send", "to_port":"in", "send":true, "stop_at":1.0}
	var event := {"source":"%1", "target":"%2", "source_port":"send", "target_port":"in", "event_id":"pending"}
	graph.import_remote(owner, {"nodes":[{"node":"%1"},{"node":"%2"}], "edges":[edge], "queues":{"%2":[event]}})
	expect(graph.connection_expired(edge), "View can style the server's expired deadline")
	expect(graph.queues["%2"].size() == 1, "The view waits for authoritative cancellation instead of consuming a queue")
	expect(not graph.connection_expired({}), "No deadline remains active")
	graph.import_remote(owner, {"nodes":[{"node":"%1"},{"node":"%2"}], "edges":[edge], "queues":{"%2":[]}})
	expect(graph.queues["%2"].is_empty() and graph.edges.size() == 1, "Server cancellation clears the queue while retaining the visible edge")
	graph.free()
	owner.free()
