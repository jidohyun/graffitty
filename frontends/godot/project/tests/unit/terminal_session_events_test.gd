extends "res://tests/unit/test_case.gd"

const Session := preload("res://scenes/TerminalSession.gd")


class TerminalState:
	extends Node
	signal title_changed(title: String)
	signal bell
	signal exited(code: int)
	var working_directory := "/initial"
	var reads := 0
	var state: Dictionary = {
		"title": "",
		"cwd": "",
		"progress_state": 0,
		"progress_value": -1,
		"scroll_total": 100,
		"scroll_offset": 80,
		"scroll_fraction": 0.0,
		"scroll_page": 20,
		"columns": 80,
		"rows": 20,
		"exited": false,
	}


	func get_ui_state() -> Dictionary:
		reads += 1
		return state


	func scroll_to_row(row: int) -> void:
		state.scroll_offset = row


	func scroll_to_position(row: float) -> void:
		state.scroll_offset = floori(row)
		state.scroll_fraction = fposmod(row, 1.0)


class EventTerminal:
	extends TerminalState
	signal ui_state_changed
	signal frame_changed


func test_semantic_events_refresh_without_polling_or_paint_reads() -> void:
	var terminal := EventTerminal.new()
	var session := Session.new()
	session.configure(4, terminal)
	expect(terminal.reads == 1, "Configuration reads the initial state once")
	expect(not session.has_method("_process"), "Sessions have no per-frame polling")
	expect(session.get_child_count() == 0, "Current backends do not create a polling timer")
	for _frame in range(120):
		terminal.frame_changed.emit()
	expect(terminal.reads == 1, "Blink and painting never read semantic state")
	var events: Array[String] = []
	session.changed.connect(
		func():
			events.append("changed"),
	)
	session.title_changed.connect(
		func(_title):
			events.append("title"),
	)
	session.progress_changed.connect(
		func(_state, _value):
			events.append("progress"),
	)
	session.scroll_changed.connect(
		func(_scroll):
			events.append("scroll"),
	)
	terminal.state.merge(
		{
			"cwd": "file://localhost/work/two%20words",
			"progress_state": 1,
			"progress_value": 42,
			"scroll_offset": 2,
			"scroll_fraction": 0.25,
			"scroll_page": 24,
			"columns": 100,
			"rows": 24,
		},
		true,
	)
	terminal.ui_state_changed.emit()
	expect(terminal.reads == 2, "A semantic invalidation reads the state once")
	expect(session.title == "/work/two words", "CWD-only events update the fallback title")
	expect(session.progress_value == 42, "Progress-only events reach the session")
	expect(session.scroll_offset == 2.25, "Fractional scroll offsets are preserved")
	expect(session.snapshot().columns == 100, "Grid-only state is retained")
	expect(events == ["title", "progress", "scroll", "changed"], "Each changed field emits once")
	events.clear()
	terminal.ui_state_changed.emit()
	expect(events.is_empty(), "Identical snapshots do not re-emit UI updates")
	session.free()
	terminal.free()


func test_remote_exit_and_restart_are_event_driven() -> void:
	var terminal := EventTerminal.new()
	var session := Session.new()
	session.configure(1, terminal)
	terminal.state.exited = true
	terminal.ui_state_changed.emit()
	expect(session.has_exited, "Remote exit needs no local process-exited signal")
	expect(session.exit_code == null, "Remote exit does not invent a process exit code")
	terminal.exited.emit(7)
	expect(session.exit_code == 7, "Local process exit retains its exit code")
	terminal.state.exited = false
	terminal.ui_state_changed.emit()
	expect(not session.has_exited and session.exit_code == null, "Restart clears stale exit state")
	session.free()
	terminal.free()


func test_scroll_commands_refresh_immediately_and_clamp() -> void:
	var terminal := EventTerminal.new()
	var session := Session.new()
	session.configure(3, terminal)
	session.scroll_to(2.25)
	session.scroll_by(1)
	expect(session.scroll_offset == 3.25, "Successive scroll commands see current fractional state")
	session.scroll_to(500)
	expect(session.scroll_offset == 80.0, "Scroll target clamps to the final page")
	session.scroll_to(-10)
	expect(session.scroll_offset == 0.0, "Scroll target clamps to the beginning")
	terminal.state.alternate_screen = true
	terminal.ui_state_changed.emit()
	session.scroll_to(20)
	expect(session.scroll_offset == 0.0, "Alternate screen ignores scrollbar commands")
	session.free()
	terminal.free()
