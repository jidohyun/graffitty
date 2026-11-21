extends MultiMeshInstance3D
## Quads for cells, runs or multiline blocks. Scatter retains native drawing
## state; whole-pane transitions can keep their terminal source live.
## Fine scatter skips empty cells; bounded scatter keeps spaces transparent.

const ShatterShader := preload("res://scenes/cell_shatter.gdshader")
const TerminalEffects := preload("res://scenes/TerminalEffects.gd")

var _cells := 0
# The grid starts inside the control by its padding, so the rect's own origin
# is not cell (0, 0).
#
# Missing this puts every piece a few pixels off and the assembled screen no
# longer matches the terminal it was cut from.
var _padding := 4.0
var _spread := 7.0
var _captures: Array[SubViewport] = []
var _raster_targets: Array[WeakRef] = []
var live_source: WeakRef

## A cursor belongs only to a live texture, never to a retained glyph snapshot.
## Return the same deformed plane that the depth shader displays.
func presentation_frame(point: Vector2) -> Transform3D:
	var source: SubViewport = live_source.get_ref()
	var size := Vector2(TerminalEffects.layout_size(source))
	var uv := point / size
	var origin := _presented_point(uv)
	var right := (_presented_point(uv + Vector2(1.0 / size.x, 0)) - origin).normalized()
	var up := (origin - _presented_point(uv + Vector2(0, 1.0 / size.y))).normalized()
	return Transform3D(Basis(right, up, right.cross(up).normalized()), origin)

func _presented_point(uv: Vector2) -> Vector3:
	var mat := _material()
	var rect: Vector4 = mat.get_shader_parameter("source_sheet_rect")
	var size: Vector2 = mat.get_shader_parameter("source_sheet_size")
	var source := Vector2(rect.x, rect.y) + uv * Vector2(rect.z, rect.w)
	var short_side := minf(size.x, size.y)
	var cursor: Vector2 = mat.get_shader_parameter("source_cursor")
	var math := preload("res://scenes/SheetMath.gd")
	var depth := math.ripple_depth(((source - cursor) * size).length(), mat.get_shader_parameter("source_ripple"), mat.get_shader_parameter("source_wavelength"), mat.get_shader_parameter("source_falloff"), short_side, mat.get_shader_parameter("source_phase"), mat.get_shader_parameter("source_zoom"))
	var rings = mat.get_shader_parameter("source_splashes")
	for i in int(mat.get_shader_parameter("source_splash_count")):
		var ring: Vector4 = rings[i]
		depth += math.splash_depth(((source - Vector2(ring.x, ring.y)) * size).length(), ring.z, ring.w, mat.get_shader_parameter("source_wavelength"), short_side, mat.get_shader_parameter("source_splash_speed"), mat.get_shader_parameter("source_splash_life"), mat.get_shader_parameter("source_zoom"))
	source = Vector2(0.5, 0.5) + (source - Vector2(0.5, 0.5)) / maxf(1.0 + depth, 0.001)
	source = math.saddle_project(source, Rect2(0, 0, 1, 1), size, rad_to_deg(mat.get_shader_parameter("source_curvature")))
	uv = (source - Vector2(rect.x, rect.y)) / Vector2(rect.z, rect.w)
	var origin: Vector3 = mat.get_shader_parameter("plane_a_origin")
	var du: Vector3 = mat.get_shader_parameter("plane_a_du")
	var dv: Vector3 = mat.get_shader_parameter("plane_a_dv")
	return global_transform * (origin + du * uv.x + dv * uv.y)


func bind_live_source(viewport: SubViewport) -> void:
	_release_live_source()
	live_source = weakref(viewport)
	preload("res://scenes/TerminalViewportUpdates.gd").retain_live(viewport)
	# Closing a shell can destroy its viewport before the departure completes.
	viewport.tree_exiting.connect(freeze_live_source)


func _release_live_source() -> void:
	if live_source == null: return
	var viewport: SubViewport = live_source.get_ref()
	live_source = null
	if not is_instance_valid(viewport): return
	if viewport.tree_exiting.is_connected(freeze_live_source):
		viewport.tree_exiting.disconnect(freeze_live_source)
	preload("res://scenes/TerminalViewportUpdates.gd").release_live(viewport)


