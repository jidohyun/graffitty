extends RefCounted
## One native window maps logical UI units to backing pixels. Embedded windows
## inherit their viewport transform, including responsive dialogs' own fit.
var window: Window
var fixed := 0.0
var _use_wayland_rects := false
var _previous_size := Vector2i.ZERO
var _backing_size := Vector2i.ZERO
var _surface_scale := 1.0


static func watch(target: Window, setting: Variant) -> void:
	if OS.has_feature("movie"): return
	var policy = target.get_meta(&"window_scale_policy") if target.has_meta(&"window_scale_policy") else null
	if policy == null:
		policy = new()
		policy.window = target
		target.set_meta(&"window_scale_policy", policy)
		target.dpi_changed.connect(policy._dpi_changed)
		target.visibility_changed.connect(policy._mapped)
		policy._use_wayland_rects = DisplayServer.get_name() == "Wayland" and target != target.get_tree().root and not ClassDB.class_exists(&"GraffittyWaylandFrame")
		if policy._use_wayland_rects: target.size_changed.connect(policy._remember_size)
		policy.fixed = float(setting) if setting is float or setting is int else 0.0
		policy._mapped()
	else:
		policy.apply()


static func auto_scale(backend: String, native_scale: float, dpi: int) -> float:
	match backend:
		"Windows": return dpi / 96.0 if dpi > 0 else 1.0
		"Android": return maxf(1.0, dpi / 160.0)
	return native_scale if is_finite(native_scale) and native_scale > 0.0 else 1.0


func _mapped() -> void:
	if window.is_embedded(): return
	if _use_wayland_rects:
		# Godot creates a fresh Wayland toplevel at buffer scale 1. An xdg
		# popup instead starts with its parent's surface scale.
		_surface_scale = native_owner(window).content_scale_factor if window.popup_wm_hint else 1.0
		_backing_size = window.size
		_previous_size = _backing_size
	apply()


static func native_owner(target: Window) -> Window:
	var owner := target.get_parent().get_window()
	while owner.is_embedded():
		owner = owner.get_parent().get_window()
	return owner


func _remember_size() -> void:
	if window.size != _backing_size:
		_previous_size = _backing_size
		_backing_size = window.size


## Godot 4.7 exposes the fractional scale directly only for the main surface.
## For another surface it delivers its rescaled backing rectangle immediately
## before dpi_changed, keeping the logical extent. Ordinary resizes only
## update the baseline. Wayland specifies fractional scales in 120ths.
static func wayland_surface_scale(old_scale: float, before: Vector2i, after: Vector2i) -> float:
	var axis := before.max_axis_index()
	var logical := roundi(before[axis] / old_scale)
	if logical < 1 or after[axis] < 1: return old_scale
	return snappedf(float(after[axis]) / logical, 1.0 / 120.0)


func _dpi_changed() -> void:
	if _use_wayland_rects:
		_surface_scale = wayland_surface_scale(_surface_scale, _previous_size, _backing_size)
		_previous_size = _backing_size
	apply()


func apply() -> void:
	if window.is_embedded(): return
	var backend := DisplayServer.get_name()
	var scale := fixed
	var dpi := 0
	if backend == "Windows" and window.visible and window.get_window_id() >= 0:
		var hwnd := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window.get_window_id())
		dpi = ClassDB.class_call_static("NativeWindowFrame", "watch_dpi", hwnd, window.get_instance_id())
	if scale == 0.0:
		var native_scale := 1.0
		match backend:
			"X11":
				var display := DisplayServer.window_get_native_handle(DisplayServer.DISPLAY_HANDLE)
				native_scale = ClassDB.class_call_static("ClientConfig", "x11_ui_scale", display)
			"Wayland":
				if window.visible and window.get_window_id() >= 0 and ClassDB.class_exists(&"GraffittyWaylandFrame"):
					native_scale = ClassDB.class_call_static(&"GraffittyWaylandFrame", &"get_scale", window.get_window_id())
				elif window == window.get_tree().root: native_scale = DisplayServer.screen_get_scale()
				elif window.visible: native_scale = _surface_scale
				else: native_scale = native_owner(window).content_scale_factor
			"Windows", "Android":
				if dpi == 0: dpi = DisplayServer.screen_get_dpi(window.current_screen)
			_: native_scale = DisplayServer.screen_get_scale(window.current_screen)
		scale = auto_scale(backend, native_scale, dpi)
	if window.content_scale_mode != Window.CONTENT_SCALE_MODE_DISABLED:
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	if not is_equal_approx(window.content_scale_factor, scale):
		window.content_scale_factor = scale
