extends SceneTree
## Real touch dispatch, with deterministic elapsed time for accessory-key holds.

class RecordedTerminal extends Node:
	var keys: Array[InputEventKey] = []
	func send_key(event: InputEventKey) -> void: keys.append(event.duplicate())

class CommandLine extends Node:
	var keys: Array[InputEventKey] = []
	func handle_key(event: InputEventKey) -> void: keys.append(event.duplicate())

class Host extends Node:
	var active_session_id := 1
	var pane_focus := "%1"
	var sessions := {}
	var command_line := CommandLine.new()
	var command_open := false
	func command_line_open() -> bool: return command_open
	func is_terminal_pane(key: String) -> bool: return key.begins_with("%")

var failures := 0

func check(ok: bool, message: String) -> void:
	print("PASS " if ok else "FAIL ", message)
	if not ok: failures += 1

func touch(button: Control, down: bool, index := 0, canceled := false) -> void:
	var event := InputEventScreenTouch.new()
	event.position = button.get_global_rect().get_center()
	event.pressed = down
	event.index = index
	event.canceled = canceled
	# Match Android's actual delivery order. A bare ScreenTouch misses the
	# duplicate pressed signal caused by its preceding emulated mouse event.
	if index == 0:
		var mouse := InputEventMouseButton.new()
		mouse.device = -1
		mouse.position = event.position
		mouse.global_position = event.position
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		mouse.pressed = down
		mouse.canceled = canceled
		root.push_input(mouse, true)
	root.push_input(event, true)

## A finger sliding from `from` to `to`, with Android's emulated mouse.
## Let a released strip's glide and rubber band finish: a clock that runs
## ahead in frame steps, then the real one again.
func settle(bar: Control) -> void:
	var later := Time.get_ticks_msec()
	for frame in 600:
		if not bar.elastic.is_active(): break
		later += 16
		bar.clock_msec = func() -> int: return later
		bar._process(0.016)
	bar.clock_msec = Time.get_ticks_msec

func swipe(from: Vector2, to: Vector2, steps := 6) -> void:
	for down in [true, false]:
		var at := from if down else to
		var mouse := InputEventMouseButton.new()
		mouse.device = -1
		mouse.position = at
		mouse.global_position = at
		mouse.button_index = MOUSE_BUTTON_LEFT
		mouse.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		mouse.pressed = down
		root.push_input(mouse, true)
		var finger := InputEventScreenTouch.new()
		finger.position = at
		finger.pressed = down
		root.push_input(finger, true)
		await process_frame
		if not down: break
		for step in range(1, steps + 1):
			var motion := InputEventScreenDrag.new()
			motion.position = from.lerp(to, float(step) / steps)
			motion.relative = (to - from) / steps
			root.push_input(motion, true)
			var moved := InputEventMouseMotion.new()
			moved.device = -1
			moved.position = motion.position
			moved.global_position = motion.position
			moved.relative = motion.relative
			moved.button_mask = MOUSE_BUTTON_MASK_LEFT
			root.push_input(moved, true)
			await process_frame

