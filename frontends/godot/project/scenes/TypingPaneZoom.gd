extends RefCounted
## Presentation only: these weights never enter layout or collision rectangles.
var weights: Dictionary = {}
var key := ""
var remaining := 0.0


func pulse(pane: String, idle_after: float) -> void:
	key = pane
	remaining = idle_after
	if not weights.has(key): weights[key] = 0.0


func cancel() -> void:
	# Keep displayed weights so losing focus starts the normal leave animation.
	key = ""
	remaining = 0.0


## Where `pane`'s weight is heading: 1 while it is the typed, focused pane.
func target_weight(pane: String, focused: String) -> float:
	return 1.0 if pane == key and pane == focused and remaining > 0.0 else 0.0


func advance(dt: float, focused: String, enter: float, leave: float) -> Dictionary:
	if key != focused: cancel()
	remaining = maxf(0.0, remaining - dt)
	var changed := {}
	for pane in weights.keys():
		var target := target_weight(pane, focused)
		var previous: float = weights[pane]
		var duration := enter if target > previous else leave
		var weight := lerpf(previous, target, 1.0 - pow(2.0, -10.0 * dt / maxf(duration, 0.001)))
		if absf(weight - target) < 0.0001: weight = target
		weights[pane] = weight
		if weight != previous: changed[pane] = weight
		if weight == 0.0: weights.erase(pane)
	return changed


static func geometry(rect: Rect2, zoom: float, bounds := Rect2()) -> Rect2:
	zoom = maxf(zoom, 1.0)
	if bounds.has_area() and rect.has_area():
		# A tile spanning one axis still grows into its neighbours on the other.
		#
		# Using the tighter axis here disabled the effect on the tall left pane of a
		# three-pane split (and on every two-column layout).
		#
		# Keep uniform scaling; only a tile that fills both axes has no room to
		# enlarge.
		zoom = minf(zoom, maxf(1.0, maxf(bounds.size.x / rect.size.x, bounds.size.y / rect.size.y)))
	var extent := rect.size * zoom
	var origin := rect.get_center() - extent * 0.5
	if bounds.has_area():
		# Three-edge tiles anchor only on their single outer edge. The axis
		# spanning two opposite edges grows symmetrically beyond those edges.
		if extent.x <= bounds.size.x:
			origin.x = clampf(origin.x, bounds.position.x, bounds.end.x - extent.x)
		if extent.y <= bounds.size.y:
			origin.y = clampf(origin.y, bounds.position.y, bounds.end.y - extent.y)
	return Rect2(origin, extent)


static func apply(pane: Control, rect: Rect2, zoom: float, bounds := Rect2()) -> void:
	var visual := geometry(rect, zoom, bounds)
	var factor := visual.size.x / maxf(rect.size.x, 1.0)
	pane.pivot_offset = (rect.position - visual.position) / (factor - 1.0) if factor > 1.000001 else Vector2.ZERO
	pane.scale = Vector2.ONE * factor
