extends "res://tests/unit/test_case.gd"
const Menu := preload("res://scenes/HyperlinkContextMenu.gd")
const Pane := preload("res://scenes/WorkspacePane.gd")

class Host extends Node:
	var calls: Array = []
	func create_chromium_session(url: String, owner: int) -> void:
		calls.append([url, owner])

class LinkPane extends Pane:
	var requested: Array[String] = []
	func _show_hyperlink_menu(uri: String, _openable: bool, _web: bool) -> void:
		requested.append(uri)


func test_browser_and_chromium_are_explicit_separate_actions() -> void:
	var menu := Menu.new()
	menu._ready()
	var browser: Array[String] = []
	menu.open_in_browser_requested.connect(func(uri: String): browser.append(uri))
	var host := Host.new()
	var pane := Pane.new()
	pane.host = host
	pane.key = "%42"
	menu.show_in_chromium_requested.connect(pane._show_link_in_chromium)
	var uri := "HTTPS://example.test/CaseSensitive?q=Mixed#Anchor"
	menu.target = uri
	menu.id_pressed.emit(Menu.Action.BROWSER)
	expect(browser == [uri] and host.calls.is_empty(), "Browser selection never creates a server Chromium session")
	menu.target = uri
	menu.id_pressed.emit(Menu.Action.CHROMIUM)
	expect(host.calls == [["https://example.test/CaseSensitive?q=Mixed#Anchor", 42]], "Chromium uses the clicked terminal as its owner and preserves URL path, query and fragment")
	expect(browser.size() == 1, "Chromium selection never opens the client browser")
	menu.id_pressed.emit(Menu.Action.CHROMIUM)
	expect(host.calls.size() == 1, "A consumed menu target cannot be opened twice")
	menu.free()
	pane.free()
	host.free()


func test_non_web_links_open_and_copy_but_not_chromium() -> void:
	var menu := Menu.new()
	menu._ready()
	var opened: Array[String] = []
	var chromium: Array[String] = []
	menu.open_in_browser_requested.connect(func(uri: String): opened.append(uri))
	menu.show_in_chromium_requested.connect(func(uri: String): chromium.append(uri))
	var open := menu.get_item_index(Menu.Action.BROWSER)
	var show := menu.get_item_index(Menu.Action.CHROMIUM)
	var copy := menu.get_item_index(Menu.Action.COPY)
	var uri := "file:///tmp/report.txt"
	menu.offer(uri, true, false)
	expect(menu.get_item_text(open) == "Open" and not menu.is_item_disabled(open), "A local file link offers Open")
	expect(menu.is_item_disabled(show) and not menu.is_item_disabled(copy), "Only Chromium is unavailable for a non-web link")
	menu.id_pressed.emit(Menu.Action.CHROMIUM)
	expect(chromium.is_empty(), "A disabled Chromium item never navigates")
	menu.offer(uri, true, false)
	menu.id_pressed.emit(Menu.Action.BROWSER)
	expect(opened == [uri], "Open hands the exact link to the client opener")
	menu.offer(uri, false, false)
	expect(menu.is_item_disabled(open) and not menu.is_item_disabled(copy), "A link this client cannot open can still be copied")
	menu.offer("https://example.test", true, true)
	expect(menu.get_item_text(open) == "Open in Browser" and not menu.is_item_disabled(open) and not menu.is_item_disabled(show), "Web links keep every action")
	menu.free()


func test_menu_rebinds_after_terminal_replacement_and_disconnects_on_exit() -> void:
	var first: Control = ClassDB.instantiate("Terminal")
	var second: Control = ClassDB.instantiate("Terminal")
	var pane := LinkPane.new()
	pane._bind_hyperlink_source(first)
	pane._bind_hyperlink_source(first)
	first.hyperlink_context_menu_requested.emit("https://first.test", true, true)
	pane._bind_hyperlink_source(second)
	first.hyperlink_context_menu_requested.emit("https://detached.test", true, true)
	second.hyperlink_context_menu_requested.emit("https://second.test", true, true)
	expect(pane.requested == ["https://first.test", "https://second.test"], "Each request opens once, and a replaced terminal no longer controls this pane")
	pane._exit_tree()
	expect(second.hyperlink_context_menu_requested.get_connections().is_empty(), "Removing the pane releases its terminal subscription")
	pane.free()
	first.free()
	second.free()
