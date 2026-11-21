extends Node2D
## Live terminal textures for whole-pane transitions; retained drawing state
## for glyph transitions, and copied UI rasterized at projected density.
const Core := preload("res://scenes/TerminalEffects.gd")
const Motion := preload("res://scenes/ScatterMotion.gd")
const DepthMotion := preload("res://scenes/TabDepthMotion.gd")
const Capture := preload("res://scenes/CellShatter.gd")
const TransitionShader := preload("res://scenes/tab_scatter_2d.gdshader")
var captures: Array[SubViewport] = []
var terminal_captures := {}
var panels: Array[CanvasItem] = []
var raster_items: Array[Node2D] = []
var glyphs: Array[MultiMeshInstance2D] = []
var pane_groups: Array[Node2D] = []
var ui_groups: Array[Node2D] = []
var dust_mode := false
var depth_mode := false
var depth_direction := 1.0
var depth_center := Vector2.ZERO
var depth_projection := Transform2D.IDENTITY
var depth_retirement := -1.0
var progress := 0.0
var arriving := false
var retirement_time := -1.0
var retirement_phase := 0.0
var live_panels: Array[Dictionary] = []

func presentation_point(viewport: SubViewport, point: Vector2, target: Node2D) -> Variant:
	for item in live_panels:
		if item.source.get_ref() != viewport: continue
		var sprite: Sprite2D = item.sprite
		if float(sprite.material.get_shader_parameter("depth_alpha")) <= 0.0001: return null
		var local := (point / Vector2(item.size) - Vector2(0.5, 0.5)) * Vector2(sprite.texture.get_size())
		return target.to_local(sprite.to_global(local))
	return null

func _exit_tree() -> void:
	for item in live_panels.duplicate(): _release_live_panel(item)
	for viewport in captures:
		if is_instance_valid(viewport): viewport.queue_free()

func capture(source: SubViewport, mask: int, parent: Node = null) -> Texture2D:
	var key := "%d:%d" % [source.get_instance_id(), mask]
	if terminal_captures.has(key): return terminal_captures[key].get_texture()
	var viewport := preload("res://scenes/RetainedViewport.gd").capture_state(source, mask, parent)
	captures.append(viewport)
	terminal_captures[key] = viewport
	return viewport.get_texture()

func panel(texture: Texture2D, rect: Rect2, parent: Node2D) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = texture
	_track_raster(sprite, texture)
	sprite.position = rect.get_center()
	_resize_panel(sprite, rect.size)
	texture.changed.connect(_resize_panel.bind(sprite, rect.size))
	var material := ShaderMaterial.new()
	material.shader = TransitionShader
	sprite.material = material
	parent.add_child(sprite)
	panels.append(sprite)

func _resize_panel(sprite: Sprite2D, extent: Vector2) -> void:
	# The frame's captures share their allocation before the first draw.
	# Changing raster density must not change the panel's logical geometry.
	if is_instance_valid(sprite):
		sprite.scale = extent / Vector2(sprite.texture.get_size()).max(Vector2.ONE)

