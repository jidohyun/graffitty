extends "res://tests/unit/test_case.gd"


func test_native_capture_reports_uninitialized_terminal() -> void:
	var terminal := ClassDB.instantiate("Terminal") as Node
	expect(terminal.has_method("get_text"), "Native text reader is exposed")
	if terminal.has_method("get_text"):
		var result: Dictionary = terminal.get_text(false)
		expect(result.has("error"), "Uninitialized terminal returns an explicit error")
	terminal.free()


func test_terminal_dispatch_compiles() -> void:
	var script = load("res://scenes/VirtualTerminalInput.gd")
	expect(script != null and script.can_instantiate(), "Terminal API compiles")
