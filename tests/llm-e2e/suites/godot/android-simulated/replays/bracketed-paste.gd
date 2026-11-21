extends "res://tests/android_workspace_replay.gd"

func _initialize() -> void:
	run.call_deferred("android-bracketed-paste")
