extends "res://tests/unit/test_case.gd"
const Gestures := preload("res://scenes/input/TouchNavigation.gd")
var events: Array = []
func model() -> RefCounted:
	var g := Gestures.new()
	g.pointer.connect(func(event): events.append(event))
	g.pinch.connect(func(a, b, factor): events.append([a,b,factor]))
	g.scroll.connect(func(anchor, delta, stage):
		if stage != "ended": events.append({"anchor": anchor, "delta": delta}))
	return g
func touch(g: RefCounted, index: int, down: bool, at: Vector2, time: int) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index; event.pressed = down; event.position = at
	g.handle(event,time)
func move(g: RefCounted, index: int, at: Vector2, time: int) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index; event.position = at
	g.handle(event,time)
func test_direct_tap_and_double_tap() -> void:
	var g := model()
	touch(g,0,true,Vector2(50,60),0)
	expect(events.is_empty(), "First contact waits briefly for a second finger")
	touch(g,0,false,Vector2(50,60),50)
	expect(events.size()==2 and events[0].position==Vector2(50,60) and events[0].pressed and not events[1].pressed,"A single tap clicks at the finger")
	touch(g,0,true,Vector2(52,61),150)
	g.advance(150 + g.PINCH_GRACE_MS)
	expect(events[2].double_click,"Second tap carries double-click semantics for titles")
	g.cancel()
	expect(not events.back().pressed and events.back().canceled and g.fingers.is_empty(),"Cancellation releases pointer explicitly")
func test_direct_drag_and_long_press() -> void:
	var g := model()
	touch(g,0,true,Vector2(10,10),0)
	move(g,0,Vector2(12,12),10)
	expect(events.is_empty(),"Finger jitter does not move pane")
	move(g,0,Vector2(40,20),20)
	expect(events.is_empty(), "Early movement is buffered while a pinch can begin")
	g.advance(g.PINCH_GRACE_MS)
	expect(events[1] is InputEventMouseMotion and events[1].position==Vector2(40,20) and events[1].button_mask==MOUSE_BUTTON_MASK_LEFT,"Drag follows finger with button held")
	g.advance(800)
	expect(events.size()==2,"Dragging cannot turn into long press")
	g.cancel(); events.clear()
	touch(g,0,true,Vector2(30,40),1000)
	g.advance(1600)
	expect(events.size()==2 and events[0].button_index==MOUSE_BUTTON_RIGHT and events[0].pressed,"Stationary long press opens context action")

func test_recording_clock_keeps_short_holds_out_of_long_press() -> void:
	var pointer := preload("res://scenes/input/MobilePointer.gd").new()
	var tick := [1000]
	pointer.clock_msec = func(): return tick[0]
	pointer.gestures = model()
	touch(pointer.gestures, 0, true, Vector2(30,40), tick[0])
	tick[0] = 1170
	pointer._process(1.0 / 60)
	expect(events.size()==1 and events[0].button_index==MOUSE_BUTTON_LEFT and events[0].pressed,
		"A 170 ms recorded hold stays a left press regardless of encoding wall time")
	tick[0] = 1900
	pointer._process(1.0 / 60)
	expect(pointer.gestures.long_pressed and events.any(func(event): return event.button_index==MOUSE_BUTTON_RIGHT),
		"A real long hold on the injected clock still triggers the context action")
	pointer.gestures.cancel()
	pointer.free()
func test_pinch_releases_drag_and_keeps_both_anchors() -> void:
	var g := model()
	touch(g,0,true,Vector2.ZERO,0)
	touch(g,1,true,Vector2(100,0),10)
	expect(events.is_empty() and not g.held,"Second finger discards the pending click completely")
	move(g,1,Vector2(150,0),30)
	expect(events.is_empty(), "Early pinch waits for a possible third finger")
	g.advance(10 + g.SCROLL_GRACE_MS)
	expect(events.back()==[Vector2(50,0),Vector2(75,0),1.5],"Existing pinch anchors and factor stay intact")
	var count := events.size()
	touch(g,1,false,Vector2(150,0),140)
	move(g,0,Vector2(70,0),150)
	touch(g,0,false,Vector2(70,0),160)
	expect(events.size()==count+1 and events.back()==[Vector2.ZERO,Vector2(70,0),1.0],"Remaining finger pans without becoming a pointer drag")

