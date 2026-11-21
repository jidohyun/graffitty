extends Node
signal context_menu_requested(menu: Dictionary)
var context_menu_screen := Vector2.ZERO
var context_menu_request := ""
var _context_menu: Dictionary = {}
## Chromium's latest find-in-page result for the selected page:
## {count, active, final, identifier}, or empty when nothing is being found.
var find_result: Dictionary = {}
## A finger's scroll has glided since it began, so its end closes the glide.
var _touch_gliding := false
var _finding := false

func accept_context_menu(menu: Dictionary) -> void:
	if menu.get("request", "") != context_menu_request or menu == _context_menu:
		return
	_context_menu = menu.duplicate(true)
	context_menu_requested.emit(menu)

## Chromium presentation/input state. The shared server owns Chromium and profiles.
var playwright: Node
signal changed
## A new frame replaced the pixels of the same `texture`.
signal presented
signal reply(id: int, result: Dictionary)
var session_id := -1
var tab_id := -1 # Terminal (or independent root browser) used for scoped RPC.
var owner_id := -1 # Direct topology parent: terminal or main browser window.
var pid := -1
var main_window := true
var resource_monitor: Node
var directory := "" # Read-only runtime path reported by the owner.
var primary_target_id := ""
var profile_directory := ""
var persistent_profile := false
var pinned_title := ""
var _page_title := "Chromium"
var title: String:
	get:
		return pinned_title if not pinned_title.is_empty() else _page_title
	set(value):
		_page_title = value
var _status_source := "Starting isolated Chromium…"
var _status_args: Array = []
var status: String:
	get: return tr(_status_source) if _status_args.is_empty() else tr(_status_source) % _status_args
	set(value):
		_status_source = value
		_status_args.clear()

var texture: Texture2D
## Set by the pane when the world draws this page beneath the workspace canvas
## (WorkspacePane.set_video_layer). Frames that keep `texture` then update it
## at frame_pre_draw, so they draw the world without redrawing the canvas.
var present_at_draw := false
var selected := false
var _capture_selected := true
var native_visible := false
## The viewer stopped this pane's frames: it is off-screen or too small to
## read. The pane keeps its last picture under a paused overlay.
var stream_paused := false
var native_window_supported := false
var sandbox_enabled := false
var chromium_ready := false
var failure_reason := ""
## The owner can relaunch this stopped chromium with the pages it had open.
var restartable := false
## A relaunch was requested and the browser has not recovered yet.
var restarting := false
## The selected page's renderer died: the browser runs, the page needs a reload.
var page_crashed := false
## The selected page stopped answering: its renderer runs but is stuck.
var page_not_responding := false
var primary_page_id := -1
var page_tabs: Array = []
var selected_page_id := -1
var captured_page_id := -1
var chrome_revision := 0
var frames := 0
var _sequence := 0
var _queue: Array[Dictionary] = []
var _closing := false
var _preview_size := Vector2i.ZERO
var mouse_buttons := 0
var pending_motion: Dictionary = { }
var pressed_keys: Dictionary = { }
var last_pointer := Vector2.ZERO
var click_counts: Dictionary = { }


func set_status(source: String, args: Array) -> void:
	_status_source = source
	_status_args = args.duplicate()


func pin_title(value: String) -> void:
	pinned_title = value
	changed.emit()





func command(action: String, args: Dictionary = { }) -> int:
	_sequence += 1
	var item := args.duplicate(true)
	item.merge({ "id": _sequence, "action": action }, true)
	_queue.append(item)
	return _sequence


func open_native() -> void:
	if can_open_native(): command("chrome-native")


func can_open_native() -> bool:
	return native_window_supported and chromium_ready and not _closing and failure_reason.is_empty()


func change_text_size(direction: int) -> void:
	if not chromium_ready or _closing: return
	# Execute Chrome's own page zoom, independent of the client/server OS and
	# the page's JavaScript key handlers. CDP key input alone is not an accelerator.
	command("cdp", {"method": "Graffitty.zoom", "params": {"direction": signi(direction)}})


## Chromium's own find in page: it matches, highlights and scrolls the page,
## and reports `find_result`. A new query restarts; `find_next` steps through it.
func find(text: String, backward := false, find_next := false) -> void:
	if not chromium_ready or _closing or text.is_empty(): return
	_finding = true
	command("find", {"text": text, "backward": backward, "find_next": find_next})


## End find in page. Like Chrome's Escape, the active match stays selected
## unless `clear_selection`.
func stop_finding(clear_selection := false) -> void:
	find_result = {}
	_finding = false
	if not chromium_ready or _closing: return
	command("find-stop", {"clear_selection": clear_selection})


