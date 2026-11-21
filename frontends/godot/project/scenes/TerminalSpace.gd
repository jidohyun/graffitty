extends "res://scenes/WorkspaceView.gd"
## Optional complete terminal space. Inherit TerminalSpace.tscn to skin/wire UI.
@export_node_path("Control") var tab_strip_path: NodePath
@export_node_path("Button") var tile_button_path: NodePath
@export_node_path("Button") var split_right_button_path: NodePath
@export_node_path("Button") var split_down_button_path: NodePath
@export_node_path("Button") var overview_button_path: NodePath
@export_node_path("Button") var main_button_path: NodePath
@export var show_workspace_controls := true
@export var show_tab_strip := true


func _ready() -> void:
	if not tab_strip_path.is_empty():
		tab_bar = get_node(tab_strip_path)
		tab_bar.bind_host(host)
	for field in [
		"tile_button",
		"split_right_button",
		"split_down_button",
		"overview_button",
		"main_button",
	]:
		var path: NodePath = get(field + "_path")
		if not path.is_empty():
			if get(field) != null:
				get(field).free()
			set(field, get_node(path))
	super._ready()
	toolbar.visible = show_workspace_controls and toolbar.get_child_count() > 0
	tab_bar.visible = show_tab_strip
