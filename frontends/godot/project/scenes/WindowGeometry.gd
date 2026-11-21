extends RefCounted
## Zoom/restore is not fullscreen. Native decorations keep OS title-bar handling.
static func toggle_fit(window: Window) -> void:
	if window.mode == Window.MODE_MAXIMIZED:
		window.mode = Window.MODE_WINDOWED
		if window.has_meta(&"normal_window_rect"):
			var rect: Rect2i = window.get_meta(&"normal_window_rect")
			window.position = rect.position
			window.size = rect.size
	else:
		window.set_meta(&"normal_window_rect", Rect2i(window.position, window.size))
		window.mode = Window.MODE_MAXIMIZED
