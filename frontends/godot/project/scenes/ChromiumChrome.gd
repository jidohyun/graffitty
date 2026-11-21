extends VBoxContainer
const DesktopText := preload("res://scenes/DesktopText.gd")
signal close_session_requested
## Reusable default chrome; ChromiumSession owns all page state and commands.
var session: Node
## Find in page: 0 opens the find bar, 1 goes to the next match, -1 the previous.
signal find_requested(direction: int)
var tabs := preload("res://scenes/ChromiumTabStrip.gd").new()
var tab_frame := PanelContainer.new()
var tab_holder := Control.new()
var navigation := preload("res://scenes/TabStripNavigation.gd").new()
var address := LineEdit.new()
var info := Label.new()
var back: Button
var forward: Button
var reload: Button
var info_button: Button
var native_button: Button
var _signature := ""
var _icons: Dictionary = { }
var _loading := false
var _revision := -1
var visual_revision := 0
var _new_tab_from := -1
var _new_tab_ids: Array = []
var _new_tab_started := 0
var _queued_url := ""
var _notice := ""
## Address-bar history suggestions, ranked by Chrome's omnibox on the server.
const HISTORY_LIMIT := 8
var suggestions := ItemList.new()
# Zero-height layout slot: the list floats below the bar over the page
# instead of resizing the chrome.
var _suggestion_anchor := Control.new()
var _history_timer := Timer.new()
var _history_sequence := 0
var _suggestion_urls := PackedStringArray()


func icon(kind: String) -> Texture2D:
	if _icons.has(kind):
		return _icons[kind]
	var paths := {
		"plus": '<path d="M8 3v10M3 8h10"/>',
		"close": '<path d="m4 4 8 8m0-8-8 8"/>',
		"back": '<path d="m9 3-5 5 5 5M4 8h9"/>',
		"forward": '<path d="m7 3 5 5-5 5M12 8H3"/>',
		"reload": '<path d="M13 6a5 5 0 1 0 0 4M13 2v4H9"/>',
		"external": '<path d="M9 2h5v5M14 2 7 9M6 3H3v10h10v-3"/>',
		"info": '<circle cx="8" cy="8" r="6"/><path d="M8 7v5M8 4v1"/>',
		"globe": '<circle cx="8" cy="8" r="6"/><ellipse cx="8" cy="8" rx="2.5" ry="6"/><path d="M2 8h12"/>',
	}
	var image := Image.new()
	image.load_svg_from_string(
		'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><g fill="none" stroke="#d9e1ef" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">%s</g></svg>'
		% paths.get(kind, paths.globe),
		2.0,
	)
	_icons[kind] = ImageTexture.create_from_image(image)
	return _icons[kind]


func _style(color: Color, radius := 8, border := Color.TRANSPARENT) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.corner_detail = 16
	style.anti_aliasing = true
	style.set_content_margin_all(6)
	# A transparent one-pixel border creates a second, nearly coincident AA
	# contour. On the HDR pane canvas it leaves bright flecks around the curve.
	# Borderless controls need a single filled contour, not an invisible stroke.
	style.border_color = border if border.a > 0.0 else color
	style.set_border_width_all(1 if border.a > 0.0 else 0)
	return style


