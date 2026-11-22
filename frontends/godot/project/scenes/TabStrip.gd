extends "res://scenes/ElasticScrollContainer.gd"
## Shared ID-keyed tabs. Owners supply data and handle selection/close/reorder.
## No terminal or chromium session ownership lives in this control.
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")
const ActionStyle := preload("res://scenes/TabActionStyle.gd")
# Chromium TabContainer / BoundsAnimator: 200 ms, quadratic EASE_OUT,
# retarget from current bounds and leave unchanged targets running.
const BOUNDS_DURATION := 0.2
const INSERTION_WIDTH := 16.0


class AttentionDot extends Control:
	const COLORS := {"waiting": Color("e3b341"), "completed": Color("8ab4f8")}
	const RADIUS := 4.0
	var state := ""
	var count := 0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_TOP_RIGHT)

	func present(next_state: String, next_count: int) -> void:
		if next_state == state and next_count == count: return
		state = next_state
		count = next_count
		var width := RADIUS * 2.0
		if count > 1:
			width = maxf(width, _font().get_string_size(str(count), HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x + 6.0)
		# Top-right corner, clear of the vertically centred close glyph.
		offset_left = -width - 5.0
		offset_right = -5.0
		offset_top = 3.0
		offset_bottom = 3.0 + (RADIUS * 2.0 if count <= 1 else 12.0)
		queue_redraw()

	func _font() -> Font:
		return get_theme_default_font()

	func _draw() -> void:
		var color: Color = COLORS.get(state, Color.WHITE)
		if count <= 1:
			draw_circle(size * 0.5, RADIUS, color)
			return
		var radius := size.y * 0.5
		var box := StyleBoxFlat.new()
		box.bg_color = color
		box.set_corner_radius_all(int(radius))
		draw_style_box(box, Rect2(Vector2.ZERO, size))
		var text := str(count)
		var font := _font()
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
		var baseline := (size.y + font.get_ascent(9) - font.get_descent(9)) * 0.5
		draw_string(font, Vector2((size.x - width) * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.08, 0.09, 0.1))


class BoundsAnimation:
	var start: Rect2
	var target: Rect2
	var elapsed := 0.0
	var started := false


	func _init(from: Rect2, to: Rect2) -> void:
		start = from
		target = to


signal selected(id: int)
signal clicked(id: int, was_selected: bool)
signal closed(id: int)
signal moved(id: int, index: int)
signal drag_started(id: int)
signal context_requested(id: int)
signal new_tab
signal layout_changed
signal appearance_changed
var external_drop: Callable
var external_motion: Callable
var external_drop_hint := -1
var incoming_tab: Button
var _incoming_title := ""
var _drag_external := false
var row := Control.new()
var plus := Button.new()
var buttons: Dictionary = { }
var ids: Array = []
var selected_id := -1
var _reveal_selected := -1
var close_tooltip := ""
var tab_count: int:
	get:
		return ids.size()
var current_tab: int:
	get:
		return ids.find(selected_id)
	set(value):
		if value >= 0 and value < ids.size():
			selected.emit(int(ids[value]))
var _pressed_id := -1
var _press_was_selected := false
var _press_point := Vector2.ZERO
var _dragging := false
var _drop_index := -1
var _pointer := Vector2.ZERO
var _pending_pages: Array = []
var _pending_active_id := -1
var _icon_keys: Dictionary = { }
var icon_factory: Callable
var title_formatter: Callable
@export var compact_tabs := false
@export var minimum_tab_width := 104.0
@export var maximum_tab_width := 200.0
@export var tab_theme_type := "WorkspaceTab"
@export var connected_tabs := false
var connected_text_outline := true
## The application moves the native window; its sole tab stays in its slot.
var window_drag := false
var _visual_order: Array = []
var _pending_order: Array = []
var _grab_offset := 0.0
var _tab_width := 200.0
var _settling := false
var _resizing_tabs := false
var _bounds_animations: Dictionary[Control, BoundsAnimation] = {}
# Clipped views can reach zero width without stripping the tab's text insets.
var _closing_tabs: Dictionary[Control, int] = {}
var _commit_timer := Timer.new()
# Chromium's closing mode keeps the next close target under a stationary
# mouse.
#
# MouseWatcher allows 40 px below / 60 px right and waits 300 ms on exit;
# touch closes release the width constraint after two seconds.
var _closing_available := -1.0
var _closing_touch := false
var _close_exit_timer := Timer.new()
## Tab resting under the pointer while this strip reorders a drag, or -1.
var hover_id := -1
var _hover_hint := -1
var _hover_progress := 0.0
var _hover_overlay := Control.new()
var _reorder_hover_styles: Dictionary = {}


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# A finger on the strip drags tabs; only trackpad pans scroll it.
	handles_touch = false
	folds_axes = true
	custom_minimum_size.y = 34
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(row)
	# Above the lifted tab, which otherwise covers the tab being hovered.
	_hover_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hover_overlay.z_index = 6
	_hover_overlay.draw.connect(_draw_hover)
	row.add_child(_hover_overlay)
	_commit_timer.one_shot = true
	_commit_timer.wait_time = 6.0
	_commit_timer.timeout.connect(
		func():
			_pending_order.clear()
			_visual_order = ids.duplicate()
			_fit(),
	)
	add_child(_commit_timer)
	_close_exit_timer.one_shot = true
	_close_exit_timer.timeout.connect(func():
		if _closing_touch and _dragging: _close_exit_timer.start(2.0)
		else: _exit_closing_mode())
	add_child(_close_exit_timer)
	# Unit fixtures call _ready() outside a window; the strip still works without the exit hook.
	var window := get_window()
	if window != null: window.mouse_exited.connect(_schedule_close_exit)
	ActionStyle.apply(plus, "M8 3v10M3 8h10", 16, 32)
	if icon_factory.is_valid():
		plus.icon = icon_factory.call("plus")
	plus.name = "NewTab"
	plus.expand_icon = true
	plus.accessibility_name = tr("New tab")
	plus.focus_mode = Control.FOCUS_NONE
	plus.pressed.connect(
		func():
			new_tab.emit(),
	)
	if plus.get_parent() == null: row.add_child(plus)
	resized.connect(_fit)
	set_process(false)


func get_tab_title(index: int) -> String:
	var button: Button = buttons[ids[index]]
	return str(button.get_meta("display_text", button.text))


func get_tab_metadata(index: int) -> int:
	return int(ids[index])


func _surviving_predecessor(id: int, next_ids: Array) -> int:
	var index := ids.find(id)
	while index > 0:
		index -= 1
		if ids[index] in next_ids:
			return int(ids[index])
	return -1


func reconcile(pages: Array, active_id: int) -> void:
	_pending_pages = pages
	_pending_active_id = active_id
	if _dragging:
		var alive := false
		for page in pages:
			if int(page.id) == _pressed_id:
				alive = true
		if alive:
			selected_id = active_id
			for id in buttons:
				buttons[id].button_pressed = id == active_id
			return
		_cancel_drag()
	var next_ids: Array = []
	for page in pages:
		next_ids.append(int(page.id))
	if next_ids.any(func(id): return id not in ids):
		_clear_closing_mode()
	elif _closing_available >= 0.0 and next_ids != ids:
		# Trailing closes can expand into the old width. Non-trailing closes
		# remove one slot from the constraint so all remaining widths stay put.
		var remaining := ids.duplicate()
		for id in ids:
			if id in next_ids: continue
			if remaining.find(id) < remaining.size() - 1:
				_closing_available -= buttons[id].size.x + 3.0
			remaining.erase(id)
		if next_ids.size() <= 1 or _closing_available >= next_ids.size() * (maximum_tab_width + 3.0):
			_clear_closing_mode()
	if not ids.is_empty() and next_ids.size() != ids.size():
		_resizing_tabs = true
	# Keep the preview after release while the owner acknowledges the operation.
	# A structural change or the acknowledgement restores authoritative order.
	if not _pending_order.is_empty():
		var same_members := next_ids.size() == _pending_order.size()
		for id in next_ids:
			if not id in _pending_order:
				same_members = false
		if next_ids == _pending_order or not same_members:
			_pending_order.clear()
			_commit_timer.stop()
	_visual_order = next_ids.duplicate() if _pending_order.is_empty() else _pending_order.duplicate()
	# Repeated closes can remove the predecessor of an already-closing tab.
	# Keep its boundary attached to the nearest surviving tab, not index zero.
	for view: Control in _closing_tabs:
		if _closing_tabs[view] not in next_ids:
			_closing_tabs[view] = _surviving_predecessor(_closing_tabs[view], next_ids)
	for id in buttons.keys():
		if not id in next_ids:
			var button: Button = buttons[id]
			_bounds_animations.erase(button)
			if next_ids.is_empty() or _drag_external:
				row.remove_child(button)
				button.queue_free()
			else:
				# Chromium retains the content insets while its decorative overlap
				# collapses. Our non-overlapping content slot collapses to zero.
				# A clip parent lets it do so below Button's theme minimum width.
				var view := Control.new()
				view.mouse_filter = Control.MOUSE_FILTER_IGNORE
				view.clip_contents = true
				view.position = button.position
				view.size = button.size
				row.add_child(view)
				button.reparent(view, false)
				button.position = Vector2.ZERO
				_closing_tabs[view] = _surviving_predecessor(id, next_ids)
				button.set_meta("closing", true)
				button.button_pressed = false
				button.mouse_filter = Control.MOUSE_FILTER_IGNORE
				button.get_node("Close").hide()
				button.text = str(button.get_meta("display_text", button.text))
			buttons.erase(id)
			_icon_keys.erase(id)
	ids = next_ids
	for i in ids.size():
		var id: int = ids[i]
		var page: Dictionary = pages[i]
		if not buttons.has(id):
			_add_tab(id)
		var button: Button = buttons[id]
		if button.get_index() != i:
			row.move_child(button, i)
		# Tab buttons keep page titles literal, so translate only this fallback.
		var title := str(page.get("title", ""))
		if title.is_empty():
			title = tr("New tab")
		button.set_meta("title", title)
		# A compact ordinal has no text trimming. Temporarily assigning its full
		# title expands the button's minimum width, relayouts the strip and can
		# move a different tab under a pending click. Format before displaying.
		if not title_formatter.is_valid():
			button.text = title
			button.set_meta("display_text", title)
		button.set_meta("item", page)
		button.tooltip_text = str(page.get("tooltip", title))
		button.button_pressed = id == active_id
		_update_icon(button, page)
		_update_attention(button, page.get("attention", {}))
		_update_close_visibility(button)
	if plus.get_parent() == row:
		row.move_child(plus, row.get_child_count() - 1)
	if selected_id != active_id and buttons.has(active_id):
		_reveal_selected = active_id
		_ensure_tab_visible.call_deferred(active_id)
	selected_id = active_id
	_fit()


func _add_tab(id: int) -> void:
	var button := Button.new()
	button.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.expand_icon = true
	button.add_theme_constant_override("icon_max_width", 16)
	button.add_theme_constant_override("h_separation", 8)
	button.theme_type_variation = tab_theme_type
	for entry in [
		["normal", "20242c"],
		["hover", "303640"],
		["pressed", "3b4350"],
		["hover_pressed", "424c5b"],
	]:
		if connected_tabs:
			var color := Color(1, 1, 1, 0.07) if entry[0] == "hover" else Color.TRANSPARENT
			var style := _tab_style(color)
			if entry[0] == "hover":
				# Chromium's inactive hover is inset above the toolbar, with
				# rounded lower corners instead of joining the active-tab opening.
				style.set_corner_radius_all(12)
				style.corner_detail = 12
				style.expand_margin_left = -3
				style.expand_margin_right = -3
				style.expand_margin_top = -2
				style.expand_margin_bottom = -6
			button.add_theme_stylebox_override(entry[0], style)
		elif not has_theme_stylebox(entry[0], tab_theme_type):
			button.add_theme_stylebox_override(entry[0], _tab_style(Color(entry[1])))
	if connected_tabs and connected_text_outline:
		# The active label sits over the live world, including bright scenery.
		button.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		button.add_theme_constant_override("outline_size", 2)
	button.item_rect_changed.connect(func(): appearance_changed.emit())
	row.add_child(button)
	button.set_meta("laid_out", false)
	buttons[id] = button
	var close := Button.new()
	close.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_ALWAYS
	close.name = "Close"
	ActionStyle.apply(close, "M4 4l8 8M12 4l-8 8", 12, 24)
	if icon_factory.is_valid():
		close.icon = icon_factory.call("close")
	close.expand_icon = true
	close.focus_mode = Control.FOCUS_NONE
	close.accessibility_name = tr("Close tab")
	close.tooltip_text = close_tooltip
	button.add_child(close)
	close.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT)
	close.offset_left = -28
	close.offset_right = -4
	close.offset_top = -12
	close.offset_bottom = 12
	close.pressed.connect(
		func():
			_request_close(id),
	)
	button.mouse_entered.connect(
		func():
			_update_close_visibility(button, true),
	)
	button.mouse_exited.connect(
		func():
			_update_close_visibility.call_deferred(button),
	)
	close.mouse_entered.connect(
		func():
			_update_close_visibility(button, true),
	)
	close.mouse_exited.connect(
		func():
			_update_close_visibility.call_deferred(button),
	)
	close.gui_input.connect(func(event):
		if close.button_pressed and (event is InputEventMouseMotion or event is InputEventMouseButton):
			if not Rect2(Vector2.ZERO, close.size).has_point(event.position):
				# Clear BaseButton's pending press so returning to the X cannot rearm it.
				close.disabled = true
				close.disabled = false
		if event is InputEventMouseMotion:
			_pointer = button.position + row.position + close.position + event.position
			_update_close_visibility(button, true))
	button.gui_input.connect(
		func(event):
			_tab_input(id, button, event),
	)


