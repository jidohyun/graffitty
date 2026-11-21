extends SceneTree
## Thin Mac runner for exactly the scenario embedded in the Android test APK.
var watch := preload("res://tests/android_runtime_smoke.gd").ErrorWatch.new()
func _initialize() -> void:
	OS.add_logger(watch)
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS","1")
	var config: Dictionary = {}
	var output := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scenario="): config = JSON.parse_string(FileAccess.get_file_as_string(arg.trim_prefix("--scenario=")))
		if arg.begins_with("--result="): output = arg.trim_prefix("--result=")
	OS.set_environment("XDG_STATE_HOME",output.get_base_dir().path_join("state"))
	OS.set_environment("XDG_CONFIG_HOME",output.get_base_dir().path_join("config"))
	var viewport_size := Vector2i(1100, 750)
	var requested := OS.get_environment("GRAFFITTY_E2E_VIEWPORT").split("x")
	if requested.size() == 2 and requested[0].is_valid_int() and requested[1].is_valid_int():
		viewport_size = Vector2i(int(requested[0]), int(requested[1]))
	root.size = viewport_size
	root.unfocusable = true
	root.content_scale_size = root.size
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	root.add_child.call_deferred(preload("res://tests/client_scenarios/android_ui.gd").PointerGuard.new())
	var scenario = load("res://tests/client_scenarios/" + str(config.scenario) + ".gd").new()
	scenario.settings = config.connection
	scenario.output = output
	if config.has("case"): scenario.case_name = config.case
	scenario.completed.connect(func(_code): _finish.call_deferred(scenario, output))
	root.add_child.call_deferred(scenario)

func _finish(scenario: Node, output: String) -> void:
	var failures: Array = scenario.failures.duplicate()
	var checks: Array = scenario.checks.duplicate()
	# Retire live viewports and their GPU textures before renderer shutdown.
	scenario.queue_free()
	for unused in range(5): await process_frame
	failures.append_array(watch.errors)
	FileAccess.open(output,FileAccess.WRITE).store_string(JSON.stringify({"checks":checks,"failures":failures}))
	quit(0 if failures.is_empty() else 1)
