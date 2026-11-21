extends Node3D
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
## Renderer-facing terminal effects. Own this node in the world, not the PTY.
## surface_frame(uv) returns a world-space Transform3D (+Y up, +Z toward viewer).
const Config := preload("res://scenes/Effects.gd")
const Particles := preload("res://scenes/TerminalParticles.gd")
const Trail := preload("res://scenes/CursorTrail.gd")
const SheetShader := preload("res://scenes/terminal_sheet.gdshader")
const ParticleShader := preload("res://scenes/terminal_particles.gdshader")
# Draw after alpha-blended scenery, before foreground sparks and world particles. The sheet
# writes depth for DoF; drawing it first would cut holes in the scenery's alpha.
const SHEET_RENDER_PRIORITY := 1
signal typed(uv: Vector2)
signal input_activity
var effect_control := preload("res://scenes/EffectControl.gd").new()
var enabled := true
var automatic := true
var config = Config.new()
var terminal: Node
var material: ShaderMaterial
var surface_frame: Callable
## Logical terminal texture pixels -> displayed pose, or null while frozen/hidden.
var cursor_frame: Callable
var particles: Node3D
var trail: Node3D
var blur_pyramid: Node
var cursor := Vector2(0.5, 0.5)
var splash_at := Vector2(0.5, 0.5)
var splash_age := -1.0
var elapsed := 0.0
var last_key := -100.0
var typing := 0.0
var burst_count := 0
var camera_zoom := 1.0
var focus_depth := 1.0
var blur_radius := 0.0
var blur_limit := 24.0
var depth_range := 1.0
var screen_dof := false
var blur_weight := 1.0
var defocus_weight := 0.0
## The depth of field last written to the camera's attributes.
var _applied_lens: Array = []
var ripple_phase := 0.0
var splash_rings: Array[Vector4] = []
## When the sheet shows more than this terminal (a workspace canvas of
## windows), the viewport it shows and where the terminal's viewport sits on it.
var sheet_viewport: SubViewport
var sheet_origin := Vector2.ZERO
var sheet_scale := 1.0
## The page in sheet uv; empty means the terminal's own rectangle.
var sheet_panel := Rect2()
var _preset := "none"


func _ready() -> void:
	particles = Particles.new()
	trail = Trail.new()
	add_child(particles)
	add_child(trail)
	blur_pyramid = preload("res://scenes/TerminalBlur.gd").new()
	add_child(blur_pyramid)
	# These are terminal-overlay sparks, not world particles. Authored world
	# surfaces are uneven; masonry must not swallow a burst on the ink plane.
	var particle_material := ShaderMaterial.new()
	particle_material.shader = ParticleShader
	particle_material.render_priority = 127
	particles.emitter.material_override = particle_material
	configure(config)


static func layout_size(viewport: SubViewport) -> Vector2i:
	return (
		viewport.size_2d_override
		if (viewport.size_2d_override_stretch and viewport.size_2d_override.x > 0)
		else viewport.size
	)


static func create_sheet_material(viewport: SubViewport) -> ShaderMaterial:
	var result := ShaderMaterial.new()
	result.shader = SheetShader
	RenderUpdates.uniform(result, "terminal_tex", viewport.get_texture())
	RenderUpdates.uniform(result, "tex_size", Vector2(layout_size(viewport)))
	result.render_priority = SHEET_RENDER_PRIORITY
	return result


func configure(settings: RefCounted) -> void:
	config = settings
	if trail != null:
		var cursor_settings = config.cursor_trail_settings()
		trail.configure(
			cursor_settings.delay,
			cursor_settings.decay,
			cursor_settings.start_threshold,
			cursor_settings.color,
			cursor_settings.style,
			cursor_settings.options,
		)
	_preset = "" # Refresh particle parameters on the next frame/key.


func cancel_typing() -> void:
	last_key = -1e9


