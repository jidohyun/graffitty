extends Node
## Android retains IME context; Latin keys and finished Hangul syllables stream,
## the open syllable and other composing scripts preview locally.
signal keyboard_height_changed(height: int)
var _keyboard_height := 0
var manager: Control
var bridge: JavaObject
var terminal_owner: Control
var epoch := 0
var preview := ""
var opened := false
var _modifier_session := ""
var _modifier_ack := 0
var _shared_dispatch := false
const NATIVE_KEYS := {67: KEY_BACKSPACE, 66: KEY_ENTER, 111: KEY_ESCAPE, 61: KEY_TAB, 19: KEY_UP, 20: KEY_DOWN, 21: KEY_LEFT, 22: KEY_RIGHT, 122: KEY_HOME, 123: KEY_END, 92: KEY_PAGEUP, 93: KEY_PAGEDOWN, 112: KEY_DELETE}
const NATIVE_PUNCTUATION := {62: KEY_SPACE, 55: KEY_COMMA, 56: KEY_PERIOD, 68: KEY_QUOTELEFT, 69: KEY_MINUS, 70: KEY_EQUAL, 71: KEY_BRACKETLEFT, 72: KEY_BRACKETRIGHT, 73: KEY_BACKSLASH, 74: KEY_SEMICOLON, 75: KEY_APOSTROPHE, 76: KEY_SLASH}

func _ready() -> void:
	if not OS.has_feature("android"): return
	var runtime = Engine.get_singleton("AndroidRuntime")
	var wrapper = Engine.get_singleton("JavaClassWrapper")
	bridge = wrapper.wrap("com.graffitty.input.TerminalIme").TerminalIme(runtime.getActivity(), get_instance_id())

func keyboard_height() -> int:
	return _keyboard_height

func _native_keyboard_height(height: int) -> void:
	var measured := height if height >= 0 else DisplayServer.virtual_keyboard_get_height()
	if measured == _keyboard_height: return
	_keyboard_height = measured
	keyboard_height_changed.emit(measured)

func _exit_tree() -> void:
	if bridge != null: bridge.dispose()

func check_owner() -> void:
	if opened and terminal_owner != _terminal(): hide()

func _terminal() -> Control:
	if manager.view == null or not is_instance_valid(manager.view.host): return null
	var host = manager.view.host
	if manager.dialog.visible or manager.chooser.visible or host.command_line_open(): return null
	if not host.is_terminal_pane(host.pane_focus) or not host.sessions.has(host.active_session_id): return null
	return host.sessions[host.active_session_id].term

func open() -> bool:
	if bridge == null: return false
	terminal_owner = _terminal()
	if not is_instance_valid(terminal_owner): return false
	epoch += 1
	preview = ""
	opened = true
	bridge.open(epoch)
	return true

func hide() -> void:
	epoch += 1
	opened = false
	preview = ""
	if is_instance_valid(terminal_owner): terminal_owner.set_preedit("", Vector2i.ZERO)
	if bridge != null: bridge.close(epoch)
	terminal_owner = null
	_modifier_session = ""

func reset(shortcut: bool) -> void:
	if not opened: return
	epoch += 1
	preview = ""
	if is_instance_valid(terminal_owner): terminal_owner.set_preedit("", Vector2i.ZERO)
	bridge.reset(epoch, shortcut)

func finish_composition() -> void:
	if not opened or preview.is_empty(): return
	var text := preview
	reset(false)
	# Accessory keys finalize text before changing modifiers or sending a key.
	_send_text(text, false)

func _native_event(generation: int, committed: String, composing: String, native_key: int, modifiers: int, unicode: int, before_shared_key := false) -> void:
	if generation != epoch or not opened or terminal_owner != _terminal(): return
	# Keep the old preview until it changes. Clearing and replaying an identical
	# preview turns repeated IME notifications into another typing burst.
	if not committed.is_empty() or native_key != 0:
		preview = ""
		terminal_owner.set_preedit("", Vector2i.ZERO)
	# Text composed before a shared shortcut must not consume its one-shot mask.
	_send_text(committed, not before_shared_key)
	if NATIVE_KEYS.has(native_key):
		_send_key(NATIVE_KEYS[native_key], 0, true, modifiers)
	elif unicode >= 32 and unicode < 127:
		_send_key(String.chr(unicode).to_upper().unicode_at(0), unicode, true, modifiers)
	# A shortcut may have reset the native editor while dispatching its letter.
	if generation != epoch: return
	preview = composing
	terminal_owner.set_preedit(preview, Vector2i.ZERO)