func freeze_live_source() -> void:
	if live_source == null: return
	var viewport: SubViewport = live_source.get_ref()
	if is_instance_valid(viewport):
		_material().set_shader_parameter("terminal_tex", _capture_texture(viewport, (1 << 17) | (1 << 18) | (1 << 19), self))
	_release_live_source()


func _capture_texture(viewport: SubViewport, mask: int, parent: Node = null) -> Texture2D:
	var view := capture(viewport, mask, parent)
	if view not in _captures:
		_captures.append(view)
		_raster_targets.append(weakref(view))
		view.set_meta("users", int(view.get_meta("users", 0)) + 1)
	return view.get_texture()


func _exit_tree() -> void:
	_release_live_source()
	for view in _captures:
		if not is_instance_valid(view):
			continue
		var users := int(view.get_meta("users", 1)) - 1
		view.set_meta("users", users)
		if users == 0:
			view.queue_free()
	_captures.clear()


static func capture_control(control: Control) -> SubViewport:
	# Screen-space labels become approaching 3D cards. Preserve their native DPI
	# and start with enough detail for the visible 3x enlargement.
	var logical := Vector2i(control.size.ceil()).max(Vector2i.ONE)
	var density := control.get_viewport().get_final_transform().get_scale().abs()
	var scale := 3.0 * maxf(1.0, maxf(density.x, density.y))
	scale = minf(scale, 8192.0 / maxf(logical.x, logical.y))
	scale = minf(scale, sqrt(4_000_000.0 / (float(logical.x) * logical.y)))
	var still := preload("res://scenes/RetainedViewport.gd").new()
	still.transparent_bg = true
	still.use_hdr_2d = true
	still.disable_3d = true
	still.size_2d_override = logical
	still.size_2d_override_stretch = true
	still.oversampling = true
	still.size = Vector2i((Vector2(logical) * scale).floor()).max(Vector2i.ONE)
	preload("res://scenes/EffectCaptureBudget.gd").fit(still)
	still.render_target_update_mode = SubViewport.UPDATE_ONCE
	var copy := preload("res://scenes/RetainedPresentation.gd").control(control)
	copy.position = Vector2.ZERO
	# Placement/scale belongs to the captured card's sheet rectangle. Keep the
	# local raster at the control's logical size instead of clipping zoomed UI.
	copy.scale = Vector2.ONE
	copy.rotation = 0.0
	copy.modulate = Color.WHITE
	copy.visible = true
	still.add_child(copy)
	# A container-owned control otherwise falls back to its minimum size when
	# reparented into a viewport. Its retained layout fills the logical target.
	copy.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return still


static func capture(viewport: SubViewport, mask: int, parent: Node = null) -> SubViewport:
	# Layer-owned captures must not be shared with a shorter-lived sibling.
	var key := "effect_capture_%d_%d" % [mask, parent.get_instance_id() if parent != null else 0]
	var reference: WeakRef = viewport.get_meta(key) if viewport.has_meta(key) else null
	var result: SubViewport = reference.get_ref() if reference != null else null
	if not is_instance_valid(result) or result.is_queued_for_deletion() or int(result.get_meta("capture_frame", -1)) != Engine.get_process_frames():
		result = preload("res://scenes/RetainedViewport.gd").capture_state(viewport, mask, parent)
		result.name = key
		result.set_meta("capture_frame", Engine.get_process_frames())
		viewport.set_meta(key, weakref(result))
	return result


func _remember_padding(term: Node) -> void:
	if term.get("cell_padding") != null:
		_padding = float(term.get("cell_padding"))


