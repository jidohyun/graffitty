extends "res://tests/unit/test_case.gd"
## View shortcuts come from the shared bindings, like every other action.

func test_fit_shortcuts_are_distinct() -> void:
	var bindings = preload("res://config/UserConfig.gd").bindings(PackedStringArray())
	var mac: bool = preload("res://graffitty/config.gd").Bindings.platform() == "macos"
	var app := KEY_MASK_META if mac else KEY_MASK_CTRL | KEY_MASK_SHIFT
	expect(bindings.direct_key("FitToPane") == (KEY_ENTER | app), "Fit to Pane is Cmd+Enter on macOS, Ctrl+Shift+Enter elsewhere")
	expect(bindings.direct_key("FitToMainArea") == (KEY_ENTER | app | KEY_MASK_ALT), "Alt distinguishes Main View from Fit to Pane")
