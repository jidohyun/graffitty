extends "res://tests/unit/test_case.gd"
## Chromium ownership/mailbox tests live with apps/server. These cover the mirror.
const Chromium := preload("res://scenes/remote/RemoteChromiumSession.gd")

class RecordingChromium extends "res://scenes/ChromiumSession.gd":
	var events: Array = []
	func _send_input(method: String, params: Dictionary) -> void:
		events.append({"method": method, "params": params})

class NativeWindowTransport extends Node:
	var url := "shared://local"

func test_browser_status_tracks_the_actual_delivery_on_local_fallback() -> void:
	var browser := Chromium.new()
	var transport := NativeWindowTransport.new()
	browser.connection = transport
	browser.reject_gpu("Device proof timed out", false)
	expect(browser.status == "Shared texture unavailable. Switching to video or PNG." and browser.gpu_error == "Device proof timed out",
		"The fallback names both possible transports and retains the diagnostic")
	browser.apply_video_frame({"format": "png"}, PackedByteArray([1]))
	expect(browser.status == "Chromium · PNG preview", "Local PNG delivery has a local endpoint")
	browser.apply_state({})
	expect(browser.status == "Chromium · PNG preview", "A routine state update preserves PNG delivery")
	browser.video_codec = "hevc"
	browser.apply_state({})
	expect(browser.status == "Chromium · HEVC", "Local video does not acquire a remote label")
	browser.gpu_active = true
	browser.gpu_frames = 1
	browser.apply_state({})
	expect(browser.status == "Local Chromium · shared GPU texture", "A state update preserves proven shared delivery")
	browser.gpu_active = false
	transport.url = "wss://example.invalid/session"
	browser.apply_state({})
	expect(browser.status == "Remote Chromium · HEVC", "A network viewer keeps its remote label")
	browser.free()
	transport.free()

class ClipboardRecoveryChromium extends "res://scenes/remote/RemoteChromiumSession.gd":
	func _clipboard_operation(_code: int) -> void:
		pass

func test_clipboard_retry_clears_visible_error_without_another_server_state() -> void:
	var chromium := ClipboardRecoveryChromium.new()
	chromium._clipboard_failed("Clipboard text exceeds the browser input limit")
	chromium._clipboard_shortcut(KEY_C)
	expect(chromium._clipboard_error.is_empty() and chromium.status == "Remote Chromium",
		"A new shortcut clears both the stored and displayed clipboard failure immediately")
	chromium.failure_reason = "Browser unavailable"
	chromium._clipboard_failed("Old clipboard failure")
	chromium._clipboard_shortcut(KEY_C)
	expect(chromium.status == "Browser unavailable", "Clearing a clipboard failure preserves the browser failure")
	chromium.free()

class RecordingRemoteChromium extends "res://scenes/remote/RemoteChromiumSession.gd":
	var events: Array = []
	var bridged: Array[int] = []
	func _send_input(method: String, params: Dictionary) -> void:
		events.append({"method": method, "params": params})
	func _clipboard_shortcut(code: int) -> void:
		bridged.append(code)

func test_clipboard_shortcuts_use_native_chromium_only_on_this_computer() -> void:
	var chromium := RecordingRemoteChromium.new()
	var transport := NativeWindowTransport.new()
	chromium.connection = transport
	chromium.chromium_ready = true
	chromium.texture = ImageTexture.create_from_image(Image.create(100, 100, false, Image.FORMAT_RGBA8))
	var key := InputEventKey.new()
	key.keycode = KEY_C
	key.meta_pressed = OS.get_name() == "macOS"
	key.ctrl_pressed = OS.get_name() != "macOS"
	key.pressed = true
	expect(chromium.native_clipboard(), "A local server shares the viewer's clipboard")
	chromium.remote_input(key, Vector2(100, 100))
	expect(chromium.bridged.is_empty() and chromium.events[-1].params.get("commands") == ["copy"], "Local copy runs Chromium's native command")
	chromium.clipboard_bridge = true
	chromium.remote_input(key, Vector2(100, 100))
	expect(chromium.bridged == [KEY_C], "The E2E override forces the viewer bridge")
	chromium.clipboard_bridge = false
	transport.url = "wss://example.invalid/session"
	chromium.events.clear()
	chromium.remote_input(key, Vector2(100, 100))
	expect(chromium.bridged == [KEY_C, KEY_C] and chromium.events.is_empty(), "A remote server's copy goes to the viewer clipboard")
	chromium.free()
	transport.free()

func test_native_window_button_requires_chrome_on_the_local_server() -> void:
	var browser := Chromium.new()
	var transport := NativeWindowTransport.new()
	browser.connection = transport
	browser.gpu_active = true
	var toolbar := preload("res://scenes/ChromiumChrome.gd").new()
	toolbar._ready()
	toolbar.session = browser
	var state := {"tabs": [{"id": 1, "title": "Page", "url": "about:blank", "selected": true}],
		"chromiumId": 1, "nativeWindowSupported": false}
	browser.apply_state(state)
	toolbar.refresh(browser)
	expect(not toolbar.native_button.visible, "Alloy has no native-window button")
	browser.open_native()
	expect(browser._queue.is_empty(), "Alloy rejects native presentation before queuing a command")
	state.nativeWindowSupported = true
	state.sandboxEnabled = true
	browser.apply_state(state)
	toolbar.refresh(browser)
	expect(toolbar.native_button.visible == (OS.get_name() in ["macOS", "Windows"]), "Local desktop Chrome exposes native presentation")
	expect(not "sandbox disabled" in toolbar.info.text, "The toolbar reflects the server's enabled sandbox")
	transport.url = "wss://example.invalid/session"
	toolbar.refresh(browser)
	expect(not toolbar.native_button.visible, "Remote Chrome also hides the native-window button")
	browser.open_native()
	expect(browser._queue.is_empty(), "Remote presentation neither opens a server window nor changes pane fit")
	toolbar.free()
	browser.free()
	transport.free()

