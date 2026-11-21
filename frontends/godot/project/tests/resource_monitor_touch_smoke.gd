extends "res://tests/mods_fixture.gd"
## The Resource Monitor on a phone: a finger slides the columns sideways when
## they are wider than the panel, and holding a header before dragging it
## reorders the columns.
##
## Touch goes through the viewport, as on a device.
const PaneTree := preload("res://scenes/WorkspaceLayout.gd")

func touch(point: Vector2, down: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.position = point
	event.pressed = down
	root.push_input(event, true)

func slide(from: Vector2, to: Vector2, hold := 0.0, steps := 6) -> void:
	touch(from, true)
	await process_frame
	if hold > 0.0:
		await create_timer(hold).timeout
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
	host.workspace_layout.tabs = [{"id": 1, "tree": {"windows": [PaneTree.leaf("%1"), PaneTree.leaf("%2")]}}]
	host.pane_focus = "%2"
	host.focused_key = ""
	app.mods.publish_window(host)
	var dialog: Window = PanelWindow.open(host, "resource-monitor")
	await settle()
	dialog.size = Vector2i(320, 300)
	await settle()
	check(dialog.load_error.is_empty() and dialog.view.last_error().is_empty(), "Resource Monitor loads on the embedded mobile window: " + dialog.view.last_error())
	var view: Control = dialog.view
	var to_screen := func(rect: Rect2) -> Vector2:
		return Vector2(dialog.position) + view.get_global_transform_with_canvas() * rect.get_center()
	check(view.hit_rect("columns").has_area() and not view.hit_rect("col-session").has_area(), "Columns wider than the panel start with the last column offscreen")
	# Measure a middle column: a hit rect is clipped to the panel's edge.
	var ram_x: float = view.hit_rect("col-memory").position.x
	var title_x: float = view.hit_rect("col-title").position.x
	var row := ""
	for key in view.hit_keys():
		if str(key).begins_with("row-") and not "/" in str(key): row = str(key)
	var start: Vector2 = to_screen.call(view.hit_rect(row))
	await slide(start, start - Vector2(200, 10))
	var moved: float = ram_x - view.hit_rect("col-memory").position.x
	check(moved > 100.0, "A finger sliding left scrolls the columns sideways (%.0f px)" % moved)
	check(host.focused_key.is_empty(), "A slide is not a tap: no pane was focused")
	await slide(start, start + Vector2(400, 0))
	# Releasing past the left edge springs the table back over several frames.
	var deadline := Time.get_ticks_msec() + 2000
	while not is_equal_approx(view.hit_rect("col-memory").position.x, ram_x) and Time.get_ticks_msec() < deadline:
		await process_frame
	check(is_equal_approx(view.hit_rect("col-memory").position.x, ram_x), "Sliding back returns to the first column (%.0f, %.0f)" % [view.hit_rect("col-memory").position.x, ram_x])

	# Hold CPU, then drag it before the title.
	var cpu: Vector2 = to_screen.call(view.hit_rect("col-cpu"))
	var title: Rect2 = view.hit_rect("col-title")
	var target: Vector2 = to_screen.call(Rect2(title.position, Vector2(4, title.size.y)))
	await slide(cpu, target, 0.7)
	check(view.hit_rect("col-cpu").position.x < view.hit_rect("col-title").position.x, "Holding a header, then dragging it, moves the column")
	check(is_equal_approx(view.hit_rect("col-cpu").position.x, title_x), "A held drag does not scroll the columns (%.0f, %.0f)" % [view.hit_rect("col-cpu").position.x, title_x])
	dialog.queue_free()
	await settle()
	finish("RESOURCE_MONITOR_TOUCH")