func build(world: Node) -> void:
	dust_mode = world.dust_effect()
	depth_mode = world.depth_effect()
	depth_direction = world.tab_fx_direction
	depth_center = world.camera_2d.position
	depth_projection = get_parent().global_transform
	var fly_ratio: float = world.dust_flying_ratio()
	var view: Control = world.host.workspace_view
	for border in world._workspace_border_captures(not arriving):
		var rect: Rect2 = border.rect
		var still := preload("res://scenes/RetainedViewport.gd").new()
		still.disable_3d = true
		still.transparent_bg = true
		still.use_hdr_2d = true
		still.size = Vector2i(rect.size.ceil()).max(Vector2i.ONE)
		still.size_2d_override = still.size
		still.size_2d_override_stretch = true
		preload("res://scenes/EffectCaptureBudget.gd").fit(still)
		still.render_target_update_mode = SubViewport.UPDATE_ONCE
		still.add_child(border.drawing)
		view.canvas.add_child(still)
		captures.append(still)
		var group := Node2D.new()
		group.position = rect.get_center()
		group.z_index = -1
		group.set_meta("border_layer", border.kind)
		add_child(group)
		pane_groups.append(group)
		panel(still.get_texture(), Rect2(-rect.size * 0.5, rect.size), group)
	# Preserve the same graph and screen-space chrome as the 3D transition.
	var wires: Node2D = view.agent_links.wire_layer.still_copy(false, true)
	var owners: Node2D = view.chromium_links.wire_layer.still_copy()
	wires.commands.append_array(owners.commands)
	owners.free()
	var sockets: Node2D = view.agent_links.wire_layer.get_script().new()
	sockets.frozen = true
	sockets.unproject = view.agent_links.wire_layer.unproject
	for output in [false, true]:
		for button in view.agent_links.sockets(output).values():
			if button.visible:
				sockets.circle(button.position + button.size * 0.5, 4.0, button.get_meta("port_color"))
	for drawing in [wires, sockets]:
		if drawing.commands.is_empty():
			drawing.free()
			continue
		var group := ui_group(view.canvas_size() * 0.5, view.canvas_size())
		group.set_meta("graph_layer", "wires" if drawing == wires else "sockets")
		group.z_index = -1 if drawing == wires else 1
		drawing.position = -group.position
		group.add_child(drawing)
	var controls: Array = view.status_strips.values()
	for control in controls:
		if not control.visible or control.size.x <= 0 or control.size.y <= 0: continue
		var still := Capture.capture_control(control)
		view.canvas.add_child(still)
		captures.append(still)
		var rect: Rect2 = view.control_canvas_rect(control)
		var at := rect.position
		var end := rect.end
		var group := ui_group((at + end) * 0.5, view.canvas_size())
		group.z_index = 2
		group.set_meta("workspace_chrome", true)
		panel(still.get_texture(), Rect2((at - end) * 0.5, end - at), group)
		if not depth_mode: panels.pop_back() # Scatter chrome moves independently.
	for key in world._shown_panes():
		var pane: Control = view.panes[key]
		var group := Node2D.new()
		group.position = pane.get_transform() * (pane.size * 0.5)
		group.scale = pane.scale
		group.set_meta("pane_scale", pane.scale)
		add_child(group)
		pane_groups.append(group)
		var still := preload("res://scenes/RetainedViewport.gd").new()
		still.disable_3d = true
		still.transparent_bg = true
		still.use_hdr_2d = true
		still.size_2d_override = Vector2i(pane.size.ceil()).max(Vector2i.ONE)
		still.size_2d_override_stretch = true
		still.size = Vector2i((pane.size * minf(maxf(view.canvas_scale(), 1.0), 8192.0 / maxf(pane.size.x, pane.size.y))).ceil()).max(Vector2i.ONE)
		preload("res://scenes/EffectCaptureBudget.gd").fit(still)
		still.render_target_update_mode = SubViewport.UPDATE_ONCE
		still.add_child(pane.still_copy())
		view.canvas.add_child(still)
		captures.append(still)
		panel(still.get_texture(), Rect2(-pane.size * 0.5, pane.size), group)
		if not world.host.is_terminal_pane(key): continue
		var pair: Dictionary = world.host.sessions.get(int(key.substr(1)), {})
		if pair.is_empty(): continue
		var layout := Vector2(Core.layout_size(pair.vp))
		var origin: Vector2 = (view.terminal_origin(key) - group.position) / pane.scale
		if depth_mode:
			preload("res://scenes/TerminalViewportUpdates.gd").retain_live(pair.vp)
			# Expand a zoomed crop before focus hides the departing pane.
			pane._resize_terminal_preview()
			panel(pair.vp.get_texture(), Rect2(origin, layout), group)
			var item := {"sprite": panels.back(), "source": weakref(pair.vp), "size": layout}
			live_panels.append(item)
			pair.vp.tree_exiting.connect(_freeze_live_panel.bind(item))
			continue
		panel(capture(pair.vp, (1 << 17) | (1 << 19)), Rect2(origin, layout), group)
		if dust_mode:
			_build_dust(world, pair, key, origin, layout, group, fly_ratio)
		var cells: Array = []
		if dust_mode:
			var builder := preload("res://scenes/DustPieces.gd")
			cells = builder.letters(builder.cells(pair.term, world.dust_particle_budget()), fly_ratio)
		else:
			for glyph in pair.term.cell_glyphs():
				cells.append(Vector3i(glyph.col, glyph.row, 2 if glyph.get("wide", false) else 1))
			var cursor: Vector2i = pair.term.get_cursor_cell()
			if cursor.x >= 0 and not cells.any(func(cell): return cursor.x >= cell.x and cursor.x < cell.x + cell.z and cell.y == cursor.y):
				cells.append(Vector3i(cursor.x, cursor.y, 1))
		if cells.is_empty(): continue
		cells = Capture.limit_layers([cells], world.scatter_block_budget())[0]
		var runs := Capture.cell_runs(cells, 3)
		var cell_size: Vector2 = pair.term.get_cell_size()
		var padding := Vector2.ONE * float(pair.term.cell_padding)
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_2D
		batch.use_custom_data = true
		batch.use_colors = true
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		batch.mesh = quad
		batch.instance_count = runs.positions.size()
		for i in runs.positions.size():
			var extent := cell_size * Vector2(runs.widths[i], runs.heights[i])
			var at: Vector2 = pair.term.position + padding + Vector2(runs.positions[i]) * cell_size
			batch.set_instance_transform_2d(i, Transform2D(Vector2(extent.x, 0), Vector2(0, extent.y), origin + at + extent * 0.5))
			batch.set_instance_custom_data(i, Color(at.x / layout.x, at.y / layout.y, extent.x / layout.x, extent.y / layout.y))
		var layer := MultiMeshInstance2D.new()
		layer.texture = capture(pair.vp, 1 << 18)
		_track_raster(layer, layer.texture, layout)
		layer.multimesh = batch
		var material := ShaderMaterial.new()
		material.shader = TransitionShader
		material.set_shader_parameter("glyph_layer", true)
		material.set_shader_parameter("arrival_flight", arriving)
		material.set_shader_parameter("texture_size", layout)
		material.set_shader_parameter("extent", view.canvas_size())
		material.set_shader_parameter("flight_seed", randf())
		material.set_shader_parameter("terminal_origin", view.terminal_origin(key))
		layer.material = material
		group.add_child(layer)
		glyphs.append(layer)
	if depth_mode:
		for group in pane_groups + ui_groups:
			group.set_meta("depth_origin", group.position)
			group.set_meta("depth_scale", group.scale)
		set_progress(1.0 if arriving else 0.0)
		return
	var positions := PackedFloat32Array()
	for layer in glyphs:
		if layer.has_meta("dust"): continue
		var origin: Vector2 = layer.material.get_shader_parameter("terminal_origin")
		var layout: Vector2 = layer.material.get_shader_parameter("texture_size")
		for i in layer.multimesh.instance_count:
			var data: Color = layer.multimesh.get_instance_custom_data(i)
			positions.append(origin.x + (data.r + data.b * 0.5) * layout.x)
	var ranks := Capture.release_ranks(positions)
	var index := 0
	for layer in glyphs:
		if layer.has_meta("dust"): continue
		for i in layer.multimesh.instance_count:
			layer.multimesh.set_instance_color(i, Color(ranks[index], 1, 1, 1))
			index += 1

