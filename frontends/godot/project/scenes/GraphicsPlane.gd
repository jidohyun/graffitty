extends RefCounted


## A lifted image plane projected back onto the terminal sheet. This retains
## native clipping and image/text z order, including in transition captures.
static func projection(
	origin: Vector3,
	pixel_u: Vector3,
	pixel_v: Vector3,
	size: Vector2,
	eye: Vector3,
	tilt: Vector2,
	lift: float,
	lean_scale: float,
	zoom := 1.0,
) -> Basis:
	var normal := pixel_u.cross(pixel_v).normalized()
	if normal.dot(eye - origin) < 0:
		normal = -normal
	var inverse := Basis(pixel_u, pixel_v, normal).inverse()
	var camera := inverse * (eye - origin)
	var fade := maxf(minf(rad_to_deg(tilt.length()) / 6.0, 1.0), clampf(zoom - 1.0, 0.0, 1.0))
	var height := lift * fade * maxf(pixel_u.length() * size.x, pixel_v.length() * size.y)
	var rotate := Basis(pixel_v.normalized(), tilt.x * (lean_scale - 1.0)) * Basis(
		pixel_u.normalized(),
		tilt.y * (lean_scale - 1.0),
	)
	var centre := origin + pixel_u * size.x * 0.5 + pixel_v * size.y * 0.5
	var a := inverse * (rotate * pixel_u)
	var b := inverse * (rotate * pixel_v)
	var c := inverse * (centre + rotate * (origin - centre) + normal * height - eye)
	var result := Basis.IDENTITY
	for i in 3:
		var ray: Vector3 = [a, b, c][i]
		result[i] = Vector3(
			camera.x * ray.z - camera.z * ray.x,
			camera.y * ray.z - camera.z * ray.y,
			ray.z,
		)
	# Homographies are scale invariant; positive unit denominator at origin.
	return Basis(result.x / c.z, result.y / c.z, result.z / c.z) if absf(c.z) > 0.001 else Basis.IDENTITY


static func point(matrix: Basis, at: Vector2) -> Vector2:
	var result := matrix * Vector3(at.x, at.y, 1.0)
	return Vector2(result.x, result.y) / maxf(result.z, 0.001)


static func bounds(matrix: Basis, rect: Rect2) -> Rect2:
	var result := Rect2(point(matrix, rect.position), Vector2.ZERO)
	for corner in [
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	]:
		result = result.expand(point(matrix, corner))
	return result