func _tab_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(7)
	style.content_margin_left = 10
	style.content_margin_right = 30
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style


func _update_close_visibility(button: Button, pointer_over := false) -> void:
	if not is_instance_valid(button) or button.is_queued_for_deletion() or button.get_meta("closing", false):
		return
	var close: Button = button.get_node("Close")
	var hovered := pointer_over or button.is_hovered() or close.is_hovered()
	# Inactive compact tabs must remain easy to select: hovering must not turn
	# almost their entire hit target into a close button. Middle-click still
	# closes.
	#
	# A collapsed insertion is narrower than any resting tab. Its close hit
	# target must not escape into its neighbour (Chromium UpdateIconVisibility).
	if button.size.x < minimum_tab_width:
		close.visible = false
	elif (
		preload("res://scenes/input/InteractionProfile.gd").touch_controls()
		and button.get_meta("compact", false)
	):
		close.visible = button.button_pressed and button.size.x >= _touch_close_width(str(button.get_meta("display_text", button.text)), button)
	else:
		close.visible = (
			(button.button_pressed and hovered and close.get_rect().has_point(_pointer - button.position - row.position))
			if button.get_meta("close_overlays_title", false)
			else (button.button_pressed or hovered)
		)
	# Remove the ordinal itself while the close icon occupies its place. This
	# also removes its outline, regardless of the theme or button draw state.
	#
	# Touch keeps the number beside the close: a tap on the selected tab must
	# never land on a close that replaced it.
	var covered: bool = button.get_meta("close_overlays_title", false) and close.visible and not preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	button.text = "" if covered else str(button.get_meta("display_text", button.text))
	# Reserve title space for a close button on the selected or hovered tab.
	# A resting inactive tab can use that space for its title.
	#
	# Use selection and pointer state for this decision. This keeps a width
	# change from triggering another refit.
	var reserved := button.button_pressed or hovered
	if reserved != button.get_meta("close_reserved", true):
		button.set_meta("close_reserved", reserved)
		_fit_button(button, button.size.x, button.size.y)


