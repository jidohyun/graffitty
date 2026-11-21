extends "res://tests/unit/test_case.gd"
const Graph := preload("res://tests/support/ServerGraph.gd")
const Inspector := preload("res://scenes/GraphQueueInspector.gd")

class ObservedInspector extends "res://scenes/GraphQueueInspector.gd":
	var refreshes := 0
	func refresh(force := false) -> void:
		refreshes += 1
		super.refresh(force)

func graph() -> Node:
	var value := Graph.new()
	for id in range(1, 4):
		var key := "%%%d" % id
		value.nodes[key] = {"provider": "adapter"}
		value.register_ports(key, {"inputs": [{"id": "in"}], "outputs": [{"id": "out"}]})
	for id in [2, 3]:
		value.connect_nodes({"from": "%1", "from_port": "out", "to": "%%%d" % id, "to_port": "in", "send": true})
	return value

func send(value: Node, run: String, target := "%2") -> Dictionary:
	return value.enqueue("%1", target, "message", "message", run, "", "out", "in")

func select_event(inspector: Inspector, id: String) -> void:
	var item := inspector.events.get_root().get_first_child()
	while item != null:
		if str(item.get_metadata(0)) == id:
			item.select(0)
			inspector._select()
			return
		item = item.get_next()

func test_inspector_budget_follows_selected_run_across_connections_without_polling() -> void:
	var value := graph()
	var first := send(value, "shared-run")
	var inspector := ObservedInspector.new()
	inspector._ready()
	inspector._bind_graph(value)
	inspector.edge_key = "%1/out>%2/in"
	inspector.visible = true
	inspector.refresh()
	expect(inspector.selected_run == "shared-run" and inspector.run_usage_label.text == "Messages queued 1/10000", "Selected delivery identifies its run and displays the default usage")
	expect(value.queue_log.snapshot(inspector.edge_key).events[0].run_id == "shared-run", "Journal preserves run identity without retaining message content")
	var refreshes := inspector.refreshes
	send(value, "shared-run", "%3")
	expect(inspector.run_usage_label.text == "Messages queued 2/10000" and inspector.refreshes == refreshes, "Another connection updates the selected run count directly without resnapshotting this journal")
	inspector.limit_editor.text = "4"
	inspector.limit_editor.text_changed.emit("4")
	expect(value.run_limit("shared-run") == 10000, "Editing the draft limit does not change enforcement until Apply")
	send(value, "shared-run", "%3")
	expect(inspector.limit_editor.text == "4", "Live usage updates preserve an in-progress limit edit")
	inspector.apply_limit_button.pressed.emit()
	expect(value.run_limit("shared-run") == 4 and inspector.run_usage_label.text == "Messages queued 3/4", "Apply changes both enforcement and displayed usage")
	var history: Dictionary = value.queue_log.snapshot()
	var queued: Dictionary = value.queues.duplicate(true)
	inspector.reset_count_button.pressed.emit()
	expect(inspector.run_usage_label.text == "Messages queued 0/4" and inspector.reset_count_button.disabled, "Reset updates the selected run immediately and disables an empty reset")
	expect(value.queues == queued and value.queue_log.snapshot() == history, "Inspector reset never consumes messages or clears history")
	for text in ["0", "-1", "1.5", "9223372036854775808"]:
		inspector.limit_editor.text = text
		inspector.limit_editor.text_changed.emit(text)
		expect(inspector.apply_limit_button.disabled and value.run_limit("shared-run") == 4, "Invalid or overflowing integer limits cannot be applied")
	var other := send(value, "another-run")
	inspector.refresh()
	select_event(inspector, other.result.event_id)
	expect(inspector.selected_run == "another-run" and inspector.run_usage_label.text == "Messages queued 1/10000" and inspector.limit_editor.text == "10000", "Changing selection switches scope and clears the previous limit draft")
	select_event(inspector, first.result.event_id)
	expect(inspector.run_usage_label.text == "Messages queued 0/4", "Returning to a delivery preserves its run's independent budget")
	inspector._disconnect_graph()
	expect(value.run_usage_changed.get_connections().is_empty(), "Inspector disconnects targeted run updates on teardown")
	inspector.free()
	value.free()

func test_empty_inspector_edits_new_run_default_and_keeps_draft_scope() -> void:
	var value := graph()
	var inspector := Inspector.new()
	inspector._ready()
	inspector._bind_graph(value)
	inspector.edge_key = "%1/out>%2/in"
	inspector.visible = true
	inspector.refresh()
	expect(inspector.run_usage_label.text == "Messages queued 0/10000" and inspector.budget_scope.selected == 1, "Empty inspector shows the new-run default without inventing a run")
	expect(inspector.limit_editor.editable and not inspector.apply_limit_button.disabled and inspector.reset_count_button.disabled, "New-run budget is editable before the first delivery; there is no count to reset")
	inspector.limit_editor.text = "8"
	inspector.limit_editor.text_changed.emit("8")
	send(value, "arrives-during-edit")
	inspector.refresh()
	expect(inspector.limit_editor.text == "8" and inspector.budget_scope.selected == 1, "A new delivery does not switch a default-budget draft to that run")
	inspector.apply_limit_button.pressed.emit()
	expect(value.default_run_limit == 8 and value.run_limit("arrives-during-edit") == 10000, "Apply changes the new-run default while preserving the active run")
	var sent := send(value, "configured-before-run")
	expect(value.run_limit("configured-before-run") == 8, "The next run uses the limit configured in an empty inspector")
	inspector.refresh()
	select_event(inspector, sent.result.event_id)
	inspector.budget_scope.select(0)
	inspector.budget_scope.item_selected.emit(0)
	expect(inspector.run_usage_label.text == "Messages queued 1/8" and not inspector.reset_count_button.disabled, "Selected run scope exposes its count and reset")
	inspector.reset_count_button.pressed.emit()
	expect(value.runs["configured-before-run"] == 0 and value.default_run_limit == 8, "Reset applies only to the selected run")
	inspector.budget_scope.select(1)
	inspector.budget_scope.item_selected.emit(1)
	value.set_default_run_limit(12)
	expect(inspector.limit_editor.text == "12" and inspector.run_usage_label.text == "Messages queued 0/12", "Default scope updates through signals when another inspector changes it")
	inspector._disconnect_graph()
	expect(value.default_run_limit_changed.get_connections().is_empty(), "Inspector disconnects default-budget notifications")
	inspector.free()
	value.free()

func test_inspector_without_graph_has_no_editable_budget() -> void:
	var inspector := Inspector.new()
	inspector._ready()
	expect(not inspector.limit_editor.editable and inspector.apply_limit_button.disabled and inspector.reset_count_button.disabled, "A closed graph cannot accept budget edits")
	inspector.free()
