extends "res://tests/client_scenarios/scenario.gd"
## Exercise the actual Android entry scene with Godot's touch-to-mouse path.
const Diagnostics := preload("res://graffitty/diagnostics.gd")
const TouchMenu := preload("res://scenes/input/TouchMenu.gd")
var manager: Control
var host: Node
var pointer: Control
var capture_path := ""

class FixtureCapture extends "res://scenes/input/DictationCapture.gd":
	var starts := 0
	func start() -> String:
		starts += 1
		recording = true
		return ""
	func stop() -> void:
		recording = false
		finished.emit()
	func discard() -> void:
		recording = false
	func _process(_dt: float) -> void:
		pass

# Keep gesture coverage independent of credentials/provider availability.
# The real streaming path is exercised by dictation_e2e.py.
class FixtureDictation extends "res://scenes/input/Dictation.gd":
	var sends := 0
	func start() -> void:
		capture.start()
		processing = true
		_refresh()
	func _capture_finished() -> void:
		processing = false
		_refresh()
		_maybe_send()
	func send() -> void:
		sends += 1
		discard()

class PointerGuard extends Node:
	func _input(event: InputEvent) -> void:
		if event is InputEventMouse and event.device != -1 and not event.get_meta("direct_touch", false):
			get_viewport().set_input_as_handled()

class ErrorWatch extends Logger:
	var errors: Array[String] = []
	func _log_error(_function: String, file: String, line: int, code: String, rationale: String, _notify: bool, type: int, _traces: Array[ScriptBacktrace]) -> void:
		if type != ERROR_TYPE_WARNING:
			errors.append("%s:%d %s" % [file, line, rationale if not rationale.is_empty() else code])
	func _log_message(_message: String, _error: bool) -> void:
		pass

var errors := ErrorWatch.new()
var diagnostic_guard := preload("res://tests/diagnostic_guard.gd").new()

func _ready() -> void:
	diagnostic_guard.install(get_tree())
	OS.add_logger(errors)
	OS.set_environment("GRAFFITTY_TOUCH_CONTROLS", "1")
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("android-ui-%d" % OS.get_process_id()))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--result="): output = arg.trim_prefix("--result=")
		if arg.begins_with("--capture="): capture_path = arg.trim_prefix("--capture=")
	run.call_deferred()

func expect(value: bool, message: String) -> void:
	checks.append(message)
	print("[android UI] %s %s" % ["PASS" if value else "FAIL", message])
	if not value: failures.append(message)

func pause() -> void:
	await create_timer(.1).timeout
	await get_tree().process_frame
	await get_tree().process_frame

