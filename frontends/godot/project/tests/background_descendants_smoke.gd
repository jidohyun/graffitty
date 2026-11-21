extends SceneTree
## Launch through tools/e2e_background.prepare_background to check child isolation.
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")
var failures: Array[String] = []
var depth := 0
var result_path := ""


func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-descendants-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	Background.install(self)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--depth="):
			depth = int(arg.trim_prefix("--depth="))
		if arg.begins_with("--descendant-result="):
			result_path = arg.trim_prefix("--descendant-result=")
	run.call_deferred()


func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", "depth %d: " % depth, message)
	if not ok:
		failures.append(message)


func run() -> void:
	check(Background.requested(), "Background launch was requested")
	check(
		OS.get_environment("GRAFFITTY_E2E_GUARD_ACTIVE") == str(OS.get_process_id()),
		"Native guard ran in this Godot process",
	)
	var library := OS.get_environment("GRAFFITTY_E2E_NATIVE_LIBRARY")
	var inherited := OS.get_environment("DYLD_INSERT_LIBRARIES")
	check(not library in inherited.split(":"), "Helpers cannot inherit the loaded test guard")
	check(OS.execute("/usr/bin/true", []) == 0, "Signed system helper starts successfully")
	var directory := OS.get_cache_dir().path_join("child-evidence")
	DirAccess.make_dir_recursive_absolute(directory)
	var child_result := directory.path_join("result.json")
	FileAccess.open(child_result, FileAccess.WRITE).store_string("{}")
	check(
		OS.execute("/bin/chmod", ["600", child_result]) == 0,
		"System chmod helper starts successfully",
	)
	DirAccess.remove_absolute(child_result)
	if depth < 2:
		var arguments := Background.rendering_arguments()
		# Propagate headless mode for a fast harness-only run when requested.
		if DisplayServer.get_name() == "headless":
			arguments.append("--headless")
		arguments.append_array(
			[
				"--path",
				ProjectSettings.globalize_path("res://"),
				"--script",
				"tests/background_descendants_smoke.gd",
				"--",
				"--depth=%d" % (depth + 1),
				"--descendant-result=" + child_result,
			]
		)
		var child := Background.create_godot_process(arguments)
		check(child > 0, "Guarded Godot child starts")
		check(
			OS.get_environment("DYLD_INSERT_LIBRARIES") == inherited,
			"Child launch preserves parent helper environment",
		)
		if child > 0:
			var deadline := Time.get_ticks_msec() + 15000
			while OS.is_process_running(child) and Time.get_ticks_msec() < deadline:
				await process_frame
			if OS.is_process_running(child):
				OS.kill(child)
			check(FileAccess.file_exists(child_result), "Child produced a result")
			if FileAccess.file_exists(child_result):
				var result: Dictionary = JSON.parse_string(
					FileAccess.get_file_as_string(child_result)
				)
				check(result.get("failures", ["missing result"]).is_empty(), "Descendant checks pass")
				check(
					int(result.get("pid", -1)) == child,
					"Launcher preserves the guarded child PID",
				)
	await create_timer(0.3).timeout
	if not result_path.is_empty():
		FileAccess.open(result_path, FileAccess.WRITE).store_string(
			JSON.stringify({ "pid": OS.get_process_id(), "failures": failures })
		)
	quit(0 if failures.is_empty() else 1)
