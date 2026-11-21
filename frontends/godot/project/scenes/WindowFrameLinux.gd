extends Node
## Client-side decorations for X11 and Wayland, including GNOME. Movement and
## resizing use native window management when the desktop supports it.
const ActionStyle := preload("res://scenes/TabActionStyle.gd")
const WindowTransparency := preload("res://graffitty/window_transparency.gd")
const BUTTON_WIDTH := 44.0
const EDGE := 5.0
const RADIUS := 12.0
enum Mode { SYSTEM, ROUNDED, OPAQUE, SQUARE }
var decorations := "client"
var mode := Mode.SYSTEM
var _world_transparent := false
static var _desktop_layout: String
var left_buttons := HBoxContainer.new()
var _window_id := DisplayServer.INVALID_WINDOW_ID
var _window_mode := Window.MODE_WINDOWED
var _pixel_size := Vector2i.ZERO
var _radius_px := 0.0
var _passthrough := false
var _x11_gesture: RefCounted
var _corner_material := ShaderMaterial.new()
var _mask := Control.new()
var native: RefCounted # Same controller interface as the Windows native frame.
var layer := CanvasLayer.new()
var buttons := HBoxContainer.new()
var minimize := Button.new()
var maximize := Button.new()
var close := Button.new()
var edges: Array[Control] = []
var _was_borderless := false
var _enabled := false


static func frame_mode(backend: String, transparent: bool, window_mode: int, tiled: bool, preference: String) -> Mode:
	if backend not in ["X11", "Wayland"] or preference == "system":
		return Mode.SYSTEM
	if window_mode != Window.MODE_WINDOWED or tiled: return Mode.SQUARE
	return Mode.ROUNDED if transparent else Mode.OPAQUE


func _ready() -> void:
	var window := get_window()
	_was_borderless = window.borderless
	if DisplayServer.get_name() == "X11":
		_x11_gesture = ClassDB.instantiate(&"X11FrameGesture")
	set_process(false)
	_world_transparent = window.transparent
	var mask_layer := CanvasLayer.new()
	mask_layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.WINDOW_CORNERS
	add_child(mask_layer)
	mask_layer.add_child(_mask)
	_mask.hide()
	_mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_corner_material.shader = preload("res://scenes/window_corner_mask.gdshader")
	_mask.draw.connect(_draw_corners)
	layer.layer = preload("res://scenes/WorkspaceLayers.gd").Order.WINDOW_CHROME
	add_child(layer)
	for group in [left_buttons, buttons]:
		group.hide()
		group.add_theme_constant_override("separation", 0)
		group.layout_direction = Control.LAYOUT_DIRECTION_LTR
		layer.add_child(group)
	var icons := ["M4 8h8", "M4 4h8v8H4z", "M4 4l8 8M12 4l-8 8"]
	var labels := ["Minimize window", "Maximize window", "Close window"]
	for i in 3:
		var button: Button = [minimize, maximize, close][i]
		ActionStyle.apply(button, icons[i], 6, 28)
		button.custom_minimum_size.x = BUTTON_WIDTH
		button.focus_mode = Control.FOCUS_NONE
		button.accessibility_name = tr(labels[i])
	var actions := {"minimize": minimize, "maximize": maximize, "close": close}
	var groups := button_layout(_get_desktop_layout())
	for side in 2:
		var group: HBoxContainer = [left_buttons, buttons][side]
		for action in groups[side]:
			group.add_child(actions[action])
	minimize.pressed.connect(
		func():
			window.mode = Window.MODE_MINIMIZED,
	)
	maximize.pressed.connect(_toggle_maximize)
	close.pressed.connect(
		func():
			window.close_requested.emit(),
	)
	var cursors := [
		Control.CURSOR_FDIAGSIZE,
		Control.CURSOR_VSIZE,
		Control.CURSOR_BDIAGSIZE,
		Control.CURSOR_HSIZE,
		Control.CURSOR_HSIZE,
		Control.CURSOR_BDIAGSIZE,
		Control.CURSOR_VSIZE,
		Control.CURSOR_FDIAGSIZE,
	]
	for edge in 8:
		var control := Control.new()
		control.hide()
		control.mouse_default_cursor_shape = cursors[edge]
		control.gui_input.connect(_resize_input.bind(edge, control))
		layer.add_child(control)
		edges.append(control)

	# A WM can change tiling or compositing without resizing the client.
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.timeout.connect(_refresh_frame)
	add_child(timer)
	timer.start()
	window.visibility_changed.connect(_refresh_frame)
	window.size_changed.connect(_refresh_frame, CONNECT_DEFERRED)
	window.dpi_changed.connect(_refresh_frame, CONNECT_DEFERRED)
	_refresh_frame()


