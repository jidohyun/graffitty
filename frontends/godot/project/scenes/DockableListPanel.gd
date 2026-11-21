extends PanelContainer
## Dock-only presentation; floating content belongs to the real Window.
const DesktopText := preload("res://scenes/DesktopText.gd")
var dialog: Window
var space: Control
var side := ""
## Row inside a top/bottom band, outermost first.
var row := 0
var weight := 1.0
var dragging := false
var slot := VBoxContainer.new()
var _sizing := ""
var _origin := Vector2.ZERO
var _old_width := 300.0
var _old_requested_width := 300.0
var _old_weights := Vector2.ONE
var _neighbor: Control
var _candidate := {}
var _last_pointer := Vector2.ZERO
var _edge := ColorRect.new()
var _divider := ColorRect.new()
var _drag_grab_ratio := 0.5
var _header := HBoxContainer.new()
var _title := Label.new()
var _close := Button.new()
var _touch := -1
var _fold_on_click := false
var _drag_moved := false

func build() -> void:
	add_theme_stylebox_override("panel", load("res://scenes/DockableWindow.gd").surface(dialog.surface_color()))
	custom_minimum_size = Vector2(40, space.MIN_BAND_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_force_pass_scroll_events = false
	add_to_group(&"touch_chrome")
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 0)
	add_child(layout)
	var header := _header
	header.custom_minimum_size.y = 20
	layout.add_child(header)
	var titlebar := Control.new()
	titlebar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titlebar.mouse_default_cursor_shape = Control.CURSOR_MOVE
	titlebar.accessibility_name = tr("Click to fold or unfold; drag to move or undock")
	header.add_child(titlebar)
	var label := _title
	label.text = tr(dialog.title)
	label.add_theme_font_size_override("font_size", DesktopText.size(11))
	label.add_theme_color_override("font_color", Color("a2a4ae"))
	label.clip_text = true
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	titlebar.add_child(label)
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	titlebar.gui_input.connect(func(event):
		if event is InputEventScreenTouch and event.pressed and not event.canceled:
			_touch = event.index
			begin_drag(_point(titlebar, event.position))
			_fold_on_click = true
			titlebar.accept_event()
		elif _touch < 0 and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			begin_drag(_point(titlebar, event.position))
			_fold_on_click = true
			titlebar.accept_event())
	var close := _close
	close.text = "×"
	close.flat = true
	close.custom_minimum_size = Vector2(20, 20)
	close.add_theme_font_size_override("font_size", DesktopText.size(11))
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color("c42b1c") if state in ["hover", "pressed"] else Color.TRANSPARENT
		style.set_content_margin_all(0)
		close.add_theme_stylebox_override(state, style)
	close.add_theme_color_override("font_hover_color", Color.WHITE)
	close.add_theme_color_override("font_pressed_color", Color.WHITE)
	close.accessibility_name = tr("Close")
	close.pressed.connect(dialog._close_panel)
	apply_scale()
	header.add_child(close)
	slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(slot)
	for handle in [_edge, _divider]:
		handle.set_as_top_level(true)
		handle.z_index = 20
		handle.mouse_filter = Control.MOUSE_FILTER_STOP
		handle.mouse_force_pass_scroll_events = false
		handle.add_to_group(&"touch_chrome")
		handle.color = Color.TRANSPARENT
		add_child(handle)
	_edge.mouse_default_cursor_shape = Control.CURSOR_HSIZE
	_edge.accessibility_name = tr("Resize sidebar")
	_divider.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	_divider.accessibility_name = tr("Resize stacked panels")
	_edge.gui_input.connect(func(event): _handle_press(event, _edge, "band_height" if side in ["top", "bottom"] else "width"))
	_divider.gui_input.connect(func(event): _handle_press(event, _divider, "band_weight" if side in ["top", "bottom"] else "height"))
	space.add_panel(self)
	get_window().focus_exited.connect(func(): finish(true))
	hide()

## The title row draws at the panel's magnification, like its content.
func apply_scale() -> void:
	var scale: float = dialog.layout_scale()
	_header.custom_minimum_size.y = roundf(20 * scale)
	_title.add_theme_font_size_override("font_size", DesktopText.size(11 * scale))
	_close.custom_minimum_size = Vector2(20, 20) * scale
	_close.add_theme_font_size_override("font_size", DesktopText.size(11 * scale))
	# A bar smaller than one status row may shrink to its own height.
	custom_minimum_size.y = minf(space.MIN_BAND_HEIGHT, space.bar_height([self])) if dialog.dock_only() else space.MIN_BAND_HEIGHT

func _point(control: Control, point: Vector2) -> Vector2:
	return space.get_global_transform_with_canvas().affine_inverse() * (control.get_global_transform_with_canvas() * point)

func raise_panel() -> void:
	show()
	if dialog.folded: dialog.set_folded(false)
	if side in ["left", "right"] and space.widths[side] < space.COMPACT_WIDTH * space.side_scale(side): space.toggle_fold(side)
	space.move_child(self, space.get_child_count() - 1)

