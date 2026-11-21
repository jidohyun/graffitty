extends HBoxContainer
## Official, themeable tab strip. Worlds own layout; the host owns sessions.
## Instantiate through host.ui.create_tab_strip(), or set host_path in a scene.
const DesktopText := preload("res://scenes/DesktopText.gd")
const ScreenSpace := preload("res://scenes/ScreenSpace.gd")
const NativeFrame := preload("res://scenes/NativeWindowFrame.gd")
const ActionStyle := preload("res://scenes/TabActionStyle.gd")
const ACTION_SIZE := 28.0
const ACTION_GAP := 8.0
const TITLE_HEIGHT := 42.0
const TAB_TOP_INSET := 8.0
@export var host_path: NodePath
@export_range(8, 24) var minimum_title_font_size := 12
var host: Node
var window_menu: PopupMenu
var context_id := -1
var navigation := preload("res://scenes/TabStripNavigation.gd").new()
var _title_margins := Vector3.ZERO
var _native_frame: Node
var _syncing_frame := false
var _refresh_pending := false
## Formatted titles by (text, budget, font).
##
## Measuring a title with get_string_size shapes it through every fallback
## face; a strip of ten long agent titles re-measured on each refresh cost
## hundreds of milliseconds per frame on phones.
var _title_cache: Dictionary = {}
var tabs: Control:
	get:
		return $TabGroup/Tabs


func _ready() -> void:
	DesktopText.apply_theme(theme)
	material = preload("res://scenes/TabFrameStyle.gd").create_material()
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(_sync_window_frame)
	var window := get_window()
	window.titlebar_changed.connect(_sync_window_frame, CONNECT_DEFERRED)
	window.dpi_changed.connect(_sync_window_frame, CONNECT_DEFERRED)
	window.size_changed.connect(_sync_window_frame, CONNECT_DEFERRED)
	window.visibility_changed.connect(_sync_window_frame, CONNECT_DEFERRED)
	if host == null and not host_path.is_empty():
		host = get_node(host_path)
	_setup_frame()
	if host != null:
		_connect_host()
	_sync_window_frame.call_deferred()


func bind_host(service_host: Node) -> void:
	if host != null:
		push_error("TerminalTabBar is already bound")
		return
	host = service_host
	if is_node_ready():
		_connect_host()


func _setup_frame() -> void:
	tabs.close_tooltip = ""
	tabs.plus.reparent($TabGroup)
	$TabGroup.resized.connect(_layout_tabs)
	tabs.plus.minimum_size_changed.connect(_layout_tabs)
	tabs.layout_changed.connect(_layout_tabs, CONNECT_DEFERRED)
	tabs.appearance_changed.connect(_sync_frame_shape)
	tabs.row.item_rect_changed.connect(_sync_frame_shape)
	tabs.title_formatter = _format_title
	add_child(navigation)
	navigation.configure($TabGroup, tabs, _populate_tab_menu)
	tabs.get_h_scroll_bar().value_changed.connect(func(_value): _sync_frame_shape())
	tabs.plus.accessibility_name = tr("New terminal tab")
	$NewChromium.hide()


func _connect_host() -> void:
	var close_hint: String = host.shortcut_text("CloseTab")
	var new_hint: String = host.shortcut_text("NewTab")
	tabs.close_tooltip = tr("Close tab") + " (%s)" % close_hint if not close_hint.is_empty() else ""
	tabs.plus.tooltip_text = tr("New terminal tab") + " (%s)" % new_hint if not new_hint.is_empty() else ""
	tabs.selected.connect(host.select_workspace)
	tabs.clicked.connect(func(id: int, was_selected: bool):
		if was_selected and id == host.workspace_layout.active:
			host.prefix_commands.toggle())
	tabs.closed.connect(host.request_close_tab)
	tabs.moved.connect(host.move_session)
	tabs.new_tab.connect(host.create_session)
	if host.workspace_view != null and host.has_method("detach_session"):
		tabs.drag_started.connect(
			func(id):
				host.application.begin_drag(host, tabs, id),
		)
		tabs.external_motion = host.application.update_drag
		tabs.external_drop = func():
			return host.application.finish_drag(ScreenSpace.of(tabs, tabs._pointer))
		tabs.context_requested.connect(_show_window_menu)
		window_menu = PopupMenu.new()
		window_menu.add_item("Rename Tab…", 2)
		if host.application.opens_windows():
			window_menu.add_separator()
			window_menu.add_item("Move Tab to New Window", 0)
		window_menu.id_pressed.connect(
			func(id):
				if id == 0:
					host.detach_session.call_deferred(context_id)
				elif id == 2:
					host.rename_tab.call_deferred(context_id),
		)
		add_child(window_menu)
	navigation.before_show = func():
		if host.has_method("open_tab_menu") and host.prefix_commands.active: host.prefix_commands.cancel()
	navigation.menu.tab_selected.connect(host.select_workspace)
	if host.has_method("reveal_pane"): navigation.menu.pane_selected.connect(host.reveal_pane)
	host.ui_changed.connect(_queue_refresh)
	var application = host.get("application")
	if application != null and application.get("agent_attention") != null:
		application.agent_attention.changed.connect(_queue_refresh)
	_refresh()