func test_remote_pointer_and_key_events_cross_native_message_mapping() -> void:
	var chromium := RecordingChromium.new()
	chromium.chromium_ready = true
	chromium.texture = ImageTexture.create_from_image(Image.create(100, 100, false, Image.FORMAT_RGBA8))
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(25, 35)
	chromium.remote_input(motion, Vector2(100, 100))
	for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_WHEEL_DOWN]:
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.position = motion.position
			event.button_index = button
			event.pressed = pressed
			chromium.remote_input(event, Vector2(100, 100))
	var pan := InputEventPanGesture.new()
	pan.position = motion.position
	pan.delta = Vector2(0, 1)
	chromium.remote_input(pan, Vector2(100, 100))
	var key := InputEventKey.new()
	key.keycode = KEY_A
	key.unicode = 97
	key.pressed = true
	chromium.remote_input(key, Vector2(100, 100))
	chromium.release_input()
	var connection := preload("res://scenes/remote/RemoteConnection.gd").new()
	connection.namespace_ids = true
	connection.local_ids = {7: 70}
	expect(chromium.events.size() >= 9, "Exercise motion, clicks, scrolling, typing and focus-loss release")
	for event in chromium.events:
		var mapped: Variant = connection.map_graph({"chromium": "%70", "event": event}, false)
		if expect(mapped is Dictionary, "Chromium %s input survives native message conversion" % event.params.type):
			# Compare wire values: Godot's JSON parser makes every number a float.
			var wire_event: Variant = JSON.parse_string(JSON.stringify(mapped.event))
			expect(mapped.chromium == "%7" and wire_event == JSON.parse_string(JSON.stringify(event)), "Remote input retains every CDP field and maps the owning pane")
	connection.free()
	chromium.free()

func test_mac_text_bindings_become_blink_edit_commands() -> void:
	var Session := preload("res://scenes/ChromiumSession.gd")
	for case in [
		[KEY_LEFT, true, false, false, false, "moveToBeginningOfLine"],
		[KEY_LEFT, true, false, true, false, "moveToBeginningOfLineAndModifySelection"],
		[KEY_DOWN, true, false, true, false, "moveToEndOfDocumentAndModifySelection"],
		[KEY_BACKSPACE, true, false, false, false, "deleteToBeginningOfLine"],
		[KEY_BACKSPACE, true, false, true, false, ""],
		[KEY_E, false, false, true, true, "moveToEndOfParagraphAndModifySelection"],
		[KEY_K, false, false, false, true, "deleteToEndOfParagraph"],
		[KEY_LEFT, false, true, false, false, ""],
		[KEY_LEFT, true, false, false, true, ""],
		[KEY_X, false, false, false, true, ""],
	]:
		var key := InputEventKey.new()
		key.keycode = case[0]
		key.meta_pressed = case[1]
		key.alt_pressed = case[2]
		key.shift_pressed = case[3]
		key.ctrl_pressed = case[4]
		expect(Session.mac_text_command(key) == case[5], "%s maps to '%s'" % [key.as_text(), case[5]])

func test_editing_shortcuts_include_commands_only_on_key_down() -> void:
	var chromium := RecordingChromium.new()
	chromium.chromium_ready = true
	chromium.texture = ImageTexture.create_from_image(Image.create(100, 100, false, Image.FORMAT_RGBA8))
	for action in [[KEY_A, false, "selectAll"], [KEY_Z, false, "undo"], [KEY_Z, true, "redo"], [KEY_C, false, "copy"], [KEY_X, false, "cut"], [KEY_V, false, "paste"]]:
		var key := InputEventKey.new()
		key.keycode = action[0]
		key.shift_pressed = action[1]
		key.meta_pressed = OS.get_name() == "macOS"
		key.ctrl_pressed = OS.get_name() != "macOS"
		key.pressed = true
		chromium.remote_input(key, Vector2(100, 100))
		expect(chromium.events[-1].params.get("commands") == [action[2]], "Shortcut includes Blink editing command: " + action[2])
		key.pressed = false
		chromium.remote_input(key, Vector2(100, 100))
		expect(not chromium.events[-1].params.has("commands"), "Key-up cannot repeat an editing command")
		key.pressed = true
		chromium.remote_input(key, Vector2(100, 100))
		chromium.release_input()
		expect(chromium.events[-1].params.type == "keyUp" and not chromium.events[-1].params.has("commands"), "Focus-loss release cannot repeat an editing command")
		key.alt_pressed = true
		chromium.remote_input(key, Vector2(100, 100))
		expect(not chromium.events[-1].params.has("commands"), "Alt-modified chord is not an editing command")
		key.alt_pressed = false
		key.meta_pressed = false
		key.ctrl_pressed = false
		chromium.remote_input(key, Vector2(100, 100))
		expect(not chromium.events[-1].params.has("commands"), "Plain letter does not invoke an editing command")
	chromium.free()

