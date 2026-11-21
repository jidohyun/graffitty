extends RefCounted
## Invisible mobile floating-window resize gesture. The entire top stays drag-only.
const REACH := 16.0
var window: Window
var finger := -1
var edges := Vector2i.ZERO
var origin := Vector2.ZERO
var initial := Rect2i()

static func hit(rect: Rect2, point: Vector2) -> Vector2i:
	# Exclude both top corners as well as the title itself.
	if point.y < rect.position.y + 24.0 or not rect.grow(REACH).has_point(point):
		return Vector2i.ZERO
	var horizontal := -1 if absf(point.x - rect.position.x) <= REACH else (1 if absf(point.x - rect.end.x) <= REACH else 0)
	return Vector2i(horizontal, 1 if absf(point.y - rect.end.y) <= REACH else 0)

func cancel(restore := true) -> void:
	if is_instance_valid(window):
		if restore:
			window.position = initial.position
			window.size = initial.size
			window.geometry_changed()
	window = null
	finger = -1

func handle(event: InputEvent, panels: Array[Control]) -> bool:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		var active := is_instance_valid(window)
		cancel()
		return active
	if not (event is InputEventScreenTouch or event is InputEventScreenDrag): return false
	if is_instance_valid(window):
		if not window.visible or not window._workspace_active:
			cancel()
			return true
		if event.index != finger:
			if event is InputEventScreenTouch and event.pressed: cancel()
			return true
		if event is InputEventScreenTouch:
			if event.canceled: cancel()
			elif not event.pressed:
				window._native_rect = Rect2i(window.position, window.size)
				window._desktop.space.save_layout()
				cancel(false)
			return true
		var delta := Vector2i(event.position - origin)
		var bounds: Rect2i = window._available()
		var end := initial.end
		var start := initial.position
		if edges.x < 0: start.x = clampi(initial.position.x + delta.x, bounds.position.x, end.x - window.min_size.x)
		if edges.x > 0: end.x = clampi(initial.end.x + delta.x, start.x + window.min_size.x, bounds.end.x)
		if edges.y > 0: end.y = clampi(initial.end.y + delta.y, start.y + window.min_size.y, bounds.end.y)
		window.position = start
		window.size = end - start
		window.geometry_changed()
		return true
	if not (event is InputEventScreenTouch) or not event.pressed or event.canceled: return false
	for i in range(panels.size() - 1, -1, -1):
		var candidate: Window = panels[i].dialog
		if not is_instance_valid(candidate) or candidate.force_native or not candidate.visible: continue
		var rect := Rect2(Vector2(candidate.position), Vector2(candidate.size))
		if candidate.folded:
			if rect.has_point(event.position): return false
			continue
		edges = hit(rect, event.position)
		if edges == Vector2i.ZERO:
			if rect.grow(REACH).has_point(event.position): return false
			continue
		window = candidate
		finger = event.index
		origin = event.position
		initial = Rect2i(window.position, window.size)
		window.grab_focus()
		return true
	return false
