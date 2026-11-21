extends Window
## Shared non-modal dockable window: application chrome, geometry and input ownership.
## Subclasses supply content, without reimplementing docking or window lifecycle.
const DesktopText := preload("res://scenes/DesktopText.gd")
const WindowTransparency := preload("res://graffitty/window_transparency.gd")
var footer := HBoxContainer.new()
var footer_actions_in_compact := false
var _footer_spacer := Control.new()
var _bottom_inset := 0.0
var _unobstructed := Rect2i()
var _resize_grip := Button.new()
var _resize_origin := Vector2.ZERO
var _resize_size := Vector2i.ZERO
var _resizing := false
var _resize_finger := -1
var _body: Control
var _desktop: Control
var _native_rect := Rect2i()
var _native_drag := false
var _native_candidate := {}
var _windows_move := false
var _mac_move := false
var _restore_transient := false
var _release_pointer := Vector2.INF
var _preview_was_floating := false
var _dock_preview_active := false
var _drag_from_workspace := false
var _drag_pointer_offset := Vector2.ZERO
var _drag_origin := Rect2i()
var _workspace_active := true
var _resume_visible := false
var compact := false
## Compact top/bottom bands lay content out as one status-strip row.
var compact_row := false
var persistence_key := ""
## Per-panel folding is independent of a sidebar's compact rail mode.
var folded := false
var _expanded_size := Vector2i.ZERO
var _expanded_minimum := Vector2i.ZERO
var _title_pressed := false
var _title_origin := Vector2.ZERO
var _title_moved := false
var _title_touch := -1
var _frame := Panel.new()
var _floating_title := Control.new()
var _floating_close := Button.new()
var _resize_edges: Array[Control] = []
const TITLE_HEIGHT := 24.0
## Below 1, the panel's surface lets what is behind it show through: the
## workspace when docked or embedded, the desktop when floating natively.
## Set before the window enters the tree.
var background_opacity := 1.0
const SURFACE := Color("202126")
## Narrower than this, panels show their compact rail/row form.
const COMPACT_WIDTH := preload("res://scenes/ListDockSpace.gd").COMPACT_WIDTH

func toggle_fold() -> void:
	set_folded(not folded)

func set_folded(value: bool) -> void:
	if dock_only(): value = false
	if value == folded: return
	folded = value
	if not is_instance_valid(_desktop) or _desktop.side.is_empty():
		_apply_floating_fold()
	else:
		_body.visible = not folded
		_desktop.space.reflow()
	if is_instance_valid(_desktop): _desktop.space.save_layout()

func _apply_floating_fold() -> void:
	if folded:
		if _expanded_size == Vector2i.ZERO:
			_expanded_size = size
			_expanded_minimum = min_size
		_body.hide()
		min_size = Vector2i(min_size.x, int(floating_title_height()))
		size = Vector2i(size.x, int(floating_title_height()))
	else:
		_body.show()
		if _expanded_size != Vector2i.ZERO:
			min_size = _expanded_minimum
			size = Vector2i(size.x, _expanded_size.y)
			_expanded_size = Vector2i.ZERO
	_layout_frame()
	_backdrop_changed()

func floating_rect() -> Rect2i:
	return Rect2i(position, Vector2i(size.x, _expanded_size.y) if folded and _expanded_size.y > 0 else size)

## Native screen pixels, or the embedded parent's logical coordinates.
func _title_rect() -> Rect2:
	return Rect2(Vector2(position), Vector2(maxf(0, size.x - TITLE_HEIGHT * content_scale_factor), floating_title_height()))

func compositor_drag() -> bool:
	return force_native and DisplayServer.get_name().to_lower().contains("wayland")

## Embedded input belongs to the parent viewport. A drag that undocks also
## keeps its original parent input stream until release, even over a new window.
func floating_title_input(event: InputEvent) -> bool:
	if not is_instance_valid(_desktop) or not _workspace_active: return false
	if force_native and not _drag_from_workspace: return false
	var point := Vector2.ZERO
	if not (_mac_move or _windows_move) and (event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag):
		point = _desktop.space.local_to_screen(event.position) if force_native else event.position
	return _title_event(event, point)

