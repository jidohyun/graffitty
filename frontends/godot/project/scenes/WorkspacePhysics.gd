extends RefCounted
## Godot adapter for the shared spatial index and floating-pane contact solver.
var _native: RefCounted = ClassDB.instantiate("ScenePanePhysics")
var sleeping: bool:
	get: return _native.sleeping()
var velocities: Dictionary:
	get: return _native.velocities()
var indexed: Dictionary:
	get: return _native.indexed()
var pair_checks: int:
	get: return _native.pair_checks()

func reset() -> void:
	_native.reset()

func sleep() -> void:
	_native.sleep()

func step(rectangles: Dictionary, movable: Dictionary, area: Rect2, dt: float, constrain := Callable()) -> Dictionary:
	return _native.step(rectangles, movable, area, dt, constrain)
