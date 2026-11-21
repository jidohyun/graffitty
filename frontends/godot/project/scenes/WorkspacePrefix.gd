extends RefCounted
## Client-local, one-shot `Prefix+…` sequences; repeated prefixes reach the pane.
## Sequences run the shared actions in HostActions.gd, like menus, direct
## shortcuts and the command line.
const HostActions := preload("res://scenes/HostActions.gd")
var host: Node
var settings
var active := false
var held: Dictionary = {}
var _last_trigger: InputEventKey
var filetree := preload("res://scenes/WorkspaceFiletree.gd").new()

func focus_lost() -> void:
	held.clear()
	_last_trigger = null
	cancel()
	# The command line the prefix opened closes with it.
	if host.has_method("command_line_open") and host.command_line_open():
		host.command_line.dismiss()

func cancel() -> void:
	active = false
	host.ui_changed.emit()

func toggle() -> void:
	if settings.key == KEY_NONE:
		return
	_last_trigger = null
	active = not active
	host.ui_changed.emit()

func handle(event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	if not event.pressed:
		if held.has(event.keycode):
			held.erase(event.keycode)
			return true
		return false
	if held.has(event.keycode):
		if event.echo:
			return true
		# A fresh press means the release was lost; some Android keyboards
		# never send one, which would otherwise swallow this key for good.
		held.erase(event.keycode)
	# The prefix must not steal Select All from UI editors.
	if text_input_focused(host):
		if active: cancel()
		return false
	var trigger = preload("res://graffitty/terminal_config.gd").KeyBinding.new(settings.key, "").key
	if settings.key != KEY_NONE and trigger != null and trigger.is_match(event, true):
		held[event.keycode] = true
		if active:
			cancel()
			_send_key(event)
		else:
			toggle()
			_last_trigger = event.duplicate()
		return true
	if not active:
		return false
	held[event.keycode] = true
	if event.echo:
		return true
	# Modifier transitions do not cancel a prefix after releasing Command or Control.
	if event.keycode in [KEY_META, KEY_CTRL, KEY_ALT, KEY_SHIFT]:
		return true
	var key: int = event.get_keycode_with_modifiers()
	var typed = command_line_text(event)
	if key == (settings.key & KEY_CODE_MASK):
		cancel()
		send_prefix()
	elif key == KEY_ESCAPE:
		cancel()
	elif typed != null:
		# Target selectors start with their character; `:` starts empty.
		cancel()
		host.open_command_line(typed)
	else:
		var action: String = settings.bindings.get(key, "")
		if action.is_empty():
			var character: int = ClassDB.class_call_static("ClientConfig", "prefix_punctuation",
				event.unicode, event.ctrl_pressed, event.alt_pressed, event.meta_pressed)
			action = settings.bindings.get(character, "")
		cancel()
		if action == "SendPrefix":
			send_prefix()
		elif not action.is_empty():
			HostActions.run(host, action)
	return true


## A UI text control has keyboard focus. Offscreen chromium chrome owns focus
## in its own viewport, not the window.
static func text_input_focused(owner: Node) -> bool:
	if not owner.is_inside_tree():
		return false
	var focus: Array[Control] = [owner.get_viewport().gui_get_focus_owner()]
	if "workspace_view" in owner and is_instance_valid(owner.workspace_view):
		focus.append(owner.workspace_view.canvas.gui_get_focus_owner())
	for control in focus:
		if is_instance_valid(control) and control.is_visible_in_tree() and (control is LineEdit or control is TextEdit or control is RichTextLabel):
			return true
	return false

## What a key types into the command line it opens: a digit or `%`, `@`, `$`,
## "" for `:`, or null for any other key.
##
## The typed character decides first, so layouts with `:` or the digits
## elsewhere (AZERTY, German) work; replays send no unicode.
static func command_line_text(event: InputEventKey) -> Variant:
	if event.ctrl_pressed or event.meta_pressed or event.alt_pressed:
		return null
	if event.unicode > 0:
		var character := String.chr(event.unicode)
		if character == ":":
			return ""
		return character if character in "0123456789%@$" else null
	if event.keycode == KEY_COLON or (event.keycode == KEY_SEMICOLON and event.shift_pressed):
		return ""
	if event.keycode == KEY_PERCENT or (event.keycode == KEY_5 and event.shift_pressed):
		return "%"
	if event.keycode == KEY_DOLLAR or (event.keycode == KEY_4 and event.shift_pressed):
		return "$"
	if event.keycode == KEY_AT or (event.keycode == KEY_2 and event.shift_pressed):
		return "@"
	if event.keycode >= KEY_0 and event.keycode <= KEY_9 and not event.shift_pressed:
		return str(event.keycode - KEY_0)
	return null

## The prefix sequence bound to `action`, such as "⌃A, C", or "".
func shortcut_label(action: String) -> String:
	if settings.key == KEY_NONE:
		return ""
	for key in settings.bindings:
		if settings.bindings[key] == action:
			return "%s, %s" % [key_label(settings.key), key_label(key)]
	return ""

## A key combination as the platform writes it: ⌃⌥⇧⌘ symbols in Apple's order
## on macOS (⇧⌘T), named modifiers elsewhere.
static func key_label(key: int, mac := OS.get_name() == "macOS") -> String:
	var code := key & KEY_CODE_MASK
	var names := {
		KEY_BACKSLASH: "\\", KEY_MINUS: "-", KEY_BAR: "|", KEY_UNDERSCORE: "_",
		KEY_EQUAL: "=", KEY_PLUS: "+", KEY_COMMA: ",", KEY_PERIOD: ".", KEY_SLASH: "/",
		KEY_SEMICOLON: ";", KEY_APOSTROPHE: "'", KEY_BRACKETLEFT: "[", KEY_BRACKETRIGHT: "]",
		KEY_QUOTELEFT: "`",
	}
	if mac:
		names.merge({
			KEY_ENTER: "↩", KEY_KP_ENTER: "⌤", KEY_ESCAPE: "⎋", KEY_TAB: "⇥",
			KEY_BACKSPACE: "⌫", KEY_DELETE: "⌦", KEY_LEFT: "←", KEY_RIGHT: "→",
			KEY_UP: "↑", KEY_DOWN: "↓", KEY_HOME: "↖", KEY_END: "↘",
			KEY_PAGEUP: "⇞", KEY_PAGEDOWN: "⇟",
		})
	var label: String = names.get(code, OS.get_keycode_string(code))
	if mac:
		var symbols := ""
		for modifier in [[KEY_MASK_CTRL, "⌃"], [KEY_MASK_ALT, "⌥"], [KEY_MASK_SHIFT, "⇧"], [KEY_MASK_META, "⌘"]]:
			if key & modifier[0]:
				symbols += modifier[1]
		return symbols + label
	var parts := PackedStringArray()
	if key & KEY_MASK_CTRL: parts.append("Ctrl")
	if key & KEY_MASK_ALT: parts.append("Alt")
	if key & KEY_MASK_SHIFT: parts.append("Shift")
	if key & KEY_MASK_META: parts.append("Win" if OS.get_name() == "Windows" else "Super")
	parts.append(label)
	return "+".join(parts)

func send_prefix() -> void:
	if settings.key == KEY_NONE:
		return
	# Retain the trigger's actual layout text for bare-key and A aliases,
	# including Alt/Shift prefixes whose text differs from the following key.
	if _last_trigger != null and _last_trigger.get_keycode_with_modifiers() == settings.key:
		_send_key(_last_trigger)
		return
	var key: InputEventKey = preload("res://graffitty/terminal_config.gd").KeyBinding.new(settings.key, "").key
	if key.keycode >= KEY_SPACE and key.keycode <= 0x10ffff:
		var letter := String.chr(key.keycode)
		key.unicode = (letter if key.shift_pressed else letter.to_lower()).unicode_at(0)
	_send_key(key)

func _send_key(event: InputEventKey) -> void:
	var id := int(host.pane_focus.substr(1))
	if not host.sessions.has(id) and not host.chromiums.has(id):
		return
	var key: InputEventKey = event.duplicate()
	key.echo = false
	# Bypass this client's prefix handler for both kinds of pane.
	for down in [true, false]:
		key.pressed = down
		if host.chromiums.has(id):
			var chromium: Node = host.chromiums[id]
			chromium.remote_input(key, chromium.texture.get_size() if chromium.texture != null else Vector2.ONE)
		else:
			host.sessions[id].term.send_key(key)

func focus_direction(direction: Vector2) -> void:
	var name: String = {Vector2.LEFT: "left", Vector2.DOWN: "down", Vector2.UP: "up", Vector2.RIGHT: "right"}.get(direction, "")
	host.navigator.focus_direction(name)
