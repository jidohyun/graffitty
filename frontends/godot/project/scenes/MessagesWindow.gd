extends "res://scenes/TranslucentPanelWindow.gd"
## Dockable home of the Graffitty messages panel. DiagnosticPanel owns the
## content and decides when messages are shown; this window owns docking,
## chrome and placement. Closing from the dock chrome dismisses the messages.
var controller: Node
var slot := VBoxContainer.new()


func dock_sides() -> Array[String]:
	return ["top", "bottom", "left", "right"]


func default_dock_side() -> String:
	return "bottom"


## Messages sit below the status line, at the window edge, not between it and the terminal.
func default_dock_row() -> String:
	return "outer"


func _ready() -> void:
	title = tr("Graffitty messages")
	persistence_key = "messages"
	background_opacity = 0.8
	var application := get_node_or_null("/root/TerminalApplication")
	if application != null:
		for host in application.hosts:
			if is_instance_valid(host) and host.get_window() == get_parent():
				source = host
				break
	set_meta(&"preferred_size", Vector2i(420, 180))
	super()


func _create_content() -> Control:
	slot.add_theme_constant_override("separation", 0)
	slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return slot


func _compact_changed() -> void:
	if is_instance_valid(controller): controller.set_compact(compact)


func _close_panel() -> void:
	if is_instance_valid(controller): controller.dismiss_messages()
	else: release()


## Leaves the dock layout and frees the window, after the content moved out.
func release() -> void:
	super._close_panel()
