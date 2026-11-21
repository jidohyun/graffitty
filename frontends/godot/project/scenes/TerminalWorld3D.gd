extends "res://scenes/SpatialTerminalWorld.gd"
## Complete world kit: place TerminalSpace3D instances among your scenery.
## The inherited presenter owns session binding, tabs, input and rendering.
@export_file("*.conf") var effects_preset := "res://presets/flat.conf"

## Optional typed settings; read_settings() decides where their values come from.
@export var settings_script: GDScript
var settings: RefCounted

## Override to read your own client.toml table, for example
## `return WorldConfig.load_settings(settings_script, user, ["my-world"])`.
## The default uses the settings class's defaults with the user's terminal.
func read_settings(user: TerminalConfig) -> RefCounted:
	return settings_script.new(user.copy())

func configure_terminal(user: TerminalConfig) -> TerminalConfig:
	if settings_script == null: return super.configure_terminal(user)
	settings = read_settings(user)
	terminal_window = settings.terminal_window
	terminal_padding = settings.sheet.padding
	render_scale = settings.render_scale
	motion_render_scale = settings.motion_render_scale
	window_config = settings.window
	return settings.terminal

func configure_effects(effects: RefCounted) -> void:
	if settings != null:
		settings.apply_common_effects(effects)
		settings.apply_effects(effects)


func _init() -> void:
	terminal_space_scene = preload("res://scenes/TerminalSpace.tscn")
	world_mode = "3d"
	fixed_tab_camera = false
	backdrop_fill_viewport = false
	terminal_padding = 0.0
	use_navgraph = false


func _load_world() -> Dictionary:
	default_config = effects_preset
	surfaces.clear()
	_collect_spaces(self)
	var order := {}
	var used_ids := {}
	for surface in surfaces:
		if used_ids.has(surface.id):
			surface.surface_id = str(get_path_to(surface))
		while used_ids.has(surface.id): surface.surface_id += "_new"
		used_ids[surface.id] = true
	for i in surfaces.size(): order[surfaces[i]] = i
	surfaces.sort_custom(func(a, b):
		return a.visit_order < b.visit_order if a.visit_order != b.visit_order else order[a] < order[b])
	if surfaces.is_empty():
		# A newly created kit remains usable before the first space is placed.
		var space := preload("res://scenes/TerminalSpace3D.tscn").instantiate()
		add_child(space)
		surfaces.append(space)
	authored_surface_count = surfaces.size()
	return {}


func _collect_spaces(node: Node) -> void:
	for child in node.get_children():
		if child is TerminalSurface3D:
			surfaces.append(child)
		else:
			_collect_spaces(child)


func _build_world() -> void:
	_build_walls()


func _build_environment(light: Dictionary) -> void:
	var authored: WorldEnvironment = _find_environment(self)
	if authored == null or authored.environment == null:
		super._build_environment(light)
		fx_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		fx_env.ambient_light_color = Color(0.65, 0.7, 0.8)
		fx_env.ambient_light_energy = 0.6
	else:
		# Each host gets its own mutable effects environment.
		authored.environment = authored.environment.duplicate(true)
		fx_env = authored.environment
		fx_attr = CameraAttributesPhysical.new()
		get_viewport().transparent_bg = false
		preload("res://scenes/DesktopBlur.gd").set_window_transparent(get_window(), false)


func _find_environment(node: Node) -> WorldEnvironment:
	for child in node.get_children():
		if child is WorldEnvironment: return child
		var found := _find_environment(child)
		if found != null: return found
	return null


func _navigation_route(_previous: int, destination: int) -> PackedVector3Array:
	var surface: Node = surfaces[destination]
	if surface.has_method("camera_route_from"):
		return surface.camera_route_from(camera_motion.frame.transform.origin)
	return super._navigation_route(_previous, destination)
