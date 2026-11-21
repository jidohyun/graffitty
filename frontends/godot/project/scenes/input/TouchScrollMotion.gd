extends RefCounted
## Clocked momentum integration shared with native frontends.
var _native: RefCounted = ClassDB.instantiate("SceneScrollMotion")
var velocity: Vector2:
	get: return _native.velocity()

func begin(now: int) -> void:
	_native.begin(now)

func track(delta: Vector2, now: int) -> void:
	_native.track(delta, now)

func release(now: int) -> void:
	_native.release(now)

func advance(now: int) -> Vector2:
	return _native.advance(now)

func stop() -> void:
	_native.stop()
