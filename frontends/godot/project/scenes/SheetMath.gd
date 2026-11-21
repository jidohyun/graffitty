extends RefCounted


## Perspective projection of the saddle depth field with camera tilt handled
## separately by Godot. Pixel coordinates are pane-centred, with Y upward.
static func saddle_depth(point: Vector2, size: Vector2, degrees: float) -> float:
	var extent := maxf(size.x, size.y)
	return tan(deg_to_rad(degrees)) * 2.5 * point.x * point.y / maxf(extent * extent, 0.001)


static func saddle_fit(size: Vector2, degrees: float) -> float:
	var corner_depth := absf(saddle_depth(size * 0.5, size, degrees))
	return 1.0 / maxf(1.0 - corner_depth, 0.05)


static func saddle_project(
	uv: Vector2,
	pane: Rect2,
	texture_size: Vector2,
	degrees: float,
) -> Vector2:
	var size := pane.size * texture_size
	var p := (uv - pane.get_center()) * texture_size * Vector2(1, -1)
	var divisor := (1.0 + saddle_depth(p, size, degrees)) * saddle_fit(size, degrees)
	return pane.get_center() + p * Vector2(1, -1) / maxf(divisor, 0.001) / texture_size


static func saddle_unproject(
	uv: Vector2,
	pane: Rect2,
	texture_size: Vector2,
	degrees: float,
) -> Vector2:
	var size := pane.size * texture_size
	var p := (uv - pane.get_center()) * texture_size * Vector2(1, -1) * saddle_fit(size, degrees)
	# Solve t = 1 + depth(p)*t*t; the stable root approaches 1 at zero bend.
	var discriminant := 1.0 - 4.0 * saddle_depth(p, size, degrees)
	var t := 2.0 / (1.0 + sqrt(maxf(discriminant, 0.0)))
	return pane.get_center() + p * t * Vector2(1, -1) / texture_size


## Paper-z / sheet-frame-splash in source-pixel coordinates.
## Returned depth is divided by its 2*max(width,height) focal distance.
static func ripple_depth(
	radius: float,
	amplitude_deg: float,
	wavelength: float,
	falloff: float,
	short_side: float,
	phase: float,
	zoom := 1.0,
) -> float:
	var k := TAU / maxf(wavelength * short_side, 0.001)
	var attenuation := 1.0 / maxf(falloff * short_side, 1.0)
	return 0.375 * tan(deg_to_rad(amplitude_deg / maxf(zoom, 1.0))) * sin(radius * k - phase) * exp(
		-radius * attenuation
	)


static func splash_depth(
	radius: float,
	age: float,
	amplitude_deg: float,
	wavelength: float,
	short_side: float,
	speed: float,
	life: float,
	zoom := 1.0,
) -> float:
	if age < 0.0 or age >= life:
		return 0.0
	var sigma := maxf(0.25 * wavelength * short_side, 0.001)
	var u := radius - age * speed
	var angle := minf(amplitude_deg * exp(-3.0 * age / maxf(life, 0.001)), 45.0)
	return 0.375 * tan(deg_to_rad(angle)) / maxf(zoom, 0.001) * sin(u * 2.0 / sigma) * exp(
		-u * u / (sigma * sigma)
	)
