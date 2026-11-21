extends RefCounted
## Optional adapters. Control ownership, Theme, position and animation are the world's.
const SpaceView := preload("res://scenes/WorkspaceView.gd")
const Binding := preload("res://scenes/TerminalUIBinding.gd")
const DefaultTabStrip := preload("res://scenes/TerminalTabBar.tscn")
var host: Node


func bind(control: Control, kind: String, session_id := -1) -> Node:
	var valid := (kind == "tabs" and control is TabBar) \
			or (kind == "scroll" and control is ScrollBar) \
			or (kind == "progress" and control is ProgressBar) \
			or (kind == "title" and control is Label)
	if not valid:
		push_error("Unsupported terminal UI binding: %s" % kind)
		return null
	var binding := Binding.new()
	binding.host = host
	binding.control = control
	binding.kind = kind
	binding.session_id = session_id
	control.add_child(binding)
	return binding


func create_tab_bar() -> TabBar:
	var node := TabBar.new()
	bind(node, "tabs")
	return node


func create_tab_strip() -> HBoxContainer:
	var node := DefaultTabStrip.instantiate()
	node.bind_host(host)
	return node


func create_progress_bar(session_id := -1) -> ProgressBar:
	var node := ProgressBar.new()
	node.show_percentage = false
	bind(node, "progress", session_id)
	return node


func create_scroll_bar(session_id := -1) -> VScrollBar:
	var node := preload("res://scenes/TerminalScrollBar.gd").new()
	bind(node, "scroll", session_id)
	return node


func mount_scroll_bar(world: Node) -> VScrollBar:
	var bar := create_scroll_bar()
	bar.mount_workspace(host.workspace_view, world)
	return bar


func create_title_label(session_id := -1) -> Label:
	var node := Label.new()
	bind(node, "title", session_id)
	return node


## Unparented complete presenter. The host mounts a world's chosen scene before
## the world enters the tree, so its terminal and tabs are wired from startup.
func create_terminal_space(
	scene: PackedScene = preload("res://scenes/TerminalSpace.tscn")
) -> Control:
	var node := scene.instantiate()
	if not node is SpaceView:
		node.free()
		push_error("Terminal space must inherit WorkspaceView")
		return null
	node.bind_host(host)
	return node
