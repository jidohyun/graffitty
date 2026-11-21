extends RefCounted
## The Agents window: the Agents mod (res://mods/agents, ported from herdr-app)
## in the shared panel window. Rows come from the Rust model through `Agents.gd`,
## published by the panel service.
const PanelWindow := preload("res://scenes/mods/PanelWindow.gd")

static func find(host: Node) -> Window:
	return PanelWindow.find(host, "agents")

static func open(host: Node) -> Window:
	return PanelWindow.open(host, "agents")
