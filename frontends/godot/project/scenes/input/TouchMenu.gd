extends PopupPanel
## App-drawn presentation of a PopupMenu command model: every menu on touch,
## and on desktop menus with a destructive (red) item, which OS menus cannot
## color.
##
## The list owns the entire pointer sequence; rows are passive, so scrolling
## can never press commands.
const DesktopText := preload("res://scenes/DesktopText.gd")
const ROW_HEIGHT := 40.0
## Desktop shows this menu only for destructive commands (red text): rows match
## a mouse-sized menu instead of finger targets.
const DESKTOP_ROW_HEIGHT := 28.0
const MAX_HEIGHT := 360.0
const MAX_WIDTH := 320.0
## A touch menu is as wide as its widest row, never narrower than a
## comfortable finger target.
const MIN_TOUCH_WIDTH := 160.0
const MARGIN := 8.0
const DRAG_THRESHOLD := 8.0

var model: PopupMenu
var stack: Array[PopupMenu] = []
var scroll := preload("res://scenes/ElasticScrollContainer.gd").new()
var rows := VBoxContainer.new()
var surface := Control.new()
var anchor := Vector2.ZERO
var bottom_inset := 0.0
var fingers: Dictionary = {}
var contact := -2
var origin := Vector2.ZERO
var dragging := false
var last := Vector2.ZERO
var pressed_row := -1
var selected := -1
var indices: Array[int] = []
var buttons: Array[Button] = []
var background: StyleBoxFlat
var opening: Tween
var pending := false
var generation := 0
var touch := preload("res://scenes/input/InteractionProfile.gd").touch_controls()

func _init() -> void:
	name = "TouchMenu"
	transparent_bg = true
	transparent = true
	borderless = true
	unresizable = true
	wrap_controls = false
	surface.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(surface)
	scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The menu owns the pointer sequence and drives the scroll itself.
	scroll.handles_touch = false
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.get_v_scroll_bar().mouse_filter = Control.MOUSE_FILTER_IGNORE
	surface.add_child(scroll)
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_theme_constant_override("separation", 0)
	scroll.add_child(rows)
	surface.gui_input.connect(_pointer)
	window_input.connect(_key)
	popup_hide.connect(_closed)
	focus_exited.connect(_cancel)

func _ready() -> void:
	set_process(false)
	add_to_group(&"touch_menus")
	add_to_group(&"floating_controls")
	get_parent().get_viewport().size_changed.connect(_fit)

func request_present(source: PopupMenu, at: Vector2) -> void:
	generation += 1
	var requested := generation
	pending = true
	# Let the previously dismissed native window finish returning focus first.
	await get_tree().process_frame
	if not pending or requested != generation or not is_instance_valid(source): return
	pending = false
	present(source, at)

func dismiss() -> void:
	pending = false
	hide()

func present(source: PopupMenu, at: Vector2) -> void:
	model = source
	stack.clear()
	anchor = at
	# Reuse command updates/localization, not PopupMenu's mouse-driven window.
	model.about_to_popup.emit()
	_build()
	_fit()
	popup()
	_set_opacity(0)
	if opening != null: opening.kill()
	opening = create_tween()
	opening.tween_method(_set_opacity, 0.0, 1.0, .12)

func _set_opacity(value: float) -> void:
	surface.modulate.a = value
	background.bg_color = Color(.055, .055, .065, .96 * value)
	background.border_color = Color(1, 1, 1, .14 * value)

func set_bottom_inset(value: float) -> void:
	if is_equal_approx(value, bottom_inset): return
	bottom_inset = value
	if visible: _fit()

