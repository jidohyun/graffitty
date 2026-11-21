extends PanelContainer
## Terminal accessory keys. Modifiers cycle off -> next key -> locked -> off.
const DesktopText := preload("res://scenes/DesktopText.gd")
signal modifiers_changed
var host: Node
var connection: Node
var terminal_ime: Node
var modifiers := {}
var locked_modifiers := {}
var pressed_keys := {}
var pointer_chords := {}
var buttons := {}
var selected_session := -1
var armed_style := StyleBoxFlat.new()
var locked_style := StyleBoxFlat.new()
const Face := preload("res://scenes/input/TouchFace.gd")
## Built-in keys: label, key code, accessible name. Icons live in the
## touch-controls mod; text keys keep their label here for layout and access.
const KEYS := {
	"escape": ["Esc", KEY_ESCAPE, "Escape"], "tab": ["", KEY_TAB, "Tab"],
	"ctrl": ["Ctrl", KEY_CTRL, "Control"], "alt": ["Alt", KEY_ALT, "Alt"],
	"shift": ["", KEY_SHIFT, "Shift"], "left": ["", KEY_LEFT, "Left"],
	"down": ["", KEY_DOWN, "Down"], "up": ["", KEY_UP, "Up"], "right": ["", KEY_RIGHT, "Right"],
	"home": ["Home", KEY_HOME, "Home"], "end": ["End", KEY_END, "End"],
	"page_up": ["PgUp", KEY_PAGEUP, "Page Up"], "page_down": ["PgDn", KEY_PAGEDOWN, "Page Down"],
	"copy": ["", KEY_NONE, "Copy"], "paste": ["", KEY_NONE, "Paste"],
}
## Built-in keys that tap a registry action instead of sending a key.
const ACTIONS := {"copy": "Copy", "paste": "Paste"}
## The keys shown, from client.toml `[touch] keys`; tests may set it before _ready.
var layout: Array = []
## Keep the strip right-aligned when it fits. Start at its left end when
## it is wider than the screen.
##
## Dragging shifts the strip between two positions: its right end at the
## screen's right edge, or its left end at the middle. On a wide or unfolded
## screen, that second position brings left-hand keys under the right thumb.
var track: Control
var row: HBoxContainer
## Where the strip's left end is in `track`; kept until the width changes.
var strip_left := 0.0
var track_width := -1.0
## The finger that may slide the strip: where it landed, and whether it has moved far enough to be a slide, not a tap.
var swipe_index := -1
var swipe_from := 0.0
var swiping := false
## The strip scrolls like the other touch lists (`ElasticScroller`): a flick
## glides on and slows down, and past either end the strip stretches with the
## rubber band and springs back.
var elastic: RefCounted = ClassDB.instantiate("ElasticScroller")
## The rubber band's pull in pixels; positive pulls the strip further left.
var stretch := 0.0
var last_swipe := 0.0
var gliding: bool:
	get: return elastic.is_flinging()
## Tests inject a clock; interactive clients keep the monotonic real one.
var clock_msec: Callable = Time.get_ticks_msec
const SWIPE_SLOP := 8.0
const HEIGHT := 36.0
const LOCKED_COLOR := Color(0.58, 0.82, 1.0)
# Match SwiftKey's programming arrows: long press, then 80 ms down to 20 ms.
const ARROW_HOLD_DELAY := 0.45
var held_arrow: InputEventKey
var held_target: Node
var held_button: BaseButton
var repeat_remaining := 0.0
var repeat_count := 0

func _ready() -> void:
	name = "TouchKeyBar"
	set_process(false)
	visibility_changed.connect(func():
		if not is_visible_in_tree():
				stop_arrow()
				stop_glide()
				swipe_index = -1)
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top = -HEIGHT
	armed_style.bg_color = Color(0.24, 0.26, 0.30)
	armed_style.border_color = Color(0.60, 0.63, 0.68, 0.6)
	armed_style.set_border_width_all(1)
	armed_style.set_corner_radius_all(4)
	locked_style.bg_color = Color(0.10, 0.25, 0.40)
	locked_style.border_color = LOCKED_COLOR
	locked_style.set_border_width_all(1)
	locked_style.set_corner_radius_all(4)
	elastic.horizontal = true
	track = Control.new()
	track.clip_contents = true
	track.custom_minimum_size.y = HEIGHT
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(track)
	row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	track.add_child(row)
	track.resized.connect(_place_strip)
	row.minimum_size_changed.connect(_place_strip)
	if layout.is_empty():
		layout = preload("res://config/UserConfig.gd").touch_config(OS.get_cmdline_user_args()).keys
	for index in layout.size():
		var entry = layout[index]
		var button := _key_button(entry, index)
		if button == null: continue
		button.gui_input.connect(_gui_input)
		buttons[button.name] = button
		row.add_child(button)
		if button.toggle_mode: _refresh_modifier(button.name)
	hide()

