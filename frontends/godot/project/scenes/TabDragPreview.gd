extends Window
## A decorated native window carrying the live compositor until drop commits.
## The receiving host takes over this same window; no second scene runs mid-drag.
var content := TextureRect.new()
var header: Control
var group_canvas: Node2D
var _composite := ShaderMaterial.new()
var grab_offset := Vector2.ZERO
var _title := ""
var _tab_id := -1
var _grab_x := 20.0
var _grab_y := 16.0
var _last_pointer := Vector2.INF
var _source_size := Vector2i.ZERO
var _source: WeakRef
var _presentation: SubViewport


func configure(source: Node, strip: Control, id: int, rectangles: Dictionary = {}, connections: Array = []) -> void:
	source.application.configure_workspace_frame(self)
	_source = weakref(source)
	name = "TabDragPreview"
	title = "Graffitty"
	visible = false
	unfocusable = true
	always_on_top = true
	transparent = source.get_window().transparent
	transparent_bg = source.get_window().transparent_bg
	min_size = Vector2i(480, 300)
	extend_to_title = DisplayServer.has_feature(DisplayServer.FEATURE_EXTEND_TO_TITLE)
	set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	_source_size = source.get_window().size
	size = _source_size
	content_scale_mode = source.get_window().content_scale_mode
	content_scale_aspect = source.get_window().content_scale_aspect
	content_scale_size = source.get_window().content_scale_size
	content_scale_factor = source.get_window().content_scale_factor
	var is_tab: bool = "buttons" in strip
	var width: float = strip._tab_width if is_tab else 280.0
	_grab_x = clampf(strip._grab_offset if is_tab else 20.0, 8, width - 8)
	_grab_y = strip._press_point.y if is_tab else 16.0
	_title = str(strip.buttons[id].get_meta("title", "Terminal")) if is_tab else strip.handle.text
	_tab_id = id
	theme = source.workspace_view.tab_bar.get_theme()
	content.texture = source.get_window().get_texture()
	content.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	content.stretch_mode = TextureRect.STRETCH_SCALE
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.z_index = -1
	# Window textures already contain premultiplied coverage. Preserve both
	# their configured alpha and their colors when carrying them into a window.
	_composite.shader = preload("res://scenes/tab_drag_preview.gdshader")
	_composite.set_shader_parameter("world_texture", source.world_viewport.get_texture())
	content.material = _composite
	add_child(content)
	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if not rectangles.is_empty():
		content.texture = null
		content.material = null
		group_canvas = Node2D.new()
		add_child(group_canvas)
		var preview := preload("res://scenes/WorkspaceDropPreview.gd").new()
		group_canvas.add_child(preview)
		var keys: Array[String] = []
		keys.assign(rectangles.keys())
		preview.present({"tree": {}, "incoming": keys, "rectangles": rectangles}, Rect2(), Vector2.ZERO, true)
		preview.connections = connections
		var logical_size := Vector2(size) / content_scale_factor
		var available := logical_size - Vector2(80, 160)
		var scale_factor := minf(available.x / preview.size.x, available.y / preview.size.y)
		group_canvas.scale = Vector2.ONE * scale_factor
		group_canvas.position = (logical_size - preview.size * scale_factor) * 0.5 - preview.position * scale_factor
		_title = tr("Connected group (%d panes)") % keys.size()
	# Replace the source's title strip with the live world before drawing this
	# one-tab strip. Its selected opening must reveal the world, not frame color.
	header = preload("res://scenes/TerminalTabBar.tscn").instantiate()
	add_child(header)
	header.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	header.item_rect_changed.connect(_sync_grab)


func _ready() -> void:
	header.present_tabs([{"id": _tab_id, "title": _title, "progress_state": 0, "progress_value": -1}], _tab_id)
	header.tabs.layout_changed.connect(_sync_grab)
	dpi_changed.connect(_sync_grab, CONNECT_DEFERRED)
	visibility_changed.connect(_shown, CONNECT_DEFERRED)
	_sync_grab()


func _shown() -> void:
	if not visible: return
	# Removing Windows' native caption expands the client area. Restore the
	# source client size after attaching our frame, then measure its tab grip.
	preload("res://scenes/NativeWindowFrame.gd").acquire(self)
	size = _source_size
	_sync_grab.call_deferred()


func _sync_grab() -> void:
	if not is_instance_valid(header) or not header.is_node_ready(): return
	_composite.set_shader_parameter("header_fraction", header.size.y / maxf(content.size.y, 1.0))
	var button: Button = header.tabs.buttons.get(_tab_id)
	if button == null: return
	# The first tab moves right of the traffic lights. Keep the same point on
	# its label under the pointer, including on a Retina display.
	grab_offset = get_screen_transform() * (button.global_position + Vector2(_grab_x, _grab_y))
	if _last_pointer.is_finite(): follow(_last_pointer)


func follow(screen_position: Vector2) -> void:
	# No interpolation here: lag between pointer and window feels like friction.
	_last_pointer = screen_position
	preload("res://scenes/NativeWindowFrame.gd").move_window(self, Vector2i((screen_position - grab_offset).round()))


func retain_presentation() -> void:
	# Copy drawing state before the source changes tabs. This window owns the
	# scene, terminal commands and render targets until the receiver takes over.
	_last_pointer = Vector2.INF
	if content.texture == null or _presentation != null: return
	var source: Node = _source.get_ref()
	if not is_instance_valid(source): return
	_presentation = preload("res://scenes/RetainedPresentation.gd").workspace(source)
	add_child(_presentation)
	content.texture = _presentation.get_texture()
	# The retained scene omits the source tab bar; our one-tab header draws above.
	content.material = ShaderMaterial.new()
	content.material.shader = preload("res://scenes/terminal_composite.gdshader")


func complete_handoff() -> void:
	if is_instance_valid(_presentation): _presentation.queue_free()
	_presentation = null
	if is_instance_valid(group_canvas): group_canvas.queue_free()
	for node in [content, header]:
		remove_child(node)
		node.queue_free()
	unfocusable = false
	always_on_top = false
	set_flag(Window.FLAG_MOUSE_PASSTHROUGH, false)
	if has_meta(&"graffitty_window_frame"):
		var frame = get_meta(&"graffitty_window_frame")
		if frame.has_method("_refresh_frame"): frame._refresh_frame()
	name = "DetachedWindow"
