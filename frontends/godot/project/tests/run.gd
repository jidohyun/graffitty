extends SceneTree
## Fast tests: every tests/unit/*_test.gd, no app sessions or provider calls.
## Graph UI fixtures delegate to the real Rust authority. Build it first:
##     cargo build -p graffitty-workspace-core --example graph_fixture
##
##     godot --headless --path . --script tests/run.gd [-- name-filter]
##
## A test file extends tests/unit/test_case.gd; each `test_*` method is a test.
class ErrorCapture extends Logger:
	var messages: Array[String] = []
	var mutex := Mutex.new()
	func take() -> Array[String]:
		mutex.lock()
		var result := messages.duplicate()
		messages.clear()
		mutex.unlock()
		return result
	func _log_error(_function: String, _file: String, _line: int, code: String, rationale: String, _notify: bool, kind: int, _traces: Array[ScriptBacktrace]) -> void:
		if kind != ERROR_TYPE_WARNING:
			mutex.lock()
			messages.append(rationale if not rationale.is_empty() else code)
			mutex.unlock()

const UNIT_DIR := "res://tests/unit"


func _initialize() -> void:
	# Assertions use English source text, independently of the developer's OS.
	# Localization tests explicitly switch languages and restore this locale.
	TranslationServer.set_locale("en_US")
	# Unit fixtures must not load a developer's startup script or remote server.
	var isolated := OS.get_cache_dir().path_join("graffitty-unit-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	var filter := ""
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			filter = arg
	var errors := ErrorCapture.new()
	OS.add_logger(errors)
	var started := Time.get_ticks_msec()
	var passed := 0
	var failed: Array[String] = []
	var files := Array(DirAccess.get_files_at(UNIT_DIR)).filter(
		func(name):
			return name.ends_with("_test.gd"),
	)
	files.sort()
	for file in files:
		var script: GDScript = load(UNIT_DIR.path_join(file))
		if script == null or not script.can_instantiate():
			failed.append(file)
			print("FAIL %s does not compile" % file)
			continue
		for method in script.get_script_method_list():
			var name: String = method.name
			if (
				not name.begins_with("test_")
				or (filter != "" and not (filter in file or filter in name))
			):
				continue
			var fixture_nodes := Node.get_orphan_node_ids()
			var case: RefCounted = script.new()
			var clock := Time.get_ticks_msec()
			errors.take()
			case.call(name)
			var expected: Array[String] = case.expected_errors.duplicate()
			for message in errors.take():
				if message in expected:
					expected.erase(message)
				else:
					case.failures.append("Unexpected engine error: " + message)
			for message in expected:
				case.failures.append("Expected engine error was not emitted: " + message)
			var label := "%s.%s (%d ms)" % [
				file.get_basename(),
				name,
				Time.get_ticks_msec() - clock,
			]
			if case.failures.is_empty():
				passed += 1
				print("PASS ", label)
			else:
				failed.append(label)
				print("FAIL ", label)
				for failure in case.failures.slice(0, 5):
					print("     ", failure)
			# Unit fixtures intentionally construct nodes without entering a tree.
			# Their pre-created child controls are not owned until _ready(), so
			# freeing only the fixture root leaves them alive at engine shutdown.
			for id in Node.get_orphan_node_ids():
				if id in fixture_nodes or not is_instance_id_valid(id): continue
				var node := instance_from_id(id) as Node
				if node != null and node.get_parent() == null: node.free()
	print(
		"%d passed, %d failed in %.1f s"
		% [passed, failed.size(), (Time.get_ticks_msec() - started) / 1000.0]
	)
	quit(0 if failed.is_empty() else 1)
