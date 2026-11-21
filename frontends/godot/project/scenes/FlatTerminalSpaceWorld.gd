extends "res://scenes/TerminalWorld.gd"
const FlatWorldSettings := preload("res://scenes/FlatWorldSettings.gd")
const WorldConfig := preload("res://graffitty/world_config.gd")
## This world's client.toml table, `[worlds.<id>]`.
var config_id := "flat-3d"
var settings: FlatWorldSettings
## The bundled Flat preset opts into the complete workspace UI.


func _init() -> void:
	terminal_space_scene = preload("res://scenes/TerminalSpace.tscn")


func uses_workspace_backdrop() -> bool:
	# Solid/transparent Flat has a continuous world background below the pane
	# glass. Its tiled outer frame can be hidden without removing the pane tint.
	return backdrop_fill_viewport and world_mode in ["color", "transparent"]


func _begin_navigation(prev: int, idx: int, speed: float) -> void:
	if tab_fx_t >= 0.0: camera_motion.reset(camera_motion.frame)
	super._begin_navigation(prev, idx, speed)


func configure_terminal(user: TerminalConfig) -> TerminalConfig:
	settings = WorldConfig.load_settings(FlatWorldSettings, user, PackedStringArray([config_id]))
	# WorkspacePane applies per-edge padding; avoid a second inset in the grid.
	terminal_padding = 0.0
	terminal_window = settings.terminal_window
	return settings.terminal


func configure_effects(effects: RefCounted) -> void:
	if settings != null:
		settings.apply_effects(effects)


func _load_background_config() -> void:
	super._load_background_config()
	# Opaque displays get tinted space behind the terminal panes in both Flat
	# renderers (Android starts in Flat 2D). Keep
	# terminal theme colors and pane opacity independent of this backdrop.
	var window_id := get_window().get_window_id() if is_inside_tree() else DisplayServer.MAIN_WINDOW_ID
	var transparent := preload("res://graffitty/window_transparency.gd").available(window_id)
	if world_mode == "color" and not transparent and not Array(OS.get_cmdline_user_args()).any(func(arg): return arg.begins_with("--bg=")):
		bg_color = Color("#3b4452")