## The strip's left end may be anywhere from `x` (right end on the screen's
## right edge) to `y` (left end at mid-screen); equal when it cannot slide.
func strip_range() -> Vector2:
	var low := track.size.x - row.get_combined_minimum_size().x
	return Vector2(low, maxf(low, track.size.x / 2.0))

func slide_strip(left: float) -> void:
	var limits := strip_range()
	strip_left = clampf(left, limits.x, limits.y)
	row.position = Vector2(roundf(strip_left - stretch), 0)

## The strip as a scroller: offset, range and visible width. The offset grows
## as the strip moves left, from 0 (left end at mid-screen).
func _scroll_state() -> Vector3:
	var limits := strip_range()
	elastic.fixed_time = clock_msec.call() / 1000.0
	return Vector3(limits.y - strip_left, limits.y - limits.x, track.size.x)

func _scroll_to(offset: float) -> void:
	var limits := strip_range()
	stretch = elastic.get_stretch()
	slide_strip(limits.x if offset >= limits.y - limits.x else limits.y - offset)
	set_process(elastic.is_active() or held_arrow != null)

## A new width (rotation, fold, first layout) returns the strip to rest.
func _place_strip() -> void:
	row.size = Vector2(row.get_combined_minimum_size().x, track.size.y)
	if track.size.x != track_width:
		track_width = track.size.x
		stop_glide()
		strip_left = maxf(0.0, strip_range().x)
	slide_strip(strip_left)

## One strip key: a built-in key name, or {label, action, text} that taps an action.
func _key_button(entry: Variant, index: int) -> Button:
	var button := Button.new()
	var icon_key := ""
	if entry is String and KEYS.has(entry):
		var spec: Array = KEYS[entry]
		button.name = entry
		button.text = spec[0]
		button.tooltip_text = spec[2]
		if spec[0].is_empty():
			icon_key = entry
			# A placeholder of the real icon size keeps the button's measured size.
			button.icon = PlaceholderTexture2D.new()
			(button.icon as PlaceholderTexture2D).size = Vector2(24, 24)
	elif entry is Dictionary and entry.has("action"):
		button.name = "action_%d" % index
		button.text = str(entry.get("label", ""))
		button.tooltip_text = button.text
	else:
		push_warning("Unknown touch key: %s" % [entry])
		return null
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(36, HEIGHT)
	button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	button.add_theme_font_size_override("font_size", DesktopText.size(14))
	# Android's emulated mouse remains over the last tapped button. A hover
	# must not look like a latched Esc/Tab or a consumed modifier.
	button.add_theme_stylebox_override("hover", get_theme_stylebox("normal", "Button"))
	button.add_theme_color_override("font_hover_color", get_theme_color("font_color", "Button"))
	button.add_theme_color_override("icon_hover_color", get_theme_color("icon_normal_color", "Button"))
	var face := {"part": "key", "locked": false, "locked_color": Face.hex(LOCKED_COLOR)}
	if entry is String: face["key"] = entry
	else: face["label"] = button.text
	Face.attach(button, face, icon_key.is_empty())
	if entry is Dictionary:
		var params := {"text": str(entry.text)} if entry.get("text") != null else {}
		button.pressed.connect(func():
			if is_instance_valid(host): preload("res://scenes/HostActions.gd").run(host, str(entry.action), params))
		return button
	if ACTIONS.has(entry):
		button.pressed.connect(func():
			if is_instance_valid(host): preload("res://scenes/HostActions.gd").run(host, ACTIONS[entry]))
		return button
	var code: int = KEYS[entry][1]
	button.toggle_mode = entry in ["alt", "ctrl", "shift"]
	if button.toggle_mode:
		button.toggled.connect(func(_enabled): cycle_modifier(entry))
	elif code in [KEY_LEFT, KEY_DOWN, KEY_UP, KEY_RIGHT]:
		button.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
		button.button_up.connect(stop_arrow)
		button.mouse_exited.connect(stop_arrow)
		button.gui_input.connect(arrow_input.bind(code, button))
	else:
		button.pressed.connect(press_key.bind(code))
	return button

