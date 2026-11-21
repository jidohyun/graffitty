extends Node
## Shared scenarios run in a desktop SceneTree or the real Android APK.
##
## A fresh APK install first downloads the server fonts missing on the device
## (tens of MiB for a CJK collection); later connections reuse the cache.
const FIRST_CONNECTION_SECONDS := 60.0
signal completed(code: int)
var root: Window:
	get: return get_tree().root
var settings: Dictionary = {}
var output := ""
var failures: Array[String] = []
var checks: Array[String] = []
var result: Dictionary = {}
## Values a runner reads from the scenario's state, e.g. a process to stop on
## the server computer that an Android device cannot reach itself.
var published: Dictionary = {}

func _enter_tree() -> void:
	preload("../../../../../tests/llm-e2e/replay/background.gd").install(get_tree())

func create_timer(seconds: float) -> SceneTreeTimer:
	return get_tree().create_timer(seconds)

func quit(code: int) -> void:
	result["checks"] = checks
	result["failures"] = failures
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		file.store_string(JSON.stringify(result))
	completed.emit(code)
