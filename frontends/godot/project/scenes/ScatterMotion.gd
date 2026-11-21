extends RefCounted
## CPU counterpart of scatter_motion.gdshaderinc, for intact UI and retirement.
const DEPARTURE := 1.5
const ARRIVAL_FLIGHT := 1.2
const ARRIVAL := ARRIVAL_FLIGHT + 1.0 / 3.0
const FLIGHT := 1.1
const RAMP := 0.15
const INITIAL_SPEED := 0.2
const DISTANCE := FLIGHT - (1.0 - INITIAL_SPEED) * RAMP * 0.5

static func clock(phase: float, rank: float, arriving: bool) -> float:
	var release := 0.0 if rank < 0.2 else (1.0 if rank < 0.8 else 2.0) / 6.0
	if arriving:
		var elapsed := (1.0 - clampf(phase, 0.0, 1.0)) * ARRIVAL
		var remaining := clampf(ARRIVAL_FLIGHT - elapsed + release, 0.0, ARRIVAL_FLIGHT)
		var u := minf(remaining / 0.3, 1.0)
		var distance := 0.3 * (u * u * u - 0.5 * u * u * u * u) + maxf(remaining - 0.3, 0.0)
		return distance / (ARRIVAL_FLIGHT - 0.15)
	var t := clampf(phase * DEPARTURE - release, 0.0, FLIGHT)
	var u := minf(t / RAMP, 1.0)
	var ramp_distance := RAMP * (u * u * u - 0.5 * u * u * u * u) + maxf(t - RAMP, 0.0)
	return (INITIAL_SPEED * t + (1.0 - INITIAL_SPEED) * ramp_distance) / DISTANCE

static func retire_pose(position: float, velocity: float, elapsed: float) -> float:
	# Keep the arriving velocity, then turn gently toward the normal departure
	# speed. Bound the stopping distance so a late arrival cannot cross the pane.
	var response := minf(0.1, maxf(position, 0.000001) / maxf(-velocity, 0.000001) * 0.5)
	var carried := response * (1.0 - exp(-maxf(elapsed, 0.0) / response))
	return position + velocity * carried + (elapsed - carried) / DISTANCE

static func retire_flight(phase: float, rank: float, elapsed: float) -> float:
	var position := clock(phase, rank, true)
	var velocity := (clock(clampf(phase - 0.0001, 0.0, 1.0), rank, true) - clock(clampf(phase + 0.0001, 0.0, 1.0), rank, true)) / (0.0002 * ARRIVAL)
	return retire_pose(position, velocity, elapsed)

static func wind(sheet_uv: Vector2, jitter: Vector2) -> Vector2:
	var p := sheet_uv - Vector2(0.5, 0.5)
	var gust := sin(p.y * 3.0 + p.x * 1.7)
	var bend := deg_to_rad(clampf(50.0 + 14.0 * gust + 12.0 * (jitter.x - 0.5), 30.0, 70.0))
	var heading := deg_to_rad(12.0 * sin(p.x * 2.2 + p.y * 1.4) + 96.0 * (jitter.y - 0.5))
	return Vector2(-cos(heading), sin(heading)) * tan(bend)

static func drift(sheet_uv: Vector2, jitter: Vector2, gust: Vector2) -> Vector2:
	var right := 0.02 + 0.06 * (jitter.x - 0.5) + 0.01 * sin((sheet_uv.y - 0.5) * 3.0)
	return Vector2(right, 0.045 * gust.y / gust.length())

static func wind_distance(flight: float) -> float:
	var u := flight / 0.85
	return 1.5 * 0.85 / 5.0 * u * u * u * u * u