func build_cells(
	term: Node,
	viewport: SubViewport,
	rect: Rect2,
	uv_origin: Vector3,
	uv_du: Vector3,
	uv_dv: Vector3,
	cells: Array,
	motion := Vector2(7.0, 5.0),
	delay_range := Vector2(0.0, 0.85),
	chunk_columns := 0,
	fragment := false,
	dust_budget := 16384,
	fly_ratio := -1.0,
) -> int:
	## Vector4i stores (column, row, column span, row span); Vector3i is one row.
	## chunk_columns coalesces adjacent cells during the same conversion pass.
	##
	## `Terminal.cell_glyphs()` already knows where the ink is and what each cell
	## holds, so a layer of emoji, or of 한글, or of everything bold, needs no
	## pixel readback.
	var grid: Vector2i = term.call("get_grid_size")
	var cell: Vector2 = term.call("get_cell_size")
	if grid.x <= 0 or grid.y <= 0 or cell.x <= 0.0 or cell.y <= 0.0 or cells.is_empty():
		return 0
	if fragment:
		var positions := PackedFloat32Array()
		for item in cells: positions.append(float(item.x))
		var particles := preload("res://scenes/DustPieces.gd").particles(term, rect, cells, dust_budget, release_ranks(positions), fly_ratio)
		var regions: Array = particles.rects
		if regions.is_empty(): return 0
		build_regions(viewport, regions, rect, uv_origin, uv_du, uv_dv, Vector2.ZERO, 1 << 18, true)
		set_meta("dust", true)
		var layout := Vector2(TerminalEffects.layout_size(viewport))
		for i in regions.size():
			var region: Rect2 = regions[i]
			multimesh.set_instance_custom_data(i, Color(region.position.x / layout.x, region.position.y / layout.y, region.size.x / layout.x, region.size.y / layout.y))
			multimesh.set_instance_color(i, Color(particles.ranks[i], 1, 1, 1))
		_material().set_shader_parameter("dust_mode", true)
		_material().set_shader_parameter("dust_count", regions.size())
		_material().set_shader_parameter("dust_tex_size", layout)
		return regions.size()

	_remember_padding(term)
	var runs := cell_runs(cells, chunk_columns)
	var inked: Array[Vector2i] = runs.positions
	var widths: PackedInt32Array = runs.widths
	return _emit(
		viewport,
		rect,
		uv_origin,
		uv_du,
		uv_dv,
		inked,
		grid,
		cell,
		motion,
		delay_range,
		widths,
		runs.heights,
	)


## The native terminal enumerates rows/columns in order; layer filtering keeps
## that order. Coalesce in the existing linear conversion pass, with no sorting,
## word parsing, readback, additional draw calls, or per-frame CPU animation.
static func cell_runs(cells: Array, columns: int) -> Dictionary:
	var positions: Array[Vector2i] = []
	var widths := PackedInt32Array()
	var heights := PackedInt32Array()
	for cell in cells:
		var width: int = maxi(cell.z, 1) if cell is Vector3i or cell is Vector4i else 1
		var height: int = maxi(cell.w, 1) if cell is Vector4i else 1
		if not cell is Vector4i and columns > 0 and not positions.is_empty():
			var last := positions[-1]
			if last.y == cell.y and last.x + widths[-1] == cell.x and widths[-1] < columns:
				widths[-1] += width
				continue
		positions.append(Vector2i(cell.x, cell.y))
		widths.append(width)
		heights.append(height)
	return {"positions": positions, "widths": widths, "heights": heights}


static func limit_layers(layers: Array, maximum: int) -> Array:
	# Zero preserves the original short runs and semantic layers without regrouping.
	if maximum <= 0: return layers
	var glyphs := 0
	for cells in layers: glyphs += cells.size()
	if glyphs <= maximum: return layers
	# A short run can contain at most three glyphs. Dense screens need no
	# temporary run arrays just to discover that they exceed the budget.
	if glyphs <= maximum * 3:
		var count := 0
		for cells in layers: count += cell_runs(cells, 3).positions.size()
		if count <= maximum: return layers
	var combined: Array = []
	for cells in layers: combined.append_array(cells)
	var result: Array = []
	for i in layers.size():
		result.append(preload("res://scenes/ScatterBlocks.gd").build(combined, maximum) if i == 0 else [])
	return result


static func chunk_cells(cells: Array, columns: int = 3) -> Array:
	var runs := cell_runs(cells, columns)
	var chunks: Array = []
	for i in runs.positions.size():
		chunks.append(Vector3i(runs.positions[i].x, runs.positions[i].y, runs.widths[i]))
	return chunks


