extends "../../../../tests/llm-e2e/replay/replay.gd"
## Sideways scrolling in the Resource Monitor inside the real application:
## docked in the left sidebar, narrower than its columns, with input pushed
## into the main window as AppKit delivers it.
const PanelWindow := preload("res://scenes/mods/PanelWindow.gd")

var dialog: Window

func column_x() -> float:
	return dialog.view.hit_rect("col-cpu").position.x

func push(event: InputEvent, over := "row") -> void:
	_pointer_in_window()
	var key := ""
	for candidate in dialog.view.hit_keys():
		if str(candidate).begins_with(over) and not "/" in str(candidate):
			key = str(candidate)
			break
	var at: Vector2 = dialog.view.get_screen_transform() * dialog.view.hit_rect(key).get_center()
	event.position = at
	if event is InputEventMouse:
		event.global_position = at
		event.device = 0xC0DE
	root.push_input(event, true)
	for i in 3: await process_frame

func play() -> void:
	await camera_at_rest()
	native_subwindows()
	dialog = PanelWindow.open(host, "resource-monitor")
	for i in 5: await process_frame
	var space: Control = preload("res://scenes/ListDockSpace.gd").for_window(host.get_window())
	space.commit(dialog._desktop, space.plan(dialog._desktop, Vector2(10, 400)))
	if space.widths.left < space.COMPACT_WIDTH * space.side_scale("left"):
		space.toggle_fold("left")
	for i in 8: await process_frame
	print("dock side=%s view=%s keys=%d" % [dialog._desktop.side, dialog.view.size, dialog.view.hit_keys().size()])
	check(dialog.view.hit_rect("columns").has_area() and not dialog.view.hit_rect("col-session").has_area(), "Columns wider than the sidebar scroll sideways")
	var start := column_x()
	var pan := InputEventPanGesture.new()
	pan.delta = Vector2(3, 0.2)
	await push(pan)
	check(column_x() < start, "A sideways trackpad swipe over the rows scrolls the columns (%.1f -> %.1f)" % [start, column_x()])
	var after := column_x()
	var tilt := InputEventMouseButton.new()
	tilt.button_index = MOUSE_BUTTON_WHEEL_RIGHT
	tilt.pressed = true
	tilt.factor = 1.0
	await push(tilt)
	check(column_x() < after, "A tilted wheel scrolls the columns (%.1f -> %.1f)" % [after, column_x()])
	after = column_x()
	var shifted := InputEventMouseButton.new()
	shifted.button_index = MOUSE_BUTTON_WHEEL_UP
	shifted.pressed = true
	shifted.shift_pressed = true
	shifted.factor = 1.0
	await push(shifted, "header")
	check(column_x() > after, "Shift+wheel over the header scrolls them back (%.1f -> %.1f)" % [after, column_x()])
