extends RefCounted
## WezTerm uses 10% scale steps and a 2-raster-pixel lower bound. Our terminal
## accepts integral layout sizes, so each shortcut must advance at least one.
const MIN_SIZE := 1
const MAX_SIZE := 72

static func step(current: int, increase: bool) -> int:
	return clampi(maxi(current + 1, roundi(current * 1.1)) if increase else mini(current - 1, roundi(current / 1.1)), MIN_SIZE, MAX_SIZE)

static func clamp_requested(size: int, scale: float, workspace: bool) -> int:
	# Workspace panes use the requested layout size directly. Their height or
	# camera zoom must not impose a higher font-size floor.
	if workspace: return clampi(size, MIN_SIZE, MAX_SIZE)
	return clampi(size, maxi(MIN_SIZE, ceili(1.0 / maxf(scale, 0.001))), maxi(MIN_SIZE, mini(MAX_SIZE, floori(72.0 / maxf(scale, 0.001)))))
