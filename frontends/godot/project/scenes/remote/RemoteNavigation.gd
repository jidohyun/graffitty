extends RefCounted
## One presentation boundary for connection pages and the live workspace.
## Transport state and saved credentials are deliberately not navigation state.
enum Space { MANAGER, EDITOR, WORKSPACE }
var current := Space.MANAGER
var manager: Control

func enter(next: Space) -> void:
	current = next
	manager.chooser.visible = next == Space.MANAGER
	manager.dialog.visible = next == Space.EDITOR
	apply_workspace()

func apply_workspace() -> void:
	var shown := current == Space.WORKSPACE
	if is_instance_valid(manager.view) and is_instance_valid(manager.view.host):
		var host: Node = manager.view.host
		if not shown: preload("res://scenes/input/WorkspaceMenus.gd").dismiss(host)
		if is_instance_valid(host.layout_root): host.layout_root.visible = shown
	if not manager.is_inside_tree(): return
	var window := manager.get_window()
	window.set_meta(&"workspace_ui_active", shown)
	if window.has_meta(&"list_dock_space"):
		window.get_meta(&"list_dock_space").set_workspace_active(shown)
	for panel in manager.get_tree().get_nodes_in_group(&"workspace_tool_windows"):
		if panel.get_parent().get_window() == window: panel.set_workspace_active(shown)
