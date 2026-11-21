extends SceneTree
## Exercise native Android touch events through the menu's real GUI hierarchy.
## godot --headless --path frontends/godot/project --script tests/tab_list_touch_smoke.gd
var failures := 0
var chosen: Array[int] = []
var popup: Control
var opener: Button
var items: Array = []

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("tab-list-touch-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func settle() -> void:
	for i in 4: await process_frame

func touch(at: Vector2, pressed: bool, canceled := false, index := 0) -> void:
	# Android also sends emulated mouse input before the raw contact event.
	var mouse := InputEventMouseButton.new()
	mouse.device = -1
	mouse.position = at
	mouse.global_position = at
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = pressed
	mouse.canceled = canceled
	root.push_input(mouse, true)
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = at
	event.pressed = pressed
	event.canceled = canceled
	root.push_input(event, true)

func drag(at: Vector2, relative: Vector2) -> void:
	var mouse := InputEventMouseMotion.new()
	mouse.device = -1
	mouse.position = at
	mouse.global_position = at
	mouse.relative = relative
	mouse.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(mouse, true)
	var event := InputEventScreenDrag.new()
	event.position = at
	event.relative = relative
	root.push_input(event, true)

func open() -> void:
	chosen.clear()
	popup.populate(items, 0, opener, Color.BLACK)
	popup.show_below(opener)
	await settle()

func run() -> void:
	root.size = Vector2i(1000, 700)
	opener = Button.new()
	opener.position = Vector2(20, 20)
	opener.size = Vector2(50, 30)
	root.add_child(opener)
	popup = preload("res://scenes/TabMenu.gd").new()
	root.add_child(popup)
	popup.tab_selected.connect(func(id: int): chosen.append(id))
	for i in 40: items.append({"id": i, "title": "Tab %d" % i, "panes": []})
	await open()
	var row: Button = popup.list.rows[2]
	var at: Vector2 = row.global_position + Vector2(80, 20)
	touch(at, true)
	check(chosen.is_empty() and popup.visible, "Touch down never opens a tab")
	drag(at + Vector2(2, -3), Vector2(2, -3))
	check(popup.list.scroll_vertical == 0, "Small finger jitter does not scroll")
	touch(at + Vector2(2, -3), false)
	check(chosen == [2] and not popup.visible, "A slightly moving tap opens the touched tab once on release")
	await open()
	row = popup.list.rows[3]
	at = row.global_position + Vector2(80, 20)
	touch(at, true)
	drag(at - Vector2(0, 80), Vector2(0, -80))
	check(popup.list.scroll_vertical > 40, "A one-finger drag over a row scrolls the content")
	check(popup.list.selected > 0, "Touch scrolling moves the menu highlight")
	var offset: int = popup.list.scroll_vertical
	items[0].title = "Updated tab title"
	popup.populate(items, 0, opener, Color.BLACK)
	await settle()
	check(popup.list.scroll_vertical == offset, "Live refresh preserves an ongoing touch scroll")
	# Return to the original point: crossing the threshold permanently cancels
	# this tap, even if the gesture ends back over the original row.
	drag(at, Vector2(0, 80))
	touch(at, false)
	check(chosen.is_empty() and popup.visible, "Dragging back to the starting row never clicks it")
	await open()
	row = popup.list.rows[2]
	var count: Control = row.get_meta("mod_view")
	count.render_now()
	at = count.global_position + count.hit_rect("panes").get_center()
	touch(at, true)
	drag(at - Vector2(0, 65), Vector2(0, -65))
	touch(at - Vector2(0, 65), false)
	check(popup.list.scroll_vertical > 30 and chosen.is_empty() and popup.visible, "Dragging the pane-count button scrolls without opening a tab")
	await open()
	count.render_now()
	at = count.global_position + count.hit_rect("panes").get_center()
	touch(at, true)
	touch(at, false)
	check(chosen == [2], "Tapping the pane count opens its tab exactly once")
	await open()
	row = popup.list.rows[2]
	at = row.global_position + Vector2(80, 20)
	touch(at, true)
	touch(at, false, true)
	check(chosen.is_empty() and popup.visible, "Android touch cancellation never opens a tab")
	await open()
	at = popup.list.rows[0].global_position + Vector2(80, 20)
	touch(at, true)
	drag(at + Vector2(0, 24), Vector2(0, 24))
	touch(at + Vector2(0, 24), false)
	check(chosen.is_empty() and popup.visible and popup.list.scroll_vertical == 0, "Dragging against the top boundary cannot turn into a click")
	await open()
	at = popup.list.rows[2].global_position + Vector2(80, 20)
	touch(at, true)
	touch(at + Vector2(30, 0), true, false, 1)
	touch(at + Vector2(30, 0), false, false, 1)
	drag(at - Vector2(0, 80), Vector2(0, -80))
	touch(at - Vector2(0, 80), false)
	check(chosen.is_empty() and popup.visible and popup.list.scroll_vertical == 0, "A second finger cancels the gesture until every finger lifts")
	await open()
	at = popup.list.rows[3].global_position + Vector2(80, 20)
	touch(at, true)
	for i in 4:
		await create_timer(0.02).timeout
		at.y -= 35
		drag(at, Vector2(0, -35))
	touch(at, false)
	offset = popup.list.scroll_vertical
	await create_timer(0.05).timeout
	check(popup.list.scroll_vertical > offset, "A flick continues scrolling after release")
	at = popup.list.global_position + Vector2(80, 160)
	touch(at, true)
	offset = popup.list.scroll_vertical
	await create_timer(0.05).timeout
	touch(at, false)
	check(popup.list.scroll_vertical == offset and chosen.is_empty() and popup.visible, "A tap stops momentum without opening a tab")
	touch(at, true)
	touch(at, false)
	check(chosen.size() == 1 and not popup.visible, "The next deliberate tap opens a tab normally")
	await open()
	at = popup.list.rows[2].global_position + Vector2(80, 20)
	touch(at, true)
	var outside: Vector2 = popup.get_global_rect().end + Vector2(40, 40)
	drag(outside, outside - at)
	touch(outside, false)
	check(chosen.is_empty() and popup.visible, "A captured drag can finish outside the menu without clicking or dismissing it")
	popup.hide()
	await open()
	at = popup.list.rows[2].global_position + Vector2(80, 20)
	touch(at, true)
	popup.hide()
	await open()
	touch(at, false)
	check(chosen.is_empty() and popup.visible, "Closing and reopening clears the old touch")
	var mouse := InputEventMouseMotion.new()
	mouse.position = at
	mouse.global_position = at
	root.push_input(mouse, true)
	for pressed in [true, false]:
		var click := InputEventMouseButton.new()
		click.position = at
		click.global_position = at
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		root.push_input(click, true)
	check(chosen == [2] and not popup.visible, "A desktop mouse click still opens its row once")
	popup.free()
	opener.free()
	await settle()
	print("TAB_LIST_TOUCH_PASS" if failures == 0 else "TAB_LIST_TOUCH_FAIL")
	quit.call_deferred(failures)