func test_pan_survives_lift_and_rejoin_without_jumps_or_grace() -> void:
	for survivor in [0, 1]:
		var g := model()
		events.clear()
		touch(g, 0, true, Vector2(100,100), 0)
		touch(g, 1, true, Vector2(200,100), 10)
		g.advance(150)
		var remaining := Vector2(100 + 100 * survivor, 100)
		touch(g, 1-survivor, false, Vector2(200 - 100 * survivor,100), 160)
		expect(events.is_empty(), "Lifting either contact cannot jump the camera")
		move(g, survivor, remaining + Vector2(20,30), 170)
		expect(events.back() == [remaining, remaining+Vector2(20,30),1.0], "Single remaining contact keeps panning with fixed zoom")
		g.advance(900)
		expect(events.size() == 1, "Remaining contact cannot long press or select")
		var joined := remaining + Vector2(120,30)
		touch(g, 7, true, joined, 910)
		expect(events.size() == 1, "A replacement finger establishes a new baseline without movement")
		move(g, 7, joined + Vector2(20,0), 920)
		expect(events.size() == 2 and is_equal_approx(events.back()[2],1.2), "Pinching resumes immediately from the new distance")
		g.cancel()
		events.clear()
		touch(g, 0, true, Vector2.ZERO, 1000)
		touch(g, 0, false, Vector2.ZERO, 1020)
		expect(events.size() == 2 and events[0] is InputEventMouseButton, "Cancellation restores normal single-finger taps")

func test_late_pinch_cancels_selection_without_offscreen_motion() -> void:
	var g := model()
	touch(g, 0, true, Vector2(40, 50), 0)
	g.advance(g.PINCH_GRACE_MS)
	move(g, 0, Vector2(80, 50), 160)
	touch(g, 1, true, Vector2(180, 50), 200)
	expect(events.size() == 3 and events.back().canceled and not events.back().pressed, "Late second finger explicitly cancels an active drag")
	expect(events.back().position == Vector2(80, 50), "Cancellation never moves the pointer to the edge of terminal history")
	var count := events.size()
	touch(g, 2, true, Vector2(200, 50), 210)
	expect(events.size() == count, "Additional fingers cannot restart or repeat pointer cancellation")
	g.cancel()
	touch(g, 0, true, Vector2(80, 50), 230)
	touch(g, 0, false, Vector2(80, 50), 250)
	expect(not events[-2].double_click, "A canceled gesture cannot turn the next tap into word selection")

func test_quick_one_finger_drag_flushes_before_release() -> void:
	var g := model()
	touch(g, 0, true, Vector2(20, 30), 0)
	move(g, 0, Vector2(60, 50), 40)
	touch(g, 0, false, Vector2(70, 50), 80)
	expect(events.size() == 3 and events[0].pressed and events[1] is InputEventMouseMotion and not events[2].pressed, "A quick drag still delivers press, motion, release in order")
	expect(events[1].relative == Vector2(50, 20), "Buffered movement includes the full finger displacement")
func test_distant_taps_are_independent() -> void:
	var g := model()
	touch(g,0,true,Vector2.ZERO,0); touch(g,0,false,Vector2.ZERO,50)
	touch(g,0,true,Vector2(300,300),150)
	g.advance(150 + g.PINCH_GRACE_MS)
	expect(not events.back().double_click,"Separate controls receive independent single taps")

func test_three_finger_scroll_tracks_centroid_and_latches_on_release() -> void:
	var g := model()
	for index in 3:
		touch(g, index, true, Vector2(100 + index * 30, 100), index * 10)
	for index in 3:
		move(g, index, Vector2(100 + index * 30, 160), 40 + index)
	expect(events.size() == 3, "Three-finger movement emits scroll only, without click or pinch")
	var total := Vector2.ZERO
	for event in events:
		expect(event is Dictionary and event.anchor == Vector2(130, 100), "Scroll stays anchored to its starting pane")
		total += event.delta
	expect(total == Vector2(0, 60), "Moving all three contacts 60 pixels scrolls 60 pixels, not 180")
	touch(g, 2, false, Vector2(160, 160), 60)
	move(g, 1, Vector2(130, 200), 70)
	touch(g, 1, false, Vector2(130, 200), 80)
	move(g, 0, Vector2(100, 200), 90)
	touch(g, 0, false, Vector2(100, 200), 100)
	expect(events.size() == 3, "Lifting fingers cannot turn scrolling into pinch, selection, or click")
	touch(g, 0, true, Vector2.ZERO, 120)
	touch(g, 1, true, Vector2(100, 0), 130)
	move(g, 1, Vector2(150, 0), 140)
	g.advance(130 + g.SCROLL_GRACE_MS)
	expect(events.back() == [Vector2(50, 0), Vector2(75, 0), 1.5], "A fresh two-finger gesture still pinches")