func prepare(extent: Vector2, destination_side := "") -> void:
	if not is_instance_valid(dialog): return
	# Preview layout uses its destination without changing committed dock ownership.
	var layout_side: String = side if destination_side.is_empty() else destination_side
	# Apply compact content before Control clamps the requested size to its minimum.
	var compact: bool = dialog.dock_only() or space.compact_for(layout_side, extent / dialog.layout_scale())
	_header.visible = not dialog.dock_only() and (dialog.folded or not compact)
	slot.visible = not dialog.folded
	dialog._body.visible = not dialog.folded
	var narrow: bool = extent.x < space.COMPACT_WIDTH * dialog.layout_scale()
	var chrome := get_theme_stylebox("panel") as StyleBoxFlat
	chrome.content_margin_left = 0 if narrow else 4
	chrome.content_margin_right = 0 if narrow else 4
	var body_drags: bool = compact and layout_side in ["top", "bottom"]
	dialog.set_compact(compact, body_drags)
	# Keep touches on a compact band's body for dragging the band.
	# On regular content, a resting finger can join a workspace pinch.
	if body_drags: slot.remove_from_group(&"touch_yield")
	else: slot.add_to_group(&"touch_yield")

## A compact band has no title row; its body is the drag target instead.
func body_input(event: InputEvent, body: Control) -> void:
	if event is InputEventScreenTouch and event.pressed and not event.canceled:
		_touch = event.index
		begin_drag(_point(body, event.position))
		body.accept_event()
	elif _touch < 0 and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if event.double_click and not dialog.dock_only(): dialog.float_native()
		else: begin_drag(_point(body, event.position))
		body.accept_event()

func place_handles(has_next: bool) -> void:
	if side.is_empty() or not is_instance_valid(dialog): return
	_edge.visible = not side.is_empty()
	var hit := 16.0 if preload("res://scenes/input/InteractionProfile.gd").touch_controls() else 5.0
	# Own the shared boundary, not just a sliver inside the sidebar: span
	# the tiling gap and reach into both adjacent surfaces. The dock layer
	# and touch_chrome barrier give this target priority over pane resizing.
	var gap: float = space.gap()
	_edge.global_position = global_position + Vector2(size.x - hit if side == "left" else -gap - hit, 0)
	_edge.size = Vector2(gap + 2 * hit, size.y)
	_edge.mouse_default_cursor_shape = Control.CURSOR_VSIZE if side in ["top", "bottom"] else Control.CURSOR_HSIZE
	_edge.accessibility_name = tr("Resize panel height") if side in ["top", "bottom"] else tr("Resize sidebar")
	if side in ["top", "bottom"]:
		# Each row's terminal-facing edge resizes that row's height.
		# A thin band (a status line) keeps its own controls tappable: the
		# finger target reaches only a little into it, fully into the terminal.
		var inner := minf(hit, size.y / 4.0)
		_edge.global_position = global_position + Vector2(0, size.y - inner if side == "top" else -gap - hit)
		_edge.size = Vector2(size.x, gap + hit + inner)
		_edge.accessibility_name = tr("Resize panel height")
		# A row of bars is as tall as its bars: there is no height to drag.
		_edge.visible = space.bar_height(space.column(side).filter(func(panel): return panel.row == row)) <= 0.0
		# Side-by-side panels in a row share a vertical divider that changes their proportions.
		_divider.visible = has_next
		_divider.mouse_default_cursor_shape = Control.CURSOR_HSIZE
		_divider.global_position = global_position + Vector2(size.x - hit, 0)
		_divider.size = Vector2(gap + hit, size.y)
		return
	_divider.visible = has_next
	_divider.mouse_default_cursor_shape = Control.CURSOR_VSIZE
	_divider.global_position = global_position + Vector2(0, size.y - hit)
	# Cover the whole gap without stealing the next panel's title/close row.
	_divider.size = Vector2(size.x, gap + hit)

func _handle_press(event: InputEvent, handle: Control, kind: String) -> void:
	if event is InputEventScreenTouch and event.pressed and not event.canceled:
		_touch = event.index
		begin_resize(_point(handle, event.position), kind)
		handle.accept_event()
	elif _touch < 0 and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		begin_resize(_point(handle, event.position), kind)
		handle.accept_event()

func begin_drag(point: Vector2) -> void:
	dragging = true
	_fold_on_click = false
	_drag_moved = false
	_drag_grab_ratio = clampf((point.x - global_position.x) / maxf(1, size.x), 0, 1)
	_origin = point
	_last_pointer = point
	_candidate = {}

func drag_to(point: Vector2) -> void:
	_last_pointer = point
	if point.distance_to(_origin) < 8 and not _drag_moved: return
	_drag_moved = true
	_candidate = space.plan(self, point)
	space.show_preview(_candidate)
	if _candidate.is_empty() and not dialog.dock_only() and not dialog.compositor_drag():
		dragging = false
		# Keep the main window's original press/release stream during detachment.
		dialog.unfocusable = true
		dialog.float_from_drag(space.local_to_screen(point), _drag_grab_ratio)
		dialog.continue_pointer_drag(_touch)
		_touch = -1
		space.reflow()

