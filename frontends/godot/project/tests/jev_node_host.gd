extends SceneTree
## Isolated real graph/socket fixture. No terminals, user sessions, or model calls.
var graph = preload("res://tests/support/ServerGraph.gd").new()
var transport: RefCounted


func _initialize() -> void:
	call_deferred("start")


func start() -> void:
	root.add_child(graph)
	graph.set_process(false)
	for id in range(1, 6):
		graph.nodes["%%%d" % id] = {"provider": "adapter", "status": "idle", "title": "Worker %d" % id}
		if id >= 3: graph.register_ports("%%%d" % id, {"inputs": [{"id": "in"}], "outputs": []})
	transport = ClassDB.instantiate("AgentSocket")
	var directory := OS.get_environment("JEV_TEST_DIRECTORY")
	if not transport.start(directory.path_join("socket")):
		quit(1)
		return
	var ready := FileAccess.open(directory.path_join("ready.json"), FileAccess.WRITE)
	ready.store_string(JSON.stringify({"socket": transport.endpoint()}))
	ready.close()


func _process(_delta: float) -> bool:
	if transport != null:
		for packet in transport.poll():
			handle(packet.peer, packet.json)
	return false


func handle(peer: int, text: String) -> void:
	var request: Dictionary = JSON.parse_string(text)
	var id := int(str(request.get("token", "0")))
	var response: Dictionary
	if id < 1 or id > 5:
		response = {"error": {"message": "invalid fixture token"}}
	else:
		response = await graph.dispatch(id, str(request.method), request.params)
	response["id"] = request.id
	transport.respond(peer, JSON.stringify(response))
