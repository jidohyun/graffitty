extends RefCounted
## Godot input/signal adapter. Gesture ownership and timing live in
## scene-core.
##
## Where a contact lands: on the workspace, on a surface that gives a resting
## contact up to a pinch, or on a control that never joins a workspace
## gesture.
enum Zone { WORKSPACE, YIELDING, EXCLUSIVE }
signal pointer(event: InputEventMouse)
## A contact left its surface for a workspace pinch; the surface must see it
## canceled. `mouse`: the platform's emulated mouse follows this contact.
signal yielded(index: int, position: Vector2, mouse: bool)
signal pinch(previous_center: Vector2, center: Vector2, factor: float)
## `stage`: "began", "changed" under the fingers, "momentum" after they
## lift, and a motionless "ended" that releases a rubber band.
signal scroll(anchor: Vector2, delta: Vector2, stage: String)
signal canceled
signal remote_swipe(progress: float, finished: bool, commit: bool)
const PINCH_GRACE_MS := 120
const SCROLL_GRACE_MS := 120
const YIELD_MS := 400
var _native: RefCounted = ClassDB.instantiate("SceneTouchNavigation")
var fingers: Dictionary:
	get: return _native.fingers()
var held: bool:
	get: return _native.held()
var scrolling: bool:
	get: return _native.scrolling()
var navigating: bool:
	get: return _native.navigating()
var long_pressed: bool:
	get: return _native.long_pressed()

func set_drag_scroll(enabled: bool) -> void:
	_native.set_drag_scroll(enabled)

func set_remote_swipe_width(width: float) -> void:
	_native.set_remote_swipe_width(width)

## Whether the workspace owns this event. `zone` matters only for a new contact.
func handle(event: InputEvent, now: int, zone := Zone.WORKSPACE) -> bool:
	var kind: int
	if event is InputEventScreenTouch:
		kind = 3 if event.canceled else (0 if event.pressed else 1)
	elif event is InputEventScreenDrag:
		kind = 2
	else:
		return false
	var result: Dictionary = _native.handle(kind, event.index, event.position, zone, now)
	for contact: Dictionary in result.yielded: yielded.emit(contact.id, contact.position, contact.mouse)
	_emit(result.actions)
	return result.handled

## A surface contact lifted where the router could not see its release.
func forget(index: int) -> void:
	_native.forget(index)

func advance(now: int) -> void:
	_emit(_native.advance(now))

func cancel() -> void:
	_emit(_native.cancel())

func stop_scroll() -> void:
	_native.stop_scroll()

func _center() -> Vector2:
	return _native.center()

func _emit(actions: Array) -> void:
	for action: Dictionary in actions:
		match action.kind:
			"remote_swipe": remote_swipe.emit(action.progress, action.finished, action.commit)
			"canceled": canceled.emit()
			"pinch": pinch.emit(action.previous, action.center, action.factor)
			"scroll": scroll.emit(action.anchor, action.delta, action.stage)
			"motion":
				var event := InputEventMouseMotion.new()
				event.position = action.position
				event.relative = action.relative
				event.button_mask = MOUSE_BUTTON_MASK_LEFT
				pointer.emit(event)
			"button":
				var event := InputEventMouseButton.new()
				event.position = action.position
				event.global_position = action.position
				event.button_index = action.button
				event.pressed = action.pressed
				event.double_click = action.double
				event.canceled = action.canceled
				event.button_mask = MOUSE_BUTTON_MASK_LEFT if action.held else 0
				pointer.emit(event)