func cycle_modifier(key: String) -> void:
	if key not in ["ctrl", "alt", "shift"]: return
	if key in ["ctrl", "alt"] and is_instance_valid(terminal_ime): terminal_ime.finish_composition()
	# Synchronize tab changes before arming a new one-shot modifier. Locked
	# modifiers stay active until explicitly released, including across tabs.
	update_host()
	if locked_modifiers.has(key):
		locked_modifiers.erase(key)
		modifiers.erase(key)
	elif modifiers.get(key, false):
		locked_modifiers[key] = true
	else:
		modifiers[key] = true
	_refresh_modifier(key)
	modifiers_changed.emit()
	if key in ["ctrl", "alt"]: reset_keyboard_buffer()

func _shared_key_in_progress() -> bool:
	return is_instance_valid(terminal_ime) and terminal_ime.has_method("shared_key_in_progress") and terminal_ime.shared_key_in_progress()

func reset_keyboard_buffer() -> void:
	# The negotiated IME channel finalizes its native editor before dispatch.
	# Restarting it here would invalidate the remainder of the held gesture.
	if _shared_key_in_progress(): return
	if is_instance_valid(terminal_ime) and terminal_ime.opened:
		terminal_ime.reset(modifiers.get("ctrl", false) or modifiers.get("alt", false) or modifiers.get("meta", false))
		return
	# Godot's Android EditText retains composing text after emitting its keys. A
	# terminal shortcut consumes that text outside EditText; without clearing it,
	# the IME can later replace/recommit the shortcut letter as plain text.
	#
	# Reopening the visible keyboard with empty text resets it with its text
	# listener detached, so the reset itself emits no Backspace or text events.
	if OS.get_name() == "Android" and DisplayServer.virtual_keyboard_get_height() > 0:
		DisplayServer.virtual_keyboard_show("", Rect2(), DisplayServer.KEYBOARD_TYPE_MULTILINE)

func _refresh_modifier(key: String) -> void:
	if not buttons.has(key): return
	var button: Button = buttons[key]
	var locked: bool = locked_modifiers.get(key, false)
	button.set_pressed_no_signal(modifiers.get(key, false))
	for state in ["pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, locked_style if locked else armed_style)
	Face.update(button, {"locked": locked})

func update_host() -> void:
	if not is_instance_valid(host): return
	var id: int = host.active_session_id
	if id == selected_session: return
	stop_arrow()
	pressed_keys.clear()
	selected_session = id
	clear_modifiers(true)

func clear_modifiers(keep_locked := false) -> void:
	if not keep_locked: locked_modifiers.clear()
	modifiers = locked_modifiers.duplicate()
	for key in buttons:
		if buttons[key].toggle_mode: _refresh_modifier(key)
	modifiers_changed.emit()

func modifier_masks() -> Vector2i:
	var result := Vector2i.ZERO
	for entry in [["ctrl", 1], ["alt", 2], ["shift", 4]]:
		if modifiers.get(entry[0], false): result.x |= entry[1]
		if locked_modifiers.get(entry[0], false): result.y |= entry[1]
	return result

func key_identity(event: InputEventKey) -> int:
	if event.physical_keycode not in [KEY_NONE, KEY_UNKNOWN]: return event.physical_keycode
	if event.keycode not in [KEY_NONE, KEY_UNKNOWN]: return event.keycode
	return String.chr(event.unicode).to_upper().unicode_at(0) if event.unicode > 0 else 0

func apply_modifiers(event: InputEventKey) -> void:
	if event.keycode in [KEY_META, KEY_ALT, KEY_CTRL, KEY_SHIFT]: return
	update_host()
	# IMEs can commit text without a logical keycode. Normalize printable ASCII
	# before workspace shortcuts, including the unmodified command after Ctrl+A.
	# Preserve actual layout keycodes and non-ASCII composition events.
	if event.keycode in [KEY_NONE, KEY_UNKNOWN] and event.unicode >= 32 and event.unicode < 127:
		event.keycode = String.chr(event.unicode).to_upper().unicode_at(0)
	var identity := key_identity(event)
	if identity == 0 and not event.pressed and pressed_keys.size() == 1:
		identity = pressed_keys.keys()[0]
	if pressed_keys.has(identity) and (not event.pressed or event.echo):
		var previous: InputEventKey = pressed_keys[identity]
		event.meta_pressed = previous.meta_pressed
		event.alt_pressed = previous.alt_pressed
		event.ctrl_pressed = previous.ctrl_pressed
		event.shift_pressed = previous.shift_pressed
		event.keycode = previous.keycode
		if event.unicode > 0: event.unicode = previous.unicode
		if not event.pressed: pressed_keys.erase(identity)
		return
	# Some Android IMEs emit text presses without releases. A fresh press must
	# never inherit a modifier from an earlier committed character.
	if event.pressed and not event.echo: pressed_keys.erase(identity)
	if (not visible and not _shared_key_in_progress()) or not event.pressed or not modifiers.values().has(true): return
	event.meta_pressed = event.meta_pressed or modifiers.get("meta", false)
	event.alt_pressed = event.alt_pressed or modifiers.get("alt", false)
	event.ctrl_pressed = event.ctrl_pressed or modifiers.get("ctrl", false)
	event.shift_pressed = event.shift_pressed or modifiers.get("shift", false)
	if modifiers.get("shift", false) and event.unicode > 0:
		event.unicode = String.chr(event.unicode).to_upper().unicode_at(0)
	pressed_keys[identity] = event.duplicate()
	var reset_ime := event.ctrl_pressed or event.alt_pressed or event.meta_pressed
	clear_modifiers(true)
	if reset_ime: reset_keyboard_buffer()

## Called only for pane content, never toolbar/control clicks. One-shot state
## belongs to the complete press/move/release chord, not just its first packet.
func apply_pointer_modifiers(event: InputEvent, target: String) -> void:
	if not (event is InputEventMouse or event is InputEventPanGesture): return
	var chord: Dictionary = pointer_chords.get(target, {}).duplicate()
	if event is InputEventMouseButton and event.pressed and not event.canceled:
		if chord.is_empty() and visible:
			chord = modifiers.duplicate()
			if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT]:
				chord["_held"] = true
				pointer_chords[target] = chord.duplicate()
			clear_modifiers(true)
	elif chord.is_empty() and visible:
		chord = modifiers.duplicate()
	for modifier in ["ctrl", "alt", "shift", "meta"]:
		var property: String = modifier + "_pressed"
		event.set(property, bool(event.get(property)) or chord.get(modifier, false))
	if event is InputEventMouseButton and not event.pressed and event.button_mask == 0:
		pointer_chords.erase(target)

