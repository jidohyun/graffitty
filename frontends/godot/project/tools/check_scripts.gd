extends SceneTree
## Compile every supplied script without instantiating it or opening the app.
func _initialize() -> void:
	var failed := false
	var count := 0
	var paths: Variant = JSON.parse_string(FileAccess.get_file_as_string(OS.get_cmdline_user_args()[0]))
	if not paths is Array:
		printerr("ERROR: Invalid script manifest")
		quit(1)
		return
	for path in paths:
		var script := load(path) as GDScript
		count += 1
		if script == null or not script.can_instantiate():
			printerr("ERROR: Cannot compile ", path)
			failed = true
	print("Compiled %d scripts" % count)
	quit(1 if failed else 0)
