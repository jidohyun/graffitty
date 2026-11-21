extends SceneTree
## Real touch controls, transport and Podman server; only microphone PCM is synthetic.
var failures: Array[String] = []
var manager: Node
var mode := OS.get_environment("GRAFFITTY_DICTATION_CASE")
var provider := OS.get_environment("GRAFFITTY_DICTATION_PROVIDER")
var model := OS.get_environment("GRAFFITTY_DICTATION_MODEL")

class FixtureCapture extends "res://scenes/input/DictationCapture.gd":
	var pending := 0.0
	func start() -> String:
		rate = 48000
		recording = true
		return ""
	func _process(delta: float) -> void:
		if not recording: return
		pending += delta
		if pending < .1: return
		pending -= .1
		var frames := PackedVector2Array()
		frames.resize(4800)
		frames.fill(Vector2(.001, .001))
		consume(frames)
	func stop() -> void:
		var tail := PackedVector2Array()
		tail.resize(17)
		tail.fill(Vector2(.001, .001))
		consume(tail)
		_complete()

func _initialize() -> void:
	root.size = Vector2i(480, 900)
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	print("PASS " if value else "FAIL ", message)
	if not value: failures.append(message)

func until(condition: Callable, seconds := 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await create_timer(.025).timeout
	return condition.call()

func _run() -> void:
	manager = load("res://scenes/remote_manager.tscn").instantiate()
	root.add_child(manager)
	var connected := await until(func():
		return (manager.view.host != null and is_instance_valid(manager.dictation)
			and manager.federation.connections.size() == 1 and manager.federation.connections[0].connected
			and manager.federation.connections[0].server_fonts.ready and not manager.view.host.sessions.is_empty()), 60)
	check(connected, "Android client connects to the container server")
	if not connected: finish(""); return
	manager._return_to_workspace()
	var mic: Node = manager.dictation
	var old: Node = mic.capture
	mic.remove_child(old)
	old.free()
	mic.capture = FixtureCapture.new()
	mic.capture.live = true
	mic.add_child(mic.capture)
	mic.capture.pcm.connect(func(pcm):
		if is_instance_valid(mic.active_client): mic.active_client.accept(pcm))
	mic.capture.failed.connect(mic._error)
	mic.capture.finished.connect(mic._capture_finished)
	await process_frame
	var host: Node = manager.view.host
	var pane := int(host.pane_focus.substr(1))
	var connection: Node = manager.federation.connections[0]
	var settings: Dictionary = await connection.remote_call(pane, "dictation.settings", {})
	var disabled := mode in ["default-disabled", "disabled"]
	check(settings.get("result", {}).get("enabled") == (not disabled), "Settings report server opt-in")
	check(not settings.get("result", {}).get("providers", {}).has("openrouter"), "OpenRouter is not advertised for dictation")
	if not disabled:
		var unsupported: Dictionary = await connection.remote_call(pane, "dictation.begin", {"provider":"openrouter", "size":100})
		check(unsupported.get("error", {}).get("code") == "dictation_provider", "Removed provider is rejected before upload")
	if disabled:
		for method in ["dictation.begin", "dictation.live.begin"]:
			var reply: Dictionary = await connection.remote_call(pane, method,
				{"enabled":true, "provider":provider, "format":"opus", "sample_rate":48000, "size":100})
			check(reply.get("error", {}).get("code") == "dictation_disabled", "Client cannot override disabled server: " + method)
	var interactive := mode in ["success", "early-stop", "cancel", "empty-commit", "failed-event", "disconnect", "final-timeout", "setup-timeout"]
	var typed := OS.get_environment("GRAFFITTY_DICTATION_TYPED")
	if interactive:
		await connection.remote_call(pane, "terminal.type", {"interval_ms":0, "text":
			"read -r line; printf '%s' \"$line\" > '" + OS.get_environment("GRAFFITTY_DICTATION_REMOTE_TYPED") + "'\n"})
		await create_timer(.3).timeout
	# Drive the floating touch handler Android uses, including release after failure.
	var press := InputEventScreenTouch.new()
	press.index = 0
	press.pressed = true
	press.position = mic.button.get_global_rect().get_center()
	mic.button.gui_input.emit(press)
	if interactive:
		if mode not in ["early-stop", "setup-timeout"]:
			if model == "gpt-live-transcribe" and mode != "empty-commit":
				check(await until(func(): return mic.preview.text == "안녕 draft"), "Live words arrive before release")
			else:
				await create_timer(.4).timeout
				check(mic.preview.text.is_empty(), "Turn transcription waits for commit")
		await create_timer(.4).timeout
		if mode == "cancel": mic.discard_button.pressed.emit()
	else:
		check(await until(func(): return mic.failed, 20), "Microphone shows its configuration error")
	var release := InputEventScreenTouch.new()
	release.index = 0
	release.position = press.position
	manager.floating._input(release)
	if interactive:
		check(await until(func(): return not mic.processing and not mic.capture.is_busy(), 20), "Recording and response collection stop")
		await create_timer(1).timeout
	else:
		await create_timer(.3).timeout
	var message: String = mic.status.text
	var expected_error := mode not in ["success", "early-stop", "cancel", "empty-commit"]
	if expected_error:
		check(mic.failed and mic.bar.is_visible_in_tree() and mic.status.is_visible_in_tree(), "Error stays visible after finger release")
		check(not mic.capture.is_busy() and not mic.processing and not mic.dispatched, "Failure stops recording without sending text")
		check(not mic.submit_when_done, "No pending automatic submission after failure")
		if mode in ["failed-event", "disconnect", "final-timeout"]:
			check(mic.preview.text == "안녕 draft", "Provider failure preserves the received preview")
		else:
			check(mic.preview.text.is_empty(), "Setup failure supplies no transcript")
		if disabled:
			check("disabled" in message and "enabled = true" in message, "Disabled error explains explicit server opt-in")
		elif mode == "missing-key":
			check(("GRAFFITTY_" + provider.to_upper() + "_API_KEY") in message and "no server API key" in message, "Missing-key error names the server environment variable")
		elif mode.begins_with("bad-key"):
			check("rejected the server's API key" in message and "valid key" in message, "Bad-key error explains that the key did not work and must be replaced")
		elif mode in ["quota-event", "rate-limit-http"]:
			check("quota" in message and "retry" in message, "Quota error explains recovery")
		elif mode == "model-error":
			check("model" in message and "server.toml" in message, "Model error names server configuration")
		elif mode.ends_with("timeout"):
			check("timed out" in message, "Timeout reports the failed phase")
		elif mode == "disconnect":
			check("disconnected" in message, "Disconnect is reported")
		else:
			check("failed" in message, "Failed transcription is reported")
		if disabled or mode == "missing-key" or mode.begins_with("bad-key"):
			check("server.toml" in message and "restart" in message.to_lower(), "Error explains server configuration and restart")
	else:
		check(not mic.failed and not mic.bar.visible, "Success or cancellation closes the microphone UI")
		check(mic.preview.text.is_empty(), "Finished UI cannot be reopened by late text")
	if interactive:
		check(not FileAccess.file_exists(typed), "Dictation never presses Enter")
		await connection.remote_call(pane, "terminal.type", {"text":"\n"})
		check(await until(func(): return FileAccess.file_exists(typed)), "Terminal completes the fixture read")
		var expected := "안녕 final words" if mode in ["success", "early-stop"] else ""
		check(FileAccess.get_file_as_string(typed) == expected, "Only the corrected final result is inserted, exactly once")
	check("invalid-test-key" not in message and "Sensitive provider detail" not in message, "Provider details and keys never reach the client")
	if mic.bar.visible:
		mic.discard_button.pressed.emit()
		check(not mic.bar.visible, "Error can be dismissed")
	var result := {"case":mode, "message":message if not message.is_empty() else "completed", "failures":failures}
	FileAccess.open(OS.get_environment("GRAFFITTY_DICTATION_RESULT"), FileAccess.WRITE).store_string(JSON.stringify(result))
	finish(message)

func finish(_message: String) -> void:
	if failures.is_empty(): print("DICTATION_CONFIG_PASS")
	if is_instance_valid(manager):
		manager.queue_free()
		await process_frame
	quit(0 if failures.is_empty() else 1)