static func _get_desktop_layout() -> String:
	if _desktop_layout.is_empty():
		_desktop_layout = ":minimize,maximize,close"
		if DisplayServer.get_name() in ["X11", "Wayland"] and OS.get_environment("XDG_CURRENT_DESKTOP").to_lower().contains("gnome"):
			var output := []
			if OS.execute("gsettings", ["get", "org.gnome.desktop.wm.preferences", "button-layout"], output) == 0 and not output.is_empty():
				_desktop_layout = str(output[0]).strip_edges().trim_prefix("'").trim_suffix("'")
	return _desktop_layout


static func button_layout(layout: String) -> Array:
	var groups := [[], []]
	for side in 2:
		for action in layout.get_slice(":", side).split(",", false):
			if action in ["minimize", "maximize", "close"] and action not in groups[0] and action not in groups[1]:
				groups[side].append(action)
	# Keep all three controls available even on desktops that advertise only close.
	var left_close: bool = "close" in groups[0]
	for action in ["minimize", "maximize", "close"]:
		if action in groups[0] or action in groups[1]: continue
		if left_close: groups[0].append(action)
		elif "close" in groups[1]: groups[1].insert(groups[1].find("close"), action)
		else: groups[1].append(action)
	return groups


func _is_tiled(backend: String, id: int) -> bool:
	if backend == "Wayland" and ClassDB.class_exists(&"GraffittyWaylandFrame"):
		return ClassDB.class_call_static(&"GraffittyWaylandFrame", &"is_tiled", id)
	if backend == "X11":
		return ClassDB.class_call_static(&"NativeWindowFrame", &"x11_is_tiled", id)
	return false


func _refresh_frame() -> void:
	var window := get_window()
	if window == null or not window.visible or window.get_window_id() < 0:
		_window_id = DisplayServer.INVALID_WINDOW_ID
		return
	var backend := DisplayServer.get_name()
	var transparent := WindowTransparency.available(window.get_window_id())
	var window_mode := window.mode
	var tiled := window_mode == Window.MODE_WINDOWED and _is_tiled(backend, window.get_window_id())
	var next := frame_mode(backend, transparent, window_mode, tiled, decorations)
	_apply_shape(next)
	set_world_transparent(_world_transparent)


func _apply_shape(next: Mode) -> void:
	var window := get_window()
	var radius := 0.0
	if next == Mode.ROUNDED:
		radius = minf(RADIUS * window.get_final_transform().get_scale().x, 0.5 * mini(window.size.x, window.size.y))
	var passthrough := window.get_flag(Window.FLAG_MOUSE_PASSTHROUGH)
	var remapped := window.get_window_id() != _window_id
	var presentation_changed := _window_mode != window.mode
	if not remapped and not presentation_changed and next == mode and window.size == _pixel_size and is_equal_approx(_radius_px, radius) and _passthrough == passthrough:
		return
	var changed := next != mode
	mode = next
	_window_id = window.get_window_id()
	_window_mode = window.mode
	_pixel_size = window.size
	_radius_px = radius
	_passthrough = passthrough
	if changed or (remapped and mode != Mode.SYSTEM):
		var borderless := _was_borderless or mode != Mode.SYSTEM
		if window.borderless != borderless: window.borderless = borderless
	if changed or remapped or presentation_changed:
		window.titlebar_changed.emit.call_deferred()
	_mask.visible = mode in [Mode.ROUNDED, Mode.OPAQUE]
	_mask.material = _corner_material if mode == Mode.ROUNDED else null
	_corner_material.set_shader_parameter("radius_px", radius)
	_mask.queue_redraw()
	if mode != Mode.SYSTEM or changed:
		_set_input_shape(radius, passthrough)


func _set_input_shape(radius: float, passthrough: bool) -> void:
	var window := get_window()
	if DisplayServer.get_name() == "X11":
		window.mouse_passthrough_polygon = _input_polygon(window.size, radius)
	elif DisplayServer.get_name() == "Wayland" and ClassDB.class_exists(&"GraffittyWaylandFrame"):
		ClassDB.class_call_static(&"GraffittyWaylandFrame", &"set_input_shape", window.get_window_id(), radius, passthrough)


func set_world_transparent(requested: bool) -> void:
	_world_transparent = requested
	var window := get_window()
	var alpha := mode == Mode.ROUNDED or (requested and WindowTransparency.available(window.get_window_id()))
	if window.transparent != alpha or window.transparent_bg != alpha:
		window.transparent = alpha


func corner_radius_px() -> float:
	return _radius_px


