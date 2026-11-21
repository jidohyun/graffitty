extends "res://tests/unit/test_case.gd"
## Tab agent markers: real Rust evidence core, fake hosts and graph.
const Attention := preload("res://scenes/AgentAttention.gd")
const TabStrip := preload("res://scenes/TabStrip.gd")


class Graph extends RefCounted:
	signal changed
	var nodes: Dictionary = {}


class API extends RefCounted:
	var graph := Graph.new()


class Application extends RefCounted:
	var hosts: Array = []
	var agent_api := API.new()


class Host extends Node:
	var workspace_layout := preload("res://scenes/WorkspaceLayout.gd").new()
	var in_view := true
	func is_terminal_pane(key: String) -> bool: return key.begins_with("%")


func _tab(id: int, keys: Array, shown := []) -> Dictionary:
	var children := []
	for key in keys:
		children.append({"pane": key, "shown": shown.is_empty() or key in shown})
	return {"id": id, "focused": keys[0], "tree": {"type": "windows", "windows": children}}


func _node(status: String, history: Array) -> Dictionary:
	var entries := []
	for entry in history:
		entries.append({"at": "2030-01-01T00:00:%s.000+00:00" % entry[0], "status": entry[1]})
	return {"provider": "claude", "status": status, "status_history": entries}


func _setup() -> Array:
	var app := Application.new()
	var host := Host.new()
	app.hosts.append(host)
	var attention := Attention.new()
	attention.application = app
	attention.in_view = func(h): return h.in_view
	return [attention, app, host]


func test_tabs_show_unseen_outcomes_and_clear_only_after_every_pane_is_seen() -> void:
	var parts := _setup()
	var attention: Node = parts[0]
	var app: Application = parts[1]
	var host: Host = parts[2]
	host.workspace_layout.tabs = [_tab(1, ["%1"]), _tab(2, ["%2", "%3", "%4"], ["%2", "%3"])]
	host.workspace_layout.active = 1
	var busy := _node("busy", [["01", "busy"]])
	app.agent_api.graph.nodes = {"%1": busy, "%2": busy, "%3": busy, "%4": busy}
	attention.refresh()
	expect(attention.marker(["%2", "%3", "%4"]).state == "", "Running agents have no marker")
	var done := _node("idle", [["01", "busy"], ["02", "idle"]])
	var ask := _node("waiting", [["01", "busy"], ["02", "waiting"]])
	app.agent_api.graph.nodes = {"%1": done, "%2": done, "%3": done, "%4": ask}
	var emitted := [0]
	attention.changed.connect(func(): emitted[0] += 1)
	attention.refresh()
	expect(emitted[0] == 1, "A marker change emits once")
	expect(attention.marker(["%1"]).state == "", "The visible active tab's completion is already seen")
	expect(attention.marker(["%2", "%3", "%4"]) == {"state": "waiting", "count": 1}, "Waiting wins over completions")
	attention.refresh()
	expect(emitted[0] == 1, "Re-observing unchanged evidence changes nothing")
	host.workspace_layout.active = 2
	attention.refresh()
	expect(attention.marker(["%2", "%3", "%4"]) == {"state": "waiting", "count": 1}, "A hidden pane in the active tab is not seen")
	host.workspace_layout.tabs[1] = _tab(2, ["%2", "%3", "%4"])
	attention.refresh()
	expect(attention.marker(["%2", "%3", "%4"]).state == "", "Showing every pane clears the tab")
	host.free()
	attention.free()


func test_unfocused_window_does_not_count_as_seen_and_closed_panes_are_forgotten() -> void:
	var parts := _setup()
	var attention: Node = parts[0]
	var app: Application = parts[1]
	var host: Host = parts[2]
	host.workspace_layout.tabs = [_tab(1, ["%1"])]
	host.workspace_layout.active = 1
	host.in_view = false
	app.agent_api.graph.nodes = {"%1": _node("busy", [["01", "busy"]])}
	attention.refresh()
	app.agent_api.graph.nodes = {"%1": _node("idle", [["01", "busy"], ["02", "idle"]])}
	attention.refresh()
	expect(attention.marker(["%1"]) == {"state": "completed", "count": 1}, "An unfocused window's active tab still marks")
	host.workspace_layout.tabs = []
	attention.refresh()
	expect(attention.marker(["%1"]).state == "", "A closed pane leaves no marker")
	host.free()
	attention.free()


func test_tab_strip_draws_one_pointer_transparent_dot() -> void:
	var strip: ScrollContainer = TabStrip.new()
	Engine.get_main_loop().root.add_child(strip)
	strip.reconcile([{"id": 1, "title": "a", "attention": {"state": "completed", "count": 1}}], 1)
	var dot: Control = strip.buttons[1].get_node_or_null("Attention")
	expect(dot != null and dot.visible and dot.state == "completed", "Completed tab shows a green dot")
	expect(dot != null and dot.mouse_filter == Control.MOUSE_FILTER_IGNORE, "The dot never steals tab clicks")
	strip.reconcile([{"id": 1, "title": "a", "attention": {"state": "waiting", "count": 3}}], 1)
	expect(dot.state == "waiting" and dot.count == 3 and strip.buttons[1].get_children().filter(func(c): return c.name == "Attention").size() == 1, "State changes reuse one marker")
	strip.reconcile([{"id": 1, "title": "a"}], 1)
	expect(not dot.visible, "No attention hides the marker")
	strip.free()
