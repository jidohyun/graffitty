extends RefCounted
## The native chromium and Godot are sampled on the same movie-frame clock.
## Waiting here blocks frame advancement, not the separate Chromium process.
var r: SceneTree
var chromium: Node
var directory: String
var start_frame := -1
var last_frame := -1
var failed := false
var reused := {}


func _init(replay: SceneTree, target: Node) -> void:
	r = replay
	chromium = target
	directory = r.output.path_join("native-window")
	var reused_path: String = r.output.path_join("reused-native-window.json")
	if FileAccess.file_exists(reused_path):
		reused = JSON.parse_string(FileAccess.get_file_as_string(reused_path))


func sample() -> void:
	if failed: return
	var frame: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	if frame == last_frame: return
	if not reused.is_empty():
		# Keep the current app's exact reveal interval; the external window
		# pixels come from the approved capture instead of another screenshot run.
		if start_frame < 0: start_frame = frame
		last_frame = frame
		return
	var file := FileAccess.open(directory.path_join("request.tmp"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"frame": frame, "pid": chromium.pid}))
	file.close()
	DirAccess.rename_absolute(directory.path_join("request.tmp"), directory.path_join("request.json"))
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline:
		if FileAccess.file_exists(directory.path_join("response.json")):
			var response = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("response.json")))
			if response is Dictionary:
				if response.has("error"):
					failed = true
					r.check(false, "Native window capture: " + str(response.error))
					return
				if int(response.get("frame", -1)) == frame:
					if start_frame < 0: start_frame = frame
					last_frame = frame
					return
		# Do not await process_frame: that would advance Movie Maker while the
		# native capture is pending, accumulating drift or missing source frames.
		OS.delay_usec(1000)
	failed = true
	r.check(false, "Native window capture timed out at movie frame %d" % frame)


func begin() -> bool:
	sample()
	if failed: return false
	var dimensions: Dictionary = reused if not reused.is_empty() else JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("window.json")))
	if not r.check(int(dimensions.width) <= 1964 and int(dimensions.height) <= 1160,
		"The real native window fits the landscape composition"):
		failed = true
		return false
	RenderingServer.frame_pre_draw.connect(sample)
	return true


func finish(pointer: Vector2, duration_frames: int) -> void:
	if RenderingServer.frame_pre_draw.is_connected(sample):
		RenderingServer.frame_pre_draw.disconnect(sample)
	var end_frame: int = Engine.get_singleton("GraffittyMovieWriter").frames_written()
	r.check(not failed and last_frame == end_frame - 1,
		"Every native window frame matches its Godot movie frame")
	r.check(end_frame - start_frame == duration_frames,
		"Native reveal has the exact authored frame duration")
	var metadata: Dictionary = reused.duplicate(true) if not reused.is_empty() else JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("window.json")))
	metadata.merge({"start_frame": start_frame, "end_frame": end_frame,
		"fps": 60, "pointer_source": [pointer.x, pointer.y],
		"motion": "Captured native window; title-bar drag composited in HyperFrames"}, true)
	var file := FileAccess.open(directory.path_join("capture.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(metadata, "\t"))
	file.close()