func _input(event: InputEvent) -> void:
	if not _workspace_active or _drag_from_workspace: return
	# Touch input on embedded windows is routed once by the parent window.
	if not force_native and is_instance_valid(_desktop): return
	var point := Vector2.ZERO
	if not (_mac_move or _windows_move) and (event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag):
		point = Vector2(position) + event.position * content_scale_factor
	if _title_event(event, point): set_input_as_handled()

func _title_event(event: InputEvent, point: Vector2) -> bool:
	# Godot emits the emulated mouse event before its original touch.
	if event is InputEventMouse and event.device == -1: return false
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		var active := _title_pressed
		cancel_native_drag()
		return active
	var touch := event is InputEventScreenTouch or event is InputEventScreenDrag
	if _title_pressed and event is InputEventScreenTouch and event.pressed and event.index != _title_touch:
		cancel_native_drag()
		return true
	if touch and _title_pressed and event.index != _title_touch: return false
	if not touch and _title_touch >= 0: return false
	var button: bool = event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT)
	var motion := event is InputEventScreenDrag or event is InputEventMouseMotion
	if not button and not motion: return false
	if button and event.canceled:
		var active := _title_pressed
		cancel_native_drag()
		return active
	# The OS owns Windows motion. On macOS only the frame callback places the
	# window, including its final move if release arrives between frames.
	if _mac_move or _windows_move:
		if _mac_move and button and not event.pressed and not _left_mouse_down():
			_release_pointer = _screen_pointer()
		return true
	if button and event.pressed:
		if _title_pressed or not visible or not _title_rect().has_point(point): return false
		if force_native and not folded and (point.y - position.y < 4 * content_scale_factor or point.x - position.x < 4 * content_scale_factor): return false
		if is_instance_valid(_desktop) and not _desktop.side.is_empty(): return false
		_title_pressed = true
		_title_touch = event.index if touch else -1
		_title_origin = point
		_title_moved = false
		_drag_origin = floating_rect()
		_drag_pointer_offset = (point - Vector2(position)) / content_scale_factor
		return true
	if not _title_pressed: return false
	_title_moved = _title_moved or point.distance_to(_title_origin) >= 8 * content_scale_factor
	if motion and _title_moved:
		if compositor_drag():
			# Wayland owns native placement; it never exposes desktop coordinates.
			# Start only after the threshold so a title click still folds.
			_title_pressed = false
			_title_touch = -1
			DisplayServer.window_start_drag(get_window_id())
		else:
			_native_drag = true
			if touch or not _start_desktop_mouse_move(): _move_drag(point)
	elif button and not event.pressed:
		var click := not _title_moved and _title_rect().has_point(point)
		_title_pressed = false
		_title_touch = -1
		if _native_drag:
			_move_drag(point)
			_finish_drag()
		elif click: toggle_fold()
	return true

func _screen_pointer() -> Vector2:
	return Vector2(DisplayServer.mouse_get_position())

func _left_mouse_down() -> bool:
	return bool(DisplayServer.mouse_get_button_state() & MOUSE_BUTTON_MASK_LEFT)

func _system_window_move() -> void:
	DisplayServer.window_start_drag(get_window_id())

func _start_desktop_mouse_move(driver := DisplayServer.get_name()) -> bool:
	if not force_native: return false
	match driver:
		"macOS":
			_start_mac_move()
		"Windows":
			_windows_move = true
			_system_window_move()
			# SC_MOVE returns when the modal move loop exits. Escape can
			# end it while the button is still down.
			if _windows_move:
				if _left_mouse_down(): cancel_native_drag()
				else:
					_update_drag_preview(_screen_pointer())
					_finish_drag()
		_: return false
	return true

func _start_mac_move() -> void:
	# AppKit throttles child-window moves. Keep the title's original grab
	# offset, detach for this gesture and sample in desktop coordinates.
	_mac_move = true
	_restore_transient = transient
	get_tree().process_frame.connect(_mac_drag_frame)
	transient = false

func _mac_drag_frame() -> void:
	var released := _release_pointer != Vector2.INF or not _left_mouse_down()
	var point := _screen_pointer() if _release_pointer == Vector2.INF else _release_pointer
	var target := Vector2i((point - _drag_pointer_offset * content_scale_factor).round())
	if position != target:
		position = target
		geometry_changed()
	_update_drag_preview(point)
	if released: _finish_drag()

