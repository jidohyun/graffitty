extends RefCounted
const Paths := preload("res://graffitty/paths.gd")
static var logger: AppLogger
static var history: Array[Dictionary] = []
static var revision := 0


class AppLogger extends Logger:
	var mutex := Mutex.new()
	var pending: Array[Dictionary] = []
	var failures := 0
	var file: FileAccess
	var path := ""


	## Known engine errors that are not Graffitty failures: still written to the log
	## file, but never counted or shown in the messages panel.
	static func engine_noise(source: String, function: String) -> bool:
		# Godot 4.7's root Window asks for the mouse position on enter-tree even when
		# the display server has no mouse (scene/main/window.cpp), as on iOS.
		return OS.get_name() == "iOS" and source.ends_with("display_server.cpp") and function == "mouse_get_position"


	func _log_message(message: String, _error: bool) -> void:
		mutex.lock()
		if file != null:
			file.store_string(message)
			file.flush()
		mutex.unlock()


	func _log_error(
		function: String,
		source: String,
		line: int,
		code: String,
		rationale: String,
		_notify: bool,
		kind: int,
		backtraces: Array[ScriptBacktrace],
	) -> void:
		var message := rationale if not rationale.is_empty() else code
		var trace := ""
		for backtrace in backtraces:
			trace += backtrace.format() + "\n"
			if not source.ends_with(".gd") and backtrace.get_frame_count() > 0:
				source = backtrace.get_frame_file(0)
				line = backtrace.get_frame_line(0)
		var entry := {
			"message": message,
			"file": source,
			"line": line,
			"warning": kind == ERROR_TYPE_WARNING,
			"trace": trace,
			"function": function,
		}
		mutex.lock()
		if not engine_noise(source, function):
			if kind != ERROR_TYPE_WARNING:
				failures += 1
			pending.append(entry)
			if pending.size() > 200:
				pending.pop_front()
		if file != null:
			file.store_string(
				"%s: %s\n  %s:%d\n%s"
				% ["WARNING" if entry.warning else "ERROR", message, source, line, trace]
			)
			file.flush()
		mutex.unlock()


static func start() -> void:
	if logger != null:
		return
	logger = AppLogger.new()
	var args := OS.get_cmdline_args()
	var index := args.find("--log-file")
	if index >= 0 and index + 1 < args.size():
		logger.path = args[index + 1]
	else:
		logger.path = Paths.stdpath("state").path_join("graffitty.log")
		var error := DirAccess.make_dir_recursive_absolute(logger.path.get_base_dir())
		if error == OK:
			if FileAccess.file_exists(logger.path):
				var existing := FileAccess.open(logger.path, FileAccess.READ)
				var rotate := existing != null and existing.get_length() > 8 * 1024 * 1024
				existing = null
				if rotate:
					DirAccess.remove_absolute(logger.path + ".1")
					DirAccess.rename_absolute(logger.path, logger.path + ".1")
			if FileAccess.file_exists(logger.path):
				logger.file = FileAccess.open(logger.path, FileAccess.READ_WRITE)
				if logger.file != null:
					logger.file.seek_end()
			else:
				logger.file = FileAccess.open(logger.path, FileAccess.WRITE)
	OS.add_logger(logger)
	if index < 0 and logger.file == null:
		push_warning("Cannot open Graffitty log: " + logger.path)


static func error_count() -> int:
	start()
	logger.mutex.lock()
	var count := logger.failures
	logger.mutex.unlock()
	return count


static func collect() -> bool:
	start()
	logger.mutex.lock()
	var entries := logger.pending.duplicate()
	logger.pending.clear()
	logger.mutex.unlock()
	if entries.is_empty():
		return false
	history.append_array(entries)
	while history.size() > 200:
		history.pop_front()
	revision += 1
	return true


static func log_path() -> String:
	start()
	return logger.path

static func user_message(message: String) -> void:
	start()
	logger.mutex.lock()
	logger.pending.append({"message":message,"file":"","line":0,"warning":false,"trace":"","function":""})
	if logger.pending.size() > 200: logger.pending.pop_front()
	if logger.file != null:
		logger.file.store_line(message)
		logger.file.flush()
	logger.mutex.unlock()