func _fit() -> void:
	if not is_inside_tree(): return
	# A desktop (non-embedded) menu is its own OS window: its anchor and position
	# are screen pixels, and it must share the host window's HiDPI scale.
	var host: Window = get_parent().get_window()
	var embedder := preload("res://scenes/input/PointerPopup.gd").embedder_of(self)
	var native := embedder == null
	var scale := host.content_scale_factor if native else 1.0
	# Native menus may extend beyond a narrow floating panel, like OS menus.
	var bounds := DisplayServer.screen_get_usable_rect(host.current_screen) if native else Rect2i()
	var origin_px := Vector2(bounds.position) if native else Vector2.ZERO
	content_scale_factor = scale
	var available := Vector2(bounds.size) / scale if native else embedder.get_visible_rect().size
	available.y = maxf(1, available.y - bottom_inset)
	var fitted := _content_width() + 16
	var width := minf(clampf(fitted, MIN_TOUCH_WIDTH, MAX_WIDTH) if touch else fitted, maxf(1, available.x - MARGIN * 2))
	var height := minf(MAX_HEIGHT, minf(rows.get_combined_minimum_size().y + 16, maxf(1, available.y - MARGIN * 2)))
	var local := ((anchor - origin_px) / scale).clamp(Vector2.ONE * MARGIN, (available - Vector2(width, height) - Vector2.ONE * MARGIN).max(Vector2.ONE * MARGIN))
	var next_size := Vector2i(Vector2(width, height) * scale)
	var next_position := Vector2i(origin_px + local * scale)
	if next_size != size or next_position != position: _cancel()
	min_size = Vector2i.ZERO
	max_size = next_size
	size = next_size
	position = next_position

func _build() -> void:
	_cancel()
	selected = -1
	for child in rows.get_children():
		rows.remove_child(child)
		child.queue_free()
	indices.clear()
	buttons.clear()
	theme = model.theme.duplicate() if model.theme != null else Theme.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(.055, .055, .065, .96)
	panel.border_color = Color(1, 1, 1, .14)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(10)
	panel.set_content_margin_all(8)
	background = panel
	theme.set_stylebox("panel", "PopupPanel", panel)
	if not stack.is_empty(): _add_row(-1, tr("Back"), null, false)
	for index in model.item_count:
		if model.is_item_separator(index):
			var separator := HSeparator.new()
			separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
			separator.custom_minimum_size.y = 9
			rows.add_child(separator)
			continue
		var text := model.get_item_text(index)
		if model.get_item_auto_translate_mode(index) != Node.AUTO_TRANSLATE_MODE_DISABLED:
			text = model.tr(text)
		var suffix := "  ›" if model.get_item_submenu_node(index) != null else ""
		_add_row(index, text + suffix, model.get_item_icon(index), model.is_item_disabled(index))
		if preload("res://scenes/PopupChrome.gd").is_danger(model, index):
			var row: Button = buttons[-1]
			for state in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color", "icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color"]:
				row.add_theme_color_override(state, preload("res://scenes/UIAccent.gd").DANGER)
	_stop_glide()
	scroll.scroll_vertical = 0