func _stop_desktop_mouse_move() -> void:
	_windows_move = false
	if not _mac_move: return
	_mac_move = false
	get_tree().process_frame.disconnect(_mac_drag_frame)
	_release_pointer = Vector2.INF
	if _restore_transient: transient = true
	_restore_transient = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_POSITION_CHANGED and _windows_move:
		geometry_changed()
		_update_drag_preview(_screen_pointer())

func _move_drag(point: Vector2) -> void:
	position = Vector2i((point - _drag_pointer_offset * content_scale_factor).round())
	geometry_changed()
	_update_drag_preview(point)

func _update_drag_preview(point: Vector2) -> void:
	if not is_instance_valid(_desktop): return
	var local: Vector2 = _desktop.space.screen_to_local(point) if force_native else point
	var candidate: Dictionary = _desktop.space.plan(_desktop, local)
	if (_mac_move or _windows_move) and candidate == _native_candidate: return
	_native_candidate = candidate
	_desktop.space.show_preview(_native_candidate)

func _finish_drag() -> void:
	_title_pressed = false
	_native_drag = false
	_stop_desktop_mouse_move()
	if is_instance_valid(_desktop):
		if not _native_candidate.is_empty(): _desktop.space.commit(_desktop, _native_candidate)
		elif not force_native: _fit()
		_desktop.space.show_preview({})
		_desktop.space.save_layout()
	_native_candidate = {}
	_drag_from_workspace = false
	unfocusable = false
	if visible: grab_focus()

func dock_sides() -> Array[String]:
	return ["left", "right"]

## Bars share dock layout and content ownership, with no floating/folded form.
func dock_only() -> bool:
	return false

## Where a window with no saved placement docks on first open; empty floats it.
func default_dock_side() -> String:
	return ""

## For a top/bottom band: "inner" takes the terminal-facing row, "outer" the
## window edge beyond every existing row.
func default_dock_row() -> String:
	return "inner"

func set_compact(value: bool, row := false) -> void:
	if dock_only():
		value = true
		row = true
	row = row and value
	if compact == value and compact_row == row: return
	compact = value
	compact_row = row
	if is_instance_valid(_body):
		var chrome := _body.get_theme_stylebox("panel") as StyleBoxFlat
		chrome.content_margin_left = 0 if value else 4
		chrome.content_margin_right = 0 if value else 4
		chrome.content_margin_top = 2 if row else 4
		chrome.content_margin_bottom = 2 if row else 4
	_update_footer()
	_compact_changed()

func _update_footer() -> void:
	footer.visible = not compact or footer_actions_in_compact
	_footer_spacer.visible = not compact
	_resize_grip.visible = not compact and not force_native and not preload("res://scenes/input/InteractionProfile.gd").touch_controls()

func _compact_changed() -> void:
	pass

func _create_content() -> Control:
	return Control.new()

## How much larger than its natural size the content draws. Docking compares
## widths and heights in the content's own units, so thresholds follow it.
func layout_scale() -> float:
	return 1.0

func set_workspace_active(active: bool) -> void:
	active = active and not get_parent().get_window().get_meta(&"side_panels_hidden", false)
	if active == _workspace_active: return
	_workspace_active = active
	if not active:
		_stop_desktop_mouse_move()
		_resume_visible = visible or (is_instance_valid(_desktop) and (_desktop.visible or _desktop.space._preview_source == _desktop))
		_native_drag = false
		_title_pressed = false
		_title_touch = -1
		_drag_from_workspace = false
		unfocusable = false
		_native_candidate = {}
		if is_instance_valid(_desktop) and _desktop.space._preview_source == _desktop:
			_desktop.space.show_preview({})
		_resizing = false
		hide()
		if is_instance_valid(_desktop):
			_desktop.finish(true)
			_desktop.hide()
	elif _resume_visible:
		if is_instance_valid(_desktop) and not _desktop.side.is_empty(): _desktop.show()
		else: show()

func _follow_workspace() -> void:
	set_workspace_active(get_parent().get_window().get_meta(&"workspace_ui_active", true))

func _close_panel() -> void:
	if is_instance_valid(_desktop):
		if _desktop.space._preview_source == _desktop: _desktop.space.show_preview({})
		_desktop.space.remember_closed(_desktop)
	queue_free()