## The default strip on a phone-width screen: it opens at Copy/Paste and a
## sideways drag, even one starting on a key, reaches the navigation keys.
func narrow_strip(host: Host, terminal: RecordedTerminal) -> void:
	var screen := Control.new()
	screen.size = Vector2(300, 240)
	root.add_child(screen)
	var bar := preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.host = host
	screen.add_child(bar)
	bar.show()
	await process_frame
	await process_frame
	var names := bar.buttons.keys().map(func(key): return String(key))
	check(names.slice(0, 2) == ["copy", "paste"] and names.slice(-4) == ["home", "end", "page_up", "page_down"], "Default strip starts with Copy/Paste and ends with the navigation keys")
	var view := bar.track.get_global_rect()
	check(bar.size.y == bar.HEIGHT and bar.strip_left == 0 and view.encloses(bar.buttons.copy.get_global_rect()) and not view.intersects(bar.buttons.page_down.get_global_rect()), "A narrow strip opens at its left end with the navigation keys off screen")
	# Route a phased pan through the key under the pointer.
	bar.slide_strip(bar.strip_range().x)
	for phase in ["began", "changed", "ended"]:
		var pan := InputEventPanGesture.new()
		pan.position = bar.buttons.page_down.get_global_rect().get_center()
		pan.delta = Vector2.ZERO if phase == "ended" else Vector2(40, 0)
		pan.set_meta("scroll_phase", phase)
		pan.set_meta("touch_travel", true)
		root.push_input(pan, true)
	check(bar.stretch > 0, "Trackpad panning over a key stretches the strip at its right end")
	settle(bar)
	check(bar.stretch == 0 and is_equal_approx(bar.strip_left, bar.strip_range().x), "Trackpad release settles at the same edge")
	for start in ["escape", "ctrl", "left"]:
		bar.slide_strip(0)
		await process_frame
		terminal.keys.clear()
		var from: Vector2 = bar.buttons[start].get_global_rect().get_center()
		# Short enough to lift on the key it started on: only the scroll, not
		# leaving the key, may cancel its tap.
		await swipe(from, from - Vector2(14, 0))
		# The slow drag may still leave a short glide; it is not under test here.
		bar.stop_glide()
		bar._process(1.0)
		check(bar.strip_left <= -14 and bar.strip_left > -40, "Dragging from %s scrolls the strip with the finger" % start)
		# An arrow sends on touch down, before the touch is known to be a drag.
		check(terminal.keys.size() == (2 if start == "left" else 0) and bar.modifiers.is_empty() and bar.held_arrow == null, "Dragging from %s taps nothing further, latches nothing and leaves no repeat" % start)
	bar.stop_glide()
	terminal.keys.clear()
	touch(bar.buttons.escape, true)
	touch(bar.buttons.escape, false)
	check(terminal.keys.size() == 2 and terminal.keys[0].keycode == KEY_ESCAPE, "A tap after scrolling activates exactly once")
	var far: Vector2 = bar.buttons.shift.get_global_rect().get_center()
	await swipe(far, far - Vector2(400, 0))
	settle(bar)
	check(bar.track.get_global_rect().encloses(bar.buttons.page_down.get_global_rect()) and is_equal_approx(bar.buttons.page_down.get_global_rect().end.x, view.end.x), "Scrolled to the end, the strip stops with its last key at the screen's right edge")
	terminal.keys.clear()
	for name in ["home", "end", "page_up", "page_down"]:
		touch(bar.buttons[name], true)
		touch(bar.buttons[name], false)
	var codes := []
	for key in terminal.keys:
		if key.pressed: codes.append(key.keycode)
	check(terminal.keys.size() == 8 and codes == [KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN], "Each navigation key sends one balanced key after scrolling")
	# The other way, the strip follows the finger until its left end is at
	# mid-screen, so the left-hand keys come under the right thumb.
	far = bar.track.get_global_rect().position + Vector2(20, 18)
	for pass_index in 3:
		await swipe(far, far + Vector2(260, 0), 12)
		settle(bar)
	var middle := view.position.x + view.size.x / 2.0
	check(is_equal_approx(bar.buttons.copy.get_global_rect().position.x, middle), "Slid right, the strip stops with Copy at mid-screen: %s" % bar.strip_left)
	terminal.keys.clear()
	touch(bar.buttons.escape, true)
	touch(bar.buttons.escape, false)
	check(terminal.keys.size() == 2 and terminal.keys[0].keycode == KEY_ESCAPE, "Keys still tap where the strip was slid to")
	bar.free()
	screen.free()
	await flick_strip(host, terminal)
	# A screen wide enough for every key: right-aligned at rest, and it still
	# slides right as far as mid-screen and back, never further left.
	screen = Control.new()
	screen.size = Vector2(880, 240)
	root.add_child(screen)
	bar = preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.host = host
	screen.add_child(bar)
	bar.show()
	await process_frame
	await process_frame
	view = bar.track.get_global_rect()
	var rest: float = bar.strip_left
	check(rest > 0 and is_equal_approx(bar.buttons.page_down.get_global_rect().end.x, view.end.x) and view.encloses(bar.buttons.copy.get_global_rect()), "A wide screen shows the whole strip right-aligned")
	far = bar.buttons.tab.get_global_rect().get_center()
	await swipe(far, far + Vector2(400, 0), 12)
	settle(bar)
	check(is_equal_approx(bar.buttons.copy.get_global_rect().position.x, view.position.x + view.size.x / 2.0), "On a wide screen the strip slides right until Copy is at mid-screen")
	far = bar.buttons.copy.get_global_rect().get_center()
	await swipe(far, far - Vector2(430, 0), 12)
	settle(bar)
	check(bar.strip_left == rest, "Slid back, it stops right-aligned and goes no further left")
	bar.free()
	screen.free()

