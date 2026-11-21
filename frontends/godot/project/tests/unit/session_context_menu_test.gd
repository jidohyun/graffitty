extends "res://tests/unit/test_case.gd"
const Menu := preload("res://scenes/session/SessionContextMenu.gd")
const Chrome := preload("res://scenes/PopupChrome.gd")

class Peer extends Node:
	var connected := true

func test_session_menu_has_rename_and_red_trash_without_acting() -> void:
	var menu := Menu.new()
	var peer := Peer.new()
	menu.peer = peer
	menu.target = "$7"
	menu.refresh()
	expect(menu.item_count == 3 and menu.is_item_separator(1), "Rename and kill use distinct groups like pane menus")
	expect(menu.get_item_text(0) == "Rename Session…" and menu.get_item_text(2) == "Kill Session", "Right-click offers both session actions")
	expect(menu.get_item_icon(2) == preload("res://scenes/PaneIcons.gd").trash(), "Kill uses the shared trash artwork")
	expect(Chrome.is_danger(menu, 2) and not Chrome.is_danger(menu, 0), "Only killing is marked destructive")
	expect(menu.get_item_icon_modulate(2) == preload("res://scenes/UIAccent.gd").DANGER, "Trash artwork is red")
	var presentation := preload("res://scenes/input/TouchMenu.gd").new()
	presentation.model = menu
	presentation._build()
	var row: Button = presentation.buttons[1]
	expect(row.get_theme_color("font_color") == preload("res://scenes/UIAccent.gd").DANGER, "Rendered kill text is red")
	expect(row.get_theme_color("icon_normal_color") == preload("res://scenes/UIAccent.gd").DANGER, "Rendered trash is red")
	peer.connected = false
	menu.refresh()
	expect(menu.is_item_disabled(0) and menu.is_item_disabled(2), "A disconnected server cannot rename or kill")
	presentation.free()
	menu.free()
	peer.free()
