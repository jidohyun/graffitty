extends "res://tests/unit/test_case.gd"
## Which touches on pane content drag it like a phone instead of pointing.
const Pointer := preload("res://scenes/input/MobilePointer.gd")

class App extends RefCounted:
	var terminal_touch_scroll_fingers := 1

class KeyBar extends Control:
	var shift := false
	func shift_drag_selects() -> bool: return shift

class Host extends RefCounted:
	var application := App.new()
	var touch_keybar: Control
	func is_terminal_pane(key: String) -> bool: return key == "%1"
	func is_chromium_pane(key: String) -> bool: return key == "%2"

class Links extends RefCounted:
	func sockets(_visible: bool) -> Dictionary: return {}

class Pane extends Control:
	var texture := Control.new()
	func _init() -> void:
		texture.size = Vector2(200, 100)
		add_child(texture)

class View extends Control:
	var host := Host.new()
	var agent_links := Links.new()
	var canvas_root := Control.new()
	var panes := {}
	var resize_key := ""
	var divider_hit := false
	func resize_window_at(_point: Vector2, _touch := false) -> String: return resize_key
	func canvas_point_at(local: Vector2) -> Vector2: return local
	func _compact_header_at(_local: Vector2) -> String: return ""
	func dividers_at(_point: Vector2, _touch := false) -> Array: return [{"axis": "h"}] if divider_hit else []
	func window_at(point: Vector2) -> String:
		for key: String in panes:
			if Rect2(panes[key].position, panes[key].texture.size).has_point(point): return key
		return ""

func test_one_finger_drags_chromium_pages_always_and_terminals_by_preference() -> void:
	var view := View.new()
	for key in ["%1", "%2"]:
		var pane := Pane.new()
		pane.position = Vector2(0 if key == "%1" else 300, 0)
		view.panes[key] = pane
		view.canvas_root.add_child(pane)
	var pointer := Pointer.new()
	pointer.view = view
	expect(pointer._scroll_target(Vector2(50, 50)) == "%1", "Terminal momentum is scoped to its pane")
	expect(pointer._scroll_target(Vector2(350, 50)) == "%2", "Chromium has a separate momentum target")
	expect(pointer._scroll_target(Vector2(250, 50)).is_empty(), "Empty canvas cannot inherit momentum")
	expect(pointer._drag_scrolls(Vector2(50, 50)), "One finger drags terminal history by default")
	expect(pointer._drag_scrolls(Vector2(350, 50)), "One finger drags a Chromium page, as in mobile Chrome")
	view.host.touch_keybar = KeyBar.new()
	expect(pointer._drag_scrolls(Vector2(50, 50)), "A key strip without Shift leaves the terminal drag a scroll")
	view.host.touch_keybar.shift = true
	expect(not pointer._drag_scrolls(Vector2(50, 50)), "Shift on the key strip turns a terminal drag into a selecting Shift+drag")
	expect(pointer._drag_scrolls(Vector2(350, 50)), "Shift on the key strip leaves Chromium pages scrolling")
	view.host.touch_keybar.free()
	view.host.touch_keybar = null
	view.host.application.terminal_touch_scroll_fingers = 3
	expect(not pointer._drag_scrolls(Vector2(50, 50)), "Multi-finger terminal scrolling leaves one finger for selection")
	expect(pointer._drag_scrolls(Vector2(350, 50)), "Chromium pages ignore the terminal scrolling preference")
	expect(not pointer._drag_scrolls(Vector2(250, 50)), "Empty canvas keeps pointer navigation")
	view.resize_key = "%2"
	expect(not pointer._drag_scrolls(Vector2(350, 50)), "A finger resize target is not a Chromium scroll")
	expect(pointer._scroll_target(Vector2(350, 50)).is_empty(), "A resize interrupts old content momentum instead of consuming the first drag")
	view.resize_key = ""
	view.divider_hit = true
	expect(not pointer._drag_scrolls(Vector2(350, 50)), "A widened tile divider is not a content scroll")
	expect(pointer._scroll_target(Vector2(350, 50)).is_empty(), "Tile resizing also interrupts content momentum")
	pointer.free()
	view.canvas_root.free()
	view.free()
