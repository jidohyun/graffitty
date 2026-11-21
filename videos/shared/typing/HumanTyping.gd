extends RefCounted
## Offline, frame-quantized human cadence. Runtime never reads the source ZIP.
const DEFAULT_PATH := "res://videos/shared/typing/timings.json"
var phrases: Dictionary
var uses: Dictionary = {}
var source_hash := ""

func _init(path := DEFAULT_PATH) -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert(int(data.fps) == 60, "Typing schedules use the demo's 60 fps clock")
	phrases = data.phrases
	source_hash = FileAccess.get_sha256(path)

func frames_before(text: String) -> Array:
	assert(phrases.has(text), "Add the demo phrase to typing/phrases.json and run build.py: " + text)
	var variants: Array = phrases[text].variants
	var occurrence: int = int(uses.get(text, 0))
	uses[text] = occurrence + 1
	var frames: Array = variants[occurrence % variants.size()].frames_before
	assert(frames.size() == text.length(), "One timing entry per character")
	return frames