## Whether a finger dragged over a terminal should select rather than scroll:
## Shift is armed or locked, and apply_pointer_modifiers will attach it.
func shift_drag_selects() -> bool:
	return visible and modifiers.get("shift", false)

func cancel_pointer(target: String) -> void:
	pointer_chords.erase(target)

func key_target() -> Node:
	if not is_instance_valid(host): return null
	if host.command_line_open(): return host.command_line
	if host.has_method("is_chromium_pane") and host.is_chromium_pane(host.pane_focus):
		return host.chromiums.get(int(host.pane_focus.substr(1)))
	if not host.is_terminal_pane(host.pane_focus): return null
	var id: int = host.active_session_id
	return host.sessions[id].term if host.sessions.has(id) else null

func send_key(target: Node, key: InputEventKey) -> void:
	var event: InputEventKey = key.duplicate()
	var command_line: bool = is_instance_valid(host) and host.command_line_open()
	if command_line:
		# Esc, Tab and the arrows drive the open command line, not the terminal.
		target.handle_key(event)
	elif target.has_method("remote_input"):
		target.remote_input(event, target.texture.get_size() if target.texture != null else Vector2.ONE)
	else:
		target.send_key(event)
	event.pressed = false
	apply_modifiers(event)
	if not command_line and is_instance_valid(target):
		if target.has_method("remote_input"):
			target.remote_input(event, target.texture.get_size() if target.texture != null else Vector2.ONE)
		else: target.send_key(event)

func press_key(code: int) -> void:
	if is_instance_valid(terminal_ime): terminal_ime.finish_composition()
	update_host()
	var target := key_target()
	if not is_instance_valid(target): return
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	apply_modifiers(event)
	send_key(target, event)

func start_arrow(code: int, button: BaseButton) -> void:
	stop_arrow()
	if is_instance_valid(terminal_ime): terminal_ime.finish_composition()
	update_host()
	var target := key_target()
	if not is_instance_valid(target): return
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	apply_modifiers(event)
	# Consume one-shot modifiers once, keeping that chord for the entire hold.
	held_arrow = event
	held_target = target
	held_button = button
	repeat_remaining = ARROW_HOLD_DELAY
	set_process(true)
	send_key(target, event)

func stop_arrow() -> void:
	held_arrow = null
	held_target = null
	held_button = null
	repeat_count = 0
	set_process(elastic.is_active())

