extends "res://tests/unit/test_case.gd"
const Settings := preload("res://scenes/FlatWorldSettings.gd")
const Effects := preload("res://scenes/Effects.gd")
const TerminalConfig := preload("res://graffitty/terminal_config.gd")
const Paths := preload("res://config/UserConfig.gd")

func test_flat_transition_default_and_override() -> void:
	var settings := Settings.new()
	var effects := Effects.new()
	settings.apply_effects(effects)
	expect(effects.scene.tab_switch.effect == "push_pull", "Flat 2D and 3D settings default to Push/Pull")
	expect(preload("res://scenes/TabSwitchSettings.gd").new().effect == "push_pull", "Spatial tabs also zoom in place")
	expect(effects.scene.session_switch.effect == "fly_away", "Flat sessions default to the quicker Fly away")
	expect(preload("res://scenes/WorldSettings.gd").new().session_switch.effect == "fly_away_and_in", "Scenery worlds keep Fly away and in")
	for effect in ["none", "push_pull"]:
		settings.tab_switch.effect = effect
		expect(settings.validate().is_empty(), "Supported effect validates")
		settings.apply_effects(effects)
		expect(effects.scene.tab_switch.effect == effect, "Explicit world effect is applied")
	settings.tab_switch.effect = "invalid"
	expect(not settings.validate().is_empty(), "Unknown effect is rejected")

func test_session_switch_settings_validation() -> void:
	var settings := Settings.new()
	expect(settings.validate().is_empty(), "Default Flat settings validate")
	for key in ["fly_ratio_sparse", "fly_ratio_dense"]:
		for invalid in [-0.1, 1.1, NAN, INF]:
			settings.session_switch.set(key, invalid)
			expect(not settings.validate().is_empty(), "Reject invalid " + key)
		settings.session_switch.set(key, 0.25)
	for invalid in [0, -1, 1000001]:
		settings.session_switch.fly_dense_count = invalid
		expect(not settings.validate().is_empty(), "Reject invalid density count")
	settings.session_switch.fly_dense_count = 500
	expect(settings.validate().is_empty(), "Custom ratios and density validate")
	var other := Settings.new()
	expect(other.session_switch.fly_ratio_sparse == 0.5 and other.session_switch.fly_dense_count == 1200, "World instances have independent settings")
	settings.session_switch = null
	expect(not settings.validate().is_empty(), "Reject a missing session_switch group")

func test_each_flat_world_reads_its_own_table() -> void:
	var path := Paths.config_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	FileAccess.open(path, FileAccess.WRITE).store_string("""
[worlds.flat-3d.session_switch]
effect = "fly_away_and_in"
fly_ratio_sparse = 0.7
fly_ratio_dense = 0.2
fly_dense_count = 500

[worlds.flat-3d.terminal_window]
blur_radius = 4
padding = [1, 2, 3, 4]

[worlds.flat-3d.terminal.background]
alpha = 0.4

[worlds.flat-2d.terminal_window]
blur_radius = 6
""")
	var flat_3d = load("res://scenes/FlatTerminalSpaceWorld.gd").new()
	var terminal: TerminalConfig = flat_3d.configure_terminal(TerminalConfig.new())
	var effects := Effects.new()
	effects.load_config(flat_3d.default_config)
	flat_3d.configure_effects(effects)
	expect(effects.scene.session_switch.fly_ratio_sparse == 0.7 and effects.scene.session_switch.fly_ratio_dense == 0.2, "Flat 3D applies both ratio endpoints")
	expect(effects.scene.session_switch.effect == "fly_away_and_in" and effects.scene.session_switch.fly_dense_count == 500, "Flat 3D applies the effect and density")
	expect(flat_3d.terminal_window.blur_radius == 4.0 and flat_3d.terminal_window.padding == Vector4(1, 2, 3, 4), "Flat 3D appearance settings load")
	expect(terminal.background.alpha == 0.4, "A world's terminal table overrides the user's terminal settings")
	effects.set_option("scene.session_switch", "fly_ratio_dense", 0.3)
	expect(effects.scene.session_switch.fly_ratio_dense == 0.3, "Explicit effects overrides take precedence")
	flat_3d.free()
	var flat_2d = load("res://scenes/Flat2DWorld.gd").new()
	terminal = flat_2d.configure_terminal(TerminalConfig.new())
	expect(flat_2d.config_id == "flat-2d" and flat_2d.terminal_window.blur_radius == 6.0, "Flat 2D reads [worlds.flat-2d]")
	expect(flat_2d.terminal_window.padding == Vector4(8, 8, 8, 8) and terminal.background.alpha != 0.4, "Flat 2D ignores Flat 3D's table")
	flat_2d.free()
	DirAccess.remove_absolute(path)