func test_unexpected_stop_alerts_once_and_a_relaunch_restores_the_pane_size() -> void:
	var chromium := Chromium.new()
	var notices := preload("res://scenes/AppNotifications.gd").new()
	chromium.notifications = notices
	chromium.session_id = 7
	var running := {"tabs": [{"id": 1, "title": "Docs", "url": "https://example.com/", "selected": true}], "chromiumId": 1}
	chromium.apply_state(running)
	chromium.set_preview_size(Vector2(1280, 800))
	var crashed := {"error": "Chromium host exited (signal: 6)", "crashed": true, "restartable": true, "tabs": [], "chromiumId": -1}
	chromium.apply_state(crashed)
	chromium.apply_state(crashed)
	expect(notices.history.size() == 1 and notices.history[0].level == "error", "An unexpected stop posts exactly one error notice")
	expect(notices.history.size() == 1 and "Docs" in notices.history[0].body and "signal: 6" in notices.history[0].body,
		"The notice names the page and the owner's reason")
	expect(chromium.restartable and chromium.texture == null, "A stopped chromium offers a restart instead of a frozen page")
	chromium._queue.clear()
	chromium.restarting = true
	chromium.apply_state(crashed)
	expect(chromium.restarting, "A relaunch in progress keeps Restart disabled")
	chromium.apply_state(running)
	expect(chromium.failure_reason.is_empty() and chromium._queue.any(func(item): return item.action == "resize" and item.width == 1280),
		"A relaunched chromium receives the pane size again")
	expect(not chromium.restarting, "Recovery ends the relaunch")
	chromium.apply_state({"error": "Chromium host exited (signal: 11)", "crashed": true, "restartable": true, "tabs": [], "chromiumId": -1})
	expect(notices.history.size() == 2, "A later stop is announced again")
	notices.free()
	chromium.free()

func test_a_pane_laid_out_before_its_browser_starts_sends_its_size_once_ready() -> void:
	var chromium := Chromium.new()
	chromium.session_id = 7
	chromium.set_preview_size(Vector2(400, 1000))
	expect(chromium._queue.is_empty(), "A browser that is still starting receives no resize")
	chromium.apply_state({"tabs": [{"id": 1, "title": "", "url": "about:blank", "selected": true}], "chromiumId": 1})
	var fitted := Chromium.viewport_for(Vector2(400, 1000))
	var resizes := chromium._queue.filter(func(item): return item.action == "resize")
	expect(resizes.size() == 1 and resizes[0].width == fitted.x and resizes[0].height == fitted.y,
		"The pane's size reaches the browser once it is ready, instead of its default window")
	chromium.apply_state({"tabs": [{"id": 1, "title": "", "url": "about:blank", "selected": true}], "chromiumId": 1})
	expect(chromium._queue.filter(func(item): return item.action == "resize").size() == 1, "Later states do not resend an unchanged size")
	chromium.free()

func test_a_crashed_page_alerts_once_and_reloads_while_the_browser_runs() -> void:
	var chromium := Chromium.new()
	var notices := preload("res://scenes/AppNotifications.gd").new()
	chromium.notifications = notices
	chromium.session_id = 7
	var page := {"id": 1, "title": "Docs", "url": "https://example.com/", "selected": true}
	var crashed := page.duplicate()
	crashed.crashed = true
	chromium.apply_state({"tabs": [page], "chromiumId": 1})
	chromium.apply_state({"tabs": [crashed], "chromiumId": 1})
	chromium.apply_state({"tabs": [crashed], "chromiumId": 1})
	expect(chromium.page_crashed and chromium.failure_reason.is_empty() and chromium.chromium_ready,
		"A crashed page leaves its browser running")
	expect(notices.history.size() == 1 and notices.history[0].level == "error" and "Docs" in notices.history[0].body,
		"A page crash is announced once, naming the page")
	chromium._queue.clear()
	chromium.reload_failed_page()
	expect(chromium._queue.any(func(item): return item.action == "tab-reload"), "Reload asks the browser for a new renderer")
	chromium.apply_state({"tabs": [page], "chromiumId": 1})
	expect(not chromium.page_crashed, "A reloaded page clears the crash")
	chromium.apply_state({"tabs": [crashed], "chromiumId": 1})
	expect(notices.history.size() == 2, "A later crash is announced again")
	notices.free()
	chromium.free()

func test_a_stuck_page_is_reloaded_without_being_announced_as_a_failure() -> void:
	var chromium := Chromium.new()
	var notices := preload("res://scenes/AppNotifications.gd").new()
	chromium.notifications = notices
	chromium.session_id = 7
	var page := {"id": 1, "title": "Docs", "url": "https://example.com/", "selected": true}
	var stuck := page.duplicate()
	stuck.notResponding = true
	chromium.apply_state({"tabs": [stuck], "chromiumId": 1})
	expect(chromium.page_not_responding and not chromium.page_crashed and chromium.failure_reason.is_empty(),
		"A stuck page keeps its browser and its renderer")
	expect(notices.history.is_empty(), "A page that may yet answer is not announced as a failure")
	chromium._queue.clear()
	chromium.reload_failed_page()
	expect(chromium._queue.any(func(item): return item.action == "tab-reload"), "Reload is the owner's recovery for a stuck page too")
	chromium.apply_state({"tabs": [page], "chromiumId": 1})
	expect(not chromium.page_crashed and not chromium.page_not_responding, "Loading again clears it")
	notices.free()
	chromium.free()

class RestartConnection extends Node:
	var reply: Dictionary
	func remote_call(_tab: int, _method: String, _params: Dictionary) -> Dictionary:
		return reply

