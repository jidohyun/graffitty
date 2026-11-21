extends Control
## Read-only text that selects and scrolls like a terminal.
##
## - Drag selects characters. A double click takes a terminal word, and
##   dragging on extends word by word. A triple click takes the line, and
##   dragging extends line by line. Words follow the terminal's
##   `selection_word_boundaries`.
## - Trackpad pans and finger drags scroll by the distance travelled. A flick
##   glides, and both stretch past either end and spring back like a terminal.
## - Copy with Cmd/Ctrl+C or the context menu.
## - On Android the system's own selection handles and Copy toolbar take over
##   (AndroidSelectableText), with its native stretch overscroll.
##
## Rust owns word boundaries (`TextWords`) and motion (`ElasticScroller`).

const ElasticScrollContainer := preload("res://scenes/ElasticScrollContainer.gd")
const TOUCH_SLOP := 12.0
## A third click this soon after a double click, this close, takes the line.
const TRIPLE_CLICK_MSEC := 400
const TRIPLE_CLICK_DISTANCE := 6.0
enum Mode { NONE, WORD, LINE }

var view := TextEdit.new()
## Clips the text (and its rubber-band shift); the Android scrollbar may draw
## outside it, in the margin beside this view.
var _clip := Control.new()
var words: RefCounted = ClassDB.instantiate("TextWords")
var elastic: RefCounted = ClassDB.instantiate("ElasticScroller")
## The Android overlay that owns selection there; null elsewhere.
var native_text: Node
var text: String:
	get: return view.text
	set(value):
		if view.text == value: return
		var keep := view.scroll_vertical
		view.text = value
		if follow_end: _scroll_to_end.call_deferred()
		else: view.scroll_vertical = keep
## Grow to the text instead of scrolling it; an enclosing list scrolls.
var fit_content := false:
	set(value):
		fit_content = value
		view.scroll_fit_content_height = value
		update_minimum_size()
## Keep the newest text in view as it arrives, like a log.
var follow_end := false
## With the Android overlay, the native text's height in this view's pixels,
## and the offset it is drawn at (the hidden TextEdit does not scroll).
var native_content_height := 0.0:
	set(value):
		native_content_height = value
		# Flash the scrollbar when there is more to see, as a Mac does.
		_bar_moved_msec = Time.get_ticks_msec()
		var limits := _limits()
		_set_offset(limits.x if follow_end else minf(_offset(), limits.x))
var _native_offset := 0.0
## The overlay scrollbar drawn under the Android text: shown while it moves,
## faded out after a rest, as on a Mac.
const BAR_WIDTH := 4.0
const BAR_MARGIN := 3.0
const BAR_MIN_LENGTH := 24.0
const BAR_REST_MSEC := 900
const BAR_FADE_MSEC := 300
var _bar_moved_msec := -100000
var _bar_skin: Control
## Draw the Android scrollbar just outside this view's right edge, in the
## margin of the dialog or panel around it, so it hugs that edge and the text
## keeps its full width. Needs at least BAR_WIDTH + 2 pixels of margin.
var bar_outside := false
var _mode := Mode.NONE
var _anchor := PackedInt32Array()
var _double_click_msec := -TRIPLE_CLICK_MSEC
var _double_click_at := Vector2.ZERO
var _drag_at := Vector2.ZERO
var _touch := -1
var _touch_origin := Vector2.ZERO
var _touch_dragging := false
var menu: PopupMenu


func _init() -> void:
	_clip.clip_contents = true
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_clip)
	view.editable = false
	view.context_menu_enabled = false
	view.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	view.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	view.highlight_current_line = false
	view.caret_blink = false
	view.deselect_on_focus_loss_enabled = false
	view.drag_and_drop_selection_enabled = false
	view.middle_mouse_paste_enabled = false
	view.virtual_keyboard_enabled = false
	view.emoji_menu_enabled = false
	view.focus_mode = Control.FOCUS_CLICK
	view.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	for style in ["normal", "read_only", "focus"]:
		view.add_theme_stylebox_override(style, StyleBoxEmpty.new())
	view.add_theme_color_override("caret_color", Color.TRANSPARENT)
	view.add_theme_color_override("font_readonly_color", Color("d8dde6"))
	view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_clip.add_child(view)
	view.gui_input.connect(_view_input)
	view.minimum_size_changed.connect(update_minimum_size)
	set_process(false)


func _enter_tree() -> void:
	# Words end where the terminal's do.
	var node := get_parent()
	while node != null and node.get("terminal_config") == null: node = node.get_parent()
	words.set_word_boundaries(node.terminal_config.selection_word_boundaries if node != null else null)
	if OS.has_feature("android") and not fit_content and native_text == null:
		native_text = preload("res://scenes/remote/AndroidSelectableText.gd").new()
		native_text.source = self
		add_child(native_text)


