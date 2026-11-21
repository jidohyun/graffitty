extends SceneTree
## One- and three-finger scrolling through MobilePointer into a native terminal's scrollback.
## godot --headless --path . --script tests/touch_scroll_smoke.gd
var failures := 0

class ScrollPointer extends "res://scenes/input/MobilePointer.gd":
	var now := 0
	var drag_scroll := false
	var target := "%1"
	var pointer_events: Array[InputEventMouse] = []
	# This fixture presents one terminal without workspace chrome. Keep the
	# production input handler and deferred scroll dispatch into that terminal.
	func _accept_start(_position: Vector2) -> bool: return true
	func _drag_scrolls(_position: Vector2) -> bool: return drag_scroll
	func _scroll_target(_position: Vector2) -> String: return target
	func _pointer(event: InputEventMouse) -> void: pointer_events.append(event)
	var terminal: Control
	func _fling_scrolled(sequence: int) -> Variant: return terminal.touch_scrolled(sequence)

class View extends Control:
	var host := RefCounted.new()
	var agent_links: Node
	var panes := {}
	func cancel_tile_resize() -> void: pass

func _initialize() -> void:
	var isolated := OS.get_cache_dir().path_join("graffitty-touch-scroll-%d" % OS.get_process_id())
	for kind in ["CONFIG", "STATE", "DATA", "CACHE"]:
		OS.set_environment("XDG_%s_HOME" % kind, isolated.path_join(kind.to_lower()))
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	print(("PASS " if ok else "FAIL ") + message)
	if not ok: failures += 1

func settle() -> void:
	await process_frame
	await process_frame

func touch(pointer: Control, index: int, pressed: bool, now := -1) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = pressed
	event.position = Vector2(160 + index * 30, 150)
	if not pressed:
		event.position = pointer.gestures.fingers.get(index, event.position)
	pointer.now = Time.get_ticks_msec() if now < 0 else now
	pointer._input(event)

func drag(pointer: Control, y: float, now: int, count: int) -> void:
	for index in count:
		var event := InputEventScreenDrag.new()
		event.index = index
		event.position = Vector2(160 + index * 30, y)
		pointer.now = now
		pointer._input(event)