func _add_row(index: int, text: String, icon: Texture2D, disabled: bool) -> void:
	var row := Button.new()
	row.text = text
	# Labels are already resolved using the command model's translation policy.
	row.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	row.tooltip_text = text
	row.icon = icon
	row.expand_icon = true
	row.add_theme_constant_override("icon_max_width", 20)
	row.add_theme_font_size_override("font_size", DesktopText.size(16 if touch else 14))
	row.alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.clip_text = true
	row.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.custom_minimum_size.y = ROW_HEIGHT if touch else DESKTOP_ROW_HEIGHT
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.focus_mode = Control.FOCUS_NONE
	row.toggle_mode = true
	row.disabled = disabled
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color.TRANSPARENT
	normal.set_corner_radius_all(6)
	normal.set_content_margin_all(6)
	if index >= 0 and model.is_item_checkable(index):
		# Keep the state visible when empty, without replacing the command icon
		# or shifting its label when toggled. Share the themed DPI indicators.
		var state := "checked" if model.is_item_checked(index) else "unchecked"
		if model.is_item_radio_checkable(index): state = "radio_" + state
		if disabled: state += "_disabled"
		var indicator := TextureRect.new()
		indicator.name = "CheckIndicator"
		indicator.texture = model.get_theme_icon(state, "PopupMenu")
		indicator.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		indicator.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(indicator)
		indicator.anchor_top = .5
		indicator.anchor_bottom = .5
		indicator.offset_left = 6
		indicator.offset_right = 26
		indicator.offset_top = -10
		indicator.offset_bottom = 10
		normal.content_margin_left = 34
	var hint: Label = null
	if index >= 0 and model.get_item_accelerator(index) != 0:
		hint = Label.new()
		hint.text = preload("res://scenes/WorkspacePrefix.gd").key_label(model.get_item_accelerator(index))
		hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hint.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		hint.add_theme_font_size_override("font_size", DesktopText.size(12))
		# The menu inherits the theme of whatever opened it; a themed Label
		# stylebox would pad the hint and push its text off the right edge.
		hint.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		hint.modulate.a = .5
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(hint)
		# Pinned to the right edge, growing leftwards over the reserved margin.
		hint.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
		hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		hint.offset_left = -8
		hint.offset_right = -8
		row.tooltip_text += " (" + hint.text + ")"
	row.add_theme_stylebox_override("normal", normal)
	row.add_theme_stylebox_override("hover", normal)
	row.add_theme_stylebox_override("disabled", normal)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(preload("res://scenes/UIAccent.gd").PRIMARY, .28)
	row.add_theme_stylebox_override("pressed", pressed)
	rows.add_child(row)
	if hint != null:
		# Only inside the tree does the label know its themed width. Reserve it
		# so the trimmed command name never runs under the shortcut.
		var reserve := _hint_width(hint) + 20
		for style in [normal, pressed]: style.content_margin_right = reserve
		row.update_minimum_size()
	indices.append(index)
	buttons.append(row)
	# Accessibility activation uses the same command boundary as a tap.
	row.pressed.connect(_activate.bind(buttons.size() - 1))

## The shortcut text as drawn, independent of any inherited Label padding.
static func _hint_width(hint: Label) -> float:
	var font := hint.get_theme_font("font")
	return ceilf(font.get_string_size(hint.text, HORIZONTAL_ALIGNMENT_LEFT, -1, hint.get_theme_font_size("font_size")).x)


## Rows clip their text (so long labels trim on touch), which hides the text
## from their minimum size: measure the widest label, icon and shortcut here.
func _content_width() -> float:
	var widest := 0.0
	for row in buttons:
		var font := row.get_theme_font("font")
		var width := font.get_string_size(row.text, HORIZONTAL_ALIGNMENT_LEFT, -1, row.get_theme_font_size("font_size")).x
		if row.icon != null: width += row.get_theme_constant("icon_max_width") + row.get_theme_constant("h_separation")
		width += row.get_theme_stylebox("normal").get_minimum_size().x
		for hint in row.get_children():
			if hint is Label: width += _hint_width(hint) + 24
		widest = maxf(widest, width)
	return ceilf(widest)

func _row_at(point: Vector2) -> int:
	for index in buttons.size():
		if not buttons[index].disabled and buttons[index].get_global_rect().has_point(point): return index
	return -1

func _highlight(index: int) -> void:
	selected = index
	for row in buttons.size(): buttons[row].set_pressed_no_signal(row == index)

func _stop_glide() -> void:
	scroll.stop_scrolling()

func _cancel() -> void:
	# A sequence cut short still lets its pull spring back.
	if scroll.elastic.is_touching(): scroll.elastic_touch_end(false)
	fingers.clear()
	contact = -2
	dragging = false
	pressed_row = -1
	_highlight(-1)