func _build_dust(world: Node, pair: Dictionary, key: String, origin: Vector2, layout: Vector2, group: Node2D, fly_ratio: float) -> void:
	var builder := preload("res://scenes/DustPieces.gd")
	var cells := builder.cells(pair.term, world.dust_particle_budget())
	var positions := PackedFloat32Array()
	for item in cells: positions.append(float(item.x))
	var particles := builder.particles(pair.term, Rect2(pair.term.position, pair.term.size), cells, world.dust_particle_budget(), Capture.release_ranks(positions), fly_ratio)
	var regions: Array = particles.rects
	if regions.is_empty(): return
	var batch := MultiMesh.new()
	batch.transform_format = MultiMesh.TRANSFORM_2D
	batch.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	batch.mesh = quad
	batch.use_colors = true
	batch.instance_count = regions.size()
	for i in regions.size():
		var rect: Rect2 = regions[i]
		batch.set_instance_color(i, Color(particles.ranks[i], 1, 1, 1))
		batch.set_instance_transform_2d(i, Transform2D(Vector2(rect.size.x, 0), Vector2(0, rect.size.y), origin + rect.get_center()))
		batch.set_instance_custom_data(i, Color(rect.position.x / layout.x, rect.position.y / layout.y, rect.size.x / layout.x, rect.size.y / layout.y))
	var layer := MultiMeshInstance2D.new()
	layer.multimesh = batch
	layer.texture = capture(pair.vp, 1 << 18)
	_track_raster(layer, layer.texture, layout)
	layer.set_meta("dust", true)
	var material := ShaderMaterial.new()
	material.shader = TransitionShader
	material.set_shader_parameter("dust_mode", true)
	material.set_shader_parameter("dust_count", regions.size())
	material.set_shader_parameter("arrival_flight", arriving)
	material.set_shader_parameter("texture_size", layout)
	material.set_shader_parameter("extent", world.host.workspace_view.canvas_size())
	material.set_shader_parameter("terminal_origin", world.host.workspace_view.terminal_origin(key))
	layer.material = material
	group.add_child(layer)
	glyphs.append(layer)

