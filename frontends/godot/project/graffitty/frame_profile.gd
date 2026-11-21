extends RefCounted
## Per-callback CPU accounting for the process step, reported by render_stats.
## `_process` bodies call `add(label, usec)`; totals reset with each report.
static var _usec: Dictionary = {}
static var _calls: Dictionary = {}
static var _frames := 0
static var _process_usec := 0.0


static func add(label: String, usec: int) -> void:
	_usec[label] = int(_usec.get(label, 0)) + usec
	_calls[label] = int(_calls.get(label, 0)) + 1


## Called once per frame by the reporter to average the engine's process time.
static func frame() -> void:
	_frames += 1
	_process_usec += Performance.get_monitor(Performance.TIME_PROCESS) * 1_000_000.0


static func take() -> String:
	var frames := maxi(_frames, 1)
	var entries: Array = []
	var accounted := 0
	for label in _usec:
		accounted += int(_usec[label])
		entries.append([int(_usec[label]), label, int(_calls[label])])
	if ClassDB.class_exists("NativeFrameProfile"):
		var native: Dictionary = ClassDB.instantiate("NativeFrameProfile").take()
		for label in native:
			accounted += int(native[label][0])
			entries.append([int(native[label][0]), label, int(native[label][1])])
	entries.sort_custom(func(a, b): return a[0] > b[0])
	var parts := PackedStringArray()
	for entry in entries.slice(0, 12):
		parts.append("%s=%.1fms/%d" % [entry[1], entry[0] / 1000.0 / frames, entry[2]])
	var line := "[frame-profile] frames=%d process_avg=%.1fms accounted=%.1fms %s" % [
		_frames, _process_usec / 1000.0 / frames, accounted / 1000.0 / frames, " ".join(parts)]
	_usec.clear()
	_calls.clear()
	_frames = 0
	_process_usec = 0.0
	return line