func bind_terminal(node: Node, sheet_material: ShaderMaterial, mapping: Callable, presentation: Callable) -> void:
	if (
		is_instance_valid(terminal) and terminal.has_signal("keystroke")
		and terminal.keystroke.is_connected(_on_keystroke)
	):
		terminal.keystroke.disconnect(_on_keystroke)
	if terminal != node:
		cancel_typing()
		if particles != null: particles.clear()
		splash_age = -1.0
		splash_rings.clear()
	if material != sheet_material:
		splash_age = -1.0
		splash_rings.clear()
	terminal = node
	material = sheet_material
	blur_pyramid.bind(material)
	surface_frame = mapping
	cursor_frame = presentation
	trail.clear()
	if terminal != null and terminal.has_signal("keystroke"):
		terminal.keystroke.connect(_on_keystroke)


func _on_keystroke(cell: Vector2i, _unicode: int) -> void:
	if not is_instance_valid(terminal):
		return
	# Workspace interaction must remain active with visual effects disabled,
	# including applications that hide their cursor or report no cursor cell.
	input_activity.emit()
	if not enabled:
		return
	var grid: Vector2i = terminal.get_grid_size()
	if grid.x <= 0 or grid.y <= 0 or cell.x < 0 or cell.y < 0:
		return
	# The native event reports the pre-input cursor. Backspace erases the
	# preceding cell; forward Delete erases the cell under that cursor.
	if _unicode == 8:
		cell.x = maxi(0, cell.x - 1)
	particles.source_unicode = 0 if _unicode == 8 or _unicode == 127 else _unicode
	particles.text_color = terminal.get_write_color()
	if _unicode <= 0 or _unicode == 8 or _unicode == 127:
		var glyph := preload("res://scenes/ParticleTints.gd").glyph_at(terminal.cell_glyphs(), cell)
		if not glyph.is_empty():
			particles.text_color = glyph.get("foreground", particles.text_color)
			cell.x = int(glyph.col)
	particles.source_cell = cell
	pulse((Vector2(cell) + Vector2(0.5, 0.5)) / Vector2(grid))


func pulse(uv: Vector2) -> void:
	if not enabled:
		return
	var grid_uv := uv.clamp(Vector2.ZERO, Vector2.ONE)
	cursor = to_sheet_uv(grid_uv)
	effect_control.pulse()
	if effect_control.allows("sheet.splash"):
		splash_at = cursor
		splash_age = 0.0
		splash_rings.append(Vector4(cursor.x, cursor.y, 0.0, config.typing_settings().splash_scale))
		if splash_rings.size() > 8:
			splash_rings.pop_front()
	last_key = elapsed
	# Configure BEFORE the first burst; waiting for the next frame loses it.
	var frame: Dictionary = config.frame(str(config.behavior.active_state))
	_set_particles(str(frame["typing.particles"]))
	var point := preload("res://scenes/TerminalPresentation.gd").grid_point(terminal, grid_uv)
	var displayed = cursor_frame.call(point) if cursor_frame.is_valid() else null
	if displayed != null and effect_control.allows("sparks"):
		var pose: Transform3D = displayed
		var neighbour: Transform3D = cursor_frame.call(point + Vector2.RIGHT)
		particles.units_per_pixel = pose.origin.distance_to(neighbour.origin)
		particles.cell_height = terminal.get_cell_size().y
		particles.burst(
			pose.origin,
			pose.basis.y.normalized(),
			pose.basis.z.normalized(),
		)
		if _preset != "none":
			burst_count += 1
	typed.emit(grid_uv)


func sheet_size() -> Vector2:
	var viewport: SubViewport = sheet_viewport if is_instance_valid(sheet_viewport) else terminal.get_viewport()
	return Vector2(layout_size(viewport)).max(Vector2.ONE)