func ui_group(center: Vector2, extent: Vector2) -> Node2D:
	var group := Node2D.new()
	group.position = center
	group.set_meta("origin", center)
	group.set_meta("camera_offset", center - extent * 0.5)
	var radial := center / extent - Vector2(0.5, 0.5)
	group.set_meta("rank", clampf(1.0 - radial.length() * sqrt(2.0), 0.0, 1.0))
	var jitter := Vector2(randf(), randf())
	var wind := Motion.wind(center / extent, jitter)
	group.set_meta("wind", wind)
	group.set_meta("drift", Motion.drift(center / extent, jitter, wind))
	group.set_meta("span", minf(extent.x, extent.y))
	group.set_meta("spin", radial.x * 0.3)
	add_child(group)
	ui_groups.append(group)
	return group

func set_progress(value: float) -> void:
	progress = clampf(value, 0.0, 1.0)
	if depth_mode:
		var phase := DepthMotion.phase(progress)
		var magnification := DepthMotion.magnification(progress, depth_direction, arriving)
		var opacity := (1.0 - phase) * (1.0 - DepthMotion.phase(depth_retirement / DepthMotion.RETIRE_DURATION) if depth_retirement >= 0.0 else 1.0)
		# Cancel the live camera's saved pan/zoom. The whole captured workspace
		# keeps its original projection and moves with one common dolly scale.
		transform = get_parent().global_transform.affine_inverse() * depth_projection
		for group in pane_groups + ui_groups:
			group.position = depth_center + (Vector2(group.get_meta("depth_origin")) - depth_center) * magnification
			group.scale = Vector2(group.get_meta("depth_scale")) * magnification
			if group.has_meta("graph_layer"): group.modulate.a = opacity
		for item in panels:
			item.material.set_shader_parameter("depth_alpha", opacity)
			item.material.set_shader_parameter("depth_blur", phase * 6.0)
		_update_raster()
		return
	for group in ui_groups:
		if group.has_meta("graph_layer"):
			group.modulate.a = 1.0 - smoothstep(0.0, 0.3, progress)
			continue
		if dust_mode:
			group.modulate.a = 1.0 - smoothstep(0.0, 0.7, progress)
			continue
		var rank: float = group.get_meta("rank")
		var flight := Motion.retire_flight(retirement_phase, rank, retirement_time) if retirement_time >= 0.0 else Motion.clock(progress, rank, arriving)
		# Emulate the 3D near plane: past the eye is invisible, never mirrored.
		var depth := 1.5 * flight
		group.scale = Vector2.ONE / maxf(1.0 - depth, 0.01)
		var wind: Vector2 = group.get_meta("wind")
		var drift: Vector2 = group.get_meta("drift")
		var lateral := drift * flight + wind * Motion.wind_distance(flight)
		if arriving: lateral.x = -lateral.x
		group.position = group.get_meta("origin") + lateral * float(group.get_meta("span")) * group.scale.x
		group.rotation = group.get_meta("spin") * flight
		group.modulate.a = 1.0 if depth < 0.99 else 0.0
	var backing_flight := smoothstep(0.0, 0.3, progress)
	for item in panels:
		if item.material is ShaderMaterial: item.material.set_shader_parameter("progress", backing_flight)
		else: item.modulate.a = 1.0 - backing_flight
	for group in pane_groups: group.scale = group.get_meta("pane_scale", Vector2.ONE) * (1.0 - 0.06 * backing_flight)
	for layer in glyphs:
		# Sibling pane groups must not paint their backings over flying ink.
		layer.z_index = 1 if progress > 0.0 else 0
		layer.material.set_shader_parameter("progress", progress)
		layer.material.set_shader_parameter("retirement_time", retirement_time)
		layer.material.set_shader_parameter("retirement_phase", retirement_phase)
	_update_raster()


