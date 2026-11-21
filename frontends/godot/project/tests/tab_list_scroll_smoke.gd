extends SceneTree
## Scrolling navigates the menu without activating a tab or fighting refreshes.
var failures := 0
var chosen: Array[int] = []

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("tab-list-scroll-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func settle() -> void:
	for i in 4: await process_frame

func wheel(at: Vector2, button: int) -> void:
	var event := InputEventMouseButton.new()
	event.position = at
	event.global_position = at
	event.button_index = button
	event.pressed = true
	root.push_input(event)

func pan(at: Vector2, amount: float) -> void:
	var event := InputEventPanGesture.new()
	event.position = at
	event.delta = Vector2(0, amount)
	root.push_input(event)

func run() -> void:
	root.size = Vector2i(1000, 700)
	var opener := Button.new()
	opener.position = Vector2(20, 20)
	opener.size = Vector2(50, 30)
	root.add_child(opener)
	var popup := preload("res://scenes/TabMenu.gd").new()
	root.add_child(popup)
	popup.tab_selected.connect(func(id: int): chosen.append(id))
	var items: Array = []
	for i in 40: items.append({"id": i, "title": "Tab %d" % i, "panes": []})
	popup.populate(items, 0, opener, Color.BLACK)
	popup.show_below(opener)
	await settle()
	check(popup.list.selected == 0, "Opening highlights the active tab")
	# Input over a row exercises the popup's routing before child buttons.
	var at: Vector2 = popup.list.global_position + Vector2(50, 30)
	for i in 12: wheel(at, MOUSE_BUTTON_WHEEL_DOWN)
	await settle()
	check(popup.list.selected == 12 and popup.list.scroll_vertical > 0, "Wheel scrolling advances the highlight and reveals it")
	check(popup.visible and chosen.is_empty(), "Scrolling does not activate a tab")
	pan(at, 0.4)
	pan(at, 0.4)
	check(popup.list.selected == 12, "Small trackpad deltas accumulate without skipping rows")
	pan(at, 0.4)
	check(popup.list.selected == 13, "Accumulated trackpad scrolling moves the highlight")
	pan(at, -1.0)
	check(popup.list.selected == 12, "Reversing the gesture responds immediately")
	await settle()
	var offset: int = popup.list.scroll_vertical
	items[0].title = "Updated tab title"
	popup.populate(items, 0, opener, Color.BLACK)
	await settle()
	check(popup.list.selected == 12 and popup.list.scroll_vertical == offset, "Periodic title/resource refresh preserves highlight and scroll position")
	# Native touch scrolling and dragging the scrollbar use the same value path.
	popup.list.scroll_vertical += int(popup.list.row_height * 3)
	await settle()
	check(popup.list.selected > 12, "Native scrolling moves the selection along with the content")
	var identity: String = popup.list.get_item_identity(popup.list.selected)
	offset = popup.list.scroll_vertical
	popup.populate(items, 0, opener, Color.BLACK)
	await settle()
	check(popup.list.get_item_identity(popup.list.selected) == identity and popup.list.scroll_vertical == offset, "Refresh never snaps back after touch or scrollbar scrolling")
	for i in 60: wheel(at, MOUSE_BUTTON_WHEEL_DOWN)
	check(popup.list.selected == 39, "Scrolling stops at the final item")
	for i in 60: wheel(at, MOUSE_BUTTON_WHEEL_UP)
	check(popup.list.selected == 0, "Scrolling stops at the first item")
	popup.search.text = "Tab 27"
	popup._refresh_results(true)
	await settle()
	check(popup.list.get_item_metadata(popup.list.selected) == 27, "Search still highlights its preferred result")
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	root.push_input(enter)
	await settle()
	check(chosen == [27] and not popup.visible, "Enter activates the highlighted result exactly once")
	popup.free()
	opener.free()
	await settle()
	print("TAB_LIST_SCROLL_PASS" if failures == 0 else "TAB_LIST_SCROLL_FAIL")
	quit.call_deferred(failures)
