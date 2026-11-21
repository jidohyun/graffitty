extends RefCounted
const TerminalConfig := preload("res://graffitty/terminal_config.gd")

var terminal: TerminalConfig
var terminal_window := preload("res://scenes/WorldAppearance.gd").new()
var tab_switch := preload("res://scenes/TabSwitchSettings.gd").new()
var session_switch := preload("res://scenes/SessionSwitchSettings.gd").new()

func _init(user: TerminalConfig = null) -> void:
	terminal = user.copy() if user != null else TerminalConfig.new()
	# Flat worlds replace the session at once; scenery worlds keep the fly-in.
	session_switch.effect = "fly_away"

func validate() -> PackedStringArray:
	if terminal == null or terminal_window == null or tab_switch == null or session_switch == null:
		return PackedStringArray(["terminal, terminal_window, tab_switch, and session_switch must not be null"])
	var errors := terminal.validate()
	errors.append_array(terminal_window.validate())
	errors.append_array(tab_switch.validate())
	errors.append_array(session_switch.validate())
	return errors

func apply_effects(effects: RefCounted) -> void:
	tab_switch.apply_effects(effects)
	session_switch.apply_effects(effects)
