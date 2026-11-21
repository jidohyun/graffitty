extends Node
## Owns the platform frame for one native window, including drag previews.
## macOS uses Godot's native frame. Linux draws its own window controls.
const META := &"graffitty_window_frame"
var native: RefCounted
var handle := 0
var _updating := false
var caption: Control


func _ready() -> void:
	var layer := CanvasLayer.new()
	layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.WINDOW_CHROME
	add_child(layer)
	caption = preload("res://scenes/WindowFrameWindows.gd").new()
	layer.add_child(caption)
	get_window().size_changed.connect(func(): caption.set_caption_state(caption.state))


func _caption_changed(state: PackedInt32Array) -> void:
	if is_instance_valid(caption): caption.set_caption_state(state)


## A hidden native Window gets a fresh HWND each time it opens.
static func watch_corners(node: Node) -> void:
	if node is Window:
		var mapped := _apply_corners.bind(node)
		if not node.visibility_changed.is_connected(mapped):
			node.visibility_changed.connect(mapped)
		_apply_corners(node)


static func _apply_corners(window: Window) -> void:
	if not window.visible or window.is_embedded() or window.get_window_id() < 0:
		return
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())
	if handle:
		ClassDB.class_call_static(&"NativeWindowFrame", &"round_corners", handle, window is Popup)


static func acquire(window: Window) -> Node:
	if window.is_embedded() or not window.visible:
		return null
	if window.has_meta(META):
		return window.get_meta(META)
	var backend := DisplayServer.get_name()
	if backend in ["X11", "Wayland"]:
		var linux_frame := preload("res://scenes/WindowFrameLinux.gd")
		var app := window.get_node("/root/TerminalApplication")
		if app.window_decorations == "system":
			return null
		var controller: Node = linux_frame.new()
		controller.decorations = app.window_decorations
		window.set_meta(META, controller)
		window.add_child(controller)
		return controller
	if backend != "Windows":
		return null
	if not ClassDB.class_exists("NativeWindowFrame"):
		return null
	var controller := new()
	controller.native = ClassDB.instantiate("NativeWindowFrame")
	controller.handle = DisplayServer.window_get_native_handle(
		DisplayServer.WINDOW_HANDLE,
		window.get_window_id(),
	)
	if not controller.native.attach(controller.handle, controller.get_instance_id()):
		controller.free()
		return null
	window.set_meta(META, controller)
	window.add_child(controller)
	return controller


static func move_window(window: Window, point: Vector2i) -> void:
	if window.has_meta(META):
		var controller: Node = window.get_meta(META)
		# A delta also handles Godot's normalized multi-monitor desktop origin.
		if controller.native != null and controller.native.move_by(
				controller.handle,
				point - window.position,
			):
			return
	window.position = point


static func resize_window(window: Window, dimensions: Vector2i) -> void:
	if window.has_meta(META):
		var controller: Node = window.get_meta(META)
		if controller.native != null and controller.native.resize_client(controller.handle, dimensions):
			return
	window.size = dimensions


func margins() -> Vector3:
	return Vector3(native.margins(handle))


func resize_border() -> float:
	# The Windows resize border is outside the client area.
	return 0.0


func update_regions(bar: Control, controls: Array) -> void:
	if _updating:
		return
	_updating = true
	var window := get_window()
	var enabled := (
		window.mode != Window.MODE_FULLSCREEN and window.mode != Window.MODE_EXCLUSIVE_FULLSCREEN
	)
	var title := _physical_rect(bar)
	var regions: Array[Rect2i] = []
	for control in controls:
		if control.is_visible_in_tree():
			regions.append(_physical_rect(control).intersection(title))
	native.update(handle, enabled, window.get_flag(Window.FLAG_MOUSE_PASSTHROUGH), title, regions)
	_updating = false


static func _physical_rect(control: Control) -> Rect2i:
	var transform := control.get_viewport().get_final_transform() * control.get_global_transform_with_canvas()
	# Round the two shared boundaries independently. Growing and truncating
	# each rectangle can assign one pixel to both a tab and its drag region.
	return preload("res://scenes/ScreenSpace.gd").pixel_bounds(transform * Rect2(Vector2.ZERO, control.size))


func _exit_tree() -> void:
	if native != null and handle != 0:
		native.detach(handle)
	var window := get_window()
	if window != null and window.has_meta(META):
		window.remove_meta(META)
