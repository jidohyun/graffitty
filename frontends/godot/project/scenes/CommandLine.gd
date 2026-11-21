extends CanvasLayer
## Vim-like command line opened by the workspace prefix with `:`, `%`, `@`,
## `$` or a digit, with a wilder.nvim-style completion list above it.
##
## CommandLineModel.gd ranks and runs the rows; this draws them and owns the
## keyboard while open.
const Model := preload("res://scenes/CommandLineModel.gd")
const MatchLabel := preload("res://scenes/SearchMatchLabel.gd")
const MAX_ROWS := 10
const ACCENT := Color("ffd078")

var host: Node
var model := Model.new()
var line := LineEdit.new()
var _root := VBoxContainer.new()
var _popup := PanelContainer.new()
var _list := VBoxContainer.new()
var _bar := PanelContainer.new()
var _prompt := Label.new()
var _status := Label.new()
var _background := Color("20242c")
var _foreground := Color.WHITE
var _font: Font
var _font_size := 16
var _bottom_inset := 0.0


func _init() -> void:
	layer = preload("res://scenes/WorkspaceLayers.gd").Order.COMMAND
	visible = false


func _ready() -> void:
	model.host = host
	_root.resized.connect(_place)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_theme_constant_override("separation", 4)
	add_child(_root)
	_list.add_theme_constant_override("separation", 2)
	_popup.add_child(_list)
	_root.add_child(_popup)
	var row := HBoxContainer.new()
	_prompt.text = ":"
	row.add_child(_prompt)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_theme_constant_override("minimum_character_width", 1)
	line.flat = true
	line.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	line.context_menu_enabled = false
	line.text_changed.connect(_on_text_changed)
	row.add_child(line)
	_status.clip_text = true
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(_status)
	_bar.add_child(row)
	_root.add_child(_bar)
	host.ui_changed.connect(_on_ui_changed)
	host.active_session_changed.connect(func(_id): dismiss())
	get_viewport().size_changed.connect(func():
		if visible: _render())
	# Window focus loss reaches this through WorkspacePrefix.focus_lost().


func open(text: String) -> void:
	# Input runs in reverse tree order; being last keeps the in-window menu
	# bar, rebuilt on focus changes, from taking shortcuts first.
	get_parent().move_child(self, -1)
	_apply_theme()
	# The focused terminal owns the IME while it has focus; release it before
	# the line takes the keyboard.
	var pair: Dictionary = host.sessions.get(int(host.pane_focus.substr(1)), {}) if host.is_terminal_pane(host.pane_focus) else {}
	if not pair.is_empty() and is_instance_valid(pair.term):
		pair.term.release_focus()
	visible = true
	_show_text(text)
	model.set_text(text)
	_render()
	line.grab_focus()
	# Command names and numbers are ASCII, so a Korean input source types Latin.
	if DisplayServer.has_feature(DisplayServer.FEATURE_IME):
		DisplayServer.window_set_ime_active(false, get_window().get_window_id())


## Closes and gives the keyboard back to the focused pane.
func close() -> void:
	if not visible:
		return
	dismiss()
	host.focus_pane(host.pane_focus)


## Closes without moving focus, because something else is taking it.
func dismiss() -> void:
	if not visible:
		return
	visible = false
	line.release_focus()


## Keeps the line above the Android soft keyboard.
func set_bottom_inset(inset: float) -> void:
	if is_equal_approx(_bottom_inset, inset): return
	_bottom_inset = inset
	if visible: _render()


func _place() -> void:
	if is_inside_tree():
		_root.position = Vector2(8, get_viewport().get_visible_rect().size.y - 8 - _bottom_inset - _root.size.y)


## Handles navigation keys; anything else is left to the LineEdit. The Android
## key bar calls this too, since its buttons otherwise type into the terminal.
func handle_key(event: InputEventKey) -> bool:
	if not visible or not event.pressed:
		return false
	var key := event.keycode
	if key == KEY_ESCAPE:
		close()
	elif key in [KEY_ENTER, KEY_KP_ENTER]:
		if not event.echo:
			_accept()
	elif key == KEY_TAB:
		model.cycle(-1 if event.shift_pressed else 1)
		_show_text(model.text)
	elif key == KEY_UP or (key == KEY_P and event.ctrl_pressed):
		model.move(-1)
	elif key == KEY_DOWN or (key == KEY_N and event.ctrl_pressed):
		model.move(1)
	elif key == KEY_BACKSPACE and line.text.is_empty():
		if not event.echo:
			close()
	else:
		return false
	_render()
	return true


func _input(event: InputEvent) -> void:
	if not visible:
		return
	var tap: bool = event is InputEventScreenTouch or (
		event is InputEventMouseButton
		and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]
	)
	if tap and event.pressed:
		# An outside click or tap leaves without running anything; wheels scroll.
		if not _popup.get_global_rect().has_point(event.position) and not _bar.get_global_rect().has_point(event.position):
			close()
		return
	if event is InputEventKey and handle_key(event):
		get_viewport().set_input_as_handled()


func _shortcut_input(event: InputEvent) -> void:
	# The LineEdit already took the keys it edits with. Menu shortcuts, which
	# the in-window menu bar runs at this stage, wait until the line closes.
	if visible and event is InputEventKey:
		get_viewport().set_input_as_handled()


func _unhandled_key_input(_event: InputEvent) -> void:
	# Keys the LineEdit did not take must not reach the terminal underneath.
	if visible:
		get_viewport().set_input_as_handled()


func _on_text_changed(text: String) -> void:
	model.set_text(text)
	_render()


