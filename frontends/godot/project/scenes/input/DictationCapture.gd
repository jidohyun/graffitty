extends Node
## Bounded, non-overlapping speech segments; no microphone playback or disk files.
signal segment(opus: PackedByteArray)
signal pcm(audio: PackedByteArray)
signal failed(message: String)
signal level_changed(level: float)
signal finished
var native: DictationAudio
var recording := false
var draining := false
var captured_frames := 0
var generation := 0
var samples := PackedVector2Array()
var rate := 48000
var spoken := false
var quiet := 0.0
var elapsed := 0.0
var started := 0
var live := false

func start() -> String:
	if OS.has_feature("android") and not OS.request_permission("android.permission.RECORD_AUDIO"):
		return "Microphone permission is required. In Android Settings → Apps → Graffitty → Permissions → Microphone, allow access, then tap the microphone again."
	if is_busy(): return "Microphone is still finishing."
	samples.clear()
	spoken = false
	quiet = 0.0
	elapsed = 0.0
	captured_frames = 0
	started = Time.get_ticks_usec()
	# Godot audio is disabled; capture is native on every platform.
	if not DictationAudio.has_native_capture(): return "Microphone capture is unavailable on this device."
	native = DictationAudio.new()
	var error := native.start_capture()
	if not error.is_empty():
		native = null
		return error
	rate = 48000
	recording = true
	return ""

func _process(_dt: float) -> void:
	if not is_busy() or native == null: return
	_handle_poll(native.poll_capture())

func _handle_poll(result: Dictionary) -> void:
	var error := str(result.get("error", ""))
	# A failed capture must not be consumed: consume() can itself flush queued audio
	# into the upload path. Frames delivered alongside the error are dropped too.
	if result.done and not error.is_empty():
		_complete(error)
		return
	consume(result.frames)
	if result.done: _complete()

func consume(frames: PackedVector2Array) -> void:
	# Keep silence detection and segment limits independent of UI polling frequency.
	var step := maxi(1, rate / 50)
	var current := generation
	for offset in range(0, frames.size(), step):
		if current != generation: return
		_consume_frame(frames.slice(offset, offset + step))

func _consume_frame(frames: PackedVector2Array) -> void:
	if frames.is_empty(): return
	captured_frames += frames.size()
	var peak := 0.0
	for frame in frames: peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	level_changed.emit(peak)
	var duration := float(frames.size()) / rate
	elapsed += duration
	if live:
		samples.append_array(frames)
		var count := rate / 10
		while samples.size() >= count:
			var chunk := samples.slice(0, count)
			samples = samples.slice(count)
			_emit_pcm(chunk)
		return
	quiet = quiet + duration if peak < 0.003 else 0.0
	spoken = spoken or peak >= 0.003
	samples.append_array(frames)
	if not spoken and samples.size() > rate:
		samples = samples.slice(samples.size() - int(rate * .2))
	elif spoken and (samples.size() >= mini(rate * 8, 750000) or (quiet >= .65 and samples.size() >= rate * .5)):
		flush()

func flush() -> void:
	var frames := samples
	var should_send := spoken and not frames.is_empty()
	samples = PackedVector2Array()
	spoken = false
	quiet = 0.0
	if live:
		_emit_pcm(frames)
		return
	# Reset before emitting because the queue may stop capture from this callback.
	if should_send:
		var encoded := DictationAudio.encode_opus(frames, rate)
		if encoded.has("error"):
			stop()
			failed.emit(encoded.error)
		else:
			segment.emit(encoded.audio)

func _emit_pcm(frames: PackedVector2Array) -> void:
	if frames.is_empty(): return
	# No local speech threshold: quiet isolated words and partial final frames
	# reach the recognizer. The server applies Polyglot's stateful low-pass filter.
	var bytes := PackedByteArray()
	bytes.resize(frames.size() * 2)
	for i in frames.size():
		var sample := int(round(clampf((frames[i].x + frames[i].y) * .5, -1, 1) * 32768))
		bytes.encode_u16(i * 2, clampi(sample, -32768, 32767) & 65535)
	pcm.emit(bytes)

func is_busy() -> bool:
	return recording or draining

func stop() -> void:
	if not recording: return
	# Keep the source alive until its capture clock reaches this stop boundary;
	# native capture uses device timestamps. An empty buffer is not end-of-input.
	recording = false
	draining = true
	if native != null:
		native.stop_capture()

func _complete(error := "") -> void:
	_release_source()
	if error.is_empty():
		flush() # A normal stop sends its tail.
	else:
		_drop_buffered() # A failed recording is never submitted, even partially.
	draining = false
	level_changed.emit(0.0)
	if not error.is_empty(): failed.emit(error)
	finished.emit()

func _release_source() -> void:
	recording = false
	if native != null:
		native.cancel_capture()
		native = null

func discard() -> void:
	# Cancel is immediate and never flushes canceled audio into the upload queue.
	generation += 1
	_release_source()
	draining = false
	_drop_buffered()
	level_changed.emit(0.0)

func _drop_buffered() -> void:
	spoken = false
	quiet = 0.0
	samples = PackedVector2Array()

func _exit_tree() -> void:
	discard()

