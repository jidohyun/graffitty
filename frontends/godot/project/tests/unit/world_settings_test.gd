extends "res://tests/unit/test_case.gd"
const Settings := preload("res://scenes/WorldSettings.gd")
const Loader := preload("res://graffitty/world_config.gd")
const TerminalConfig := preload("res://graffitty/terminal_config.gd")

class CustomEffectsSettings extends "res://scenes/WorldSettings.gd":
	# World-owned effect hooks are independent of shared switch settings.
	func apply_effects(effects: RefCounted) -> void:
		effects.set_option("scene.sheet", "corner_radius", 31.0)

func test_world_settings_session_switch_survives_custom_effects_override() -> void:
	var world = preload("res://scenes/TerminalWorld3D.gd").new()
	world.settings = CustomEffectsSettings.new()
	world.settings.session_switch.fly_ratio_sparse = 0.8
	world.settings.session_switch.fly_ratio_dense = 0.25
	world.settings.session_switch.fly_dense_count = 400
	var effects := preload("res://scenes/Effects.gd").new()
	world.configure_effects(effects)
	expect(effects.scene.session_switch.fly_ratio_sparse == 0.8 and effects.scene.session_switch.fly_ratio_dense == 0.25, "Custom world effects preserve shared session ratios without calling super")
	expect(effects.scene.session_switch.fly_dense_count == 400, "Custom world effects preserve density scale")
	expect(effects.scene.sheet.corner_radius == 31.0, "Custom world effects still apply")
	world.settings.session_switch.fly_ratio_dense = NAN
	expect(not world.settings.validate().is_empty(), "Shared world settings reject invalid session ratios")
	world.free()

func test_world_settings_validation_and_copy() -> void:
	var user := TerminalConfig.new()
	user.font_size = 23
	var settings := Settings.new(user)
	expect(settings.validate().is_empty(), "Shared defaults validate")
	settings.terminal.font_size = 29
	expect(user.font_size == 23, "World settings cannot mutate host preferences")
	settings.sheet.padding = NAN
	expect(not settings.validate().is_empty(), "Nonfinite padding rejected")
	settings.sheet.padding = 24
	settings.render_scale = 0
	expect(not settings.validate().is_empty(), "Invalid render scale rejected")
	settings.render_scale = 0.8
	settings.motion_render_scale = 0
	expect(not settings.validate().is_empty(), "Invalid motion render scale rejected")

func test_world_sections_layer_and_skip_invalid_tables() -> void:
	var args := PackedStringArray([client_toml("worlds", """
[worlds.shared]
sheet.padding = 42
terminal.font_size = 27

[worlds.specific.terminal.background]
alpha = 0.4

[worlds.invalid]
render_scale = 0

[worlds.unknown]
sheet.paddng = 1

[worlds.wrong-type]
sheet.padding = "wide"
""")])
	var user := TerminalConfig.new()
	var valid := Loader.load_settings(Settings, user, PackedStringArray(["shared", "specific"]), args)
	expect(valid.terminal.font_size == 27 and valid.sheet.padding == 42, "The shared table applies")
	expect(is_equal_approx(valid.terminal.background.alpha, 0.4), "A specific table layers on top")
	var fallback := Loader.load_settings(Settings, user, PackedStringArray(["shared", "invalid", "unknown", "wrong-type"]), args)
	expect(fallback.terminal.font_size == 27 and fallback.sheet.padding == 42 and fallback.render_scale == 1.0, "Invalid tables are skipped, keeping earlier layers")
	expect(user.font_size != 27, "Loading isolates caller state")
	var missing := Loader.load_settings(Settings, user, PackedStringArray(["absent"]), args)
	expect(missing.sheet.padding == 24, "Unconfigured worlds keep their defaults")

func test_tables_are_read_only_by_their_world() -> void:
	var args := PackedStringArray([client_toml("opaque", "[worlds.some-plugin]\nanything = { nested = true }\n")])
	expect(preload("res://config/UserConfig.gd").validate_startup(args).is_empty(), "The client never validates a world's table")
	expect(Loader.table("some-plugin", args).anything.nested == true, "A world reads its own table verbatim")
	expect(Loader.table("other", args).is_empty(), "Unconfigured worlds get an empty table")


func test_typed_conversion() -> void:
	expect(Loader.convert_value(1.0, 2) == 2.0, "Integers widen to floats")
	expect(Loader.convert_value(1, 2.5) == null, "Floats do not narrow to integers")
	expect(Loader.convert_value(Vector4.ZERO, [1, 2, 3, 4]) == Vector4(1, 2, 3, 4), "Arrays become vectors")
	expect(Loader.convert_value(Vector4.ZERO, [1, 2]) == null, "Vector sizes are checked")
	expect(Loader.convert_value(Color.WHITE, "#102030") == Color("#102030"), "Strings become colors")
	expect(Loader.convert_value(Color.WHITE, "blue-ish") == null, "Invalid colors are rejected")
	var numbers: Array[int] = []
	expect(Loader.convert_value(numbers, [3, 1]) == [3, 1], "Typed arrays accept matching items")
	expect(Loader.convert_value(numbers, ["3"]) == null, "Typed arrays reject other items")