func _emit(
	viewport: SubViewport,
	rect: Rect2,
	uv_origin: Vector3,
	uv_du: Vector3,
	uv_dv: Vector3,
	inked: Array[Vector2i],
	grid: Vector2i,
	cell: Vector2,
	motion: Vector2,
	delay_range: Vector2,
	widths := PackedInt32Array(),
	heights := PackedInt32Array(),
) -> int:
	_cells = inked.size()
	if _cells == 0:
		return 0
	var texture_size := Vector2(TerminalEffects.layout_size(viewport))
	var cell_uv := cell / texture_size
	var grid_origin := rect.position + Vector2(_padding, _padding)

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var material := ShaderMaterial.new()
	material.shader = ShatterShader
	material.set_shader_parameter("terminal_tex", _capture_texture(viewport, 1 << 18))
	material.set_shader_parameter("cell_uv", cell_uv)
	material.set_shader_parameter("multirow_cells", true)
	material.set_shader_parameter("progress", 0.0)
	_spread = motion.x
	material.set_shader_parameter("spread", motion.x)
	material.set_shader_parameter("spin", motion.y)
	# The pieces are placed by the shader from this map, not by their instance
	# transform, so one uniform can slide the whole screen onto another wall.
	for side in ["a", "b"]:
		material.set_shader_parameter("plane_%s_origin" % side, uv_origin)
		material.set_shader_parameter("plane_%s_du" % side, uv_du)
		material.set_shader_parameter("plane_%s_dv" % side, uv_dv)
	material.set_shader_parameter("travel", 0.0)
	quad.surface_set_material(0, material)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = _cells

	# The cell's own axes in world space: u to the right, v down the wall.
	#
	# The instance transform no longer positions anything — the shader does — but
	# it still describes where the piece belongs, and costs one write.
	var right := uv_du * cell_uv.x
	var down := uv_dv * cell_uv.y
	var normal := uv_du.cross(uv_dv).normalized()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260919
	for i in _cells:
		var c: Vector2i = inked[i]
		var columns := widths[i] if not widths.is_empty() else 1
		var rows := heights[i] if not heights.is_empty() else 1
		var uv := (grid_origin + Vector2(c.x * cell.x, c.y * cell.y)) / texture_size
		var centre := uv_origin + uv_du * (uv.x + cell_uv.x * columns * 0.5) + uv_dv * (
			uv.y + cell_uv.y * rows * 0.5
		)
		# Columns: the quad's local x, y and z mapped onto the wall's plane.
		var basis := Basis(right * columns, -down * rows, normal)
		mm.set_instance_transform(i, Transform3D(basis, centre))
		# Start later columns and lower rows later so text assembles in a wave.
		# Use `delay_range` to place this wave within the full arrival and let
		# other layers follow it.
		var wave := clampf(
			float(c.x) / maxf(float(grid.x), 1.0) * 0.64
			+ float(c.y) / maxf(float(grid.y), 1.0) * 0.36,
			0.0,
			1.0,
		)
		var delay := clampf(lerpf(delay_range.x, delay_range.y, wave), 0.0, 0.999)
		# Delay is below one; its integer part carries the extra column count.
		mm.set_instance_custom_data(i, Color(uv.x, uv.y, columns - 1 + delay, rows - 1 + minf(rng.randf(), 0.999)))
	multimesh = mm
	# Every piece starts up to `spread` cells away, so the visibility box has to
	# hold the scattered state or Godot culls the whole thing on approach.
	var span := (uv_du + uv_dv).length()
	custom_aabb = AABB(uv_origin - Vector3.ONE * span, Vector3.ONE * span * 3.0)
	return _cells