func _get_minimum_size() -> Vector2:
	return view.get_combined_minimum_size() if fit_content else Vector2.ZERO


## The readable text colour.
func set_font_color(color: Color) -> void:
	view.add_theme_color_override("font_readonly_color", color)


func font_color() -> Color:
	return view.get_theme_color("font_readonly_color")


func font_size() -> int:
	return view.get_theme_font_size("font_size")


func has_selection() -> bool:
	return view.has_selection()


func get_selected_text() -> String:
	return view.get_selected_text()


func select_all() -> void:
	view.select_all()


func deselect() -> void:
	view.deselect()


## Copy the selection; with nothing selected, copy everything.
func copy() -> void:
	DisplayServer.clipboard_set(view.get_selected_text() if view.has_selection() else view.text)


func _scroll_to_end() -> void:
	if native_text != null: _set_offset(_limits().x)
	else: view.scroll_vertical = _limits().x / maxf(view.get_line_height(), 1.0)


# --- Scrolling ---------------------------------------------------------------

## (max offset, page) in pixels.
func _limits() -> Vector2:
	if native_text != null: return Vector2(maxf(native_content_height - size.y, 0.0), size.y)
	var bar := view.get_v_scroll_bar()
	var row := float(view.get_line_height())
	return Vector2(maxf(bar.max_value - bar.page, 0.0) * row, view.size.y)


func _offset() -> float:
	if native_text != null: return _native_offset
	return view.scroll_vertical * view.get_line_height()


func _set_offset(offset: float) -> void:
	if native_text != null:
		var pull: float = elastic.get_stretch()
		if not is_equal_approx(offset, _native_offset) or pull != 0.0:
			_bar_moved_msec = Time.get_ticks_msec()
		_native_offset = offset
		native_text.scroll(offset, pull)
		queue_redraw()
		set_process(elastic.is_active() or _bar_alpha() > 0.0)
		return
	var row := maxf(view.get_line_height(), 1.0)
	if not is_equal_approx(_offset(), offset): view.scroll_vertical = offset / row
	var pull: float = elastic.get_stretch()
	# The scrollbar thumb shortens against the pulled end, in the bar's rows.
	if pull != 0.0 or _bar_skin != null:
		if _bar_skin == null: _bar_skin = preload("res://scenes/ElasticBarSkin.gd").attach(view.get_v_scroll_bar(), elastic)
		_bar_skin.set_stretch(pull / row)
	view.offset_top = -pull
	view.offset_bottom = -pull
	set_process(elastic.is_active() or _mode != Mode.NONE)


func _process(_dt: float) -> void:
	var limits := _limits()
	var offset: float = elastic.advance(_offset(), limits.x, limits.y)
	# Dragging a selection past an edge scrolls toward the pointer.
	if _mode != Mode.NONE:
		var past := 0.0
		if _drag_at.y < 0.0: past = _drag_at.y
		elif _drag_at.y > view.size.y: past = _drag_at.y - view.size.y
		if past != 0.0:
			offset = clampf(offset + past * 0.25, 0.0, limits.x)
			_extend_to(_drag_at)
	_set_offset(offset)


func _bar_alpha() -> float:
	var rest := Time.get_ticks_msec() - _bar_moved_msec - BAR_REST_MSEC
	return clampf(1.0 - float(rest) / BAR_FADE_MSEC, 0.0, 1.0)


func _draw() -> void:
	if native_text == null: return
	var limits := _limits()
	var alpha := _bar_alpha()
	if limits.x <= 0.0 or alpha <= 0.0: return
	# A pull past either end shortens the thumb against that end.
	var span: Vector2 = elastic.thumb(size.y - BAR_MARGIN * 2.0, _native_offset, limits.x, limits.y, elastic.get_stretch(), BAR_MIN_LENGTH)
	var thumb := StyleBoxFlat.new()
	thumb.bg_color = Color(1, 1, 1, 0.45 * alpha)
	thumb.set_corner_radius_all(int(BAR_WIDTH / 2.0))
	var x := size.x + 1.0 if bar_outside else size.x - BAR_WIDTH - BAR_MARGIN
	draw_style_box(thumb, Rect2(x, BAR_MARGIN + span.x, BAR_WIDTH, span.y))


## Width the Android text leaves free on its right for the overlay scrollbar.
func bar_gutter() -> float:
	return 0.0 if bar_outside else BAR_WIDTH + BAR_MARGIN * 2.0


## Finger motion the Android overlay reports (`dy` in this view's pixels).
func native_touch(kind: String, dy: float) -> void:
	var limits := _limits()
	match kind:
		"down":
			elastic.touch_begin()
			set_process(true)
		"move":
			_set_offset(elastic.touch_move(Vector2(0, dy), _offset(), limits.x, limits.y))
		"up", "cancel":
			elastic.touch_end(_offset(), limits.x, limits.y, kind == "up")
			set_process(true)


