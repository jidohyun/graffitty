extends "res://tests/unit/test_case.gd"

class View extends RefCounted:
	var splits: Array = []
	var icon_directions: Array = []
	func split_direction_icon(direction: String) -> Texture2D:
		icon_directions.append(direction)
		return preload("res://scenes/PaneIcons.gd").monitor()
	func split_window(axis: String, key: String, before := false) -> void:
		splits.append([axis, key, before])

class Host extends Node:
	var workspace_view := View.new()
	var terminal := true
	func is_terminal_pane(_key: String) -> bool: return terminal
	func shortcut_text(action: String) -> String: return "binding:" + action

func test_all_title_actions_show_resolved_shortcuts_and_reverse_splits() -> void:
	var host := Host.new()
	var pane := preload("res://scenes/WorkspacePane.gd").new()
	pane.host = host
	pane.key = "%42"
	pane._update_title_menu_hints()
	for id in range(10):
		expect("binding:" in pane.title_menu.get_item_text(pane.title_menu.get_item_index(id)), "Every pane-menu action uses its configured shortcut")
	expect("binding:ToggleFiletree" in pane.title_menu.get_item_text(pane.title_menu.get_item_index(6)), "Filetree uses its actual command binding")
	pane._update_title_menu_hints()
	var order: Array = []
	for index in pane.title_menu.item_count:
		order.append(-1 if pane.title_menu.is_item_separator(index) else pane.title_menu.get_item_id(index))
	expect(order == [5, 7, -1, 8, 3, 9, 4, -1, 6, 2, 1, -1, 0], "Stable groups: pane, splits, tools, close; reopening never duplicates entries")
	var close_index: int = pane.title_menu.get_item_index(0)
	expect(pane.title_menu.get_item_icon(close_index) == preload("res://scenes/PaneIcons.gd").trash(), "Close pane uses the shared trash icon")
	expect(preload("res://scenes/PopupChrome.gd").is_danger(pane.title_menu, close_index), "Close pane uses red destructive menu styling")
	expect(pane.title_menu.get_item_icon_modulate(close_index) == preload("res://scenes/UIAccent.gd").DANGER, "The pane trash icon is red")
	expect(host.workspace_view.icon_directions.slice(0, 4) == ["left", "right", "up", "down"], "Each split item points toward the side the new pane takes")
	pane._title_menu_action(8)
	pane._title_menu_action(9)
	expect(host.workspace_view.splits == [["h", "%42", true], ["v", "%42", true]], "Left/up split the owning pane before its current position")
	host.terminal = false
	pane._update_title_menu_hints()
	order.clear()
	for index in pane.title_menu.item_count:
		order.append(-1 if pane.title_menu.is_item_separator(index) else pane.title_menu.get_item_id(index))
	expect(order == [5, 7, -1, 1, -1, 0], "Non-terminal panes omit terminal actions without empty groups or a misplaced close")
	host.terminal = true
	pane._update_title_menu_hints()
	expect(pane.title_menu.item_count == 13 and pane.title_menu.get_item_id(12) == 0, "Late terminal metadata rebuilds the complete ordered menu")
	pane.title_menu.free()
	pane.free()
	host.free()
