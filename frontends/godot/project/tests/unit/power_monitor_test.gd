extends "res://tests/unit/test_case.gd"
const Monitor := preload("res://scenes/PowerMonitor.gd")
const Settings := preload("res://graffitty/config.gd")


func test_power_events_ignore_duplicates_and_unknown_sources() -> void:
	var monitor := Monitor.new()
	var events: Array = []
	var availability: Array = []
	monitor.source_changed.connect(func(value): events.append(value))
	monitor.availability_changed.connect(func(value): availability.append(value))
	monitor._accept({"available": true, "on_battery": true})
	monitor._accept({"available": true, "on_battery": true})
	monitor._accept({"available": false})
	expect(events == [true], "Unknown state never switches to external power")
	expect(not monitor.available, "Loss of monitoring is exposed")
	monitor._accept({"available": true, "on_battery": false})
	monitor._accept({"available": true, "on_battery": false})
	expect(events == [true, false], "Only source transitions reach configuration")
	expect(availability == [true, false, true], "Availability transitions are distinct")
	monitor._accept({"available": true, "on_battery": "invalid"})
	expect(not monitor.available and events == [true, false], "Malformed state cannot switch a world")
	monitor.free()


func test_power_worlds_load_from_client_toml() -> void:
	var args := PackedStringArray([client_toml("power", "[power]\nenabled = true\nbattery_world = \"flat-2d\"\nexternal_world = \"worlds/example\"\nfollow_changes = false\n")])
	var config = preload("res://config/UserConfig.gd").power_config(args)
	expect(config.enabled, "Power policy is enabled")
	expect(config.battery_world == "flat-2d", "Battery world is preserved")
	expect(config.external_world == "worlds/example", "External world is preserved")
	expect(not config.follow_changes, "Startup-only policy remains selectable")
