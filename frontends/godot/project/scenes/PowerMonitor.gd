extends Node
## One OS subscription per application. Signals are delivered on the main thread.
signal source_changed(on_battery: bool)
signal availability_changed(available: bool)
var available := false
var on_battery := false
var _process_info: Dictionary = {}
var _reader: Thread


func _ready() -> void:
	var binary := preload("res://graffitty/executables.gd").cli()
	# Obtain the initial state before the first world is created. The watcher
	# also sends an initial snapshot after subscribing, closing the startup gap.
	var output: Array = []
	if OS.execute(binary, ["--power-state"], output) == 0 and not output.is_empty():
		_accept(JSON.parse_string(str(output[0])))
	_process_info = OS.execute_with_pipe(binary, ["--power-monitor"])
	if _process_info.is_empty():
		_accept({"available": false})
		return
	_reader = Thread.new()
	_reader.start(_read_events.bind(_process_info.stdio))


func _read_events(pipe: FileAccess) -> void:
	while true:
		var line := pipe.get_line()
		# Godot pipe FileAccess always reports eof_reached() == false.
		if line.is_empty() and pipe.get_error() != OK: break
		var state: Variant = JSON.parse_string(line) if not line.is_empty() else null
		if state is Dictionary: _accept.call_deferred(state)
	_accept.call_deferred({"available": false})


func _accept(state: Variant) -> void:
	if not state is Dictionary or not state.get("available") is bool: return
	var known: bool = state.available and state.get("on_battery") is bool
	var was_available := available
	var changed: bool = known and (not available or on_battery != state.on_battery)
	available = known
	if known: on_battery = state.on_battery
	if was_available != available: availability_changed.emit(available)
	# Unknown is never interpreted as external power. Repeated percentage or
	# charging notifications must not reset a user's manual world selection.
	if changed: source_changed.emit(on_battery)


func _exit_tree() -> void:
	if not _process_info.is_empty() and OS.is_process_running(_process_info.pid):
		OS.kill(_process_info.pid)
	if _reader != null: _reader.wait_to_finish()
