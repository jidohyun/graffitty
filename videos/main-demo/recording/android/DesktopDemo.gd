extends SceneTree
## The Android scenario, rendered by the desktop engine with mobile controls.
var scenario: Node
var output := ""
var watch := preload("res://tests/android_runtime_smoke.gd").ErrorWatch.new()

func _initialize() -> void:
	OS.add_logger(watch)
	TranslationServer.set_locale("en")
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "1")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--demo-output="): output = arg.trim_prefix("--demo-output=")
	assert(not output.is_empty())
	# Establish the phone's logical viewport before creating either the manager
	# or workspace. Rescaling after connection moves floating controls.
	root.size = Vector2i(1968, 1968)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 2.625
	root.unfocusable = true
	root.add_child.call_deferred(preload("res://tests/client_scenarios/android_ui.gd").PointerGuard.new())
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("demo-config.json")))
	scenario = load("res://videos/main-demo/recording/android/ManagerDemo.gd").new() if config.get("manager_only", false) else preload("AndroidDemo.gd").new()
	scenario.desktop_capture = true
	scenario.settings = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("server.json")))
	scenario.output = output.path_join("capture.json")
	scenario.completed.connect(_finish)
	process_frame.connect(_publish_clock)
	root.add_child.call_deferred(scenario)

func _publish_clock() -> void:
	var path := output.path_join("animation-clock")
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	file.store_string(str(Engine.get_singleton("GraffittyMovieWriter").frames_written() * 1000 / 60))
	file.close()
	DirAccess.rename_absolute(path + ".tmp", path)

func _finish(_code: int) -> void:
	var writer = Engine.get_singleton("GraffittyMovieWriter")
	writer.set_recording(false)
	var failures: Array = scenario.failures.duplicate()
	failures.append_array(watch.errors)
	FileAccess.open(output.path_join("capture.json"), FileAccess.WRITE).store_string(JSON.stringify({
		"checks": scenario.checks, "failures": failures, "frames": writer.frames_written(),
		"fps": 60, "capture_backend": "desktop-mobile", "ui_scale": 2.625,
		"typing_schedule_sha256": scenario.human_typing.source_hash,
	}))
	FileAccess.open(output.path_join("beats.json"), FileAccess.WRITE).store_string(JSON.stringify(scenario.beats))
	print("DESKTOP_MOBILE_DEMO_PASS" if failures.is_empty() else "DESKTOP_MOBILE_DEMO_FAIL: " + str(failures))
	scenario.queue_free()
	for i in 5: await process_frame
	quit(0 if failures.is_empty() else 1)
