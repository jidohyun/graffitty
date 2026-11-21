extends "res://tests/unit/test_case.gd"
const Motion := preload("res://scenes/input/TouchScrollMotion.gd")

func flick(direction := 1.0) -> RefCounted:
	var motion := Motion.new()
	motion.begin(0)
	for time in [20, 40, 60, 80]: motion.track(Vector2(0, 20 * direction), time)
	motion.release(80)
	return motion

func test_fling_preserves_direction_and_decelerates() -> void:
	for direction in [-1.0, 1.0]:
		var motion := flick(direction)
		var first: Vector2 = motion.advance(100)
		var second: Vector2 = motion.advance(120)
		expect(first.y * direction > 0 and second.y * direction > 0, "Momentum follows either flick direction")
		expect(second.length() < first.length(), "Momentum decelerates continuously")
		# UIScrollView's deceleration: about 3.5 s for a 1000 px/s flick.
		motion.advance(8000)
		expect(motion.velocity == Vector2.ZERO, "Fling eventually stops")

func test_distance_is_independent_of_frame_rate() -> void:
	var totals: Array[float] = []
	for step in [8, 16, 33]:
		var motion := flick()
		var total := 0.0
		for now in range(80 + step, 8000, step): total += motion.advance(now).y
		totals.append(total)
	expect(absf(totals.max() - totals.min()) < 0.001, "60/120 Hz and slow frames travel the same distance")

func test_pause_and_new_touch_stop_momentum() -> void:
	var motion := flick()
	motion.begin(100)
	expect(motion.advance(200) == Vector2.ZERO, "New touch immediately stops the old fling")
	motion.track(Vector2(0, 100), 120)
	motion.release(300)
	expect(motion.advance(320) == Vector2.ZERO, "Holding still before lifting does not fling")
	motion = flick()
	motion.stop()
	expect(motion.advance(200) == Vector2.ZERO, "Cancellation stops momentum")

func test_repeated_flicks_build_speed_but_taps_and_reversals_reset_it() -> void:
	var motion := flick()
	motion.begin(180)
	expect(motion.advance(190) == Vector2.ZERO, "Repeated contact brakes while the finger is down")
	for time in [200, 220, 240, 260]: motion.track(Vector2(0, 20), time)
	motion.release(260)
	# Chromium's fling booster adds the gliding flick's launch speed.
	expect(absf(motion.velocity.y - 2000) < 1, "A quick repeated flick adds momentum")
	motion.begin(360)
	for time in [380, 400, 420, 440]: motion.track(Vector2(0, -20), time)
	motion.release(440)
	expect(absf(motion.velocity.y + 1000) < 1, "Reversing starts at normal speed")
	motion.begin(460)
	motion.release(480)
	expect(motion.advance(500) == Vector2.ZERO, "A braking tap never restarts the fling")
	motion.begin(540)
	for time in [560, 580, 600, 620]: motion.track(Vector2(0, -20), time)
	motion.release(620)
	expect(absf(motion.velocity.y + 1000) < 1, "A tap also clears the repeat boost")

func test_same_timestamp_contacts_and_stationary_start() -> void:
	var motion := Motion.new()
	motion.begin(0)
	for time in [1000, 1020, 1040, 1060]:
		for contact in 3: motion.track(Vector2(0, 20.0 / 3.0), time)
	motion.release(1060)
	expect(absf(motion.velocity.y - 1000) < 0.01, "Batched contacts estimate centroid speed after a stationary start")