func _draw_corners() -> void:
	if mode == Mode.OPAQUE:
		# Fill just the outermost physical rows and columns at fractional UI scales.
		var pixel := Vector2.ONE / get_window().get_final_transform().get_scale()
		var area := Vector2(get_window().size) * pixel
		var ink := Color("#515662")
		for x: float in [0.0, area.x - pixel.x]:
			_mask.draw_rect(Rect2(x, 0, pixel.x, area.y), ink)
		for y: float in [0.0, area.y - pixel.y]:
			_mask.draw_rect(Rect2(0, y, area.x, pixel.y), ink)
		return
	# Four small quads multiply the final premultiplied color and alpha.
	# The middle of the window never incurs a screen copy or an extra draw.
	var corner := Vector2.ONE * _radius_px / get_window().get_final_transform().get_scale()
	for x: float in [0.0, _mask.size.x - corner.x]:
		for y: float in [0.0, _mask.size.y - corner.y]:
			_mask.draw_rect(Rect2(Vector2(x, y), corner), Color.WHITE)


static func _input_polygon(area: Vector2, radius: float) -> PackedVector2Array:
	var polygon := PackedVector2Array()
	if radius <= 0: return polygon
	var centers := [Vector2(radius, radius), Vector2(area.x - radius, radius),
		area - Vector2.ONE * radius, Vector2(radius, area.y - radius)]
	for corner in 4:
		for point in 9:
			var angle := PI + (corner + point / 8.0) * PI * 0.5
			polygon.append((centers[corner] + Vector2.from_angle(angle) * radius).round())
	return polygon


func margins() -> Vector3:
	var scale := get_window().get_final_transform().get_scale()
	if not _enabled: return Vector3.ZERO
	var width := BUTTON_WIDTH * scale.x
	return Vector3(left_buttons.get_child_count() * width, buttons.get_child_count() * width, 0)


func resize_border() -> float:
	var window := get_window()
	if mode not in [Mode.ROUNDED, Mode.OPAQUE] or window.unresizable: return 0.0
	var scale := window.get_final_transform().get_scale().x
	return roundf(EDGE * scale) / scale


func update_regions(bar: Control, _controls: Array) -> void:
	var window := get_window()
	_enabled = (
		mode != Mode.SYSTEM and window.mode not in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]
	)
	for group in [left_buttons, buttons]:
		group.visible = _enabled
		var width: float = BUTTON_WIDTH * group.get_child_count()
		group.position = Vector2(bar.global_position.x if group == left_buttons else bar.get_global_rect().end.x - width, bar.global_position.y)
		group.size = Vector2(width, bar.size.y)
	maximize.disabled = window.unresizable
	maximize.accessibility_name = tr("Restore window") if window.mode == Window.MODE_MAXIMIZED else tr("Maximize window")
	var area := Vector2(window.size) / window.get_final_transform().get_scale()
	var e := resize_border()
	var c := minf(RADIUS, 0.5 * minf(area.x, area.y))
	var rects := [
		Rect2(0, 0, c, c),
		Rect2(c, 0, area.x - c * 2, e),
		Rect2(area.x - c, 0, c, c),
		Rect2(0, c, e, area.y - c * 2),
		Rect2(area.x - e, c, e, area.y - c * 2),
		Rect2(0, area.y - c, c, c),
		Rect2(c, area.y - e, area.x - c * 2, e),
		Rect2(area.x - c, area.y - c, c, c),
	]
	for i in edges.size():
		edges[i].position = rects[i].position
		edges[i].size = rects[i].size
		edges[i].visible = e > 0


func title_input(event: InputEvent) -> bool:
	if not _enabled: return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and event.double_click:
			if _x11_gesture != null:
				set_process(false)
				_x11_gesture.cancel()
			_toggle_maximize()
		elif event.pressed:
			_start_gesture(event, -1)
		return true
	return false


func _toggle_maximize() -> void:
	var window := get_window()
	if window.unresizable:
		return
	window.mode = Window.MODE_WINDOWED if window.mode == Window.MODE_MAXIMIZED else Window.MODE_MAXIMIZED


func _resize_input(event: InputEvent, edge: int, control: Control) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_start_gesture(event, edge)
		control.accept_event()


func _start_gesture(event: InputEventMouseButton, edge: int) -> void:
	var window := get_window()
	if _x11_gesture != null:
		var press := Vector2i((window.get_final_transform() * event.global_position).round())
		set_process(_x11_gesture.begin(window, press, edge))
	elif edge < 0:
		# Wayland authorizes this request with the current press serial.
		DisplayServer.window_start_drag(window.get_window_id())
	else:
		DisplayServer.window_start_resize(edge, window.get_window_id())


func _process(_delta: float) -> void:
	set_process(_x11_gesture.update(get_window()))


func _exit_tree() -> void:
	if _x11_gesture != null: _x11_gesture.cancel()
	var window := get_window()
	if window != null:
		window.remove_meta(&"graffitty_window_frame")
		if not window.is_queued_for_deletion() and mode != Mode.SYSTEM:
			window.transparent = _world_transparent and WindowTransparency.available(window.get_window_id())
			if window.visible: _set_input_shape(0.0, window.get_flag(Window.FLAG_MOUSE_PASSTHROUGH))
			window.borderless = _was_borderless
