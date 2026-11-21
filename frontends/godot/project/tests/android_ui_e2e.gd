extends SceneTree
## Desktop entry for the scenario also executed inside the Android APK.
func _initialize() -> void:
	var scenario = preload("res://tests/client_scenarios/android_ui.gd").new()
	scenario.completed.connect(func(code): quit(code))
	root.add_child.call_deferred(scenario)