## The narrowest touch tab that shows `text` beside its 24-pixel close
## (inset 4, see `_fit_button`) with room to spare.
const TOUCH_CLOSE_ROOM := 36.0
func _touch_close_width(text: String, measured: Control = self) -> float:
	return measured.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, measured.get_theme_font_size("font_size")).x + TOUCH_CLOSE_ROOM


## Title room the close button takes at this width.
func _close_allowance(button: Button) -> float:
	return 40.0 if button.get_meta("close_reserved", true) else 20.0


func _apply_title_margins(button: Button, overlays_title: bool) -> void:
	var reserved: bool = button.get_meta("close_reserved", true)
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var style: StyleBox = button.get_theme_stylebox(state).duplicate()
		style.content_margin_left = 4 if overlays_title else 10
		var touch_close := overlays_title and reserved and preload("res://scenes/input/InteractionProfile.gd").touch_controls()
		style.content_margin_right = 30 if touch_close else (4 if overlays_title else (30 if reserved else 10))
		button.add_theme_stylebox_override(state, style)
	button.set_meta("margins_reserved", reserved)


func _fit() -> void:
	var inline_plus := plus.get_parent() == row
	# An incoming placeholder takes a slot without resizing tabs: a narrowing
	# strip would slide the tab under a held pointer away from it.
	var count := ids.size() - (1 if _drag_external else 0)
	var slots := count + (1 if external_drop_hint >= 0 else 0)
	var reserved := 36.0 if inline_plus else 0.0
	var minimum := minimum_tab_width
	if compact_tabs:
		# Keep even three/four-digit ordinals readable before falling back to scroll.
		minimum = maxf(
			minimum,
			get_theme_font("font")
			.get_string_size(str(maxi(count, 1)), HORIZONTAL_ALIGNMENT_LEFT, -1, get_theme_font_size(
				"font_size"
			))
			.x
			+ 8,
		)
		# Phones have no hover: the selected tab's close must fit beside its
		# number. Narrower strips scroll instead of hiding the close.
		if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
			minimum = maxf(minimum, _touch_close_width(str(maxi(count, 1))))
	_tab_width = clampf(constrained_width(size.x - reserved) / maxi(1, count) - 3, minimum, maximum_tab_width)
	var height := 32.0
	if connected_tabs:
		height = 34.0
		for button: Button in buttons.values():
			height = maxf(height, button.get_combined_minimum_size().y)
			# Width animation can restore the normal title font. Reserve its
			# height up front so tabs and actions keep the same vertical centre.
			height = maxf(height, ceilf(get_theme_font("font", tab_theme_type).get_height(
				get_theme_font_size("font_size", tab_theme_type)
			)) + button.get_theme_stylebox("normal").get_minimum_size().y)
	row.custom_minimum_size = Vector2(slots * (_tab_width + 3) + (32 if inline_plus else 0), maxf(34, height))
	if inline_plus:
		plus.size = Vector2(32, 32)
		place_plus(Vector2(slots * (_tab_width + 3), 0))
	for i in _visual_order.size():
		var button: Button = buttons[_visual_order[i]]
		var arriving: bool = not button.get_meta("laid_out", false)
		var width := _tab_width
		if _resizing_tabs:
			width = minf(INSERTION_WIDTH, _tab_width) if arriving else button.size.x
		_fit_button(button, width, height)
		if arriving:
			button.set_meta("laid_out", true)
			button.set_meta("opening", _resizing_tabs)
			button.position = Vector2(i * (_tab_width + 3), 0)
			if _resizing_tabs and i > 0:
				var previous: Button = buttons[_visual_order[i - 1]]
				# Chromium subtracts its decorative overlap here. Our slots have
				# a positive gap, so the new tab starts outside the previous tab.
				button.position.x = previous.position.x + previous.size.x + 3
			elif _resizing_tabs and i + 1 < _visual_order.size():
				button.position.x = buttons[_visual_order[i + 1]].position.x
	if incoming_tab != null and external_drop_hint >= 0:
		incoming_tab.text = _incoming_title
		incoming_tab.size = Vector2(_tab_width, height)
	_separate_opening_tabs()
	_settle()
	layout_changed.emit()


