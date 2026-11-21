extends Node
## Android overlays its IME without resizing Godot's surface. Offer the
## remaining space to the shared layout.
##
## Main View refits into it; navigated content stays where it is on screen
## while the keyboard covers the part below.
var manager: Control
var inset := -1.0
var host: Node
var visible_dialogs: Array[Window] = []
var compact_chrome: Dictionary = {}

# Resume precedes window focus on Android. A hide issued between them may
# detach Godot's text listener without dismissing the IME's old surface.
var paused := false
var window_focused := true
var recovering := false
var hide_attempts := 0
var retry := Timer.new()
var _pending := false

func _init() -> void:
	retry.one_shot = true
	retry.wait_time = 0.25
	retry.timeout.connect(_retry_hide)
	add_child(retry)

func _ready() -> void:
	manager.terminal_ime.keyboard_height_changed.connect(_height_changed)
	manager.view.host_ready.connect(queue_update)
	manager.dialog.visibility_changed.connect(queue_update)
	manager.chooser.visibility_changed.connect(queue_update)
	get_tree().root.size_changed.connect(queue_update)
	get_tree().root.gui_focus_changed.connect(func(_control): queue_update())
	get_tree().node_added.connect(_watch_window)
	for window in get_tree().get_nodes_in_group(&"keyboard_safe_windows"):
		_watch_window(window)
	queue_update()

func _watch_window(node: Node) -> void:
	if node is Window and not node is PopupMenu:
		if not node.visibility_changed.is_connected(queue_update): node.visibility_changed.connect(queue_update)
		var focus_changed := queue_update.unbind(1)
		if not node.gui_focus_changed.is_connected(focus_changed): node.gui_focus_changed.connect(focus_changed)

func queue_update() -> void:
	if _pending or not is_inside_tree(): return
	_pending = true
	_flush_update.call_deferred()

func _flush_update() -> void:
	_pending = false
	manager.terminal_ime.check_owner()
	var next_host: Node = manager.view.host if manager.view != null else null
	if is_instance_valid(next_host):
		for event in [&"ui_changed", &"presentation_changed"]:
			if not next_host.is_connected(event, queue_update): next_host.connect(event, queue_update)
	var scale_y := get_tree().root.get_final_transform().get_scale().y
	update_inset(_recovered_inset(float(keyboard_height()) / maxf(scale_y, 1.0)))

func _height_changed(_height: int) -> void:
	# Android reports zero while another activity owns the IME. That does not
	# dismiss our editor: it must still be closed when this window resumes.
	if recovering and not paused and window_focused and keyboard_height() <= 0:
		recovering = false
		retry.stop()
	queue_update()

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			paused = true
			window_focused = false
			prepare_keyboard_close()
			if is_instance_valid(manager) and is_instance_valid(manager.keybar):
				manager.keybar.clear_modifiers()
		NOTIFICATION_APPLICATION_RESUMED:
			paused = false
			_resume_recovery()
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			window_focused = false
			retry.stop()
		NOTIFICATION_APPLICATION_FOCUS_IN:
			window_focused = true
			_resume_recovery()
	queue_update()

func _hide_keyboard() -> void:
	if is_instance_valid(manager) and is_instance_valid(manager.get("terminal_ime")): manager.terminal_ime.hide()
	DisplayServer.virtual_keyboard_hide()

func prepare_keyboard_open() -> void:
	# An explicit open wins over recovery, even if Android never reports zero
	# height for the old IME. No delayed hide may close the new editor.
	recovering = false
	hide_attempts = 0
	retry.stop()
	queue_update()

func prepare_keyboard_close() -> void:
	# Explicit dismissal must release the workspace and floating controls even
	# while Android's asynchronous height measurement still describes the IME.
	recovering = true
	hide_attempts = 0
	retry.stop()
	_resume_recovery()
	queue_update()

func keyboard_visible() -> bool:
	return not recovering and keyboard_height() > 0

func keyboard_height() -> int:
	if is_instance_valid(manager) and is_instance_valid(manager.get("terminal_ime")):
		return manager.terminal_ime.keyboard_height()
	return DisplayServer.virtual_keyboard_get_height()

func _resume_recovery() -> void:
	if recovering and not paused and window_focused and retry.is_stopped(): _retry_hide()

func _retry_hide() -> void:
	if not recovering or paused or not window_focused or hide_attempts >= 3: return
	_hide_keyboard()
	hide_attempts += 1
	if keyboard_height() <= 0:
		recovering = false
	elif hide_attempts < 3 and retry.is_inside_tree():
		retry.start()
	queue_update()

func _recovered_inset(reported: float) -> float:
	if not recovering: return reported
	if reported <= 0.0 and not paused and window_focused:
		recovering = false
		retry.stop()
	return 0.0