func test_restart_already_done_by_another_viewer_is_not_a_failure() -> void:
	var chromium := Chromium.new()
	var notices := preload("res://scenes/AppNotifications.gd").new()
	var connection := RestartConnection.new()
	chromium.notifications = notices
	chromium.connection = connection
	chromium.session_id = 7
	connection.reply = {"error": {"code": "chromium_running", "message": "Chromium is running; only a stopped chromium can be restarted"}}
	var reply: Dictionary = await chromium.restart()
	expect(not reply.has("error") and not chromium.restarting, "A browser another viewer relaunched counts as restarted")
	expect(notices.history.is_empty(), "No failure is announced for it")
	connection.reply = {"error": {"code": "remote_error", "message": "Chromium host failed to start"}}
	reply = await chromium.restart()
	expect(reply.has("error") and notices.history.size() == 1 and notices.history[0].level == "error",
		"A real relaunch failure is still announced")
	connection.free()
	notices.free()
	chromium.free()

func test_pinch_cancellation_releases_chromium_pointer_without_clicking() -> void:
	var chromium := RecordingChromium.new()
	chromium.chromium_ready = true
	chromium.texture = ImageTexture.create_from_image(Image.create(100, 100, false, Image.FORMAT_RGBA8))
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = Vector2(50, 50)
	event.pressed = true
	chromium.remote_input(event, Vector2(100, 100))
	event.pressed = false
	event.canceled = true
	chromium.remote_input(event, Vector2(100, 100))
	var released: Dictionary = chromium.events.back().params
	expect(released.type == "mouseReleased" and released.buttons == 0 and chromium.mouse_buttons == 0, "Pinch releases chromium mouse capture")
	expect(released.x < 0 and released.y < 0, "Canceled release cannot click the page beneath the fingers")
	chromium.free()

func test_state_updates_preserve_server_chromium_identity_and_failure() -> void:
	var chromium := Chromium.new()
	chromium.session_id = 7
	chromium.apply_state({"chromiumId": 19, "tabs": [{"id": 19, "title": "Retained page"}],
		"pid": 12345, "profile": "/private/test-profile", "temporaryProfile": false,
		"primaryTargetId": "target-19", "runtimeDirectory": "/private/test-runtime"})
	expect(chromium.chromium_ready and chromium.title == "Retained page", "Remote state supplies page title and readiness")
	expect(chromium.pid == 12345 and chromium.profile_directory == "/private/test-profile" and chromium.persistent_profile,
		"Owner metadata supplies the actual chromium process and profile identity")
	expect(chromium.primary_target_id == "target-19" and chromium.directory == "/private/test-runtime",
		"Attachment and diagnostics use the owner's target and runtime directory")
	chromium.texture = ImageTexture.create_from_image(Image.create(2, 2, false, Image.FORMAT_RGBA8))
	chromium.apply_frame(Image.create(2, 2, false, Image.FORMAT_RGBA8).save_png_to_buffer())
	chromium.apply_state({"chromiumId": -1, "error": "Chromium host exited", "tabs": []})
	expect(not chromium.chromium_ready and chromium.status == "Chromium host exited", "Owner failure remains visible without launching a replacement")
	expect(chromium.texture == null and chromium.pending_frame.is_empty(), "Worker failure removes stale pixels and queued frames")
	chromium.apply_frame(Image.create(2, 2, false, Image.FORMAT_RGBA8).save_png_to_buffer())
	chromium._update_frame()
	expect(chromium.texture == null and chromium.pending_frame.is_empty(), "Late frames cannot revive a failed chromium preview")
	expect(chromium.session_id == 7, "Failed chromium keeps its durable server identity")
	chromium.free()

func test_latest_remote_frame_replaces_pending_decode() -> void:
	var chromium := Chromium.new()
	var first := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	first.fill(Color.RED)
	var last := Image.create(3, 2, false, Image.FORMAT_RGBA8)
	last.fill(Color.BLUE)
	chromium.apply_frame(first.save_png_to_buffer())
	chromium.apply_frame(last.save_png_to_buffer())
	chromium._update_frame()
	expect(chromium.frames == 1 and chromium.texture.get_size() == Vector2(3, 2), "Only the latest queued image is decoded")
	var decoded: Image = chromium.texture.get_image()
	expect(decoded.get_pixel(1, 1) == Color.BLUE, "Newest server pixels reach the presentation texture")
	chromium._update_frame()
	expect(chromium.frames == 1, "Idle polling does not decode the same frame again")
	chromium.free()

func test_failed_chromium_chrome_shows_error_without_opening_information() -> void:
	var chromium := Chromium.new()
	chromium.apply_state({"chromiumId": -1, "error": "Chromium host exited", "tabs": []})
	var chrome := preload("res://scenes/ChromiumChrome.gd").new()
	chrome._ready()
	chrome.session = chromium
	expect(not chrome.info.visible, "Session information starts collapsed")
	chrome.refresh(chromium)
	expect(chrome.info.visible and chrome.info.text == "Chromium host exited", "Worker failure is visible without clicking the information button")
	chrome.free()
	chromium.free()

func test_resize_commands_coalesce_without_losing_other_commands() -> void:
	var chromium := Chromium.new()
	chromium.chromium_ready = true
	chromium.set_preview_size(Vector2(320, 200))
	chromium.command("tab-select", {"chromiumId": 5})
	chromium.set_preview_size(Vector2(640, 480))
	expect(chromium._queue.size() == 2, "Unsent resizes coalesce while navigation is retained")
	expect(chromium._queue[0].action == "tab-select" and chromium._queue[1].width == 1280 and chromium._queue[1].height == 960, "Latest dimensions follow prior explicit action")
	chromium.free()

