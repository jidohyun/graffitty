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


func apply_background() -> void:
	super()
	_update_docked_backdrop()
	_update_embedded_backdrop()


func _update_docked_backdrop() -> void:
	if not is_instance_valid(_desktop): return
	if not background_blur or background_blur_radius <= 0.0 or not translucent():
		_desktop.material = null
		return
	var material := _desktop.material as ShaderMaterial
	if material == null:
		material = ShaderMaterial.new()
		material.shader = BACKDROP_SHADER
		_desktop.material = material
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
	var owner_window := _embedded_backdrop.get_window()
	var density := owner_window.content_scale_factor if owner_window != null else 1.0
	(_embedded_backdrop.material as ShaderMaterial).set_shader_parameter("radius", background_blur_radius * density)
	_embedded_backdrop.show()


func _exit_tree() -> void:
	if is_instance_valid(_embedded_backdrop): _embedded_backdrop.queue_free()
	super()
