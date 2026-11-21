extends "res://tests/unit/test_case.gd"
const Capture := preload("res://scenes/input/DictationCapture.gd")
const Dictation := preload("res://scenes/input/Dictation.gd")
const Transcriber := preload("res://scenes/input/DictationTranscriber.gd")

func test_desktop_native_capture_does_not_require_godot_input() -> void:
	if not (OS.has_feature("macos") or OS.has_feature("windows") or OS.has_feature("linux")): return
	expect(not ProjectSettings.get_setting_with_override("audio/driver/enable_input"), "Desktop startup must not initialize Godot microphone input")
	expect(DictationAudio.has_native_capture(), "Desktop dictation retains native capture support")
	var native := DictationAudio.new()
	var result := native.poll_capture()
	expect(result.done and result.frames.is_empty(), "Constructing the capture interface leaves the microphone idle")
	native.stop_capture()
	native.cancel_capture()

func test_live_audio_arrives_before_stop_and_keeps_quiet_partial_word() -> void:
	var recorder := Capture.new()
	recorder.live = true
	recorder.rate = 48000
	var chunks: Array = []
	recorder.pcm.connect(func(pcm): chunks.append(pcm))
	var frames := PackedVector2Array()
	frames.resize(4817)
	frames.fill(Vector2(.001, .001)) # Below the old local speech gate.
	recorder.consume(frames)
	expect(chunks.size() == 1 and chunks[0].size() == 9600, "First 100 ms streams before stop, even for quiet speech")
	recorder.flush()
	expect(chunks.size() == 2 and chunks[1].size() == 34, "All seventeen tail samples survive without silence padding")
	expect(chunks[1].decode_s16(0) == 33, "PCM amplitude is retained")
	recorder.flush()
	expect(chunks.size() == 2, "Final flush cannot repeat audio")
	recorder.free()

func test_stop_drain_failure_is_reported_before_completion() -> void:
	var recorder := Capture.new()
	recorder.live = true
	var events: Array = []
	recorder.failed.connect(func(_message): events.append("failed"))
	recorder.finished.connect(func(): events.append("finished"))
	recorder._complete("Missing microphone tail")
	expect(events == ["failed", "finished"], "An incomplete final word must never be auto-sent before its error is known")
	recorder.free()

func _failure_fixture(live: bool) -> Dictionary:
	var recorder := Capture.new()
	recorder.live = live
	recorder.rate = 48000
	var out := {"recorder": recorder, "audio": [], "events": []}
	recorder.pcm.connect(func(pcm): out.audio.append(pcm))
	recorder.segment.connect(func(opus): out.audio.append(opus))
	recorder.failed.connect(func(_message): out.events.append("failed"))
	recorder.finished.connect(func(): out.events.append("finished"))
	recorder.recording = true
	return out

func _loud(count: int) -> PackedVector2Array:
	var frames := PackedVector2Array()
	frames.resize(count)
	frames.fill(Vector2(.2, .2))
	return frames

func test_failed_live_capture_drops_queued_and_same_poll_audio() -> void:
	var f := _failure_fixture(true)
	var recorder: Node = f.recorder
	recorder.consume(_loud(4817)) # 100 ms streams; 17 samples stay queued
	var streamed: int = f.audio.size()
	# The failing poll carries enough frames that consume() would flush another chunk.
	recorder._handle_poll({"frames": _loud(9600), "done": true, "error": "Microphone was interrupted"})
	expect(f.audio.size() == streamed, "Failure neither flushes the queued tail nor consumes the failing poll's frames")
	expect(f.events == ["failed", "finished"], "Failure is reported before completion")
	expect(recorder.samples.is_empty() and not recorder.draining and not recorder.recording, "Buffers and state are cleared")
	recorder.free()

func test_failed_segmented_capture_never_submits_speech() -> void:
	var f := _failure_fixture(false)
	var recorder: Node = f.recorder
	recorder.consume(_loud(24000)) # Speech below the segment-size and silence thresholds
	expect(recorder.spoken and f.audio.is_empty(), "Speech is buffered, not yet sent")
	recorder._handle_poll({"frames": PackedVector2Array(), "done": true, "error": "Missing microphone tail"})
	expect(f.audio.is_empty(), "Failed segmented capture sends nothing")
	expect(f.events == ["failed", "finished"] and recorder.samples.is_empty() and not recorder.spoken, "Ordered failure and cleared buffers")
	# A failing poll whose frames alone would trigger a size flush must not send either.
	f = _failure_fixture(false)
	recorder = f.recorder
	recorder._handle_poll({"frames": _loud(400000), "done": true, "error": "Microphone was interrupted"})
	expect(f.audio.is_empty(), "Frames delivered with the error are discarded before consume")
	recorder.free()

func test_normal_stop_poll_still_delivers_the_tail_then_finishes() -> void:
	var f := _failure_fixture(true)
	var recorder: Node = f.recorder
	recorder._handle_poll({"frames": _loud(4817), "done": true})
	expect(f.audio.size() == 2 and f.audio[1].size() == 34, "Stop drains full chunk and the 17-sample tail")
	expect(f.events == ["finished"], "No failure on a clean stop")
	recorder.free()
	f = _failure_fixture(false)
	recorder = f.recorder
	recorder._handle_poll({"frames": _loud(24000), "done": true})
	expect(f.audio.size() == 1 and f.events == ["finished"], "Segmented stop still flushes the spoken tail")
	recorder.free()

