extends Node
## Same presentation API as TerminalResourceMonitor, sampled by the owner.
signal snapshot_changed(data: Dictionary)
signal state_changed(status: String)
const Intervals := preload("res://scenes/TerminalResourceMonitor.gd")
var interval_seconds := 1.0
var enabled := true
var paused := false
var _chromium: Node
var _timer: Timer
var _busy := false
var _epoch := 0
var _revision := 0
var _peak := 0
var _received_msec := 0
var _last_sample_sequence: Variant = null
var _snapshot: Dictionary = {"status": "starting", "cpu_time": null}
var cpu_percent: float:
	get: return float(_snapshot.get("cpu_percent", 0.0)) if cpu_valid else 0.0
var cpu_valid: bool:
	get: return bool(_snapshot.get("cpu_valid", false))
var memory_current: int:
	get: return int(_snapshot.get("memory_current", 0)) if _snapshot.get("memory_valid", false) else 0
var cpu_time: Variant:
	get: return _snapshot.get("cpu_time")
var status: String:
	get: return str(_snapshot.get("status", "starting"))


func configure(chromium: Node, config: ConfigFile) -> void:
	_chromium = chromium
	enabled = bool(config.get_value("resource_monitor", "enabled", true))
	for arg in OS.get_cmdline_user_args():
		if arg == "--resource-monitor=off": enabled = false
	if not enabled: _snapshot.status = "disabled"


func _ready() -> void:
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_poll)
	add_child(_timer)
	_schedule(0.1)


func _schedule(delay: float) -> void:
	if _timer != null and enabled and not paused and not _busy:
		_timer.start(maxf(delay, 0.1))


func snapshot() -> Dictionary:
	var data := _snapshot.duplicate(true)
	data["sample_age_seconds"] = (Time.get_ticks_msec() - _received_msec) / 1000.0 if _received_msec > 0 else -1.0
	return data


func _publish(data: Dictionary) -> void:
	var previous := status
	_revision += 1
	data["revision"] = _revision
	data["epoch"] = _epoch
	_snapshot = data
	if status != previous: state_changed.emit(status)
	snapshot_changed.emit(snapshot())


func _invalidate(next_status: String) -> void:
	_epoch += 1
	if _timer != null: _timer.stop()
	var data := _snapshot.duplicate(true)
	data["status"] = next_status
	data["cpu_valid"] = false
	data["coverage_gap"] = true
	_publish(data)


func set_enabled(value: bool) -> void:
	if enabled == value: return
	enabled = value
	if enabled:
		paused = false
		reset()
	else:
		_invalidate("disabled")
		_stop_tracker()


func pause() -> void:
	if paused: return
	paused = true
	_invalidate("paused" if enabled else "disabled")
	_stop_tracker()


func resume() -> void:
	if not enabled:
		set_enabled(true)
		return
	paused = false
	_invalidate("starting")
	_schedule(0.1)


func reset() -> void:
	_peak = 0
	_received_msec = 0
	_snapshot = {"status": status, "cpu_time": null}
	_invalidate("disabled" if not enabled else ("paused" if paused else "starting"))
	_schedule(0.1)


func set_interval(seconds: float) -> void:
	interval_seconds = Intervals.parse_interval(seconds)
	_schedule(interval_seconds)


func _accept_sample(response: Dictionary) -> void:
	var data: Dictionary = response.get("result", {}).duplicate(true)
	if response.has("error") or not data.has_all(["root_pid", "status", "memory_current", "revision"]):
		data = _snapshot.duplicate(true)
		data["status"] = "unavailable"
		data["error"] = str(response.get("error", "Invalid owner resource snapshot"))
		data["cpu_valid"] = false
		data["coverage_gap"] = true
	else:
		data["sample_sequence"] = data.revision
		data["memory_valid"] = data.status == "running" and int(data.get("process_count", 0)) > 0
		if data.get("status") == "running":
			if data.has("sample_sequence") and data.sample_sequence == _last_sample_sequence:
				return
			_last_sample_sequence = data.get("sample_sequence")
			_received_msec = Time.get_ticks_msec() - int(float(data.get("sample_age_seconds", 0)) * 1000.0)
		if data.get("memory_valid", false):
			_peak = maxi(_peak, int(data.memory_current))
		data["memory_peak_observed"] = _peak
	_publish(data)


func _poll() -> void:
	if not enabled or paused or _busy: return
	if not is_instance_valid(_chromium) or _chromium._closing:
		_invalidate("exited")
		return
	# The first topology can precede the owner's PID/page. Keep polling until
	# startup completes; a missing initial identity is not an exited browser.
	if _chromium.pid <= 0 or not _chromium.chromium_ready:
		_schedule(0.5)
		return
	_busy = true
	var epoch := _epoch
	var started := Time.get_ticks_msec()
	var response: Dictionary = await _chromium.request("resources", {}, 12000)
	_busy = false
	if epoch == _epoch and enabled and not paused:
		_accept_sample(response)
	# Read Chromium's cached snapshot without restarting its listener. An
	# invalidated response never repopulates a reset/paused view.
	_schedule(interval_seconds - (Time.get_ticks_msec() - started) / 1000.0)


func _stop_tracker() -> void:
	# Every browser surface has an owner-side tracker, including secondary
	# windows. Its samples describe the shared browser process tree.
	if is_instance_valid(_chromium) and _chromium.pid > 0 and not _chromium._closing:
		_chromium.command("resources", {"enabled": false})


func _exit_tree() -> void:
	_stop_tracker()