func _ready() -> void:
	if theme == null:
		theme = Theme.new()
		theme.default_font_size = DesktopText.size(13)
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			theme.set_stylebox(
				state,
				"Button",
				_style(Color("303742") if state in ["hover", "pressed"] else Color("20242c")),
			)
		theme.set_constant("icon_max_width", "Button", 16)
		theme.set_color("font_color", "Button", Color("d9e1ef"))
		theme.set_color("icon_disabled_color", "Button", Color(1, 1, 1, 0.25))
		theme.set_stylebox("normal", "LineEdit", _style(Color("161b23"), 14))
		theme.set_stylebox("focus", "LineEdit", _style(Color("1b2331"), 14, Color("88afff")))
		theme.set_color("font_color", "LineEdit", Color("e1e7f2"))
	add_theme_constant_override("separation", 0)
	tabs.icon_factory = icon
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color.WHITE
	frame_style.content_margin_left = 8
	frame_style.content_margin_right = 8
	frame_style.content_margin_top = 8
	frame_style.content_margin_bottom = 0
	tab_frame.add_theme_stylebox_override("panel", frame_style)
	tab_frame.material = preload("res://scenes/TabFrameStyle.gd").create_material()
	add_child(tab_frame)
	tab_frame.add_child(tab_holder)
	tab_holder.add_child(tabs)
	# The new-tab action is outside the clipped, scrollable tab row.
	# Otherwise enough minimum-width tabs push it beyond the viewport.
	if tabs.plus.get_parent() != null: tabs.plus.reparent(tab_holder)
	else: tab_holder.add_child(tabs.plus)
	add_child(navigation)
	navigation.configure(tab_holder, tabs, _populate_tab_menu)
	navigation.menu.tab_selected.connect(func(id): _command("tab-select", id))
	tab_holder.resized.connect(_layout_tabs)
	tabs.layout_changed.connect(_layout_tabs)
	_layout_tabs.call_deferred()
	tab_frame.resized.connect(_sync_tab_frame)
	tabs.layout_changed.connect(_sync_tab_frame)
	tabs.appearance_changed.connect(_sync_tab_frame)
	tabs.row.item_rect_changed.connect(_sync_tab_frame)
	tabs.get_h_scroll_bar().value_changed.connect(func(_value): _sync_tab_frame())
	_sync_tab_frame.call_deferred()
	tabs.selected.connect(
		func(id):
			_command("tab-select", id),
	)
	tabs.closed.connect(_close_tab)
	tabs.moved.connect(
		func(id, index):
			if is_instance_valid(session):
				session.command("tab-move", { "chromium_id": id, "index": index })
				session.command("chrome-state"),
	)
	tabs.new_tab.connect(_new_tab)
	var navigation_margin := MarginContainer.new()
	navigation_margin.add_theme_constant_override("margin_left", 8)
	navigation_margin.add_theme_constant_override("margin_right", 8)
	navigation_margin.add_theme_constant_override("margin_top", 4)
	navigation_margin.add_theme_constant_override("margin_bottom", 4)
	add_child(navigation_margin)
	var navigation := HBoxContainer.new()
	navigation.add_theme_constant_override("separation", 4)
	navigation_margin.add_child(navigation)
	back = _button(
		navigation,
		"back",
		"Back",
		func():
			_command("tab-back", session.selected_page_id),
	)
	forward = _button(
		navigation,
		"forward",
		"Forward",
		func():
			_command("tab-forward", session.selected_page_id),
	)
	reload = _button(
		navigation,
		"reload",
		"Reload",
		func():
			_command("tab-stop" if _loading else "tab-reload", session.selected_page_id),
	)
	address.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	address.custom_minimum_size = Vector2(100, 32)
	address.placeholder_text = "Enter URL"
	address.text_submitted.connect(_navigate)
	navigation.add_child(address)
	native_button = _button(
		navigation,
		"external",
		"Open all tabs in Chrome",
		func():
			if is_instance_valid(session):
				session.open_native(),
	)
	native_button.visible = false
	info_button = _button(
		navigation,
		"info",
		"Session information · sandbox disabled",
		func():
			info.visible = not info.visible
			visual_revision += 1,
	)
	info.add_theme_font_size_override("font_size", DesktopText.size(11))
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.visible = false
	add_child(info)
	_suggestion_anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_suggestion_anchor)
	suggestions.visible = false
	# The address bar keeps the keyboard while a pointer picks a suggestion.
	suggestions.focus_mode = Control.FOCUS_NONE
	suggestions.auto_height = true
	suggestions.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	suggestions.add_theme_stylebox_override("panel", _style(Color("1b2331"), 10, Color("3b4350")))
	suggestions.add_theme_color_override("font_color", Color("e1e7f2"))
	suggestions.item_clicked.connect(
		func(index, _position, button):
			if button == MOUSE_BUTTON_LEFT:
				_accept_suggestion(index),
	)
	_suggestion_anchor.add_child(suggestions)
	_history_timer.one_shot = true
	_history_timer.wait_time = 0.08
	_history_timer.timeout.connect(_query_history)
	add_child(_history_timer)
	address.text_changed.connect(func(_text): _history_timer.start())
	address.gui_input.connect(_address_input)
	address.focus_exited.connect(_hide_suggestions)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("3b4350"))


