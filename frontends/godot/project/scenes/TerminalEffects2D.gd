extends Node2D
## Canvas effects using the same typing envelopes and wave shader as the 3D world.
## surface_frame(uv) returns sheet pixels; depth-dependent lens effects are omitted.
const RenderUpdates := preload("res://scenes/RenderUpdates.gd")
const Config := preload("res://scenes/Effects.gd")
const Particles := preload("res://scenes/TerminalParticles2D.gd")
const Trail := preload("res://scenes/CursorTrail2D.gd")
signal typed(uv: Vector2)
var effect_control := preload("res://scenes/EffectControl.gd").new()
var enabled := true
var automatic := true
var config = Config.new()
var terminal: Node
var sheet_material: ShaderMaterial
var surface_frame: Callable
## Logical terminal texture pixels -> displayed pose, or null while frozen/hidden.
var cursor_frame: Callable
var particles: Node2D
var trail: Node2D
var cursor := Vector2(0.5, 0.5)
var splash_at := Vector2(0.5, 0.5)
var splash_age := -1.0
var elapsed := 0.0
var last_key := -100.0
var typing := 0.0
var burst_count := 0
var camera_zoom := 1.0
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
	configure(config)


static func layout_size(viewport: SubViewport) -> Vector2i:
	return (
		viewport.size_2d_override
		if (viewport.size_2d_override_stretch and viewport.size_2d_override.x > 0)
		else viewport.size
	)


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


func bind_terminal(node: Node, supplied_material: ShaderMaterial, mapping: Callable, presentation: Callable) -> void:
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
	if sheet_material != supplied_material:
		splash_age = -1.0
		splash_rings.clear()
	terminal = node
	sheet_material = supplied_material
	surface_frame = mapping
	cursor_frame = presentation
	trail.clear()
	if terminal != null and terminal.has_signal("keystroke"):
		terminal.keystroke.connect(_on_keystroke)


func _on_keystroke(cell: Vector2i, _unicode: int) -> void:
	if not enabled or not is_instance_valid(terminal):
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
		var position: Vector2 = displayed
		var neighbour: Vector2 = cursor_frame.call(point + Vector2.RIGHT)
		particles.units_per_pixel = position.distance_to(neighbour)
		particles.cell_height = terminal.get_cell_size().y
		particles.burst(Vector3(position.x, position.y, 0), Vector3.UP * -1.0, Vector3.FORWARD)
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


var tint_poll := 0.0


func _process(dt: float) -> void:
	var profiled_started := Time.get_ticks_usec()
	_process_body(dt)
	preload("res://graffitty/frame_profile.gd").add("TerminalEffects2D", Time.get_ticks_usec() - profiled_started)


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
	if sheet_material == null:
		return
	RenderUpdates.uniform(sheet_material, "ripple_phase", ripple_phase)
	RenderUpdates.uniform(sheet_material, "wave_zoom", camera_zoom)
	var packets := PackedVector4Array(splash_rings)
	packets.resize(8)
	RenderUpdates.uniform(sheet_material, "splash_rings", packets)
	RenderUpdates.uniform(sheet_material, "splash_count", splash_rings.size())
	if sheet_panel.has_area():
		RenderUpdates.uniform(sheet_material,
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
		RenderUpdates.uniform(sheet_material,
			"panel_rect",
			Vector4(
				origin.x / size.x,
				origin.y / size.y,
				terminal.size.x * sheet_scale / size.x,
				terminal.size.y * sheet_scale / size.y,
			),
		)
	for key in ["corner_radius", "edge_blur", "edge_shadow", "edge_shadow_width"]:
		RenderUpdates.uniform(sheet_material, key, config.scene.sheet[key] * (effect_control.weight("sheet.shadow") if key == "edge_shadow" else 1.0))
	RenderUpdates.uniform(sheet_material, "cursor", cursor)
	RenderUpdates.uniform(sheet_material, "ripple", float(frame["sheet.ripple"]) if enabled else 0.0)
	for key in ["ripple_wavelength", "ripple_speed", "ripple_falloff"]:
		RenderUpdates.uniform(sheet_material, key, config.scene.sheet[key])
	RenderUpdates.uniform(sheet_material,
		"splash",
		Vector4(splash_at.x, splash_at.y, splash_age, ty.splash_scale if enabled else 0.0),
	)
	RenderUpdates.uniform(sheet_material, "splash_speed", ty.splash_speed)
	RenderUpdates.uniform(sheet_material, "splash_life", ty.splash_life)
