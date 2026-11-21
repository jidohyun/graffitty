extends "res://tests/tab_close_selection_smoke.gd"
## Real workspace, real tab bar and Rust evidence core; graph snapshots stand
## in for agent hooks.
##
## Headless windows never hold focus, so "in view" here means the host is
## presenting; focus itself is covered in agent_attention_test.gd.
##
##     godot --headless --path . --script tests/tab_agent_attention_smoke.gd -- --shell=/bin/sh

func _at(second: int) -> String:
	return "2030-01-01T00:00:%02d.000+00:00" % second


func _snapshot(key: String, status: String, history: Array) -> Dictionary:
	var entries := []
	for entry in history: entries.append({"at": _at(entry[0]), "status": entry[1]})
	return {"nodes": [{"node": key, "provider": "claude", "status": status, "status_history": entries}]}


func _dot(tab: int) -> Control:
	var button: Button = host.workspace_view.tab_bar.tabs.buttons.get(tab)
	return button.get_node_or_null("Attention") if button != null else null


func _marker(tab: int) -> String:
	var dot := _dot(tab)
	return dot.state if dot != null and dot.visible else ""


func _sync() -> void:
	host.application.agent_attention.refresh()
	for i in 3: await process_frame


func run() -> void:
	var wrapper: Node = load("res://scenes/terminal.tscn").instantiate()
	root.add_child(wrapper)
	var deadline := Time.get_ticks_msec() + 15000
	while wrapper.host == null and Time.get_ticks_msec() < deadline: await process_frame
	if wrapper.host == null: check(false, "Startup host"); quit(1); return
	host = wrapper.host
	connection = wrapper.connection
	await settled()
	var attention: Node = host.application.agent_attention
	check(attention != null, "Application owns the attention tracker")
	if attention == null: quit(1); return
	attention.in_view = func(h): return h.presentation_active
	var first: int = host.workspace_layout.active
	var key: String = host.pane_focus
	var graph: Node = host.agent_api.graph
	var agent := Node.new()
	host.add_child(agent)
	graph.import_remote(agent, _snapshot(key, "busy", [[1, "busy"]]))
	await _sync()
	var second := await add_tab()
	check(host.workspace_layout.active == second, "The agent's tab is in the background")
	check(_marker(first) == "", "A running agent has no marker")
	graph.import_remote(agent, _snapshot(key, "idle", [[1, "busy"], [2, "idle"]]))
	await _sync()
	check(_marker(first) == "completed", "A background completion marks its tab green")
	check(_dot(first).count == 1, "One completed agent counts once")
	check("unseen agent completion" in host.workspace_view.tab_bar.tabs.buttons[first].tooltip_text, "The tooltip explains the marker")
	check(_marker(second) == "", "Other tabs stay unmarked")
	graph.import_remote(agent, _snapshot(key, "waiting", [[1, "busy"], [2, "idle"], [3, "busy"], [4, "waiting"]]))
	await _sync()
	check(_marker(first) == "waiting", "Awaiting input replaces green with yellow")
	host.select_workspace(first, true)
	await settled()
	await _sync()
	check(_marker(first) == "", "Entering the tab with the pane visible clears it")
	host.select_workspace(second, true)
	await settled()
	await _sync()
	check(_marker(first) == "", "A seen wait does not return after leaving")
	graph.import_remote(agent, _snapshot(key, "idle", [[3, "busy"], [4, "waiting"], [5, "busy"], [6, "idle"]]))
	await _sync()
	check(_marker(first) == "completed", "The next unseen completion marks again")
	graph.import_remote(agent, {})
	await _sync()
	check(_marker(first) == "completed", "A detached graph snapshot is not evidence the result was seen")
	agent.queue_free()
	check(error_watch.errors.is_empty(), "No engine or script errors: " + str(error_watch.errors))
	print("TAB_AGENT_ATTENTION_PASS" if failures.is_empty() else "TAB_AGENT_ATTENTION_FAIL")
	quit(0 if failures.is_empty() else 1)
