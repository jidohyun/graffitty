extends "../../../../tests/llm-e2e/replay/replay.gd"
## Every consecutive Bistro tab flight turns smoothly and never detours or
## doubles back (worlds/bistro/tools/link_destinations.gd).
##
## Measures the displayed camera: the direction of travel, while moving above
## 15% of the flight's peak speed, may not swing faster than gently cornered
## flights do.
##
##     godot --path . --script tests/bistro_flight_smoothness_smoke.gd -- --shell=/bin/sh
const TABS := 9
const MAX_TURN_RATE := 250.0
const MAX_DETOUR := 1.6

func play() -> void:
	check(host.switch_world("bistro"), "Bistro opens")
	await camera_at_rest()
	host.instant_workspace_switch = true
	await open_tabs(TABS)
	host.select_workspace(int(host.get_tabs()[0].id), true)
	host.instant_workspace_switch = false
	await camera_at_rest()
	var motion = host.world.camera_motion
	for i in TABS - 1:
		host.select_workspace(int(host.get_tabs()[i + 1].id))
		await process_frame
		var samples: Array = []
		var guard := 0
		while motion.moving and guard < 2000:
			samples.append([motion.frame.transform.origin, motion.velocity, motion.elapsed])
			await process_frame
			guard += 1
		var peak := 0.0
		for s in samples: peak = maxf(peak, s[1].length())
		var turn := 0.0
		var length := 0.0
		for k in range(1, samples.size()):
			var a: Array = samples[k - 1]
			var b: Array = samples[k]
			length += a[0].distance_to(b[0])
			if b[2] > a[2] and minf(a[1].length(), b[1].length()) > 0.15 * peak:
				turn = maxf(turn, rad_to_deg(a[1].angle_to(b[1])) / (b[2] - a[2]))
		var straight: float = samples[0][0].distance_to(samples[-1][0]) if samples.size() > 1 else 0.0
		var label := "Tab %d→%d (%s)" % [i + 1, i + 2, host.world.navigation_route_kind]
		print("BISTRO_FLIGHT ", label, " turn=%.0f°/s detour=%.2f" % [turn, length / maxf(straight, 0.001)])
		check(turn <= MAX_TURN_RATE, label + " turns smoothly: %.0f°/s" % turn)
		check(length <= straight * MAX_DETOUR, label + " does not detour or double back")
		await camera_at_rest()
