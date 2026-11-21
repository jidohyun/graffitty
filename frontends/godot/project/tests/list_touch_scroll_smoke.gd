extends "res://tests/mods_fixture.gd"
## A finger on a panel list scrolls it; a tap without movement activates the row.
## Touch goes through the viewport, as the sidebar docking does.

func touch(point: Vector2, down: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = point
	event.pressed = down
	root.push_input(event, true)

func drag(from: Vector2, to: Vector2, steps := 6) -> void:
	touch(from, true)
	await process_frame
	for i in range(1, steps + 1):
		var motion := InputEventScreenDrag.new()
		motion.index = 0
		motion.position = from.lerp(to, float(i) / steps)
		motion.relative = (to - from) / steps
		root.push_input(motion, true)
		await process_frame
	touch(to, false)
	await settle()

func run() -> void:
	setup(true)
	Input.emulate_mouse_from_touch = true
	var rows := []
	# Long enough that a flick glides mid-list rather than into its end.
	for i in 120: rows.append({"id": "test-%d" % i, "key": "%%%d" % i, "title": "Agent %d" % i, "provider": "pi", "status": "idle", "section": "Idle", "at": 0, "focused": false, "pinned": false, "remote": "", "session": ""})
	app.agents.rows = rows
	app.agents.changed.emit()
	var dialog: Window = PanelWindow.open(host, "agents")
	await settle()
	dialog.size = Vector2i(280, 300)
	await settle()
	check(dialog.load_error.is_empty(), "Agents mod loads on the embedded mobile window")
	var view: Control = dialog.view
	var list: Rect2 = view.hit_rect("ag-list")
	check(list.size.y > 0 and view.scroll_offset("ag-list") == 0, "List starts at the top")
	var origin: Vector2 = view.get_global_transform_with_canvas() * list.get_center()
	var window_origin := Vector2(dialog.position)
	await drag(window_origin + origin, window_origin + origin - Vector2(0, 120))
	check(view.scroll_offset("ag-list") > 0, "Dragging a finger across rows scrolls the list")
	check(view.scroll_offset("ag-list") > 125, "A flick keeps gliding past where the finger lifted")
	# A touch on a gliding list brakes it; it is not a tap on the row beneath.
	touch(window_origin + origin, true)
	await process_frame
	touch(window_origin + origin, false)
	pump()
	await settle()
	var rested: float = view.scroll_offset("ag-list")
	await settle()
	check(view.scroll_offset("ag-list") == rested, "The list rests once the glide ends")
	check(app.agents.focused.is_empty(), "A scroll is not a tap: no row was focused")
	# The first row fully inside the list after the glide.
	var tapped := ""
	var row := Rect2()
	for i in 120:
		var candidate: Rect2 = view.hit_rect("ag-test-%d" % i)
		if candidate.size.y > 0 and list.encloses(candidate):
			tapped = "test-%d" % i
			row = candidate
			break
	if check(not tapped.is_empty(), "A row is on screen after scrolling"):
		var at: Vector2 = window_origin + (view.get_global_transform_with_canvas() * row.get_center())
		touch(at, true)
		await process_frame
		touch(at, false)
		pump()
		await settle()
		check(app.agents.focused == tapped, "A tap without movement focuses the row once")
	var before: float = view.scroll_offset("ag-list")
	await drag(window_origin + origin, window_origin + origin + Vector2(0, 400))
	check(view.scroll_offset("ag-list") == 0 and before > 0, "Dragging back down returns to the top without overshooting")
	dialog.queue_free()
	await settle()
	finish("LIST_TOUCH_SCROLL")
