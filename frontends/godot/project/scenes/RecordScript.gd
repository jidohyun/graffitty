extends RefCounted
## Runs a user's recording script: `-- --record-script=<file.gd>`.
##
## Release builds compile out Godot's own `--script`, so this is how an
## installed Graffitty records a scripted take. It only works while Movie
## Maker is recording (`--write-movie`), so a normal launch never loads
## outside code. The script extends Node; it is added under the root once
## the app is running and can reach the app with `get_tree().current_scene`.

const OPTION := "--record-script="


static func path(arguments: PackedStringArray) -> String:
	for argument in arguments:
		if argument.begins_with(OPTION):
			return argument.trim_prefix(OPTION)
	return ""


static func attach(tree: SceneTree) -> void:
	var file := path(OS.get_cmdline_user_args())
	if file.is_empty():
		return
	if not OS.has_feature("movie"):
		printerr("--record-script runs only while recording; add --write-movie <file>.")
		tree.quit(1)
		return
	var script = load(file) if FileAccess.file_exists(file) else null
	if not script is GDScript or not script.can_instantiate():
		printerr("--record-script: cannot load %s" % file)
		tree.quit(1)
		return
	var node = script.new()
	if not node is Node:
		printerr("--record-script: %s must extend Node" % file)
		tree.quit(1)
		return
	node.name = "RecordScript"
	tree.root.add_child(node)
