extends "../../../../tests/llm-e2e/replay/replay.gd"

func send_pointer(event: InputEventMouse) -> void:
	_pointer_in_window()
	event.device = 0xC0DE
	event.position = host.workspace_view.size * .5
	event.global_position = event.position
	root.push_input(event, true)
	await process_frame

func play() -> void:
	await camera_at_rest()
	var view: Control = host.workspace_view
	var initial: float = view.navigation_zoom
	var wheel := InputEventMouseButton.new()
	wheel.meta_pressed = true
	wheel.pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	await send_pointer(wheel)
	check(view.navigation_zoom < initial, "Cmd+wheel down zooms out")
	var zoomed: float = view.navigation_zoom
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	await send_pointer(wheel)
	check(view.navigation_zoom > zoomed, "Cmd+wheel up zooms in")
	var pan := InputEventPanGesture.new()
	pan.meta_pressed = true
	pan.position = view.size * .5
	pan.delta = Vector2(0, 5)
	root.push_input(pan, true)
	await process_frame
	check(view.navigation_zoom < initial, "Cmd+trackpad scroll zooms out")
	var start: Vector2 = view.navigation_center
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_RIGHT
	button.pressed = true
	button.meta_pressed = false
	await send_pointer(button)
	check(view._navigation_press != null and not view._navigation_drag, "Right press waits for drag threshold")
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(120, 0)
	motion.button_mask = MOUSE_BUTTON_MASK_RIGHT
	await send_pointer(motion)
	check(view.navigation_center.x < start.x, "Dragging right moves the workspace right")
	button.pressed = false
	button.meta_pressed = false
	await send_pointer(button)
	check(not view._navigation_drag and view._held == 0, "Right release ends pan")
	# A wheel notch eases out like a pinch: part lands at once, the rest over
	# the next frames, never overshooting, and the whole step arrives.
	var before: float = view.navigation_zoom
	wheel.meta_pressed = true
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	await send_pointer(wheel)
	var path: Array[float] = [view.navigation_zoom]
	var deadline := Time.get_ticks_msec() + 400
	while Time.get_ticks_msec() < deadline:
		await process_frame
		path.append(view.navigation_zoom)
	var target := before / 1.15
	check(path[0] < before and path[0] > target * 1.01, "A wheel notch responds at once without jumping the whole step (%.4f of %.4f -> %.4f)" % [path[0], before, target])
	var monotonic := true
	var steps := 0
	for i in range(1, path.size()):
		monotonic = monotonic and path[i] <= path[i - 1] + 1e-6
		if path[i] < path[i - 1] - 1e-6: steps += 1
	check(monotonic and steps >= 3, "The notch eases over several frames (%d steps)" % steps)
	check(absf(path.back() - target) < target * 0.002, "The whole notch arrives (%.4f, wanted %.4f)" % [path.back(), target])