func _uses_native_title() -> bool:
	if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
		return false
	if not DisplayServer.has_feature(DisplayServer.FEATURE_EXTEND_TO_TITLE):
		return false
	var window := get_window()
	return (
		window.visible and not window.is_queued_for_deletion() and window.get_window_id() >= 0
		and window.extend_to_title and not window.is_embedded() and get_viewport() == window
		and window.mode not in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]
	)


func _sync_window_frame() -> void:
	if _syncing_frame or not is_node_ready() or not is_inside_tree() or is_queued_for_deletion():
		return
	_syncing_frame = true
	_title_margins = Vector3.ZERO
	if DisplayServer.get_name() == "macOS" and get_window().mode in [Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN]:
		var frame: RefCounted = ClassDB.instantiate("NativeWindowFrame")
		frame.fullscreen_content(DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, get_window().get_window_id()))
	custom_minimum_size.y = 40.0 if OS.get_name() == "Windows" else TITLE_HEIGHT
	if get_viewport() == get_window() and (DisplayServer.get_name() in ["X11", "Wayland"] or not preload("res://scenes/input/InteractionProfile.gd").touch_controls()):
		_native_frame = NativeFrame.acquire(get_window())
	if is_instance_valid(_native_frame):
		_native_frame.update_regions(self, [tabs, tabs.plus, navigation.all_tabs, navigation.previous_tabs, navigation.next_tabs])
		var safe: Vector3 = _native_frame.margins()
		var scale := get_viewport().get_final_transform().get_scale().abs()
		_title_margins = Vector3(safe.x / scale.x, safe.y / scale.x, safe.z / scale.y)
		# Containers place children on whole logical pixels. A fractional native
		# caption minimum otherwise leaves a sliver below the bottom-aligned tab.
		custom_minimum_size.y = ceilf(maxf(custom_minimum_size.y, _title_margins.z))
	elif _uses_native_title():
		# DisplayServer uses backing pixels; the strip lays out in UI points.
		var transform := get_viewport().get_screen_transform() * get_global_transform_with_canvas()
		var scale := transform.get_scale().abs()
		var window_id := get_window().get_window_id()
		DisplayServer.window_set_window_buttons_offset(
			Vector2i((Vector2(20, (size.y + TAB_TOP_INSET) * 0.5 - 2.0) * scale).round()),
			window_id,
		)
		var safe := DisplayServer.window_get_safe_title_margins(window_id)
		_title_margins = Vector3(safe.x / scale.x, safe.y / scale.x, safe.z / scale.y)
	_layout_tabs()
	_sync_frame_shape()
	_syncing_frame = false


func _draw() -> void:
	var profiled_started := Time.get_ticks_usec()
	_draw_body()
	preload("res://graffitty/frame_profile.gd").add("TerminalTabBar._draw", Time.get_ticks_usec() - profiled_started)


func _draw_body() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)


func _sync_frame_shape() -> void:
	if not is_node_ready():
		return
	preload("res://scenes/TabFrameStyle.gd").update(self, tabs, _title_background())
	if is_instance_valid(_native_frame):
		_native_frame.update_regions(self, [tabs, tabs.plus, navigation.all_tabs, navigation.previous_tabs, navigation.next_tabs])
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	# Tab buttons consume their presses. Only empty title-strip space controls the OS window.
	if is_instance_valid(_native_frame) and _native_frame.has_method("title_input") and _native_frame.title_input(event):
		accept_event()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and event.double_click:
		preload("res://scenes/WindowGeometry.gd").toggle_fit(get_window())
		accept_event()
		return
	if not _uses_native_title() or not event is InputEventMouseButton:
		return
	if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		DisplayServer.window_start_drag(get_window().get_window_id())
		accept_event()


func _queue_refresh() -> void:
	# One owner update can change several session titles and tab definitions.
	# Reconcile once with the final state before drawing the next frame.
	if _refresh_pending: return
	_refresh_pending = true
	_refresh.call_deferred()


func _refresh() -> void:
	var profiled_started := Time.get_ticks_usec()
	_refresh_body()
	preload("res://graffitty/frame_profile.gd").add("TerminalTabBar._refresh", Time.get_ticks_usec() - profiled_started)


