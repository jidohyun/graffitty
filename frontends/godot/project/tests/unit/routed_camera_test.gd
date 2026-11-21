extends "res://tests/unit/test_case.gd"
const Motion := preload("res://scenes/CameraMotion.gd")

func test_reversal_reuses_curve_and_keeps_displayed_velocity() -> void:
	var start := frame_at(Vector3.ZERO)
	var end := frame_at(Vector3(30, 0, 0))
	var route := PackedVector3Array([Vector3(8, 5, 3), Vector3(22, 3, -2)])
	var reference := Motion.new()
	reference.reset(start)
	reference.retarget(end, 2.1, route)
	var samples := PackedVector3Array([Vector3.ZERO])
	for i in 2000:
		reference.advance(2.1 / 2000.0)
		samples.append(reference.frame.transform.origin)
	var motion := Motion.new()
	motion.reset(start)
	motion.retarget(end, 2.1, route)
	motion.advance(0.8)
	var before: Dictionary = motion.frame.duplicate()
	var speed: Vector3 = motion.velocity
	expect(motion.retarget_on_path(start, 2.1), "An interrupted A→B can return to A on the same curve")
	expect(motion.frame == before, "Reversing never jumps position, orientation or lens")
	motion.advance(0.00001)
	expect(motion.velocity.distance_to(speed) < 0.02, "Reversal brakes from incoming vector velocity")
	var peak: float = motion._path_clock(0.0).x
	var turned := false
	for i in 500:
		motion.advance(motion.duration / 500.0)
		var at: float = motion._path_clock(motion.elapsed / motion.duration).x
		if at < peak: turned = true
		peak = maxf(peak, at)
		var nearest := INF
		for point in samples: nearest = minf(nearest, point.distance_to(motion.frame.transform.origin))
		if not expect(nearest < 0.04, "Every reverse-flight frame remains on the original curve"): break
	expect(turned and motion.frame == start and not motion.moving, "Return lands at A exactly and at rest")

func test_repeated_reversal_and_resize_keep_the_route() -> void:
	var motion := Motion.new()
	var start := frame_at(Vector3.ZERO)
	var end := frame_at(Vector3(30, 0, 0))
	motion.reset(start)
	motion.retarget(end, 2.1, PackedVector3Array([Vector3(10, 4, 0), Vector3(20, 4, 0)]))
	motion.advance(.9)
	var geometry: PackedVector3Array = motion._points.duplicate()
	expect(motion.retarget_on_path(start, 2.1), "First reversal is supported")
	motion.advance(.3)
	expect(motion.retarget_on_path(end, 2.1), "Switching back toward B reuses the same path")
	motion.advance(.2)
	var remaining: float = motion.duration - motion.elapsed
	end.rect = Vector4(-.2, -.4, .4, .8)
	motion.retarget_remaining(end)
	expect(motion._points == geometry, "Resize preserves the original geometry after reversals")
	expect(is_equal_approx(motion.duration, remaining), "Resize preserves the landing deadline")
	motion.advance(motion.duration)
	expect(motion.frame == end, "Repeated reversal lands at the resized B frame")

func test_reversal_brakes_inside_the_route_near_endpoints() -> void:
	for fraction in [.001, .1, .5, .9, .999]:
		for route in [PackedVector3Array(), PackedVector3Array([Vector3(10, 5, 0), Vector3(20, 5, 0)])]:
			var motion := Motion.new()
			motion.reset(frame_at(Vector3.ZERO))
			motion.retarget(frame_at(Vector3(30, 0, 0)), 2.1, route)
			motion.advance(2.1 * fraction)
			expect(motion.retarget_on_path(frame_at(Vector3.ZERO), 2.1), "Endpoint reversal accepted")
			expect(is_equal_approx(motion.duration, 2.1), "Braking near the endpoint must not rush the return flight")
			var contained := true
			for i in 1001:
				var at: float = motion._path_clock(float(i) / 1000.0).x
				contained = contained and at >= -.0001 and at <= 2.1001
			expect(contained, "Reversal stays inside path bounds without a hard positional clamp")
func frame_at(p: Vector3) -> Dictionary:
	return Motion.pose(p, Vector3.FORWARD, Vector3.UP, Vector4(-.5,-.3,1,.6))

