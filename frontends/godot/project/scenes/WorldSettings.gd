extends RefCounted
const TerminalConfig := preload("res://graffitty/terminal_config.gd")
const Config := preload("res://graffitty/config.gd")
const UserConfig := preload("res://config/UserConfig.gd")

class Sheet extends RefCounted:
	var padding: float = 24.0
	var content_gloss: float = 0.0
	var corner_radius: float = 18.0
	var edge_blur: float = 32.0

var terminal: TerminalConfig
var window: Config.WindowSettings = UserConfig.window_config(OS.get_cmdline_user_args())
var sheet := Sheet.new()
var render_scale: float = 1.0
## Scenery scale while the camera moves; at or above render_scale it is off.
var motion_render_scale: float = 1.0
var terminal_window := preload("res://scenes/WorldAppearance.gd").new()
var tab_switch := preload("res://scenes/TabSwitchSettings.gd").new()
var session_switch := preload("res://scenes/SessionSwitchSettings.gd").new()

func _init(user: TerminalConfig = null) -> void:
	terminal = user.copy() if user != null else TerminalConfig.new()
	window.background_blur = false

func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	if terminal == null or window == null or sheet == null or terminal_window == null or tab_switch == null or session_switch == null:
		errors.append("terminal, window, sheet, terminal_window, tab_switch, and session_switch must not be null")
		return errors
	errors.append_array(terminal.validate())
	errors.append_array(terminal_window.validate())
	errors.append_array(tab_switch.validate())
	errors.append_array(session_switch.validate())
	errors.append_array(window.validate())
	for rule in [["render_scale", render_scale, 0.25, 1.0],
		["motion_render_scale", motion_render_scale, 0.25, 1.0],
		["sheet.padding", sheet.padding, 0, 10000], ["sheet.content_gloss", sheet.content_gloss, 0, 1],
		["sheet.corner_radius", sheet.corner_radius, 0, 10000], ["sheet.edge_blur", sheet.edge_blur, 0, 10000]]:
		if not is_finite(float(rule[1])) or rule[1] < rule[2] or rule[1] > rule[3]:
			errors.append("%s must be between %s and %s" % [rule[0], rule[2], rule[3]])
	return errors

func apply_common_effects(effects: RefCounted) -> void:
	# Called by the kit independently of world-owned apply_effects overrides.
	# Existing world packs can replace that hook without calling super.
	tab_switch.apply_effects(effects)
	session_switch.apply_effects(effects)

func apply_effects(effects: RefCounted) -> void:
	for key in ["content_gloss", "corner_radius", "edge_blur"]:
		effects.set_option("scene.sheet", key, sheet.get(key))