func stop_glide() -> void:
	elastic.stop()
	if stretch != 0.0:
		stretch = 0.0
		slide_strip(strip_left)
	set_process(held_arrow != null)

func arrow_input(event: InputEvent, code: int, button: BaseButton) -> void:
	# Android delivers an emulated mouse press before the original touch. The
	# button's pressed signal can fire for both, so start from the original event.
	if event.device == -1: return
	# A touch that brakes a gliding strip is not a key press.
	if swiping: return
	if event is InputEventScreenTouch:
		if event.pressed and not event.canceled: start_arrow(code, button)
		else: stop_arrow()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed: start_arrow(code, button)
		else: stop_arrow()
	elif event is InputEventScreenDrag or event is InputEventMouseMotion:
		if not Rect2(Vector2.ZERO, button.size).has_point(event.position): stop_arrow()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		if absf(event.delta.x) < absf(event.delta.y) and not elastic.is_active(): return
		var state := _scroll_state()
		_scroll_to(elastic.pan(event, event.delta.x, state.x, state.y, state.z))
		accept_event()

func _input(event: InputEvent) -> void:
	# Also catch release outside the button and a second finger interrupting it.
	if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed):
		stop_arrow()
	# A sideways drag slides the strip, also when it starts on a key.
	#
	# Keys keep their own input; once the touch is a slide, their pending press
	# is cancelled, so it neither taps a key nor latches a modifier.
	if event is InputEventScreenTouch:
		if not event.pressed:
			if event.index == swipe_index:
				swipe_index = -1
				# A slide flicks on; a tap or a cancel only releases any pull.
				var state := _scroll_state()
				elastic.touch_end(state.x, state.y, state.z, swiping and not event.canceled)
				_scroll_to(state.x)
				swiping = false
		elif swipe_index == -1 and is_visible_in_tree() and get_global_rect().has_point(event.position):
			swipe_index = event.index
			swipe_from = event.position.x
			last_swipe = swipe_from
			# Touching a gliding strip brakes it; that touch taps no key. The
			# key sees the press after this, so cancel it once it has.
			swiping = gliding
			if gliding: row.propagate_notification.call_deferred(NOTIFICATION_SCROLL_BEGIN)
			var state := _scroll_state()
			elastic.touch_begin()
			_scroll_to(state.x)
	elif event is InputEventScreenDrag and event.index == swipe_index:
		var moved: float = event.position.x - swipe_from
		# A strip that cannot slide still stretches under the finger.
		if not swiping and absf(moved) > SWIPE_SLOP:
			swiping = true
			stop_arrow()
			row.propagate_notification(NOTIFICATION_SCROLL_BEGIN)
			# The slop distance moves the strip too.
			last_swipe = swipe_from
		if swiping:
			var state := _scroll_state()
			_scroll_to(elastic.touch_move(Vector2(event.position.x - last_swipe, 0), state.x, state.y, state.z))
		last_swipe = event.position.x

func _notification(what: int) -> void:
	var profiled_started := Time.get_ticks_usec()
	_notification_body(what)
	preload("res://graffitty/frame_profile.gd").add("TouchKeyBar._notification", Time.get_ticks_usec() - profiled_started)


func _notification_body(what: int) -> void:
	if what in [NOTIFICATION_WM_WINDOW_FOCUS_OUT, NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_EXIT_TREE]:
		stop_arrow()
		stop_glide()
		pointer_chords.clear()
		clear_modifiers()

func _process(delta: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(delta)
	preload("res://graffitty/frame_profile.gd").add("TouchKeyBar", Time.get_ticks_usec() - profiled_started)


func _process_body(delta: float) -> void:
	update_host()
	if elastic.is_active():
		var state := _scroll_state()
		_scroll_to(elastic.advance(state.x, state.y, state.z))
	if held_arrow == null: return
	if not is_visible_in_tree() or not is_instance_valid(held_button) or not held_button.button_pressed or not is_instance_valid(held_target) or key_target() != held_target:
		stop_arrow()
		return
	repeat_remaining -= delta
	# Keep fractional frame time for a smooth 50 Hz maximum without catching up
	# a long stalled frame with a burst of terminal input.
	if repeat_remaining > 0.0: return
	var event := held_arrow
	var target := held_target
	var interval := maxf(0.02, 0.08 - repeat_count * 0.005)
	repeat_remaining = interval if repeat_remaining < -interval else repeat_remaining + interval
	repeat_count += 1
	send_key(target, event)
