extends RefCounted
## Window-owned inspector for the focused pane. Sampling stays with the
## session; the Pane Status mod (res://mods/pane-status) draws what the host
## publishes inside the shared panel window.
const PanelWindow := preload("res://scenes/mods/PanelWindow.gd")

static func find(host: Node) -> Window:
	return PanelWindow.find(host, "pane-status")

static func open(host: Node) -> Window:
	return PanelWindow.open(host, "pane-status")