## Chromium's mid-animation trailing edge keeps closing tabs inside the viewport.
## This can exceed the preferred width only when surviving tabs are already at
## their maximum, so it does not change their target widths.
func animated_width() -> float:
	var right := 0.0
	for view: Control in buttons.values() + _closing_tabs.keys():
		right = maxf(right, view.get_rect().end.x + 3)
	return right


func _separate_opening_tabs() -> void:
	if _dragging or external_drop_hint >= 0:
		return
	var previous: Button
	var previous_id := -1
	var opening := false
	for id in _visual_order:
		var button: Button = buttons[id]
		if button.get_meta("opening", false):
			opening = true
			# A preceding insertion may be further through its animation. Its
			# visible edge, not a second independent clock, bounds the new tab.
			if previous != null:
				button.position.x = maxf(button.position.x, previous.get_rect().end.x + 3)
			for view: Control in _closing_tabs:
				if _closing_tabs[view] == previous_id:
					button.position.x = maxf(button.position.x, view.get_rect().end.x + 3)
		previous = button
		previous_id = int(id)
	if (opening or not _closing_tabs.is_empty()) and previous != null:
		# Keep the plus hit target outside growing and closing tabs. With
		# overflow, only the part visible through the scroll viewport matters.
		var right := animated_width() - 3
		if plus.get_parent() != row:
			right = minf(right, scroll_horizontal + size.x)
		var edge := row.get_global_transform() * Vector2(right + 3, 0)
		edge = plus.get_parent().get_global_transform().affine_inverse() * edge
		plus.position.x = maxf(plus.position.x, edge.x)


