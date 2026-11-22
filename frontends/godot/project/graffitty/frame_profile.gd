extends RefCounted
## Per-callback CPU accounting for the process step, reported by render_stats.
## `_process` bodies call `add(label, usec)`; totals reset with each report.
static var _usec: Dictionary = {}
static var _calls: Dictionary = {}
static var _frames := 0
static var _process_usec := 0.0
const MAX_SAMPLES := 4096
static var _frame_usec: Array[float] = []
static var _interval_usec: Array[float] = []
static var _process_started_usec := -1
static var _last_post_draw_usec := -1


static func add(label: String, usec: int) -> void:
	_usec[label] = int(_usec.get(label, 0)) + usec
	_calls[label] = int(_calls.get(label, 0)) + 1


## Called once per frame by the reporter to average the engine's process time.
static func frame() -> void:
	_frames += 1
	_process_usec += Performance.get_monitor(Performance.TIME_PROCESS) * 1_000_000.0


static func process_frame_started() -> void:
	_process_started_usec = Time.get_ticks_usec()


static func frame_post_draw() -> void:
	var now := Time.get_ticks_usec()
	if _process_started_usec >= 0:
		_add_sample(_frame_usec, now - _process_started_usec)
	if _last_post_draw_usec >= 0:
		_add_sample(_interval_usec, now - _last_post_draw_usec)
	_last_post_draw_usec = now
	_process_started_usec = -1


static func take(drawn: int = 0) -> String:
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
	var frame_stats := _stats(_frame_usec)
	var interval_stats := _stats(_interval_usec)
	var line := "[frame-profile] frames=%d drawn=%d process_avg=%.1fms accounted=%.1fms frame_ms p50=%.1f p95=%.1f p99=%.1f max=%.1f interval_ms p50=%.1f p95=%.1f p99=%.1f max=%.1f %s" % [
		_frames, drawn, _process_usec / 1000.0 / frames, accounted / 1000.0 / frames,
		frame_stats[0], frame_stats[1], frame_stats[2], frame_stats[3],
		interval_stats[0], interval_stats[1], interval_stats[2], interval_stats[3],
		" ".join(parts)]
	_usec.clear()
	_calls.clear()
	_frames = 0
	_process_usec = 0.0
	_frame_usec.clear()
	_interval_usec.clear()
	return line


static func _add_sample(samples: Array[float], usec: int) -> void:
	samples.append(float(usec))
	if samples.size() > MAX_SAMPLES:
		samples.pop_front()


static func _stats(samples: Array[float]) -> Array[float]:
	if samples.is_empty(): return [0.0, 0.0, 0.0, 0.0]
	var sorted := samples.duplicate()
	sorted.sort()
	return [
		sorted[_percentile_index(sorted.size(), 0.50)] / 1000.0,
		sorted[_percentile_index(sorted.size(), 0.95)] / 1000.0,
		sorted[_percentile_index(sorted.size(), 0.99)] / 1000.0,
		sorted.back() / 1000.0,
	]


static func _percentile_index(size: int, percentile: float) -> int:
	return mini(int(ceil(float(size) * percentile)) - 1, size - 1)
