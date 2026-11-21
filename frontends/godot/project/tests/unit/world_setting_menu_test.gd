extends "res://tests/unit/test_case.gd"
## SetWorldSetting menu entries: WorldConfig reads, checks, sets and remembers
## one dotted world setting, and tells the world.
const WorldConfig := preload("res://graffitty/world_config.gd")
const Loader := preload("res://config/UserConfig.gd")

class WeatherSettings extends "res://scenes/WorldSettings.gd":
	class Weather extends RefCounted:
		var kind: String = "snow"
		var intensity: float = 1.4

	var weather := Weather.new()

	func validate() -> PackedStringArray:
		var errors := super.validate()
		if weather.kind not in ["none", "snow", "rain"]: errors.append("Invalid weather.kind")
		if weather.intensity < 0 or weather.intensity > 10: errors.append("weather.intensity must be between 0 and 10")
		return errors

class WeatherWorld extends Node:
	var settings: RefCounted
	var changed: Array[String] = []

	func settings_changed(setting: String) -> void:
		changed.append(setting)


func _world(args: PackedStringArray) -> WeatherWorld:
	var world := WeatherWorld.new()
	world.settings = WorldConfig.load_settings(WeatherSettings, Loader.terminal_config(args), PackedStringArray(["test-weather"]), args)
	return world


func test_a_world_setting_is_set_checked_and_remembered() -> void:
	var previous := OS.get_environment("XDG_STATE_HOME")
	OS.set_environment("XDG_STATE_HOME", cache_directory().path_join("graffitty-world-setting-%d" % OS.get_process_id()))
	var args := PackedStringArray([client_toml("world-setting", "[terminal]\nfont_size = 14\n")])
	var world := _world(args)
	expect(WorldConfig.setting_value(world, "weather.kind") == "snow", "A dotted setting reads the world's value")
	expect(WorldConfig.setting_is(world, "weather.kind", "snow") and not WorldConfig.setting_is(world, "weather.kind", "none"), "The checked entry is the current value")
	expect(WorldConfig.setting_is(world, "weather.intensity", 1.4), "A number compares as the setting's type")
	expect(WorldConfig.setting_value(world, "weather") == null and WorldConfig.setting_value(world, "weather.depth") == null, "A table or a missing key has no value")

	expect(WorldConfig.set_setting(world, "weather.kind", "none", args) == "", "A valid value is set")
	expect(world.settings.weather.kind == "none" and world.changed == ["weather.kind"], "The world is told which setting changed")
	expect(WorldConfig.set_setting(world, "weather.intensity", 3, args) == "" and world.settings.weather.intensity == 3.0, "An integer sets a float setting")

	var rejected := WorldConfig.set_setting(world, "weather.kind", "hail", args)
	expect(not rejected.is_empty() and world.settings.weather.kind == "none", "A value the world rejects keeps the previous one: %s" % rejected)
	expect(not WorldConfig.set_setting(world, "weather.intensity", 99, args).is_empty() and world.settings.weather.intensity == 3.0, "An out-of-range value keeps the previous one")
	expect(not WorldConfig.set_setting(world, "weather.kind", 1, args).is_empty() and world.settings.weather.kind == "none", "A value of the wrong type keeps the previous one")
	expect(WorldConfig.set_setting(world, "weather.depth", 1, args).begins_with("Unknown setting"), "A missing setting is reported")
	expect(WorldConfig.set_setting(world, "weather", "none", args).begins_with("Unknown setting"), "A table cannot be set to a value")
	expect(world.changed == ["weather.kind", "weather.intensity"], "Rejected values do not notify the world")

	var next := _world(args)
	expect(next.settings.weather.kind == "none" and next.settings.weather.intensity == 3.0, "The choice is the next launch's default")
	var pinned := PackedStringArray([client_toml("world-setting-pinned", "[worlds.test-weather.weather]\nkind = \"rain\"\n")])
	var user := _world(pinned)
	expect(user.settings.weather.kind == "rain" and user.settings.weather.intensity == 3.0, "client.toml's own key wins over the remembered choice")
	for node in [world, next, user]: node.free()
	OS.set_environment("XDG_STATE_HOME", previous)


func test_a_world_without_settings_reports_it() -> void:
	var world := Node.new()
	expect(not WorldConfig.set_setting(world, "weather.kind", "none", PackedStringArray(["--no-config"])).is_empty(), "A world with no settings rejects the entry")
	expect(not WorldConfig.setting_is(world, "weather.kind", "none"), "Nothing is checked in a world with no settings")
	world.free()
