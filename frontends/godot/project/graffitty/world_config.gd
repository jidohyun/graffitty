extends RefCounted
## A world's own client.toml table, `[worlds.<id>]`.
##
## Like `[tool.<name>]` in pyproject.toml, the client never interprets these
## tables: each world reads its own, by the id in its plugin manifest, and
## owns their schema, validation and documentation.
##
##     const WorldConfig := preload("res://graffitty/world_config.gd")
##     var mine := WorldConfig.table("my-world")
##
## The helpers below are optional: they set a typed settings object from a
## table, which is how the bundled worlds use them.
const TerminalConfig := preload("res://graffitty/terminal_config.gd")
const UserConfig := preload("res://config/UserConfig.gd")
const REMEMBER_ID := "world_config_id"


## `[worlds.<id>]` from the effective client configuration, or {} if absent.
static func table(id: String, args := OS.get_cmdline_user_args()) -> Dictionary:
	return UserConfig.world_settings(args, id)


## Construct `base` (a settings class taking the user's TerminalConfig) and
## apply the `[worlds.<id>]` tables named in `ids`, in order.
##
## A table with an unknown key, a wrong type or a failing validate() is
## skipped with a warning, keeping the earlier tables. A `terminal` subtable
## overrides [terminal].
static func load_settings(base: GDScript, user: TerminalConfig, ids: PackedStringArray, args := OS.get_cmdline_user_args()) -> RefCounted:
	var accepted: Array[Dictionary] = []
	var current: RefCounted = base.new(user.copy())
	for id in ids:
		var values := table(id, args)
		if values.is_empty():
			continue
		var candidate: RefCounted = base.new(user.copy())
		var errors := PackedStringArray()
		for layer in accepted + [values]:
			errors.append_array(apply(candidate, layer, "worlds.%s" % id))
		if errors.is_empty():
			errors = candidate.validate()
		if not errors.is_empty():
			push_warning("Invalid [worlds.%s] settings; keeping earlier settings: %s" % [id, "; ".join(errors)])
			continue
		accepted.append(values)
		current = candidate
	# The most specific table is where the app remembers this world's choices.
	if not ids.is_empty(): current.set_meta(REMEMBER_ID, ids[-1])
	return current


## Remember `choice` (a fragment of the world's table) for the next launch,
## below the user's own `[worlds.<id>]` keys. Worlds without tables are skipped.
static func remember(world: Node, choice: Dictionary, args := OS.get_cmdline_user_args()) -> void:
	var settings = world.get("settings")
	if settings is Object and settings.has_meta(REMEMBER_ID):
		UserConfig.remember(args, {"worlds": {str(settings.get_meta(REMEMBER_ID)): choice}})


## The current value of a dotted setting such as "weather.kind" on `world`,
## or null when the world has no such setting.
static func setting_value(world: Node, setting: String) -> Variant:
	var target = world.get("settings") if is_instance_valid(world) else null
	var parts := setting.split(".")
	for part in parts.slice(0, -1):
		if not target is Object or not part in target: return null
		target = target.get(part)
	if not target is Object or not parts[-1] in target: return null
	var value = target.get(parts[-1])
	return null if value is Object else value


## Whether `world`'s setting currently equals `value`, as the setting's type.
static func setting_is(world: Node, setting: String, value: Variant) -> bool:
	var current = setting_value(world, setting)
	if current == null: return false
	var converted = convert_value(current, value)
	return converted != null and converted == current


## Set a dotted setting on the active `world` from a SetWorldSetting menu
## entry. The world's settings class checks the value: on any error the
## setting keeps its previous value. A change is remembered for the next
## launch, below the user's own [worlds.<id>] keys, and the world is told
## through `settings_changed(setting)` so it can apply it live.
## Returns an error message, or "" on success.
static func set_setting(world: Node, setting: String, value: Variant, args := OS.get_cmdline_user_args()) -> String:
	var settings = world.get("settings") if is_instance_valid(world) else null
	if not settings is Object:
		return "the active world has no settings"
	var parts := setting.split(".")
	var parent: Object = settings
	for part in parts.slice(0, -1):
		var next = parent.get(part) if part in parent else null
		if not next is Object:
			return "Unknown setting " + setting
		parent = next
	var key := parts[-1]
	if not key in parent or parent.get(key) is Object:
		return "Unknown setting " + setting
	var previous = parent.get(key)
	var id := str(settings.get_meta(REMEMBER_ID, "world"))
	var errors := apply(parent, {key: value}, "worlds.%s.%s" % [id, ".".join(parts.slice(0, -1))] if parts.size() > 1 else "worlds." + id)
	if errors.is_empty(): errors = settings.validate()
	if not errors.is_empty():
		parent.set(key, previous)
		return "; ".join(errors)
	# Remember the value as written in client.toml, not its converted type.
	var choice := {key: value}
	var tables := parts.slice(0, -1)
	tables.reverse()
	for part in tables: choice = {part: choice}
	remember(world, choice, args)
	if world.has_method("settings_changed"): world.settings_changed(setting)
	return ""


## Set `values` onto `target`'s script properties, recursing into nested
## settings objects. Returns errors for unknown keys and mismatched types.
static func apply(target: Object, values: Dictionary, path: String) -> PackedStringArray:
	var errors := PackedStringArray()
	var properties := {}
	for property in target.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			properties[property.name] = property
	for key in values:
		var name := "%s.%s" % [path, key]
		var value = values[key]
		if key == "terminal" and target.get("terminal") is TerminalConfig:
			if not value is Dictionary:
				errors.append(name + " must be a table")
			else:
				UserConfig.apply_terminal(target.terminal, value)
			continue
		if not properties.has(key):
			errors.append("Unknown setting " + name)
			continue
		var current = target.get(key)
		if current is Object:
			if value is Dictionary:
				errors.append_array(apply(current, value, name))
			else:
				errors.append(name + " must be a table")
			continue
		var converted = convert_value(current, value)
		if converted == null:
			errors.append("Invalid type for " + name)
			continue
		target.set(key, converted)
	return errors


## `value` converted to the type of `current`, or null when incompatible.
static func convert_value(current: Variant, value: Variant) -> Variant:
	match typeof(current):
		TYPE_BOOL, TYPE_STRING:
			return value if typeof(value) == typeof(current) else null
		TYPE_INT:
			return value if value is int else null
		TYPE_FLOAT:
			return float(value) if value is int or value is float else null
		TYPE_COLOR:
			return TerminalConfig._color(value) if value is String and (value == "none" or Color.html_is_valid(value)) else null
		TYPE_VECTOR2, TYPE_VECTOR4:
			var size := 2 if current is Vector2 else 4
			if not value is Array or value.size() != size or not value.all(func(item): return item is int or item is float):
				return null
			return Vector2(value[0], value[1]) if size == 2 else Vector4(value[0], value[1], value[2], value[3])
		TYPE_ARRAY:
			if not value is Array:
				return null
			var result: Array = current.duplicate()
			result.clear()
			for item in value:
				if current.is_typed() and typeof(item) != current.get_typed_builtin():
					return null
				result.append(item)
			return result
		TYPE_DICTIONARY:
			return value.duplicate(true) if value is Dictionary else null
	return null
