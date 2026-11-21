@tool
extends EditorPlugin
## FileAccess-based DPI icons need source bytes even after texture import.
class IconSources extends EditorExportPlugin:
	func _get_name() -> String:
		return "GraffittyIconSources"

	func _export_begin(_features: PackedStringArray, _debug: bool, _path: String, _flags: int) -> void:
		# Export presets are local/generated on Android. Attribution must travel
		# with the artwork regardless of those presets' non-resource filters.
		for directory in ["res://scenes/icons", "res://assets/icons"]:
			for name in DirAccess.get_files_at(directory):
				if _is_attribution(name):
					var source: String = directory.path_join(name)
					add_file(source, FileAccess.get_file_as_bytes(source), false)

	func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
		if not (path.begins_with("res://assets/icons/") or path.begins_with("res://scenes/icons/")):
			return
		if path.get_extension() in ["svg", "png"]:
			add_file(path, FileAccess.get_file_as_bytes(path), false)
		elif _is_attribution(path.get_file()):
			# Already added above, even if a preset also includes non-resources.
			skip()

	func _is_attribution(name: String) -> bool:
		return name.ends_with("-LICENSE") or name in ["README.md", "SOURCES.md"]

var exporter := IconSources.new()

func _enter_tree() -> void:
	add_export_plugin(exporter)

func _exit_tree() -> void:
	remove_export_plugin(exporter)