func begin_resize(point: Vector2, kind: String) -> void:
	_sizing = kind
	Input.set_default_cursor_shape(Input.CURSOR_HSIZE if kind in ["width", "band_weight"] else Input.CURSOR_VSIZE)
	_origin = point
	if side in ["top", "bottom"]:
		var heights: Array = space.heights_of(side)
		_old_requested_width = float(heights[row]) if row < heights.size() else space.DEFAULT_ROW_HEIGHT
		_old_width = size.y
	else:
		_old_requested_width = space.widths[side]
		_old_width = size.x
	if kind in ["height", "band_weight"]:
		var items: Array = space.rows_of(side)[row] if kind == "band_weight" else space.column(side)
		var index := items.find(self)
		if index + 1 >= items.size(): _sizing = ""; return
		_neighbor = items[index + 1]
		_old_weights = Vector2(weight, _neighbor.weight)

func resize_to(point: Vector2) -> void:
	if _sizing == "band_height":
		var heights: Array = space.heights_of(side)
		var others := 0.0
		for index in heights.size():
			if index != row: others += float(heights[index]) + space.gap()
		var limit: float = maxf(space.MIN_BAND_HEIGHT, space.band_height_limit(side) - others)
		heights[row] = clampf(_old_width + (point.y - _origin.y) * (-1 if side == "bottom" else 1), space.MIN_BAND_HEIGHT, limit)
		space.band_rows[side] = heights
	elif _sizing == "band_weight" and is_instance_valid(_neighbor):
		var items: Array = space.rows_of(side)[row]
		var total := 0.0
		for item in items: total += item.weight
		var flexible: float = maxf(1, space._band_span(space.column("left"), space.column("right")).y - items.size() * space.MIN_PANEL - (items.size() - 1) * space.gap())
		var delta := (point.x - _origin.x) / flexible * total
		weight = clampf(_old_weights.x + delta, .001, _old_weights.x + _old_weights.y - .001)
		_neighbor.weight = _old_weights.x + _old_weights.y - weight
	elif _sizing == "width":
		var limit: float = space.width_limit(side)
		space.widths[side] = clampf(_old_width + (point.x - _origin.x) * (-1 if side == "right" else 1), space.MIN_PANEL, limit)
	elif _sizing == "height" and is_instance_valid(_neighbor):
		var items: Array = space.column(side)
		var total := 0.0
		for item in items: total += item.weight
		var flexible: float = maxf(1, space.stack_flexible(items.size()))
		var delta := (point.y - _origin.y) / flexible * total
		weight = clampf(_old_weights.x + delta, .001, _old_weights.x + _old_weights.y - .001)
		_neighbor.weight = _old_weights.x + _old_weights.y - weight
	space.reflow()

func finish(cancel := false) -> void:
	if not dragging and _sizing.is_empty(): return
	if cancel:
		if _sizing == "band_height":
			var heights: Array = space.heights_of(side)
			heights[row] = _old_requested_width
			space.band_rows[side] = heights
		if _sizing == "width": space.widths[side] = _old_requested_width
		if _sizing in ["height", "band_weight"] and is_instance_valid(_neighbor):
			weight = _old_weights.x; _neighbor.weight = _old_weights.y
	elif dragging and _drag_moved:
		if not _candidate.is_empty(): space.commit(self, _candidate)
		elif not dialog.dock_only():
			dialog.float_from_drag(space.local_to_screen(_last_pointer), _drag_grab_ratio)
			if not dialog.force_native: dialog._fit()
	elif dragging and _fold_on_click:
		dialog.toggle_fold()
	if not cancel and _sizing == "width":
		if space.widths[side] >= space.COMPACT_WIDTH * space.side_scale(side): space.expanded_widths[side] = space.widths[side]
		elif _old_width >= space.COMPACT_WIDTH * space.side_scale(side): space.expanded_widths[side] = _old_width
	dragging = false
	space._touches.erase(_touch)
	_touch = -1
	_sizing = ""
	_candidate = {}
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	space.show_preview({})
	space.reflow()
	if not cancel: space.save_layout()

func _input(event: InputEvent) -> void:
	if not dragging and _sizing.is_empty(): return
	if event is InputEventScreenTouch and event.pressed and _touch >= 0 and event.index != _touch:
		finish(true)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventScreenDrag and event.index == _touch:
		var point: Vector2 = space.get_global_transform_with_canvas().affine_inverse() * event.position
		if dragging: drag_to(point)
		else: resize_to(point)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenTouch and event.index == _touch and (not event.pressed or event.canceled):
		finish(event.canceled)
		get_viewport().set_input_as_handled()
	elif _touch >= 0:
		return
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		finish(true)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		finish()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var point: Vector2 = space.get_global_transform_with_canvas().affine_inverse() * event.position
		if dragging: drag_to(point)
		else: resize_to(point)
		get_viewport().set_input_as_handled()

func _exit_tree() -> void:
	if is_instance_valid(space) and not space.is_queued_for_deletion(): space.remove_panel(self)
