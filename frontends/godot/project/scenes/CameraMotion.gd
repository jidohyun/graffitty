class_name CameraMotion
extends RefCounted
## Godot frame/camera boundary. Motion and framing are owned by scene-core.
var _native: RefCounted = ClassDB.instantiate("SceneCameraMotion")
var frame: Dictionary:
	get: return _native.current_frame()
	set(value): _native.observe(value, 0.0)
var moving: bool:
	get: return _native.moving()
var velocity: Vector3:
	get: return _native.velocity()
var angular_velocity: Vector3:
	get: return _native.angular_velocity()
var framing_velocity: Vector4:
	get: return _native.framing_velocity()
var duration: float:
	get: return _native.duration()
var elapsed: float:
	get: return _native.elapsed()
var _points: PackedVector3Array:
	get: return _native.route_points()
var _target: Dictionary:
	get: return _native.target()

static func _core() -> RefCounted:
	var owner := (Engine.get_main_loop() as SceneTree).root
	if not owner.has_meta("graffitty_scene_camera"):
		owner.set_meta("graffitty_scene_camera", ClassDB.instantiate("SceneCameraMath"))
	return owner.get_meta("graffitty_scene_camera")

func stop() -> void:
	_native.stop()

static func pose(eye: Vector3, forward: Vector3, up: Vector3, rect: Vector4) -> Dictionary:
	return { "transform": Transform3D(Basis.looking_at(forward, up), eye), "rect": rect }



func reset(value: Dictionary) -> void:
	_native.reset(value)

func observe(value: Dictionary, dt: float) -> void:
	_native.observe(value, dt)

func retarget(destination: Dictionary, seconds: float, route := PackedVector3Array()) -> void:
	_native.retarget(destination, seconds, route)

func _path_clock(t: float) -> Vector2:
	return _native.path_clock(t)

func retarget_on_path(destination: Dictionary, seconds: float) -> bool:
	return _native.retarget_on_path(destination, seconds)

func retarget_remaining(destination: Dictionary) -> void:
	_native.retarget_remaining(destination)

func advance(dt: float) -> Dictionary:
	return _native.advance(dt)

static func compose(
	base: Dictionary,
	zoom: float,
	pan: Vector2,
	tilt: Vector2,
	center: Vector3,
	axis_u: Vector3,
	axis_v: Vector3,
	cursor: Vector3,
	near_distance: float,
	constrain_cursor: bool,
) -> Dictionary:
	return _core().compose(base, zoom, pan, tilt, center, axis_u, axis_v, cursor, near_distance, constrain_cursor)

static func keep_cursor_in_view(
	eye: Vector3,
	forward: Vector3,
	right: Vector3,
	up: Vector3,
	rect: Vector4,
	point: Vector3,
	near_distance: float,
	margin := .15,
) -> Vector3:
	return _core().keep_cursor_in_view(eye, forward, right, up, rect, point, near_distance, margin)

static func frame_pane(
	base: Dictionary,
	zoom: float,
	pan: Vector2,
	tilt: Vector2,
	distance: float,
) -> Dictionary:
	return _core().frame_pane(base, zoom, pan, tilt, distance)

static func frame_sheet(
	base: Dictionary,
	zoom: float,
	pan: Vector2,
	tilt: Vector2,
	center: Vector3,
	axis_u: Vector3,
	axis_v: Vector3,
) -> Dictionary:
	return _core().frame_sheet(base, zoom, pan, tilt, center, axis_u, axis_v)

static func lean(frame: Dictionary, tilt: Vector2, depth: float) -> Dictionary:
	return _core().lean(frame, tilt, depth)

static func apply(camera: Camera3D, value: Dictionary) -> void:
	if not camera.global_transform.is_equal_approx(value.transform):
		camera.global_transform = value.transform
	var rect: Vector4 = value.rect
	var projection_changed: bool = not camera.get_meta("frustum_vertical_aspect", false)
	if camera.projection != Camera3D.PROJECTION_FRUSTUM:
		camera.projection = Camera3D.PROJECTION_FRUSTUM
		projection_changed = true
	var size := rect.z * camera.near
	if not is_equal_approx(camera.size, size):
		camera.size = size
		projection_changed = true
	var offset := Vector2(rect.x + rect.z * .5, rect.y + rect.w * .5) * camera.near
	if not camera.frustum_offset.is_equal_approx(offset):
		camera.frustum_offset = offset
		projection_changed = true
	if projection_changed:
		RenderingServer.camera_set_use_vertical_aspect(camera.get_camera_rid(), true)
		camera.set_meta("frustum_vertical_aspect", true)
