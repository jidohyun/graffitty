extends "../../../../tests/llm-e2e/replay/replay.gd"
## Assertions run before yielding a frame: a timer cannot make these pass.
const Monitor := preload("res://scenes/TerminalResourceMonitor.gd")

## What the agent list reads from a graph's remote owner when scoping pins.
class RemotePeer extends Node:
	var url := "gft://fixture"
	var epoch := 1
	func wire_id(id: int) -> int: return id

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var key: String = host.pane_focus
	var id := int(key.substr(1))
	var graph: Node = host.agent_api.graph
	graph.set_process(false)
	view.show_overview()
	await hold(.2)
	if not check(view.status_strips.has(key) and view.status_strips[key].is_class("ModView"), "Overview creates the real pane-strip mod"): return
	var strip: Control = view.status_strips[key]
	var shown := func() -> PackedStringArray:
		strip.render_now()
		return strip.texts()
	var original: Node = host.sessions[id].resource_monitor
	var source := Monitor.new()
	source.remote = true
	host.add_child(source)
	host.sessions[id].resource_monitor = source
	view.refresh()
	host.pane_status_visible = true
	view.refresh()
	# Lay the monitor out before any event: hover text is found by position.
	await hold(.2)
	source.apply_remote({"status":"running", "cpu_valid":true, "cpu_percent":37.0, "memory_current":134217728}, 5.0)
	check(view.pane_status[key].cpu == "37%" and view.pane_status[key].memory == "128M" and "37%" in shown.call() and "128M" in shown.call(), "Resource sample changes strip labels synchronously")
	check("37.0%" in "\n".join(preload("res://scenes/PaneStatusDialog.gd").find(host).texts()), "Resource sample changes the open monitor synchronously")
	var connection := RemotePeer.new()
	host.add_child(connection)
	graph.import_remote(connection, {"nodes":[{"node":key, "provider":"codex", "status":"busy"}]})
	var agent := func() -> Variant: return view.pane_status[key].agent
	check(agent.call() != null and agent.call().provider == "codex" and agent.call().status == "busy" and agent.call().spinning, "Prompt hook changes text and badge synchronously")
	shown.call()
	check("agent" in strip.hit_keys() and strip.get_tooltip(strip.hit_rect("agent").get_center()).begins_with("Codex · "), "The badge is drawn with its hover text")
	# The monitor draws the same badge as the strip; its status is the hover text.
	var monitor: Window = preload("res://scenes/PaneStatusDialog.gd").find(host)
	monitor.texts()
	var monitor_badge: String = monitor.view.get_tooltip(monitor.view.hit_rect("agent").get_center()) if "agent" in monitor.view.hit_keys() else ""
	check(monitor_badge.begins_with("Codex · " + preload("res://scenes/AgentStatusBadge.gd").status_label("busy")), "Prompt hook changes the open monitor synchronously (%s)" % monitor_badge)
	graph.import_remote(connection, {"nodes":[{"node":key, "provider":"codex", "status":"idle"}]})
	check(agent.call().status == "idle" and not agent.call().spinning, "Stop hook changes text and badge synchronously")
	graph.import_remote(connection, {"nodes":[{"node":key, "provider":"claude", "status":"waiting"}]})
	check(agent.call().provider == "claude" and agent.call().status == "waiting", "Claude permission hook changes text synchronously")
	graph.import_remote(connection, {"nodes":[{"node":key, "provider":"codex", "status":"busy"}]})
	check(agent.call().provider == "codex" and agent.call().status == "busy", "Remote graph snapshot changes strip text synchronously")
	graph.import_remote(connection, {})
	check(agent.call() == null, "Remote detach removes the agent badge synchronously")
	shown.call()
	check(not "agent" in strip.hit_keys(), "The badge leaves the strip")
	connection.queue_free()
	strip.hide()
	source.apply_remote({"status":"running", "cpu_valid":true, "cpu_percent":61.0, "memory_current":268435456}, 5.0)
	check(view.pane_status[key].cpu == "61%" and "61%" in shown.call(), "Hidden strip retains the newest sample before it is shown")
	# Rebinding a restored/reconnected session must release the old publisher.
	host.sessions[id].resource_monitor = original
	view.refresh()
	var restored: String = JSON.stringify(view.pane_status[key])
	source.apply_remote({"status":"running", "cpu_valid":true, "cpu_percent":99.0}, 5.0)
	check(JSON.stringify(view.pane_status[key]) == restored, "Replaced monitor no longer publishes into this pane")
	check(not source.snapshot_changed.is_connected(view._resource_status_changed.bind(key)), "Old sample subscription is disconnected")
	source.queue_free()
