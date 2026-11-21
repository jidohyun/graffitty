extends "res://graffitty/paths.gd"
## User preferences from client.toml, separate from installed world assets and
## runtime state.
##
## Rust (graffitty-client-config) parses, validates, merges overlays, filters
## platform-specific entries and resolves key bindings; this script maps the
## result onto the typed settings objects.
const Settings := preload("res://graffitty/config.gd")
const TerminalConfig := preload("res://graffitty/terminal_config.gd")
const Rule := preload("res://graffitty/rule.gd")
const Actions := preload("res://graffitty/actions.gd")
const Effects := preload("res://graffitty/effects.gd")


## The automatic client.toml unless --no-config, then each explicit
## --config=<path> TOML overlay in command-line order.
static func override_paths(args: PackedStringArray) -> Array[String]:
	var paths: Array[String] = []
	if "--no-config" not in args and FileAccess.file_exists(config_path()):
		paths.append(config_path())
	for arg in args:
		if arg.begins_with("--config="):
			paths.append(expand_home(arg.substr(9)))
	return paths


## Choices made in the UI (effects profile, effect switches, terminal
## effects), kept for the next launch.
##
## Rust layers the file below client.toml, so a key set there wins and every
## other key follows the last choice. --no-config runs neither read nor write
## it.
static func remembered_path(args: PackedStringArray) -> String:
	return "" if "--no-config" in args else stdpath("state").path_join("remembered.toml")


## Remember `choice`, a client.toml fragment such as {"effects": {"profile": "off"}}.
static func remember(args: PackedStringArray, choice: Dictionary) -> void:
	var path := remembered_path(args)
	if path.is_empty(): return
	var error := str(ClassDB.class_call_static("ClientConfig", "remember", path, choice))
	if not error.is_empty(): push_warning("Could not remember %s: %s" % [choice, error])


## The client.toml [terminal.effects] shape of a TerminalConfig's effects.
static func terminal_effects_table(effects: RefCounted) -> Dictionary:
	var trail = effects.cursor_trail
	var result := {
		"cursor_trail": {
			"style": trail.style, "delay_ms": trail.delay_ms,
			"decay": [snappedf(trail.decay.x, 0.0001), snappedf(trail.decay.y, 0.0001)],
			"start_threshold": [snappedf(trail.start_threshold.x, 0.0001), snappedf(trail.start_threshold.y, 0.0001)],
		},
		"typing_particles": {
			"preset": effects.typing_particles.preset, "amount": effects.typing_particles.amount,
			"scale": effects.typing_particles.scale,
		},
		"typing_pane_zoom": {"scale": effects.typing_pane_zoom.scale},
	}
	for style in ["smear", "blaze", "lightning"]:
		var options := {}
		for key in trail.get(style):
			var value = trail.get(style)[key]
			options[key] = "#" + value.to_html() if value is Color else value
		result.cursor_trail[style] = options
	return result


## The keys of `after` that differ from `before`, keeping the nesting.
static func changed(before: Dictionary, after: Dictionary) -> Dictionary:
	var result := {}
	for key in after:
		if after[key] is Dictionary and before.get(key) is Dictionary:
			var inner := changed(before[key], after[key])
			if not inner.is_empty(): result[key] = inner
		elif not before.has(key) or before[key] != after[key]:
			result[key] = after[key]
	return result


## Directories that `~` and `%(config)`, `%(data)`, `%(cache)`, `%(state)`
## prefixes in client.toml paths expand against.
static func path_dirs() -> Dictionary:
	var dirs := { "home": expand_home("~") }
	for kind in ["config", "data", "cache", "state"]:
		dirs[kind] = stdpath(kind)
	return dirs


## The resolved configuration: {settings, prefix, bindings, menu, rules, mods, mod_order}, or
## the defaults with {error} when any layer is invalid. Cached by path and content.
static func resolved(args: PackedStringArray) -> Dictionary:
	var paths := PackedStringArray(override_paths(args))
	var remembered := remembered_path(args)
	if not FileAccess.file_exists(remembered): remembered = ""
	var key := Settings.Bindings.platform()
	for path in paths + PackedStringArray([remembered] if not remembered.is_empty() else []):
		key += "\n" + path + "\n" + FileAccess.get_md5(path)
	var owner := (Engine.get_main_loop() as SceneTree).root
	var cache: Dictionary = owner.get_meta("graffitty_client_config", {})
	if not cache.has(key):
		var result: Dictionary = ClassDB.class_call_static("ClientConfig", "load", paths,
			Settings.Bindings.platform(), path_dirs(), remembered)
		if result.has("error"):
			push_warning("Invalid client configuration; using defaults: " + str(result.error))
			var fallback: Dictionary = ClassDB.class_call_static("ClientConfig", "load",
				PackedStringArray(), Settings.Bindings.platform(), {}, "")
			fallback.error = result.error
			result = fallback
		cache[key] = result
		owner.set_meta("graffitty_client_config", cache)
	return cache[key]


