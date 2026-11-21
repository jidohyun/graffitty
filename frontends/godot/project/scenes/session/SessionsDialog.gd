extends RefCounted
## The Sessions window: the Sessions mod (res://mods/sessions, ported from
## herdr-app's spaces) in the shared panel window. Named Graffitty sessions
## replace Herdr spaces; no invented Git metadata.
const PanelWindow := preload("res://scenes/mods/PanelWindow.gd")

static func find(host: Node) -> Window:
	return PanelWindow.find(host, "sessions")

static func open(host: Node) -> Window:
	return PanelWindow.open(host, "sessions")