func test_narrow_panes_fit_a_desktop_width_page() -> void:
	expect(Chromium.viewport_for(Vector2(400, 300)) == Vector2i(1280, 960), "A narrow pane lays out a desktop-width page with its own aspect ratio")
	expect(Chromium.viewport_for(Vector2(1600, 900)) == Vector2i(1600, 900), "A wide pane uses its own size")
	var tall := Chromium.viewport_for(Vector2(200, 1600))
	expect(tall.y == 4096 and tall.x == 512, "A tall narrow pane keeps its aspect ratio within the maximum extent")

func test_context_menu_updates_are_idempotent() -> void:
	var chromium := Chromium.new()
	chromium.context_menu_request = "request-1"
	var changes: Array = []
	chromium.context_menu_requested.connect(func(menu): changes.append(menu))
	chromium.accept_context_menu({"request": "stale", "items": []})
	chromium.accept_context_menu({"request": "request-1", "items": ["Copy"]})
	chromium.accept_context_menu({"request": "request-1", "items": ["Copy"]})
	expect(changes.size() == 1, "Stale or duplicate menus never reopen the presentation")
	chromium.free()

func test_remote_video_error_is_not_reported_as_empty_success() -> void:
	var chromium := Chromium.new()
	chromium.apply_video_frame({"format": "error", "error": "Decoder unavailable"}, PackedByteArray())
	expect(chromium.status == "Decoder unavailable" and chromium.frames == 0, "Server video failure stays visible and creates no false frame")
	chromium.free()

class RecoveryDecoder extends RefCounted:
	var packets: Array[PackedByteArray] = []
	var accepted := true
	func start(_codec: String, _width: int, _height: int, _implementation: String, _nv12: bool) -> bool:
		return true
	func submit(packet: PackedByteArray, _frame: int) -> bool:
		packets.append(packet)
		return accepted
	func consumed() -> int:
		return 0

class RefusingDecoder extends RecoveryDecoder:
	func start(_codec: String, _width: int, _height: int, _implementation: String, _nv12: bool) -> bool:
		return false

## Builds decoders that refuse to start until `refusals` have been used up.
class StarvedChromium extends "res://scenes/remote/RemoteChromiumSession.gd":
	var refusals := 0
	var created: Array = []
	func _new_video_decoder() -> RefCounted:
		var decoder: RefCounted = RefusingDecoder.new() if created.size() < refusals else RecoveryDecoder.new()
		created.append(decoder)
		return decoder

class RecoveryConnection extends Node:
	var connected := true
	var resets: Array[int] = []
	var acks: Array[int] = []
	var rejected: Array = []
	func reset_chromium_video(id: int) -> void:
		resets.append(id)
	var holds: Array[int] = []
	func acknowledge_chromium(_id: int, frame: int, held_msec := 0) -> void:
		acks.append(frame)
		holds.append(held_msec)
	func reject_chromium_codec(id: int, codec: String) -> void:
		rejected.append([id, codec])

class RebuildingChromium extends "res://scenes/remote/RemoteChromiumSession.gd":
	var created: Array = []
	func _new_video_decoder() -> RefCounted:
		var decoder := RecoveryDecoder.new()
		created.append(decoder)
		return decoder

class SuspendedLayout extends RefCounted:
	var active := 0
	func tab(_id: int) -> Dictionary:
		return {}

class SuspendedHost extends Node:
	var chromiums: Dictionary = {}
	var sessions: Dictionary = {}
	var presentation_active := false
	var workspace_layout := SuspendedLayout.new()
	var workspace_view: Control

func test_a_narrow_pane_keeps_the_address_field_inside_by_dropping_buttons() -> void:
	var body := Control.new()
	var chrome: VBoxContainer = preload("res://scenes/ChromiumChrome.gd").new()
	chrome._ready()
	body.add_child(chrome)
	body.size = Vector2(400, 300)
	chrome._fit_navigation()
	expect(chrome.back.visible and chrome.forward.visible and chrome.reload.visible and chrome.info_button.visible, "A wide pane shows every navigation button")
	# A phone-width browser pane: 142 logical pixels.
	body.size = Vector2(142, 300)
	chrome._fit_navigation()
	expect(not chrome.info_button.visible and not chrome.forward.visible and not chrome.back.visible and not chrome.reload.visible, "A pane only wide enough for the address field keeps just that")
	expect(chrome.address.visible, "The address field always stays")
	body.size = Vector2(170, 300)
	chrome._fit_navigation()
	expect(chrome.reload.visible and not chrome.back.visible, "Buttons return in order as the pane widens: reload first")
	body.size = Vector2(400, 300)
	chrome._fit_navigation()
	expect(chrome.back.visible and chrome.forward.visible and chrome.info_button.visible and not chrome.native_button.visible, "Everything the session offers returns at full width")
	body.free()

func _starved(refusals: int) -> Array:
	var chromium := StarvedChromium.new()
	var connection := RecoveryConnection.new()
	chromium.refusals = refusals
	chromium.connection = connection
	chromium.session_id = 7
	return [chromium, connection]