func test_scroll_cancellation_and_extra_contact_do_not_jump() -> void:
	var g := model()
	for index in 3:
		touch(g, index, true, Vector2(index * 30, 100), index * 10)
	touch(g, 3, true, Vector2(900, 900), 40)
	move(g, 3, Vector2(900, 1000), 50)
	touch(g, 3, false, Vector2(900, 1000), 60)
	move(g, 0, Vector2(0, 130), 70)
	expect(events.size() == 1 and events[0].delta == Vector2(0, 10), "Extra contact pauses scrolling without a centroid jump")
	g.cancel()
	events.clear()
	touch(g, 0, true, Vector2(50, 50), 100)
	touch(g, 0, false, Vector2(50, 50), 120)
	expect(events.size() == 2 and events[0] is InputEventMouseButton, "Canceling scroll restores ordinary taps")

func test_third_finger_discards_buffered_pan_and_zoom() -> void:
	var g := model()
	touch(g, 0, true, Vector2(100, 100), 0)
	touch(g, 1, true, Vector2(200, 100), 30)
	move(g, 0, Vector2(100, 120), 50)
	move(g, 1, Vector2(240, 120), 70)
	g.advance(75)
	expect(events.is_empty(), "Staggered contacts cannot select, pan, or zoom during the grace period")
	touch(g, 2, true, Vector2(170, 120), 78)
	g.advance(300)
	expect(events.is_empty(), "Third finger discards buffered workspace movement")
	move(g, 2, Vector2(170, 150), 310)
	expect(events.size() == 1 and events[0] is Dictionary and events[0].delta == Vector2(0, 10), "Scrolling starts without replaying buffered pinch")

func test_moving_contacts_commit_before_stationary_grace() -> void:
	var g := model()
	g.set_drag_scroll(true)
	touch(g, 0, true, Vector2(50, 60), 0)
	move(g, 0, Vector2(50, 100), 30)
	g.advance(50)
	expect(events == [{"anchor": Vector2(50, 60), "delta": Vector2(0, 40)}], "A clear terminal swipe scrolls without waiting for the stationary grace")
	g.cancel()
	events.clear()
	g.set_drag_scroll(false)
	touch(g, 0, true, Vector2.ZERO, 1000)
	touch(g, 1, true, Vector2(100, 0), 1010)
	g.advance(1060)
	expect(events.is_empty(), "Stationary contacts keep the full wait for a third finger")
	move(g, 1, Vector2(150, 0), 1020)
	g.advance(1060)
	expect(events == [[Vector2(50, 0), Vector2(75, 0), 1.5]], "A clearly moving pinch starts early with its original anchors")
	g.cancel()

func test_pending_pinch_release_and_cancel_do_not_move_workspace() -> void:
	var g := model()
	touch(g, 0, true, Vector2.ZERO, 0)
	touch(g, 1, true, Vector2(100, 0), 10)
	move(g, 1, Vector2(150, 0), 30)
	touch(g, 1, false, Vector2(150, 0), 40)
	move(g, 0, Vector2(30, 20), 50)
	g.advance(300)
	expect(events.is_empty(), "Releasing an uncommitted pinch discards motion")
	g.cancel()
	g.advance(500)
	expect(events.is_empty(), "Cancellation cannot replay buffered motion later")

func test_scroll_continues_after_release_and_new_touch_stops_it() -> void:
	var g := model()
	for index in 3: touch(g, index, true, Vector2(index * 30, 100), 0)
	for time in [20, 40, 60, 80]:
		for index in 3: move(g, index, Vector2(index * 30, 100 + time), time)
	for index in 3: touch(g, index, false, Vector2(index * 30, 180), 90 + index)
	events.clear()
	g.advance(110)
	expect(events.size() == 1 and events[0] is Dictionary and events[0].delta.y > 0, "Released three-finger flick continues scrolling")
	touch(g, 0, true, Vector2(50, 50), 120)
	events.clear()
	g.advance(140)
	expect(events.is_empty(), "A new touch immediately arrests momentum")

