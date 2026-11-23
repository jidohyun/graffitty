extends "res://tests/unit/test_case.gd"

const Application := preload("res://scenes/TerminalApplication.gd")


func test_idle_render_loop_starts_in_low_processor_mode() -> void:
	# Given an active workspace is registering with the application.
	var previous := OS.low_processor_usage_mode
	OS.low_processor_usage_mode = false
	# When the application configures its idle render loop.
	Application._configure_idle_render_loop()
	# Then idle rendering starts asleep until activity wakes it.
	expect(OS.low_processor_usage_mode, "Idle workspaces must use low-processor sleeps")
	OS.low_processor_usage_mode = previous
