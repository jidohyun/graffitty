extends "res://tests/unit/test_case.gd"
const Ports := preload("res://scenes/GraphPorts.gd")
const Topology := preload("res://scenes/GraphVisualTopology.gd")
func manifest() -> Dictionary:
	return {"name": "Judge", "inputs": [{"id": "evaluate"}], "outputs": [
		{"id": "yes", "name": "Approved", "color": "#00ff00"},
		{"id": "no", "color": "#ff0000"}]}

func test_reroute_stems_are_grouped_by_output_socket() -> void:
	var edges := {
		"%1/yes>%2": {"from": "%1", "from_port": "yes", "to": "%2"},
		"%1/no>%2": {"from": "%1", "from_port": "no", "to": "%2"}}
	var data := {"routes": {}}
	Topology.normalize(data)
	var segments: Array = Topology.segments(data, edges)
	expect(segments.size() == 2, "Independent outputs never collapse into a shared wire")
	expect(segments[0].from != segments[1].from, "Socket identities include port IDs")


func test_node_and_output_icon_manifest_validation() -> void:
	var declaration := manifest()
	declaration["icon"] = {"text": "⚖", "font": "Symbols Nerd Font Mono"}
	declaration.outputs[0]["icon"] = "✓"
	var checked := Ports.validate(declaration)
	expect(checked.manifest.icon.font == "Symbols Nerd Font Mono", "Custom text font family survives registration")
	expect(checked.manifest.outputs[0].icon.text == "✓", "Short string icons normalize to text")
	declaration.outputs[0].icon = {"svg": "x".repeat(17000)}
	expect(Ports.validate(declaration).has("error"), "Oversized SVG is rejected")
	declaration.outputs[0].icon = {"text": 123}
	expect(Ports.validate(declaration).has("error"), "Non-text glyph is rejected")
