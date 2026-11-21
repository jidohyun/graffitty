extends SceneTree
## Android sends emulated mouse events before each original touch event.
var failures := 0
var selections: Array[int] = []
var clicks: Array[bool] = []

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func touch(button: Button, down: bool) -> void:
	var point := button.get_global_rect().get_center()
	var mouse := InputEventMouseButton.new()
	mouse.device = -1
	mouse.position = point
	mouse.global_position = point
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	mouse.pressed = down
	root.push_input(mouse, true)
	var event := InputEventScreenTouch.new()
	event.position = point
	event.pressed = down
	root.push_input(event, true)

func _initialize() -> void:
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("graffitty-tab-touch-%d" % OS.get_process_id()))
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(700, 240)
	var strip := preload("res://scenes/TabStrip.gd").new()
	strip.connected_tabs = true
	strip.size = Vector2(650, 44)
	root.add_child(strip)
	var pages := [{"id": 1, "title": "First"}, {"id": 2, "title": "Second"}]
	strip.selected.connect(func(id): selections.append(id); strip.reconcile(pages, id))
	strip.clicked.connect(func(_id, was_selected): clicks.append(was_selected))
	strip.reconcile(pages, 1)
	await process_frame
	await process_frame
	for id in [2, 1, 1]:
		var before := selections.size()
		touch(strip.buttons[id], true)
		touch(strip.buttons[id], false)
		check(selections.size() == before + 1, "Touch selects exactly once")
		check(strip.selected_id == id and strip.buttons[id].button_pressed, "Selected tab remains pressed after Android touch release")
		check(not strip.buttons[3 - id].button_pressed, "Other tab remains unselected")
	check(clicks == [false, false, true], "Retapping the active tab preserves the existing click action")
	strip.free()
	quit.call_deferred(failures)