## A list that encloses this text scrolls instead of it.
func _enclosing_list() -> Node:
	var node := get_parent()
	while node != null and not node is ElasticScrollContainer: node = node.get_parent()
	return node


# --- Input -------------------------------------------------------------------

func _view_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		var list := _enclosing_list() if fit_content else null
		if list != null:
			if list.elastic_pan(event): view.accept_event()
			return
		var limits := _limits()
		var along: float = event.delta.y
		_set_offset(elastic.pan(event, along, _offset(), limits.x, limits.y))
		view.accept_event()
		return
	if _touch_input(event): return
	if event is InputEventMouseButton:
		var wheel: bool = event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]
		var list := _enclosing_list() if fit_content and wheel else null
		if list != null:
			# Text that fits has nothing to scroll; its list takes the wheel step.
			if event.pressed:
				var bar: ScrollBar = list.get_v_scroll_bar()
				bar.value += bar.page / 8.0 * event.factor * (-1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0)
			view.accept_event()
			return
		if event.pressed and wheel and elastic.is_active():
			elastic.stop()
			_set_offset(_offset())
			return
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_show_menu()
			view.accept_event()
			return
		if event.button_index != MOUSE_BUTTON_LEFT: return
		if not event.pressed:
			if _mode != Mode.NONE:
				_mode = Mode.NONE
				view.accept_event()
			return
		var now := Time.get_ticks_msec()
		var triple: bool = not event.double_click and now - _double_click_msec <= TRIPLE_CLICK_MSEC \
			and event.position.distance_to(_double_click_at) <= TRIPLE_CLICK_DISTANCE
		if event.double_click:
			_double_click_msec = now
			_double_click_at = event.position
			_begin(Mode.WORD, event.position)
			view.accept_event()
		elif triple:
			_double_click_msec = -TRIPLE_CLICK_MSEC
			_begin(Mode.LINE, event.position)
			view.accept_event()
		return
	if event is InputEventMouseMotion and _mode != Mode.NONE:
		_drag_at = event.position
		_extend_to(event.position)
		view.accept_event()


func _span(at: Vector2) -> PackedInt32Array:
	var cell := view.get_line_column_at_pos(Vector2i(at))
	var line := clampi(cell.y, 0, view.get_line_count() - 1)
	var content := view.get_line(line)
	var columns: Vector2i = words.word_range(content, cell.x) if _mode == Mode.WORD else words.line_range(content)
	if _mode == Mode.LINE and columns.x == columns.y: columns = Vector2i(0, content.length())
	return PackedInt32Array([line, columns.x, line, columns.y])


func _begin(mode: Mode, at: Vector2) -> void:
	_mode = mode
	_drag_at = at
	_anchor = _span(at)
	view.grab_focus()
	view.select(_anchor[0], _anchor[1], _anchor[2], _anchor[3])
	set_process(true)


func _extend_to(at: Vector2) -> void:
	var clamped := Vector2(at.x, clampf(at.y, 0.0, maxf(view.size.y - 1.0, 0.0)))
	var selection: PackedInt32Array = words.extend(_anchor, _span(clamped))
	if selection.size() == 4: view.select(selection[0], selection[1], selection[2], selection[3])


## Fingers scroll; they never drag a selection. Returns whether handled.
func _touch_input(event: InputEvent) -> bool:
	if native_text != null: return false
	if event is InputEventScreenTouch:
		if fit_content: return false
		if event.pressed and _touch == -1:
			_touch = event.index
			_touch_origin = event.position
			_touch_dragging = false
			elastic.touch_begin()
			set_process(true)
		elif not event.pressed and event.index == _touch:
			_touch = -1
			_touch_dragging = false
			var limits := _limits()
			elastic.touch_end(_offset(), limits.x, limits.y, true)
			set_process(true)
		view.accept_event()
		return true
	if event is InputEventScreenDrag and event.index == _touch:
		var relative: Vector2 = event.relative
		if not _touch_dragging:
			var travel: Vector2 = event.position - _touch_origin
			if travel.length() <= TOUCH_SLOP: return true
			_touch_dragging = true
			relative = travel - travel.normalized() * TOUCH_SLOP
		var limits := _limits()
		_set_offset(elastic.touch_move(relative, _offset(), limits.x, limits.y))
		view.accept_event()
		return true
	# The emulated mouse of a finger would otherwise drag a selection.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION and not fit_content:
		view.accept_event()
		return true
	return false


func _show_menu() -> void:
	if menu == null:
		menu = PopupMenu.new()
		menu.prefer_native_menu = true
		menu.add_item("Copy", 0)
		menu.add_item("Select All", 1)
		menu.id_pressed.connect(func(id: int):
			if id == 0: copy()
			else: view.select_all())
		add_child(menu)
	menu.set_item_disabled(0, view.text.is_empty())
	preload("res://scenes/input/PointerPopup.gd").open(menu)