func test_a_decoder_that_cannot_start_for_a_moment_is_retried_not_rejected() -> void:
	var pair := _starved(2)
	var chromium: Node = pair[0]
	var connection: Node = pair[1]
	var key := {"format": "hevc", "width": 1000, "height": 700, "key": true, "source_width": 1000, "source_height": 700, "epoch": 1, "sequence": 1, "frame": 1}
	chromium.apply_video_frame(key, PackedByteArray([1]))
	expect(connection.rejected.is_empty() and chromium.video_decoder == null and chromium.video_waiting_key, "One refused start keeps the codec and waits")
	key.sequence = 2
	chromium.apply_video_frame(key, PackedByteArray([2]))
	expect(chromium.created.size() == 1 and connection.resets.is_empty(), "Frames before the retry time neither start a decoder nor ask for a keyframe")
	chromium._video_retry_at = 0
	chromium.apply_video_frame(key, PackedByteArray([2]))
	expect(chromium.created.size() == 2 and connection.rejected.is_empty(), "The second refusal is still a retry")
	chromium._video_retry_at = 0
	key.sequence = 3
	chromium.apply_video_frame(key, PackedByteArray([3]))
	expect(chromium.created.size() == 3 and chromium.video_decoder == chromium.created[2] and not chromium.video_waiting_key, "The third attempt starts and decodes")
	expect(connection.rejected.is_empty() and chromium.created[2].packets == [PackedByteArray([3])], "The codec was never rejected")
	chromium.free(); connection.free()

func test_a_decoder_that_never_starts_rejects_the_codec_for_its_pane() -> void:
	var pair := _starved(99)
	var chromium: Node = pair[0]
	var connection: Node = pair[1]
	var key := {"format": "hevc", "width": 1000, "height": 700, "key": true, "source_width": 1000, "source_height": 700, "epoch": 1, "sequence": 1, "frame": 1}
	for attempt in chromium.VIDEO_START_ATTEMPTS:
		chromium._video_retry_at = 0
		chromium.apply_video_frame(key, PackedByteArray([1]))
	expect(connection.rejected == [[7, "hevc"]], "After every attempt fails, this pane rejects the codec once")
	expect(chromium._video_start_failures == 0 and chromium._video_retry_at == 0, "The next codec starts with a clean count")
	chromium.free(); connection.free()

func test_application_pause_and_resume_rebuild_decoder_without_rejecting_codec() -> void:
	var chromium := RebuildingChromium.new()
	var connection := RecoveryConnection.new()
	var old_decoder := RecoveryDecoder.new()
	chromium.connection = connection
	chromium.session_id = 7
	chromium.video_codec = "h264"
	chromium.video_epoch = 4
	chromium.video_sequence = 10
	chromium.video_decoder = old_decoder
	chromium.video_waiting_key = false
	chromium.texture = ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	var texture := chromium.texture
	var frame := {"format": "h264", "width": 1000, "height": 700, "key": false, "source_width": 1000, "source_height": 700, "epoch": 4, "sequence": 11, "frame": 21}
	chromium.apply_video_frame(frame, PackedByteArray([1]))
	expect(old_decoder.packets.size() == 1 and connection.acks.is_empty(), "A frame in the decoder's queue is not acknowledged yet")
	var host := SuspendedHost.new()
	host.chromiums = {7: chromium}
	var client := preload("res://scenes/remote/RemoteClient.gd").new()
	client.host = host
	client._notification_body(Node.NOTIFICATION_APPLICATION_PAUSED)
	expect(client.stream_background, "Pause stops the pane streams")
	expect(chromium.video_decoder == null and chromium.video_waiting_key, "Pause discards the decoder and waits for a keyframe")
	expect(connection.acks == [21], "Frames queued to the discarded decoder are acknowledged by the existing drop helper")
	expect(chromium.texture == texture, "The last displayed texture stays")
	expect(connection.rejected.is_empty() and chromium.video_codec == "h264", "Suspension is not a codec failure")
	client._notification_body(Node.NOTIFICATION_APPLICATION_RESUMED)
	expect(not client.stream_background and chromium.video_decoder == null and connection.rejected.is_empty(), "Resume keeps waiting without a decoder")
	var delta := {"format": "h264", "width": 1000, "height": 700, "key": false, "source_width": 1000, "source_height": 700, "epoch": 4, "sequence": 60, "frame": 30}
	chromium.apply_video_frame(delta, PackedByteArray([2]))
	expect(chromium.video_decoder == null and chromium.created.is_empty() and connection.resets == [7], "A delta frame never reaches a stale decoder; it requests a keyframe")
	var key := {"format": "h264", "width": 1000, "height": 700, "key": true, "source_width": 1000, "source_height": 700, "epoch": 4, "sequence": 61, "frame": 31}
	chromium.apply_video_frame(key, PackedByteArray([3]))
	expect(chromium.created.size() == 1 and chromium.video_decoder == chromium.created[0] and chromium.video_decoder != old_decoder, "The next IDR builds a new decoder")
	expect(chromium.created[0].packets == [PackedByteArray([3])] and not chromium.video_waiting_key and chromium.video_sequence == 61, "The new decoder starts at that IDR")
	expect(old_decoder.packets.size() == 1 and connection.rejected.is_empty(), "The stale decoder is never reused and no codec was rejected")
	client._notification_body(Node.NOTIFICATION_APPLICATION_RESUMED)
	chromium.release_video_decoder()
	chromium.release_video_decoder()
	expect(chromium.video_decoder == null and chromium.video_waiting_key, "Releasing is idempotent")
	client.connection.free()
	client.free()
	host.free()
	chromium.free()
	connection.free()