func build_regions(
	viewport: SubViewport,
	regions: Array,
	rect: Rect2,
	uv_origin: Vector3,
	uv_du: Vector3,
	uv_dv: Vector3,
	motion := Vector2(3.0, 12.0),
	capture_mask := 1 << 19,
	instance_colors := false,
) -> int:
	## Keep each image intact by emitting one piece per region.
	## Each Rect2 uses texel coordinates measured from the grid's origin.
	if regions.is_empty():
		return 0
	var texture_size := Vector2(TerminalEffects.layout_size(viewport))
	var first: Rect2 = regions[0]
	var region_uv := first.size / texture_size

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var material := ShaderMaterial.new()
	material.shader = ShatterShader
	material.set_shader_parameter(
		"terminal_tex",
		_capture_texture(viewport, capture_mask) if capture_mask else viewport.get_texture(),
	)
	if capture_mask == 0 and viewport.has_method("request_extent"):
		_raster_targets.append(weakref(viewport))
	_spread = motion.x
	material.set_shader_parameter("cell_uv", region_uv)
	# Set the position map for this path too. The shader places pieces from
	# the map. `build()` sets it through `_emit()`.
	#
	# Without the map, correctly sized pieces collapse to a point at the
	# world origin.
	for side in ["a", "b"]:
		material.set_shader_parameter("plane_%s_origin" % side, uv_origin)
		material.set_shader_parameter("plane_%s_du" % side, uv_du)
		material.set_shader_parameter("plane_%s_dv" % side, uv_dv)
	material.set_shader_parameter("travel", 0.0)
	material.set_shader_parameter("progress", 0.0)
	material.set_shader_parameter("spread", motion.x)
	material.set_shader_parameter("spin", motion.y)
	quad.surface_set_material(0, material)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.use_colors = instance_colors
	mm.instance_count = regions.size()
	var normal := uv_du.cross(uv_dv).normalized()
	for i in regions.size():
		var region: Rect2 = regions[i]
		var uv := region.position / texture_size
		var size_uv := region.size / texture_size
		var centre := uv_origin + uv_du * (uv.x + size_uv.x * 0.5) + uv_dv * (
			uv.y + size_uv.y * 0.5
		)
		var basis := Basis(uv_du * size_uv.x, -uv_dv * size_uv.y, normal)
		mm.set_instance_transform(i, Transform3D(basis, centre))
		# Images land last, after the text has settled around them.
		mm.set_instance_custom_data(i, Color(uv.x, uv.y, 0.55, 0.3 + 0.4 * float(i)))
	multimesh = mm
	_cells = regions.size()
	var span := (uv_du + uv_dv).length()
	custom_aabb = AABB(uv_origin - Vector3.ONE * span, Vector3.ONE * span * 3.0)
	return _cells


func set_appearance(gain: float, exposure: float, preserve_opacity := true) -> void:
	## Match live terminal compositing; movement must not re-expose the ink.
	var material := _material()
	material.set_shader_parameter("ink_gain", gain)
	material.set_shader_parameter("exposure_compensation", maxf(exposure, 0.0001))
	material.set_shader_parameter("preserve_flight_opacity", preserve_opacity)
	if preserve_opacity:
		material.set_shader_parameter("fade", 1.0)
		material.set_shader_parameter("thickness_shade", 1.0)


func set_progress(t: float) -> void:
	_material().set_shader_parameter("progress", clampf(t, 0.0, 1.0))


func set_fade(a: float) -> void:
	## Below zero the alpha follows progress, which is what an arrival wants.
	## Held, a scattered piece stays visible — a departure has to be watchable
	## after it has finished coming apart.
	_material().set_shader_parameter("fade", a)


func set_spread_scale(k: float) -> void:
	## Pieces keep travelling after progress has bottomed out; otherwise they
	## hang perfectly still in the air while the camera flies past them.
	_material().set_shader_parameter("spread", _spread * k)