func test_terminal_drag_scroll_never_presses_or_selects() -> void:
	for quick in [false, true]:
		var g := model()
		g.set_drag_scroll(true)
		events.clear()
		touch(g, 0, true, Vector2(50, 60), 0)
		g.advance(20 if quick else 250)
		expect(events.is_empty() and not g.held, "Waiting to scroll cannot send a terminal mouse press")
		move(g, 0, Vector2(52, 62), 30 if quick else 260)
		expect(events.is_empty(), "Touch jitter cannot scroll or select")
		move(g, 0, Vector2(50, 120), 40 if quick else 280)
		touch(g, 0, false, Vector2(50, 120), 80 if quick else 300)
		expect(events.size() == 1 and events[0] == {"anchor": Vector2(50, 60), "delta": Vector2(0, 60)}, "Slow and quick drags scroll the full distance without a click")
		g.advance(320)
		expect(events.size() == 2 and events.back() is Dictionary and events.back().delta.y > 0, "One-finger flick keeps scrolling after release")
		touch(g, 0, true, Vector2(50, 120), 330)
		events.clear()
		g.advance(470)
		expect(events.is_empty(), "New touch stops momentum without a mouse press")
		touch(g, 0, false, Vector2(50, 120), 480)
		expect(events.is_empty(), "A tap that stops momentum cannot also click")
		touch(g, 0, true, Vector2(50, 120), 520)
		move(g, 0, Vector2(50, 160), 650)
		touch(g, 0, false, Vector2(50, 160), 670)
		expect(events.size() == 1 and events[0] is Dictionary, "A braking tap cannot turn the next scroll into double-tap selection")
		g.cancel()

func test_terminal_tap_jitter_does_not_drag_between_cells() -> void:
	var g := model()
	g.set_drag_scroll(true)
	touch(g, 0, true, Vector2(50, 60), 0)
	var now := 30
	for offset in [Vector2(4, 0), Vector2(-4, 3), Vector2(2, -4)]:
		move(g, 0, Vector2(50, 60) + offset, now)
		g.advance(now)
		now += 30
	g.advance(130)
	expect(events.is_empty() and not g.held, "Tap jitter sends no press or drag before finger lift")
	touch(g, 0, false, Vector2(55, 64), 180)
	expect(events.size() == 2 and events[0].pressed and not events[1].pressed, "A slightly unsteady tap still clicks once")
	expect(events.all(func(event): return event.position == Vector2(50, 60)), "Tap press and release stay in the same cell")

func test_terminal_release_only_swipe_and_returning_drag_cannot_click() -> void:
	var g := model()
	g.set_drag_scroll(true)
	touch(g, 0, true, Vector2(50, 60), 0)
	touch(g, 0, false, Vector2(50, 100), 60)
	expect(events == [{"anchor": Vector2(50, 60), "delta": Vector2(0, 40)}], "Finger-up displacement is a scroll even without intermediate motion events")
	g.cancel()
	events.clear()
	touch(g, 0, true, Vector2(50, 60), 1000)
	move(g, 0, Vector2(50, 90), 1020)
	move(g, 0, Vector2(50, 60), 1040)
	touch(g, 0, false, Vector2(50, 60), 1060)
	expect(events.all(func(event): return event is Dictionary), "Returning to the start after crossing the drag threshold never becomes a click")
	# Lifted while moving back up, it flings, as Chromium measures release
	# speed; stop that glide so the touch below is a tap, not a brake.
	g.stop_scroll()
	events.clear()
	touch(g, 0, true, Vector2(50, 60), 1100)
	touch(g, 0, false, Vector2(50, 60), 1140)
	expect(events.size() == 2 and not events[0].double_click, "A drag ending at its start cannot arm double-tap selection")

func test_terminal_double_tap_requires_close_and_quick_taps() -> void:
	for second in [[Vector2(80, 60), 150], [Vector2(52, 61), 400]]:
		var g := model()
		g.set_drag_scroll(true)
		events.clear()
		touch(g, 0, true, Vector2(50, 60), 0)
		touch(g, 0, false, Vector2(50, 60), 50)
		events.clear()
		touch(g, 0, true, second[0], second[1])
		move(g, 0, second[0] + Vector2(0, 60), second[1] + 130)
		touch(g, 0, false, second[0] + Vector2(0, 60), second[1] + 160)
		expect(events.size() == 1 and events[0] is Dictionary, "A displaced or delayed second touch scrolls instead of selecting")
		g.cancel()

