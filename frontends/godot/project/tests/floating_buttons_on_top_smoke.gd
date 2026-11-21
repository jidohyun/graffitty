extends SceneTree
## Floating buttons are on top of everything: drawn over embedded windows
## (floating panels, dialogs), tapped through them, and tapping one never moves
## keyboard focus into a panel. Needs a real renderer: --position -32000,-32000.
const Floating := preload("res://scenes/input/FloatingButtons.gd")
var failures: Array[String] = []
var released := 0
var typed := []

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures.append(message)

func send(event: InputEvent) -> void:
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await process_frame

func touch(at: Vector2, down: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = down
	event.position = at
	await send(event)

func _initialize() -> void:
	Input.emulate_mouse_from_touch = true
	root.size = Vector2i(400, 300)
	root.gui_embed_subwindows = true
	var field := LineEdit.new()
	field.size = Vector2(120, 30)
	field.gui_input.connect(func(e): if e is InputEventKey and e.pressed: typed.append("field"))
	root.add_child(field)
	var floating := Floating.new()
	floating.preferences_path = OS.get_cache_dir().path_join("gft-on-top-%d.conf" % OS.get_process_id())
	floating.animate_layout = false
	var button := Button.new()
	floating.add("keyboard", button, Vector2(.5, .5), Callable(), func(): released += 1, true)
	root.add_child(floating)
	# A floating panel (embedded window) covering the button, holding focus.
	var panel := Window.new()
	panel.size = Vector2i(300, 220)
	panel.position = Vector2i(40, 40)
	var fill := ColorRect.new()
	fill.color = Color(0, 0, 1)
	fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(fill)
	var panel_touches := []
	fill.gui_input.connect(func(e): if e is InputEventScreenTouch: panel_touches.append(e))
	root.add_child(panel)
	panel.show()
	for i in 8: await process_frame
	panel.position = Vector2i(button.get_global_rect().get_center()) - panel.size / 2
	for i in 4: await process_frame
	panel.grab_focus()
	field.grab_focus()
	await process_frame
	var center := button.get_global_rect().get_center()
	check(Rect2(Vector2(panel.position), Vector2(panel.size)).has_point(center), "The panel covers the button")
	var image := root.get_viewport().get_texture().get_image()
	var pixel := image.get_pixelv(Vector2i(center + Vector2(0, button.size.y * .45)))
	check(not pixel.is_equal_approx(Color(0, 0, 1)), "The button is drawn over the embedded panel: %s" % pixel)
	await touch(center, true)
	await touch(center, false)
	check(released == 1 and panel_touches.is_empty(), "A tap over the panel reaches the button, not the panel")
	check(not panel.has_focus(), "Tapping the button leaves no panel focused")
	var key := InputEventKey.new()
	key.keycode = KEY_A
	key.unicode = 97
	key.pressed = true
	await send(key)
	check(typed == ["field"], "Typing after the tap still reaches the focused field: %s" % [typed])
	# Desktop touch-controls mode: a real mouse click is handed to the button too.
	for down in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = down
		click.position = center
		click.global_position = center
		click.device = 0
		await send(click)
	await process_frame
	check(released == 2, "A real mouse click on the button works over a panel")
	button.hide()
	await process_frame
	await process_frame
	await touch(center, true)
	await touch(center, false)
	check(panel_touches.size() >= 1, "A hidden button no longer takes the panel's touches")
	print("FLOATING_ON_TOP_PASS" if failures.is_empty() else "FLOATING_ON_TOP_FAIL")
	quit(0 if failures.is_empty() else 1)
