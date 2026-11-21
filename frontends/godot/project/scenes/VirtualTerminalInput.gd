extends RefCounted
## Scoped input uses the same viewport/native keyboard path as physical typing.
var busy: Dictionary = { }
const KEYS := {
	"Enter": KEY_ENTER,
	"Tab": KEY_TAB,
	"Escape": KEY_ESCAPE,
	"Backspace": KEY_BACKSPACE,
	"Delete": KEY_DELETE,
	"ArrowLeft": KEY_LEFT,
	"ArrowRight": KEY_RIGHT,
	"ArrowUp": KEY_UP,
	"ArrowDown": KEY_DOWN,
	"Home": KEY_HOME,
	"End": KEY_END,
	"PageUp": KEY_PAGEUP,
	"PageDown": KEY_PAGEDOWN,
	"Space": KEY_SPACE,
}


func error(code: String, message: String) -> Dictionary:
	return { "error": { "code": code, "message": message } }


func key_event(key: String) -> InputEventKey:
	var pieces := key.split("+")
	var name: String = pieces[pieces.size() - 1]
	var event := InputEventKey.new()
	for modifier in pieces.slice(0, pieces.size() - 1):
		match modifier:
			"Ctrl":
				event.ctrl_pressed = true
			"Alt":
				event.alt_pressed = true
			"Shift":
				event.shift_pressed = true
			"Meta":
				event.meta_pressed = true
			_:
				return null
	if KEYS.has(name):
		event.keycode = KEYS[name]
		event.unicode = 32 if name == "Space" else 0
	elif name.length() == 1 and name.unicode_at(0) >= 32 and name.unicode_at(0) < 127:
		event.keycode = name.to_upper().unicode_at(0)
		event.unicode = (name.to_upper() if event.shift_pressed else name).unicode_at(0)
	else:
		return null
	return event


func dispatch(host: Node, tab_id: int, method: String, params: Dictionary) -> Dictionary:
	if method == "terminal.get_text":
		for key in params:
			if key not in ["scrollback", "tab_id"]:
				return error("invalid_params", "Unsupported parameter: " + str(key))
		var scrollback = params.get("scrollback", false)
		if not scrollback is bool:
			return error("invalid_params", "scrollback must be a boolean")
		if not host.sessions.has(tab_id) or not is_instance_valid(host.sessions[tab_id].term):
			return error("workspace_closed", "Terminal no longer exists")
		var captured: Dictionary = host.sessions[tab_id].term.get_text(scrollback)
		if captured.has("error"):
			return error("capture_failed", captured.error)
		return { "result": captured }
	if not method in ["terminal.type", "terminal.press"]:
		return error("method_not_found", "Unknown terminal method")
	var allowed := (
		["text", "interval_ms", "tab_id"]
		if method == "terminal.type"
		else ["key", "interval_ms", "tab_id", "effects"]
	)
	for key in params:
		if key not in allowed:
			return error("invalid_params", "Unsupported parameter: " + str(key))
	var effects = params.get("effects", true)
	if not effects is bool:
		return error("invalid_params", "effects must be a boolean")
	var events: Array[InputEventKey] = []
	var interval = params.get("interval_ms", 50)
	if (
		not (interval is int or interval is float)
		or not is_finite(float(interval)) or interval < 0 or interval > 1000
	):
		return error("invalid_params", "interval_ms must be 0–1000")
	if method == "terminal.type":
		var text = params.get("text")
		if not text is String or text.length() > 4096:
			return error("invalid_params", "text must be a string of at most 4096 characters")
		for character in text:
			var event := InputEventKey.new()
			var code: int = character.unicode_at(0)
			if character in ["\n", "\t"]:
				event = key_event("Enter" if character == "\n" else "Tab")
			elif code < 32 or code == 127:
				return error("invalid_params", "Use terminal.press for control keys")
			else:
				event.unicode = code
				event.keycode = character.to_upper().unicode_at(0) if code < 127 else 0
			events.append(event)
	else:
		if not params.get("key") is String:
			return error("invalid_params", "key must be a string")
		var event := key_event(params.key)
		if event == null:
			return error("invalid_key", "Unsupported key or modifier")
		events.append(event)
	if events.size() * float(interval) > 30000:
		return error("invalid_params", "Input sequence must fit within 30 seconds")
	if busy.has(tab_id):
		return error("busy", "Virtual input already running in this workspace")
	if not host.sessions.has(tab_id):
		return error("workspace_closed", "Terminal no longer exists")
	var pair: Dictionary = host.sessions[tab_id]
	var application: Node = host.application
	var tree: SceneTree = host.get_tree()
	busy[tab_id] = true
	var sent := 0
	for event in events:
		if not is_instance_valid(pair.term) or not is_instance_valid(pair.vp):
			busy.erase(tab_id)
			return error("workspace_closed", "Terminal closed after %d keys" % sent)
		var current_host: Node = application.host_for_workspace(tab_id)
		if (
			current_host == null or current_host.active_session_id != tab_id
			or pair.vp.gui_disable_input
		):
			busy.erase(tab_id)
			return error(
				"inactive_terminal",
				"Select this terminal before virtual input (%d keys sent)" % sent,
			)
		pair.term.grab_focus()
		event.pressed = true
		if effects: pair.vp.push_input(event, true)
		else: pair.term.send_key(event, false)
		var release: InputEventKey = event.duplicate()
		release.pressed = false
		if effects: pair.vp.push_input(release, true)
		else: pair.term.send_key(release, false)
		sent += 1
		if float(interval) > 0:
			await tree.create_timer(float(interval) / 1000.0).timeout
	busy.erase(tab_id)
	return { "result": { "keys_sent": sent } }
