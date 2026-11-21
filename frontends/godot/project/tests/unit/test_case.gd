extends RefCounted
## Base for fast tests. Failures are collected, not thrown, so one run reports
## every broken rule. `rng` is seeded, so a failing case reproduces exactly.
var failures: Array[String] = []
## Exact intentional engine errors; unexpected diagnostics always fail the case.
var expected_errors: Array[String] = []
var rng := RandomNumberGenerator.new()

func cache_directory() -> String:
	var directory := OS.get_environment("XDG_CACHE_HOME")
	if directory.is_empty(): directory = OS.get_cache_dir()
	DirAccess.make_dir_recursive_absolute(directory)
	return directory


## Write a client.toml overlay for this test and return its --config argument.
func client_toml(name: String, source: String) -> String:
	var path := cache_directory().path_join("graffitty-client-%d-%s.toml" % [OS.get_process_id(), name])
	FileAccess.open(path, FileAccess.WRITE).store_string(source)
	return "--config=" + path


func _init() -> void:
	rng.seed = 20260926


func expect(ok: bool, message: String) -> bool:
	if not ok:
		failures.append(message)
	return ok
