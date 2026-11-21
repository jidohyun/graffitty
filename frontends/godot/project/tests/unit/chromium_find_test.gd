extends "res://tests/unit/test_case.gd"
## The in-page find box and browser shortcuts. Chromium's find engine itself is
## covered against a real browser by tests/chromium/headless_chromium_e2e.py.
const FindBar := preload("res://scenes/ChromiumFindBar.gd")
const Chrome := preload("res://scenes/ChromiumChrome.gd")

class FakeSession extends Node:
	var selected_page_id := 7
	var find_result: Dictionary = {}
	var calls: Array = []
	func find(text: String, backward := false, find_next := false) -> void:
		calls.append(["find", text, backward, find_next])
	func stop_finding(clear_selection := false) -> void:
		calls.append(["stop", clear_selection])
		find_result = {}
	func command(action: String, args: Dictionary = {}) -> int:
		calls.append([action, args.get("chromium_id", -1)])
		return calls.size()

func key(code: int, command := true, shift := false, alt := false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	event.shift_pressed = shift
	event.alt_pressed = alt
	if OS.get_name() == "macOS": event.meta_pressed = command
	else: event.ctrl_pressed = command
	return event

func test_find_bar_drives_chromium_find_and_shows_its_result() -> void:
	var session := FakeSession.new()
	var bar := FindBar.new()
	bar._ready()
	bar.session = session
	bar.open()
	expect(bar.visible, "Opening shows the box")
	expect(session.calls.is_empty(), "An empty query searches nothing")
	bar.field.text = "needle"
	bar.field.text_changed.emit("needle")
	expect(session.calls[-1] == ["find", "needle", false, false], "Typing starts a new Chromium search: %s" % str(session.calls))
	session.find_result = {"count": 3, "active": 1, "final": true}
	bar.refresh()
	expect(bar.result.text == "1/3" and not bar.next.disabled, "Chromium's active/count is shown")
	bar._field_input(key(KEY_ENTER, false))
	expect(session.calls[-1] == ["find", "needle", false, true], "Enter finds the next match")
	bar._field_input(key(KEY_ENTER, false, true))
	expect(session.calls[-1] == ["find", "needle", true, true], "Shift+Enter finds the previous match")
	session.find_result = {"count": 0, "active": 0, "final": true}
	bar.refresh()
	expect(bar.result.text == "0/0" and bar.next.disabled and bar.previous.disabled, "No match disables stepping")
	var closed := [false]
	bar.closed.connect(func(): closed[0] = true)
	bar._field_input(key(KEY_ESCAPE, false))
	expect(not bar.visible and closed[0] and session.calls[-1] == ["stop", false], "Escape closes and keeps the active match selected")
	session.calls.clear()
	bar.open()
	expect(session.calls == [["find", "needle", false, false]], "Reopening searches the previous query again")
	expect(bar.field.get_selected_text() == "needle", "Reopening selects the previous query")
	session.selected_page_id = 8
	bar.refresh()
	expect(not bar.visible, "Switching tabs ends the page's find")
	bar.free()
	session.free()

func test_find_bar_sits_at_the_page_top_right() -> void:
	var bar := FindBar.new()
	bar._ready()
	bar.place(Vector2(1000, 600), 84)
	expect(bar.position == Vector2(1000 - FindBar.WIDTH - FindBar.MARGIN, 92) and is_equal_approx(bar.size.x, FindBar.WIDTH),
		"The box is in the page's top-right corner: %s" % str(bar.position))
	bar.place(Vector2(200, 600), 84)
	# Minimum sizes only shrink inside a scene tree, which unit tests lack.
	expect(not bar.previous.visible and not bar.next.visible and bar.position.x >= 0,
		"A narrow pane drops the arrow buttons and keeps the box on screen")
	bar.free()

func test_browser_shortcuts_navigate_and_find() -> void:
	var chrome := Chrome.new()
	var session := FakeSession.new()
	chrome.session = session
	var requested: Array = []
	chrome.find_requested.connect(func(direction): requested.append(direction))
	var mac := OS.get_name() == "macOS"
	expect(chrome.handle_shortcut(key(KEY_R)) and session.calls[0] == ["tab-reload", 7], "Reload")
	session.calls.clear()
	if mac:
		expect(chrome.handle_shortcut(key(KEY_BRACKETLEFT)) and session.calls[0] == ["tab-back", 7], "Cmd+[ goes back")
		expect(chrome.handle_shortcut(key(KEY_BRACKETRIGHT)) and session.calls[2] == ["tab-forward", 7], "Cmd+] goes forward")
		expect(not chrome.handle_shortcut(key(KEY_LEFT, false, false, true)), "Option+Left stays a text chord")
	else:
		expect(chrome.handle_shortcut(key(KEY_LEFT, false, false, true)) and session.calls[0] == ["tab-back", 7], "Alt+Left goes back")
		expect(chrome.handle_shortcut(key(KEY_RIGHT, false, false, true)) and session.calls[2] == ["tab-forward", 7], "Alt+Right goes forward")
	expect(chrome.handle_shortcut(key(KEY_F)) and chrome.handle_shortcut(key(KEY_G)) and chrome.handle_shortcut(key(KEY_G, true, true)),
		"Find, find next and find previous are browser shortcuts")
	expect(requested == [0, 1, -1], "Find requests carry their direction: %s" % str(requested))
	expect(not chrome.handle_shortcut(key(KEY_F, true, true)), "Shift+Find remains the terminal search chord")
	chrome.free()
	session.free()
