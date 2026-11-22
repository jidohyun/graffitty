extends "res://scenes/DockableWindow.gd"
## Shared translucent backdrop for mod panels and Graffitty messages.
var source: Node
var background_blur := true
var background_blur_radius := 12.0
const BACKDROP_SHADER := preload("res://scenes/mods/panel_backdrop.gdshader")
var _embedded_backdrop: Panel


func _ready() -> void:
	super()
	visibility_changed.connect(_update_embedded_backdrop)


static func valid_blur_radius(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value)) and float(value) >= 0.0 and float(value) <= 64.0


## Copies only the screen region a translucent surface's blur samples, before
## the surface draws. Without it, Godot copies and mipmaps the whole render
## target for every screen-texture redraw.
class BackdropCopy extends BackBufferCopy:
	var radius := 0.0

	## Region around a surface of `size`, in its local pixels. Linear mipmap
	## lookups at lod log2(radius) reach about two mip texels of `radius` past
	## the edge; four keeps every sampled texel freshly copied.
	static func region(size: Vector2, blur_radius: float) -> Rect2:
		var reach := Vector2.ONE * 4.0 * ceilf(maxf(blur_radius, 1.0))
		return Rect2(-reach, size + reach * 2.0)

	func fit() -> void:
		rect = region((get_parent() as Control).size, radius)


static func _sync_backdrop_copy(surface: Control, radius: float) -> void:
	var copy := surface.get_node_or_null(^"BackdropCopy") as BackdropCopy
	if copy == null:
		copy = BackdropCopy.new()
		copy.name = "BackdropCopy"
		copy.copy_mode = BackBufferCopy.COPY_MODE_RECT
		copy.show_behind_parent = true
		surface.add_child(copy, false, Node.INTERNAL_MODE_FRONT)
		surface.resized.connect(copy.fit)
	copy.radius = radius
	copy.fit()


static func _remove_backdrop_copy(surface: Control) -> void:
	var copy := surface.get_node_or_null(^"BackdropCopy")
	if copy != null: copy.free()


func apply_background() -> void:
	super()
	_update_docked_backdrop()
	_update_embedded_backdrop()


func _update_docked_backdrop() -> void:
	if not is_instance_valid(_desktop): return
	if not background_blur or background_blur_radius <= 0.0 or not translucent():
		_desktop.material = null
		_remove_backdrop_copy(_desktop)
		return
	var material := _desktop.material as ShaderMaterial
	if material == null:
		material = ShaderMaterial.new()
		material.shader = BACKDROP_SHADER
		_desktop.material = material
	_sync_backdrop_copy(_desktop, background_blur_radius)
	var owner_window := _desktop.get_window()
	var density := owner_window.content_scale_factor if owner_window != null else 1.0
	material.set_shader_parameter("radius", background_blur_radius * density)
	material.set_shader_parameter("surface_opacity", background_opacity)


func _backdrop_changed() -> void:
	if force_native and visible and is_instance_valid(source) and source.get("desktop_blur") != null:
		source.desktop_blur.apply_to(self, not _dock_preview_active and background_blur and background_blur_radius > 0.0 and translucent(), background_blur_radius)


func _update_geometry() -> void:
	_update_embedded_backdrop()


func _update_embedded_backdrop() -> void:
	# Read the parent scene before subwindows are composited, not our own viewport.
	var enabled := is_inside_tree() and is_embedded() and visible and _workspace_active and background_blur and background_blur_radius > 0.0 and translucent()
	if is_instance_valid(_body) and _body.get_parent() != self: enabled = false
	if not enabled:
		if is_instance_valid(_embedded_backdrop): _embedded_backdrop.hide()
		return
	if not is_instance_valid(_embedded_backdrop):
		_embedded_backdrop = Panel.new()
		_embedded_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_embedded_backdrop.focus_mode = Control.FOCUS_NONE
		var shape := StyleBoxFlat.new()
		shape.bg_color = Color.WHITE
		shape.set_corner_radius_all(10)
		_embedded_backdrop.add_theme_stylebox_override("panel", shape)
		var material := ShaderMaterial.new()
		material.shader = BACKDROP_SHADER
		material.set_shader_parameter("surface_opacity", 1.0)
		material.set_shader_parameter("tint_surface", false)
		_embedded_backdrop.material = material
		get_parent().get_viewport().add_child(_embedded_backdrop)
	_embedded_backdrop.position = Vector2(position)
	_embedded_backdrop.size = Vector2(size)
	_sync_backdrop_copy(_embedded_backdrop, background_blur_radius)
	var owner_window := _embedded_backdrop.get_window()
	var density := owner_window.content_scale_factor if owner_window != null else 1.0
	(_embedded_backdrop.material as ShaderMaterial).set_shader_parameter("radius", background_blur_radius * density)
	_embedded_backdrop.show()


func _exit_tree() -> void:
	if is_instance_valid(_embedded_backdrop): _embedded_backdrop.queue_free()
	super()
