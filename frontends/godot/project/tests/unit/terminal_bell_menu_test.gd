extends "res://tests/unit/test_case.gd"

func test_terminal_bell_menu_has_no_notification_viewer() -> void:
	var host := preload("res://scenes/TerminalHost.gd").new()
	var labels: Array = host._workspace_menu_entries().map(func(entry): return entry.label)
	expect(labels.count("Edit::Terminal Bell…") == 1, "Terminal Bell menu exists once")
	expect(not labels.has("Edit::Notifications and Bell…"), "Old combined menu is removed")
	var settings := preload("res://scenes/TerminalBellSettings.gd").new()
	expect(not settings.has_method("refresh"), "Bell settings do not poll pending notifications")
	expect(settings.duration != null and settings.color != null and settings.audible != null, "Visual and audible bell controls remain")
	# Controls are parented in _ready; this fixture does not enter the tree.
	settings.duration.free()
	settings.color.free()
	settings.audible.free()
	settings.status.free()
	settings.free()
	host.free()