func _refresh_body() -> void:
	_refresh_pending = false
	present_tabs(host.get_tabs(true), host.workspace_layout.active)
	if navigation.menu.visible: _populate_tab_menu()
	for id in tabs.buttons:
		var button: Button = tabs.buttons[id]
		var armed: bool = host.prefix_commands.active and id == host.workspace_layout.active
		button.self_modulate = Color("ffd078") if armed else Color.WHITE
		if armed:
			button.tooltip_text = "Prefix active · : or a number opens the command line · Esc to cancel"


## Draw the same chrome for a detached preview without connecting host actions.
func present_tabs(items: Array, active_id: int) -> void:
	for i in items.size():
		items[i]["ordinal"] = i + 1
		items[i]["tooltip"] = items[i].title
		var attention := preload("res://scenes/AgentAttention.gd").describe(items[i].get("attention", {}))
		if not attention.is_empty(): items[i]["tooltip"] += "\n" + attention
	tabs.reconcile(items, active_id)
	_layout_tabs()


func _layout_tabs() -> void:
	navigation.layout(_title_margins.x + ACTION_GAP, _title_margins.y + ACTION_GAP, 6.0 if OS.get_name() == "Windows" else TAB_TOP_INSET)
	_sync_frame_shape()


func _populate_tab_menu() -> void:
	navigation.menu.populate(host.get_tab_menu_items() if host.has_method("get_tab_menu_items") else host.get_tabs(true), host.workspace_layout.active, tabs, _title_background())


func _title_background() -> Color:
	return (
		get_theme_color("titlebar_background", "TerminalTabBar")
		if has_theme_color("titlebar_background", "TerminalTabBar") else Color("20242c")
	)


func _format_title(item: Dictionary, budget: float) -> Dictionary:
	var title := str(item.title)
	var colon := title.find(":")
	if colon >= 0 and "@" in title.left(colon):
		var suffix := title.substr(colon + 1)
		if suffix.begins_with("/") or suffix.begins_with("~"):
			title = suffix
	var prefix := "%d: " % int(item.ordinal)
	if item.progress_state != 0 and item.progress_value >= 0:
		prefix += "%d%% " % int(item.progress_value)
	var path := title.begins_with("/") or title.begins_with("~")
	var font := tabs.get_theme_font("font", tabs.tab_theme_type)
	var theme_size := tabs.get_theme_font_size("font_size", tabs.tab_theme_type)
	var key := "%s\u0001%s\u0001%.1f\u0001%d\u0001%d" % [prefix, title, budget, theme_size, font.get_rid().get_id()]
	if _title_cache.has(key): return _title_cache[key]
	if _title_cache.size() > 512: _title_cache.clear()
	var result := _fit_title(prefix, title, path, budget, font, theme_size)
	_title_cache[key] = result
	return result


func _fit_title(prefix: String, title: String, path: bool, budget: float, font: Font, font_size: int) -> Dictionary:
	var original := prefix + title
	var width := func(text: String, size: int) -> float:
		return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	# Make a modest reduction before discarding title information. Never
	# enlarge an already-small theme font, or shrink a normal one below 12 px.
	var minimum := mini(font_size, maxi(DesktopText.size(minimum_title_font_size), ceili(font_size * 0.8)))
	while font_size > minimum and width.call(original, font_size) > budget:
		font_size -= 1
	if width.call(original, font_size) <= budget:
		return {"text": original, "font_size": font_size}
	# Keep the longest end (paths) or start (titles) that fits, with an ellipsis.
	# Width grows with the kept length, so a binary search needs a few
	# measurements instead of one per dropped character.
	var trimmed := func(keep: int) -> String:
		var part := title.right(keep) if path else title.left(keep)
		return prefix + ("…" + part if path else part + "…")
	var low := 1
	var high := title.length() - 1
	while low < high:
		var middle := (low + high + 1) >> 1
		if width.call(trimmed.call(middle), font_size) <= budget: low = middle
		else: high = middle - 1
	var full: String = trimmed.call(low)
	# Measure the actual surviving characters, rather than guessing with wide
	# placeholder letters. Short titles that fit in full still keep their name.
	var fits: bool = width.call(full, font_size) <= budget
	return {"text": str(int(prefix.get_slice(":", 0))) if not fits or low <= 5 else full, "font_size": font_size}


func _show_window_menu(id: int) -> void:
	context_id = id
	window_menu.set_item_disabled(window_menu.get_item_index(1), host.application.hosts.size() < 2)
	preload("res://scenes/input/PointerPopup.gd").open(window_menu)
