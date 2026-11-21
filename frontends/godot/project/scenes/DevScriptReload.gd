extends Node
## Development-only method reload. Existing instances keep their member values.
## This does not rerun constructors/_ready or reconstruct scenes and UI controls.
signal reloaded(path: String)
var roots := PackedStringArray(["res://scenes", "res://config", "res://graffitty"])
var sources: Dictionary = {}
var pending: Dictionary = {}

func _ready() -> void:
	for directory in roots:
		_scan(directory, true)
	var timer := Timer.new()
	timer.wait_time = 0.75
	timer.timeout.connect(poll)
	add_child(timer)
	timer.start()
	print("[dev] Watching GDScript. Method edits reload in place; UI construction/native changes need a restart.")

func poll() -> void:
	for directory in roots:
		_scan(directory, false)

func _scan(directory: String, initial: bool) -> void:
	for name in DirAccess.get_directories_at(directory):
		if not name.begins_with("."):
			_scan(directory.path_join(name), initial)
	for name in DirAccess.get_files_at(directory):
		if name.get_extension() != "gd": continue
		var path := directory.path_join(name)
		if path == get_script().resource_path: continue
		var source := FileAccess.get_file_as_string(path)
		if initial or not sources.has(path):
			sources[path] = source
			continue
		if source == sources[path]:
			pending.erase(path)
			continue
		# Wait for the same contents on two polls so a save can finish.
		if pending.get(path) != source:
			pending[path] = source
			continue
		pending.erase(path)
		sources[path] = source
		if not ResourceLoader.has_cached(path): continue
		var script := load(path) as GDScript
		if script == null: continue
		var previous := script.source_code
		script.source_code = source
		var error := script.reload(true)
		if error != OK:
			script.source_code = previous
			script.reload(true)
			push_warning("[dev] Reload failed; restored previous source: " + path)
			continue
		print("[dev] Reloaded " + path)
		reloaded.emit(path)