func _track_raster(item: Node2D, texture: Texture2D, logical := Vector2.ZERO) -> void:
	for viewport in captures:
		if viewport.get_texture() == texture:
			item.set_meta("presentation_viewport", weakref(viewport))
			item.set_meta("presentation_size", logical)
			raster_items.append(item)
			return


func _update_raster() -> void:
	for item in raster_items:
		var viewport: SubViewport = item.get_meta("presentation_viewport").get_ref()
		if not is_instance_valid(viewport): continue
		var scale := item.get_global_transform_with_canvas().get_scale().abs()
		var logical: Vector2 = item.get_meta("presentation_size")
		# Sprites compensate texture size in their own scale; glyph batches use
		# logical cell geometry and normalized UVs at every raster density.
		if logical == Vector2.ZERO: logical = Vector2(viewport.size)
		viewport.request_extent(logical * scale)

func _release_live_panel(item: Dictionary) -> void:
	var source: SubViewport = item.source.get_ref()
	if is_instance_valid(source):
		var callback := _freeze_live_panel.bind(item)
		if source.tree_exiting.is_connected(callback): source.tree_exiting.disconnect(callback)
		preload("res://scenes/TerminalViewportUpdates.gd").release_live(source)
	live_panels.erase(item)

func _freeze_live_panel(item: Dictionary) -> void:
	var source: SubViewport = item.source.get_ref()
	if is_instance_valid(source):
		var sprite: Sprite2D = item.sprite
		sprite.texture.changed.disconnect(_resize_panel.bind(sprite, item.size))
		sprite.texture = capture(source, (1 << 17) | (1 << 18) | (1 << 19), self)
		_track_raster(sprite, sprite.texture)
		_resize_panel(sprite, item.size)
		sprite.texture.changed.connect(_resize_panel.bind(sprite, item.size))
	_release_live_panel(item)

func retire() -> void:
	# An interrupted layer retains its last view before its source is reused.
	for item in live_panels.duplicate(): _freeze_live_panel(item)
	if depth_mode:
		depth_retirement = 0.0
		return
	if arriving and retirement_time < 0.0:
		retirement_time = 0.0
		retirement_phase = progress

func advance_retirement(dt: float) -> bool:
	if depth_mode:
		depth_retirement += dt
		set_progress(progress)
		return depth_retirement < DepthMotion.RETIRE_DURATION
	if retirement_time >= 0.0:
		retirement_time += dt
		set_progress(Motion.retire_pose(retirement_phase, -1.0 / Motion.ARRIVAL, retirement_time))
		return retirement_time < Motion.DEPARTURE
	set_progress(progress + dt / Motion.DEPARTURE)
	return progress < 1.0
