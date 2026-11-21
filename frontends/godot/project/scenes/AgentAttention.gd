extends Node
## Tab markers for unseen agent outcomes. Evidence and counting live in Rust
## (AgentAttentionCore); this node only gathers what is on screen.
##
## Signals drive normal updates. A slow repair tick re-reads the same graph
## and layout, so a missed signal (focus, minimize, reconnect) cannot leave a
## marker stale.
##
## The core acts only on server-timestamped status history and current status;
## re-observing unchanged evidence never adds or removes a marker.
signal changed
const WorkspaceLayout := preload("res://scenes/WorkspaceLayout.gd")
const REPAIR_INTERVAL := 1.0
var application  # TerminalApplication: hosts and agent_api
var _core: RefCounted = ClassDB.instantiate("AgentAttentionCore") if ClassDB.class_exists("AgentAttentionCore") else null
var _queued := false
## Shared by tab markers and the agent list. Recordings and headless fixtures
## can supply their viewed host without taking native window focus.
var in_view: Callable = host_in_view


func _ready() -> void:
	if _core == null:
		push_error("AgentAttentionCore is unavailable; tab agent markers are disabled")
		return
	var timer := Timer.new()
	timer.wait_time = REPAIR_INTERVAL
	timer.timeout.connect(refresh)
	add_child(timer)
	timer.start()


func watch_host(host: Node) -> void:
	host.ui_changed.connect(queue_refresh)
	var window := host.get_window()
	for event in [window.focus_entered, window.focus_exited, window.visibility_changed]:
		if not event.is_connected(queue_refresh): event.connect(queue_refresh)


func watch_graph(graph: Object) -> void:
	if not graph.changed.is_connected(queue_refresh): graph.changed.connect(queue_refresh)


func queue_refresh() -> void:
	if _queued: return
	_queued = true
	refresh.call_deferred()


## True only while the user can actually see the host's active tab.
static func host_in_view(host: Node) -> bool:
	if not host.is_inside_tree(): return false
	var window: Window = host.get_window()
	return bool(host.get("presentation_active")) and window.visible and window.has_focus()


func panes(host: Node) -> Dictionary:
	var live: Array[String] = []
	var visible: Array[String] = []
	var shown: bool = in_view.call(host)
	for group in host.workspace_layout.tabs:
		for key in WorkspaceLayout.keys(group.tree):
			if host.is_terminal_pane(key): live.append(key)
		if shown and group.id == host.workspace_layout.active:
			for key in WorkspaceLayout.keys(group.tree, true):
				if host.is_terminal_pane(key): visible.append(key)
	return {"live": live, "visible": visible}


func refresh() -> void:
	_queued = false
	if _core == null or application == null or application.agent_api == null: return
	var live := PackedStringArray()
	var visible := PackedStringArray()
	for host in application.hosts:
		# unregister_host drops a closing window before it is freed.
		if not is_instance_valid(host) or host.is_queued_for_deletion(): continue
		var found := panes(host)
		live.append_array(PackedStringArray(found.live))
		visible.append_array(PackedStringArray(found.visible))
	if _core.observe(application.agent_api.graph.nodes, visible, live):
		changed.emit()
	if "agents" in application and is_instance_valid(application.agents):
		application.agents.refresh()


## `{state: "waiting" | "completed" | "", count}`; waiting wins.
func marker(keys: Array) -> Dictionary:
	if _core == null: return {"state": "", "count": 0}
	return _core.marker(PackedStringArray(keys))


static func describe(attention: Dictionary) -> String:
	var count := int(attention.get("count", 0))
	match str(attention.get("state", "")):
		"waiting":
			return "%d agent%s awaiting input" % [count, "" if count == 1 else "s"]
		"completed":
			return "%d unseen agent completion%s" % [count, "" if count == 1 else "s"]
	return ""