func test_keyframe_recovery_retains_decoder_until_encoder_changes() -> void:
	var chromium := Chromium.new()
	var connection := RecoveryConnection.new()
	var decoder := RecoveryDecoder.new()
	chromium.connection = connection
	chromium.session_id = 7
	chromium.video_codec = "h264"
	chromium.video_epoch = 4
	chromium.video_sequence = 10
	chromium.video_decoder = decoder
	chromium.video_waiting_key = false
	var submitted := {"format": "h264", "width": 1000, "height": 700, "key": false, "source_width": 1000, "source_height": 700, "epoch": 4, "sequence": 11, "frame": 21}
	chromium.apply_video_frame(submitted, PackedByteArray([1]))
	expect(decoder.packets.size() == 1, "Contiguous encoded packet reaches the retained decoder")
	expect(submitted.get("ack_deferred", false) and connection.acks.is_empty(), "A submitted frame is acknowledged once its codec accepts it")
	var dropped := {"format": "h264", "width": 1000, "height": 700, "key": false, "source_width": 1000, "source_height": 700, "epoch": 4, "sequence": 14, "frame": 22}
	chromium.apply_video_frame(dropped, PackedByteArray([2]))
	expect(connection.resets == [7] and decoder.packets.size() == 1, "A dropped delta frame requests a keyframe without decoding broken dependencies")
	expect(not dropped.get("ack_deferred", false), "A frame that is not decoded is acknowledged on receipt")
	chromium.apply_video_frame({"format": "h264", "width": 1000, "height": 700, "key": true, "source_width": 1000, "source_height": 700, "epoch": 4, "sequence": 15}, PackedByteArray([3]))
	expect(chromium.video_decoder == decoder and decoder.packets == [PackedByteArray([1]), PackedByteArray([3])], "A fresh keyframe reuses the same MediaCodec lifetime")
	expect(not chromium.video_waiting_key and chromium.video_sequence == 15, "Recovered sequence resumes normal packet delivery")
	decoder.accepted = false
	chromium.apply_video_frame({"format": "h264", "width": 1000, "height": 700, "key": false, "source_width": 1000, "source_height": 700, "epoch": 4, "sequence": 16, "frame": 24}, PackedByteArray([4]))
	expect(chromium.video_decoder == null and chromium.video_waiting_key and connection.resets == [7, 7], "An actual decoder failure discards it and requests a new independent stream")
	expect(connection.acks == [21], "Frames queued to a discarded decoder are acknowledged, so the stream's window cannot stall")
	chromium.free()
	connection.free()

func test_missing_video_dimensions_report_protocol_error_without_decoding() -> void:
	var chromium := Chromium.new()
	chromium.apply_video_frame({"format": "h264", "width": 640, "height": 360}, PackedByteArray([1]))
	expect("source_width" in chromium.video_error, "Missing dimensions identify the invalid wire field")
	expect(chromium.video_decoder == null and chromium.video_waiting_key, "Invalid headers never reach the decoder")
	chromium.free()

class WindowHost extends Node:
	var chromiums: Dictionary = {}
	var sessions: Dictionary = {}

func test_only_main_chromium_window_owns_the_session_status_strip() -> void:
	var host := WindowHost.new()
	var view := preload("res://scenes/WorkspaceView.gd").new()
	view.host = host
	var main := Chromium.new()
	var child := Chromium.new()
	main.apply_state({"mainWindow": true})
	child.apply_state({"mainWindow": false})
	host.chromiums = {7: main, 8: child}
	expect(view._has_session_status("%1"), "Terminal retains its own status strip")
	expect(view._has_session_status("%7"), "Main Chromium window has session status")
	expect(not view._has_session_status("%8"), "Detached window has no duplicate session status")
	child.apply_state({"mainWindow": true})
	expect(view._has_session_status("%8"), "Promoted window takes over session status")
	view.free()
	main.free()
	child.free()
	host.free()

func test_detached_window_uses_terminal_controller_but_links_to_main_chromium() -> void:
	var client = preload("res://scenes/remote/RemoteClient.gd")
	var windows := [{"id": 7, "owner": 1}, {"id": 8, "owner": 7}]
	expect(client.chromium_controller(windows, 7) == 1, "Child window commands retain terminal authorization")
	expect(client.chromium_controller(windows, 1) == 1, "Main window uses its terminal")
	expect(client.chromium_controller([{"id": 7, "owner": 7}, {"id": 8, "owner": 7}], 7) == 7,
		"Independent chromium windows retain the root chromium controller")
	var host := WindowHost.new()
	var view := preload("res://scenes/WorkspaceView.gd").new()
	view.host = host
	var main := Chromium.new()
	var child := Chromium.new()
	main.owner_id = 1
	child.owner_id = 7
	main.tab_id = 1
	child.tab_id = 1
	host.chromiums = {7: main, 8: child}
	expect(view._chromium_owners() == {"%7": "%1", "%8": "%7"}, "Graph distinguishes sessions from windows")
	view.free()
	main.free()
	child.free()
	host.free()