func to_sheet_uv(grid_uv: Vector2) -> Vector2:
	# The terminal Control may occupy only a content rectangle in its texture,
	# and that texture may be one window on a larger sheet.
	if (
		is_instance_valid(terminal) and terminal is Control
		and terminal.get_viewport() is SubViewport
	):
		return (sheet_origin + preload("res://scenes/TerminalPresentation.gd").grid_point(terminal, grid_uv) * sheet_scale) / sheet_size()
	return grid_uv


func _set_particles(preset: String) -> void:
	if _preset == preset:
		return
	_preset = preset
	var ty = config.typing_settings()
	particles.configure(preset, ty.particles_amount, ty.particles_scale)
	RenderUpdates.uniform(particles.emitter.material_override, "sparks", preset == "sparks")
	var process: ParticleProcessMaterial = particles.emitter.process_material
	if process != null:
		process.anim_offset_min = 0.0
		process.anim_offset_max = 1.0
		process.set_particle_flag(ParticleProcessMaterial.PARTICLE_FLAG_ALIGN_Y_TO_VELOCITY, true)


var tint_poll := 0.0


func _process(dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(dt)
	preload("res://graffitty/frame_profile.gd").add("TerminalEffects", Time.get_ticks_usec() - profiled_started)


func _process_body(dt: float) -> void:
	tint_poll -= dt
	if (
		tint_poll <= 0.0 and is_instance_valid(terminal)
		and not particles.sparks.is_empty()
	):
		particles.refresh_tints(terminal.cell_glyphs(), terminal.get_grid_size().x)
		tint_poll = 0.05
	if automatic:
		if is_instance_valid(terminal) and terminal.has_method("get_cursor_cell"):
			var cell: Vector2i = terminal.get_cursor_cell()
			var grid: Vector2i = terminal.get_grid_size()
			if cell.x >= 0 and grid.x > 0 and grid.y > 0:
				cursor = to_sheet_uv((Vector2(cell) + Vector2(0.5, 0.5)) / Vector2(grid))
		advance(dt)


func advance_cursor(dt: float) -> void:
	if enabled and is_instance_valid(terminal) and cursor_frame.is_valid() and cursor_frame.call(Vector2.ZERO) != null:
		if material != null:
			RenderUpdates.uniform(trail._material,
				"exposure_compensation",
				material.get_shader_parameter("exposure_compensation"),
			)
		var cursor_info: Dictionary = (
			terminal.get_cursor_render_info()
			if terminal.has_method("get_cursor_render_info")
			else { }
		)
		trail.update_cursor(
			terminal.get_cursor_cell(),
			terminal.get_grid_size(),
			dt,
			terminal.get_cell_size(),
			func(uv):
				return cursor_frame.call(preload("res://scenes/TerminalPresentation.gd").grid_point(terminal, uv)),
			cursor_info.get("rect", Rect2(0, 0, 1, 1)),
			cursor_info.get("color", Color.WHITE),
			effect_control.allows("cursor_trail"),
		)
	else:
		trail.clear()


func advance(dt: float, resolved_frame: Dictionary = { }) -> void:
	if automatic: effect_control.advance(dt, config.behavior.enter_duration, config.behavior.leave_duration)
	elapsed += dt
	if automatic: advance_cursor(dt)
	var target := 1.0 if enabled and elapsed - last_key < float(config.behavior.idle_after) else 0.0
	var duration: float = (
		config.behavior.enter_duration
		if target > typing
		else config \
				.behavior \
				.leave_duration
	)
	typing = lerpf(typing, target, 1.0 - pow(2.0, -10.0 * dt / maxf(duration, 0.001)))
	if absf(target - typing) < 0.000001: typing = target
	var frame: Dictionary = resolved_frame
	if frame.is_empty():
		frame = config.blend(
			config.frame(str(config.behavior.rest_state)),
			config.frame(str(config.behavior.active_state)),
			typing,
		)
		frame = effect_control.frame(frame, false, config.frame(str(config.behavior.rest_state)))
	_set_particles(str(frame["typing.particles"]) if enabled else "none")
	if not enabled:
		particles.clear()
	var ty = config.typing_settings()
	for i in splash_rings.size():
		splash_rings[i].z += dt
	splash_rings = splash_rings.filter(
		func(ring):
			return enabled and ring.z < ty.splash_life,
	)
	if enabled and float(frame["sheet.ripple"]) > 0.01:
		ripple_phase += dt * float(config.scene.sheet.ripple_speed)
	if splash_age >= 0.0:
		splash_age += dt
		if splash_age > ty.splash_life or not enabled:
			splash_age = -1.0
	if material == null:
		return
	RenderUpdates.uniform(particles.emitter.material_override,
		"exposure_compensation",
		material.get_shader_parameter("exposure_compensation"),
	)
	RenderUpdates.uniform(material, "ripple_phase", ripple_phase)
	RenderUpdates.uniform(material, "wave_zoom", camera_zoom)
	var packets := PackedVector4Array(splash_rings)
	packets.resize(8)
	RenderUpdates.uniform(material, "splash_rings", packets)
	RenderUpdates.uniform(material, "splash_count", splash_rings.size())
	if sheet_panel.has_area():
		RenderUpdates.uniform(material,
			"panel_rect",
			Vector4(
				sheet_panel.position.x,
				sheet_panel.position.y,
				sheet_panel.size.x,
				sheet_panel.size.y,
			),
		)
	elif (
		is_instance_valid(terminal) and terminal is Control
		and terminal.get_viewport() is SubViewport
	):
		var size := sheet_size()
		var origin: Vector2 = sheet_origin + terminal.position * sheet_scale
		RenderUpdates.uniform(material,
			"panel_rect",
			Vector4(
				origin.x / size.x,
				origin.y / size.y,
				terminal.size.x * sheet_scale / size.x,
				terminal.size.y * sheet_scale / size.y,
			),
		)
	for key in ["corner_radius", "edge_blur", "edge_shadow", "edge_shadow_width"]:
		RenderUpdates.uniform(material, key, config.scene.sheet[key] * (effect_control.weight("sheet.shadow") if key == "edge_shadow" else 1.0))
	RenderUpdates.uniform(material, "cursor", cursor)
	RenderUpdates.uniform(material, "ripple", float(frame["sheet.ripple"]) if enabled else 0.0)
	for key in ["ripple_wavelength", "ripple_speed", "ripple_falloff"]:
		RenderUpdates.uniform(material, key, config.scene.sheet[key])
	RenderUpdates.uniform(material,
		"splash",
		Vector4(splash_at.x, splash_at.y, splash_age, ty.splash_scale if enabled else 0.0),
	)
	RenderUpdates.uniform(material, "splash_speed", ty.splash_speed)
	RenderUpdates.uniform(material, "splash_life", ty.splash_life)


func update_lens(
	camera: Camera3D,
	focus: Vector3,
	zoom_factor: float,
	depth_override: float = -1.0,
	focus_weight: float = 1.0,
	previous_optics: Vector3 = Vector3(0.0, 0.0263, 0.0),
	lens_progress: float = 1.0,
) -> void:
	focus_weight *= effect_control.weight("camera.dof")
	defocus_weight = clampf(focus_weight, 0.0, 1.0) if enabled else 0.0
	var cursor_depth := maxf((focus - camera.global_position).dot(-camera.global_basis.z), 0.051)
	focus_depth = maxf(depth_override if depth_override >= 0.0 else cursor_depth, 0.051)
	# Godot's bokeh pass uses a 64 px base radius per unit of dof_blur_amount.
	blur_radius = (
		float(config.scene.camera.get("dof_blur_amount", 0.125)) * 64.0 * maxf(zoom_factor, 1.0) * clampf(
			focus_weight,
			0.0,
			1.0,
		)
		if enabled
		else 0.0
	)
	# Scale the blur radius itself. A lower cap leaves the blur unchanged
	# until it crosses the radius, then makes the blur drop abruptly.
	blur_radius *= clampf(blur_weight, 0.0, 1.0)
	# Normalize terminal blur to the visible sheet's depth range rather than
	# a hypothetical point at infinity.
	depth_range = 0.0263
	if surface_frame.is_valid():
		for uv in [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]:
			var pose: Transform3D = surface_frame.call(uv)
			var depth := maxf(
				(pose.origin - camera.global_position).dot(-camera.global_basis.z),
				0.051,
			)
			depth_range = maxf(depth_range, absf(1.0 - focus_depth / depth))
	# A session bind resets typing and changes the measured sheet depth range.
	#
	# Preserve both optical strength and its normalization at departure; focus
	# depth alone cannot prevent an immediate loss of blur on the retained pane.
	var optics := blend_lens(previous_optics, Vector3(blur_radius, depth_range, defocus_weight), lens_progress)
	blur_radius = optics.x
	depth_range = optics.y
	defocus_weight = optics.z
	if material != null:
		RenderUpdates.uniform(material, "blur_limit", blur_limit)
		RenderUpdates.uniform(material, "focus_depth", focus_depth)
		configure_defocus_tint(material)
		RenderUpdates.uniform(material,
			"blur_radius",
			0.0 if screen_dof else blur_radius / depth_range,
		)
		blur_pyramid.update(blur_radius > 0.0 and not screen_dof)
	RenderUpdates.uniform(particles.emitter.material_override, "focus_depth", focus_depth)
	RenderUpdates.uniform(particles.emitter.material_override, "blur_radius", blur_radius)
	# Normalized thin-lens depth curve, through Godot's bokeh pass.
	if camera.attributes != null and not camera.get_viewport().transparent_bg:
		# Rewriting an unchanged lens kept the rendering server dirty, so a
		# world with physical camera attributes drew every frame at rest.
		var lens := [camera.attributes.get_rid(), blur_radius > 0.0, focus_depth, blur_radius / 64.0]
		if not _same_lens(lens, _applied_lens):
			_applied_lens = lens
			camera.attributes.set_meta("presentation_dof", [lens[1], focus_depth, -1.0, lens[1], focus_depth, -1.0, lens[3]])
			RenderingServer.camera_attributes_set_dof_blur(
				lens[0],
				lens[1],
				focus_depth,
				-1.0,
				lens[1],
				focus_depth,
				-1.0,
				lens[3],
			)


static func blend_lens(previous: Vector3, current: Vector3, progress: float) -> Vector3:
	var weight := clampf(progress, 0.0, 1.0)
	return Vector3(lerpf(previous.x, current.x, weight),
		1.0 / lerpf(1.0 / maxf(previous.y, 0.001), 1.0 / maxf(current.y, 0.001), weight),
		lerpf(previous.z, current.z, weight))

static func _same_lens(a: Array, b: Array) -> bool:
	return b.size() == a.size() and a[0] == b[0] and a[1] == b[1] \
		and is_equal_approx(a[2], b[2]) and is_equal_approx(a[3], b[3])


func configure_defocus_tint(target: ShaderMaterial) -> void:
	# Use the exact focus (including lens transitions) and depth range of DOF.
	# This weight is the same continuous lens weight, never a zoom-settled test.
	RenderUpdates.uniform(target, "defocus_focus_depth", focus_depth)
	RenderUpdates.uniform(target, "defocus_depth_range", depth_range)
	RenderUpdates.uniform(target, "defocus_weight", defocus_weight)
	RenderUpdates.uniform(target, "defocus_strength", float(config.scene.lighting.strength) * effect_control.weight("lighting"))
	RenderUpdates.uniform(target, "defocus_minimum", float(config.scene.lighting.minimum))
	RenderUpdates.uniform(target, "dof_blur_tint", Color(str(config.scene.camera.dof_blur_tint)))
	RenderUpdates.uniform(target, "dof_blur_tint_strength", float(config.scene.camera.dof_blur_tint_strength))