func _fit_button(button: Button, width: float, height: float) -> void:
	if title_formatter.is_valid():
		var formatted: Variant = title_formatter.call(button.get_meta("item"), width - _close_allowance(button))
		if formatted is Dictionary:
			button.text = str(formatted.text)
			if button.get_theme_font_size("font_size") != int(formatted.font_size):
				button.add_theme_font_size_override("font_size", int(formatted.font_size))
		else:
			button.text = str(formatted)
	button.set_meta("display_text", button.text)
	var compact := (
		compact_tabs and button.text == str(button.get_meta("item").get("ordinal", ""))
	)
	var text_width := button.get_theme_font("font").get_string_size(
		button.text, HORIZONTAL_ALIGNMENT_LEFT, -1, button.get_theme_font_size("font_size")
	).x
	var overlays_title := compact and text_width + 40 > width
	var mode_changed: bool = (
		compact_tabs
		and (not button.has_meta("compact") or button.get_meta("compact") != compact
			or button.get_meta("close_overlays_title", false) != overlays_title)
	)
	if mode_changed or button.get_meta("margins_reserved", true) != button.get_meta("close_reserved", true):
		_apply_title_margins(button, overlays_title)
	if mode_changed:
		button.set_meta("compact", compact)
		button.set_meta("close_overlays_title", overlays_title)
		button.alignment = HORIZONTAL_ALIGNMENT_CENTER if compact else HORIZONTAL_ALIGNMENT_LEFT
		button.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING if compact else TextServer.OVERRUN_TRIM_ELLIPSIS
		var close: Button = button.get_node("Close")
		var centered_close := (
			overlays_title
			and not preload("res://scenes/input/InteractionProfile.gd").touch_controls()
		)
		# A compact close covers the ordinal while hovered. Its resting
		# surface matches the selected tab; the hover remains circular.
		var background := Color.TRANSPARENT
		var selected_style := button.get_theme_stylebox("pressed")
		if centered_close and selected_style is StyleBoxFlat:
			background = selected_style.bg_color
		ActionStyle.apply(close, "M4 4l8 8M12 4l-8 8", 12, 24, background)
		if icon_factory.is_valid():
			close.icon = icon_factory.call("close")
		close.set_anchors_and_offsets_preset(
			Control.PRESET_CENTER if centered_close else Control.PRESET_CENTER_RIGHT
		)
		close.offset_left = -12 if centered_close else -28
		close.offset_right = 12 if centered_close else -4
		close.offset_top = -12
		close.offset_bottom = 12
	button.custom_minimum_size = Vector2(0, height)
	button.size = Vector2(width, height)
	_update_close_visibility(button)

## Agent outcome dot in the tab's top-right corner. It ignores the pointer so
## selection and close targets are unchanged, and it never affects layout.
func _update_attention(button: Button, attention: Dictionary) -> void:
	var state := str(attention.get("state", ""))
	var dot: Control = button.get_node_or_null("Attention")
	if state.is_empty():
		if dot != null: dot.hide()
		return
	if dot == null:
		dot = AttentionDot.new()
		dot.name = "Attention"
		button.add_child(dot)
	dot.present(state, int(attention.get("count", 1)))
	dot.show()


func _update_icon(button: Button, item: Dictionary) -> void:
	button.icon = item.get("icon", null)


func _input(event: InputEvent) -> void:
	if _closing_available >= 0.0 and not _closing_touch and event is InputEventMouse:
		var point: Vector2 = get_global_transform_with_canvas().affine_inverse() * event.position
		var region := Rect2(Vector2.ZERO, size + Vector2(60, 40))
		if region.has_point(point):
			_close_exit_timer.stop()
		elif event is InputEventMouseButton and event.pressed:
			_exit_closing_mode()
		else:
			_schedule_close_exit()
	if _dragging and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_drag()
		get_viewport().set_input_as_handled()


func constrained_width(available: float) -> float:
	return minf(available, _closing_available) if _closing_available >= 0.0 else available