## A flick: the strip keeps gliding after the finger lifts, slows to a stop,
## and a touch on it while it glides brakes it without tapping a key.
func flick_strip(host: Host, terminal: RecordedTerminal) -> void:
	var screen := Control.new()
	screen.size = Vector2(300, 240)
	root.add_child(screen)
	var bar := preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.host = host
	var clock := {"now": 1000}
	bar.clock_msec = func() -> int: return clock.now
	screen.add_child(bar)
	bar.show()
	await process_frame
	await process_frame
	var flick := func(from: Vector2, step: float) -> void:
		var finger := InputEventScreenTouch.new()
		finger.position = from
		finger.pressed = true
		root.push_input(finger, true)
		for index in range(1, 7):
			clock.now += 8
			var drag := InputEventScreenDrag.new()
			drag.position = from + Vector2(step * index, 0)
			drag.relative = Vector2(step, 0)
			root.push_input(drag, true)
		clock.now += 8
		finger = InputEventScreenTouch.new()
		finger.position = from + Vector2(step * 6, 0)
		root.push_input(finger, true)
	terminal.keys.clear()
	var from: Vector2 = bar.buttons.shift.get_global_rect().get_center()
	flick.call(from, -10.0)
	var lifted: float = bar.strip_left
	check(lifted == -60 and bar.gliding and bar.is_processing(), "A flick leaves the strip gliding where the finger lifted")
	var places := [lifted]
	for frame in 12:
		clock.now += 16
		bar._process(0.016)
		places.append(bar.strip_left)
	var first: float = places[0] - places[1]
	var later: float = places[6] - places[7]
	check(places[12] < lifted - 20 and first > 0 and later < first, "The glide carries the strip on and slows down: %s" % [places])
	# Brake it with a touch on a key and an arrow: neither taps.
	check(bar.gliding, "It is still gliding when touched")
	touch(bar.buttons.left, true)
	await process_frame
	check(not bar.gliding and terminal.keys.is_empty() and bar.held_arrow == null, "Touching a gliding strip stops it without sending the arrow under the finger")
	touch(bar.buttons.left, false)
	var rested: float = bar.strip_left
	for frame in 5:
		clock.now += 16
		bar._process(0.016)
	check(bar.strip_left == rested and terminal.keys.is_empty() and not bar.is_processing(), "The braked strip stays put and idles")
	touch(bar.buttons.left, true)
	touch(bar.buttons.left, false)
	check(terminal.keys.size() == 2, "The next tap is a key press again")
	# A hard flick runs into the end and stops there.
	from = bar.buttons.left.get_global_rect().get_center()
	flick.call(from, -40.0)
	var pulled := 0.0
	for frame in 200:
		clock.now += 16
		if bar.elastic.is_active(): bar._process(0.016)
		pulled = maxf(pulled, bar.stretch)
	check(pulled > 0.0, "A hard flick runs past the strip's end and stretches: %s" % pulled)
	check(bar.strip_left == bar.strip_range().x and bar.stretch == 0.0 and bar.row.position.x == bar.strip_range().x and not bar.gliding and not bar.is_processing(), "It springs back and stops at the strip's end: %s")
	# Dragged past its end, the strip follows the finger with resistance and
	# springs back on release, tapping nothing.
	terminal.keys.clear()
	from = bar.buttons.end.get_global_rect().get_center()
	var finger := InputEventScreenTouch.new()
	finger.position = from
	finger.pressed = true
	root.push_input(finger, true)
	for index in range(1, 6):
		clock.now += 40
		var drag := InputEventScreenDrag.new()
		drag.position = from + Vector2(-12.0 * index, 0)
		drag.relative = Vector2(-12, 0)
		root.push_input(drag, true)
	var held: float = bar.stretch
	check(held > 0.0 and held < 60.0 and bar.row.position.x < bar.strip_range().x, "Dragged past the end, the strip stretches less than the finger moved: %s" % held)
	clock.now += 200
	finger = InputEventScreenTouch.new()
	finger.position = from + Vector2(-60, 0)
	root.push_input(finger, true)
	for frame in 200:
		clock.now += 16
		if bar.elastic.is_active(): bar._process(0.016)
	check(bar.stretch == 0.0 and bar.row.position.x == bar.strip_range().x and terminal.keys.is_empty() and bar.modifiers.is_empty() and not bar.is_processing(), "Released, it springs back without tapping a key")
	bar.free()
	screen.free()

func _initialize() -> void:
	OS.set_environment("XDG_CONFIG_HOME", OS.get_cache_dir().path_join("graffitty-arrow-test-%d" % OS.get_process_id()))
	call_deferred("run")