static func _section(args: PackedStringArray, name: String) -> Dictionary:
	var value = resolved(args).settings.get(name)
	return value if value is Dictionary else {}


## Validate before creating any owner or shell: syntax, schema, bindings and
## menus in Rust; value ranges and font files with the typed settings.
static func validate_startup(args: PackedStringArray) -> PackedStringArray:
	var errors := PackedStringArray()
	var result := resolved(args)
	if result.has("error"):
		errors.append(str(result.error))
		return errors
	var terminal := TerminalConfig.new()
	apply_terminal(terminal, _section(args, "terminal"))
	errors.append_array(terminal.validate())
	for path in terminal.compiled_font_paths():
		if not path.is_empty() and not FileAccess.file_exists(path):
			errors.append("font file does not exist: " + path)
	for name in result.mods:
		var spec: Dictionary = result.mods[name]
		if spec.enabled and not FileAccess.file_exists(spec.entry):
			errors.append("mod entry does not exist: %s (%s)" % [spec.entry, name])
	errors.append_array(_window(args).validate())
	errors.append_array(_tiling(args).validate())
	if result.rules != null:
		for rule in result.rules:
			errors.append_array(Effects.validate(_selector(rule)))
	return errors


static func terminal_config(args: PackedStringArray):
	var config := TerminalConfig.new()
	apply_terminal(config, _section(args, "terminal"))
	var errors: PackedStringArray = config.validate()
	if errors.is_empty():
		return config
	push_warning("Invalid terminal configuration; using defaults: " + "; ".join(errors))
	return TerminalConfig.new()


## Set TerminalConfig fields from a client.toml [terminal] table.
static func apply_terminal(config: TerminalConfig, values: Dictionary) -> void:
	for key in values:
		var value = values[key]
		match key:
			"background":
				for field in value:
					config.background.set(field, TerminalConfig._color(value[field]) if field == "color" else value[field])
			"effects":
				for group in value:
					_apply_effect(config.effects.get(group), value[group])
			"palette":
				config.palette = PackedColorArray(Array(value).map(func(color): return TerminalConfig._color(color)))
			"palette_overrides":
				for index in value:
					config.palette_overrides[int(index)] = TerminalConfig._color(value[index])
			"symbol_maps":
				config.symbol_maps.clear()
				for item in value:
					config.symbol_maps.append(TerminalConfig.SymbolMap.new(int(item.first), int(item.last), str(item.family)))
			"font_fallbacks", "quick_select_patterns", "hyperlink_patterns":
				config.set(key, PackedStringArray(value))
			"iskeyword":
				config.iskeyword.assign(value)
			"font_features":
				config.font_features.clear()
				for tag in value: config.font_features[str(tag)] = int(value[tag])
			"font_variations":
				config.font_variations.clear()
				for tag in value: config.font_variations[str(tag)] = float(value[tag])
			_:
				config.set(key, TerminalConfig._color(value) if config.get(key) is Color else value)


static func _apply_effect(target: RefCounted, values: Dictionary) -> void:
	for key in values:
		var value = values[key]
		if key in ["smear", "blaze", "lightning"]:
			var options: Dictionary = target.get(key)
			for option in value:
				options[option] = TerminalConfig._color(value[option]) if str(option).ends_with("color") else value[option]
		elif key in ["decay", "start_threshold"]:
			target.set(key, Vector2(value[0], value[1]))
		else:
			target.set(key, value)


static func bindings(args: PackedStringArray) -> Settings.Bindings:
	return Settings.Bindings.new(resolved(args))


## Direct shortcuts for terminal actions as the native terminal's key table
## ({keycode: native action}). The terminal runs them after its copy-mode,
## search and quick-select keys, so they never preempt those modes.
static func terminal_key_bindings(args: PackedStringArray) -> Dictionary:
	const Actions := preload("res://scenes/HostActions.gd")
	var result := {}
	var resolved_bindings := bindings(args)
	for action in resolved_bindings.actions:
		var native: String = Actions.TERMINAL.get(action, Actions.NATIVE_FONT_SIZE.get(action, ""))
		if native.is_empty():
			continue
		for shortcut in resolved_bindings.actions[action]:
			if not shortcut.prefix:
				# SendText writes its entry's own text.
				result[int(shortcut.key)] = native + str(shortcut.get("text", ""))
	return result


