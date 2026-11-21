extends RefCounted
## Typed client settings. config/UserConfig.gd populates them from client.toml;
## worlds receive copies and may override them programmatically.
## Generic preferences are inputs: each world chooses its effective TerminalConfig.
const TerminalConfig := preload("res://graffitty/terminal_config.gd")
const Actions := preload("res://graffitty/actions.gd")
const Rule := preload("res://graffitty/rule.gd")


static func validate_rules(value: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	for rule in value:
		if not rule is Rule:
			errors.append("rules entries must be Rule.on(...)")
		else:
			errors.append_array(rule.validate())
	return errors


class PowerSettings extends RefCounted:
	var enabled := false
	var battery_world := "flat-2d"
	var external_world := "flat-3d"
	var follow_changes := true


## The resolved prefix key and its `Prefix+…` sequences ({keycode: Action}).
## Defaults come from the shared Rust action registry, as client.toml does.
class PrefixSettings extends RefCounted:
	## KEY_NONE disables workspace prefix commands. Client preferences,
	## independent of the session server's OS.
	var key: int = KEY_NONE
	var bindings: Dictionary = {}


	func _init() -> void:
		var defaults: Dictionary = ClassDB.class_call_static("ClientConfig", "load",
			PackedStringArray(), Bindings.platform(), {}, "")
		var resolved := Bindings.new(defaults)
		key = resolved.prefix
		bindings = resolved.prefix_bindings()


	func validate() -> PackedStringArray:
		var errors := PackedStringArray()
		var known: PackedStringArray = ClassDB.class_call_static("ClientConfig", "actions")
		for binding in bindings:
			if not binding is int:
				errors.append("Prefix bindings must be logical key codes")
			if not bindings[binding] is String or bindings[binding] not in known:
				errors.append("Unknown prefix action: " + str(bindings[binding]))
		return errors


## Resolved bindings: one source for dispatch, menu accelerators and hints.
class Bindings extends RefCounted:
	var prefix: int = KEY_NONE
	## Action name → [{prefix: bool, key: int}] in configured order.
	var actions: Dictionary = {}


	func _init(resolved: Dictionary = {}) -> void:
		prefix = int(resolved.get("prefix", KEY_NONE))
		actions = resolved.get("bindings", {})


	## iOS has its own binding map. Desktop touch simulation uses Android's.
	static func platform() -> String:
		if OS.has_feature("ios"):
			return "ios"
		if preload("res://scenes/input/InteractionProfile.gd").touch_controls():
			return "android"
		return {"macOS": "macos", "Windows": "windows", "Android": "android"}.get(OS.get_name(), "linux")


	func direct_action(code: int) -> String:
		return _action(code, false)


	func prefix_bindings() -> Dictionary:
		var result := {}
		for action in actions:
			for shortcut in actions[action]:
				if shortcut.prefix:
					result[int(shortcut.key)] = action
		return result


	## The first direct (not prefixed) key for `action`, or KEY_NONE.
	func direct_key(action: String) -> int:
		return _first(action, false)


	func prefix_key(action: String) -> int:
		return _first(action, true)


	func _first(action: String, prefixed: bool) -> int:
		for shortcut in actions.get(action, []):
			if bool(shortcut.prefix) == prefixed:
				return int(shortcut.key)
		return KEY_NONE


	func _action(code: int, prefixed: bool) -> String:
		for action in actions:
			for shortcut in actions[action]:
				if bool(shortcut.prefix) == prefixed and int(shortcut.key) == code:
					return action
		return ""


class TilingSettings extends RefCounted:
	var enabled: bool = true
	var gap: float = 8.0


	func validate() -> PackedStringArray:
		if not is_finite(gap) or gap < 0 or gap > 128:
			return PackedStringArray(["tiling.gap must be between 0 and 128"])
		return PackedStringArray()


class MacOSWindowSettings extends RefCounted:
	var blur_radius: int = 20


class WindowsWindowSettings extends RefCounted:
	var blur_material: String = "acrylic"


class WindowSettings extends RefCounted:
	var decorations := "client"
	## Desktop content scale, or "auto" to follow the display.
	var ui_scale: Variant = "auto"
	## Active rendering cap.
	var max_fps: int = 120
	## Inactive cap after pointer activity ends, bounded by max_fps.
	var inactive_max_fps: int = 30
	var background_blur: bool = OS.get_name() != "Linux"
	var macos := MacOSWindowSettings.new()
	var windows := WindowsWindowSettings.new()


	func validate() -> PackedStringArray:
		var errors := PackedStringArray()
		if max_fps < 1 or max_fps > 240:
			errors.append("window.max_fps must be between 1 and 240")
		if inactive_max_fps < 1 or inactive_max_fps > 240:
			errors.append("window.inactive_max_fps must be between 1 and 240")
		if macos == null or macos.blur_radius < 0 or macos.blur_radius > 128:
			errors.append("window.macos.blur_radius must be between 0 and 128")
		if windows == null or windows.blur_material not in ["acrylic", "mica", "tabbed"]:
			errors.append("window.windows.blur_material must be acrylic, mica, or tabbed")
		return errors