func _pointer(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			fingers[event.index] = true
			if contact != -2:
				contact = -3 # No activation until all fingers lift.
				_stop_glide()
				_highlight(-1)
			else: _begin(event.index, event.position)
		else:
			fingers.erase(event.index)
			if event.index == contact: _finish(event.position, event.canceled)
			elif fingers.is_empty(): _cancel()
		surface.accept_event()
	elif event is InputEventScreenDrag:
		if contact == event.index: _move(event.position)
		surface.accept_event()
	elif event is InputEventMouseButton:
		# Touch already owns the sequence; ignore its emulated mouse copy.
		if event.device == -1: return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed: _begin(-1, event.position)
			elif contact == -1: _finish(event.position, event.canceled)
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_stop_glide()
			scroll.get_v_scroll_bar().value += (ROW_HEIGHT if touch else DESKTOP_ROW_HEIGHT) * (-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
			_highlight(-1)
		surface.accept_event()
	elif event is InputEventPanGesture:
		# Trackpads (and finger pans) scroll by the distance travelled.
		if contact == -2 and scroll.elastic_pan(event): _highlight(-1)
		surface.accept_event()
	elif event is InputEventMouseMotion and event.device != -1:
		if contact == -1: _move(event.position)
		elif contact == -2: _highlight(_row_at(event.position + surface.position))

func _begin(id: int, point: Vector2) -> void:
	contact = id
	origin = point
	# A touch that brakes a glide must not also activate the row beneath it.
	dragging = scroll.gliding()
	scroll.elastic_touch_begin()
	last = point
	pressed_row = -1 if dragging else _row_at(point + surface.position)
	_highlight(pressed_row)

func _move(point: Vector2) -> void:
	if point.distance_to(origin) > DRAG_THRESHOLD: dragging = true
	if dragging:
		_highlight(-1)
		scroll.elastic_touch_move(Vector2(0, point.y - last.y))
	last = point

func _finish(point: Vector2, canceled: bool) -> void:
	_move(point)
	var activate := pressed_row if not canceled and not dragging and _row_at(point + surface.position) == pressed_row else -1
	# Only a finger flicks; a mouse drag stops where it is released.
	var flick := dragging and not canceled and contact >= 0
	scroll.elastic_touch_end(flick)
	_cancel()
	if activate >= 0: _activate(activate)

func _activate(row: int) -> void:
	if row < 0 or row >= indices.size(): return
	var index := indices[row]
	if index == -1:
		model = stack.pop_back()
		_build()
		_fit()
		return
	if model.is_item_disabled(index): return
	var submenu := model.get_item_submenu_node(index)
	if submenu != null:
		stack.append(model)
		model = submenu
		model.about_to_popup.emit()
		_build()
		_fit()
		return
	var close := model.hide_on_item_selection
	if model.is_item_checkable(index): close = model.hide_on_checkable_item_selection
	if model.get_item_multistate_max(index) > 0: close = model.hide_on_state_item_selection
	var command_model := model
	if close: hide()
	command_model.id_pressed.emit(command_model.get_item_id(index))
	if is_instance_valid(command_model): command_model.index_pressed.emit(index)
	if not close and visible: _build()

func _key(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed: return
	if event.keycode == KEY_ESCAPE:
		hide()
	elif event.keycode in [KEY_UP, KEY_DOWN]:
		var direction := -1 if event.keycode == KEY_UP else 1
		var next := selected
		for attempt in buttons.size():
			next = posmod(next + direction, buttons.size())
			if not buttons[next].disabled:
				_highlight(next)
				scroll.ensure_control_visible(buttons[next])
				break
	elif event.keycode == KEY_LEFT and not stack.is_empty(): _activate(0)
	elif event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_RIGHT]: _activate(selected)
	else:
		for row in indices.size():
			var index := indices[row]
			if index < 0 or model.is_item_disabled(index): continue
			var shortcut := model.get_item_shortcut(index)
			if (shortcut != null and shortcut.matches_event(event)) or model.get_item_accelerator(index) == event.get_keycode_with_modifiers():
				_activate(row)
				set_input_as_handled()
				return
		return
	set_input_as_handled()

func _closed() -> void:
	pending = false
	_cancel()
	if opening != null: opening.kill()
	if is_instance_valid(model): model.popup_hide.emit()
	for parent_model in stack:
		if is_instance_valid(parent_model): parent_model.popup_hide.emit()
	stack.clear()
