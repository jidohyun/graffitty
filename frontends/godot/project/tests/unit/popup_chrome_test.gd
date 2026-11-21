extends "res://tests/unit/test_case.gd"

func test_popup_chrome_is_shared_and_idempotent() -> void:
	var menu := PopupMenu.new()
	menu.add_item("Close pane", 1)
	var chrome := preload("res://scenes/PopupChrome.gd")
	chrome.apply(menu)
	chrome.apply(menu)
	expect(menu.get_child_count() == 1, "Repeated styling does not add duplicate chrome")
	var panel: StyleBoxFlat = menu.theme.get_stylebox("panel", "PopupMenu")
	expect(panel.corner_radius_top_left == 10 and panel.border_width_left == 1, "Shared rounded bordered style")
	expect(menu.get_item_id(0) == 1, "Chrome does not alter menu actions")
	menu.free()

func test_android_accessory_keys_do_not_offer_command() -> void:
	var bar := preload("res://scenes/input/TouchKeyBar.gd").new()
	bar._ready()
	expect(not bar.buttons.has("meta"), "Android has no Cmd button")
	for key in ["ctrl", "alt", "shift"]:
		expect(bar.buttons.has(key), "Android keeps " + key)
	bar.cycle_modifier("meta")
	expect(not bar.modifiers.has("meta"), "Unsupported virtual modifier cannot be armed")
	bar.free()
