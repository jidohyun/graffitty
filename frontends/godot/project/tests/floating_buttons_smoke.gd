extends SceneTree
## Floating touch buttons: relative placement above the keyboard and across a
## folding phone's screens, tap versus drag, persistence, and touches that
## never fall through to the terminal.
##     godot --headless --path . --script tests/floating_buttons_smoke.gd
const Floating := preload("res://scenes/input/FloatingButtons.gd")
const Pointer := preload("res://scenes/input/MobilePointer.gd")
var failures := 0

class FakeHost extends RefCounted:
	pass

class FakeView extends Control:
	var host := FakeHost.new()
	var tab_bar: Control
	var toolbar: Control
	var monitor: Control
	var agent_links: Object = null
	var panes := {}
	func viewport_content_rect() -> Rect2: return get_viewport_rect()
	func cancel_tile_resize() -> void: pass


func _initialize() -> void:
	run.call_deferred()


func check(ok: bool, message: String) -> void:
	print("[floating] %s %s" % ["PASS" if ok else "FAIL", message])
	if not ok: failures += 1


func layer(path: String, fresh := true) -> CanvasLayer:
	if fresh: DirAccess.remove_absolute(path)
	var created: CanvasLayer = Floating.new()
	created.preferences_path = path
	created.animate_layout = false
	root.add_child(created)
	return created


func mouse(button: Button, global: Vector2, pressed := true) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = button.get_global_transform().affine_inverse() * global
	button.gui_input.emit(event)


