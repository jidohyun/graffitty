extends PanelContainer
## Keep tab selection inside the owning window so its native caption stays active.

signal tab_selected(id: int)
signal pane_selected(key: String)
signal popup_hide
var list := preload("res://scenes/mods/ModTabRows.gd").new()
var search := LineEdit.new()
var empty := Label.new()
var model := preload("res://scenes/TabListSearch.gd").new()
var _items: Array = []
var _active_id := -1
var _font: Font
var _font_size := 16
var _foreground := Color.WHITE
var _background := Color.BLACK
var _previous_focus: WeakRef
var _opener: WeakRef


func _init() -> void:
	hide()


func _ready() -> void:
	add_to_group(&"touch_chrome")
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	add_child(column)
	search.placeholder_text = "Search tabs and panes…"
	search.clear_button_enabled = true
	search.custom_minimum_size.y = 36
	search.text_changed.connect(func(_value): _refresh_results(true))
	search.gui_input.connect(func(event):
		if list.navigate(event): search.accept_event())
	column.add_child(search)
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(list)
	empty.text = "No matching tabs or panes"
	empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	empty.custom_minimum_size.y = 40
	column.add_child(empty)
	empty.hide()
	list.item_clicked.connect(func(index: int, _at: Vector2, button: int):
		if button == MOUSE_BUTTON_LEFT:
			_choose(index))
	list.item_activated.connect(_choose)
	visibility_changed.connect(_visibility_changed)
	get_window().focus_exited.connect(hide)
	get_viewport().size_changed.connect(hide)
	_visibility_changed()


func populate(items: Array, active_id: int, source: Control, background: Color) -> void:
	_items = items
	_active_id = active_id
	_foreground = source.get_theme_color("font_color", "Button")
	_font = source.get_theme_font("font", "Button")
	_font_size = source.get_theme_font_size("font_size", "Button")
	_background = background
	var panel := _surface(background, 8)
	panel.set_content_margin_all(6)
	add_theme_stylebox_override("panel", panel)
	search.add_theme_font_override("font", _font)
	search.add_theme_font_size_override("font_size", _font_size)
	_refresh_results(false)


func _refresh_results(reset_selection: bool) -> void:
	var previous := list.get_item_identity(list.selected)
	var rows := model.filter(_items, search.text)
	list.populate(rows, _active_id, _font, _font_size, _foreground, _background)
	if reset_selection:
		previous = "tab:%d" % _active_id if search.text.strip_edges().is_empty() else model.preferred
		list.reset_scroll_navigation()
	list.select_identity(previous)
	list.visible = not rows.is_empty()
	empty.visible = rows.is_empty()
	if visible:
		_place.call_deferred()
		if reset_selection:
			list.ensure_current_is_visible.call_deferred()


func show_below(button: Control) -> void:
	_opener = weakref(button)
	var viewport := button.get_viewport()
	var focus := viewport.gui_get_focus_owner()
	_previous_focus = weakref(focus) if focus != null else null
	search.set_text("")
	_refresh_results(true)
	_place()
	show()
	search.grab_focus.call_deferred()
	list.ensure_current_is_visible.call_deferred()


func _place() -> void:
	var button: Control = _opener.get_ref() if _opener != null else null
	if not is_instance_valid(button): return
	var available := button.get_viewport().get_visible_rect().size
	var content := list.content_height() if list.visible else 40.0
	var extent := Vector2(minf(600, available.x - 16), minf(content + 54, available.y * .8))
	# The overlay and button use the same logical coordinates, including HiDPI.
	var at := button.get_global_transform_with_canvas() * Vector2(0, button.size.y + 4)
	size = extent.ceil()
	position = at.clamp(Vector2(8, 8), (available - size - Vector2(8, 8)).max(Vector2(8, 8)))


func _choose(index: int) -> void:
	if not visible or index < 0 or index >= list.item_count:
		return
	var id := int(list.get_item_metadata(index))
	var pane: String = list.rows[index].get_meta("pane_key", "")
	hide()
	if pane.is_empty(): tab_selected.emit(id)
	else: pane_selected.emit(pane)


func _visibility_changed() -> void:
	set_process_input(visible)
	set_process_unhandled_key_input(visible)
	if visible:
		return
	list.reset_touch_navigation()
	list.release_focus()
	search.release_focus()
	var focus: Control = _previous_focus.get_ref() if _previous_focus != null else null
	_previous_focus = null
	_opener = null
	if is_instance_valid(focus) and focus.is_visible_in_tree():
		focus.grab_focus()
	popup_hide.emit()


func _input(event: InputEvent) -> void:
	if list.touch_navigation(event):
		get_viewport().set_input_as_handled()
		return
	# Handle scrolling before the row buttons or search field consume it.
	# Periodic resource/title refreshes preserve this highlight and scroll offset.
	if (event is InputEventMouseButton or event is InputEventPanGesture) and get_global_rect().has_point(event.position):
		if list.scroll_selection(event):
			get_viewport().set_input_as_handled()
			return
	if (event is InputEventMouseButton or event is InputEventScreenTouch) and event.pressed:
		if get_global_rect().has_point(event.position):
			return
		var opener: Control = _opener.get_ref() if _opener != null else null
		if is_instance_valid(opener):
			var at: Vector2 = opener.get_global_transform_with_canvas().affine_inverse() * event.position
			if Rect2(Vector2.ZERO, opener.size).has_point(at):
				# Let the button toggle on release. Hiding on press can reopen
				# the menu when that same mouse click or touch reaches the button.
				return
		hide()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if event.is_action_pressed("ui_cancel"):
			hide()
			get_viewport().set_input_as_handled()
		elif (event.meta_pressed or event.ctrl_pressed or event.alt_pressed) and event.keycode not in [
			KEY_A, KEY_C, KEY_V, KEY_X, KEY_Z, KEY_Y, KEY_LEFT, KEY_RIGHT, KEY_HOME, KEY_END, KEY_BACKSPACE, KEY_DELETE,
		]:
			# Keep text editing available without forwarding workspace shortcuts.
			get_viewport().set_input_as_handled()


func _unhandled_key_input(_event: InputEvent) -> void:
	# The row list handles navigation and activation; unused keys must not type into a pane.
	get_viewport().set_input_as_handled()


func _surface(color: Color, radius := 4) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(6)
	return style