func set_planes(
	a_origin: Vector3,
	a_du: Vector3,
	a_dv: Vector3,
	b_origin: Vector3,
	b_du: Vector3,
	b_dv: Vector3,
) -> void:
	## Where the screen starts and where it is going. Both maps are the wall's
	## own uv -> world, so a piece keeps its cell wherever it is in between.
	var m := _material()
	m.set_shader_parameter("plane_a_origin", a_origin)
	m.set_shader_parameter("plane_a_du", a_du)
	m.set_shader_parameter("plane_a_dv", a_dv)
	m.set_shader_parameter("plane_b_origin", b_origin)
	m.set_shader_parameter("plane_b_du", b_du)
	m.set_shader_parameter("plane_b_dv", b_dv)
	# Culling is done against one box, so it has to hold both walls and the
	# scatter around them, or the screen vanishes somewhere over the courtyard.
	var span := (a_du + a_dv).length() + (b_du + b_dv).length() + _spread
	var lo := Vector3(
		minf(a_origin.x, b_origin.x),
		minf(a_origin.y, b_origin.y),
		minf(a_origin.z, b_origin.z),
	) - Vector3.ONE * span
	var hi := Vector3(
		maxf(a_origin.x, b_origin.x),
		maxf(a_origin.y, b_origin.y),
		maxf(a_origin.z, b_origin.z),
	) + Vector3.ONE * span
	custom_aabb = AABB(lo, hi - lo)


func update_raster(camera: Camera3D) -> void:
	if _raster_targets.is_empty(): return
	var material := _material()
	var origin: Vector3 = material.get_shader_parameter("plane_a_origin")
	var du: Vector3 = material.get_shader_parameter("plane_a_du")
	var dv: Vector3 = material.get_shader_parameter("plane_a_dv")
	var bounds := Rect2()
	var first := true
	for uv in [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]:
		var point: Vector3 = global_transform * (origin + du * uv.x + dv * uv.y)
		if camera.is_position_behind(point): return
		var pixel := camera.unproject_position(point)
		bounds = Rect2(pixel, Vector2.ZERO) if first else bounds.expand(pixel)
		first = false
	var extent := bounds.size
	for reference in _raster_targets:
		var viewport: SubViewport = reference.get_ref()
		if is_instance_valid(viewport): viewport.request_extent(extent)


func set_fly(target: Vector3, t: float) -> void:
	## Set the destination point and progress along the flight.
	## The pieces converge on that point near the viewer.
	var m := _material()
	m.set_shader_parameter("fly_target", target)
	m.set_shader_parameter("fly", maxf(t, 0.0))
	if get_meta("glyph_layer", false):
		# Flying text clears every pane backing (priorities <= 120). Restore
		# the original canvas stack at the exact assembled handoff.
		if not has_meta("assembled_priority"):
			set_meta("assembled_priority", m.render_priority)
		m.render_priority = 121 if t > 0.0 else int(get_meta("assembled_priority"))
	# Give Godot a culling box that covers the whole flight.
	#
	# The wall's box excludes pieces that approach the camera while still
	# onscreen. Godot can then cull the entire MultiMesh too early.
	var box := custom_aabb
	box = box.expand(target)
	box = box.grow(_spread * 2.0)
	custom_aabb = box


func set_fly_character(
	stagger: float,
	tumble: float,
	tilt: float,
	arc: float = 0.18,
	ease: float = 2.2,
) -> void:
	## Set how this layer's pieces move.
	##
	## - Spread their start times.
	## - Set how much they turn and how far their paths bend.
	## - Set acceleration along each path. A value of 1 means constant speed.
	var m := _material()
	m.set_shader_parameter("fly_stagger", clampf(stagger, 0.0, 0.9))
	m.set_shader_parameter("fly_tumble", tumble)
	m.set_shader_parameter("fly_tilt", tilt)
	m.set_shader_parameter("fly_arc", arc)
	m.set_shader_parameter("fly_ease", maxf(ease, 1.0))