func drag(button: Button, global: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = button.get_global_transform().affine_inverse() * global
	button.gui_input.emit(event)


func double_hold(buttons: CanvasLayer, button: Button) -> void:
	buttons.cancel_gesture()
	var center := button.get_global_rect().get_center()
	mouse(button, center)
	mouse(button, center, false)
	mouse(button, center)
	buttons._gesture.at -= Floating.HOLD_MS + 1
	buttons._process(0.0)


func run() -> void:
	var solver := preload("res://scenes/input/FloatingButtonLayout.gd")
	var reference := Vector2(800, 900)
	var homes := {"left": Rect2(8, 780, 52, 52), "right": Rect2(740, 780, 52, 52), "above": Rect2(740, 716, 52, 52)}
	var full: Dictionary = solver.solve(homes, reference, reference, Rect2(8, 8, 784, 884))
	var reduced: Dictionary = solver.solve(homes, reference, reference, Rect2(8, 8, 784, 584))
	check(reduced.right - reduced.above == full.right - full.above, "Obstructions translate a nearby group without compressing its spacing")
	var wide: Dictionary = solver.solve(homes, reference, Vector2(1200, 900), Rect2(8, 8, 1184, 884))
	check(wide.left == full.left and wide.right.x == full.right.x + 400, "Opposite edge groups spread on wider windows")
	var tiny_bounds := Rect2(8, 8, 170, 150)
	var tiny: Dictionary = solver.solve(homes, reference, Vector2(186, 166), tiny_bounds)
	for id in tiny:
		check(tiny_bounds.encloses(Rect2(tiny[id], homes[id].size)), "Small window keeps " + id + " in bounds")
		for other in tiny:
			if id != other: check(not Rect2(tiny[id], homes[id].size).intersects(Rect2(tiny[other], homes[other].size)), "Small window separates " + id + " and " + other)
	check(solver.solve(homes, reference, reference, Rect2(8, 8, 784, 884)) == full, "Restoring bounds restores preferences without accumulated movement")
	var path := OS.get_cache_dir().path_join("graffitty-floating-%d.conf" % Time.get_ticks_usec())
	var original := root.size
	root.size = Vector2i(820, 960)
	await process_frame
	var buttons := layer(path)
	var corner := Button.new()
	var middle := Button.new()
	buttons.add("corner", corner, Vector2.ONE)
	buttons.add("middle", middle, Vector2(.5, .5))
	var view := root.get_visible_rect().size
	check(corner.position == view - Vector2(8, 8) - Floating.SIZE, "A bottom-right anchor sits in the corner")
	buttons.set_bottom_inset(300)
	check(corner.position == Vector2(view.x - 8, view.y - 300 - 8) - Floating.SIZE, "Opening the keyboard lifts the button above it")
	check(middle.get_rect().get_center().is_equal_approx(Vector2(view.x / 2, view.y / 2)), "An unobstructed button stays still when available bounds shrink")
	buttons.set_bottom_inset(0)
	root.size = Vector2i(430, 900)
	await process_frame
	view = root.get_visible_rect().size
	check(corner.position == view - Vector2(8, 8) - Floating.SIZE, "A folding screen change keeps the corner")
	check(middle.get_rect().get_center().is_equal_approx(view / 2), "and the relative middle")
	root.size = Vector2i(1200, 900)
	await process_frame
	buttons._save_position("corner", Vector2(800, 600))
	buttons.layout()
	check(corner.position.is_equal_approx(Vector2(800, 600)), "A deliberate move after expansion saves the exact new position")
	check(corner.is_in_group(Floating.CHROME) and corner.focus_mode == Control.FOCUS_NONE, "Buttons are tappable chrome that never take keyboard focus")
	buttons.free()

	buttons = layer(path)
	var calls: Array[String] = []
	var button := Button.new()
	buttons.add("mic", button, Vector2.ONE, func(): calls.append("press"), func(): calls.append("release"), false, func(): calls.append("cancel"))
	var start := button.position
	var center := button.get_global_rect().get_center()
	mouse(button, center)
	drag(button, center + Vector2(4, -4))
	mouse(button, center + Vector2(4, -4), false)
	check(calls == ["press", "release"] and button.position == start, "A small wobble is still a tap")
	calls.clear()
	mouse(button, center)
	drag(button, center + Vector2(-200, -150))
	mouse(button, center + Vector2(-200, -150), false)
	check(calls == ["press", "release"] and button.position == start, "Even an immediate large movement stays a microphone gesture")
	calls.clear()
	double_hold(buttons, button)
	drag(button, center + Vector2(-200, -150))
	mouse(button, center + Vector2(-200, -150), false)
	check(calls == ["press", "release", "press", "cancel"], "Double-tap and hold cancels the first tap's action and consumes the second release")
	check(button.position.is_equal_approx(start + Vector2(-200, -150)), "The button follows the finger")
	double_hold(buttons, button)
	drag(button, Vector2(-5000, -5000))
	mouse(button, Vector2(-5000, -5000), false)
	check(button.position == Vector2(8, 8), "Dragging stops at the edge of the window")
	check(buttons._gesture.is_empty(), "Releasing the drag immediately restores ordinary gestures")
	double_hold(buttons, button)
	drag(button, Vector2(200, 200))
	buttons.cancel_gesture()
	await create_timer(.4).timeout
	check(button.position == Vector2(8, 8), "An interrupted move returns to the last saved position")
	var held := Button.new()
	calls.clear()
	buttons.add("keyboard", held, Vector2(.5, .5), Callable(), func(): calls.append("keyboard"), true)
	var spot := held.position
	mouse(held, held.get_global_rect().get_center())
	buttons._gesture.at -= Floating.HOLD_MS + 1
	buttons._process(0.0)
	drag(held, held.get_global_rect().get_center() + Vector2(60, 0))
	mouse(held, held.get_global_rect().get_center() + Vector2(60, 0), false)
	check(calls.is_empty() and held.position.x > spot.x + 40, "Holding the keyboard unlocks movement without toggling it")
	mouse(held, held.get_global_rect().get_center())
	mouse(held, held.get_global_rect().get_center(), false)
	check(calls == ["keyboard"], "A quick keyboard tap still toggles it")
	calls.clear()
	spot = held.position
	mouse(held, held.get_global_rect().get_center())
	drag(held, held.get_global_rect().get_center() + Vector2(60, 0))
	mouse(held, held.get_global_rect().get_center(), false)
	check(calls.is_empty() and held.position == spot, "A quick swipe neither moves the keyboard nor toggles it")
	var touch := InputEventScreenTouch.new()
	touch.index = 2
	touch.position = button.size / 2
	touch.pressed = true
	button.gui_input.emit(touch)
	var other := InputEventScreenTouch.new()
	other.index = 3
	buttons._input(other)
	check(calls == ["press"], "Another finger cannot release the active microphone gesture")
	touch.pressed = false
	touch.canceled = true
	buttons._input(touch)
	check(calls == ["press", "cancel"] and buttons._gesture.is_empty(), "System cancellation reaches the active recording and clears capture")
	buttons.movement_allowed = func(): return false
	double_hold(buttons, button)
	check(not buttons._gesture.dragging, "A gesture that starts while the microphone is busy cannot reposition it")
	buttons.cancel_gesture()
	buttons.free()
	buttons = layer(path, false)
	var again := Button.new()
	buttons.add("mic", again, Vector2.ONE)
	check(again.position == Vector2(8, 8), "A moved button keeps its place after restart")
	buttons.free()
	DirAccess.remove_absolute(path)

	buttons = layer(path)
	var pill := preload("res://scenes/input/TextSizeButton.gd").new()
	var steps: Array[int] = []
	pill.stepped.connect(func(direction): steps.append(direction))
	buttons.add("text_size", pill, Vector2(.5, 1), Callable(), pill.activate, true, pill.cancel)
	check(pill.size == Vector2(104, 52) and pill.pivot_offset == pill.size / 2, "The text-size pill preserves both full-size tap targets")
	for fraction in [.25, .75]:
		var at: Vector2 = pill.get_global_transform() * Vector2(pill.size.x * fraction, pill.size.y / 2)
		mouse(pill, at)
		mouse(pill, at, false)
		await create_timer(.36).timeout
	check(steps == [-1, 1], "Left tap shrinks and right tap enlarges")
	steps.clear()
	for index in [0, 1]:
		var contact := InputEventScreenTouch.new()
		contact.index = index
		contact.pressed = true
		contact.position = Vector2(pill.size.x * (.25 if index == 0 else .75), pill.size.y / 2)
		pill.gui_input.emit(contact)
	buttons._finish()
	check(steps == [-1], "A second finger cannot change the first finger's minus/plus target")
	steps.clear()
	var left_target: Vector2 = pill.get_global_transform() * Vector2(pill.size.x * .25, pill.size.y / 2)
	mouse(pill, left_target)
	drag(pill, left_target + Vector2(80, 0))
	mouse(pill, left_target + Vector2(80, 0), false)
	var right_target: Vector2 = pill.get_global_transform() * Vector2(pill.size.x * .75, pill.size.y / 2)
	mouse(pill, right_target)
	mouse(pill, right_target, false)
	check(steps == [1], "A canceled swipe clears the half before the next tap")
	steps.clear()
	spot = pill.position
	mouse(pill, pill.get_global_rect().get_center())
	buttons._gesture.at -= Floating.HOLD_MS + 1
	buttons._process(0.0)
	drag(pill, pill.get_global_rect().get_center() + Vector2(30, -80))
	mouse(pill, pill.get_global_rect().get_center(), false)
	check(steps.is_empty() and pill.position.distance_to(spot) > 50, "Holding the pill moves it without changing text size")
	var anchor: Vector2 = buttons.entries.text_size.anchor
	buttons.free()
	buttons = layer(path, false)
	pill = preload("res://scenes/input/TextSizeButton.gd").new()
	buttons.add("text_size", pill, Vector2.ZERO)
	check(buttons.entries.text_size.anchor == anchor, "The pill restores its own saved position")
	buttons.free()
	DirAccess.remove_absolute(path)

	var fake := FakeView.new()
	var pointer: Control = Pointer.new()
	pointer.view = fake
	root.add_child(fake)
	root.add_child(pointer)
	var overlay := CanvasLayer.new()
	var chrome := Button.new()
	chrome.position = Vector2(100, 100)
	chrome.size = Vector2(52, 52)
	chrome.add_to_group(Floating.CHROME)
	overlay.add_child(chrome)
	root.add_child(overlay)
	check(not pointer._accept_start(Vector2(120, 120)), "A touch on floating chrome stays with the control")
	check(pointer._accept_start(Vector2(300, 400)), "A touch elsewhere still reaches the workspace")
	chrome.hide()
	check(pointer._accept_start(Vector2(120, 120)), "Hidden chrome does not block the workspace")
	# A floating (undocked) tool panel is non-modal: only its own frame keeps
	# the touch; elsewhere the workspace still pans and pinches.
	var embedded := root.gui_embed_subwindows
	root.gui_embed_subwindows = true
	var panel: Window = preload("res://scenes/DockableWindow.gd").new()
	root.add_child(panel)
	panel.position = Vector2i(200, 200)
	panel.size = Vector2i(200, 150)
	panel.show()
	var title: float = panel.floating_title_height()
	check(not pointer._accept_start(Vector2(250, 250)), "A floating panel keeps touches on its body")
	check(not pointer._accept_start(Vector2(250, 200 - title / 2)), "A floating panel keeps touches on its title")
	check(pointer._accept_start(Vector2(600, 500)), "Outside a floating panel, the workspace still pans and pinches")
	var modal := Window.new()
	modal.size = Vector2i(100, 100)
	root.add_child(modal)
	modal.show()
	check(not pointer._accept_start(Vector2(600, 500)), "Other windows still block the whole workspace")
	modal.free()
	panel.free()
	root.gui_embed_subwindows = embedded
	overlay.free()
	fake.free()
	pointer.free()
	root.size = original
	print("FLOATING_BUTTONS_%s" % ["PASS" if failures == 0 else "FAIL"])
	quit(0 if failures == 0 else 1)
