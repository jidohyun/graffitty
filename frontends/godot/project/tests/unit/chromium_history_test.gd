extends "res://tests/unit/test_case.gd"
## Address-bar history suggestions. Chrome's ranking itself runs in the CEF
## fork (fork/cef/graffitty_history.cc); the server filter has Rust tests.
const Chrome := preload("res://scenes/ChromiumChrome.gd")

## Unit fixtures run outside a scene tree, where controls cannot hold focus.
class EditingChrome extends "res://scenes/ChromiumChrome.gd":
	var editing := true
	func _editing() -> bool:
		return editing

class FakeSession extends Node:
	var selected_page_id := 7
	var page_tabs: Array = []
	var matches: Array = []
	var requests: Array = []
	func request(action: String, args: Dictionary = {}, _timeout_ms := 20000) -> Dictionary:
		requests.append([action, args.duplicate()])
		# Like ChromiumSession.request: the action's value under "result".
		return {"result": {"matches": matches}} if action == "history-query" else {"result": {}}
	func command(_action: String, _args: Dictionary = {}) -> int:
		return 0

func key(code: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	return event

func fixture() -> Array:
	var session := FakeSession.new()
	session.matches = [
		{"url": "https://github.com/", "title": "GitHub"},
		{"url": "https://github.com/kiyoon", "title": ""},
	]
	var chrome := EditingChrome.new()
	chrome._ready()
	chrome.session = session
	chrome.address.text = "git"
	chrome._query_history()
	return [chrome, session]

func test_typing_lists_chrome_history_below_the_address_bar() -> void:
	var made := fixture()
	var chrome: EditingChrome = made[0]
	var session: FakeSession = made[1]
	expect(session.requests == [["history-query", {"text": "git", "limit": Chrome.HISTORY_LIMIT}]], "Typing asks the server: %s" % str(session.requests))
	expect(chrome.suggestions.visible and chrome.suggestions.item_count == 2, "Matches are listed")
	expect(chrome.suggestions.get_item_text(0) == "GitHub — https://github.com/", "A title precedes its URL")
	expect(chrome.suggestions.get_item_text(1) == "https://github.com/kiyoon", "An untitled match shows its URL")
	chrome.address.text = ""
	chrome._query_history()
	expect(not chrome.suggestions.visible, "Clearing the bar hides suggestions")
	expect(session.requests.size() == 1, "Empty text never queries")
	chrome.free()
	session.free()

func test_arrow_keys_and_enter_navigate_to_the_selected_suggestion() -> void:
	var made := fixture()
	var chrome: EditingChrome = made[0]
	var session: FakeSession = made[1]
	chrome._address_input(key(KEY_UP))
	expect(chrome.suggestions.get_selected_items() == PackedInt32Array([1]), "Up from the bar wraps to the last match")
	chrome._address_input(key(KEY_DOWN))
	expect(chrome.suggestions.get_selected_items() == PackedInt32Array([0]), "Down wraps to the first match")
	# Navigating releases the bar's focus, which needs a tree this fixture lacks.
	expected_errors.append('Condition "!is_inside_tree()" is true.')
	chrome._address_input(key(KEY_ENTER))
	expect(session.requests[-1] == ["tab-navigate", {"chromium_id": 7, "text": "https://github.com/"}], "Enter opens the selection: %s" % str(session.requests[-1]))
	expect(chrome.address.text == "https://github.com/", "The bar shows the chosen URL")
	expect(not chrome.suggestions.visible, "Navigating closes the list")
	chrome.free()
	session.free()

func test_escape_closes_suggestions_first() -> void:
	var made := fixture()
	var chrome: EditingChrome = made[0]
	var session: FakeSession = made[1]
	expect(chrome.suggestions.visible, "Suggestions are open")
	expect(chrome.handle_shortcut(key(KEY_ESCAPE)) and not chrome.suggestions.visible, "First Escape closes only the list")
	chrome.free()
	session.free()

func test_a_stale_answer_never_replaces_newer_typing() -> void:
	var made := fixture()
	var chrome: EditingChrome = made[0]
	var session: FakeSession = made[1]
	chrome._hide_suggestions()
	var sequence: int = chrome._history_sequence
	chrome._history_sequence += 1 # A newer keystroke supersedes the reply below.
	session.matches = [{"url": "https://stale.example/", "title": "Stale"}]
	expect(sequence != chrome._history_sequence, "Each query and dismissal advances the sequence")
	chrome.editing = false
	chrome._query_history()
	expect(not chrome.suggestions.visible, "A bar without focus shows no list")
	expect(session.requests.size() == 1, "Leaving the bar stops querying")
	chrome.free()
	session.free()