func _request_close(id: int) -> void:
	if _closing_available < 0.0:
		_closing_available = ids.size() * (_tab_width + 3.0)
	_closing_touch = preload("res://scenes/input/InteractionProfile.gd").touch_controls()
	_close_exit_timer.stop()
	if _closing_touch: _close_exit_timer.start(2.0)
	closed.emit(id)


func _schedule_close_exit() -> void:
	if _closing_available >= 0.0 and not _closing_touch and _close_exit_timer.is_stopped():
		_close_exit_timer.start(0.3)


func _clear_closing_mode() -> void:
	_closing_available = -1.0
	_close_exit_timer.stop()


func _exit_closing_mode() -> void:
	if _closing_available < 0.0: return
	_clear_closing_mode()
	_resizing_tabs = true
	_fit()


func _settle() -> void:
	_settling = true
	set_process(true)


func place_plus(at: Vector2) -> void:
	plus.position.y = at.y
	if _resizing_tabs and plus.get_meta("laid_out", false):
		_animate_to(plus, Rect2(at, plus.size))
	else:
		_bounds_animations.erase(plus)
		plus.position = at
	plus.set_meta("laid_out", true)


func _animate_to(control: Control, target: Rect2) -> void:
	if is_inside_tree() and (not is_visible_in_tree() or not get_window().visible):
		_bounds_animations.erase(control)
		control.position = target.position
		if control is Button and control != plus and control != incoming_tab:
			_fit_button(control, target.size.x, target.size.y)
		else:
			control.size = target.size
		return
	if _bounds_animations.has(control) and _bounds_animations[control].target.is_equal_approx(target):
		return
	var current := Rect2(control.position, control.size)
	if current.is_equal_approx(target):
		_bounds_animations.erase(control)
		return
	_bounds_animations[control] = BoundsAnimation.new(current, target)
	_settle()