func until(condition: Callable, seconds := 15.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while not condition.call() and Time.get_ticks_msec() < deadline:
		await pause()
	return condition.call()

func button(parent: Node, text: String) -> Button:
	for node in parent.find_children("*", "Button", true, false):
		if node.text == text or (node is MenuButton and node.name == text): return node
	return null

func point(control: Control) -> Vector2:
	var at := control.get_global_transform_with_canvas() * (control.size * .5)
	var window := control.get_window()
	if window != root: at += Vector2(window.position)
	return at

func touch(at: Vector2, pressed: bool, index: int = 0, settle := true) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = root.get_final_transform() * at
	event.pressed = pressed
	Input.parse_input_event(event)
	if settle: await pause()
	else: await get_tree().process_frame

func tap(control: Control) -> void:
	if not is_instance_valid(control):
		expect(false, "Tap target exists")
		return
	var at := point(control)
	expect(root.get_visible_rect().has_point(at), "Touch target is inside viewport: " + str(control.name))
	await touch(at, true)
	await touch(at, false)
	await pause()

func expand_menu() -> void:
	if not host.window_menu.expanded:
		expect(not pointer._accept_start(point(host.window_menu.expand_button)), "Collapsed menu bypasses terminal touch capture")
		await tap(host.window_menu.expand_button)
		expect(await until(func(): return is_equal_approx(host.window_menu.progress, 1.0)), "Floating menu expansion finishes")

func open_servers() -> void:
	await expand_menu()
	var menu: MenuButton = button(host.window_menu, "Sessions")
	await tap(menu)
	var popup := menu.get_popup()
	var shown: Window = preload("res://scenes/PopupChrome.gd").presentation(popup)
	expect(shown is TouchMenu and await until(func(): return shown.visible) and shown.is_embedded(), "Touch opens embedded Sessions menu")
	expect(not host.menu_entries.any(func(entry): return str(entry.label).begins_with("Sessions::Remote Access")), "Android Sessions menu omits host-only remote access controls")
	var server_index := -1
	for entry in host.menu_entries:
		if entry.label == "Sessions::Servers…" and entry.get("popup") == popup: server_index = entry.index
	expect(server_index >= 0, "Sessions menu contains Servers")
	# Live group: New, Rename, Next, Previous, Last, then the Switch Session submenu.
	expect(host.menu_entries.any(func(entry): return entry.label == "Sessions::New Session" and entry.index == 0) and popup.get_item_submenu(5) == str(host.popup_menus["Sessions::Switch Session"].name), "Live session commands are first")
	expect(server_index == 7 and popup.is_item_separator(6) and range(6).all(func(index): return not popup.is_item_separator(index)), "Servers follows the first divider")
	if popup.item_count > server_index + 1:
		expect(popup.is_item_separator(server_index + 1), "Saved sessions follow a second divider")
	if server_index >= 0:
		shown.dismiss()
		popup.id_pressed.emit(popup.get_item_id(server_index))
		await pause()

func run() -> void:
	if not OS.has_feature("android"):
		root.unfocusable = true
		if DisplayServer.get_name() != "headless" and not preload("../../../../../tests/llm-e2e/replay/background.gd").enabled():
			root.always_on_top = true
	if not OS.has_feature("android"):
		root.size = Vector2i(1456, 1312)
		root.content_scale_size = root.size
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
		root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	Input.emulate_mouse_from_touch = true
	if not settings.is_empty():
		var directory: String = preload("res://graffitty/paths.gd").stdpath("state")
		DirAccess.make_dir_recursive_absolute(directory)
		FileAccess.open(directory.path_join("remote.json"), FileAccess.WRITE).store_string(JSON.stringify(settings))
	manager = load("res://scenes/remote_manager.tscn").instantiate()
	root.add_child(manager)
	if not OS.has_feature("android"): root.add_child(PointerGuard.new())
	expect(await until(func(): return manager.view.host != null and manager.view.host.workspace_layout.tabs.size() == 2, FIRST_CONNECTION_SECONDS), "Full manager connects to server")
	host = manager.view.host
	if host == null:
		finish()
		return
	manager._return_to_workspace()
	if not OS.has_feature("android"): root.content_scale_factor = 1.0
	for child in host.workspace_view.get_children():
		if child.get_script() == preload("res://scenes/input/MobilePointer.gd"): pointer = child
	expect(pointer != null, "Real mobile pointer is installed")
	expect(root.gui_embed_subwindows, "Host registration preserves embedded dialogs")
	await pause()
	var tabs: Node = host.workspace_view.tab_bar.tabs
	var ids: Array = tabs.ids.duplicate()
	await tap(tabs.buttons[ids[1]])
	expect(host.workspace_layout.active == int(ids[1]), "Single finger tap switches remote tab")
	await tap(tabs.buttons[ids[0]])
	expect(host.workspace_layout.active == int(ids[0]), "Single finger tap returns to first tab")
	var terminal: Node = host.sessions[host.active_session_id].term
	terminal.send_text("printf 'UI_%s\\n' '한글'\r")
	expect(await until(func(): return "UI_한글" in str(terminal.get_text(false).get("text", ""))), "Full manager receives terminal text and Korean glyph state")
	expect(host.workspace_view.toolbar.get_child_count() == 0 and not host.workspace_view.toolbar.visible, "Android workspace has no toolbar taking up the main area")

	# A diagnostic must be directly tappable, even over the terminal surface.
	diagnostic_guard.allow("Touch dismissal fixture", "fixture.gd", 1)
	Diagnostics.history.assign([{"message": "Touch dismissal fixture", "file": "fixture.gd", "line": 1, "warning": false}])
	Diagnostics.revision += 1
	host.show_messages()
	host.diagnostic_panel.window.float_native()
	await pause()
	var panel: Node = host.diagnostic_panel
	expect(panel.panel.visible, "Messages panel opens")
	var dismiss: Button = panel.dismiss_button
	expect(not pointer._accept_start(point(dismiss)), "Messages are excluded from trackpad capture")
	await tap(dismiss)
	expect(not panel.panel.visible, "A real finger tap dismisses messages")

	await open_servers()
	expect(manager.chooser.visible, "Touch opens Connections dialog")
	expect(manager.chooser is Control, "Server list is an in-app page")
	expect(not pointer._accept_start(pointer.get_global_rect().get_center()), "Dialog blocks background trackpad")
	# A card's tap is its connection action; the start control opens the workspace.
	await tap(manager.cards.values()[0].select)
	expect(manager.chooser.visible, "Touching the connected card stays on the server page")
	await tap(manager.touch_start.brand)
	expect(not manager.chooser.visible, "Touch to start opens the connected workspace")
	# The Android profile uses floating icon menus, even on a Mac test host.
	await expand_menu()
	for label in ["Shell", "View", "Help"]:
		var menu: MenuButton = button(host.window_menu, label)
		expect(menu.text.is_empty() and menu.icon != null, "Floating menu uses an icon for " + label)
		await tap(menu)
		var shown: Window = preload("res://scenes/PopupChrome.gd").presentation(menu.get_popup())
		expect(shown is TouchMenu and await until(func(): return shown.visible) and shown.is_embedded(), "Touch opens embedded " + label + " menu")
		expect(not pointer._accept_start(pointer.get_global_rect().get_center()), "Open menu blocks trackpad")
		var shown_ref: WeakRef = weakref(shown)
		# Tall phone menus can cover the workspace center. Close from the
		# top window margin, without accidentally activating a menu item.
		var outside := Vector2(2, 2)
		expect(not Rect2(Vector2(shown.position), Vector2(shown.size)).has_point(outside), "Dismissal point is outside the menu")
		await touch(outside, true)
		await touch(outside, false)
		expect(await until(func(): return shown_ref.get_ref() == null or not shown_ref.get_ref().visible), "Outside tap closes " + label + " menu")
	var chrome_bottom: float = host.workspace_chrome_bottom()
	expect(not pointer._accept_start(point(host.window_menu.collapse_button)), "Expanded menu bypasses terminal touch capture")
	await tap(host.window_menu.collapse_button)
	expect(await until(func(): return is_zero_approx(host.window_menu.progress)), "Chevron collapses floating menu")
	expect(host.window_menu.expand_button.visible and not host.window_menu.row.visible, "Only the translucent ellipsis remains")
	expect(host.layout_root.offset_top == 0.0 and host.workspace_chrome_bottom() == chrome_bottom, "Floating menu never reserves workspace space")
	host.show_info()
	await pause()
	await tap(host.info_dialog.get_ok_button())
	expect(not is_instance_valid(host.info_dialog) or not host.info_dialog.visible, "About dialog dismisses by touch")

	var floating: CanvasLayer = manager.floating
	var keyboard: Button = floating.get_node("KeyboardButton")
	expect(keyboard.icon != null and keyboard.text.is_empty(), "Normal keyboard has Lucide icon")
	expect(floating.get_node_or_null("MicrophoneButton") != null and host.workspace_view.toolbar.get_node_or_null("KeyboardButton") == null, "Keyboard and microphone float above the workspace")
	expect(button(host.workspace_view.toolbar, "Keyboard 2") == null and button(host.workspace_view.toolbar, "Keyboards…") == null and button(floating, "Keyboards…") == null, "No keyboard switching or settings UI")
	await tap(keyboard)
	if OS.has_feature("android"):
		manager.keyboard_insets._hide_keyboard()
		await create_timer(.8).timeout
	expect(pointer.gestures.fingers.is_empty() and pointer.buttons == 0, "Keyboard tap bypasses trackpad capture")
	# Hold and drag moves a floating button; the terminal never sees the touch.
	var from := point(keyboard)
	var moved_to := from - Vector2(160, 120)
	await touch(from, true)
	await create_timer(.4).timeout
	var move := InputEventScreenDrag.new()
	move.position = root.get_final_transform() * moved_to
	move.relative = root.get_final_transform().basis_xform(moved_to - from)
	Input.parse_input_event(move)
	await pause()
	await touch(moved_to, false)
	expect(point(keyboard).distance_to(moved_to) < 4 and pointer.gestures.fingers.is_empty() and pointer.buttons == 0, "Dragging moves the keyboard button without touching the terminal")
	var placement_deadline := Time.get_ticks_msec() + 1500
	while (floating._returns.has("keyboard") or not keyboard.position.is_equal_approx(floating.destination("keyboard"))) and Time.get_ticks_msec() < placement_deadline:
		await get_tree().process_frame
	var placed := keyboard.position
	var desktop_insets: bool = not OS.has_feature("android") and manager.keyboard_insets == null
	if desktop_insets:
		# Desktop has no IME; drive the production inset handler directly.
		manager.terminal_ime = preload("res://scenes/input/AndroidTerminalIme.gd").new()
		manager.terminal_ime.manager = manager
		manager.add_child(manager.terminal_ime)
		manager.keyboard_insets = preload("res://scenes/input/AndroidKeyboardInsets.gd").new()
		manager.keyboard_insets.manager = manager
		manager.add_child(manager.keyboard_insets)
		manager.keyboard_insets.set_process(false)
	manager.terminal_ime._native_keyboard_height(roundi(300.0 * maxf(root.get_final_transform().get_scale().y, 1.0)))
	manager.keyboard_insets.update_inset(300.0)
	expect(keyboard.get_global_rect().end.y <= root.get_visible_rect().size.y - 300.0, "An open keyboard lifts floating buttons above it")
	expect(host.window_menu.mover.bottom_inset == floating.bottom_inset, "Menu uses the same IME and accessory-strip bounds as other controls")
	expect(host.window_menu.get_global_rect().end.y <= root.get_visible_rect().size.y - floating.bottom_inset, "Floating menu cannot overlap the Esc/Shift strip")
	manager.terminal_ime._native_keyboard_height(roundi(0.0 * maxf(root.get_final_transform().get_scale().y, 1.0)))
	manager.keyboard_insets.update_inset(0.0)
	var settle_deadline := Time.get_ticks_msec() + 1500
	while not keyboard.position.is_equal_approx(placed) and Time.get_ticks_msec() < settle_deadline:
		await get_tree().process_frame
	expect(keyboard.position.is_equal_approx(placed), "Closing the keyboard restores the button's place")
	expect(not host.workspace_view.toolbar.visible, "Closing the keyboard keeps the empty toolbar hidden")
	if desktop_insets:
		# Leave the desktop as production configures it: no IME to dismiss later.
		manager.keyboard_insets.queue_free()
		manager.keyboard_insets = null
		manager.terminal_ime.queue_free()
		manager.terminal_ime = null
	await microphone_gestures()

	expect(pointer.gestures.fingers.is_empty() and pointer.buttons == 0, "Controls do not leave a held pointer")
	# Two fingers navigate directly; a single finger scrolls terminal text.
	var center: Vector2 = pointer.get_global_rect().get_center()
	var before: Vector2 = host.workspace_view.navigation_center
	await touch(center - Vector2(30, 0), true)
	await touch(center + Vector2(30, 0), true, 1)
	for index in 2:
		var drag := InputEventScreenDrag.new()
		drag.index = index
		drag.position = root.get_final_transform() * (center + Vector2(-30 + index * 60, 0) + Vector2(80, 30))
		drag.relative = root.get_final_transform().basis_xform(Vector2(80, 30))
		Input.parse_input_event(drag)
		await pause()
	await touch(center + Vector2(50, 30), false)
	await touch(center + Vector2(110, 30), false, 1)
	expect(host.workspace_view.navigation_center.distance_to(before) > 10, "Two-finger navigation resumes after dialogs close")
	expect(pointer.buttons == 0, "Navigation leaves no terminal mouse button pressed")
	# A folded/narrow phone must keep dismiss and menu targets on-screen.
	if OS.has_feature("android"):
		DisplayServer.screen_set_orientation(DisplayServer.SCREEN_PORTRAIT)
		await create_timer(1.5).timeout
	else:
		root.size = Vector2i(400, 800)
		root.content_scale_size = Vector2i(400, 800)
	await pause()
	expect(root.get_visible_rect().encloses(keyboard.get_global_rect()) and root.get_visible_rect().encloses(floating.get_node("MicrophoneButton").get_global_rect()), "Floating buttons stay on a folded screen")
	host.show_messages()
	host.diagnostic_panel.window.float_native()
	await pause()
	expect(root.get_visible_rect().encloses(dismiss.get_global_rect()), "Portrait message Dismiss stays on-screen")
	await tap(dismiss)
	expect(not panel.panel.visible, "Portrait messages dismiss by touch")
	await open_servers()
	expect(await until(func(): return manager.chooser.size.x <= root.get_visible_rect().size.x + 1.0), "Portrait Connections dialog fits screen (%s in %s)" % [manager.chooser.size, root.get_visible_rect().size])
	await tap(manager.chooser.add_server)
	expect(manager.dialog.visible and manager.dialog.size.x <= root.get_visible_rect().size.x, "Portrait connection form opens within screen (%s in %s; visible %s)" % [manager.dialog.size, root.get_visible_rect().size, manager.dialog.visible])
	await tap(manager.dialog.back)
	expect(not manager.dialog.visible, "Connection form cancels by touch")
	# A card's tap is its connection action; the start control opens the workspace.
	await tap(manager.cards.values()[0].select)
	expect(manager.chooser.visible, "Portrait server card tap stays on the server page")
	await tap(manager.touch_start.brand)
	expect(not manager.chooser.visible, "Portrait Touch to start opens the workspace by touch")
	host.workspace_view.fit_to_main_area()
	await create_timer(.8).timeout
	var view: Control = host.workspace_view
	var pane: Control = view.panes[host.pane_focus]
	expect(Rect2(Vector2.ZERO, view.size).grow(2).encloses(view._pane_screen_rect(pane)), "Portrait Main View fits the complete terminal (%s in %s, zoom %.3f)" % [view._pane_screen_rect(pane), view.size, view.navigation_zoom])
	if not capture_path.is_empty():
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(capture_path)
	await connection_error_recovery()
	finish()

func connection_error_recovery() -> void:
	var key: String = manager.transports.keys()[0]
	var transport: Node = manager.transports[key]
	var password: String = manager.session_passwords[key]
	transport._connection_error("Formatter hyperlink cell mismatch")
	await pause()
	expect(manager.chooser.visible and manager.view.host == null, "Protocol failure leaves the stale workspace and opens connections")
	expect(manager.cards[key].action.text == "Retry now", "Failed workspace offers reconnect, not stale workspace access")
	expect(manager.states[key].state == "error" and "Formatter hyperlink cell mismatch" in manager.cards[key].status.text, "The connection screen retains the actual error")
	expect(manager.entries.has(key) and manager.session_passwords[key] == password, "Recovery keeps the server and password")
	manager._activate(key)
	expect(await until(func(): return manager.view.host != null and manager.states[key].state == "connected", FIRST_CONNECTION_SECONDS), "Retry reconnects the server")
	# Reconnecting keeps the server page; the start control opens the workspace.
	expect(manager.chooser.visible, "Retry stays on the server page")
	await tap(manager.touch_start.brand)
	expect(await until(func(): return not manager.chooser.visible, 5.0), "Touch to start opens a fresh workspace")
	host = manager.view.host
	expect(host != null and host.layout_root.visible, "The recovered workspace is visible")

func microphone_gestures() -> void:
	manager.dictation.queue_free()
	await pause()
	var dictation := FixtureDictation.new()
	dictation.host = host
	dictation.floating = manager.floating
	dictation.capture.free()
	dictation.capture = FixtureCapture.new()
	manager.dictation = dictation
	manager.add_child(dictation)
	var mic: Button = dictation.button
	var floating: CanvasLayer = manager.floating
	var original := mic.position
	await tap(mic)
	expect(dictation.capture.recording and dictation.bar.visible, "Quick microphone tap keeps recording with bottom preview")
	expect(mic.icon == preload("res://scenes/PaneIcons.gd").stop(), "The microphone becomes the single stop/send control")
	expect(host.menu_entries.all(func(entry): return entry.label != "View::Move floating buttons"), "Floating controls no longer need a positioning menu")
	dictation.preview.text = "Send once"
	await tap(mic)
	expect(not dictation.capture.recording and not dictation.bar.visible and dictation.sends == 1, "Second tap stops and sends once")
	var from := point(mic)
	await touch(from, true)
	var shifted := from - Vector2(120, 0)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = root.get_final_transform() * shifted
	drag.relative = root.get_final_transform().basis_xform(shifted - from)
	Input.parse_input_event(drag)
	Input.flush_buffered_events()
	expect(not dictation.capture.recording and mic.position.x < original.x - 60, "Cancel immediately discards audio while the mic starts returning from the dragged position")
	var overshoot := false
	var return_deadline := Time.get_ticks_msec() + 450
	while Time.get_ticks_msec() < return_deadline:
		await get_tree().process_frame
		overshoot = overshoot or mic.position.x > original.x + 1
	await touch(shifted, false)
	expect(overshoot and mic.position.is_equal_approx(original), "Sliding left returns the microphone with a bounce and settles exactly at its saved anchor")
	expect(not dictation.bar.visible and dictation.sends == 1, "Canceled release never sends")
	await tap(mic)
	dictation.preview.text = "Discard"
	await tap(dictation.discard_button)
	expect(not dictation.bar.visible and dictation.preview.text.is_empty() and dictation.sends == 1, "Preview cross discards without submitting")
	await create_timer(.45).timeout
	# Keep the first tap short and the second press inside the double-tap
	# window; ordinary tap() waits for layout twice after release.
	from = point(mic)
	await touch(from, true, 0, false)
	await touch(from, false, 0, false)
	from = point(mic)
	shifted = from - Vector2(100, 40)
	await touch(from, true)
	await create_timer(.4).timeout
	expect(floating._gesture.get("dragging", false) and not dictation.capture.recording and not dictation.bar.visible, "Double-tap and hold unlocks direct movement and discards the first tap's recording")
	drag = InputEventScreenDrag.new()
	drag.index = 0
	drag.position = root.get_final_transform() * shifted
	drag.relative = root.get_final_transform().basis_xform(shifted - from)
	Input.parse_input_event(drag)
	await touch(shifted, false)
	await create_timer(.4).timeout
	expect(point(mic).distance_to(shifted) < 4 and dictation.sends == 1, "Dragging and releasing saves the microphone position without sending")
	var saved := ConfigFile.new()
	saved.load(floating._profile_path)
	expect(saved.get_value("anchors", "microphone", Vector2.ZERO).is_equal_approx(floating.entries.microphone.anchor), "Direct movement persists the microphone anchor")
	await tap(mic)
	expect(dictation.capture.recording, "The repositioned microphone still supports quick tap recording")
	# A later hold on an already running recording is Stop, not a move.
	await create_timer(.45).timeout
	from = point(mic)
	await touch(from, true)
	await create_timer(.4).timeout
	expect(not floating._gesture.get("dragging", false) and dictation.capture.recording, "A later stop hold cannot turn an existing recording into a move")
	dictation.preview.text = "Later stop"
	await touch(from, false)
	expect(dictation.sends == 2, "A later stop hold still sends exactly once on release")
	await create_timer(.45).timeout
	from = point(mic)
	await touch(from, true)
	await create_timer(.4).timeout
	expect(dictation.capture.recording and not floating._gesture.get("dragging", false), "A single long press remains hold-to-record")
	dictation.preview.text = "Held recording"
	await touch(from, false)
	expect(dictation.sends == 3, "Single hold release sends once after movement gestures")
	dictation.discard()

func finish() -> void:
	failures.append_array(diagnostic_guard.failures)
	failures.append_array(errors.errors)
	result = {"failures": failures, "target": -1, "verify_terminal_commands": false}
	quit(0 if failures.is_empty() else 1)
