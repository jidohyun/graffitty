extends Node
## Disposable Android app: keep no microphone audio on disk and call no provider.
var failures: Array[String] = []
var reports: Array = []

func check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	# Exercise real hardware with ordinary and near-immediate release.
	for seconds in [0.03, 0.3, 1.5]:
		var audio := DictationAudio.new()
		var error := audio.start_capture()
		check(error.is_empty(), "Microphone start: " + error)
		if not error.is_empty(): break
		var frames := PackedVector2Array()
		var deadline := Time.get_ticks_msec() + int(seconds * 1000)
		while Time.get_ticks_msec() < deadline:
			var pending := audio.poll_capture()
			frames.append_array(pending.frames)
			check(not pending.done, "Capture remains active before Stop")
			await get_tree().process_frame
		audio.stop_capture()
		audio.stop_capture()
		deadline = Time.get_ticks_msec() + 2000
		var last: Dictionary = {}
		while Time.get_ticks_msec() < deadline:
			last = audio.poll_capture()
			frames.append_array(last.frames)
			if last.done: break
			await get_tree().process_frame
		check(last.get("done", false), "Stop completes")
		check(not last.has("error"), "Drain: " + str(last.get("error", "")))
		if not last.has("error"):
			check(last.get("delivered_frames", -1) == frames.size(), "Done follows every queued frame")
			check(last.get("delivered_frames", 0) >= last.get("target_frames", 1), "All audio through Stop was delivered")
			check(last.get("drain_ms", 9999) < 500, "Capture drains promptly")
		if not frames.is_empty():
			var encoded := DictationAudio.encode_opus(frames, 48000)
			check(not encoded.has("error"), "Opus encoder works on Android")
			if encoded.has("audio"):
				var decoded := DictationAudio.provider_wave(encoded.audio)
				check(not decoded.has("error"), "Opus decoder works on Android")
				if decoded.has("audio"):
					check(decoded.audio.decode_u32(40) == frames.size() * 2, "Opus preserves final partial frame duration")
				last["opus_bytes"] = encoded.audio.size()
		last.erase("frames")
		last["requested_seconds"] = seconds
		reports.append(last)
		audio.cancel_capture()
		await get_tree().create_timer(0.1).timeout
	var result := {"passed":failures.is_empty(), "failures":failures, "captures":reports}
	var output := FileAccess.open("user://dictation-test-result.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(result))
	output.close()
	get_tree().quit(0 if failures.is_empty() else 1)