## Terminal states the direct shortcuts above require ({keycode: "prompt"}).
## While a state does not hold, the terminal sends the key to its program.
static func terminal_key_conditions(args: PackedStringArray) -> Dictionary:
	var result := {}
	var shortcuts: Dictionary = terminal_key_bindings(args)
	var resolved_bindings := bindings(args)
	for action in resolved_bindings.actions:
		for shortcut in resolved_bindings.actions[action]:
			var code := int(shortcut.key)
			if not shortcut.prefix and shortcut.has("when") and shortcuts.has(code):
				result[code] = str(shortcut.when)
	return result


## `[touch]`: the key strip and floating buttons, in order. Rust fills omitted
## lists with the shipped defaults, so both are always present.
## keys: built-in key names, or {label, action, text?}; buttons: button names.
static func touch_config(args: PackedStringArray) -> Dictionary:
	var touch := _section(args, "touch")
	return {"keys": Array(touch.get("keys", [])), "buttons": Array(touch.get("buttons", []))}


static func prefix_config(args: PackedStringArray) -> Settings.PrefixSettings:
	var resolved_bindings := bindings(args)
	var result := Settings.PrefixSettings.new()
	result.key = resolved_bindings.prefix
	result.bindings = resolved_bindings.prefix_bindings()
	return result


static func _selector(rule: Dictionary) -> Dictionary:
	var selector := {}
	for key in ["include", "exclude"]:
		if rule.get(key) != null: selector[key] = rule[key]
	return selector


## Only explicit user rules can alter effects on foreground app changes.
static func context_rules(args: PackedStringArray) -> Array:
	var configured = resolved(args).rules
	if configured == null:
		return []
	var result := []
	for item in configured:
		var where := {}
		for key in ["app", "pane"]:
			if item.get(key) != null: where[key] = item[key]
		var selector := _selector(item)
		if not Effects.validate(selector).is_empty():
			push_warning("Invalid effect names in client rules; ignoring rules")
			return []
		if item.event == "active":
			result.append(Rule.while_active(where, Actions.disable(selector)))
		else:
			result.append(Rule.on(item.event, where, Actions.settle(selector)))
	return result


static func power_config(args: PackedStringArray):
	var result := Settings.PowerSettings.new()
	var values := _section(args, "power")
	for key in values:
		result.set(key, values[key])
	return result


static func tiling_config(args: PackedStringArray):
	var result = _tiling(args)
	if result.validate().is_empty(): return result
	push_warning("Invalid tiling configuration; using defaults")
	return Settings.TilingSettings.new()


static func _tiling(args: PackedStringArray):
	var result := Settings.TilingSettings.new()
	var values := _section(args, "tiling")
	for key in values:
		result.set(key, values[key])
	return result


static func window_config(args: PackedStringArray):
	var result = _window(args)
	var errors: PackedStringArray = result.validate()
	if errors.is_empty(): return result
	push_warning("Invalid window configuration; using defaults: " + "; ".join(errors))
	return Settings.WindowSettings.new()


static func _window(args: PackedStringArray):
	var result := Settings.WindowSettings.new()
	var values := _section(args, "window")
	for key in values:
		if key in ["macos", "windows"]:
			for field in values[key]:
				result.get(key).set(field, values[key][field])
		else:
			result.set(key, values[key])
	return result


static func world_path(args: PackedStringArray) -> String:
	return str(_section(args, "world").get("path", ""))


## The `[worlds.<name>]` table, or {} when not configured.
static func world_settings(args: PackedStringArray, name: String) -> Dictionary:
	var value = _section(args, "worlds").get(name)
	return value if value is Dictionary else {}


static func language(args: PackedStringArray) -> String:
	var value = resolved(args).settings.get("language")
	return str(value) if value != null else "auto"


## Configured menu entries for this platform; built-ins with the same label
## are replaced. Actions are PascalCase registry names, SwitchWorld,
## SetWorldSetting or Separator. An entry with `world` is kept here; the host
## shows it only while that world is active.
static func menu_entries(args: PackedStringArray) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var configured = resolved(args).menu
	if configured != null:
		for item in configured:
			result.append(item.duplicate())
	return result


static func apply_effect_settings(effects: RefCounted, args: PackedStringArray) -> void:
	for option in resolved(args).get("effect_options", []):
		effects.set_option(str(option[0]), str(option[1]), option[2])