## Pages lay out at least this wide and scale down into narrower panes, like a
## desktop page fitted to a phone.
##
## Panes are often shown magnified, so a pane-sized viewport would show a
## phone layout with oversized text.
const FIT_WIDTH := 1280.0
const MAX_EXTENT := 4096.0


## The browser viewport for a pane: its aspect ratio, at least FIT_WIDTH wide.
static func viewport_for(pane: Vector2) -> Vector2i:
	var scale := maxf(1.0, FIT_WIDTH / maxf(pane.x, 1.0))
	# Keep the aspect ratio inside Chromium's maximum extent.
	scale = minf(scale, maxf(1.0, MAX_EXTENT / maxf(pane.y, 1.0)))
	return Vector2i((pane * scale).round()).clamp(Vector2i(64, 64), Vector2i(int(MAX_EXTENT), int(MAX_EXTENT)))


## Last pane size requested, replayed when the browser becomes ready or relaunches.
var _preview_request := Vector2.ZERO


func set_preview_size(size: Vector2) -> void:
	_preview_request = size
	# A stopped browser has no viewport; its relaunch replays the request.
	if not chromium_ready or native_visible or _closing or not failure_reason.is_empty():
		return
	var extent := viewport_for(size)
	if extent == _preview_size:
		return
	_preview_size = extent
	# Resizing is asynchronous. Keep only the latest unsent size while a pane
	# is dragged, rather than making Chromium replay every intermediate frame.
	for i in range(_queue.size() - 1, -1, -1):
		if _queue[i].action == "resize":
			_queue.remove_at(i)
	command("resize", { "width": extent.x, "height": extent.y })


func request(_action: String, _args: Dictionary = {}, _timeout_ms := 20000) -> Dictionary:
	return _unavailable()


func restart() -> Dictionary:
	return _unavailable()


## A crashed or stuck page gets a new renderer only by loading again; the
## owner picks the load that works for each.
func reload_failed_page() -> void:
	command("tab-reload", { "chromium_id": selected_page_id })
	command("chrome-state")


func _unavailable() -> Dictionary:
	return {"error": {"code": "chromium_unavailable", "message": "Chromium closed or timed out"}}



func return_to_preview() -> void:
	command("chrome-world")


func close() -> void:
	_closing = true
	_queue.clear()


func _exit_tree() -> void:
	close()


func retire() -> void:
	# Let pending API coroutines observe _closing and reply before freeing self.
	await get_tree().process_frame
	await get_tree().process_frame
	queue_free()



func _process(_dt: float) -> void:
	_flush_motion()


func _accept(request: Dictionary, result: Dictionary) -> void:
	if request.action == "chrome-state":
		chrome_revision += 1
		page_tabs = result.get("tabs", [])
		selected_page_id = int(result.get("chromiumId", -1))
		captured_page_id = int(result.get("capturedPageId", -1))
		page_crashed = false
		page_not_responding = false
		for page in page_tabs:
			if int(page.id) == selected_page_id:
				title = str(page.title)
				page_crashed = bool(page.get("crashed", false))
				page_not_responding = bool(page.get("notResponding", false))
		var was_ready := chromium_ready
		chromium_ready = int(result.get("chromiumId", -1)) >= 0
		if primary_page_id < 0:
			primary_page_id = int(result.get("chromiumId", -1))
		# State sent before a stop must not bring its result back.
		find_result = result.findResult if _finding and result.get("findResult") is Dictionary else {}
		native_visible = bool(result.get("nativeVisible", false))
		native_window_supported = bool(result.get("nativeWindowSupported", false))
		sandbox_enabled = bool(result.get("sandboxEnabled", false))
		status = "Native Chrome is open — return here to resume preview" if native_visible else "Click, type and scroll here · isolated profile"
		# Send the recorded pane size when the remote browser becomes ready.
		# Layout can finish before startup. Without this send, the page uses
		# its default viewport and stays letterboxed until the next resize.
		if chromium_ready and not was_ready and _preview_request != Vector2.ZERO:
			set_preview_size(_preview_request)


func _flush_motion() -> void:
	if pending_motion.is_empty():
		return
	var params := pending_motion
	pending_motion = { }
	_send_input("Input.dispatchMouseEvent", params)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED: changed.emit()
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		release_input()