func test_cancel_never_flushes_buffered_audio() -> void:
	var recorder := Capture.new()
	recorder.live = true
	var chunks: Array = []
	recorder.pcm.connect(func(pcm): chunks.append(pcm))
	recorder.consume(PackedVector2Array([Vector2(.1, .1)]))
	recorder.discard()
	recorder.flush()
	expect(chunks.is_empty(), "Cancel drops the unsent tail")
	recorder.free()

func test_setup_queue_preserves_short_recording_and_has_a_limit() -> void:
	var client := Transcriber.new()
	client.rate = 48000
	client.accept(PackedByteArray([1, 0, 2, 0]))
	client.stop()
	expect(client.queued.size() == 1 and client.stopping, "Stopping before setup keeps the tiny recording for upload then activityEnd")
	expect(client.queued[0][0] == 3, "Short recording is a first+final Opus batch with codec delay flushed")
	client.stop()
	expect(client.queued.size() == 1, "Repeated Stop cannot flush the codec twice")
	client.accept(PackedByteArray([3, 0]))
	expect(client.queued_bytes == 4, "No post-stop audio enters the source stream")
	client.cancel()
	expect(client.queued.is_empty(), "Cancel drops setup audio")
	client.free()
	client = Transcriber.new()
	var full_chunk := PackedByteArray()
	full_chunk.resize(9600)
	for i in 50: client.accept(full_chunk)
	client.stop()
	expect(not client.canceled and client.queued.size() == 51, "Five seconds of setup audio retain room for the codec tail")
	client.free()
	client = Transcriber.new()
	client.rate = 48000
	var oversized := PackedByteArray()
	oversized.resize(480002)
	client.accept(oversized)
	expect(client.canceled and client.queued.is_empty(), "Setup audio is bounded to five seconds")
	client.free()

func test_live_opus_compresses_before_setup_and_cancel_resets_state() -> void:
	var client := Transcriber.new()
	var pcm := PackedByteArray()
	pcm.resize(9600)
	for i in 4800: pcm.encode_s16(i * 2, int(sin(i * .0576) * 8000))
	client.accept(pcm)
	expect(client.queued.size() == 1 and client.queued[0].size() < 960, "Setup queue contains compressed Opus, not PCM")
	expect(client.queued[0][0] == 1, "First batch starts a codec stream")
	client.accept(pcm)
	expect(client.queued[1][0] == 0, "Subsequent batches retain codec state")
	client.stop()
	expect(client.queued[2][0] == 2, "Stop flushes the final codec tail")
	client.cancel()
	expect(client.queued.is_empty(), "Cancel discards encoded audio")
	client.free()
	client = Transcriber.new()
	client.accept(pcm)
	expect(client.queued[0][0] == 1, "Next recording starts with fresh codec state")
	client.free()

class GestureController extends "res://scenes/input/Dictation.gd":
	var sends := 0
	func _finish_and_send() -> void: sends += 1

func test_hold_release_and_latched_stop_only_send_once_on_release() -> void:
	var controller := GestureController.new()
	controller.press_started = Time.get_ticks_msec()
	controller._release()
	expect(controller.sends == 0, "A quick tap latches recording")
	controller.press_started = Time.get_ticks_msec() - 500
	controller._release()
	controller._release()
	expect(controller.sends == 1, "Hold release submits once")
	controller.press_started = Time.get_ticks_msec()
	controller.press_stopping = true
	controller._release()
	expect(controller.sends == 2, "A second tap stops at release, matching Polyglot timing")
	controller.free()

func test_slide_cancel_returns_mic_and_drops_draft() -> void:
	var controller := Dictation.new()
	controller.mic_position = Vector2(250, 500)
	controller.button.position = controller.mic_position
	controller.press_started = Time.get_ticks_msec()
	controller.preview.text = "Do not send"
	expect(not controller._drag(Vector2(-30, 0)), "Short drag follows the finger without canceling")
	expect(controller.button.position == Vector2(220, 500), "Mic follows left drag")
	expect(controller._drag(Vector2(-90, 0)), "Crossing the cancel threshold discards")
	expect(controller.button.position == Vector2(250, 500) and controller.preview.text.is_empty(), "Canceled mic returns to its original position")
	expect(not controller.bar.visible and not controller.submit_when_done, "Cancel cannot submit")
	controller.free()

func test_capture_drain_gates_controls_but_provider_wait_does_not() -> void:
	var controller := Dictation.new()
	controller.preview.text = "Earlier words"
	controller.capture.draining = true
	controller._refresh()
	expect(controller.button.disabled and not controller.preview.editable, "Microphone tail keeps stop/send and editing locked")
	controller.capture.draining = false
	controller.processing = true
	controller._refresh()
	expect(not controller.button.disabled and controller.preview.editable, "Provider wait must allow editing and explicit stop/cancel")
	controller.processing = false
	controller._refresh()
	expect(not controller.button.disabled and controller.preview.editable, "Input stays available after provider completion")
	controller.free()

func test_cancel_pending_result_preserves_draft_and_invalidates_late_callbacks() -> void:
	var controller := Dictation.new()
	controller.preview.text = "Manual draft"
	controller.processing = true
	controller.submit_when_done = true
	var previous := controller.generation
	controller._cancel_pending_result()
	expect(not controller.processing and not controller.submit_when_done, "Pending final cannot auto-send after an edit")
	expect(controller.generation > previous and controller.preview.text == "Manual draft", "Late transcript is invalidated without losing the draft")
	controller.free()