func _on_ui_changed() -> void:
	if visible:
		model.refresh()
		# A previewed row that was renumbered shows its new label.
		if line.text != model.text:
			_show_text(model.text)
		_render()


func _accept() -> void:
	var row := model.accepted()
	if row.is_empty():
		if model.query.is_empty():
			close()
		return # The status explains why nothing ran.
	close()
	model.execute(row)


func _choose(index: int) -> void:
	model.select(index)
	_accept()


func _show_text(text: String) -> void:
	line.text = text
	line.caret_column = text.length()


func _apply_theme() -> void:
	var source: Control = null
	if is_instance_valid(host.workspace_view) and "tab_bar" in host.workspace_view and is_instance_valid(host.workspace_view.tab_bar):
		source = host.workspace_view.tab_bar
	if source != null:
		if source.has_method("_title_background"):
			_background = source._title_background()
		_foreground = source.get_theme_color("font_color", "Button")
		_font = source.get_theme_font("font", "Button")
		_font_size = source.get_theme_font_size("font_size", "Button")
	for control: Control in [line, _prompt, _status]:
		if _font != null:
			control.add_theme_font_override("font", _font)
		control.add_theme_font_size_override("font_size", _font_size)
	line.add_theme_color_override("font_color", _foreground)
	line.add_theme_color_override("font_placeholder_color", _dim())
	line.add_theme_color_override("caret_color", ACCENT)
	_prompt.add_theme_color_override("font_color", ACCENT)
	_status.add_theme_color_override("font_color", _dim())
	for panel in [_popup, _bar]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(_background, 0.97)
		style.set_corner_radius_all(8)
		style.set_content_margin_all(6)
		panel.add_theme_stylebox_override("panel", style)


func _dim() -> Color:
	return _foreground.lerp(_background, 0.4)


func _render() -> void:
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	var rows := model.rows
	_popup.visible = not rows.is_empty()
	# Without an explicit choice, the row Enter would run is tinted lightly.
	var current := model.selected if model.selected >= 0 else (0 if not model.accepted().is_empty() else -1)
	# Ten touch rows can exceed the entire phone, especially above the IME.
	# Page around the selection using only the space above the input bar.
	var font := _font if _font != null else ThemeDB.fallback_font
	var row_height := font.get_height(_font_size) + 8.0
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		row_height = maxf(46.0, row_height)
	var room := get_viewport().get_visible_rect().size.y - _bottom_inset - 32.0 - _bar.get_combined_minimum_size().y
	var count := clampi(int(floor(room / row_height)), 0, MAX_ROWS)
	var start := clampi(current - count + 1, 0, maxi(0, rows.size() - count))
	var shown := range(start, mini(start + count, rows.size()))
	_popup.visible = not shown.is_empty()
	var available := maxf(1.0, get_viewport().get_visible_rect().size.x - 16.0)
	var width := 0.0
	for index in shown:
		width = maxf(width, _text_width(str(rows[index].candidate.label)))
	# Keep space for descriptions and shortcuts even with an unusually long name.
	var address_width := minf(width, available * 0.35)
	var content_width := 0.0
	for index in shown:
		var candidate: Dictionary = rows[index].candidate
		content_width = maxf(content_width, width + _text_width(_title(candidate)) + _text_width(str(candidate.detail)) + 48.0 + 28.0)
		_list.add_child(_row(rows[index], index, address_width, available, index == current, index == model.selected))
	var message := tr(model.status())
	if message.is_empty() and (model.selected >= 0 or rows.size() > count):
		message = "%d/%d" % [maxi(current + 1, 0), rows.size()]
	_status.text = message
	_status.custom_minimum_size.x = minf(_text_width(message), available * 0.4)
	line.placeholder_text = model.placeholder_text()
	var input_width := maxf(_text_width(line.text), _text_width(line.placeholder_text))
	# Panel margins, the prompt, the status and spacing between input columns.
	content_width = maxf(content_width, input_width + _text_width(":" + message) + 32.0)
	_root.size = Vector2(minf(ceilf(content_width), available), 0)
	_place()


func _text_width(text: String) -> float:
	var font := _font if _font != null else ThemeDB.fallback_font
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size).x


func _title(candidate: Dictionary) -> String:
	return ("✓ " if candidate.get("checked", false) else "") + str(candidate.title).replace("\n", " ") + (tr("  (hidden)") if candidate.get("hidden", false) else "")


func _row(row: Dictionary, index: int, width: float, available: float, current: bool, chosen: bool) -> Control:
	var candidate: Dictionary = row.candidate
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = _background.lerp(_foreground, 0.16 if chosen else (0.08 if current else 0.0))
	style.set_corner_radius_all(4)
	style.set_content_margin_all(3)
	style.content_margin_left = 8
	style.content_margin_right = 8
	panel.add_theme_stylebox_override("panel", style)
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		panel.custom_minimum_size.y = 44
	panel.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_choose(index))
	var view := preload("res://scenes/mods/EmbeddedMod.gd").create("command-line", {
		"label": str(candidate.label), "indices": row.indices, "title": _title(candidate),
		"detail": tr(str(candidate.detail)), "address_width": width, "detail_width": minf(_text_width(tr(str(candidate.detail))), available * .25),
		"font_size": _font_size, "foreground": "#" + _foreground.to_html(), "dim": "#" + _dim().to_html(),
	})
	var font := _font if _font != null else ThemeDB.fallback_font
	view.custom_minimum_size.y = font.get_height(_font_size)
	panel.add_child(view)
	return panel