func _init() -> void:
	visible = false
	borderless = true
	exclusive = false
	transient = true
	unresizable = false
	wrap_controls = false
	min_size = Vector2i(240, 140)
	transparent_bg = true

func present() -> void:
	if dock_only() or not get_parent().get_viewport().gui_embed_subwindows or preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		if not is_instance_valid(_desktop):
			force_native = not dock_only() and not preload("res://scenes/input/InteractionProfile.gd").touch_controls()
			# The frame paints the surface. A transparent viewport preserves rounded
			# corners and lets native preview capture keep an empty window mapped.
			# Set `transparent` first because its setter changes `transparent_bg`.
			var owner_window := get_parent().get_window()
			transparent = force_native and WindowTransparency.available(owner_window.get_window_id())
			transparent_bg = not force_native or transparent
			apply_background()
			content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
			content_scale_factor = owner_window.content_scale_factor if force_native else 1.0
			var preferred: Vector2i = get_meta(&"preferred_size", Vector2i(420, 560))
			min_size = Vector2i(Vector2(40, mini(100, preferred.y)) * content_scale_factor)
			current_screen = owner_window.current_screen
			_desktop = load("res://scenes/DockableListPanel.gd").new()
			_desktop.dialog = self
			_desktop.space = preload("res://scenes/ListDockSpace.gd").for_window(get_parent().get_window())
			_desktop.build()
			_update_footer()
			if not force_native:
				# Mobile owns side/bottom resize gestures, leaving the title drag-only.
				unresizable = true
			var extent := Vector2i((Vector2(preferred) * content_scale_factor).round())
			if force_native:
				_native_rect = Rect2i(owner_window.position + (owner_window.size - extent) / 2, extent)
			else:
				var available := _available()
				extent = extent.min(available.size)
				_native_rect = Rect2i(available.position + (available.size - extent) / 2, extent)
		if not _desktop.space.restore_panel(_desktop) and not _desktop.space.dock_default(_desktop, default_dock_side()): float_native()
		_follow_workspace()
		return
	var bounds := _available()
	var preferred: Vector2i = get_meta(&"preferred_size", Vector2i(420, 560))
	min_size = Vector2i(240, mini(140, preferred.y)).min(bounds.size)
	size = preferred.min(bounds.size)
	position = bounds.position + (bounds.size - size) / 2
	show()
	grab_focus()
	_follow_workspace()

func raise_panel() -> void:
	_follow_workspace()
	if not _workspace_active: return
	if is_instance_valid(_desktop) and not _desktop.side.is_empty():
		_desktop.raise_panel()
	else:
		if folded: set_folded(false)
		show()
		grab_focus()

func set_dock_preview(active: bool) -> void:
	_dock_preview_active = active
	if active:
		_preview_was_floating = visible
		if visible:
			_native_rect = floating_rect()
			if force_native and _native_drag and (not _drag_from_workspace or _mac_move or _windows_move):
				# Keep the pressed native window mapped to retain its event stream.
				# Its live content is in the preview; only its empty canvas is hidden.
				_frame.hide()
			else: hide()
		_desktop.hide()
	elif _workspace_active:
		if _desktop.side.is_empty():
			if _preview_was_floating: show()
			set_compact(size.x / (content_scale_factor * layout_scale()) < COMPACT_WIDTH)
		else: _desktop.show()
	if not active:
		_preview_was_floating = false
		_frame.show()
	_layout_frame()
	_backdrop_changed()

func cancel_native_drag() -> void:
	_title_pressed = false
	_title_touch = -1
	unfocusable = false
	if not _native_drag: return
	_native_drag = false
	_stop_desktop_mouse_move()
	_drag_from_workspace = false
	_native_candidate = {}
	if is_instance_valid(_desktop): _desktop.space.show_preview({})
	if _drag_origin.has_area():
		_native_rect = _drag_origin
		position = _drag_origin.position
		size = _drag_origin.size
	float_native()

func attach_to_dock() -> void:
	_stop_desktop_mouse_move()
	if visible:
		_native_rect = floating_rect() if mode == MODE_WINDOWED else get_meta(&"normal_window_rect", _native_rect)
	_native_drag = false
	_title_pressed = false
	hide()
	_body.visible = not folded
	_body.reparent(_desktop.slot)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	apply_background()
	_desktop.show()

