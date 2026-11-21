extends "res://scenes/TranslucentPanelWindow.gd"
## Dockable home of the notification history. NotificationOverlay owns the
## list and keeps it current; this window owns docking, chrome and placement.
var controller: Node
var slot := VBoxContainer.new()


func dock_sides() -> Array[String]:
	return ["left", "right", "top", "bottom"]


func default_dock_side() -> String:
	return "right"


func _ready() -> void:
	title = tr("Notifications")
	persistence_key = "notifications"
	background_opacity = 0.8
	var application := get_node_or_null("/root/TerminalApplication")
	if application != null:
		for host in application.hosts:
			if is_instance_valid(host) and host.get_window() == get_parent():
				source = host
				break
	set_meta(&"preferred_size", Vector2i(320, 560))
	super()


func _create_content() -> Control:
	slot.add_theme_constant_override("separation", 0)
	slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return slot


func _close_panel() -> void:
	if is_instance_valid(controller): controller.close_history()
	else: release()


## Leaves the dock layout and frees the window, after the content moved out.
func release() -> void:
	super._close_panel()