func run() -> void:
	root.size = Vector2i(900, 240)
	var host := Host.new()
	var terminal := RecordedTerminal.new()
	var other := RecordedTerminal.new()
	host.sessions = {1: {"term": terminal}, 2: {"term": other}}
	var bar := preload("res://scenes/input/TouchKeyBar.gd").new()
	bar.host = host
	root.add_child(bar)
	bar.show()
	await process_frame
	await process_frame
	for name in ["left", "down", "up", "right"]:
		var before := terminal.keys.size()
		touch(bar.buttons[name], true)
		check(terminal.keys.size() == before + 2, name + " sends immediately on touch down")
		touch(bar.buttons[name], false)
		bar._process(1.0)
		check(terminal.keys.size() == before + 2 and bar.held_arrow == null, name + " tap sends one balanced key with no release-time duplicate")
	var rapid_before := terminal.keys.size()
	for index in 2:
		touch(bar.buttons.left, true)
		touch(bar.buttons.left, false)
	check(terminal.keys.size() == rapid_before + 4, "Two rapid taps still send two arrows")
	var mouse := InputEventMouseButton.new()
	mouse.position = bar.buttons.right.get_global_rect().get_center()
	mouse.global_position = mouse.position
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	var mouse_before := terminal.keys.size()
	root.push_input(mouse, true)
	bar._process(0.45)
	mouse.pressed = false
	root.push_input(mouse, true)
	check(terminal.keys.size() == mouse_before + 4 and bar.held_arrow == null, "A real mouse press still sends and repeats arrows")
	terminal.keys.clear()
	bar.cycle_modifier("ctrl")
	bar.cycle_modifier("shift")
	touch(bar.buttons.left, true)
	bar._process(0.44)
	check(terminal.keys.size() == 2, "Hold waits before repeating")
	bar._process(0.010001)
	check(terminal.keys.size() == 4, "Repeat begins at 450 ms")
	for index in 12:
		bar._process(0.08 - index * 0.005)
	check(terminal.keys.size() == 28, "Repeats accelerate from 80 ms to 20 ms")
	for index in 30: bar._process(1.0 / 60.0)
	check(terminal.keys.size() >= 76 and terminal.keys.size() <= 78, "At 60 FPS the fast hold delivers 50 keys per second")
	var balanced := terminal.keys.size() % 2 == 0
	for index in terminal.keys.size():
		var key := terminal.keys[index]
		balanced = balanced and key.pressed == (index % 2 == 0) and not key.echo and key.ctrl_pressed and key.shift_pressed
	check(balanced and bar.modifiers.is_empty(), "Every repeat retains the consumed Ctrl+Shift chord on both edges")
	var before := terminal.keys.size()
	touch(bar.buttons.left, false)
	bar._process(2.0)
	check(terminal.keys.size() == before, "Releasing stops fast repeat")
	touch(bar.buttons.left, true)
	check(not terminal.keys[-2].shift_pressed and not terminal.keys[-2].ctrl_pressed, "A new hold does not inherit one-shot modifiers")
	bar._process(10.0)
	check(terminal.keys.size() == before + 4, "A stalled frame cannot flood the terminal with catch-up input")
	touch(bar.buttons.left, false, 0, true)
	bar._process(1.0)
	check(bar.held_arrow == null and terminal.keys.size() == before + 4, "Canceled Android touch stops repeat")
	touch(bar.buttons.right, true)
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = bar.buttons.right.get_global_rect().position - Vector2(10, 10)
	root.push_input(drag, true)
	check(bar.held_arrow == null, "Dragging outside cancels the hold")
	touch(bar.buttons.right, false)
	touch(bar.buttons.left, true)
	touch(bar.buttons.right, true, 1)
	touch(bar.buttons.left, false)
	touch(bar.buttons.right, false, 1)
	check(bar.held_arrow == null, "Multiple fingers cannot leave a repeating key behind")
	for reason in ["hide", "focus", "session", "pane", "command"]:
		touch(bar.buttons.left, true)
		before = terminal.keys.size()
		match reason:
			"hide": bar.hide()
			"focus": bar._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
			"session": host.active_session_id = 2
			"pane": host.pane_focus = "browser:1"
			"command": host.command_open = true
		bar._process(1.0)
		check(bar.held_arrow == null and terminal.keys.size() == before and other.keys.is_empty(), reason + " change cancels without sending to another target")
		touch(bar.buttons.left, false)
		host.active_session_id = 1
		host.pane_focus = "%1"
		host.command_open = false
		bar.show()
	host.command_open = true
	bar.update_host()
	bar.cycle_modifier("shift")
	before = terminal.keys.size()
	touch(bar.buttons.up, true)
	bar._process(0.45)
	touch(bar.buttons.up, false)
	check(host.command_line.keys.size() == 2 and terminal.keys.size() == before, "Command-line arrows repeat without reaching the terminal")
	check(host.command_line.keys.all(func(key): return key.shift_pressed) and bar.pressed_keys.is_empty(), "Command-line repeats preserve Shift and clear key tracking")
	bar.free()
	host.command_open = false
	await narrow_strip(host, terminal)
	terminal.free()
	other.free()
	host.command_line.free()
	host.free()
	# Let the coroutine release its local references before engine shutdown.
	quit.call_deferred(failures)