func test_terminal_slow_release_cannot_click_after_a_missed_timer() -> void:
	var g := model()
	g.set_drag_scroll(true)
	touch(g, 0, true, Vector2(50, 60), 0)
	touch(g, 0, false, Vector2(50, 60), 600)
	expect(events.is_empty(), "An overdue hold is not a click when no frame processed its long-press timer")
	touch(g, 0, true, Vector2(50, 60), 650)
	move(g, 0, Vector2(50, 120), 800)
	expect(events.size() == 1 and events[0] is Dictionary, "An overdue hold cannot arm double-tap selection")
	g.cancel()

func test_terminal_double_tap_drag_selects_and_long_press_still_works() -> void:
	var g := model()
	g.set_drag_scroll(true)
	touch(g, 0, true, Vector2(50, 60), 0)
	touch(g, 0, false, Vector2(50, 60), 50)
	expect(events.size() == 2 and events[0].pressed and not events[1].pressed, "Single tap still clicks in scroll mode")
	events.clear()
	touch(g, 0, true, Vector2(52, 61), 150)
	move(g, 0, Vector2(90, 90), 180)
	touch(g, 0, false, Vector2(110, 100), 220)
	expect(events.size() == 3 and events[0].double_click and events[0].pressed and events[1] is InputEventMouseMotion and not events[2].pressed, "Double-tap drag delivers a double-click selection drag, even before the grace period")
	expect(events[1].position == Vector2(110, 100), "Selection includes the complete buffered drag")
	events.clear()
	touch(g, 0, true, Vector2(50, 60), 1000)
	g.advance(1200)
	g.advance(1600)
	expect(events.size() == 2 and events[0].button_index == MOUSE_BUTTON_RIGHT and not g.held, "Long press opens the context action without an accidental left click")
	g.cancel()

func test_terminal_scroll_can_become_pinch_without_selection() -> void:
	var g := model()
	g.set_drag_scroll(true)
	touch(g, 0, true, Vector2(50, 60), 0)
	move(g, 0, Vector2(50, 100), 150)
	expect(events.size() == 1 and events[0] is Dictionary, "Single finger starts scrolling")
	events.clear()
	touch(g, 1, true, Vector2(150, 100), 160)
	move(g, 1, Vector2(200, 100), 170)
	g.advance(290)
	expect(events == [[Vector2(100, 100), Vector2(125, 100), 1.5]], "Second finger starts a pinch from its own anchors without replaying scrolling")
	touch(g, 1, false, Vector2(200, 100), 300)
	move(g, 0, Vector2(60, 110), 310)
	expect(events.back() == [Vector2(50, 100), Vector2(60, 110), 1.0], "Pinch survivor keeps panning instead of selecting or scrolling")
	g.cancel()
	events.clear()
	g.advance(500)
	expect(events.is_empty(), "Canceling clears momentum and pending gestures")

class Application extends "res://scenes/TerminalApplication.gd":
	var test_path: String
	func presentation_path() -> String: return test_path

func test_terminal_scroll_preference_persists_with_main_view_setting() -> void:
	var app := Application.new()
	app.test_path = cache_directory().path_join("touch-presentation-%d.conf" % OS.get_process_id())
	DirAccess.remove_absolute(app.test_path)
	expect(app.terminal_touch_scroll_fingers == 1 and app._load_terminal_touch_scroll_fingers() == 1, "One-finger scrolling is the default")
	app.set_terminal_touch_scroll_fingers(3)
	app.set_fit_main_view(false)
	var reloaded := Application.new()
	reloaded.test_path = app.test_path
	reloaded.terminal_touch_scroll_fingers = reloaded._load_terminal_touch_scroll_fingers()
	reloaded.fit_main_view = reloaded._load_fit_main_view()
	expect(reloaded.terminal_touch_scroll_fingers == 3 and not reloaded.fit_main_view, "Three-finger preference survives restart and main view changes")
	reloaded.set_terminal_touch_scroll_fingers(1)
	expect(app._load_terminal_touch_scroll_fingers() == 1 and not app._load_fit_main_view(), "Changing touch mode preserves the main view preference")
	reloaded.set_terminal_touch_scroll_fingers(2)
	expect(reloaded.terminal_touch_scroll_fingers == 1, "Unsupported finger counts are rejected")
	for invalid in [2, "3", 3.0, true]:
		var config := ConfigFile.new()
		config.set_value("touch", "terminal_scroll_fingers", invalid)
		config.save(app.test_path)
		expect(app._load_terminal_touch_scroll_fingers() == 1, "Invalid saved values use the default")
	DirAccess.remove_absolute(app.test_path)
	reloaded.free()
	app.free()
