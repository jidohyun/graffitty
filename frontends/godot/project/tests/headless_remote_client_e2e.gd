extends SceneTree
## The same multi-server scenario runs on desktop and in the Android APK.
func _initialize() -> void:
	var scenario = preload("res://tests/client_scenarios/multiserver.gd").new()
	scenario.completed.connect(func(code): quit(code))
	root.add_child.call_deferred(scenario)