func float_native(screen_position := Vector2.INF) -> void:
	if dock_only(): return
	if not is_instance_valid(_desktop): return
	_stop_desktop_mouse_move()
	_desktop.side = ""
	_desktop.hide()
	if _body.get_parent() != self: _body.reparent(self)
	_layout_frame()
	apply_background()
	mode = MODE_WINDOWED
	if not _native_rect.has_area(): _native_rect = Rect2i(position, get_meta(&"preferred_size", Vector2i(420, 560)))
	if folded:
		if _expanded_minimum == Vector2i.ZERO: _expanded_minimum = min_size
		_expanded_size = _native_rect.size
	size = _native_rect.size
	position = _native_rect.position if screen_position == Vector2.INF else Vector2i(screen_position if force_native else _desktop.space.screen_to_local(screen_position))
	# Keep detached windows reachable on the current display, not inside the app.
	var usable := DisplayServer.screen_get_usable_rect(current_screen) if force_native else _available()
	if usable.has_area():
		size = size.min(usable.size)
		position = position.clamp(usable.position, usable.end - size) if force_native else _reachable(position, size, usable)
	_native_drag = false
	_drag_from_workspace = false
	set_compact(size.x / (content_scale_factor * layout_scale()) < COMPACT_WIDTH)
	_apply_floating_fold()
	show()
	if force_native:
		transparent = WindowTransparency.available(get_window_id())
		apply_background()
	_backdrop_changed()
	geometry_changed()
	if not unfocusable: grab_focus()
	_desktop.space.reflow()
	_desktop.space.save_layout()
	_follow_workspace()

func floating_title_height() -> float:
	return TITLE_HEIGHT * content_scale_factor

func float_from_drag(screen_pointer: Vector2, grab_ratio: float) -> void:
	float_native()
	var point: Vector2 = screen_pointer if force_native else _desktop.space.screen_to_local(screen_pointer)
	var offset := Vector2(clampf(size.x * grab_ratio, 12, maxf(12, size.x - TITLE_HEIGHT * content_scale_factor)), floating_title_height() / 2.0)
	# The title is inside the window; keep the grab in that row on detachment.
	position = Vector2i((point - offset).round())
	geometry_changed()
	_drag_pointer_offset = offset / content_scale_factor

func continue_pointer_drag(finger := -1) -> void:
	_drag_origin = _native_rect
	_native_drag = true
	_title_pressed = true
	_title_moved = true
	_title_touch = finger
	_drag_from_workspace = true
	if finger < 0: _start_desktop_mouse_move()

func toggle_fit() -> void:
	preload("res://scenes/WindowGeometry.gd").toggle_fit(self)

func geometry_changed() -> void:
	if is_instance_valid(_desktop) and not _dock_preview_active and _desktop.side.is_empty():
		set_compact(size.x / (content_scale_factor * layout_scale()) < COMPACT_WIDTH)
	_update_geometry()

## Subclasses update geometry-dependent presentation on move/resize.
func _update_geometry() -> void:
	pass

func _exit_tree() -> void:
	_stop_desktop_mouse_move()
	if is_instance_valid(_desktop):
		_workspace_active = false
		if _desktop.space._preview_source == _desktop: _desktop.space.show_preview({})
		_desktop.queue_free()

func set_bottom_inset(value: float) -> void:
	if not is_embedded() or is_equal_approx(value, _bottom_inset): return
	if _bottom_inset == 0: _unobstructed = Rect2i(position, size)
	_bottom_inset = value
	if value == 0 and _unobstructed.has_area():
		size = _unobstructed.size
		position = _unobstructed.position
	_fit()

func _available() -> Rect2i:
	var extent := Vector2i(get_parent().get_viewport().get_visible_rect().size)
	extent.y -= int(_bottom_inset)
	var origin := Vector2i(12, 40)
	if not is_embedded(): origin += get_parent().get_window().position
	return Rect2i(origin, (extent - Vector2i(24, 52)).max(Vector2i.ONE))

func _fit() -> void:
	if is_instance_valid(_desktop):
		_desktop.space.reflow()
		if force_native or not _desktop.side.is_empty(): return
	var bounds := _available()
	var floor_height := mini(100 if is_instance_valid(_desktop) else 140, get_meta(&"preferred_size", Vector2i(420, 560)).y)
	min_size = Vector2i(40 if is_instance_valid(_desktop) else 240, int(floating_title_height()) if folded else floor_height).min(bounds.size)
	size = size.min(bounds.size)
	position = _reachable(position, size, bounds)
	geometry_changed()

