extends RefCounted
## Host-owned gates survive world changes without changing authored settings.
## Existing animations decay; discrete bursts finish their natural lifetimes.
const Catalog := preload("res://graffitty/effects.gd")
const FRAME_CHANNELS := {
	"camera.zoom": "camera.zoom", "camera.tilt_limit_deg": "camera.tilt",
	"camera.drift_px": "camera.drift", "camera.shake_px": "camera.shake",
	"sheet.ripple": "sheet.ripple", "sheet.curvature_deg": "sheet.curvature",
}
var _settled: Dictionary = {}
var _holds: Dictionary = {}
var _weights: Dictionary = {}
var _next_id := 0


func settle(effects: Array) -> void:
	for effect in effects: _settled[effect] = true


func hold(effects: Array) -> Callable:
	_next_id += 1
	_holds[_next_id] = effects.duplicate()
	return release.bind(_next_id)


func release(id: int) -> void:
	_holds.erase(id)


func pulse() -> void:
	_settled.clear()


func allows(effect: String) -> bool:
	return not _settled.has(effect) and not held(effect)


func held(effect: String) -> bool:
	for effects in _holds.values():
		if effect in effects: return true
	return false


func weight(effect: String) -> float:
	return float(_weights.get(effect, 1.0))


func camera_active() -> bool:
	return allows("camera.zoom") or allows("camera.tilt") or allows("camera.drift")


func advance(dt: float, enter: float, leave: float) -> void:
	for effect in Catalog.NAMES:
		var current := weight(effect)
		var target := 1.0 if allows(effect) else 0.0
		var duration := enter if target > current else leave
		var value := lerpf(current, target, 1.0 - pow(2.0, -10.0 * dt / maxf(duration, 0.001)))
		_weights[effect] = target if absf(value - target) < 0.00001 else value


func frame(source: Dictionary, destination := false, rest: Dictionary = {}) -> Dictionary:
	var result := source.duplicate()
	for key in FRAME_CHANNELS:
		if not result.has(key): continue
		var effect: String = FRAME_CHANNELS[key]
		# Camera controllers already ease their destination; do not ease twice.
		var amount := (1.0 if allows(effect) else 0.0) if destination else weight(effect)
		var neutral := 1.0 if key == "camera.zoom" else 0.0
		# One-shot settling follows the configured rest state. A persistent
		# disable also removes effects authored into that rest state.
		var target := float(rest.get(key, neutral)) if not held(effect) else neutral
		result[key] = lerpf(target, float(result[key]), amount)
	return result