static func release_ranks(positions: PackedFloat32Array, random_seed: int = -1) -> PackedFloat32Array:
	# A random first 20% from the right half of the occupied text gives the
	# release a direction. The next 60% and final 20% mix the entire remainder.
	#
	# Measure occupied bounds so a short prompt also catches the same gust.
	var count := positions.size()
	if count == 0: return PackedFloat32Array()
	var rng := RandomNumberGenerator.new()
	if random_seed < 0: rng.randomize()
	else: rng.seed = random_seed
	var order := range(count)
	_shuffle_release_order(order, rng)
	var left := positions[0]
	var right := positions[0]
	for x in positions:
		left = minf(left, x)
		right = maxf(right, x)
	var midpoint := (left + right) * 0.5
	var first_count := 1 if count == 1 else floori((count + 2) / 5.0)
	var first: Array[int] = []
	var remaining: Array[int] = []
	for i in order:
		if positions[i] >= midpoint and first.size() < first_count: first.append(i)
		else: remaining.append(i)
	# Removing the first right-hand picks biases the old order toward the left.
	# Reshuffle the remainder so stage two samples both halves uniformly.
	_shuffle_release_order(remaining, rng)
	# Sparse right halves use the already shuffled remainder to fill the quota.
	# No piece is sampled twice, even for one-column or highly uneven content.
	order = first + remaining
	var ranks := PackedFloat32Array()
	ranks.resize(count)
	for i in order.size():
		ranks[order[i]] = (float(i) + (0.5 if count > 1 else 0.0)) / maxf(count, 1.0)
	return ranks


static func _shuffle_release_order(order: Array, rng: RandomNumberGenerator) -> void:
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var previous: int = order[i]
		order[i] = order[j]
		order[j] = previous


static func assign_release_ranks(layers: Array) -> void:
	layers = layers.filter(func(layer): return not layer.has_meta("dust"))
	# Sample across the entire captured text, including every semantic batch
	# and pane. Small styled batches must not each release their own first 20%.
	var positions := PackedFloat32Array()
	for layer in layers:
		var mat: ShaderMaterial = layer._material()
		var mapping = mat.get_shader_parameter("source_sheet_rect")
		var rect: Vector4 = mapping if mapping is Vector4 else Vector4(0, 0, 1, 1)
		var cell: Vector2 = mat.get_shader_parameter("cell_uv")
		for i in layer.multimesh.instance_count:
			var data: Color = layer.multimesh.get_instance_custom_data(i)
			positions.append(rect.x + (data.r + cell.x * (1.0 + floorf(data.b)) * 0.5) * rect.z)
	var ranks := release_ranks(positions)
	var index := 0
	for layer in layers:
		for i in layer.multimesh.instance_count:
			var data: Color = layer.multimesh.get_instance_custom_data(i)
			data.a = floorf(data.a) + ranks[index] if layer._material().get_shader_parameter("multirow_cells") else ranks[index]
			layer.multimesh.set_instance_custom_data(i, data)
			index += 1


func enable_flight_volume() -> void:
	# One continuous alpha volume, with only its original front face at rest.
	var material := _material()
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var depths := PackedVector2Array()
	var indices := PackedInt32Array()
	# Six boundary faces of one prism. The shader traces the continuous
	# extruded alpha mask inside it instead of painting repeated glyph slices.
	var faces := [
		[Vector3(0,0,0), Vector3(1,0,0), Vector3(1,1,0), Vector3(0,1,0)],
		[Vector3(0,0,1), Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1)],
		[Vector3(0,0,0), Vector3(0,1,0), Vector3(0,1,1), Vector3(0,0,1)],
		[Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)],
		[Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)],
		[Vector3(0,1,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(0,1,1)],
	]
	for face in faces.size():
		var at := vertices.size()
		for corner: Vector3 in faces[face]:
			vertices.append(Vector3(corner.x - 0.5, 0.5 - corner.y, corner.z - 0.5))
			uvs.append(Vector2(corner.x, corner.y))
			depths.append(Vector2(corner.z, face))
		indices.append_array(PackedInt32Array([at, at + 1, at + 2, at, at + 2, at + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = depths
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	multimesh.mesh = mesh


func set_thickness(depth: float, shade: float = 0.45) -> void:
	## How solid a flying glyph looks, in fractions of a cell. Zero is the flat
	## piece the static demos want; a transition wants a little, so the letters
	## read as objects while they turn.
	var m := _material()
	m.set_shader_parameter("thickness", depth)
	m.set_shader_parameter("thickness_shade", shade)


func set_travel(t: float) -> void:
	## 0 on the wall it left, 1 on the wall it is going to.
	_material().set_shader_parameter("travel", clampf(t, 0.0, 1.0))


func _material() -> ShaderMaterial:
	return multimesh.mesh.surface_get_material(0) as ShaderMaterial