## Let an embedded window extend offscreen while keeping its title reachable.
##
## Keep the title row within `bounds` vertically. Keep at least `GRAB` logical
## pixels of it visible horizontally. The title sits inside the window.
const GRAB := 44.0
func _reachable(origin: Vector2i, extent: Vector2i, bounds: Rect2i) -> Vector2i:
	# Embedded positions are in the parent's pixels; its scale sets the finger size.
	var grab := int(minf(GRAB * get_parent().get_window().content_scale_factor, extent.x))
	var title := int(floating_title_height())
	return Vector2i(
		clampi(origin.x, bounds.position.x - extent.x + grab, bounds.end.x - grab),
		clampi(origin.y, bounds.position.y, bounds.end.y - title),
	)

## Whether a floating embedded window can still be grabbed by its title.
func title_reachable() -> bool:
	return _reachable(position, size, _available()) == position

func _ready() -> void:
	add_to_group(&"keyboard_safe_windows")
	add_to_group(&"workspace_tool_windows")
	close_requested.connect(_close_panel)
	focus_exited.connect(func():
		if not _dock_preview_active and not _drag_from_workspace: cancel_native_drag()
		_resizing = false
		_resize_finger = -1)
	get_parent().get_viewport().size_changed.connect(_fit)
	_build_frame()
	var panel := PanelContainer.new()
	_body = panel
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_force_pass_scroll_events = false
	panel.gui_input.connect(func(event):
		if compact_row and is_instance_valid(_desktop) and not _desktop.side.is_empty(): _desktop.body_input(event, panel))
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := surface(surface_color())
	background.content_margin_top = 4
	background.content_margin_bottom = 4
	panel.add_theme_stylebox_override("panel", background)
	add_child(panel)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 2)
	panel.add_child(layout)
	var content := _create_content()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(content)
	layout.add_child(footer)
	_footer_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_footer_spacer)
	_resize_grip.text = ""
	_resize_grip.accessibility_name = tr("Drag to resize width and height")
	_resize_grip.flat = true
	_resize_grip.focus_mode = Control.FOCUS_NONE
	_resize_grip.custom_minimum_size = Vector2(36, 32)
	_resize_grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	_resize_grip.add_theme_color_override("font_color", Color("838691"))
	_resize_grip.gui_input.connect(_resize_input)
	footer.add_child(_resize_grip)
	_update_footer()
	_build_resize_edges()
	size_changed.connect(_layout_frame)
	size_changed.connect(geometry_changed)
	visibility_changed.connect(geometry_changed)
	_layout_frame()

func _build_frame() -> void:
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.add_theme_stylebox_override("panel", surface(surface_color()))
	add_child(_frame)
	_floating_title.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_floating_title.accessibility_name = tr("Click to fold or unfold; drag to move or undock")
	_floating_title.add_to_group(&"touch_chrome")
	_frame.add_child(_floating_title)
	_floating_title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_floating_title.offset_right = -TITLE_HEIGHT
	_floating_title.offset_bottom = TITLE_HEIGHT
	var label := Label.new()
	label.text = tr(title)
	label.add_theme_font_size_override("font_size", DesktopText.size(11))
	label.add_theme_color_override("font_color", Color("a2a4ae"))
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_floating_title.add_child(label)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.offset_left = 6
	_floating_close.text = "×"
	_floating_close.accessibility_name = tr("Close")
	_floating_close.focus_mode = Control.FOCUS_NONE
	_floating_close.add_theme_font_size_override("font_size", DesktopText.size(11))
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color("c42b1c") if state in ["hover", "pressed"] else Color.TRANSPARENT
		style.set_content_margin_all(0)
		_floating_close.add_theme_stylebox_override(state, style)
	_floating_close.add_theme_color_override("font_hover_color", Color.WHITE)
	_floating_close.add_theme_color_override("font_pressed_color", Color.WHITE)
	_frame.add_child(_floating_close)
	_floating_close.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_floating_close.offset_left = -TITLE_HEIGHT
	_floating_close.offset_bottom = TITLE_HEIGHT
	_floating_close.pressed.connect(_close_panel)