func _native_image(generation: int, result: String) -> void:
	if generation != epoch or not opened or terminal_owner != _terminal(): return
	# Native content permission is held only while Java reads the URI. Rust
	# validates these bytes and uses the same attachment route as Paste.
	var value: Variant = JSON.parse_string(result)
	if not value is Dictionary: return
	if value.has("image"):
		terminal_owner.paste_image_base64(str(value.image))
	elif value.has("error"):
		get_node("/root/TerminalApplication").notifications.post(tr("Paste"), tr("Could not paste image"), manager.view.host, "error", 8.0, "", {"title": "Paste", "body": "Could not paste image"})
		push_warning(str(value.error))

func _send_text(text: String, through_input: bool) -> void:
	for ch in text:
		var unicode := ch.unicode_at(0)
		var code := ch.to_upper().unicode_at(0) if unicode >= 32 and unicode < 127 else 0
		if ch == "\n": code = KEY_ENTER
		_send_key(code, unicode, through_input)

func _send_key(code: int, unicode: int, through_input: bool, modifiers := 0) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.unicode = unicode
		event.ctrl_pressed = bool(modifiers & 1)
		event.alt_pressed = bool(modifiers & 2)
		event.shift_pressed = bool(modifiers & 4)
		event.meta_pressed = bool(modifiers & 8)
		event.pressed = down
		if through_input: Input.parse_input_event(event)
		elif is_instance_valid(terminal_owner): terminal_owner.send_key(event)

func shared_key_in_progress() -> bool:
	return _shared_dispatch

func _modifier_bar() -> Control:
	return manager.keybar if is_instance_valid(manager) else null

func publish_shared_modifiers() -> void:
	var bar := _modifier_bar()
	if bridge == null or not opened or _modifier_session.is_empty() or not is_instance_valid(bar): return
	var masks: Vector2i = bar.modifier_masks()
	bridge.modifierState(epoch, _modifier_session, _modifier_ack, masks.x, masks.y)

func _native_modifier_command(generation: int, session: String, sequence: int, operation: String, bit: int) -> void:
	if generation != epoch or not opened or terminal_owner != _terminal(): return
	var bar := _modifier_bar()
	if not is_instance_valid(bar): return
	if operation == "hello":
		_modifier_session = session
		if not bar.modifiers_changed.is_connected(publish_shared_modifiers):
			bar.modifiers_changed.connect(publish_shared_modifiers)
	elif session != _modifier_session: return
	_modifier_ack = sequence
	_shared_dispatch = true
	if operation == "cycle":
		bar.cycle_modifier({1: "ctrl", 2: "alt", 4: "shift"}.get(bit, ""))
	elif operation == "bye":
		_modifier_session = ""
		# An editor restart detaches the keyboard, not the toolbar's selection.
		# The next handshake receives the application's still-authoritative state.
	_shared_dispatch = false
	publish_shared_modifiers()

func _native_shared_key(generation: int, session: String, sequence: int, native_key: int, modifiers: int, unicode: int, edge: int) -> void:
	if generation != epoch or not opened or terminal_owner != _terminal() or session != _modifier_session: return
	var code: int = NATIVE_KEYS.get(native_key, KEY_NONE)
	if native_key >= 29 and native_key <= 54: code = KEY_A + native_key - 29
	elif native_key >= 7 and native_key <= 16: code = KEY_0 + native_key - 7
	elif NATIVE_PUNCTUATION.has(native_key): code = NATIVE_PUNCTUATION[native_key]
	if code == KEY_NONE and unicode >= 32 and unicode < 127:
		code = String.chr(unicode).to_upper().unicode_at(0)
	if code == KEY_NONE: return
	_modifier_ack = sequence
	var event := InputEventKey.new()
	event.keycode = code
	event.unicode = unicode
	event.ctrl_pressed = bool(modifiers & 1)
	event.alt_pressed = bool(modifiers & 2)
	event.shift_pressed = bool(modifiers & 4)
	event.pressed = edge != 3
	event.echo = edge == 2
	_shared_dispatch = true
	_dispatch_shared_key(event)
	_shared_dispatch = false
	publish_shared_modifiers()

func _dispatch_shared_key(event: InputEventKey) -> void:
	Input.parse_input_event(event)
