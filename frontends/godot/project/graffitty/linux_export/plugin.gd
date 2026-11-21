@tool
extends EditorPlugin
## Keep the same entry point in extracted archives, desktop files and installs.
class Launcher extends EditorExportPlugin:
	var output := ""

	func _get_name() -> String:
		return "GraffittyLinuxLauncher"

	func _export_begin(features: PackedStringArray, _debug: bool, path: String, _flags: int) -> void:
		output = path if "linux" in features and path.get_file() == "gft-gui" else ""

	func _export_end() -> void:
		if output.is_empty() or not FileAccess.file_exists(output):
			return
		var runtime := output.get_base_dir().path_join("GraffittyRuntime")
		var staged := output + ".new"
		var script := ProjectSettings.globalize_path("res://graffitty/linux_export/gft-gui.sh")
		var error := DirAccess.copy_absolute(script, staged, FileAccess.get_unix_permissions(output))
		if error == OK:
			error = DirAccess.rename_absolute(output, runtime)
		if error == OK:
			error = DirAccess.rename_absolute(staged, output)
			if error != OK:
				DirAccess.rename_absolute(runtime, output)
		if error != OK:
			push_error("Linux launcher export failed (%s): %s" % [output, error_string(error)])

var launcher := Launcher.new()

func _enter_tree() -> void:
	add_export_plugin(launcher)

func _exit_tree() -> void:
	remove_export_plugin(launcher)