func _tab_input(id: int, button: Button, event: InputEvent) -> void:
	# Selection and dragging use the mouse route, including Android's touch
	# emulation. The following original touch must not toggle the button again.
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		button.accept_event()
		return
	# Buttons stop GUI propagation; scrolling over a tab must still reach the strip.
	if (
		event is InputEventPanGesture
		or (
			event is InputEventMouseButton
			and event.button_index
			in [
				MOUSE_BUTTON_WHEEL_UP,
				MOUSE_BUTTON_WHEEL_DOWN,
				MOUSE_BUTTON_WHEEL_LEFT,
				MOUSE_BUTTON_WHEEL_RIGHT,
			]
		)
	):
		_gui_input(event)
		return
	if event is InputEventMouse:
		_pointer = button.position + row.position + event.position
		if event is InputEventMouseMotion:
			_update_close_visibility(button, true)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			context_requested.emit(id)
			button.accept_event()
		elif event.button_index == MOUSE_BUTTON_MIDDLE and event.pressed:
			_request_close(id)
			button.accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_pressed_id = id
				_press_was_selected = id == selected_id
				_press_point = _pointer
				_grab_offset = event.position.x
				selected.emit(id)
			else:
				if _dragging and external_drop.is_valid() and external_drop.call():
					button.accept_event()
					return
				var was_clicked := _pressed_id == id and not _dragging and Rect2(Vector2.ZERO, button.size).has_point(event.position)
				var was_selected := _press_was_selected
				commit_drag()
				if was_clicked:
					clicked.emit(id, was_selected)
			button.accept_event()
	elif event is InputEventMouseMotion and _pressed_id == id:
		if not _dragging and not (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			# The release went elsewhere, as when the window lost focus between
			# press and release. A pointer passing over later drags nothing.
			_pressed_id = -1
			return
		if not _dragging and _pointer.distance_to(_press_point) > 6:
			_dragging = true
			_sync_reorder_appearance()
			_drop_index = ids.find(id)
			hover_id = -1
			button.z_index = 5
			_pending_order.clear()
			_commit_timer.stop()
			set_process(true)
			drag_started.emit(id)
		if _dragging:
			# Resolve the slot first so the owner sees this pointer's hover target.
			_update_drop()
			if external_motion.is_valid():
				external_motion.call(ScreenSpace.of(self, _pointer))
			button.accept_event()


func commit_drag() -> void:
	if _dragging and _drop_index >= 0:
		_pending_order = _visual_order.duplicate()
		_commit_timer.start()
		moved.emit(_pressed_id, _drop_index)
		if buttons.has(_pressed_id):
			buttons[_pressed_id].z_index = 0
		_dragging = false
		_sync_reorder_appearance()
		_pressed_id = -1
		_drop_index = -1
		hover_id = -1
		_settle()
		queue_redraw()
	else:
		_cancel_drag()
	reconcile(_pending_pages, _pending_active_id)


## Where a pointer at content x places a dragged tab among `others`, whose
## slot is currently at `gap` (-1 while it has none).
##
## The middle half of a tab targets that tab without moving it, so holding
## there can open it. The outer quarters move the slot past it.
##
## Results are measured against where tabs settle, not where they are
## mid-slide, so the slot never chases the pointer.
func _placement(x: float, others: Array, gap: int) -> Dictionary:
	var slot := _tab_width + 3
	var visual := floori(x / slot)
	if visual < 0:
		return { "index": 0, "hover": -1 }
	if gap >= 0 and visual == gap:
		return { "index": gap, "hover": -1 }
	var i := visual if gap < 0 or visual < gap else visual - 1
	if i >= others.size():
		return { "index": others.size(), "hover": -1 }
	var within := (x - visual * slot) / _tab_width
	if within < 0.25:
		return { "index": i, "hover": -1 }
	if within > 0.75:
		return { "index": i + 1, "hover": -1 }
	return { "index": i + 1 if gap < 0 or i < gap else i, "hover": int(others[i]) }


func _update_drop() -> void:
	if _drag_external or window_drag:
		return
	# The grabbed point stays directly under the pointer, with no easing/lag.
	var x := _pointer.x - row.position.x
	buttons[_pressed_id].position = Vector2(x - _grab_offset, 0)
	var others := ids.duplicate()
	others.erase(_pressed_id)
	var place := _placement(x, others, _drop_index)
	_drop_index = place.index
	hover_id = place.hover if _pointer.y >= 0 and _pointer.y <= size.y else -1
	_visual_order = others
	_visual_order.insert(_drop_index, _pressed_id)
	_settle()
	queue_redraw()


func _process(dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(dt)
	preload("res://graffitty/frame_profile.gd").add("TabStrip", Time.get_ticks_usec() - profiled_started)


func _process_body(dt: float) -> void:
	if _dragging and not _drag_external and not window_drag:
		var direction := -1 if _pointer.x < 32 else (1 if _pointer.x > size.x - 32 else 0)
		if direction:
			scroll_horizontal += int(direction * 500 * dt)
		_update_drop()
	for i in _visual_order.size():
		var id: int = _visual_order[i]
		if _dragging and id == _pressed_id:
			_bounds_animations.erase(buttons[id])
			continue
		var button: Button = buttons[id]
		var slot := i + (1 if external_drop_hint >= 0 and i >= external_drop_hint else 0)
		_animate_to(button, Rect2(Vector2(slot * (_tab_width + 3), 0), Vector2(_tab_width, button.size.y)))
	for view: Control in _closing_tabs:
		var predecessor := _visual_order.find(_closing_tabs[view])
		var x := (predecessor + 1) * (_tab_width + 3)
		_animate_to(view, Rect2(Vector2(x, 0), Vector2(0, view.size.y)))
	if incoming_tab != null and external_drop_hint >= 0:
		_animate_to(incoming_tab, Rect2(Vector2(external_drop_hint * (_tab_width + 3), 0), incoming_tab.size))
	for control: Control in _bounds_animations.keys():
		var animation := _bounds_animations[control]
		# A server update can create a tab late in a slow frame. That frame's
		# elapsed time predates the animation; render its start before advancing.
		if animation.started:
			animation.elapsed = minf(BOUNDS_DURATION, animation.elapsed + dt)
		animation.started = true
		var progress := animation.elapsed / BOUNDS_DURATION
		var weight := 1.0 - (1.0 - progress) * (1.0 - progress)
		var rect := Rect2(animation.start.position.lerp(animation.target.position, weight), animation.start.size.lerp(animation.target.size, weight))
		if control is Button and control != plus and control != incoming_tab:
			_fit_button(control, rect.size.x, rect.size.y)
		else:
			control.size = rect.size
			if _closing_tabs.has(control):
				var tab: Button = control.get_child(0)
				if rect.size.x < minimum_tab_width:
					tab.icon = null
				tab.size = rect.size
		control.position = rect.position
		if progress >= 1.0:
			_bounds_animations.erase(control)
	_separate_opening_tabs()
	for button: Button in buttons.values():
		if not _bounds_animations.has(button):
			button.remove_meta("opening")
	for view: Control in _closing_tabs.keys():
		if not _bounds_animations.has(view):
			_closing_tabs.erase(view)
			row.remove_child(view)
			view.queue_free()
	if _resizing_tabs:
		layout_changed.emit()
	_settling = not _bounds_animations.is_empty()
	if _hover_hint >= 0:
		_hover_overlay.queue_redraw()
	if not _dragging and not _settling:
		_resizing_tabs = false
		# Newly inserted tabs can still be sliding and resizing when the first
		# reveal runs. Reveal once more at their final slot and scroll extent.
		if _reveal_selected >= 0:
			_ensure_tab_visible.call_deferred(_reveal_selected)
			_reveal_selected = -1
		set_process(false)
	# The strip itself draws only the external drop line, whose position follows
	# scrolling; hint changes redraw from set_external_drop_hint().
	if external_drop_hint >= 0:
		queue_redraw()


func set_drag_external(value: bool) -> void:
	if _drag_external == value:
		return
	_drag_external = value
	_sync_reorder_appearance()
	if buttons.has(_pressed_id):
		buttons[_pressed_id].modulate.a = 0.0 if value else 1.0
	_visual_order = ids.duplicate()
	if value:
		_visual_order.erase(_pressed_id)
		# Coming back re-opens the slot where the pointer arrives.
		_drop_index = -1
		hover_id = -1
	_fit()
	if not value and _dragging:
		_update_drop()


func set_drag_pointer(screen_position: Vector2) -> void:
	_pointer = ScreenSpace.into(self, screen_position)
	if _dragging and not _drag_external:
		_update_drop()


## Insertion index and hovered tab for a drag arriving from elsewhere, using
## the same stable zones as reordering. Only a pointer inside the strip hovers.
func incoming_placement(screen_position: Vector2) -> Dictionary:
	var point := ScreenSpace.into(self, screen_position)
	var place := _placement(point.x + scroll_horizontal, ids, external_drop_hint)
	if point.y < 0 or point.y > size.y:
		place.hover = -1
	return place


## Outlines a tab a drag is resting on; the bar fills until it opens.
func set_hover_hint(id: int, progress := 0.0) -> void:
	if _hover_hint == id and is_equal_approx(_hover_progress, progress):
		return
	_hover_hint = id
	_hover_progress = clampf(progress, 0.0, 1.0)
	_hover_overlay.queue_redraw()


func _draw_hover() -> void:
	# Sliding neighbours already show a local reorder's destination. Keep the
	# translucent dragged tab free of target outlines and progress bars.
	if _dragging and not _drag_external:
		return
	if not buttons.has(_hover_hint):
		return
	var button: Button = buttons[_hover_hint]
	var rect := Rect2(button.position, button.size).grow(-1)
	var accent := Color("8caee8")
	_hover_overlay.draw_rect(rect, accent, false, 2.0)
	_hover_overlay.draw_rect(
		Rect2(
			rect.position + Vector2(6, rect.size.y - 5),
			Vector2((rect.size.x - 12) * _hover_progress, 3),
		),
		accent,
	)


func _sync_reorder_appearance() -> void:
	# Native button hover can move to a neighbour beneath the grabbed tab.
	# Its tint would show through the selected tab's transparent world opening.
	if connected_tabs and _dragging and not _drag_external:
		for button: Button in buttons.values():
			if not _reorder_hover_styles.has(button):
				_reorder_hover_styles[button] = button.get_theme_stylebox("hover")
				button.add_theme_stylebox_override("hover", button.get_theme_stylebox("normal"))
	else:
		for button in _reorder_hover_styles:
			if is_instance_valid(button):
				button.add_theme_stylebox_override("hover", _reorder_hover_styles[button])
		_reorder_hover_styles.clear()
	_hover_overlay.queue_redraw()


func set_external_drop_hint(index: int, title := "") -> void:
	if external_drop_hint == index and _incoming_title == title:
		return
	var arriving := external_drop_hint < 0 and index >= 0
	external_drop_hint = index
	_incoming_title = title
	if index >= 0:
		if incoming_tab == null:
			incoming_tab = Button.new()
			incoming_tab.name = "IncomingTab"
			incoming_tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
			incoming_tab.focus_mode = Control.FOCUS_NONE
			incoming_tab.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
			incoming_tab.clip_text = true
			incoming_tab.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			incoming_tab.alignment = HORIZONTAL_ALIGNMENT_LEFT
			incoming_tab.theme_type_variation = tab_theme_type
			var style := _tab_style(Color("3b4350"))
			style.border_color = Color("8caee8")
			style.set_border_width_all(1)
			incoming_tab.add_theme_stylebox_override("normal", style)
			incoming_tab.z_index = 4
			row.add_child(incoming_tab)
		incoming_tab.show()
	elif incoming_tab != null:
		incoming_tab.hide()
	_fit()
	if arriving:
		incoming_tab.position = Vector2(index * (_tab_width + 3), 0)
	queue_redraw()


func _draw() -> void:
	var profiled_started := Time.get_ticks_usec()
	_draw_body()
	preload("res://graffitty/frame_profile.gd").add("TabStrip._draw", Time.get_ticks_usec() - profiled_started)


func _draw_body() -> void:
	if external_drop_hint >= 0:
		var x := clampf(external_drop_hint * (_tab_width + 3) - scroll_horizontal, 2, size.x - 2)
		draw_line(Vector2(x, 2), Vector2(x, 32), Color("8caee8"), 3)


func _cancel_drag() -> void:
	window_drag = false
	set_drag_external(false)
	if buttons.has(_pressed_id):
		buttons[_pressed_id].z_index = 0
	_pressed_id = -1
	_dragging = false
	_sync_reorder_appearance()
	_drop_index = -1
	hover_id = -1
	_pending_order.clear()
	_commit_timer.stop()
	_visual_order = ids.duplicate()
	_settle()
	queue_redraw()


func _ensure_tab_visible(id: int) -> void:
	if buttons.has(id) and is_ancestor_of(buttons[id]):
		ensure_control_visible(buttons[id])


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index in [
			MOUSE_BUTTON_WHEEL_UP,
			MOUSE_BUTTON_WHEEL_DOWN,
			MOUSE_BUTTON_WHEEL_LEFT,
			MOUSE_BUTTON_WHEEL_RIGHT,
		]:
			var direction := (
				-1
				if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT]
				else 1
			)
			if elastic.is_active(): stop_scrolling()
			scroll_horizontal += roundi(direction * 64.0 * event.factor)
			accept_event()
	elif event is InputEventPanGesture:
		# Trackpads move the strip by the distance swiped, either direction,
		# and stretch it at either end.
		elastic_pan(event)
		accept_event()
