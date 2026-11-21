extends "res://tests/unit/test_case.gd"
const Editor := preload("res://scenes/GraphConnectionStopEditor.gd")


func test_duration_matches_scheduled_trigger_units_and_bounds() -> void:
	for pair in [
		["100ms", 0.1],
		["250ms", 0.25],
		["30s", 30.0],
		["5m", 300.0],
		["1.5h", 5400.0],
		["365d", 31536000.0],
	]:
		expect(
			Editor.parse_duration(pair[0]).result == pair[1],
			"Scheduled Trigger duration syntax is supported: " + pair[0],
		)
	for value in ["", "0s", "99ms", "366d", "-1m", "1e309s", "5 minutes", "5"]:
		expect(
			Editor.parse_duration(value).has("error"),
			"Invalid or out-of-range duration is rejected: " + value,
		)


func test_clock_only_targets_next_occurrence_in_displayed_offset() -> void:
	var now := float(Time.get_unix_time_from_datetime_string("2030-01-01T00:00:00"))
	expect(
		Editor.parse_time("10:30", 540, now).result == now + 5400,
		"Later local clock time means today",
	)
	expect(
		Editor.parse_time("08:30", 540, now).result == now + 84600,
		"Earlier local clock time means tomorrow",
	)
	expect(
		Editor.parse_time("09:00", 540, now).result == now + 86400,
		"The current whole-second clock time targets its next occurrence",
	)


func test_after_mode_resolves_once_when_applied_and_can_rearm() -> void:
	var graph := preload("res://tests/support/ServerGraph.gd").new()
	graph.nodes = { "%1": { "provider": "claude" }, "%2": { "provider": "codex" } }
	graph.connect_nodes({ "from": "%1", "to": "%2", "send": true })
	var key: String = graph.edges.keys()[0]
	var editor := Editor.new()
	editor._ready()
	editor.bind_graph(graph, key)
	editor.mode.select(Editor.AFTER)
	editor.mode.item_selected.emit(Editor.AFTER)
	editor.duration.text = "5m"
	var before := Time.get_unix_time_from_system()
	editor._apply()
	var deadline: float = graph.edges[key].stop_at
	expect(
		deadline >= before + 300 and deadline <= Time.get_unix_time_from_system() + 300,
		"After resolves from Apply to a fixed server-enforced deadline",
	)
	graph.changed.emit()
	editor.refresh()
	expect(
		graph.edges[key].stop_at == deadline and editor.mode.selected == Editor.AFTER,
		"Refresh never restarts a duration or replaces its editor mode",
	)
	expect(not editor.apply.disabled, "Applying the same duration again is an explicit rearm")
	editor.bind_graph(graph, key)
	expect(
		editor.mode.selected == Editor.AT
		and editor.date_time.text == Editor.format_time(deadline, editor.offset_minutes),
		"Reopening shows the saved stop instant, without silently starting another duration",
	)
	editor._disconnect_graph()
	editor.free()
	graph.free()


func test_stop_time_parses_and_round_trips_explicit_offsets() -> void:
	var utc := int(Time.get_unix_time_from_datetime_string("2030-01-01T00:00:00"))
	expect(
		Editor.parse_time("2030-01-01 09:00", 540).result == utc,
		"Local positive offset maps to the correct instant",
	)
	expect(
		Editor.parse_time("2029-12-31 18:30:00", -330).result == utc,
		"Negative half-hour offset crosses the date boundary",
	)
	for minutes in [-330, 0, 345, 540]:
		var rendered: String = Editor.format_time(utc + 47, minutes)
		expect(
			Editor.parse_time(rendered, minutes).result == utc + 47,
			"Editing preserves seconds and the displayed offset",
		)
	expect(
		Editor.offset_label(-330) == "UTC-05:30" and Editor.offset_label(345) == "UTC+05:45",
		"The timezone label is explicit",
	)


func test_stop_time_rejects_invalid_calendar_input() -> void:
	for text in [
		"",
		"tomorrow",
		"2030-02-29 12:00",
		"2100-02-29 12:00",
		"2030-04-31 12:00",
		"2030-00-01 12:00",
		"2030-13-01 12:00",
		"2030-01-01 24:00",
		"2030-01-01 12:60",
		"2030-01-01 12:00:60",
	]:
		expect(
			Editor.parse_time(text, 0).has("error"),
			"Invalid time is rejected without changing the connection: " + text,
		)
	expect(Editor.parse_time("2032-02-29 12:00", 0).has("result"), "Leap dates remain valid")


func test_stop_editor_applies_clears_and_preserves_unsaved_edits() -> void:
	var graph := preload("res://tests/support/ServerGraph.gd").new()
	graph.nodes = { "%1": { "provider": "claude" }, "%2": { "provider": "codex" } }
	graph.connect_nodes({ "from": "%1", "to": "%2", "send": true })
	var key: String = graph.edges.keys()[0]
	var editor := Editor.new()
	editor._ready()
	editor.bind_graph(graph, key)
	expect(
		editor.mode.selected == Editor.NEVER and editor.status.text == "No stop time.",
		"Connections have no deadline by default",
	)
	editor.mode.select(Editor.AT)
	editor.mode.item_selected.emit(Editor.AT)
	editor.date_time.text = Editor.format_time(
		Time.get_unix_time_from_system() + 600.0,
		editor.offset_minutes,
	)
	editor._edited()
	var draft: String = editor.date_time.text
	editor.refresh()
	expect(
		editor.date_time.text == draft and not editor.apply.disabled,
		"Unrelated graph notifications preserve an unsaved edit",
	)
	editor._apply()
	expect(
		float(graph.edges[key].get("stop_at", 0)) > Time.get_unix_time_from_system(),
		"Apply stores the real connection deadline",
	)
	var saved: float = graph.edges[key].stop_at
	editor.date_time.text = "invalid"
	editor._edited()
	editor._apply()
	expect(graph.edges[key].stop_at == saved, "Invalid input cannot overwrite the stored deadline")
	editor.mode.select(Editor.NEVER)
	editor.mode.item_selected.emit(Editor.NEVER)
	editor._apply()
	expect(
		float(graph.edges[key].get("stop_at", 0)) == 0 and editor.status.text == "No stop time.",
		"Disabling the option clears the deadline",
	)
	graph.disconnect_edge(graph.edges[key])
	editor.refresh()
	expect(editor.mode.disabled and editor.apply.disabled, "Removed connections cannot be edited")
	editor._disconnect_graph()
	editor.free()
	graph.free()
