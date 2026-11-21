extends "../../../../tests/llm-e2e/replay/replay.gd"
const Dictation := preload("res://scenes/input/Dictation.gd")
const Floating := preload("res://scenes/input/FloatingButtons.gd")

class FixtureCapture extends "res://scenes/input/DictationCapture.gd":
	func start() -> String:
		rate = 48000
		recording = true
		return ""
	func stop() -> void:
		_complete()
	func _process(_dt: float) -> void: pass

class FixtureClient extends "res://scenes/input/ClientDictation.gd":
	var uploads := 0
	func _upload(upload: Dictionary, protocol: RefCounted) -> void:
		uploads += 1
		assert(upload.headers.has("Authorization: Bearer fixture"))
		_completed.call_deferred(HTTPRequest.RESULT_SUCCESS, 200, PackedStringArray(), '{"text":"final words"}'.to_utf8_buffer(), protocol)

func direct_openai() -> void:
	for abort in [false, true]:
		var client := FixtureClient.new()
		host.add_child(client)
		var events := []
		client.changed.connect(func(text: String): events.append(text))
		client.finished.connect(func(): events.append("finished"))
		client.start({"provider":"openai", "password":"fixture"})
		client.accept(PackedByteArray([1, 2]))
		check(client.uploads == 0 and events.is_empty(), "Direct recording waits for Stop")
		client.stop()
		client.stop()
		if abort: client.cancel()
		await process_frame
		check(client.uploads == 1 and events == ([] if abort else ["final words", "finished"]), "OpenAI completion honors Stop and Cancel")
		client.free()

func audio(dictation: Node, count := 4817) -> void:
	var frames := PackedVector2Array()
	frames.resize(count)
	frames.fill(Vector2(.001, .001))
	dictation.capture.consume(frames)

func settled(dictation: Node) -> void:
	var deadline := Time.get_ticks_msec() + 15000
	while dictation.processing and Time.get_ticks_msec() < deadline: await process_frame
	await hold(.15)

