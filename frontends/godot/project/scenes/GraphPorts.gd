extends RefCounted
## Stable socket identities; display names and colours never affect wiring.

static func socket_id(node: String, port := "") -> String:
	return node if port.is_empty() else node + "/" + port

static func node_id(socket: String) -> String:
	return socket.get_slice("/", 0)

static func port_id(socket: String) -> String:
	return socket.get_slice("/", 1) if "/" in socket else ""

static func endpoint(edge: Dictionary, output: bool) -> String:
	return socket_id(edge.from if output else edge.to, str(edge.get("from_port" if output else "to_port", "")))

static func edge_key(edge: Dictionary) -> String:
	return endpoint(edge, true) + ">" + endpoint(edge, false)

static func _core() -> RefCounted:
	var owner := (Engine.get_main_loop() as SceneTree).root
	if not owner.has_meta("graffitty_graph_schema"):
		owner.set_meta("graffitty_graph_schema", ClassDB.instantiate("GraphClientCore"))
	return owner.get_meta("graffitty_graph_schema")

static func ports(node: Dictionary, output: bool) -> Array:
	if node.has("manifest"):
		return node.manifest.outputs if output else node.manifest.inputs
	return _core().ports(node, output)

static func mode(node: Dictionary, id: String) -> String:
	for port in ports(node, true):
		if port.id == id:
			return port.get("mode", "send") if not id.is_empty() else ""
	return ""

static func resolve(node: Dictionary, output: bool, id: String) -> String:
	var declared := ports(node, output)
	return str(declared[0].id) if id.is_empty() and declared.size() == 1 else id

static func has_port(node: Dictionary, output: bool, id: String) -> bool:
	return ports(node, output).any(func(port): return port.id == id)

static func validate(value: Variant) -> Dictionary:
	return _core().validate_manifest(value)