func test_camera_uses_scatter_landing_time_and_stops_with_zero_acceleration() -> void:
	var seconds := preload("res://scenes/TerminalWorld.gd").tab_transition_duration()
	expect(is_equal_approx(seconds, 2.1), "Camera and scatter share the existing 2.1 second budget")
	for route in [PackedVector3Array(), PackedVector3Array([Vector3(20, 0, 0), Vector3(40, 0, .95)])]:
		var motion := Motion.new()
		motion.reset(frame_at(Vector3.ZERO))
		var target := Motion.pose(Vector3(40, 0, 1), Vector3(-1, 0, -1), Vector3.UP, Vector4(-.25, -.2, .5, .4))
		motion.retarget(target, seconds, route)
		motion.advance(1.6)
		expect(motion.moving and motion.velocity.length() > 0.01, "The camera still moves when the settling interval starts")
		var speed := motion.velocity.length()
		motion.advance(.25)
		expect(motion.velocity.length() < speed, "Camera decelerates through the final half-second")
		motion.advance(seconds - motion.elapsed - .001)
		expect(motion.velocity.length() / .001 < .4, "Positional acceleration tends to zero at landing")
		expect(motion.angular_velocity.length() / .001 < .01, "Rotation acceleration tends to zero at landing")
		expect(motion.framing_velocity.length() / .001 < .01, "Lens acceleration tends to zero at landing")
		motion.advance(.002)
		expect(not motion.moving and motion.frame == target, "All camera channels reach the exact destination together")

func test_short_final_leg_decelerates_before_landing() -> void:
	var motion = Motion.new()
	motion.reset(frame_at(Vector3.ZERO))
	motion.retarget(frame_at(Vector3(40,0,1)),1.6,PackedVector3Array([Vector3(20,0,0),Vector3(40,0,0),Vector3(40,0,.95)]))
	var peak := 0.0
	var late := 0.0
	for i in 160:
		motion.advance(.01)
		peak = maxf(peak,motion.velocity.length())
		if i >= 151: late = maxf(late,motion.velocity.length())
	expect(late < peak*.35,"A tiny final leg must not carry cruising speed into the last 5%")
	expect(motion.frame.transform.origin.distance_to(Vector3(40,0,1)) < .0001,"The camera reaches the exact destination")
	expect(motion.velocity.length() < .0001,"Landing ends at rest")

func test_routed_interruption_preserves_vector_velocity() -> void:
	var motion = Motion.new()
	motion.reset(frame_at(Vector3.ZERO))
	motion.retarget(frame_at(Vector3(30,0,0)),1.6)
	motion.advance(.6)
	var before: Vector3 = motion.velocity
	var position: Vector3 = motion.frame.transform.origin
	motion.retarget(frame_at(Vector3(10,0,20)),1.6,PackedVector3Array([position+Vector3(3,0,2),Vector3(10,0,18)]))
	motion.advance(.00001)
	expect(motion.velocity.distance_to(before) < .02,"Retargeting retains incoming vector velocity")
	var measured: Vector3 = (motion.frame.transform.origin-position)/.00001
	expect(measured.distance_to(before) < .2,"Analytic velocity matches displayed travel at the handoff")

func test_resized_flight_keeps_motion_and_original_arrival_time() -> void:
	var motion = Motion.new()
	motion.reset(frame_at(Vector3.ZERO))
	var destination := frame_at(Vector3(40, 0, 10))
	motion.retarget(destination, 1.6, PackedVector3Array([Vector3(10,0,0), Vector3(30,0,10)]))
	motion.advance(.7)
	var before: Dictionary = motion.frame.duplicate()
	var velocity: Vector3 = motion.velocity
	destination.rect = Vector4(-.25, -.5, .5, 1.0)
	motion.retarget_remaining(destination)
	expect(motion.frame == before, "Resizing never cuts the displayed pose or lens")
	expect(absf(motion.duration - .9) < .0001, "Resizing preserves the original arrival time")
	motion.advance(.00001)
	expect(motion.velocity.distance_to(velocity) < .02, "Resizing preserves incoming velocity")
	motion.advance(.9)
	expect(motion.frame == destination and not motion.moving, "The flight lands at the resized frame")
