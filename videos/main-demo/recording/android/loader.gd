extends "res://tests/client_scenarios/scenario.gd"
func _ready() -> void:
	TranslationServer.set_locale("en")
	var demo=load("user://android_demo.gd").new()
	demo.settings=settings
	checks=demo.checks
	failures=demo.failures
	demo.completed.connect(func(code): completed.emit(code))
	add_child(demo)