func presentation_copy() -> Control:
	# Keep native controls, their text and layout, without session callbacks.
	var copy: Control = duplicate(0)
	var background := preload("res://scenes/GraphWireLayer.gd").new()
	background.frozen = true
	background.commands = [[&"draw_rect", [Rect2(Vector2.ZERO, size), Color("3b4350")]]]
	copy.add_child(background)
	copy.move_child(background, 0)
	background.show_behind_parent = true
	return copy


func _layout_tabs() -> void:
	navigation.layout(0.0, 0.0, 0.0)

func _populate_tab_menu() -> void:
	var items: Array = []
	if is_instance_valid(session):
		for page in session.page_tabs:
			items.append(page.merged({"show_details": false}, true))
	navigation.menu.populate(items, tabs.selected_id, tabs, Color("20242c"))


func _sync_tab_frame() -> void:
	preload("res://scenes/TabFrameStyle.gd").update(tab_frame, tabs, Color("20242c"))


func _button(parent: Node, kind: String, hint: String, action: Callable) -> Button:
	var button := Button.new()
	button.icon = icon(kind)
	button.expand_icon = true
	preload("res://scenes/TabActionStyle.gd").apply_surface(button, 16, 32)
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.accessibility_name = tr(hint)
	if kind not in ["back", "forward", "reload"]:
		button.tooltip_text = hint
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _new_tab() -> void:
	if is_instance_valid(session):
		_new_tab_from = session.selected_page_id
		_new_tab_ids = session.page_tabs.map(
			func(page):
				return int(page.id),
		)
		_new_tab_started = Time.get_ticks_msec()
		_notice = ""
		session.command("tab-new")
		session.command("chrome-state")
		address.grab_focus()
		address.clear()


func _close_tab(id: int) -> void:
	if not is_instance_valid(session):
		return
	if session.page_tabs.size() > 1:
		_command("tab-close", id)
	else:
		close_session_requested.emit()


func _command(action: String, id: int) -> void:
	if not is_instance_valid(session):
		return
	session.command(action, { "chromium_id": id })
	session.command("chrome-state")


