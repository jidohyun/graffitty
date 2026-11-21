extends "res://tests/unit/test_case.gd"
const World := preload("res://scenes/TerminalWorld.gd")

class HostProbe extends "res://scenes/TerminalHost.gd":
	var selected := []
	func select_workspace(id: int, _instant := false) -> void:
		selected.append(id)

class MenuProbe extends HostProbe:
	func _update_menu() -> void: pass

func test_disabled_session_step_still_consumes_the_key() -> void:
	var host := MenuProbe.new()
	var popup := PopupMenu.new()
	for action in ["PreviousSession", "NextSession"]:
		popup.add_item(action)
		var index := popup.item_count - 1
		popup.set_item_disabled(index, true)
		host.menu_entries.append({"action": action, "popup": popup, "index": index})
		expect(host._run_bound_action(action), "A disabled session step consumes its shortcut")
	popup.free()
	host.free()

class WorldHost extends Node:
	var tabs: Array[Dictionary] = []
	var selected := []
	func get_tabs(_session_only := false) -> Array:
		return tabs
	func select_workspace(id: int) -> void:
		selected.append(id)

func key_event(code: int, echo := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.meta_pressed = true
	event.pressed = true
	event.echo = echo
	return event

func host_with_tabs(count: int) -> HostProbe:
	var host := HostProbe.new()
	for i in count:
		host.workspace_layout.add(100 + i, {"pane": "%%%d" % (100 + i)})
	return host

func test_host_digits_select_by_position_and_nine_selects_last() -> void:
	var host := host_with_tabs(12)
	for key in [KEY_1, KEY_8, KEY_9]:
		host.select_numbered_tab(key)
	expect(host.selected == [100, 107, 111], "Cmd+1 and Cmd+8 select by position; Cmd+9 selects the last of twelve tabs")
	host.free()

func test_host_nine_selects_last_with_few_tabs() -> void:
	var host := host_with_tabs(3)
	host.select_numbered_tab(KEY_9)
	expect(host.selected == [102], "Cmd+9 selects the last tab even when fewer than nine exist")
	host.select_numbered_tab(KEY_5)
	expect(host.selected == [102], "A missing numbered tab leaves the selection unchanged")
	host.free()

func test_host_digits_ignore_empty_layout() -> void:
	var host := host_with_tabs(0)
	for key in [KEY_1, KEY_9]:
		host.select_numbered_tab(key)
	expect(host.selected.is_empty(), "Digit shortcuts select nothing without tabs")
	host.free()

func test_world_fallback_nine_selects_last() -> void:
	var world := World.new()
	var host := WorldHost.new()
	for i in 12:
		host.tabs.append({"id": 200 + i})
	world.host = host
	expect(world._terminal_tab_shortcut(key_event(KEY_9)), "Cmd+9 is consumed")
	expect(world._terminal_tab_shortcut(key_event(KEY_1)), "Cmd+1 is consumed")
	expect(host.selected == [211, 200], "Cmd+9 selects the last tab and Cmd+1 the first")
	expect(world._terminal_tab_shortcut(key_event(KEY_9, true)), "Auto-repeat is consumed")
	expect(host.selected == [211, 200], "Auto-repeat selects nothing")
	var plain := key_event(KEY_9)
	plain.meta_pressed = false
	expect(not world._terminal_tab_shortcut(plain), "Without Command the digit belongs to the terminal")
	world.free()
	host.free()

func test_world_fallback_missing_tab_is_consumed_without_selection() -> void:
	var world := World.new()
	var host := WorldHost.new()
	host.tabs.append({"id": 300})
	world.host = host
	expect(world._terminal_tab_shortcut(key_event(KEY_4)), "A missing tab is still consumed so it never types into the shell")
	expect(host.selected.is_empty(), "A missing tab selects nothing")
	expect(world._terminal_tab_shortcut(key_event(KEY_9)), "Cmd+9 is consumed")
	expect(host.selected == [300], "Cmd+9 selects the only tab")
	world.free()
	host.free()