## AppKit text bindings that Blink does not apply to CDP key events. Option
## word movement and deletion already work without a command.
static func mac_text_command(event: InputEventKey) -> String:
	if event.alt_pressed:
		return ""
	var select := "AndModifySelection" if event.shift_pressed else ""
	if event.meta_pressed and not event.ctrl_pressed:
		match event.keycode:
			KEY_LEFT: return "moveToBeginningOfLine" + select
			KEY_RIGHT: return "moveToEndOfLine" + select
			KEY_UP: return "moveToBeginningOfDocument" + select
			KEY_DOWN: return "moveToEndOfDocument" + select
			KEY_BACKSPACE: return "" if event.shift_pressed else "deleteToBeginningOfLine"
			KEY_DELETE: return "" if event.shift_pressed else "deleteToEndOfLine"
	elif event.ctrl_pressed and not event.meta_pressed:
		var motion := {
			KEY_A: "moveToBeginningOfParagraph", KEY_E: "moveToEndOfParagraph",
			KEY_B: "moveBackward", KEY_F: "moveForward", KEY_P: "moveUp", KEY_N: "moveDown",
		}
		if motion.has(event.keycode):
			return motion[event.keycode] + select
		if not event.shift_pressed:
			match event.keycode:
				KEY_D: return "deleteForward"
				KEY_H: return "deleteBackward"
				KEY_K: return "deleteToEndOfParagraph"
				KEY_T: return "transpose"
	return ""


func release_input() -> void:
	_flush_motion()
	for bit in [1, 2, 4]:
		if mouse_buttons & bit:
			mouse_buttons &= ~bit
			_send_input("Input.dispatchMouseEvent", {
				"type": "mouseReleased", "x": last_pointer.x, "y": last_pointer.y,
				"button": {1: "left", 2: "right", 4: "middle"}[bit], "buttons": mouse_buttons, "clickCount": 1,
			})
	for held in pressed_keys.values():
		var released: Dictionary = held.duplicate()
		released.type = "keyUp"
		released.erase("text")
		released.erase("commands")
		released.modifiers = 0
		_send_input("Input.dispatchKeyEvent", released)
	pressed_keys.clear()


func _input_viewport_size() -> Vector2:
	return Vector2(_preview_size) if _preview_size != Vector2i.ZERO else Vector2(1280, 720)


func _send_input(method: String, params: Dictionary) -> void:
	command("cdp", {"method": method, "params": params})


