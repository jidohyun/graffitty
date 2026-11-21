extends RefCounted
## Named world-effect profiles from client.toml. A profile overlays validated
## keys onto the current world's effects and records what it replaced, so
## choosing another profile restores exactly those values.
##
## Edits made through other controls (Effects…, Tab Transition, Cursor Trail)
## on untouched keys survive. `off` holds every decorative effect, like a
## DisableEffects rule.
const UserConfig := preload("res://config/UserConfig.gd")
const Effects := preload("res://graffitty/effects.gd")
const WORLD := "world"
const OFF := "off"
## Built-in names match graffitty-client-config's BUILTIN_EFFECT_PROFILES.
const BUILTIN := {
	"world": {"label": "World Default"},
	"off": {"label": "Off"},
	"mild": {"label": "Mild"},
	"exaggerated": {"label": "Exaggerated"},
}

var selected := WORLD
var user_profiles: Dictionary = {}
var profile_options: Dictionary = {}
## [section, key, existed, previous value] for each key the active profile set.
var _replaced: Array = []
var _world: WeakRef = weakref(null)
var _release := Callable()


func _init(args: PackedStringArray = PackedStringArray()) -> void:
	var values: Dictionary = UserConfig._section(args, "effects")
	var profiles = values.get("profiles", {})
	user_profiles = profiles if profiles is Dictionary else {}
	profile_options = UserConfig.resolved(args).get("effect_profiles", {})
	selected = str(values.get("profile", WORLD))
	if not has(selected): selected = WORLD


func names() -> Array[String]:
	var result: Array[String] = []
	result.assign(BUILTIN.keys())
	var custom: Array = user_profiles.keys()
	custom.sort()
	result.append_array(custom)
	return result


func has(name: String) -> bool:
	return BUILTIN.has(name) or user_profiles.has(name)


func is_builtin(name: String) -> bool:
	return BUILTIN.has(name)


## Menu leaf: built-in labels are translated; user profile names are literal.
func label(name: String) -> String:
	return BUILTIN[name].label if BUILTIN.has(name) else name


func select(host: Node, name: String) -> void:
	if not has(name): return
	selected = name
	apply(host)


## Apply the selected profile to the host's current world. Called again after
## every world switch; a new world starts from its own unmodified effects.
func apply(host: Node) -> void:
	if selected == OFF:
		if not _release.is_valid(): _release = host.disable_effects(Effects.NAMES)
	elif _release.is_valid():
		var release := _release
		_release = Callable()
		release.call()
	var world: Node = host.world
	if not is_instance_valid(world) or world.get("fx_cfg") == null: return
	if _world.get_ref() != world:
		_replaced.clear()
		_world = weakref(world)
	var fx = world.fx_cfg
	_restore(fx)
	_overlay(fx, profile_options.get(selected, []))
	world._fx_apply_scene()
	for property in ["terminal_effects", "effects_2d"]:
		var renderer = world.get(property)
		if renderer != null: renderer.configure(fx)


func _overlay(fx, options: Array) -> void:
	for option in options:
		var section := str(option[0])
		var key := str(option[1])
		_replaced.append([section, key] + _current(fx, section, key))
		fx.set_option(section, key, option[2])


func _current(fx, section: String, key: String) -> Array:
	if section.begins_with("state."):
		var state: Dictionary = fx.states.get(section.substr(6), {})
		return [state.has(key), state.get(key)]
	if section == "behavior":
		return [fx.behavior.has(key), fx.behavior.get(key)]
	var group: Dictionary = fx.scene.get(section.substr(6), {})
	return [group.has(key), group.get(key)]


func _restore(fx) -> void:
	for index in range(_replaced.size() - 1, -1, -1):
		var item: Array = _replaced[index]
		var section: String = item[0]
		var target: Dictionary
		if section.begins_with("state."):
			var state := section.substr(6)
			if not fx.states.has(state): fx.states[state] = {}
			target = fx.states[state]
		elif section == "behavior":
			target = fx.behavior
		elif fx.scene.has(section.substr(6)):
			target = fx.scene[section.substr(6)]
		else:
			continue
		if item[2]: target[item[1]] = item[3]
		else: target.erase(item[1])
	_replaced.clear()
