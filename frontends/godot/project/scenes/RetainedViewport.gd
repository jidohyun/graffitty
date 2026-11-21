extends SubViewport
## A retained presentation can rasterize again at a new projected size. Its
## children own immutable terminal drawing commands or copied UI state.
const Core := preload("res://scenes/TerminalEffects.gd")
var terminal_view: Control
var _requested_extent := Vector2.ZERO


static func capture_state(source: SubViewport, mask: int, parent: Node = null) -> SubViewport:
	var snapshot: RefCounted
	if source.has_meta("terminal_render_node"):
		var reference: WeakRef = source.get_meta("terminal_render_node")
		var node: Node = reference.get_ref()
		var frame := Engine.get_process_frames()
		var state: Dictionary = source.get_meta("transition_render_state", {})
		if state.get("frame", -1) != frame:
			state = {"frame": frame, "snapshot": node.capture_render_state()}
			source.set_meta("transition_render_state", state)
			# Views own the immutable native state; the live terminal does not retain it.
			source.call_deferred("remove_meta", "transition_render_state")
		snapshot = state.snapshot
	var viewport := new()
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.use_hdr_2d = source.use_hdr_2d
	viewport.canvas_cull_mask = 1 | mask
	viewport.size_2d_override = Core.layout_size(source)
	viewport.size_2d_override_stretch = true
	viewport.oversampling = source.oversampling
	viewport.size = initial_size(source)
	preload("res://scenes/EffectCaptureBudget.gd").fit(viewport)
	if snapshot != null:
		viewport.terminal_view = snapshot.create_view(viewport._density())
		viewport.add_child(viewport.terminal_view)
	else:
		# UI-only sources retain their controls and vector drawing state too.
		for child in source.get_children():
			if child is CanvasItem: viewport.add_child(child.duplicate(0))
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Closing the source must not destroy the retained presentation.
	# A source's tree_exiting callback cannot add siblings while its parent is
	# removing it. Live transition layers supply themselves as the retained owner.
	(parent if parent != null else source.get_parent()).add_child(viewport)
	return viewport


static func initial_size(viewport: SubViewport) -> Vector2i:
	# Captures use full-sheet UVs, while live zoomed panes may rasterize a crop.
	# Undo the crop's size reduction so visible glyphs retain their texel density.
	var extent := Vector2(viewport.size) * viewport.canvas_transform.get_scale().abs()
	var budget := 4_000_000.0 if OS.has_feature("android") or OS.has_feature("ios") else 20_000_000.0
	var scale := minf(1.0, 8192.0 / maxf(1.0, maxf(extent.x, extent.y)))
	scale = minf(scale, sqrt(budget / maxf(extent.x * extent.y, 1.0)))
	return Vector2i((extent * scale).round()).max(Vector2i.ONE)


func _ready() -> void:
	size_changed.connect(_raster_changed)
	_raster_changed()


func _density() -> float:
	var logical := Vector2(Core.layout_size(self)).max(Vector2.ONE)
	return maxf(size.x / logical.x, size.y / logical.y)


func _raster_changed() -> void:
	if is_instance_valid(terminal_view): terminal_view.set_raster_scale(_density())
	render_target_update_mode = SubViewport.UPDATE_ONCE


func request_extent(extent: Vector2) -> void:
	if not extent.is_finite(): return
	# Grow in quarter-density steps, retaining the best raster until retirement.
	# This avoids reallocating a texture for every fractional camera movement.
	var logical := Vector2(Core.layout_size(self)).max(Vector2.ONE)
	var density := ceilf(maxf(extent.x / logical.x, extent.y / logical.y) * 4.0) / 4.0
	var requested := logical * maxf(density, 1.0)
	var pixels := 4_000_000.0 if OS.has_feature("android") or OS.has_feature("ios") else 20_000_000.0
	requested *= minf(1.0, minf(8192.0 / maxf(requested.x, requested.y), sqrt(pixels / (requested.x * requested.y))))
	if requested.x <= maxf(_requested_extent.x, size.x) and requested.y <= maxf(_requested_extent.y, size.y): return
	_requested_extent = requested
	if size_2d_override == Vector2i.ZERO:
		size_2d_override = size
		size_2d_override_stretch = true
	size = Vector2i(requested.ceil()).max(Vector2i.ONE)
	preload("res://scenes/EffectCaptureBudget.gd").fit(self)
