extends Node
class_name TerminalResourceMonitor
## Data-only per-terminal API. A world owns its controls, never this sampler.
signal snapshot_changed(data: Dictionary)
signal state_changed(status: String)

var terminal_id := -1
var interval_seconds := 5.0
var enabled := true
var paused := false
var remote := false
var _service: RefCounted
var _terminal: Node
var _registered := false
var _snapshot: Dictionary = { "status": "starting" }
var _poll_timer: Timer
var _await_revision := -1
var _revision := -1
var _received_msec := 0
var _reported_stale := false
var cpu_percent: float:
	get:
		return float(_snapshot.get("cpu_percent", 0.0))
var cpu_valid: bool:
	get:
		return bool(_snapshot.get("cpu_valid", false))
var memory_current: int:
	get:
		return int(_snapshot.get("memory_current", 0))
var cpu_time: float:
	get:
		return float(_snapshot.get("cpu_time", 0.0))
var status: String:
	get:
		return str(_snapshot.get("status", "starting"))


func _ready() -> void:
	if remote: return
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 0.1
	_poll_timer.timeout.connect(_poll)
	add_child(_poll_timer)
	_poll_timer.start()


func _wake() -> void:
	_await_revision = _revision
	if _poll_timer != null:
		_poll_timer.start(0.1)


func configure(service: RefCounted, id: int, terminal: Node, config: ConfigFile, is_remote := false) -> void:
	remote = is_remote
	_service = service
	terminal_id = id
	_terminal = terminal
	enabled = bool(config.get_value("resource_monitor", "enabled", true))
	interval_seconds = parse_interval(config.get_value("resource_monitor", "interval", "5s"))
	for arg in OS.get_cmdline_user_args():
		if arg == "--resource-monitor=off":
			enabled = false
		elif arg.begins_with("--resource-interval="):
			interval_seconds = parse_interval(arg.get_slice("=", 1))


static func parse_interval(value: Variant) -> float:
	var text := str(value).strip_edges()
	var scale := 1.0
	if text.ends_with("ms"):
		text = text.trim_suffix("ms")
		scale = 0.001
	elif text.ends_with("s"):
		text = text.trim_suffix("s")
	if not text.is_valid_float() or not is_finite(text.to_float()):
		return 5.0
	return clampf(text.to_float() * scale, 0.1, 3600.0)


func snapshot() -> Dictionary:
	var data := _snapshot.duplicate(true)
	if float(data.get("sample_age_seconds", -1.0)) >= 0.0:
		data["sample_age_seconds"] += (Time.get_ticks_msec() - _received_msec) / 1000.0
		if remote and data.get("status", "") == "running" and float(data.sample_age_seconds) > maxf(2.0, interval_seconds * 3.0):
			data.status = "stale"
	return data


func _process(_delta: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(_delta)
	preload("res://graffitty/frame_profile.gd").add("TerminalResourceMonitor", Time.get_ticks_usec() - profiled_started)


func _process_body(_delta: float) -> void:
	if not remote or _reported_stale or _snapshot.get("status", "") != "running": return
	var age := float(_snapshot.get("sample_age_seconds", -1.0))
	if age < 0.0: return
	age += (Time.get_ticks_msec() - _received_msec) / 1000.0
	if age > maxf(2.0, interval_seconds * 3.0):
		# Deep-copy the process inventory only when publishing, not every
		# rendered frame for every agent pane.
		_reported_stale = true
		state_changed.emit("stale")
		snapshot_changed.emit(snapshot())


func apply_remote(data: Dictionary, interval: float) -> void:
	if not remote: return
	var previous := str(_snapshot.get("status", "starting"))
	_snapshot = data.duplicate(true)
	_reported_stale = false
	_received_msec = Time.get_ticks_msec()
	interval_seconds = interval
	if previous != str(_snapshot.get("status", "starting")):
		state_changed.emit(str(_snapshot.get("status", "starting")))
	snapshot_changed.emit(snapshot())


func set_enabled(value: bool) -> void:
	if enabled == value:
		return
	enabled = value
	_wake()
	if not _registered:
		return
	if enabled:
		# Disabled time is explicitly not included in a fresh observation epoch.
		_service.reset_terminal(terminal_id)
		paused = false
		_service.resume_terminal(terminal_id)
	else:
		_service.pause_terminal(terminal_id)
	_refresh()


func pause() -> void:
	if paused:
		return
	paused = true
	_wake()
	if _registered:
		_service.pause_terminal(terminal_id)


func resume() -> void:
	if not enabled:
		set_enabled(true)
		return
	paused = false
	_wake()
	if _registered:
		_service.resume_terminal(terminal_id)


func reset() -> void:
	_wake()
	if _registered:
		_service.reset_terminal(terminal_id)


func set_interval(seconds: float) -> void:
	interval_seconds = parse_interval(seconds)
	if _registered:
		_service.set_interval(terminal_id, interval_seconds)
	if _poll_timer != null and not _poll_timer.is_stopped():
		_poll_timer.start(minf(interval_seconds, 0.2))


func _poll() -> void:
	if _service == null:
		if _snapshot.status != "unavailable":
			_snapshot = {
				"status": "unavailable",
				"error": "Native resource monitor is not installed",
			}
			state_changed.emit("unavailable")
			snapshot_changed.emit(snapshot())
		_poll_timer.stop()
		return
	if not _registered and is_instance_valid(_terminal):
		var pid := int(_terminal.get_shell_pid())
		if pid > 0:
			_service.register_terminal(terminal_id, pid, interval_seconds, enabled and not paused)
			_registered = true
	if _registered:
		_refresh()


func _refresh() -> void:
	var next: Dictionary = _service.snapshot(terminal_id)
	var native_status := str(next.get("status", "starting"))
	if not enabled:
		next["status"] = "disabled"
	var revision := int(next.get("revision", -1))
	var status := str(next.get("status", "starting"))
	if _poll_timer != null:
		if native_status == "paused" and revision != _await_revision:
			# Stop only after the worker acknowledges pause/reset, not before.
			_poll_timer.stop()
		elif native_status != "starting" and revision != _await_revision:
			# Copy the inventory at sample cadence, not five times each second.
			_poll_timer.wait_time = interval_seconds
	if revision == _revision and status == _snapshot.get("status"):
		return
	var old_status := str(_snapshot.get("status", "starting"))
	_revision = revision
	_snapshot = next
	_received_msec = Time.get_ticks_msec()
	if old_status != status:
		state_changed.emit(status)
	snapshot_changed.emit(snapshot())


func _exit_tree() -> void:
	if _registered and _service != null:
		_service.remove_terminal(terminal_id)
	_service = null
