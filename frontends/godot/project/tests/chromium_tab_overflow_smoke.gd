extends SceneTree
const Background := preload("../../../../tests/llm-e2e/replay/background.gd")
var failures := 0

class Session extends Node:
	var page_tabs: Array = []
	var selected_page_id := 1
	var native_visible := false
	var session_id := 1
	var primary_page_id := 1
	var chromium_ready := true
	var sandbox_enabled := true
	var failure_reason := ""
	var commands: Array = []
	func can_open_native() -> bool: return false
	func command(action: String, params: Dictionary = {}) -> void:
		commands.append([action, params])
		if action == "tab-select": selected_page_id = int(params.chromium_id)

func _initialize() -> void:
	Background.install(self)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok: failures += 1

func settle() -> void:
	await create_timer(.5).timeout

func run() -> void:
	root.size = Vector2i(800, 500)
	var session := Session.new()
	root.add_child(session)
	var chrome := preload("res://scenes/ChromiumChrome.gd").new()
	root.add_child(chrome)
	chrome.size = Vector2(550, 150)
	for i in 6: session.page_tabs.append({"id": i + 1, "title": "Page %d" % (i + 1), "url": "about:blank"})
	chrome.refresh(session)
	await settle()
	check(chrome.navigation.get_script() == preload("res://scenes/TabStripNavigation.gd"), "Browser uses the workspace navigation component")
	for control in [chrome.back, chrome.forward, chrome.reload, chrome.navigation.previous_tabs, chrome.navigation.next_tabs, chrome.tabs.plus, chrome.tabs.buttons[1].get_node("Close")]:
		check(control.tooltip_text.is_empty() and not control.accessibility_name.is_empty(), "Obvious browser and tab controls keep accessible names without repetitive tooltips")
	check(chrome.navigation.all_tabs.tooltip_text.contains(":ShowAllTabs"), "Non-obvious command hint remains available")
	check(chrome.tabs.buttons[1].tooltip_text.contains("about:blank"), "Browser title tooltip retains the destination URL")
	var find_bar := preload("res://scenes/ChromiumFindBar.gd").new()
	root.add_child(find_bar)
	for control in [find_bar.previous, find_bar.next, find_bar.close_button]:
		check(control.tooltip_text.is_empty() and not control.accessibility_name.is_empty(), "Find controls retain accessible names without obvious instructions")
	find_bar.queue_free()
	check(not chrome.navigation.next_tabs.visible, "Six browser tabs compress to fit a narrow pane")
	check(chrome.tabs.buttons[6].get_global_rect().end.x <= chrome.tabs.get_global_rect().end.x + 1, "All six tabs remain visible")
	check(chrome.tabs.buttons[1].get_node("Close").visible and not chrome.tabs.buttons[2].get_node("Close").visible, "Narrow tabs retain the selected close button and inactive favicons")
	for i in range(6, 40): session.page_tabs.append({"id": i + 1, "title": "Page %d" % (i + 1), "url": "about:blank"})
	chrome.refresh(session)
	await settle()
	check(chrome.navigation.next_tabs.visible and chrome.navigation.all_tabs.visible, "Overflow exposes scroll arrows and all-tabs chooser")
	check(chrome.navigation.next_tabs.get_rect().end.x <= chrome.tab_holder.size.x + 1, "Overflow controls fit inside the browser pane")
	chrome.navigation.next_tabs.pressed.emit()
	await process_frame
	check(chrome.tabs.scroll_horizontal > 0, "Next arrow reveals hidden browser tabs")
	chrome.navigation.previous_tabs.pressed.emit()
	await process_frame
	check(chrome.tabs.scroll_horizontal == 0, "Previous arrow returns to the beginning")
	chrome.navigation.all_tabs.pressed.emit()
	await process_frame
	check(chrome.navigation.menu.list.item_count == 40, "Chooser lists every browser page with appropriate actions")
	chrome.navigation.menu.search.text = "Page 40"
	await process_frame
	check(chrome.navigation.menu.list.item_count > 0, "Shared search finds browser pages")
	var found := -1
	for i in chrome.navigation.menu.list.item_count:
		if int(chrome.navigation.menu.list.get_item_metadata(i)) == 40: found = i
	check(found >= 0, "Last browser tab is searchable by title")
	if found >= 0: chrome.navigation.menu.list.item_activated.emit(found)
	chrome.refresh(session)
	await settle()
	check(session.selected_page_id == 40, "Chooser selects the requested browser page by stable ID")
	var last: Button = chrome.tabs.buttons[40]
	check(last.get_global_rect().end.x <= chrome.tabs.get_global_rect().end.x + 1 and last.get_global_rect().position.x >= chrome.tabs.get_global_rect().position.x - 1, "Selected last browser tab scrolls fully into view")
	if DisplayServer.get_name() != "headless":
		RenderingServer.force_draw(false)
		root.get_texture().get_image().save_png(OS.get_environment("GRAFFITTY_TEST_EVIDENCE").path_join("chromium-overflow.png"))
	session.page_tabs = session.page_tabs.slice(0, 2)
	session.selected_page_id = 1
	chrome.refresh(session)
	await settle()
	check(not chrome.navigation.next_tabs.visible and chrome.tabs.buttons[1].text == "Page 1", "Closing tabs restores full titles and removes overflow arrows")
	chrome.queue_free()
	session.queue_free()
	await process_frame
	await process_frame
	print("CHROMIUM_TAB_OVERFLOW failures=", failures)
	quit(1 if failures else 0)
