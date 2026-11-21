extends "res://tests/unit/test_case.gd"
const Graph := preload("res://scenes/AgentGraph.gd")
const Ports := preload("res://scenes/GraphPorts.gd")

class Overlay extends "res://scenes/AgentGraphOverlay.gd":
	var rendered_pattern := ""
	func draw_wire(_painter: CanvasItem, _points: PackedVector2Array, _color: Color,
			_width: float, dashed: bool, dotted := false) -> void:
		rendered_pattern = "dotted" if dotted else "dashed" if dashed else "solid"

func test_direct_output_style_survives_normalization_and_renaming() -> void:
	var checked := Ports.validate({"name": "My renamed composer", "inputs": [],
		"outputs": [{"id": "out", "line_style": "solid"}]})
	expect(not checked.has("error"), "Direct-output hint is accepted")
	var graph := Graph.new()
	graph.nodes = {"%1": {"manifest": checked.manifest}, "%2": {"provider": "claude"}}
	var overlay := Overlay.new()
	overlay.graph = graph
	var edge := {"from": "%1", "from_port": "out", "send": true}
	expect(overlay.wire_pattern(edge) == "solid", "Renamed direct outputs are solid")
	expect(overlay.wire_pattern({"from": "%2", "from_port": "send", "send": true}) == "dashed", "Agent Send remains conditional")
	expect(overlay.wire_pattern({"from": "%2", "from_port": "read", "read": true}) == "dashed", "Read remains dashed")
	edge.muted = true
	expect(overlay.wire_pattern(edge) == "dotted", "Mute overrides direct output style")
	edge.muted = false
	edge.stop_at = 1
	expect(overlay.wire_pattern(edge) == "dotted", "Expiry overrides direct output style")
	overlay.graph = null
	graph.free()

func test_drag_and_reconnect_resolve_the_new_output_style() -> void:
	var graph := Graph.new()
	graph.nodes = {"%1": {"manifest": {"inputs": [], "outputs": [{"id": "out", "line_style": "solid"}]}},
		"%2": {"provider": "claude"}}
	var overlay := Overlay.new()
	overlay.graph = graph
	var points := PackedVector2Array([Vector2.ZERO, Vector2(100, 0)])
	overlay.draw_preview_wire(points, "%1/out")
	expect(overlay.rendered_pattern == "solid", "New manual-output drag previews its solid wire")
	var previous := {"from": "%2", "from_port": "send", "send": true}
	overlay.draw_preview_wire(points, "%1/out", previous)
	expect(overlay.rendered_pattern == "solid", "Reconnecting to direct output updates the pattern")
	previous.muted = true
	overlay.draw_preview_wire(points, "%1/out", previous)
	expect(overlay.rendered_pattern == "dotted", "Muted reconnection stays dotted")
	overlay.graph = null
	graph.free()
