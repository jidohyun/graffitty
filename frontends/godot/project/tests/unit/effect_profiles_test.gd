extends "res://tests/unit/test_case.gd"
const Profiles := preload("res://scenes/EffectProfiles.gd")
const Effects := preload("res://scenes/Effects.gd")
const Loader := preload("res://config/UserConfig.gd")

class FakeWorld extends Node:
	var fx_cfg = Effects.new()
	var applied := 0
	func _fx_apply_scene() -> void: applied += 1

class SettingsWorld extends Node:
	var settings: RefCounted

class FakeHost extends Node:
	var world: Node
	var holds: Array = []
	var released := 0
	func disable_effects(effects: Array) -> Callable:
		holds.append(effects)
		return func(): released += 1


func _host() -> FakeHost:
	var host := FakeHost.new()
	host.world = FakeWorld.new()
	host.add_child(host.world)
	return host


func test_builtin_profiles_load_cleanly_and_match_the_rust_schema() -> void:
	for name in Profiles.BUILTIN:
		var args := PackedStringArray([client_toml("profile-" + name, "[effects]\nprofile = \"%s\"\n" % name)])
		expect(not Loader.resolved(args).has("error"), "Rust accepts built-in profile " + name)
		var profiles := Profiles.new(args)
		expect(profiles.selected == name, "Startup profile comes from client.toml: " + name)
		var fx = Effects.new()
		profiles._overlay(fx, profiles.profile_options.get(name, []))
		expect(fx.warnings.is_empty(), "%s profile keys are all valid: %s" % [name, fx.warnings])


func test_switching_restores_replaced_values_and_keeps_other_edits() -> void:
	var host := _host()
	var fx = host.world.fx_cfg
	var lighting: float = fx.scene.lighting.strength
	var profiles := Profiles.new(PackedStringArray(["--no-config"]))
	expect(profiles.selected == Profiles.WORLD, "Without configuration the world's own effects apply")
	profiles.select(host, "exaggerated")
	expect(is_equal_approx(fx.scene.lighting.strength, 1.8) and fx.states.typing["camera.zoom"] == 2.0, "Exaggerated overlays its preset")
	expect(host.world.applied == 1, "The world re-applies its scene after a profile change")
	fx.set_option("scene.tab_switch", "effect", "push_pull")
	profiles.select(host, "mild")
	expect(is_equal_approx(fx.scene.lighting.strength, 0.6) and fx.states.typing["camera.zoom"] == 1.15, "Mild replaces Exaggerated")
	profiles.select(host, "world")
	expect(is_equal_approx(fx.scene.lighting.strength, lighting), "World Default restores the world's value")
	expect(not fx.states.typing.has("camera.zoom"), "Keys the world never set are removed again")
	expect(fx.scene.tab_switch.effect == "push_pull", "Edits to keys no profile touched survive")
	host.free()


func test_off_holds_every_effect_until_another_profile() -> void:
	var host := _host()
	var profiles := Profiles.new(PackedStringArray(["--no-config"]))
	profiles.select(host, "off")
	expect(host.holds.size() == 1, "Off holds effects once")
	expect(host.holds.size() == 1 and host.holds[0] == preload("res://graffitty/effects.gd").NAMES, "Off selects every decorative effect")
	profiles.apply(host)
	expect(host.holds.size() == 1, "Re-applying Off, e.g. after a world switch, keeps the single hold")
	profiles.select(host, "mild")
	expect(host.released == 1, "Leaving Off releases its hold")
	host.free()


func test_world_switch_reapplies_to_the_new_world_only() -> void:
	var host := _host()
	var profiles := Profiles.new(PackedStringArray(["--no-config"]))
	profiles.select(host, "mild")
	var old: Node = host.world
	host.world = FakeWorld.new()
	host.add_child(host.world)
	profiles.apply(host)
	expect(host.world.fx_cfg.states.typing["camera.zoom"] == 1.15, "The new world receives the window's profile")
	profiles.select(host, "world")
	expect(not host.world.fx_cfg.states.typing.has("camera.zoom"), "Restoring uses the new world's own values")
	expect(old.fx_cfg.states.typing["camera.zoom"] == 1.15, "The previous world's values are not touched")
	host.free()


func test_user_profiles_are_listed_after_builtins_and_validated() -> void:
	var args := PackedStringArray([client_toml("user-profiles", "[effects]\nprofile = \"calm\"\n[effects.profiles.calm.camera]\ndrift_px = 7.0\n")])
	var profiles := Profiles.new(args)
	expect(profiles.names() == ["world", "off", "mild", "exaggerated", "calm"], "User profiles follow the built-ins")
	expect(profiles.selected == "calm" and not profiles.is_builtin("calm") and profiles.label("calm") == "calm", "User profile names are literal labels")
	expect(Loader.validate_startup(args).is_empty(), "Inline profile settings validate")
	var host := _host()
	profiles.apply(host)
	expect(host.world.fx_cfg.states.typing["camera.drift_px"] == 7.0, "An inline user profile overlays like a built-in")
	host.free()



