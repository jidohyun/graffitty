extends Node
## Per-window composition policy. Canvas layers are ordered here, not by widgets.
## Desktop surfaces participate in one slide; interaction chrome stays stationary.
enum Order {
	BACKGROUND = -1,
	CONTENT = 0,
	BROWSER = 1,
	WORLD_CHROME = 2,
	DOCK = 25,
	TRANSITION = 30,
	MENU = 90,
	WINDOW_CHROME = 100,
	COMMAND = 120,
	NOTIFICATION = 130,
	# Floating touch buttons are on top of everything, including embedded
	# windows (floating panels, dialogs, popups), which Godot draws on its own
	# canvas at layer 1024. FloatingButtons also keeps their taps from those windows.
	FLOATING_CONTROLS = 2000,
	POINTER_CAPTURE = 2001,
	WINDOW_CORNERS = 2002,
}
var _desktop_layers: Array[WeakRef] = []
var _slide := 0.0

static func for_window(window: Window) -> Node:
	if window.has_meta(&"workspace_layers"): return window.get_meta(&"workspace_layers")
	var owner: Node = load("res://scenes/WorkspaceLayers.gd").new()
	window.add_child(owner)
	window.set_meta(&"workspace_layers", owner)
	return owner

func create_layer(order: Order, desktop := false) -> CanvasLayer:
	var canvas := CanvasLayer.new()
	canvas.layer = order
	add_child(canvas)
	if desktop:
		_desktop_layers.append(weakref(canvas))
		canvas.offset.x = _slide
	return canvas

func slide(root: Control, origin: Vector2, displacement: float) -> void:
	_slide = displacement
	root.position = origin + Vector2(displacement, 0)
	for reference in _desktop_layers:
		var canvas = reference.get_ref()
		if is_instance_valid(canvas): canvas.offset.x = displacement
