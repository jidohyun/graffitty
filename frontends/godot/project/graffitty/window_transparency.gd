extends RefCounted


static func available(window_id := DisplayServer.MAIN_WINDOW_ID) -> bool:
	if DisplayServer.get_name() == "X11" and OS.get_name() == "Linux":
		return (ProjectSettings.get_setting_with_override("display/window/per_pixel_transparency/allowed")
			and ClassDB.class_exists(&"NativeWindowFrame")
			and ClassDB.class_call_static(&"NativeWindowFrame", &"x11_has_composited_alpha", window_id))
	return DisplayServer.is_window_transparency_available()