func remote_input(event: InputEvent, extent: Vector2) -> void:
	if not chromium_ready or texture == null:
		return
	var size := Vector2(texture.get_width(), texture.get_height())
	var scale := minf(extent.x / size.x, extent.y / size.y)
	if scale <= 0:
		return
	var modifiers := 0
	if event is InputEventWithModifiers:
		modifiers = int(event.alt_pressed) + int(event.ctrl_pressed) * 2 + int(event.meta_pressed) * 4 + int(event.shift_pressed) * 8
	if event is InputEventMouse or event is InputEventPanGesture:
		var pos: Vector2 = (event.position - (extent - size * scale) / 2.0) / scale
		var inside := Rect2(Vector2.ZERO, size).has_point(pos)
		if not inside and mouse_buttons == 0:
			return
		pos = pos.clamp(Vector2.ZERO, size - Vector2.ONE)
		pos *= _input_viewport_size() / size
		# Chromium has no canceled mouse-up. Release outside its viewport so a
		# second finger taking over for pinch cannot activate the pressed link.
		if event is InputEventMouseButton and event.canceled:
			pos = Vector2(-1, -1)
			pending_motion = {}
		last_pointer = pos
		var args := { "x": pos.x, "y": pos.y, "modifiers": modifiers, "type": "mouseMoved", "button": "none" }
		if event is InputEventPanGesture:
			args.type = "mouseWheel"
			# A dragging finger carries the page with it. Trackpads scroll by
			# native pixels; Godot's macOS backend scales those by 0.03.
			var delta: Vector2 = (
				-Vector2(event.get_meta("touch_travel")) / scale * _input_viewport_size() / size
				if event.has_meta("touch_travel")
				else event.delta / (0.03 if OS.get_name() == "macOS" else 1.0)
			)
			args.deltaX = delta.x
			args.deltaY = delta.y
			# Phases let Chromium stretch only under the fingers and bounce
			# briefly on momentum; unphased scrolling stops at the edge.
			# Trackpads carry AppKit's phases. A finger on a touchscreen carries
			# the touch recognizer's: began and changed under the finger,
			# changed while it glides, and one ended for the whole gesture.
			# That end closes the glide when there was one.
			var finger := str(event.get_meta("scroll_phase", ""))
			var momentum := str(event.get_meta("momentum_phase", ""))
			if event.has_meta("touch_travel"):
				if finger == "began": _touch_gliding = false
				if not momentum.is_empty(): _touch_gliding = true
				if finger == "ended" and _touch_gliding:
					finger = ""
					momentum = "ended"
					_touch_gliding = false
			if not finger.is_empty(): args.phase = finger
			if not momentum.is_empty(): args.momentumPhase = momentum
			# The rubber band's release velocity comes from event spacing.
			if event.has_meta("event_time"):
				args.eventTime = event.get_meta("event_time")
		elif event is InputEventMouseButton:
			if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
				if not event.pressed:
					return
				args.type = "mouseWheel"
				var distance: float = 80.0 * event.factor
				args.deltaX = -distance if event.button_index == MOUSE_BUTTON_WHEEL_LEFT else (distance if event.button_index == MOUSE_BUTTON_WHEEL_RIGHT else 0.0)
				args.deltaY = -distance if event.button_index == MOUSE_BUTTON_WHEEL_UP else (distance if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 0.0)
			else:
				var bit: int = { MOUSE_BUTTON_LEFT: 1, MOUSE_BUTTON_RIGHT: 2, MOUSE_BUTTON_MIDDLE: 4 }.get(event.button_index, 0)
				if bit == 0:
					return
				mouse_buttons = (mouse_buttons | bit) if event.pressed else (mouse_buttons & ~bit)
				args.type = "mousePressed" if event.pressed else "mouseReleased"
				if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
					context_menu_request = Crypto.new().generate_random_bytes(12).hex_encode()
					args["contextMenuRequest"] = context_menu_request
				args.button = { MOUSE_BUTTON_LEFT: "left", MOUSE_BUTTON_RIGHT: "right", MOUSE_BUTTON_MIDDLE: "middle" }[event.button_index]
				if event.pressed:
					click_counts[event.button_index] = 2 if event.double_click else 1
				args.clickCount = click_counts.get(event.button_index, 1)
		elif mouse_buttons != 0:
			args.button = "left" if mouse_buttons & 1 else ("right" if mouse_buttons & 2 else "middle")
		args.buttons = mouse_buttons
		if args.type == "mouseMoved":
			pending_motion = args
		else:
			_flush_motion()
			_send_input("Input.dispatchMouseEvent", args)
	elif event is InputEventKey:
		_flush_motion()
		var keys := {
			KEY_ENTER: ["Enter", 13], KEY_KP_ENTER: ["Enter", 13],
			KEY_BACKSPACE: ["Backspace", 8], KEY_TAB: ["Tab", 9], KEY_ESCAPE: ["Escape", 27],
			KEY_LEFT: ["ArrowLeft", 37], KEY_UP: ["ArrowUp", 38], KEY_RIGHT: ["ArrowRight", 39], KEY_DOWN: ["ArrowDown", 40],
			KEY_DELETE: ["Delete", 46], KEY_HOME: ["Home", 36], KEY_END: ["End", 35],
			KEY_PAGEUP: ["PageUp", 33], KEY_PAGEDOWN: ["PageDown", 34],
			KEY_SHIFT: ["Shift", 16], KEY_CTRL: ["Control", 17], KEY_ALT: ["Alt", 18], KEY_META: ["Meta", 91],
		}
		var key := String.chr(event.unicode) if event.unicode > 0 else OS.get_keycode_string(event.keycode).to_lower()
		var code: int = event.keycode if event.keycode < 128 else 0
		if keys.has(event.keycode):
			key = keys[event.keycode][0]
			code = keys[event.keycode][1]
		var args := { "type": "keyDown" if event.pressed else "keyUp", "modifiers": modifiers, "key": key, "windowsVirtualKeyCode": code, "autoRepeat": event.echo }
		# CDP needs the editing command as well as the macOS shortcut event.
		if event.pressed and not event.alt_pressed and (event.meta_pressed if OS.get_name() == "macOS" else event.ctrl_pressed):
			if event.keycode == KEY_A and not event.shift_pressed:
				args.commands = ["selectAll"]
			elif event.keycode == KEY_Z:
				args.commands = ["redo" if event.shift_pressed else "undo"]
			elif not event.shift_pressed and event.keycode in [KEY_C, KEY_X, KEY_V]:
				args.commands = [{KEY_C: "copy", KEY_X: "cut", KEY_V: "paste"}[event.keycode]]
		if event.pressed and OS.get_name() == "macOS" and not args.has("commands"):
			var command := mac_text_command(event)
			if not command.is_empty():
				args.commands = [command]
		if event.pressed and not event.ctrl_pressed and not event.meta_pressed and not event.alt_pressed:
			if event.keycode in [KEY_ENTER, KEY_KP_ENTER]:
				args.text = "\r"
			elif event.unicode >= 32:
				args.text = String.chr(event.unicode)
		if event.pressed:
			pressed_keys[event.keycode] = args
		else:
			pressed_keys.erase(event.keycode)
		_send_input("Input.dispatchKeyEvent", args)