func test_trackpad_phases_and_touch_travel_reach_chromium() -> void:
	var chromium := RecordingChromium.new()
	chromium.chromium_ready = true
	# A 320x180 pane shows a 640x360 frame of the default 1280x720 page.
	chromium.texture = ImageTexture.create_from_image(Image.create(640, 360, false, Image.FORMAT_RGBA8))
	var native := 0.03 if OS.get_name() == "macOS" else 1.0
	var steps := [["began", ""], ["changed", ""], ["ended", ""], ["", "began"], ["", "changed"], ["", "ended"]]
	for step in steps:
		var pan := InputEventPanGesture.new()
		pan.position = Vector2(100, 50)
		pan.delta = Vector2(0, -3 * native)
		if not step[0].is_empty(): pan.set_meta("scroll_phase", step[0])
		if not step[1].is_empty(): pan.set_meta("momentum_phase", step[1])
		pan.set_meta("event_time", 100.0 + steps.find(step) * 0.008)
		chromium.remote_input(pan, Vector2(320, 180))
	expect(chromium.events.size() == steps.size(), "Every trackpad phase reaches Chromium, including zero-travel ends")
	for index in mini(steps.size(), chromium.events.size()):
		var params: Dictionary = chromium.events[index].params
		expect(params.get("phase", "") == steps[index][0] and params.get("momentumPhase", "") == steps[index][1],
			"Trackpad %s carries AppKit's finger and momentum phases" % str(steps[index]))
		expect(is_equal_approx(params.deltaY, -3.0) and not params.has("scrollSource"), "Trackpads scroll by native pixels")
		expect(is_equal_approx(params.get("eventTime", 0.0), 100.0 + index * 0.008),
			"Trackpad events keep AppKit's event time for Chromium's release velocity")
	chromium.events.clear()
	var touch := InputEventPanGesture.new()
	touch.position = Vector2(100, 50)
	touch.delta = Vector2(0, 99)
	touch.set_meta("touch_scroll_sequence", 1)
	touch.set_meta("touch_travel", Vector2(0, 30))
	chromium.remote_input(touch, Vector2(320, 180))
	var dragged: Dictionary = chromium.events[0].params if chromium.events.size() == 1 else {}
	# One pane pixel is four page pixels: a 30 pixel drag down shows 120 more above.
	expect(is_equal_approx(dragged.get("deltaY", 0.0), -120.0) and is_equal_approx(dragged.get("deltaX", 1.0), 0.0),
		"A dragging finger carries the page exactly as far as it travels")
	chromium.events.clear()
	# A finger's gesture: began and changed under it, a glide marked changed,
	# and one ended for the whole gesture, which closes the glide.
	var gesture := [["scroll_phase", "began", 20], ["scroll_phase", "changed", 20], ["momentum_phase", "changed", 10], ["momentum_phase", "changed", 5], ["scroll_phase", "ended", 0]]
	for step in gesture:
		var finger := InputEventPanGesture.new()
		finger.position = Vector2(100, 50)
		finger.set_meta(step[0], step[1])
		finger.set_meta("touch_travel", Vector2(0, step[2]))
		chromium.remote_input(finger, Vector2(320, 180))
	var phases := chromium.events.map(func(event): return [event.params.get("phase", ""), event.params.get("momentumPhase", "")])
	expect(phases == [["began", ""], ["changed", ""], ["", "changed"], ["", "changed"], ["", "ended"]],
		"A finger stretches the page at an edge and its glide bounces, like a trackpad: %s" % [phases])
	chromium.events.clear()
	for step in [["scroll_phase", "began", 20], ["scroll_phase", "ended", 0]]:
		var finger := InputEventPanGesture.new()
		finger.position = Vector2(100, 50)
		finger.set_meta(step[0], step[1])
		finger.set_meta("touch_travel", Vector2(0, step[2]))
		chromium.remote_input(finger, Vector2(320, 180))
	expect(chromium.events.size() == 2 and chromium.events[1].params.get("phase", "") == "ended",
		"A drag that does not glide ends under the finger, releasing any stretch")
	chromium.free()

func test_video_pixels_do_not_rebuild_the_workspace_ui() -> void:
	var chromium := Chromium.new()
	var changes := [0]
	chromium.changed.connect(func(): changes[0] += 1)
	var pixels := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	pixels.fill(Color.RED)
	chromium.apply_frame(pixels.save_png_to_buffer())
	chromium._update_frame()
	var first := chromium.texture
	expect(changes[0] == 1 and chromium.frames == 1, "First frame publishes its texture")
	pixels.fill(Color.BLUE)
	chromium.apply_frame(pixels.save_png_to_buffer())
	chromium._update_frame()
	expect(changes[0] == 1 and chromium.frames == 2 and chromium.texture == first,
		"New pixels update the same texture without rebuilding workspace UI")
	pixels = Image.create(32, 16, false, Image.FORMAT_RGBA8)
	chromium.apply_frame(pixels.save_png_to_buffer())
	chromium._update_frame()
	expect(changes[0] == 2 and chromium.texture != first, "Resizing publishes the replacement texture")
	chromium.free()

func test_failure_controls_fit_a_narrow_pane() -> void:
	var pane := preload("res://scenes/WorkspacePane.gd").new()
	pane.add_child(pane.texture)
	pane._build_chromium_failure()
	pane.chromium_failure.show()
	pane.chromium_reload_button.hide()
	pane.chromium_failure_reason.text = "Chromium host exited unexpectedly with a long diagnostic from the server"
	expect(pane.chromium_failure.get_combined_minimum_size().x <= 240,
		"The heading and action row do not force recovery controls beyond a narrow pane")
	pane.free()

func test_detach_releases_consumers_before_the_video_viewport() -> void:
	var chromium := Chromium.new()
	var viewport := SubViewport.new()
	chromium.add_child(viewport)
	chromium._nv12_view = viewport
	chromium.texture = viewport.get_texture()
	var observed := []
	chromium.changed.connect(func(): observed.append([chromium.texture == null, not viewport.is_queued_for_deletion()]))
	chromium.release_rendering()
	expect(observed == [[true, true]], "Consumers clear the texture before its viewport is scheduled for deletion")
	expect(chromium._nv12_view == null, "The detached session releases its video target")
	chromium.free()
