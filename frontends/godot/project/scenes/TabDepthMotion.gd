extends RefCounted
## One visual clock for the whole workspace, shared by both renderers.
const DURATION := 0.42
const ZOOM_RATIO := 2.0
const RETIRE_DURATION := 0.18

static func phase(progress: float) -> float:
	# Quintic smoothstep: zero velocity and acceleration at both ends.
	var t := clampf(progress, 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

static func magnification(progress: float, direction: float, arriving: bool) -> float:
	# Equal distances in log zoom make push/pull exact reciprocals. Linear
	# camera depth would accelerate enlargement much more than shrinking.
	return pow(ZOOM_RATIO, direction * (-1.0 if arriving else 1.0) * phase(progress))

## The displayed pane's affine map, shared by the GPU and cursor effects.
## Capture coordinates remain fixed while the live camera pans, tilts or zooms.
static func presentation_transform(reference: Transform3D, camera: Transform3D, captured: Vector4, current: Vector4, magnification: float) -> Transform3D:
	var ratio := Vector2(current.z / captured.z, current.w / captured.w)
	var offset := Vector2(current.x, current.y) - Vector2(captured.x, captured.y) * ratio
	var center := Vector2(current.x + current.z * 0.5, current.y + current.w * 0.5)
	var shift := -offset + center * (1.0 - 1.0 / magnification)
	var projection := Basis(Vector3(ratio.x, 0, 0), Vector3(0, ratio.y, 0), Vector3(shift.x, shift.y, 1.0 / magnification))
	return camera * Transform3D(projection, Vector3.ZERO) * reference.affine_inverse()