func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 400)
	root.add_child(viewport)
	var terminal: Control = ClassDB.instantiate("Terminal")
	var copies: Array[String] = []
	terminal.copied.connect(func(value): copies.append(value))
	terminal.remote_mode = true
	terminal.size = Vector2(640, 400)
	viewport.add_child(terminal)
	var view := View.new()
	view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(view)
	var pointer := ScrollPointer.new()
	pointer.view = view
	pointer.clock_msec = func(): return pointer.now
	pointer.terminal = terminal
	viewport.add_child(pointer)
	# Inject deterministic contacts through the production input handler.
	pointer.set_process_input(false)
	pointer.set_process(false)
	await settle()
	terminal.remote_feed_stream("history\r\n".repeat(100).to_utf8_buffer(), 80, 20, false, false)
	viewport.notify_mouse_entered()
	await settle()
	for count in [1, 3]:
		pointer.drag_scroll = count == 1
		terminal.scroll_to_position(40.0)
		var before: float = terminal.get_ui_state().scroll_offset + terminal.get_scroll_fraction()
		for index in count: touch(pointer, index, true, 0)
		drag(pointer, 210, 150, count)
		await settle()
		var after: float = terminal.get_ui_state().scroll_offset + terminal.get_scroll_fraction()
		check(after < before, "%d-finger downward drag reveals older terminal history" % count)
		terminal.perform_action("copy")
		await settle()
		check(copies.is_empty(), "Scrolling creates no terminal selection")
		drag(pointer, 150, 200, count)
		await settle()
		var restored: float = terminal.get_ui_state().scroll_offset + terminal.get_scroll_fraction()
		check(is_equal_approx(restored, before), "Reverse drag restores the original scroll position")
		for index in count: touch(pointer, index, false, 210)
		await settle()
		pointer.gestures.cancel()
		terminal.scroll_to_position(40.0)
		for index in count: touch(pointer, index, true, 1000)
		for offset in [20, 40, 60, 80]: drag(pointer, 150 + offset, 1000 + offset, count)
		for index in count: touch(pointer, index, false, 1090 + index)
		await settle()
		var released: float = terminal.get_ui_state().scroll_offset + terminal.get_scroll_fraction()
		pointer.gestures.advance(1120)
		await settle()
		var coasting: float = terminal.get_ui_state().scroll_offset + terminal.get_scroll_fraction()
		check(coasting < released, "Native terminal keeps scrolling after fingers lift")
		var emulated := InputEventMouseButton.new()
		emulated.device = -1
		emulated.button_index = MOUSE_BUTTON_LEFT
		emulated.pressed = true
		emulated.position = Vector2(160, 150)
		pointer._input(emulated)
		touch(pointer, 0, true, 1130)
		pointer.gestures.advance(1150)
		await settle()
		check(is_equal_approx(terminal.get_ui_state().scroll_offset + terminal.get_scroll_fraction(), coasting), "New contact stops native momentum immediately")
		if count == 1:
			touch(pointer, 0, false, 1170)
			check(pointer.pointer_events.is_empty(), "Stopping momentum cannot click, even when an emulated mouse event arrives first")
			touch(pointer, 0, true, 1200)
			drag(pointer, 190, 1340, count)
			touch(pointer, 0, false, 1360)
			await settle()
			check(pointer.pointer_events.is_empty(), "A quick scroll after braking cannot become a double-tap selection")
			check(terminal.get_ui_state().scroll_offset + terminal.get_scroll_fraction() < coasting, "Scrolling resumes normally after braking")
		pointer.gestures.cancel()
	# Equal swipes should scroll farther on subsequent releases, without
	# multiplying finger travel or turning the repeat into a selection.
	for count in [1, 3]:
		pointer.drag_scroll = count == 1
		pointer.pointer_events.clear()
		pointer.target = "%1"
		var first_coast := 0.0
		var previous_coast := 0.0
		for repeat_index in 4:
			if repeat_index == 3: pointer.target = "%2"
			terminal.scroll_to_position(40.0)
			var start := 2000 + repeat_index * 180
			for index in count: touch(pointer, index, true, start)
			for offset in [20, 40, 60, 80]: drag(pointer, 150 + offset, start + offset, count)
			for index in count: touch(pointer, index, false, start + 80)
			await settle()
			var released: float = terminal.get_ui_state().scroll_offset + terminal.get_scroll_fraction()
			# Rows follow the finger exactly, as a Chromium page does: 80 px of
			# travel moves 80 px of rows at this unscaled terminal.
			var row: float = terminal.get_visible_area().cell_size.y
			check(absf((40.0 - released) - 80.0 / row) < 0.001, "Repeated %d-finger drag keeps its original distance (%.3f rows of %.1f px)" % [count, 40.0 - released, row])
			pointer.gestures.advance(start + 160)
			await settle()
			var coast: float = released - terminal.get_ui_state().scroll_offset - terminal.get_scroll_fraction()
			if repeat_index == 3:
				check(is_equal_approx(coast, first_coast), "Touching a different pane resets %d-finger acceleration" % count)
			else:
				check(coast > previous_coast, "Repeated %d-finger flick builds native terminal momentum" % count)
			if repeat_index == 0: first_coast = coast
			previous_coast = coast
		check(pointer.pointer_events.is_empty(), "Repeated flicks never click or select")
		pointer.gestures.cancel()
	# A hard flick into the top of the scrollback bounces there. As in Chromium,
	# whose fling stops at an update that scrolls nothing, the fling ends with
	# it: the next tap is a tap, not a brake on content that no longer moves.
	pointer.drag_scroll = true
	pointer.target = "%1"
	pointer.pointer_events.clear()
	terminal.scroll_to_position(2.0)
	touch(pointer, 0, true, 5000)
	for step in range(1, 5): drag(pointer, 150 + step * 40, 5000 + step * 8, 1)
	touch(pointer, 0, false, 5040)
	await settle()
	var frame := 5040
	for step in 40:
		frame += 16
		pointer.gestures.advance(frame)
		await settle()
	check(terminal.get_ui_state().scroll_offset == 0, "A hard flick runs into the top of the scrollback")
	touch(pointer, 0, true, frame + 20)
	touch(pointer, 0, false, frame + 60)
	pointer.gestures.advance(frame + 500)
	await settle()
	check(pointer.pointer_events.any(func(event): return event is InputEventMouseButton and event.pressed), "A tap after the flick hit the top is a tap, not a brake (%d pointer events)" % pointer.pointer_events.size())
	pointer.gestures.cancel()
	viewport.queue_free()
	await settle()
	quit(0 if failures == 0 else 1)
