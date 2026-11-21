extends "res://tests/unit/test_case.gd"
const Settings := preload("res://graffitty/config.gd")
func test_server_settings_are_absent_from_client_configuration() -> void:
	for section in ["chromium", "filetree", "remote"]:
		var args := PackedStringArray([client_toml(section, "[%s]\nenabled = true\n" % section)])
		expect(not preload("res://config/UserConfig.gd").validate_startup(args).is_empty(), section + " belongs in server.toml")
