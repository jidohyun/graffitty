extends "../../../../tests/llm-e2e/replay/replay.gd"
## Exercise the budget/deadline controls on a real, embedded inspector.


func play() -> void:
	root.gui_embed_subwindows = true
	var graph := preload("res://tests/support/ServerGraph.gd").new()
	root.add_child(graph)
	graph.set_process(false)
	for id in [1, 2]:
		var key := "%%%d" % id
		graph.nodes[key] = { "provider": "adapter" }
		graph.register_ports(key, { "inputs": [{ "id": "in" }], "outputs": [{ "id": "out" }] })
	graph.connect_nodes(
		{
			"from": "%1",
			"from_port": "out",
			"to": "%2",
			"to_port": "in",
			"send": true,
		}
	)
	var key: String = graph.edges.keys()[0]
	var inspector := preload("res://scenes/GraphQueueInspector.gd").new()
	root.add_child(inspector)
	inspector.inspect(graph, key)
	await hold(0.2)
	check(
		inspector.budget_scope.selected == 1 and inspector.limit_editor.editable,
		"Empty connection offers an editable New runs budget",
	)
	inspector.limit_editor.text = "50"
	inspector.limit_editor.text_changed.emit("50")
	inspector.apply_limit_button.pressed.emit()
	check(
		graph.default_run_limit == 50 and inspector.run_usage_label.text == "Messages queued 0/50",
		"New-run limit can be applied before any delivery exists",
	)
	var capture := OS.get_environment("GRAFFITTY_UI_CAPTURE")
	if not capture.is_empty():
		await hold(0.1)
		(await screen_image()).save_png(capture.get_basename() + "-empty.png")
	for i in 3:
		graph.enqueue(
			"%1",
			"%2",
			"Message %d" % i,
			"message",
			"inspector-controls",
			"",
			"out",
			"in",
		)
	await hold(0.2)
	inspector.budget_scope.select(0)
	inspector.budget_scope.item_selected.emit(0)
	check(
		inspector.run_usage_label.text == "Messages queued 3/50",
		"Selected run captures the budget configured before the first message",
	)
	check(inspector.stop_editor.mode.selected == 0, "Connections have no stop time by default")
	inspector.limit_editor.text = "25"
	inspector.limit_editor.text_changed.emit("25")
	inspector.apply_limit_button.pressed.emit()
	check(
		graph.run_limit("inspector-controls") == 25
		and inspector.run_usage_label.text.ends_with("3/25"),
		"Apply updates the enforced and displayed run limit",
	)
	inspector.stop_editor.mode.select(2)
	inspector.stop_editor.mode.item_selected.emit(2)
	inspector.stop_editor.date_time.text = inspector.stop_editor.format_time(
		Time.get_unix_time_from_system() + 600,
		inspector.stop_editor.offset_minutes,
	)
	inspector.stop_editor.date_time.text_changed.emit(inspector.stop_editor.date_time.text)
	inspector.stop_editor.apply.pressed.emit()
	check(
		graph.edges[key].get("stop_at", 0) > Time.get_unix_time_from_system(),
		"Stop-time control stores a future connection deadline",
	)
	check(
		graph.queues["%2"].size() == 3,
		"Changing a future stop time preserves queued deliveries",
	)
	inspector.stop_editor.mode.select(1)
	inspector.stop_editor.mode.item_selected.emit(1)
	inspector.stop_editor.duration.text = "30m"
	inspector.stop_editor.duration.text_changed.emit("30m")
	var applied_at := Time.get_unix_time_from_system()
	inspector.stop_editor.apply.pressed.emit()
	check(
		graph.edges[key].stop_at >= applied_at + 1800
		and graph.edges[key].stop_at <= Time.get_unix_time_from_system() + 1800,
		"After mode resolves a Scheduled Trigger-style duration from Apply",
	)
	await hold(0.2)
	check(
		inspector.size.y <= root.get_visible_rect().size.y - 20,
		"Inspector fits the available window height",
	)
	check(
		inspector
		.get_visible_rect()
		.has_point(inspector.stop_editor.apply.get_global_rect().get_center()),
		"Stop-time Apply stays inside the dialog",
	)
	if not capture.is_empty():
		(await screen_image()).save_png(capture)
	var history: Dictionary = graph.queue_log.snapshot()
	inspector.reset_count_button.pressed.emit()
	check(inspector.run_usage_label.text.ends_with("0/25"), "Reset updates the selected run count")
	check(
		graph.queues["%2"].size() == 3 and graph.queue_log.snapshot() == history,
		"Reset keeps queued work and delivery history",
	)
	var edge: Dictionary = graph.edges[key].duplicate()
	edge.stop_at = Time.get_unix_time_from_system() + 0.2
	graph.connect_nodes(edge)
	await hold(0.5)
	check(
		graph.queues["%2"].is_empty(),
		"One-shot deadline expires pending deliveries without graph polling",
	)
	check(
		inspector.stop_editor.status.text.begins_with("Stop time reached"),
		"An idle inspector shows that its connection stopped",
	)
	inspector.stop_editor.mode.select(0)
	inspector.stop_editor.mode.item_selected.emit(0)
	inspector.stop_editor.apply.pressed.emit()
	check(
		not graph.connection_expired(graph.edges[key]),
		"Clearing stop time re-enables the connection",
	)
	check(
		not inspector.paused.button_pressed and not inspector.paused.disabled,
		"An active connection offers an unpressed Pause switch",
	)
	inspector.paused.button_pressed = true
	check(graph.edges[key].get("muted", false), "Pause switch mutes the connection")
	edge = graph.edges[key].duplicate()
	edge.muted = false
	graph.connect_nodes(edge)
	await process_frame
	check(not inspector.paused.button_pressed, "Pause switch follows an unmute made elsewhere")
	graph.disconnect_edge(graph.edges[key])
	await process_frame
	check(inspector.paused.disabled, "Pause switch is disabled once the connection is removed")
	inspector.queue_free()
	graph.queue_free()
	await process_frame