func test_the_last_choice_is_the_next_default_unless_client_toml_sets_it() -> void:
	var previous := OS.get_environment("XDG_STATE_HOME")
	var state := cache_directory().path_join("graffitty-remembered-%d" % OS.get_process_id())
	OS.set_environment("XDG_STATE_HOME", state)
	var none := PackedStringArray(["--no-config"])
	Loader.remember(none, {"effects": {"profile": "off"}})
	expect(not FileAccess.file_exists(state.path_join("graffitty/remembered.toml")), "--no-config remembers nothing")
	var unset := PackedStringArray([client_toml("remembered-unset", "[terminal]\nfont_size = 14\n")])
	expect(Profiles.new(unset).selected == "world", "Nothing remembered keeps the default")
	Loader.remember(unset, {"effects": {"profile": "off", "disabled": ["camera.tilt"]}})
	Loader.remember(unset, {"terminal": {"effects": {"cursor_trail": {"delay_ms": 0}}}})
	expect(Profiles.new(unset).selected == "off", "The last profile is the next launch's default")
	expect(Loader._section(unset, "effects").get("disabled") == ["camera.tilt"], "Effect switches are remembered")
	expect(Loader.terminal_config(unset).effects.cursor_trail.delay_ms == 0 and Loader.terminal_config(unset).font_size == 14, "A remembered cursor trail joins client.toml's other keys")
	var explicit := PackedStringArray([client_toml("remembered-explicit", "[effects]\nprofile = \"mild\"\n[terminal.effects.cursor_trail]\ndelay_ms = 7\n")])
	expect(Profiles.new(explicit).selected == "mild", "client.toml's profile wins over the last choice")
	expect(Loader.terminal_config(explicit).effects.cursor_trail.delay_ms == 7, "client.toml's cursor trail wins over the last choice")
	expect(Loader._section(explicit, "effects").get("disabled") == ["camera.tilt"], "Keys client.toml leaves unset still follow the last choice")
	expect(Profiles.new(none).selected == "world", "--no-config ignores remembered choices")
	var before = Loader.terminal_config(none).effects
	var after = Loader.terminal_config(none).effects
	after.typing_particles.amount = 9
	after.cursor_trail.blaze.color = Color("#112233")
	var edited: Dictionary = Loader.changed(Loader.terminal_effects_table(before), Loader.terminal_effects_table(after))
	expect(edited == {"typing_particles": {"amount": 9}, "cursor_trail": {"blaze": {"color": "#112233ff"}}}, "Only edited terminal effects are remembered: %s" % edited)
	Loader.remember(unset, {"terminal": {"effects": edited}})
	var restored = Loader.terminal_config(unset).effects
	expect(restored.typing_particles.amount == 9 and restored.cursor_trail.blaze.color.is_equal_approx(Color("#112233")) and restored.cursor_trail.delay_ms == 0, "Edited terminal effects come back with earlier choices")
	var WorldConfig := preload("res://graffitty/world_config.gd")
	var FlatSettings := preload("res://scenes/FlatWorldSettings.gd")
	var world := SettingsWorld.new()
	world.settings = WorldConfig.load_settings(FlatSettings, Loader.terminal_config(unset), PackedStringArray(["flat-3d"]), unset)
	WorldConfig.remember(world, {"tab_switch": {"effect": "none"}}, unset)
	WorldConfig.remember(world, {"session_switch": {"effect": "none"}}, unset)
	expect(WorldConfig.load_settings(FlatSettings, Loader.terminal_config(unset), PackedStringArray(["flat-3d"]), unset).tab_switch.effect == "none", "A transition is remembered for its world")
	expect(WorldConfig.load_settings(FlatSettings, Loader.terminal_config(unset), PackedStringArray(["flat-2d"]), unset).tab_switch.effect == "push_pull", "Another world keeps its own transition")
	var pinned := PackedStringArray([client_toml("remembered-world", "[worlds.flat-3d.session_switch]\neffect = \"fly_away_and_in\"\n")])
	var loaded = WorldConfig.load_settings(FlatSettings, Loader.terminal_config(pinned), PackedStringArray(["flat-3d"]), pinned)
	expect(loaded.session_switch.effect == "fly_away_and_in" and loaded.tab_switch.effect == "none", "client.toml's world table wins key by key")
	world.free()
	OS.set_environment("XDG_STATE_HOME", previous)
