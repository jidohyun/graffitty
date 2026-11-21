extends RefCounted
## Geometry of the usable workspace, in full-window logical coordinates.
## Docks/chrome reserve space; they never change the projection's coordinate origin.
var viewport_size := Vector2.ZERO
var insets := Vector4.ZERO # left, top, right, bottom

func configure(extent: Vector2, reserved: Vector4) -> void:
	viewport_size = extent.max(Vector2.ZERO)
	insets = Vector4(maxf(0, reserved.x), maxf(0, reserved.y), maxf(0, reserved.z), maxf(0, reserved.w))

func rect() -> Rect2:
	var start := Vector2(insets.x, insets.y).min(viewport_size)
	var end := (viewport_size - Vector2(insets.z, insets.w)).max(start)
	return Rect2(start, end - start)

func contains(point: Vector2) -> bool:
	return rect().has_point(point)

func layout_rect() -> Rect2:
	var visible := rect()
	return Rect2(visible.position.round(), visible.size.floor())

func canvas_rect(center: Vector2, zoom: float) -> Rect2:
	var visible := rect()
	var scale := maxf(zoom, .01)
	return Rect2(center + (visible.position - viewport_size * .5) / scale, visible.size / scale)

func fit(content: Rect2, coverage := 1.0) -> Dictionary:
	var visible := rect()
	var zoom := clampf(minf(visible.size.x / maxf(content.size.x, 1), visible.size.y / maxf(content.size.y, 1)) * coverage, .05, 6)
	return {"center": content.get_center() + (viewport_size * .5 - visible.get_center()) / zoom, "zoom": zoom}

func in_projection(extent: Vector2) -> Rect2:
	# Camera/sheet pixels can differ from logical UI pixels (HiDPI/rounding).
	var scale := extent / viewport_size.max(Vector2.ONE)
	var visible := rect()
	return Rect2(visible.position * scale, visible.size * scale)