func handle_shortcut(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if event.keycode == KEY_ESCAPE and tabs._dragging:
		tabs._cancel_drag()
		return true
	if event.keycode == KEY_ESCAPE and suggestions.visible:
		_hide_suggestions()
		return true
	if event.keycode == KEY_ESCAPE and address.has_focus():
		address.release_focus()
		_signature = ""
		return true
	if not is_instance_valid(session):
		return false
	var mac := OS.get_name() == "macOS"
	# Back/forward: Cmd+[ / Cmd+] on macOS, Alt+Left / Alt+Right elsewhere.
	if not mac and event.alt_pressed and not event.ctrl_pressed and not event.shift_pressed and event.keycode in [KEY_LEFT, KEY_RIGHT]:
		_command("tab-back" if event.keycode == KEY_LEFT else "tab-forward", session.selected_page_id)
		return true
	if event.keycode == KEY_F5 and not event.is_command_or_control_pressed() and not event.alt_pressed:
		_command("tab-reload", session.selected_page_id)
		return true
	if event.keycode == KEY_F3 and not event.is_command_or_control_pressed() and not event.alt_pressed:
		find_requested.emit(1 if not event.shift_pressed else -1)
		return true
	if not event.is_command_or_control_pressed() or event.alt_pressed:
		return false
	match event.keycode:
		KEY_L:
			address.grab_focus()
			address.select_all()
		KEY_T:
			_new_tab()
		KEY_W:
			_close_tab(session.selected_page_id)
		KEY_R:
			_command("tab-reload", session.selected_page_id)
		KEY_BRACKETLEFT when mac:
			_command("tab-back", session.selected_page_id)
		KEY_BRACKETRIGHT when mac:
			_command("tab-forward", session.selected_page_id)
		KEY_F when not event.shift_pressed:
			find_requested.emit(0)
		KEY_G:
			find_requested.emit(-1 if event.shift_pressed else 1)
		_:
			return false
	return true


func _navigate(text: String) -> void:
	if not is_instance_valid(session):
		return
	# Enter immediately after Cmd+T must never navigate the previous page.
	if _new_tab_from >= 0 and session.selected_page_id in _new_tab_ids:
		_queued_url = text
		return
	if text.strip_edges().is_empty():
		return
	_notice = ""
	_hide_suggestions()
	address.release_focus()
	# Chrome's own omnibox resolves the text: a URL, or a search with the
	# profile's default engine. The server rejects non-http(s) results.
	var target := session
	var result: Dictionary = await target.request("tab-navigate", { "chromium_id": target.selected_page_id, "text": text })
	if target != session:
		return
	if result.has("error"):
		var error: Variant = result.error
		_notice = str(error.get("message", "Chromium could not open the address")) if error is Dictionary else str(error)
		info.show()
	session.command("chrome-state")


## Suggestions belong to the address bar while the user edits it.
func _editing() -> bool:
	return address.has_focus()


func _query_history() -> void:
	_history_sequence += 1
	var sequence := _history_sequence
	if not is_instance_valid(session) or not _editing() or address.text.strip_edges().is_empty():
		_show_suggestions([])
		return
	var target := session
	var result: Dictionary = await target.request("history-query", { "text": address.text, "limit": HISTORY_LIMIT }, 3000)
	# Typing on, switching sessions or leaving the bar makes this answer stale.
	if sequence != _history_sequence or target != session or not _editing():
		return
	var reply: Variant = result.get("result")
	var matches: Variant = reply.get("matches") if reply is Dictionary else null
	_show_suggestions(matches if matches is Array else [])


func _show_suggestions(matches: Array) -> void:
	suggestions.clear()
	_suggestion_urls.clear()
	for entry in matches:
		if not entry is Dictionary or not entry.get("url") is String:
			continue
		var url: String = entry.url
		var title := str(entry.get("title", "")).strip_edges()
		var index := suggestions.add_item(url if title.is_empty() else "%s — %s" % [title, url], icon("globe"))
		suggestions.set_item_tooltip(index, url)
		_suggestion_urls.append(url)
	var shown := not _suggestion_urls.is_empty()
	if shown:
		_place_suggestions()
	if suggestions.visible != shown or shown:
		suggestions.visible = shown
		visual_revision += 1


func _place_suggestions() -> void:
	# Below the address field, in the anchor's coordinates under any canvas zoom.
	var local := _suggestion_anchor.get_global_transform().affine_inverse() * address.get_global_transform()
	suggestions.position = local.origin + Vector2(0, address.size.y + 2)
	suggestions.size = Vector2(address.size.x, 0)
	suggestions.reset_size()
	suggestions.size.x = address.size.x


func _hide_suggestions() -> void:
	_history_sequence += 1
	_history_timer.stop()
	if suggestions.visible:
		suggestions.hide()
		visual_revision += 1


func _address_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if not suggestions.visible or key == null or not key.pressed:
		return
	var selected := suggestions.get_selected_items()
	var current: int = selected[0] if not selected.is_empty() else -1
	var count := suggestions.item_count
	match key.keycode:
		KEY_DOWN, KEY_UP:
			var step: int = 1 if key.keycode == KEY_DOWN else -1
			var next: int = posmod(current + step, count) if current >= 0 else (0 if step > 0 else count - 1)
			suggestions.select(next)
			suggestions.ensure_current_is_visible()
			visual_revision += 1
		KEY_ENTER, KEY_KP_ENTER when current >= 0:
			_accept_suggestion(current)
		_:
			return
	address.accept_event()


func _accept_suggestion(index: int) -> void:
	if index < 0 or index >= _suggestion_urls.size():
		return
	var url := _suggestion_urls[index]
	address.text = url
	_navigate(url)


func refresh(next: Node) -> void:
	if session != next:
		_hide_suggestions()
		address.release_focus()
		tabs._cancel_drag()
		_signature = ""
		_revision = -1
		_new_tab_from = -1
		_new_tab_ids = []
		_queued_url = ""
		_notice = ""
	session = next
	_native_wanted = is_instance_valid(session) and session.can_open_native()
	var show_native: bool = _native_wanted and not _fitted_out.has(native_button)
	if native_button.visible != show_native:
		native_button.visible = show_native
		visual_revision += 1
		_fit_navigation()
	if not is_instance_valid(session):
		return
	if _new_tab_from >= 0 and not session.selected_page_id in _new_tab_ids:
		_new_tab_from = -1
		if not _queued_url.is_empty():
			var url := _queued_url
			_queued_url = ""
			_navigate(url)
	elif _new_tab_from >= 0 and Time.get_ticks_msec() - _new_tab_started > 10000:
		_new_tab_from = -1
		_queued_url = ""
		_notice = "New tab did not become ready. Please try again."
		info.show()
	var signature := _signature
	if not "chrome_revision" in session or _revision != session.chrome_revision:
		if "chrome_revision" in session:
			_revision = session.chrome_revision
		signature = JSON.stringify(
			[session.page_tabs, session.selected_page_id, session.native_visible]
		)
	if signature != _signature:
		_signature = signature
		visual_revision += 1
		tabs.reconcile(session.page_tabs, session.selected_page_id)
		if navigation.menu.visible: _populate_tab_menu()
		for page in session.page_tabs:
			if int(page.id) != session.selected_page_id:
				continue
			_loading = page.get("loading", false)
			back.disabled = not page.get("can_go_back", false)
			forward.disabled = not page.get("can_go_forward", false)
			reload.icon = icon("close" if _loading else "reload")
			reload.accessibility_name = tr("Stop loading" if _loading else "Reload")
	for page in session.page_tabs:
		if (
			int(page.id) == session.selected_page_id
			and not address.has_focus() and address.text != str(page.url)
		):
			address.text = str(page.url)
	info.text = tr("%s · session %d · agent tab %d") % [
		tr("Native window open" if session.native_visible else "Embedded"),
		session.session_id,
		session.primary_page_id,
	]
	if session.chromium_ready and not session.sandbox_enabled:
		info.text += " · " + tr("sandbox disabled")
	info_button.tooltip_text = info.text
	if not _notice.is_empty():
		info.text = _notice
	if not session.failure_reason.is_empty():
		info.text = session.failure_reason
		info_button.tooltip_text = info.text
		if not info.visible:
			info.show()
			visual_revision += 1

## Whether this session offers opening its tabs in a native browser window.
var _native_wanted := false
## Navigation buttons that left because the pane is narrower than the toolbar.
var _fitted_out := {}


## A pane narrower than the whole toolbar keeps the address field inside it.
## The buttons around it leave, least needed first, and return in the same
## order as the pane widens. Without this the row keeps its full width and
## its right end, the address field with it, lies outside the pane.
func _fit_navigation() -> void:
	var parent := get_parent_control()
	if parent == null or back == null: return
	var available := parent.size.x - 16.0
	var leaving: Array[Button] = [native_button, info_button, forward, back, reload]
	var wanted := func(button: Button) -> bool:
		return _native_wanted if button == native_button else true
	var fitted := {}
	for step in leaving.size() + 1:
		var needed := address.custom_minimum_size.x
		for button in leaving:
			if wanted.call(button) and not fitted.has(button):
				needed += button.get_combined_minimum_size().x + 4.0
		if needed <= available or step == leaving.size(): break
		fitted[leaving[step]] = true
	if fitted == _fitted_out: return
	_fitted_out = fitted
	for button in leaving:
		button.visible = wanted.call(button) and not fitted.has(button)
	visual_revision += 1


func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED:
		var parent := get_parent_control()
		if parent != null and not parent.resized.is_connected(_fit_navigation):
			parent.resized.connect(_fit_navigation)
	if what == NOTIFICATION_READY:
		_fit_navigation.call_deferred()
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		refresh(session)
