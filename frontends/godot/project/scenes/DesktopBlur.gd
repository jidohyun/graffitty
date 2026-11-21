extends Node
var host: Node
var settings: RefCounted
var native: RefCounted
var applied := false
var status := "disabled"
var _warned := false


func _ready() -> void:
	if OS.has_feature("mobile"):
		return
	if DisplayServer.get_name() == "X11":
		get_window().size_changed.connect(_refresh_blur_region, CONNECT_DEFERRED)
		get_window().titlebar_changed.connect(_refresh_blur_region, CONNECT_DEFERRED)
	if ClassDB.class_exists("DesktopBlur"):
		native = ClassDB.instantiate("DesktopBlur")


func configure(owner_host: Node, options: RefCounted) -> void:
	host = owner_host
	settings = options
	apply.call_deferred()


static func set_window_transparent(window: Window, requested: bool) -> void:
	# The Windows display server advertises transparency even on an opaque
	# Vulkan swapchain. Embedded windows composite inside their parent viewport.
	var frame = window.get_meta(&"graffitty_window_frame") if window.has_meta(&"graffitty_window_frame") else null
	if frame != null and frame.has_method("set_world_transparent"):
		frame.set_world_transparent(requested)
		return
	window.transparent = requested and (window.is_embedded() or preload("res://graffitty/window_transparency.gd").available(window.get_window_id()))


func apply() -> void:
	# Mobile clients have no desktop compositor behind the app window.
	if OS.has_feature("mobile"):
		applied = false
		status = "disabled: mobile"
		return
	if not is_instance_valid(host) or settings == null:
		return
	var window := get_window()
	var effective: RefCounted = settings
	if host.world != null and "window_config" in host.world and host.world.window_config != null:
		effective = host.world.window_config
	set_window_transparent(window, host.world_viewport.transparent_bg)
	var enabled: bool = effective.background_blur and host.world_viewport.transparent_bg and window.transparent
	var backend := DisplayServer.get_name()
	if backend == "headless":
		status = "unavailable: headless"
		return
	if native == null:
		status = "unavailable: native extension missing"
		if enabled and not _warned:
			_warned = true
			push_warning(
				"Desktop blur needs the updated graffitty native extension. Rebuild the native library and restart Graffitty; an already running process cannot load it (reloadable=false)."
			)
		return
	var material := _material(effective)
	var success := _apply_native(window, enabled, material)
	applied = success and enabled and (backend != "macOS" or material > 0)
	status = (
		("enabled: " + backend)
		if applied
		else ("unavailable: " + backend if enabled and not success else "disabled")
	)

	_refresh_panel_backdrops()


func _refresh_panel_backdrops() -> void:
	if not is_inside_tree() or not is_instance_valid(host): return
	for panel in get_tree().get_nodes_in_group(&"panel_window"):
		if panel.source == host and panel.visible:
			panel._backdrop_changed()


func _refresh_blur_region() -> void:
	if applied and is_instance_valid(host) and get_window().visible:
		_apply_native(get_window(), true, 0)


func _effective() -> RefCounted:
	if is_instance_valid(host) and host.world != null and "window_config" in host.world and host.world.window_config != null:
		return host.world.window_config
	return settings


static func _material(effective: RefCounted) -> int:
	if OS.get_name() == "macOS": return effective.macos.blur_radius
	if OS.get_name() == "Windows": return ["acrylic", "mica", "tabbed"].find(effective.windows.blur_material)
	return 0


func _apply_native(window: Window, enabled: bool, material: int) -> bool:
	var backend := DisplayServer.get_name()
	if native == null or backend == "headless": return false
	if backend == "X11" and enabled and window.has_meta(&"graffitty_window_frame"):
		var frame = window.get_meta(&"graffitty_window_frame")
		if frame.has_method("corner_radius_px"):
			material = roundi(frame.corner_radius_px())
	var window_id := window.get_window_id()
	var handle := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window_id)
	var display := DisplayServer.window_get_native_handle(DisplayServer.DISPLAY_HANDLE, window_id) if backend == "X11" else 0
	return native.apply(handle, enabled, material, display, backend)


## Blurs (or stops blurring) the desktop behind another native window of this
## host, such as a translucent floating panel, with the user's blur settings.
##
## Both the panel's opt-in and the user's `background_blur` must be enabled.
## False explicitly removes a previously installed native backdrop.
func apply_to(window: Window, requested: bool = true, radius: float = -1.0) -> bool:
	if OS.has_feature("mobile") or settings == null or not is_instance_valid(window): return false
	var effective := _effective()
	var enabled: bool = requested and window.transparent and effective.background_blur
	var material := _material(effective)
	# Windows materials and X11 blur hints do not expose a per-window radius.
	if OS.get_name() == "macOS" and radius >= 0.0: material = roundi(clampf(radius, 0.0, 64.0))
	return _apply_native(window, enabled, material) and enabled and (DisplayServer.get_name() != "macOS" or material > 0)


func _exit_tree() -> void:
	if applied and native != null and is_instance_valid(host):
		var window_id := get_window().get_window_id()
		if not window_id in DisplayServer.get_window_list():
			return
		var backend := DisplayServer.get_name()
		var display := (
			DisplayServer.window_get_native_handle(DisplayServer.DISPLAY_HANDLE, window_id)
			if backend == "X11"
			else 0
		)
		native.apply(
			DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window_id),
			false,
			0,
			display,
			backend,
		)
