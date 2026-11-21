extends RefCounted
## Desktop coordinates of points in controls. CanvasItem.get_screen_transform()
## counts the native window's desktop position only while that window embeds
## no subwindows; going through the viewport gives the same answer either way.


## Half-open backing-pixel bounds. A shared logical edge maps to the same
## pixel in both neighbors, including on monitors left of the desktop origin.
static func pixel_bounds(rect: Rect2) -> Rect2i:
	var start := Vector2i(rect.position.round())
	return Rect2i(start, Vector2i(rect.end.round()) - start)


static func of(control: CanvasItem, point: Vector2) -> Vector2:
	var viewport := control.get_viewport()
	return Vector2(viewport.get_window().position) + viewport.get_screen_transform() * (
		control.get_global_transform_with_canvas() * point
	)


static func into(control: CanvasItem, screen: Vector2) -> Vector2:
	var viewport := control.get_viewport()
	var in_viewport := viewport.get_screen_transform().affine_inverse() * (
		screen - Vector2(viewport.get_window().position)
	)
	return control.get_global_transform_with_canvas().affine_inverse() * in_viewport


## The desktop rectangle of a control that shows: an embedded window is cut
## off at the edges of the window that embeds it.
static func shown(control: Control) -> Rect2:
	var corner := of(control, Vector2.ZERO)
	var rect := Rect2(corner, of(control, control.size) - corner)
	var window: Window = control.get_window()
	while window != null and window.is_embedded():
		# The viewport a window is embedded in is its parent's.
		var outer: Viewport = window.get_parent().get_viewport()
		var area: Rect2 = outer.get_visible_rect()
		var top := Vector2(outer.get_window().position) + outer.get_screen_transform() * area.position
		var end := Vector2(outer.get_window().position) + outer.get_screen_transform() * area.end
		rect = rect.intersection(Rect2(top, end - top))
		window = outer.get_window()
	return rect