func update_inset(next: float) -> void:
	var root := get_tree().root
	root.set_meta(&"keyboard_bottom_inset", next)
	var next_host: Node = manager.view.host if manager.view != null else null
	# Measured before compact chrome or the inset moves the workspace's edges.
	var view: Control = next_host.workspace_view if is_instance_valid(next_host) else null
	if is_instance_valid(view) and not view.is_inside_tree(): view = null
	var shown := view.get_global_rect() if is_instance_valid(view) else Rect2()
	var keybar: Control = manager.keybar
	# Dictation's fields take the keyboard only while they have focus.
	var dictating: bool = is_instance_valid(manager.get("dictation")) and manager.dictation.owns_keyboard()
	var show_keys: bool = next > 0 and is_instance_valid(next_host) and not manager.dialog.visible and not manager.chooser.visible and not dictating and (next_host.is_terminal_pane(next_host.pane_focus) or next_host.is_chromium_pane(next_host.pane_focus))
	# A landscape IME can leave less room than the menu, tabs and accessory row
	# together. Reclaim the navigation chrome while typing so the main area still
	# has real terminal rows.
	#
	# Restore its previous visibility when the keyboard closes, the device
	# rotates, or the workspace changes.
	var compact := show_keys and root.get_visible_rect().size.y - next < 220.0
	if not compact_chrome.is_empty() and (not compact or next_host != host):
		for chrome: Control in compact_chrome:
			if is_instance_valid(chrome): chrome.visible = compact_chrome[chrome]
		compact_chrome.clear()
		if is_instance_valid(host): host._resize_menu_content()
	if compact:
		for chrome: Control in [next_host.window_menu, next_host.workspace_view.tab_bar]:
			if not is_instance_valid(chrome): continue
			if not compact_chrome.has(chrome): compact_chrome[chrome] = chrome.visible
			chrome.hide()
		if next_host.layout_root.offset_top != 0.0: next_host._resize_menu_content()
	var extra := preload("res://scenes/input/TouchKeyBar.gd").HEIGHT if show_keys else 0.0
	# One usable area for every floating controller, including the menu. This
	# includes the accessory strip and keyboard-close recovery, not just the IME.
	get_tree().call_group(&"floating_controls", &"set_bottom_inset", next + extra)
	get_tree().call_group(&"keyboard_safe_windows", &"set_bottom_inset", next)
	if is_instance_valid(manager.get("dictation")): manager.dictation.set_bottom_inset(next + extra)
	if is_instance_valid(keybar):
		if keybar.visible and not show_keys: keybar.clear_modifiers()
		keybar.visible = show_keys
		keybar.offset_bottom = -next
		keybar.offset_top = -next - extra
		keybar.update_host()
	if next != inset or next_host != host or (is_instance_valid(next_host) and not is_equal_approx(next_host.layout_root.offset_bottom, -next - extra)):
		inset = next
		host = next_host
		if is_instance_valid(host) and host.layout_root != null:
			host.layout_root.offset_bottom = -inset - extra
			if host.workspace_view != null:
				var toolbar: Control = host.workspace_view.toolbar
				toolbar.visible = inset <= 0.0 and toolbar.get_child_count() > 0
				host.workspace_view._refresh_after_resize.call_deferred()
	if is_instance_valid(view): view.keep_screen_position(shown)
	if is_instance_valid(host) and host.command_line != null:
		host.command_line.set_bottom_inset(inset)
	var current_dialogs: Array[Window] = []
	# Dialog discovery is only needed to dismiss an open keyboard. Avoid a
	# recursive walk of every terminal and control on each idle frame.
	if inset > 0.0:
		for candidate in root.find_children("*", "Window", true, false):
			var window := candidate as Window
			if window == root or not window.visible or window is PopupMenu: continue
			current_dialogs.append(window)
			# Read-only modal dialogs have no keyboard destination. Dismiss the old
			# terminal IME when opening them, leaving their buttons at readable size.
			if inset > 0.0 and window.exclusive and window not in visible_dialogs and window.find_children("*", "LineEdit", true, false).is_empty() and window.find_children("*", "TextEdit", true, false).is_empty():
				DisplayServer.virtual_keyboard_hide()
	visible_dialogs = current_dialogs
	for page: Control in [manager.dialog, manager.chooser]:
		if not is_equal_approx(page.offset_bottom, -inset):
			page.offset_bottom = -inset
			if page.visible and inset > 0.0: page.reveal_focus.call_deferred()

func _reveal_dialog_focus(window: Window) -> void:
	var focus := window.gui_get_focus_owner()
	if focus == null: return
	var ancestor := focus.get_parent()
	while ancestor != null and ancestor != window:
		if ancestor is ScrollContainer:
			ancestor.ensure_control_visible(focus)
			return
		ancestor = ancestor.get_parent()