func play() -> void:
	await direct_openai()
	# The remaining scenarios use the private server and its mock provider.
	for key in ["GRAFFITTY_GEMINI_API_KEY", "GRAFFITTY_OPENAI_API_KEY", "GRAFFITTY_OPENROUTER_API_KEY"]: OS.unset_environment(key)
	var dictation := Dictation.new()
	var floating := Floating.new()
	host.add_child(floating)
	dictation.floating = floating
	dictation.capture.free()
	dictation.capture = FixtureCapture.new()
	dictation.host = host
	host.add_child(dictation)
	var source: String = host.pane_focus
	var source_id := int(source.substr(1))
	dictation._press()
	dictation._release()
	audio(dictation)
	var deadline := Time.get_ticks_msec() + 10000
	while dictation.preview.text.is_empty() and Time.get_ticks_msec() < deadline: await process_frame
	check(dictation.capture.recording and dictation.preview.text == "Interim words", "Live words appear before stopping, with no client key: " + dictation.status.text)
	check(is_instance_valid(dictation.active_client) and dictation.active_client.offset > 0 and dictation.active_client.offset < 960, "Live transport uses compressed Opus, not the 9600-byte PCM chunk")
	check(dictation.bar.position.y > root.get_visible_rect().size.y / 2, "Preview sits at the bottom")
	check(dictation.bar.get_global_rect().end.y <= root.get_visible_rect().size.y - 70, "Preview clears the microphone row")
	check(dictation.discard_button.is_visible_in_tree(), "Preview has a cancel cross")
	var localization: Node = root.get_node("Localization")
	var original_language: String = localization.choice
	localization.set_language("fr", false)
	await process_frame
	check(dictation.slide_hint.text == "< Faire glisser pour annuler", "French gesture hint is concise")
	check(dictation.preview.text == "Interim words", "Dictated content is never translated")
	localization.set_language(original_language, false)
	if DisplayServer.get_name() != "headless":
		await hold(.2)
		root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_DICTATION_TEST_OUTPUT") + ".png")
	var origin: Vector2 = dictation.button.position
	floating._begin("microphone", origin + Vector2(26, 26), 0)
	floating._move(origin + Vector2(26, 26) - Vector2(100, 0))
	deadline = Time.get_ticks_msec() + 1000
	while dictation.button.position != origin and Time.get_ticks_msec() < deadline: await process_frame
	check(not dictation.bar.visible and dictation.preview.text.is_empty() and dictation.button.position == origin, "Slide left cancels and restores the microphone")
	check(floating._gesture.is_empty(), "Canceled finger cannot release into Send")
	# Tap then cross cancellation must also discard already-visible words.
	dictation._press()
	dictation._release()
	audio(dictation)
	await hold(.5)
	dictation.discard_button.pressed.emit()
	await hold(.2)
	check(not dictation.bar.visible and dictation.preview.text.is_empty(), "Cross cancels and late responses cannot reopen the preview")
	# Real terminal paste: hold/release submits a word captured before setup,
	# waits for final correction, inserts once, and never presses Enter.
	var output := OS.get_environment("GRAFFITTY_DICTATION_TEST_OUTPUT")
	await host.session_backend.connection.remote_call(source_id, "terminal.type", {"interval_ms":0, "text":"read -r line; printf '%s' \"$line\" > '" + output + "'\n"})
	await hold(.3)
	dictation._press()
	audio(dictation, 480)
	dictation.press_started -= 500
	dictation._release()
	check(dictation.bar.visible and dictation.processing, "Release waits for final transcription")
	await settled(dictation)
	check(not dictation.failed and not dictation.bar.visible, "Final short word auto-sends on hold release: " + dictation.status.text)
	await dictation.send()
	check(not FileAccess.file_exists(output), "Sending does not press Enter")
	await host.session_backend.connection.remote_call(source_id, "terminal.type", {"text":"\n"})
	await hold(.3)
	check(FileAccess.get_file_as_string(output) == "안녕 final words", "Only the final corrected transcript is inserted once")
	# Latched recording's square sends into the originally focused chromium field.
	var created: Dictionary = await host.session_backend.connection.remote_call(source_id, "chromium.create", {"url":"about:blank"})
	var chromium_key: String = created.get("result", {}).get("chromium", "")
	var id := int(chromium_key.substr(1))
	deadline = Time.get_ticks_msec() + 15000
	while not host.chromiums.has(id) and Time.get_ticks_msec() < deadline: await process_frame
	check(host.chromiums.has(id), "Chromium is available for dictation")
	if not host.chromiums.has(id): return
	var chromium: Node = host.chromiums[id]
	await chromium.request("cdp", {"method":"Runtime.evaluate", "params":{"expression":"document.body.innerHTML='<textarea></textarea>'; document.querySelector('textarea').focus()"}})
	host.focus_pane(chromium_key)
	dictation._press()
	dictation._release()
	audio(dictation)
	await hold(.5)
	dictation._press()
	check(dictation.capture.recording, "Stop tap keeps the microphone alive until release")
	dictation._release()
	await settled(dictation)
	var result: Dictionary = await chromium.request("cdp", {"method":"Runtime.evaluate", "params":{"expression":"document.querySelector('textarea').value", "returnByValue":true}})
	check(result.get("result", {}).get("result", {}).get("value", "") == "안녕 final words", "Square stops and inserts the final text into Chromium once")
	# Lifecycle stop preserves a draft, and server incarnation changes block send.
	host.focus_pane(source)
	dictation._press()
	dictation._release()
	audio(dictation)
	dictation.stop()
	await settled(dictation)
	check(dictation.bar.visible and dictation.preview.text == "안녕 final words", "Lifecycle stop never submits on the user's behalf")
	dictation.server_epoch = "different-server-incarnation"
	await dictation.send()
	check(not dictation.dispatched and not dictation.preview.text.is_empty(), "Server restart cannot redirect a preserved draft")
	dictation.discard()
	dictation.queue_free()
	floating.queue_free()
	print("DICTATION_SMOKE_REPLAY_PASS")