func _build_resize_edges() -> void:
	var cursors := [Control.CURSOR_FDIAGSIZE, Control.CURSOR_VSIZE, Control.CURSOR_BDIAGSIZE, Control.CURSOR_HSIZE, Control.CURSOR_HSIZE, Control.CURSOR_BDIAGSIZE, Control.CURSOR_VSIZE, Control.CURSOR_FDIAGSIZE]
	for edge in 8:
		var control := Control.new()
		control.mouse_default_cursor_shape = cursors[edge]
		control.gui_input.connect(func(event):
			if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
				DisplayServer.window_start_resize(edge, get_window_id())
				control.accept_event())
		add_child(control)
		_resize_edges.append(control)

func _layout_frame() -> void:
	if is_instance_valid(_body) and _body.get_parent() == self:
		_body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_body.offset_top = TITLE_HEIGHT
	var extent := get_visible_rect().size
	var e := 4.0
	var rects := [Rect2(0, 0, e, e), Rect2(e, 0, extent.x - e * 2, e), Rect2(extent.x - e, 0, e, e), Rect2(0, e, e, extent.y - e * 2), Rect2(extent.x - e, e, e, extent.y - e * 2), Rect2(0, extent.y - e, e, e), Rect2(e, extent.y - e, extent.x - e * 2, e), Rect2(extent.x - e, extent.y - e, e, e)]
	for i in _resize_edges.size():
		_resize_edges[i].position = rects[i].position
		_resize_edges[i].size = rects[i].size
		_resize_edges[i].visible = force_native and not folded and not _dock_preview_active and mode == MODE_WINDOWED

func _resize_input(event: InputEvent) -> void:
	if is_instance_valid(_desktop) and force_native: return
	var touch := event is InputEventScreenTouch or event is InputEventScreenDrag
	if not touch and _resize_finger >= 0: return
	if event is InputEventScreenTouch:
		if _resize_finger >= 0 and event.index != _resize_finger: return
		_resize_finger = event.index if event.pressed and not event.canceled else -1
	var press: bool = event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT)
	var motion := event is InputEventScreenDrag or event is InputEventMouseMotion
	if not press and not motion: return
	if event is InputEventScreenDrag and event.index != _resize_finger: return
	var pointer: Vector2 = Vector2(position) + _resize_grip.get_global_transform() * event.position
	if press:
		_resizing = event.pressed and (not event.canceled if touch else true)
		_resize_origin = pointer
		_resize_size = size
	elif _resizing:
		var limit := (_available().end - position).max(min_size)
		size = (_resize_size + Vector2i(pointer - _resize_origin)).clamp(min_size, limit)
	_resize_grip.accept_event()

## Whether the surface can be translucent where this window draws: a native
## window needs per-pixel transparency (desktop only).
func translucent() -> bool:
	if background_opacity >= 1.0: return false
	# Docked surfaces are ordinary canvas controls, even when their floating
	# Window is native. They do not need OS per-pixel window transparency.
	if is_instance_valid(_desktop) and is_instance_valid(_body) and _body.get_parent() != self: return true
	return not force_native or transparent


## The panel background: the chrome colour at `background_opacity` when it can show through.
func surface_color() -> Color:
	return Color(SURFACE, background_opacity) if translucent() else SURFACE


## Repaints the window chrome, body and dock surfaces with `surface_color()`.
## Docked, the body sits on the dock's surface; floating, our frame paints
## both the title and body background once, without stacking translucent layers.
func apply_background() -> void:
	var color := surface_color()
	if _frame.has_theme_stylebox_override("panel"): (_frame.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = color
	if is_instance_valid(_body):
		var docked := is_instance_valid(_desktop) and _body.get_parent() != self
		var on_surface := docked or _body.get_parent() == self
		(_body.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = Color.TRANSPARENT if on_surface else color
	if is_instance_valid(_desktop) and _desktop.has_theme_stylebox_override("panel"):
		(_desktop.get_theme_stylebox("panel") as StyleBoxFlat).bg_color = color


## A native window was shown floating: subclasses may set a desktop backdrop.
func _backdrop_changed() -> void:
	pass


static func surface(color: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(8)
	box.content_margin_left = 4
	box.content_margin_right = 4
	return box
