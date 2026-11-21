extends Node
## The launcher owns retry policy. Only the engine can acknowledge drawn frames.
const Paths := preload("res://graffitty/paths.gd")
const WindowTransparency := preload("res://graffitty/window_transparency.gd")
const NOTICE := "Using %s for graphics. Updating your GPU driver may restore all effects."
# CPU rendering starts with the software defaults (flat world, effects off);
# a driver update is not necessarily the cause or the remedy.
const CPU_NOTICE := "Graffitty is rendering with the CPU, so effects are off by default."

# Only renderer-originated device-loss diagnostics attribute an exit to the GPU.
# Godot invokes Logger on rendering threads as well as the main thread.
class DeviceFaultLogger extends Logger:
	var marker: String
	var mutex := Mutex.new()

	func _log_error(_function: String, file: String, _line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != Logger.ERROR_TYPE_ERROR or not ("/drivers/" in ("/" + file.replace("\\", "/")) or "/servers/rendering/" in ("/" + file)):
			return
		var detail := (code + " " + rationale).to_lower()
		for signature in ["dxgi_error_device_removed", "0x887a0005", "dxgi_error_device_hung", "0x887a0006", "dxgi_error_device_reset", "0x887a0007", "vk_error_device_lost", "device lost", "device was lost", "gl_context_lost"]:
			if signature in detail:
				mutex.lock()
				var out := FileAccess.open(marker, FileAccess.WRITE)
				if out != null:
					out.store_string(signature)
				mutex.unlock()
				return

var pending := ""
var fault_logger: DeviceFaultLogger
var last_heartbeat := 0

func _process(_delta: float) -> void:
	if not pending.is_empty() and Time.get_ticks_msec() - last_heartbeat >= 1000:
		# A minimized but responsive frontend can legitimately stop presenting.
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
			last_heartbeat = Time.get_ticks_msec()
			_write(pending.path_join("progress"), "minimized %d" % last_heartbeat)

func _exit_tree() -> void:
	if fault_logger != null:
		OS.remove_logger(fault_logger)
	if not pending.is_empty():
		_write(pending.path_join("closed"), "")

func _ready() -> void:
	set_process(false)
	var attempt := OS.get_environment("GRAFFITTY_GPU_ATTEMPT")
	if attempt.is_empty() or DisplayServer.get_name() == "headless":
		return
	var mode := OS.get_environment("GRAFFITTY_GPU_MODE")
	var expected := OS.get_environment("GRAFFITTY_GPU_EXPECTED")
	for key in ["ATTEMPT", "MODE", "EXPECTED"]:
		OS.unset_environment("GRAFFITTY_GPU_" + key)
	var state := Paths.stdpath("state").path_join("gpu").simplify_path()
	if attempt.replace("\\", "/").get_base_dir().simplify_path() != state.replace("\\", "/"):
		return
	_write(attempt.path_join("progress"), "autoload")
	fault_logger = DeviceFaultLogger.new()
	fault_logger.marker = attempt.path_join("device-lost")
	OS.add_logger(fault_logger)
	if mode == "software":
		# Mesa has initialized. Child terminals and future launches must inherit
		# the caller's original choice.
		if OS.has_environment("GRAFFITTY_GPU_ORIGINAL_SOFTWARE"):
			OS.set_environment("LIBGL_ALWAYS_SOFTWARE", OS.get_environment("GRAFFITTY_GPU_ORIGINAL_SOFTWARE"))
		else:
			OS.unset_environment("LIBGL_ALWAYS_SOFTWARE")
		OS.unset_environment("GRAFFITTY_GPU_ORIGINAL_SOFTWARE")
	var driver := RenderingServer.get_current_rendering_driver_name()
	var adapter := {
		"renderer": driver,
		"adapter": RenderingServer.get_video_adapter_name(),
		"api": RenderingServer.get_video_adapter_api_version(),
	}
	var presentation := {
		"display_server": DisplayServer.get_name(),
		"transparency_at_startup": WindowTransparency.available(),
		"godot_transparency_after_draw": null,
		"transparency_after_draw": null,
	}
	var observation := adapter.duplicate()
	observation.presentation = presentation
	_write(attempt.path_join("adapter"), JSON.stringify(observation))
	if not expected.is_empty() and adapter != JSON.parse_string(expected):
		_write(attempt.path_join("changed"), "")
		get_tree().quit(75)
		return
	pending = attempt
	set_process(true)
	await RenderingServer.frame_post_draw
	_write(attempt.path_join("progress"), "first-frame")
	await get_tree().create_timer(2.0).timeout
	# An idle terminal renders on demand. Request the second frame explicitly.
	_write(attempt.path_join("progress"), "second-frame")
	RenderingServer.force_draw()
	presentation.godot_transparency_after_draw = DisplayServer.is_window_transparency_available()
	presentation.transparency_after_draw = WindowTransparency.available()
	_write(attempt.path_join("adapter"), JSON.stringify(observation))
	_write(attempt.path_join("healthy"), "")
	pending = ""
	set_process(false)
	# Only the supervisor holding the history lock grants the transition notice.
	var accepted := attempt.path_join("accepted")
	for poll in range(50):
		if FileAccess.file_exists(accepted):
			break
		await get_tree().create_timer(0.1).timeout
	if FileAccess.file_exists(accepted) and FileAccess.get_file_as_string(accepted) == "1":
		var app := get_node_or_null("/root/TerminalApplication")
		if app == null:
			return
		var names := {"d3d12": "Direct3D 12", "vulkan": "Vulkan", "opengl3": "OpenGL", "opengl3_angle": "ANGLE (Direct3D 11)"}
		var name: String = "Mesa (OpenGL)" if mode == "software" else names.get(driver, driver)
		# The shared Rust test reads the device type as well as the adapter name.
		var cpu := mode == "software" or bool(ClassDB.class_call_static("ClientConfig", "software_renderer"))
		# Like Chromium, a fallback that keeps the full renderer stays silent;
		# the GPU history records it. Only lost effects are worth a notice.
		if not cpu and RenderingServer.get_current_rendering_method() != "gl_compatibility":
			return
		var notice := CPU_NOTICE if cpu else NOTICE
		var args: Array = [] if cpu else [name]
		var message := tr(notice) % args if not args.is_empty() else tr(notice)
		if not app.hosts.is_empty():
			app.notifications.post("Graffitty", message, app.hosts.front(), "info", 8.0, "gpu-startup", {"body": notice, "args": args})
		else:
			# The connection chooser can start without a terminal host.
			var layer := CanvasLayer.new()
			layer.layer = 100
			add_child(layer)
			var panel := PanelContainer.new()
			layer.add_child(panel)
			panel.position = Vector2(16, 16)
			var label := Label.new()
			label.custom_minimum_size.x = minf(400, get_viewport().get_visible_rect().size.x - 32)
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			label.text = message
			panel.add_child(label)
			await get_tree().create_timer(8.0).timeout
			layer.queue_free()

func _write(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)
