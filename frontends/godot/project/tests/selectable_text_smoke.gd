extends SceneTree
## Read-only text and lists select and scroll like a terminal: Ghostty words
## and lines, word-wise dragging, and the rubber band for trackpads and
## fingers. Headless; drives real input events through the viewport.
var failures: Array[String] = []

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)


func _initialize() -> void:
	run.call_deferred()


func frames(count := 1) -> void:
	for i in count: await process_frame


func mouse(at: Vector2, button := MOUSE_BUTTON_LEFT, pressed := true, double := false) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.double_click = double
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	root.push_input(event, true)


func move(at: Vector2, held := true) -> void:
	var event := InputEventMouseMotion.new()
	event.position = at
	event.global_position = at
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	root.push_input(event, true)


func pan(at: Vector2, delta_y: float, phase: String) -> void:
	var event := InputEventPanGesture.new()
	event.position = at
	# Content pixels, as a touch scroll reports them on every platform.
	event.delta = Vector2(0, delta_y * (0.03 if OS.get_name() == "macOS" else 1.0))
	event.set_meta("scroll_phase", phase)
	event.set_meta("touch_travel", Vector2(0, -delta_y))
	root.push_input(event, true)


func touch(at: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = at
	event.pressed = pressed
	root.push_input(event, true)


func drag(from: Vector2, to: Vector2) -> void:
	var event := InputEventScreenDrag.new()
	event.index = 0
	event.position = to
	event.relative = to - from
	root.push_input(event, true)


func at_column(text: Node, line: int, column: int) -> Vector2:
	var cell: Rect2i = text.view.get_rect_at_line_column(line, column)
	# Viewport coordinates: every event is pushed in local coordinates.
	return text.view.get_global_transform_with_canvas() * (Vector2(cell.position) + Vector2(cell.size) * 0.5)


func settle(still: Callable, seconds := 4.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if still.call(): return true
	return false


func run() -> void:
	root.size = Vector2i(900, 700)
	await check_text_selection()
	await check_text_rubber_band()
	await check_list_touch()
	print("SELECTABLE_TEXT_PASS" if failures.is_empty() else "SELECTABLE_TEXT_FAIL")
	quit(0 if failures.is_empty() else 1)


func check_text_selection() -> void:
	var text := preload("res://scenes/SelectableText.gd").new()
	text.position = Vector2(20, 20)
	text.size = Vector2(700, 300)
	root.add_child(text)
	text.text = "cd ~/project/godot-ghostty; echo $HOME\n  Build 42 (debug)  \nlast line"
	await frames(3)
	var path := at_column(text, 0, 8)
	mouse(path)
	mouse(path, MOUSE_BUTTON_LEFT, false)
	mouse(path, MOUSE_BUTTON_LEFT, true, true)
	await frames()
	check(text.get_selected_text() == "~/project/godot-ghostty", "Double click takes a terminal word: '%s'" % text.get_selected_text())
	move(at_column(text, 0, 29))
	await frames()
	check(text.get_selected_text() == "~/project/godot-ghostty; echo", "Dragging extends a whole word at a time: '%s'" % text.get_selected_text())
	move(at_column(text, 0, 1))
	await frames()
	check(text.get_selected_text() == "cd ~/project/godot-ghostty", "Dragging back keeps the first word: '%s'" % text.get_selected_text())
	mouse(at_column(text, 0, 1), MOUSE_BUTTON_LEFT, false)
	var build := at_column(text, 1, 4)
	mouse(build)
	mouse(build, MOUSE_BUTTON_LEFT, false)
	mouse(build, MOUSE_BUTTON_LEFT, true, true)
	mouse(build, MOUSE_BUTTON_LEFT, false)
	mouse(build)
	await frames()
	check(text.get_selected_text() == "Build 42 (debug)", "Triple click takes the line without blanks: '%s'" % text.get_selected_text())
	move(at_column(text, 2, 2))
	await frames()
	check(text.get_selected_text().begins_with("Build 42 (debug)") and text.get_selected_text().ends_with("last line"), "Dragging after a triple click extends by lines")
	mouse(at_column(text, 2, 2), MOUSE_BUTTON_LEFT, false)
	if DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		DisplayServer.clipboard_set("BEFORE")
		text.copy()
		check(DisplayServer.clipboard_get() == text.get_selected_text(), "Copy takes the selection")
	text.queue_free()
	await frames()


func check_text_rubber_band() -> void:
	var text := preload("res://scenes/SelectableText.gd").new()
	text.position = Vector2(20, 20)
	text.size = Vector2(500, 200)
	root.add_child(text)
	var lines := PackedStringArray()
	for i in 200: lines.append("row %d" % i)
	text.text = "\n".join(lines)
	await frames(3)
	var inside := Vector2(200, 100)
	pan(inside, 0, "began")
	for i in 12: pan(inside, -20, "changed")
	await frames()
	check(text.view.scroll_vertical == 0.0 and text.elastic.get_stretch() < 0.0 and text.view.offset_top > 0.0, "Pulling down at the top stretches the text: %s" % text.elastic.get_stretch())
	check(text._bar_skin != null and text._bar_skin.visible and text._bar_skin.stretch < 0.0, "The text's scrollbar thumb shortens while pulled")
	pan(inside, 0, "ended")
	check(await settle(func(): return text.elastic.get_stretch() == 0.0 and text.view.offset_top == 0.0), "The pull springs back to rest")
	check(not text._bar_skin.visible, "At rest the text's scrollbar draws itself again")
	pan(inside, 0, "began")
	for i in 10: pan(inside, 30, "changed")
	pan(inside, 0, "ended")
	await frames()
	check(is_equal_approx(text.view.scroll_vertical * text.view.get_line_height(), 300.0), "A pan scrolls by the distance travelled: %s rows" % text.view.scroll_vertical)
	text.queue_free()
	await frames()


func check_list_touch() -> void:
	var list := preload("res://scenes/ElasticScrollContainer.gd").new()
	list.position = Vector2(20, 20)
	list.size = Vector2(300, 240)
	list.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pressed := [0]
	for i in 40:
		var row := Button.new()
		row.text = "Row %d" % i
		row.custom_minimum_size.y = 40
		row.pressed.connect(func(): pressed[0] += 1)
		rows.add_child(row)
	list.add_child(rows)
	root.add_child(list)
	await frames(3)
	var start := Vector2(150, 200)
	touch(start, true)
	var point := start
	for i in 10:
		drag(point, point + Vector2(0, -12))
		point += Vector2(0, -12)
		await frames()
	var dragged: float = list.scroll_offset()
	check(dragged > 90.0 and dragged < 120.0, "A finger drag scrolls by its travel past the slop: %s" % dragged)
	touch(point, false)
	await frames(3)
	check(list.scroll_offset() > dragged, "A flick glides on after the finger lifts")
	check(pressed[0] == 0, "Dragging over a row never presses it")
	check(await settle(func(): return not list.elastic.is_active()), "The glide comes to rest")
	list.stop_scrolling()
	list.get_v_scroll_bar().value = 0
	await frames(2)
	start = Vector2(150, 60)
	touch(start, true)
	point = start
	for i in 10:
		drag(point, point + Vector2(0, 20))
		point += Vector2(0, 20)
		await frames()
	check(list.scroll_offset() == 0.0 and list.stretch < 0.0 and rows.position.y > 0.0, "Dragging down at the top pulls the rows past the edge: %s" % rows.position.y)
	var bar := list.get_v_scroll_bar()
	var resting: Vector2 = list.elastic.thumb(240.0, 0.0, bar.max_value - bar.page, bar.page, 0.0, 16.0)
	var pulled: Vector2 = list.elastic.thumb(240.0, 0.0, bar.max_value - bar.page, bar.page, list.stretch, 16.0)
	check(list._bar_skin != null and list._bar_skin.visible and bar.self_modulate.a == 0.0 and pulled.y < resting.y and pulled.x == 0.0, "The scrollbar thumb shortens against the pulled top")
	touch(point, false)
	check(await settle(func(): return list.stretch == 0.0 and is_zero_approx(rows.position.y)), "Released rows spring back to the edge")
	check(not list._bar_skin.visible and bar.self_modulate.a == 1.0, "At rest the scrollbar draws itself again")
	list.queue_free()
	await frames()
