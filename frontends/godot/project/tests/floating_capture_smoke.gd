extends SceneTree
const Floating := preload("res://scenes/input/FloatingButtons.gd")
var failures := 0
var hovered := 0
var clicked := 0

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-floating-capture-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func expect(value: bool, message: String) -> void:
	if not value: failures += 1
	print(("PASS " if value else "FAIL ") + message)

func mouse(point: Vector2, device := 0) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.device = device
	root.push_input(event)

func touch(point: Vector2, pressed: bool, canceled := false) -> void:
	var event := InputEventScreenTouch.new()
	event.position = point
	event.index = 0
	event.pressed = pressed
	event.canceled = canceled
	root.push_input(event)

func run() -> void:
	root.size = Vector2i(520, 400)
	root.content_scale_size = Vector2i.ZERO
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_factor = 1
	root.gui_embed_subwindows = true
	root.notify_mouse_entered()
	var target := Button.new()
	target.text = "Settings"
	target.position = Vector2(140, 180)
	target.size = Vector2(180, 60)
	target.mouse_entered.connect(func(): hovered += 1)
	target.pressed.connect(func(): clicked += 1)
	root.add_child(target)
	var floating := Floating.new()
	floating.preferences_path = OS.get_cache_dir().path_join("floating-capture-%d.conf" % OS.get_process_id())
	root.add_child(floating)
	var button := Button.new()
	button.text = "Drag"
	floating.add("test", button, Vector2.ZERO, Callable(), Callable(), true)
	if DisplayServer.get_name() != "headless": root.grab_focus()
	await create_timer(.5).timeout
	var point := target.get_global_rect().get_center()
	mouse(point)
	expect(root.gui_get_hovered_control() == target and hovered > 0, "Fixture receives actual GUI hover before capture")
	mouse(button.get_global_rect().get_center())
	hovered = 0
	touch(button.get_global_rect().get_center(), true)
	var deadline := Time.get_ticks_msec() + 2000
	while not floating._gesture.is_empty() and not floating._gesture.get("dragging", false) and Time.get_ticks_msec() < deadline:
		await process_frame
	expect(floating._gesture.get("dragging", false), "Hold begins repositioning")
	# Godot performs hover hit-testing before _input, including emulated mouse.
	mouse(point, -1)
	expect(root.gui_get_hovered_control() == floating._pointer_capture.shield, "Capture owns hit-testing before input delivery")
	expect(hovered == 0 and clicked == 0, "Underlying tab gets neither hover feedback nor activation")
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = point
	root.push_input(drag)
	expect(not floating._gesture.is_empty() and button.position.x > 50, "Global drag continues through capture surface")
	touch(point, false)
	expect(floating._gesture.is_empty() and not floating._pointer_capture.visible and clicked == 0, "Release clears capture without clicking through")
	await create_timer(.4).timeout
	touch(button.get_global_rect().get_center(), true)
	floating.cancel_gesture()
	expect(not floating._pointer_capture.visible, "Cancellation releases capture")
	touch(button.get_global_rect().get_center(), true)
	button.hide()
	await process_frame
	await process_frame
	expect(floating._gesture.is_empty() and not floating._pointer_capture.visible, "Hiding a held control cannot leave an input shield behind")
	mouse(point)
	touch(point, true)
	touch(point, false)
	# Mouse activation also verifies GUI focus/press routing was restored.
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.position = point
		event.pressed = pressed
		root.push_input(event)
	expect(clicked > 0, "Underlying controls work normally after capture")
	floating.queue_free()
	target.queue_free()
	await process_frame
	quit(1 if failures else 0)
